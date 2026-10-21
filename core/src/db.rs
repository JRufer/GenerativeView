//! The lookup database: one SQLite file with a row per media file, holding
//! what the grid needs (name, size, dimensions) and lower-cased search text
//! (prompts, models, LoRAs, settings).
//!
//! Search is a plain substring scan over that text. A trigram full-text index
//! was measured and dropped: it made first-time indexing about four times
//! slower and bought nothing at the size of an image folder, where scanning
//! ten thousand rows takes a few milliseconds.
//!
//! Exact filters (`model:="flux1-dev.safetensors"`) and the usage counts
//! read a second text column, `facets`, the same way: one scan, no extra
//! tables to keep in step while indexing.

use crate::dates;
use crate::meta::{facet_value, GenInfo};
use crate::notes::{Flag, Note};
use parking_lot::Mutex;
use rusqlite::functions::FunctionFlags;
use rusqlite::{params, params_from_iter, Connection, OpenFlags};
use std::collections::{BTreeMap, HashMap};
use std::path::Path;

pub type DbResult<T> = Result<T, rusqlite::Error>;

const SCHEMA_VERSION: i64 = 5;

// `files` stays narrow so listing a folder touches few pages. The search
// text lives beside it in `ftext`, lower-cased; it is only ever searched,
// never shown (the UI reads full metadata straight from the file when
// asked). `blob` is every field joined, so an unqualified term is one scan.
// `facets` lists what the image was made with, one line each, in the layout
// `GenInfo::facets_text` describes.
const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS files (
    id       INTEGER PRIMARY KEY,
    dir      TEXT NOT NULL,
    name     TEXT NOT NULL,
    size     INTEGER NOT NULL,
    mtime    INTEGER NOT NULL,
    kind     INTEGER NOT NULL,
    width    INTEGER NOT NULL DEFAULT 0,
    height   INTEGER NOT NULL DEFAULT 0,
    duration INTEGER NOT NULL DEFAULT 0,
    source   TEXT NOT NULL DEFAULT '',
    seed     TEXT NOT NULL DEFAULT '',
    UNIQUE (dir, name)
);
CREATE INDEX IF NOT EXISTS files_dir_mtime ON files (dir, mtime);

CREATE TABLE IF NOT EXISTS ftext (
    id       INTEGER PRIMARY KEY,
    lname    TEXT NOT NULL DEFAULT '',
    prompt   TEXT NOT NULL DEFAULT '',
    negative TEXT NOT NULL DEFAULT '',
    model    TEXT NOT NULL DEFAULT '',
    loras    TEXT NOT NULL DEFAULT '',
    extra    TEXT NOT NULL DEFAULT '',
    blob     TEXT NOT NULL DEFAULT '',
    facets   TEXT NOT NULL DEFAULT ''
);
CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
    DELETE FROM ftext WHERE id = old.id;
END;

CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE TABLE IF NOT EXISTS notes (
    dir         TEXT NOT NULL,
    name        TEXT NOT NULL,
    rating      INTEGER NOT NULL DEFAULT 0,
    flag        INTEGER NOT NULL DEFAULT 0,
    collections TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (dir, name)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS note_files (
    dir   TEXT PRIMARY KEY,
    mtime INTEGER NOT NULL,
    size  INTEGER NOT NULL
) WITHOUT ROWID;
"#;

/// What the scanner knows about a file on disk, plus its parsed metadata.
pub struct FileRecord {
    pub dir: String,
    pub name: String,
    pub size: i64,
    pub mtime: i64,
    pub video: bool,
    pub info: GenInfo,
}

#[derive(Debug, Clone, Default)]
pub struct Query {
    pub dir: String,
    pub recursive: bool,
    pub text: String,
    /// newest | oldest | name | name_desc | size | relevance (best match
    /// for `text` first)
    pub sort: String,
    /// The order among equally good matches when `sort` is relevance, which
    /// is the whole order when nothing in `text` can match better or worse:
    /// any of the others. Empty = newest.
    pub then: String,
}

/// (id, dir index, name, kind, width, height, mtime, size, duration ms)
pub type Row = (i64, u32, String, u8, u32, u32, i64, i64, i64);

#[derive(Debug, Default, serde::Serialize)]
pub struct QueryResult {
    pub dirs: Vec<String>,
    pub rows: Vec<Row>,
    /// For each row, what the user has said about it (see [`mark`]); may be
    /// empty, which is the same as all zero.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub marks: Vec<u8>,
}

impl QueryResult {
    /// The rows at `indexes`, in that order, with their marks.
    pub fn pick(&self, indexes: impl IntoIterator<Item = usize>) -> QueryResult {
        let mut out = QueryResult { dirs: self.dirs.clone(), ..Default::default() };
        for i in indexes {
            out.rows.push(self.rows[i].clone());
            out.marks.push(self.marks.get(i).copied().unwrap_or(0));
        }
        out
    }
}

/// A picture's rating (0 to 5) and flag (see [`crate::notes::Flag`]) in one
/// byte: the rating in the low three bits, the flag in the two above.
pub fn mark(rating: u8, flag: u8) -> u8 {
    (rating & 7) | (flag & 3) << 3
}

impl QueryResult {
    /// Fixed-layout binary form for the UI, which reads fields straight out
    /// of the buffer instead of parsing ten thousand JSON arrays. All
    /// integers little-endian:
    ///
    /// ```text
    /// header  u32 magic "GVQ1", u32 rows, u32 dirs, u32 string bytes
    /// rows    48 bytes each:
    ///           i64 id, i64 mtime (ms), i64 size,
    ///           u32 width, u32 height, u32 duration (ms),
    ///           u32 name offset, u16 name length, u8 kind, u8 mark, u32 dir index
    /// dirs    8 bytes each: u32 offset, u32 length
    /// strings UTF-8, addressed by the offsets above
    /// ```
    pub fn pack(&self) -> Vec<u8> {
        let names: usize = self.rows.iter().map(|r| r.2.len()).sum();
        let dirs: usize = self.dirs.iter().map(String::len).sum();
        let mut out = Vec::with_capacity(16 + self.rows.len() * 48 + self.dirs.len() * 8 + names + dirs);
        let mut strings: Vec<u8> = Vec::with_capacity(names + dirs);
        out.extend_from_slice(b"GVQ1");
        out.extend_from_slice(&(self.rows.len() as u32).to_le_bytes());
        out.extend_from_slice(&(self.dirs.len() as u32).to_le_bytes());
        out.extend_from_slice(&((names + dirs) as u32).to_le_bytes());
        for (i, (id, dir, name, kind, width, height, mtime, size, duration)) in self.rows.iter().enumerate() {
            out.extend_from_slice(&id.to_le_bytes());
            out.extend_from_slice(&mtime.to_le_bytes());
            out.extend_from_slice(&size.to_le_bytes());
            out.extend_from_slice(&width.to_le_bytes());
            out.extend_from_slice(&height.to_le_bytes());
            out.extend_from_slice(&(*duration as u32).to_le_bytes());
            out.extend_from_slice(&(strings.len() as u32).to_le_bytes());
            out.extend_from_slice(&(name.len() as u16).to_le_bytes());
            out.push(*kind);
            out.push(self.marks.get(i).copied().unwrap_or(0));
            out.extend_from_slice(&dir.to_le_bytes());
            strings.extend_from_slice(name.as_bytes());
        }
        for dir in &self.dirs {
            out.extend_from_slice(&(strings.len() as u32).to_le_bytes());
            out.extend_from_slice(&(dir.len() as u32).to_le_bytes());
            strings.extend_from_slice(dir.as_bytes());
        }
        out.extend_from_slice(&strings);
        out
    }
}

pub struct Db {
    write: Mutex<Connection>,
    read: Mutex<Connection>,
}

fn tune(conn: &Connection) -> DbResult<()> {
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;
         PRAGMA temp_store = MEMORY;
         PRAGMA cache_size = -16000;
         PRAGMA mmap_size = 268435456;",
    )
}

impl Db {
    pub fn open(dir: &Path) -> DbResult<Db> {
        let _ = std::fs::create_dir_all(dir);
        let path = dir.join("index.db");
        let mut write = Connection::open(&path)?;
        tune(&write)?;
        let version: i64 = write.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version != SCHEMA_VERSION {
            // The index is a cache of what is on disk: rebuilding beats migrating.
            let tx = write.transaction()?;
            tx.execute_batch(
                "DROP TABLE IF EXISTS search;
                 DROP TABLE IF EXISTS ftext;
                 DROP TABLE IF EXISTS files;
                 DROP TABLE IF EXISTS notes;
                 DROP TABLE IF EXISTS note_files;",
            )?;
            tx.execute_batch(SCHEMA)?;
            tx.pragma_update(None, "user_version", SCHEMA_VERSION)?;
            tx.commit()?;
        }
        let read = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX | OpenFlags::SQLITE_OPEN_URI,
        )?;
        read.execute_batch("PRAGMA temp_store = MEMORY; PRAGMA cache_size = -16000; PRAGMA mmap_size = 268435456;")?;
        register_functions(&read)?;
        Ok(Db { write: Mutex::new(write), read: Mutex::new(read) })
    }

    // ------------------------------------------------------------ settings

    pub fn get_setting(&self, key: &str) -> Option<String> {
        self.read
            .lock()
            .query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| r.get(0))
            .ok()
    }

    pub fn all_settings(&self) -> HashMap<String, String> {
        let conn = self.read.lock();
        let mut out = HashMap::new();
        if let Ok(mut stmt) = conn.prepare("SELECT key, value FROM settings") {
            if let Ok(rows) = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))) {
                out.extend(rows.flatten());
            }
        }
        out
    }

    pub fn set_setting(&self, key: &str, value: &str) -> DbResult<()> {
        self.write.lock().execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2)
             ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    // ------------------------------------------------------------ notes

    /// When `dir`'s notes file was last read: (mtime, size), or None if it
    /// was not there.
    pub fn notes_stamp(&self, dir: &str) -> Option<(i64, i64)> {
        self.read
            .lock()
            .query_row("SELECT mtime, size FROM note_files WHERE dir = ?1", [dir], |r| Ok((r.get(0)?, r.get(1)?)))
            .ok()
    }

    pub fn set_notes_stamp(&self, dir: &str, stamp: Option<(i64, i64)>) -> DbResult<()> {
        let conn = self.write.lock();
        match stamp {
            Some((mtime, size)) => conn.execute(
                "INSERT INTO note_files (dir, mtime, size) VALUES (?1, ?2, ?3)
                 ON CONFLICT (dir) DO UPDATE SET mtime = excluded.mtime, size = excluded.size",
                params![dir, mtime, size],
            )?,
            None => conn.execute("DELETE FROM note_files WHERE dir = ?1", [dir])?,
        };
        Ok(())
    }

    /// Every note held for pictures in `dir`, by name.
    pub fn notes_in(&self, dir: &str) -> DbResult<Vec<(String, Note)>> {
        let conn = self.read.lock();
        let mut stmt = conn.prepare_cached("SELECT name, rating, flag, collections FROM notes WHERE dir = ?1 ORDER BY name")?;
        let rows = stmt.query_map([dir], |r| Ok((r.get::<_, String>(0)?, note_from(r.get(1)?, r.get(2)?, &r.get::<_, String>(3)?))))?;
        rows.collect()
    }

    /// Replace what the index holds for `dir`'s notes.
    pub fn replace_notes(&self, dir: &str, notes: &[(String, Note)]) -> DbResult<()> {
        let mut conn = self.write.lock();
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM notes WHERE dir = ?1", [dir])?;
        {
            let mut stmt = tx.prepare_cached("INSERT OR REPLACE INTO notes (dir, name, rating, flag, collections) VALUES (?1, ?2, ?3, ?4, ?5)")?;
            for (name, note) in notes {
                if note.is_empty() {
                    continue;
                }
                let collections = note.collections.iter().map(|c| format!("{c}\n")).collect::<String>();
                stmt.execute(params![dir, name, note.rating, note.flag as u8, collections])?;
            }
        }
        tx.commit()
    }

    /// The note for one picture; empty if there is none.
    pub fn note(&self, dir: &str, name: &str) -> Note {
        self.read
            .lock()
            .query_row("SELECT rating, flag, collections FROM notes WHERE dir = ?1 AND name = ?2", [dir, name], |r| {
                Ok(note_from(r.get(0)?, r.get(1)?, &r.get::<_, String>(2)?))
            })
            .unwrap_or_default()
    }

    /// Every collection name anywhere in the index, with how many pictures
    /// are in it, most used first.
    pub fn collection_names(&self) -> DbResult<Vec<(String, u32)>> {
        let conn = self.read.lock();
        let mut stmt = conn.prepare_cached("SELECT collections FROM notes WHERE collections != ''")?;
        let mut rows = stmt.query([])?;
        let mut counts: HashMap<String, (String, u32)> = HashMap::new();
        while let Some(r) = rows.next()? {
            for name in r.get_ref(0)?.as_str()?.split('\n').filter(|n| !n.is_empty()) {
                counts.entry(name.to_lowercase()).or_insert_with(|| (name.to_string(), 0)).1 += 1;
            }
        }
        let mut out: Vec<(String, u32)> = counts.into_values().collect();
        out.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.to_lowercase().cmp(&b.0.to_lowercase())));
        Ok(out)
    }

    /// Every picture in the collection `name` (in any letter case), as
    /// (dir, file name, the collection as that note spells it).
    pub fn collection_members(&self, name: &str) -> DbResult<Vec<(String, String, String)>> {
        let target = name.to_lowercase();
        let conn = self.read.lock();
        let mut stmt = conn.prepare_cached("SELECT dir, name, collections FROM notes WHERE collections != ''")?;
        let mut rows = stmt.query([])?;
        let mut out = Vec::new();
        while let Some(r) = rows.next()? {
            let lines = r.get_ref(2)?.as_str()?;
            if let Some(spelt) = lines.split('\n').find(|c| !c.is_empty() && c.to_lowercase() == target) {
                out.push((r.get(0)?, r.get(1)?, spelt.to_string()));
            }
        }
        Ok(out)
    }

    /// The folders under `root` that hold a notes file the index knows of.
    pub fn note_dirs(&self, root: &str, recursive: bool) -> DbResult<Vec<String>> {
        let conn = self.read.lock();
        let (cond, args) = dir_condition(root, recursive, "");
        let mut stmt = conn.prepare(&format!("SELECT dir FROM note_files WHERE {cond}"))?;
        let rows = stmt.query_map(params_from_iter(args.iter()), |r| r.get(0))?;
        rows.collect()
    }

    // ------------------------------------------------------------ indexing

    /// Everything the index currently holds under `root`:
    /// (dir, name) -> (id, size, mtime).
    pub fn snapshot(&self, root: &str, recursive: bool) -> DbResult<HashMap<(String, String), (i64, i64, i64)>> {
        let conn = self.read.lock();
        let (cond, args) = dir_condition(root, recursive, "");
        let sql = format!("SELECT id, dir, name, size, mtime FROM files WHERE {cond}");
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(args.iter()), |r| {
            Ok(((r.get::<_, String>(1)?, r.get::<_, String>(2)?), (r.get(0)?, r.get(3)?, r.get(4)?)))
        })?;
        rows.collect()
    }

    pub fn upsert(&self, records: &[FileRecord]) -> DbResult<()> {
        if records.is_empty() {
            return Ok(());
        }
        let mut conn = self.write.lock();
        let tx = conn.transaction()?;
        {
            let mut file = tx.prepare_cached(
                "INSERT INTO files (dir, name, size, mtime, kind, width, height, duration, source, seed)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                 ON CONFLICT (dir, name) DO UPDATE SET
                    size = excluded.size, mtime = excluded.mtime, kind = excluded.kind,
                    width = excluded.width, height = excluded.height, duration = excluded.duration,
                    source = excluded.source, seed = excluded.seed
                 RETURNING id",
            )?;
            let mut text = tx.prepare_cached(
                "INSERT OR REPLACE INTO ftext (id, lname, prompt, negative, model, loras, extra, blob, facets)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            )?;
            for r in records {
                let i = &r.info;
                let id: i64 = file.query_row(
                    params![r.dir, r.name, r.size, r.mtime, r.video as i64, i.width, i.height, i.duration_ms as i64, i.source, i.seed],
                    |row| row.get(0),
                )?;
                let lname = r.name.to_lowercase();
                let prompt = i.prompt.to_lowercase();
                let negative = i.negative.to_lowercase();
                let model = i.models_text().to_lowercase();
                let loras = i.loras_text().to_lowercase();
                let extra = i.extra_text().to_lowercase();
                let blob = [lname.as_str(), &prompt, &negative, &model, &loras, &extra].join("\n");
                text.execute(params![id, lname, prompt, negative, model, loras, extra, blob, i.facets_text()])?;
            }
        }
        tx.commit()
    }

    pub fn delete_ids(&self, ids: &[i64]) -> DbResult<()> {
        if ids.is_empty() {
            return Ok(());
        }
        let mut conn = self.write.lock();
        let tx = conn.transaction()?;
        {
            let mut stmt = tx.prepare_cached("DELETE FROM files WHERE id = ?1")?;
            for id in ids {
                stmt.execute([id])?;
            }
        }
        tx.commit()
    }

    pub fn delete_path(&self, dir: &str, name: &str) -> DbResult<usize> {
        self.write.lock().execute("DELETE FROM files WHERE dir = ?1 AND name = ?2", params![dir, name])
    }

    /// Drop every row under a directory (it was removed or renamed away).
    pub fn delete_tree(&self, dir: &str) -> DbResult<usize> {
        let (cond, args) = dir_condition(dir, true, "");
        self.write.lock().execute(&format!("DELETE FROM files WHERE {cond}"), params_from_iter(args.iter()))
    }

    pub fn count(&self) -> i64 {
        self.read.lock().query_row("SELECT count(*) FROM files", [], |r| r.get(0)).unwrap_or(0)
    }

    // ------------------------------------------------------------ querying

    pub fn query(&self, q: &Query) -> DbResult<QueryResult> {
        let terms = parse_terms(&q.text);
        let (cond, mut args) = filter_sql(&q.dir, q.recursive, &terms);
        let ranked = if q.sort == "relevance" { rank_sql(&terms, &mut args) } else { None };
        let plain = |sort: &str| match sort {
            "oldest" => "f.mtime ASC, f.name ASC",
            "name" => "f.dir ASC, f.name COLLATE NOCASE ASC",
            "name_desc" => "f.dir DESC, f.name COLLATE NOCASE DESC",
            "size" => "f.size DESC, f.name ASC",
            // Best rated first; kept before unflagged before rejected among
            // equals, then newest.
            "rating" => "coalesce(n.rating, 0) DESC, CASE coalesce(n.flag, 0) WHEN 1 THEN 0 WHEN 0 THEN 1 ELSE 2 END, f.mtime DESC, f.name DESC",
            _ => "f.mtime DESC, f.name DESC",
        };
        let order = match (q.sort.as_str(), &ranked) {
            ("relevance", Some(rank)) => format!("{rank} DESC, {}", plain(&q.then)),
            ("relevance", None) => plain(&q.then).to_string(),
            (sort, _) => plain(sort).to_string(),
        };
        // The text table only when a term actually reads it; the notes
        // always, for the marks on the tiles (a lookup by key per row).
        let join = if needs_text(&terms) || ranked.is_some() { "JOIN ftext t ON t.id = f.id" } else { "" };
        let sql = format!(
            "SELECT f.id, f.dir, f.name, f.kind, f.width, f.height, f.mtime, f.size, f.duration,
                    coalesce(n.rating, 0), coalesce(n.flag, 0)
             FROM files f {join} LEFT JOIN notes n ON n.dir = f.dir AND n.name = f.name
             WHERE {cond} ORDER BY {order}"
        );
        let conn = self.read.lock();
        let mut stmt = conn.prepare_cached(&sql)?;
        let mut rows = stmt.query(params_from_iter(args.iter()))?;
        let mut out = QueryResult::default();
        let mut dir_index: HashMap<String, u32> = HashMap::new();
        while let Some(r) = rows.next()? {
            let dir: String = r.get(1)?;
            let di = match dir_index.get(&dir) {
                Some(&i) => i,
                None => {
                    let i = out.dirs.len() as u32;
                    out.dirs.push(dir.clone());
                    dir_index.insert(dir, i);
                    i
                }
            };
            out.rows.push((r.get(0)?, di, r.get(2)?, r.get::<_, i64>(3)? as u8, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?, r.get(8)?));
            out.marks.push(mark(r.get::<_, i64>(9)? as u8, r.get::<_, i64>(10)? as u8));
        }
        Ok(out)
    }
}

/// The WHERE clause (over `files f`, `ftext t` and `notes n`) for a folder
/// and the terms of a search, and the values it binds.
fn filter_sql(dir: &str, recursive: bool, terms: &[Term]) -> (String, Vec<String>) {
    let (mut cond, mut args) = dir_condition(dir, recursive, "f.");
    for term in terms {
        term.to_sql(&mut cond, &mut args);
    }
    (cond, args)
}

/// Whether any of `terms` reads the `ftext` table.
fn needs_text(terms: &[Term]) -> bool {
    terms.iter().any(Term::reads_text)
}

fn note_from(rating: i64, flag: i64, collections: &str) -> Note {
    Note {
        rating: rating.clamp(0, crate::notes::MAX_RATING as i64) as u8,
        flag: Flag::from_i64(flag),
        collections: collections.split('\n').filter(|c| !c.is_empty()).map(str::to_string).collect(),
    }
}

/// SQL predicate selecting a directory, optionally with everything below it.
/// Uses a range on the `dir` index rather than LIKE so it stays an index scan.
fn dir_condition(root: &str, recursive: bool, prefix: &str) -> (String, Vec<String>) {
    let root = if root.len() > 1 { root.trim_end_matches('/') } else { root };
    if !recursive {
        return (format!("{prefix}dir = ?1"), vec![root.to_string()]);
    }
    if root == "/" || root.is_empty() {
        return ("1 = 1".to_string(), Vec::new());
    }
    // Children sort between "root/" and "root0" ('0' is the byte after '/').
    (
        format!("({prefix}dir = ?1 OR ({prefix}dir >= ?2 AND {prefix}dir < ?3))"),
        vec![root.to_string(), format!("{root}/"), format!("{root}0")],
    )
}

// ---------------------------------------------------------------- search terms

#[derive(Debug, PartialEq)]
struct Term {
    negate: bool,
    /// A text column to search (`lname`, `prompt`, `negative`, `model`,
    /// `loras`), or one of the fields with rules of their own (`seed`,
    /// `source`, `date`, the facets `sampler`, `scheduler`, `steps`, `cfg`,
    /// `size`, and the notes `rating`, `flag`, `collection`). `similar` is
    /// answered by content search, not here. None = anywhere.
    field: Option<&'static str>,
    /// `field:=text`: the whole value, not part of it.
    exact: bool,
    text: String,
}

/// How a word search treats the two ends of what was typed.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
struct Ends {
    /// `*fox`: may start in the middle of a word.
    open_start: bool,
    /// `fox*`: may stop in the middle of a word.
    open_end: bool,
}

impl Ends {
    fn flags(self) -> u8 {
        self.open_start as u8 | (self.open_end as u8) << 1
    }

    fn from_flags(flags: i64) -> Ends {
        Ends { open_start: flags & 1 != 0, open_end: flags & 2 != 0 }
    }
}

fn field_alias(s: &str) -> Option<&'static str> {
    Some(match s.to_ascii_lowercase().as_str() {
        "name" | "file" | "filename" => "lname",
        "prompt" | "pos" | "positive" | "p" => "prompt",
        "neg" | "negative" | "n" => "negative",
        "model" | "m" | "checkpoint" | "ckpt" => "model",
        "lora" | "loras" | "l" => "loras",
        "seed" => "seed",
        "source" | "src" | "tool" => "source",
        "sampler" => "sampler",
        "scheduler" => "scheduler",
        "steps" => "steps",
        "cfg" => "cfg",
        "size" | "res" | "resolution" => "size",
        "date" => "date",
        "fullprompt" | "wholeprompt" => "fullprompt",
        "fullneg" | "wholeneg" => "fullneg",
        "rating" | "rated" | "stars" => "rating",
        "flag" | "flagged" => "flag",
        "collection" | "col" | "in" => "collection",
        "similar" | "like" => "similar",
        "taste" | "likely" => "taste",
        "type" | "kind" | "media" | "is" => "kind",
        _ => return None,
    })
}

/// Split a search box string into terms: whitespace separated, "quoted
/// phrases" kept whole, `-term` to exclude, `field:term` to target a column,
/// `field:=term` to match the whole of a value rather than part of it. A `*`
/// at either end of a word (`fox*`, `*lond*`) lets it match part of a longer
/// one; see [`Term::words`].
fn parse_terms(text: &str) -> Vec<Term> {
    let mut terms = Vec::new();
    let mut chars = text.chars().peekable();
    loop {
        while chars.peek().map_or(false, |c| c.is_whitespace()) {
            chars.next();
        }
        if chars.peek().is_none() {
            break;
        }
        let mut negate = false;
        if chars.peek() == Some(&'-') {
            let mut ahead = chars.clone();
            ahead.next();
            if ahead.peek().map_or(false, |c| !c.is_whitespace()) {
                negate = true;
                chars.next();
            }
        }
        let mut raw = String::new();
        let mut field = None;
        let mut exact = false;
        let mut quoted = false;
        while let Some(&c) = chars.peek() {
            if c == '"' {
                quoted = !quoted;
                chars.next();
                continue;
            }
            if c.is_whitespace() && !quoted {
                break;
            }
            if c == ':' && !quoted && field.is_none() {
                if let Some(f) = field_alias(&raw) {
                    field = Some(f);
                    raw.clear();
                    chars.next();
                    if chars.peek() == Some(&'=') {
                        exact = true;
                        chars.next();
                    }
                    continue;
                }
            }
            raw.push(c);
            chars.next();
        }
        if !raw.is_empty() {
            terms.push(Term { negate, field, exact, text: raw });
        }
    }
    terms
}

/// The SQL for `rating:…`: `4` exactly, `>=3` or `3+` at least, `<3`,
/// `2..4` from and to, `none` (or `0`) for unrated, `any` for rated, and
/// any of those joined by `|`.
fn rating_sql(text: &str) -> String {
    const R: &str = "coalesce(n.rating, 0)";
    let one = |part: &str| -> Option<String> {
        let part = part.trim().to_ascii_lowercase();
        let num = |s: &str| s.trim().parse::<u8>().ok().filter(|n| *n <= crate::notes::MAX_RATING);
        Some(match part.as_str() {
            "none" | "unrated" | "no" => format!("{R} = 0"),
            "any" | "rated" | "yes" => format!("{R} > 0"),
            p if p.starts_with(">=") => format!("{R} >= {}", num(&p[2..])?),
            p if p.starts_with("<=") => format!("{R} <= {}", num(&p[2..])?),
            p if p.starts_with('>') => format!("{R} > {}", num(&p[1..])?),
            p if p.starts_with('<') => format!("{R} < {}", num(&p[1..])?),
            p if p.ends_with('+') => format!("{R} >= {}", num(&p[..p.len() - 1])?),
            p if p.contains("..") => {
                let (a, b) = p.split_once("..")?;
                format!("{R} BETWEEN {} AND {}", num(a)?, num(b)?)
            }
            p => format!("{R} = {}", num(p)?),
        })
    };
    let parts: Vec<String> = text.split('|').filter_map(one).collect();
    if parts.is_empty() {
        "0".to_string()
    } else {
        format!("({})", parts.join(" OR "))
    }
}

/// Text as `prompt:=…` compares it: lower-cased, without double quotes
/// (which a search cannot hold), and with runs of spacing as one space.
fn same_text(text: &str) -> String {
    text.to_lowercase().replace('"', "").split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Whether `lines` (names one to a line) holds `needle`, already
/// lower-cased: as a whole name, or inside one.
fn lines_match(lines: &str, needle: &str, exact: bool) -> bool {
    lines.split('\n').filter(|l| !l.is_empty()).any(|line| {
        let line = line.to_lowercase();
        if exact {
            line == needle
        } else {
            line.contains(needle)
        }
    })
}

/// Whether a word of `is:…` asks for near-duplicates.
fn is_duplicate_word(text: &str) -> bool {
    matches!(text.trim().to_ascii_lowercase().as_str(), "duplicate" | "duplicates" | "dupe" | "dupes" | "near-duplicate" | "near-duplicates")
}

/// Whether a search asks for only the pictures that have a near-duplicate
/// (`is:duplicate`), which [`crate::dupes`] answers, not SQL.
pub fn wants_duplicates(text: &str) -> bool {
    parse_terms(text).iter().any(|t| t.field == Some("kind") && !t.negate && is_duplicate_word(&t.text))
}

/// What a search's `taste:` term asks for: the pictures the user has not
/// judged yet that their taste suggests keeping (`taste:keep`) or
/// rejecting (`taste:reject`). None for a search with no such term, or one
/// that asks for neither.
pub fn taste_term(text: &str) -> Option<crate::taste::Verdict> {
    parse_terms(text).into_iter().filter(|t| t.field == Some("taste") && !t.negate).find_map(|t| {
        match t.text.trim().to_ascii_lowercase().as_str() {
            "keep" | "keeper" | "keepers" | "like" | "liked" | "good" => Some(crate::taste::Verdict::Keep),
            "reject" | "rejects" | "dislike" | "disliked" | "bad" => Some(crate::taste::Verdict::Reject),
            _ => None,
        }
    })
}

/// The picture a search's `similar:` term names, if it has one.
pub fn similar_target(text: &str) -> Option<String> {
    parse_terms(text).into_iter().find(|t| t.field == Some("similar") && !t.negate).map(|t| t.text)
}

/// The columns [`find_score`] reads, as the arguments of `gv_find`.
const FIND_ALL: &str = "t.lname, t.prompt, t.negative, t.model, t.loras, t.extra";

impl Term {
    /// What a search of prompt text looks for: the words, lower-cased, and
    /// which of their ends may fall inside a longer word. A `*` typed at
    /// either end opens that end and is not part of the words.
    fn words(&self) -> (String, Ends) {
        let text = self.text.to_lowercase();
        let inner = text.trim_matches('*');
        if inner.is_empty() {
            // Nothing but stars: they are what is being looked for.
            return (text, Ends::default());
        }
        let ends = Ends { open_start: text.starts_with('*'), open_end: text.ends_with('*') };
        (inner.to_string(), ends)
    }

    /// The values an exact term accepts: `model:="a|b"` is either.
    /// Prompts are taken whole, `|` and all, since prompt syntax uses it.
    fn alternatives(&self) -> Vec<&str> {
        if !self.exact || matches!(self.field, Some("prompt" | "negative" | "fullprompt" | "fullneg")) {
            return vec![self.text.as_str()];
        }
        let parts: Vec<&str> = self.text.split('|').map(str::trim).filter(|p| !p.is_empty()).collect();
        if parts.is_empty() {
            vec![self.text.as_str()]
        } else {
            parts
        }
    }

    /// Whether this term's predicate reads the `ftext` table.
    fn reads_text(&self) -> bool {
        !matches!(self.field, Some("seed" | "source" | "date" | "rating" | "flag" | "collection" | "similar" | "taste" | "kind"))
    }

    /// Append this term's predicate.
    fn to_sql(&self, cond: &mut String, args: &mut Vec<String>) {
        let not = if self.negate { "NOT " } else { "" };
        let mut bind = |value: String| {
            args.push(value);
            args.len()
        };
        // Either of several predicates, one per alternative.
        let any = |parts: Vec<String>| if parts.len() == 1 { parts.into_iter().next().unwrap_or_default() } else { format!("({})", parts.join(" OR ")) };
        let pred = match (self.field, self.exact) {
            (Some("similar"), _) => return,
            // Answered after the query, by the model of the user's taste.
            (Some("taste"), _) => return,
            // Answered after the query, by comparing what the pictures look like.
            (Some("kind"), _) if is_duplicate_word(&self.text) => return,
            (Some("seed"), true) => any(self.alternatives().into_iter().map(|v| format!("f.seed = ?{}", bind(v.to_string()))).collect()),
            (Some("seed"), false) => {
                // Seeds are matched from the start: seed:123 finds 1234567.
                let n = bind(self.text.clone());
                format!("substr(f.seed, 1, length(?{n})) = ?{n}")
            }
            (Some("source"), _) => any(self.alternatives().into_iter().map(|v| format!("f.source = ?{}", bind(v.to_lowercase()))).collect()),
            (Some("date"), _) => {
                // Numbers we worked out ourselves, so they go in as they are.
                match dates::parse_range(&self.text) {
                    Some((from, to)) => format!("(f.mtime >= {from} AND f.mtime < {to})"),
                    None => "0".to_string(),
                }
            }
            (Some("rating"), _) => rating_sql(&self.text),
            (Some("kind"), _) => {
                // type:image, type:video; either, as type:image|video.
                let kinds: Vec<String> = self
                    .text
                    .split('|')
                    .filter_map(|k| match k.trim().to_ascii_lowercase().as_str() {
                        "image" | "images" | "picture" | "pictures" | "photo" | "still" => Some("f.kind = 0".to_string()),
                        "video" | "videos" | "movie" | "clip" => Some("f.kind = 1".to_string()),
                        _ => None,
                    })
                    .collect();
                if kinds.is_empty() {
                    "0".to_string()
                } else {
                    any(kinds)
                }
            }
            (Some("flag"), _) => {
                let flags: Vec<String> = self
                    .text
                    .split('|')
                    .filter_map(Flag::parse)
                    .map(|flag| format!("coalesce(n.flag, 0) = {}", flag as u8))
                    .collect();
                if flags.is_empty() {
                    "0".to_string()
                } else {
                    any(flags)
                }
            }
            (Some("collection"), exact) => {
                let parts = if exact { self.alternatives() } else { vec![self.text.as_str()] };
                any(parts.into_iter().map(|v| format!("gv_lines(coalesce(n.collections, ''), ?{}, {})", bind(v.to_lowercase()), exact as u8)).collect())
            }
            (Some("lname"), true) => any(self.alternatives().into_iter().map(|v| format!("t.lname = ?{}", bind(v.to_lowercase()))).collect()),
            (Some(field @ ("fullprompt" | "fullneg")), _) => {
                // The whole prompt, give or take spacing and quotes.
                let col = if field == "fullprompt" { "prompt" } else { "negative" };
                format!("gv_same(t.{col}, ?{})", bind(same_text(&self.text)))
            }
            (Some(col @ ("prompt" | "negative")), _) => {
                // As whole words: prompt:fox leaves foxglove out.
                let (words, ends) = self.words();
                let n = bind(words);
                format!("gv_word(t.{col}, ?{n}, {})", ends.flags())
            }
            (Some(field @ ("model" | "loras")), true) => {
                let kind = if field == "model" { "model" } else { "lora" };
                any(self.alternatives().into_iter().map(|v| format!("gv_facet(t.facets, '{kind}', ?{}, 1)", bind(facet_value(kind, v).to_lowercase()))).collect())
            }
            (Some(kind @ ("sampler" | "scheduler" | "size")), exact) => {
                let parts = if exact { self.alternatives() } else { vec![self.text.as_str()] };
                any(parts.into_iter().map(|v| format!("gv_facet(t.facets, '{kind}', ?{}, {})", bind(facet_value(kind, v).to_lowercase()), exact as u8)).collect())
            }
            // Numbers have no "part of": steps:30 is not steps 130.
            (Some(kind @ ("steps" | "cfg")), _) => {
                let parts: Vec<&str> = self.text.split('|').map(str::trim).filter(|p| !p.is_empty()).collect();
                any(parts.into_iter().map(|v| format!("gv_facet(t.facets, '{kind}', ?{}, 1)", bind(facet_value(kind, v).to_lowercase()))).collect())
            }
            (None, _) => {
                // Anywhere, as words. `blob` is everything in one string, so
                // the images that cannot match cost one scan of it.
                let (words, ends) = self.words();
                let n = bind(words);
                format!("(instr(t.blob, ?{n}) > 0 AND gv_find({FIND_ALL}, ?{n}, {}) > 0)", ends.flags())
            }
            // A named field holding names (file, model, LoRA): any part.
            (Some(col), _) => {
                let n = bind(self.text.to_lowercase());
                format!("(instr(t.{col}, ?{n}) > 0)")
            }
        };
        cond.push_str(&format!(" AND {not}({pred})"));
    }

    /// An SQL expression for how well an image matches this term, for the
    /// terms that can match better or worse: words looked for anywhere or in
    /// the prompt. Everything else is a yes or a no.
    fn rank(&self, args: &mut Vec<String>) -> Option<String> {
        if self.negate {
            return None;
        }
        let columns = match self.field {
            None => FIND_ALL,
            Some("prompt") => "'', t.prompt, '', '', '', ''",
            _ => return None,
        };
        let (words, ends) = self.words();
        args.push(words);
        Some(format!("gv_find({columns}, ?{}, {})", args.len(), ends.flags()))
    }
}

/// An SQL expression that is larger the better an image matches `terms`, or
/// None if nothing in them can be matched better or worse.
fn rank_sql(terms: &[Term], args: &mut Vec<String>) -> Option<String> {
    let mut parts: Vec<String> = terms.iter().filter_map(|term| term.rank(args)).collect();
    if parts.is_empty() {
        return None;
    }
    // Words typed side by side that stand side by side in the prompt too.
    let plain: Vec<&Term> = terms.iter().filter(|t| !t.negate && t.field.is_none() && !t.text.contains('*')).collect();
    if plain.len() > 1 {
        args.push(plain.iter().map(|t| t.text.to_lowercase()).collect::<Vec<_>>().join(" "));
        parts.push(format!("{SCORE_TOGETHER} * gv_word(t.prompt, ?{}, 0)", args.len()));
    }
    Some(format!("({})", parts.join(" + ")))
}

/// Whether an image's facets (see `GenInfo::facets_text`) hold `needle`,
/// already lower-cased, under `kind`: as a whole value, or anywhere inside
/// one. `model` covers the main model and every supporting one.
fn facet_matches(facets: &str, kind: &str, needle: &str, exact: bool) -> bool {
    facets.split('\n').any(|line| {
        let mut parts = line.split('\t');
        let (Some(k), Some(value)) = (parts.next(), parts.next()) else { return false };
        (k == kind || (kind == "model" && k == "aux")) && if exact { value == needle } else { value.contains(needle) }
    })
}

/// Whether `c` is part of a word. Scripts written without spaces between
/// words (Chinese, Japanese, Korean) have no word edges to speak of, so
/// their characters each count as a word of their own.
fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() && (c as u32) < 0x2E80
}

/// Where `needle` occurs in `text` as whole words rather than inside longer
/// ones: the byte offset of the first such place, and how many there are.
/// An open end (see [`Ends`]) may fall inside a word.
fn find_words(text: &str, needle: &str, ends: Ends) -> Option<(usize, usize)> {
    // An end that is punctuation is its own edge: "(fox" needs no space
    // before the bracket.
    if needle.is_empty() {
        return None;
    }
    let guard_start = !ends.open_start && needle.chars().next().map_or(false, is_word_char);
    let guard_end = !ends.open_end && needle.chars().next_back().map_or(false, is_word_char);
    let mut found: Option<(usize, usize)> = None;
    let mut from = 0;
    while from < text.len() {
        let Some(at) = text[from..].find(needle) else { break };
        let start = from + at;
        let end = start + needle.len();
        let before = guard_start && text[..start].chars().next_back().map_or(false, is_word_char);
        let after = guard_end && text[end..].chars().next().map_or(false, is_word_char);
        if before || after {
            from = start + text[start..].chars().next().map_or(1, char::len_utf8);
            continue;
        }
        found = Some(found.map_or((start, 1), |(first, count)| (first, count + 1)));
        from = end.max(start + 1);
    }
    found
}

// How well an image matches a word, by where the word was found. A prompt
// is about what it mentions first and mentions often; a word that is only
// in a name says less; one only in the negative prompt is what the picture
// was told *not* to be.
const SCORE_PROMPT: f64 = 100.0;
/// On top of that: this much for a word at the very start of the prompt,
/// falling to nothing at its end...
const SCORE_EARLY: f64 = 40.0;
/// ...and this much for each further mention, up to three.
const SCORE_AGAIN: f64 = 10.0;
/// And this much when the words searched for stand together in the prompt.
const SCORE_TOGETHER: f64 = 60.0;
const SCORE_NAME: f64 = 40.0;
const SCORE_SETTING: f64 = 20.0;
const SCORE_NEGATIVE: f64 = 10.0;

/// The parts of an image's search text that [`find_score`] looks through.
struct Searched<'a> {
    name: &'a str,
    prompt: &'a str,
    negative: &'a str,
    model: &'a str,
    loras: &'a str,
    extra: &'a str,
}

/// How well an image matches `needle` (already lower-cased): 0 if it does
/// not, otherwise one of the scores above.
///
/// Prompts are searched for whole words. Names (the file, models, LoRAs) and
/// settings are not made of words in the same way, so there the search only
/// has to begin at the start of one: `flux` finds `flux1-dev`, though not
/// `reflux`.
fn find_score(s: &Searched, needle: &str, ends: Ends) -> f64 {
    if let Some((first, count)) = find_words(s.prompt, needle, ends) {
        let early = 1.0 - first as f64 / s.prompt.len().max(1) as f64;
        return SCORE_PROMPT + SCORE_EARLY * early + SCORE_AGAIN * (count - 1).min(3) as f64;
    }
    let from_start = Ends { open_end: true, ..ends };
    if [s.name, s.model, s.loras].iter().any(|text| find_words(text, needle, from_start).is_some()) {
        return SCORE_NAME;
    }
    if find_words(s.extra, needle, from_start).is_some() {
        return SCORE_SETTING;
    }
    if find_words(s.negative, needle, ends).is_some() {
        return SCORE_NEGATIVE;
    }
    0.0
}

/// The SQL functions the predicates above call.
fn register_functions(conn: &Connection) -> DbResult<()> {
    let flags = FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC;
    conn.create_scalar_function("gv_facet", 4, flags, |ctx| {
        let facets = ctx.get_raw(0).as_str().unwrap_or("");
        let kind = ctx.get_raw(1).as_str().unwrap_or("");
        let needle = ctx.get_raw(2).as_str().unwrap_or("");
        let exact = ctx.get_raw(3).as_i64().unwrap_or(0) != 0;
        Ok(facet_matches(facets, kind, needle, exact))
    })?;
    conn.create_scalar_function("gv_same", 2, flags, |ctx| {
        let text = ctx.get_raw(0).as_str().unwrap_or("");
        let needle = ctx.get_raw(1).as_str().unwrap_or("");
        Ok(!needle.is_empty() && same_text(text) == needle)
    })?;
    conn.create_scalar_function("gv_lines", 3, flags, |ctx| {
        let lines = ctx.get_raw(0).as_str().unwrap_or("");
        let needle = ctx.get_raw(1).as_str().unwrap_or("");
        Ok(lines_match(lines, needle, ctx.get_raw(2).as_i64().unwrap_or(0) != 0))
    })?;
    conn.create_scalar_function("gv_word", 3, flags, |ctx| {
        let text = ctx.get_raw(0).as_str().unwrap_or("");
        let needle = ctx.get_raw(1).as_str().unwrap_or("");
        let ends = Ends::from_flags(ctx.get_raw(2).as_i64().unwrap_or(0));
        Ok(find_words(text, needle, ends).is_some())
    })?;
    conn.create_scalar_function("gv_find", 8, flags, |ctx| {
        let text = |i: usize| ctx.get_raw(i).as_str().unwrap_or("");
        let searched = Searched { name: text(0), prompt: text(1), negative: text(2), model: text(3), loras: text(4), extra: text(5) };
        Ok(find_score(&searched, text(6), Ends::from_flags(ctx.get_raw(7).as_i64().unwrap_or(0))))
    })
}

// ---------------------------------------------------------------- usage

/// The facet kinds that are counted, in the order they are reported.
const USAGE_KINDS: [&str; 9] = ["model", "lora", "aux", "sampler", "scheduler", "steps", "cfg", "size", "source"];
/// How many values of a kind are reported, most used first.
const USAGE_TOP: usize = 100;
const USAGE_WORDS: usize = 60;
const USAGE_PROMPTS: usize = 50;
/// How finely each value's use is spread over the folder's time span.
pub const TREND_SLOTS: usize = 24;

#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct Sample {
    pub path: String,
    pub mtime: i64,
    pub size: i64,
    pub rating: u8,
}

#[derive(Debug, Default, serde::Serialize)]
pub struct UsageItem {
    /// As written in the images (the first spelling met).
    pub value: String,
    /// How many images use it.
    pub count: u32,
    /// For supporting models, what they were used as: vae, clip, controlnet...
    #[serde(skip_serializing_if = "String::is_empty")]
    pub role: String,
    /// The count again, spread over the folder's time span, oldest first.
    pub trend: Vec<u32>,
    /// How many of its images are rated, and their stars added up.
    #[serde(skip_serializing_if = "is_zero")]
    pub rated: u32,
    #[serde(skip_serializing_if = "is_zero")]
    pub stars: u32,
    /// How many of its images are flagged keep, and reject.
    #[serde(skip_serializing_if = "is_zero")]
    pub keeps: u32,
    #[serde(skip_serializing_if = "is_zero")]
    pub rejects: u32,
    /// Its best rated images, newest first among equals (models and LoRAs).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub samples: Vec<Sample>,
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

#[derive(Debug, Default, serde::Serialize)]
pub struct UsageGroup {
    /// model | lora | aux | sampler | scheduler | steps | cfg | size | source
    /// | word | prompt | rating | flag | collection
    pub kind: &'static str,
    /// How many different values there are; `items` holds the most used.
    pub distinct: usize,
    pub items: Vec<UsageItem>,
}

#[derive(Debug, Default, serde::Serialize)]
pub struct TimeBucket {
    /// The day or month it starts on: 2026-10-09, 2026-10, 2026.
    pub label: String,
    /// The search that shows this bucket's images.
    pub query: String,
    pub count: u32,
}

/// What a folder's images were made with, and when.
#[derive(Debug, Default, serde::Serialize)]
pub struct Usage {
    pub total: u32,
    /// Files that carry generation data.
    pub generated: u32,
    pub groups: Vec<UsageGroup>,
    /// day | week | month | year
    pub unit: &'static str,
    pub timeline: Vec<TimeBucket>,
}

/// How many sample images a model or LoRA keeps.
const SAMPLES: usize = 3;

/// One image, as a tally sees it.
struct Seen<'a> {
    slot: usize,
    rating: u8,
    flag: Flag,
    sample: Option<&'a dyn Fn() -> Sample>,
}

struct Tally {
    value: String,
    role: String,
    count: u32,
    trend: [u32; TREND_SLOTS],
    rated: u32,
    stars: u32,
    keeps: u32,
    rejects: u32,
    samples: Vec<Sample>,
}

fn tally(map: &mut HashMap<String, Tally>, key: &str, value: &str, role: &str, seen: &Seen) {
    let t = map.entry(key.to_string()).or_insert_with(|| Tally {
        value: value.to_string(),
        role: role.to_string(),
        count: 0,
        trend: [0; TREND_SLOTS],
        rated: 0,
        stars: 0,
        keeps: 0,
        rejects: 0,
        samples: Vec::new(),
    });
    t.count += 1;
    t.trend[seen.slot] += 1;
    if seen.rating > 0 {
        t.rated += 1;
        t.stars += seen.rating as u32;
    }
    match seen.flag {
        Flag::Keep => t.keeps += 1,
        Flag::Reject => t.rejects += 1,
        Flag::None => {}
    }
    // Keep the best few: higher rated, then newer (rows come newest first).
    if let Some(make) = seen.sample {
        if seen.flag != Flag::Reject && (t.samples.len() < SAMPLES || t.samples.iter().any(|s| s.rating < seen.rating)) {
            t.samples.push(make());
            t.samples.sort_by(|a, b| b.rating.cmp(&a.rating).then(b.mtime.cmp(&a.mtime)));
            t.samples.truncate(SAMPLES);
        }
    }
}

fn ranked(kind: &'static str, map: HashMap<String, Tally>, top: usize) -> UsageGroup {
    let distinct = map.len();
    let mut all: Vec<Tally> = map.into_values().collect();
    all.sort_by(|a, b| b.count.cmp(&a.count).then_with(|| a.value.cmp(&b.value)));
    all.truncate(top);
    let items = all
        .into_iter()
        .map(|t| UsageItem {
            value: t.value,
            count: t.count,
            role: t.role,
            trend: t.trend.to_vec(),
            rated: t.rated,
            stars: t.stars,
            keeps: t.keeps,
            rejects: t.rejects,
            samples: t.samples,
        })
        .collect();
    UsageGroup { kind, distinct, items }
}

/// Words that say nothing about what a picture shows.
fn is_filler(word: &str) -> bool {
    matches!(
        word,
        "the" | "and" | "with" | "for" | "from" | "that" | "this" | "these" | "those" | "its" | "his" | "her" | "their" | "they"
            | "she" | "him" | "who" | "whose" | "which" | "what" | "when" | "where" | "while" | "into" | "onto" | "over" | "under"
            | "above" | "below" | "behind" | "between" | "through" | "across" | "around" | "against" | "along" | "near" | "off"
            | "out" | "are" | "was" | "were" | "been" | "being" | "has" | "have" | "had" | "but" | "not" | "nor" | "than" | "then"
            | "there" | "here" | "also" | "very" | "some" | "any" | "all" | "each" | "one" | "two" | "can" | "will" | "about"
            | "like" | "such" | "other" | "both" | "more" | "most" | "you" | "your" | "our" | "lora" | "break"
    )
}

/// Where a `<lora:name:0.8>`-style tag that opens at `rest` ends, if it is one.
fn tag_len(rest: &str) -> Option<usize> {
    let colon = rest.find(':')?;
    if colon < 2 || colon > 16 || !rest[1..colon].chars().all(|c| c.is_ascii_alphabetic()) {
        return None;
    }
    rest.find('>').map(|end| end + 1)
}

/// The distinct words of a (lower-cased) prompt worth counting: three
/// letters or more, not numbers, not filler, not embedded LoRA tags.
fn prompt_words(prompt: &str) -> Vec<&str> {
    let mut words: Vec<&str> = Vec::new();
    let mut start: Option<usize> = None;
    let mut i = 0;
    while i < prompt.len() {
        let c = prompt[i..].chars().next().unwrap_or(' ');
        let skip = if c == '<' { tag_len(&prompt[i..]) } else { None };
        if is_word_char(c) && skip.is_none() {
            start.get_or_insert(i);
            i += c.len_utf8();
            continue;
        }
        if let Some(s) = start.take() {
            words.push(&prompt[s..i]);
        }
        i += skip.unwrap_or(c.len_utf8());
    }
    if let Some(s) = start {
        words.push(&prompt[s..]);
    }
    words.retain(|w| w.chars().count() >= 3 && w.chars().any(char::is_alphabetic) && !is_filler(w));
    words.sort_unstable();
    words.dedup();
    words
}

fn timeline(days: &BTreeMap<dates::Day, u32>) -> (&'static str, Vec<TimeBucket>) {
    let (Some((&first, _)), Some((&last, _))) = (days.first_key_value(), days.last_key_value()) else {
        return ("day", Vec::new());
    };
    let within = |from: dates::Day, to: dates::Day| days.range(from..to).map(|(_, n)| n).sum::<u32>();
    let mut out = Vec::new();
    let span = last - first + 1;
    if span <= 45 {
        for day in first..=last {
            let label = dates::format_day(day);
            out.push(TimeBucket { query: format!("date:{label}"), label, count: within(day, day + 1) });
        }
        return ("day", out);
    }
    if span <= 400 {
        let mut monday = first - dates::weekday(first) as dates::Day;
        while monday <= last {
            let label = dates::format_day(monday);
            let query = format!("date:{label}..{}", dates::format_day(monday + 6));
            out.push(TimeBucket { label, query, count: within(monday, monday + 7) });
            monday += 7;
        }
        return ("week", out);
    }
    let (mut year, mut month, _) = dates::civil_from_days(first);
    let (last_year, last_month, _) = dates::civil_from_days(last);
    if span <= 1900 {
        while (year, month) <= (last_year, last_month) {
            let from = dates::days_from_civil(year, month, 1);
            let label = format!("{year:04}-{month:02}");
            let count = within(from, from + dates::days_in_month(year, month) as dates::Day);
            out.push(TimeBucket { query: format!("date:{label}"), label, count });
            (year, month) = if month == 12 { (year + 1, 1) } else { (year, month + 1) };
        }
        return ("month", out);
    }
    while year <= last_year {
        let label = format!("{year:04}");
        let count = within(dates::days_from_civil(year, 1, 1), dates::days_from_civil(year + 1, 1, 1));
        out.push(TimeBucket { query: format!("date:{label}"), label, count });
        year += 1;
    }
    ("year", out)
}

impl Db {
    /// Count what the images under `dir` that match `text` were made with,
    /// and what has been said about them. One pass over the same rows a
    /// search reads; ten thousand images take a few milliseconds.
    pub fn usage(&self, dir: &str, recursive: bool, text: &str) -> DbResult<Usage> {
        let terms = parse_terms(text);
        let (cond, args) = filter_sql(dir, recursive, &terms);
        let conn = self.read.lock();
        let from = "FROM files f JOIN ftext t ON t.id = f.id LEFT JOIN notes n ON n.dir = f.dir AND n.name = f.name";
        let (first, last): (Option<i64>, Option<i64>) = conn.query_row(
            &format!("SELECT min(f.mtime), max(f.mtime) {from} WHERE {cond}"),
            params_from_iter(args.iter()),
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        let mut usage = Usage { unit: "day", ..Default::default() };
        let (Some(first), Some(last)) = (first, last) else { return Ok(usage) };
        let span = (last - first).max(0) as i128 + 1;
        let slot = |mtime: i64| (((mtime - first).max(0) as i128 * TREND_SLOTS as i128) / span) as usize;

        let mut kinds: Vec<HashMap<String, Tally>> = USAGE_KINDS.iter().map(|_| HashMap::new()).collect();
        let mut words: HashMap<String, Tally> = HashMap::new();
        let mut prompts: HashMap<String, Tally> = HashMap::new();
        let mut ratings: HashMap<String, Tally> = HashMap::new();
        let mut flags: HashMap<String, Tally> = HashMap::new();
        let mut collections: HashMap<String, Tally> = HashMap::new();
        let mut days: BTreeMap<dates::Day, u32> = BTreeMap::new();

        let sql = format!(
            "SELECT f.mtime, f.source, t.facets, t.prompt, f.dir, f.name, f.size,
                    coalesce(n.rating, 0), coalesce(n.flag, 0), coalesce(n.collections, '')
             {from} WHERE {cond} ORDER BY f.mtime DESC"
        );
        let mut stmt = conn.prepare_cached(&sql)?;
        let mut rows = stmt.query(params_from_iter(args.iter()))?;
        while let Some(r) = rows.next()? {
            let mtime: i64 = r.get(0)?;
            let at = slot(mtime).min(TREND_SLOTS - 1);
            let rating = r.get::<_, i64>(7)?.clamp(0, 5) as u8;
            let flag = Flag::from_i64(r.get(8)?);
            let (dir, name, size) = (r.get_ref(4)?.as_str()?, r.get_ref(5)?.as_str()?, r.get::<_, i64>(6)?);
            let make = || Sample { path: join_path(dir, name), mtime, size, rating };
            let plain = Seen { slot: at, rating, flag, sample: None };
            let with_sample = Seen { slot: at, rating, flag, sample: Some(&make) };
            usage.total += 1;
            if !r.get_ref(1)?.as_str()?.is_empty() {
                usage.generated += 1;
            }
            *days.entry(dates::local_day(mtime)).or_insert(0) += 1;
            for line in r.get_ref(2)?.as_str()?.split('\n') {
                let mut parts = line.split('\t');
                let (Some(kind), Some(key), Some(value)) = (parts.next(), parts.next(), parts.next()) else { continue };
                let Some(k) = USAGE_KINDS.iter().position(|x| *x == kind) else { continue };
                let seen = if matches!(kind, "model" | "lora" | "aux") { &with_sample } else { &plain };
                tally(&mut kinds[k], key, value, parts.next().unwrap_or(""), seen);
            }
            let prompt = r.get_ref(3)?.as_str()?;
            for word in prompt_words(prompt) {
                tally(&mut words, word, word, "", &plain);
            }
            let whole = same_text(prompt);
            if !whole.is_empty() {
                tally(&mut prompts, &whole, &whole, "", &plain);
            }
            tally(&mut ratings, &rating.to_string(), &rating.to_string(), "", &plain);
            if flag != Flag::None {
                tally(&mut flags, flag.name(), flag.name(), "", &plain);
            }
            for name in r.get_ref(9)?.as_str()?.split('\n').filter(|n| !n.is_empty()) {
                tally(&mut collections, &name.to_lowercase(), name, "", &plain);
            }
        }

        usage.groups = USAGE_KINDS.iter().zip(kinds).map(|(kind, map)| ranked(kind, map, USAGE_TOP)).collect();
        usage.groups.push(ranked("word", words, USAGE_WORDS));
        usage.groups.push(ranked("prompt", prompts, USAGE_PROMPTS));
        let mut stars = ranked("rating", ratings, 6);
        // Five stars down to none, not most common first.
        stars.items.sort_by(|a, b| b.value.cmp(&a.value));
        usage.groups.push(stars);
        usage.groups.push(ranked("flag", flags, 2));
        usage.groups.push(ranked("collection", collections, USAGE_TOP));
        (usage.unit, usage.timeline) = timeline(&days);
        Ok(usage)
    }

    /// The words of the prompts under `dir` that turn up in at least `min`
    /// of them, most common first: the folder's own vocabulary, which a
    /// spelling check should not flag.
    pub fn vocabulary(&self, dir: &str, recursive: bool, min: u32, top: usize) -> DbResult<Vec<String>> {
        let (cond, args) = dir_condition(dir, recursive, "f.");
        let conn = self.read.lock();
        let mut stmt = conn.prepare_cached(&format!("SELECT t.prompt, t.negative FROM files f JOIN ftext t ON t.id = f.id WHERE {cond}"))?;
        let mut rows = stmt.query(params_from_iter(args.iter()))?;
        let mut counts: HashMap<String, u32> = HashMap::new();
        while let Some(r) = rows.next()? {
            for col in [0, 1] {
                let text = r.get_ref(col)?.as_str()?;
                let mut seen: Vec<&str> = text.split(|c: char| !is_word_char(c) && c != '\'').filter(|w| w.chars().count() >= 2).collect();
                seen.sort_unstable();
                seen.dedup();
                for w in seen {
                    *counts.entry(w.to_string()).or_insert(0) += 1;
                }
            }
        }
        let mut out: Vec<(String, u32)> = counts.into_iter().filter(|(_, n)| *n >= min).collect();
        out.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        out.truncate(top);
        Ok(out.into_iter().map(|(w, _)| w).collect())
    }
}

fn join_path(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(dir: &str, name: &str, mtime: i64, prompt: &str, model: &str, lora: &str) -> FileRecord {
        let mut info = GenInfo { source: "comfyui".into(), prompt: prompt.into(), seed: "12345".into(), ..Default::default() };
        info.add_model("checkpoint", model, "");
        info.model = model.into();
        info.add_lora(lora, Some(1.0), None);
        info.negative = "watermark".into();
        FileRecord { dir: dir.into(), name: name.into(), size: 10, mtime, video: false, info }
    }

    fn names(db: &Db, dir: &str, recursive: bool, text: &str) -> Vec<String> {
        let q = Query { dir: dir.into(), recursive, text: text.into(), sort: "name".into(), ..Default::default() };
        db.query(&q).unwrap().rows.into_iter().map(|r| r.2).collect()
    }

    #[test]
    fn images_or_videos() {
        let tmp = tempfile::tempdir().unwrap();
        let db = Db::open(tmp.path()).unwrap();
        let mut clip = rec("/out", "clip.mp4", 3, "a fox running", "wan", "motion");
        clip.video = true;
        db.upsert(&[rec("/out", "a.png", 1, "a fox", "flux", "fur"), rec("/out", "b.png", 2, "an owl", "flux", "fur"), clip]).unwrap();
        assert_eq!(names(&db, "/out", true, "type:image"), ["a.png", "b.png"]);
        assert_eq!(names(&db, "/out", true, "type:video"), ["clip.mp4"]);
        assert_eq!(names(&db, "/out", true, "type:image|video"), ["a.png", "b.png", "clip.mp4"]);
        assert_eq!(names(&db, "/out", true, "fox -type:video"), ["a.png"]);
        assert_eq!(names(&db, "/out", true, "type:nonsense"), Vec::<String>::new());
    }

    #[test]
    fn terms() {
        let t = parse_terms(r#"blue "red fox" -ugly model:flux -lora:"detail xl" a-b"#);
        assert_eq!(t.len(), 6);
        let term = |negate, field, exact, text: &str| Term { negate, field, exact, text: text.into() };
        assert_eq!(t[0], term(false, None, false, "blue"));
        assert_eq!(t[1], term(false, None, false, "red fox"));
        assert_eq!(t[2], term(true, None, false, "ugly"));
        assert_eq!(t[3], term(false, Some("model"), false, "flux"));
        assert_eq!(parse_terms("name:IMG")[0].field, Some("lname"));
        assert_eq!(t[4], term(true, Some("loras"), false, "detail xl"));
        assert_eq!(t[5], term(false, None, false, "a-b"));
        // A URL-ish token is not mistaken for a field.
        assert_eq!(parse_terms("http://x")[0].field, None);
        // `:=` asks for the whole value; on its own `=` is just a character.
        let t = parse_terms(r#"model:="flux dev" -lora:=detail seed:=12 a=b =c size:=1024x1024 date:2026-10"#);
        assert_eq!(t[0], term(false, Some("model"), true, "flux dev"));
        assert_eq!(t[1], term(true, Some("loras"), true, "detail"));
        assert_eq!(t[2], term(false, Some("seed"), true, "12"));
        assert_eq!(t[3], term(false, None, false, "a=b"));
        assert_eq!(t[4], term(false, None, false, "=c"));
        assert_eq!(t[5], term(false, Some("size"), true, "1024x1024"));
        assert_eq!(t[6], term(false, Some("date"), false, "2026-10"));
    }

    #[test]
    fn search_and_scope() {
        let tmp = tempfile::tempdir().unwrap();
        let db = Db::open(tmp.path()).unwrap();
        db.upsert(&[
            rec("/out", "a.png", 1, "a blonde fox girl in the snow", "flux1-dev.safetensors", "detail_xl"),
            rec("/out", "b.png", 2, "portrait of an old sailor, 50% grey", "sdxl_base.safetensors", "film_grain"),
            rec("/out/sub", "c.png", 3, "a red fox on a log", "flux1-dev.safetensors", ""),
            rec("/outside", "d.png", 4, "fox", "flux1-dev.safetensors", ""),
            rec("/out2", "e.png", 5, "fox", "flux1-dev.safetensors", ""),
        ])
        .unwrap();

        assert_eq!(names(&db, "/out", false, ""), ["a.png", "b.png"]);
        assert_eq!(names(&db, "/out", true, ""), ["a.png", "b.png", "c.png"]);
        assert_eq!(names(&db, "/out/", true, "fox"), ["a.png", "c.png"]);
        // whole words, case-insensitive; a star opens an end
        assert_eq!(names(&db, "/out", true, "BLONDE"), ["a.png"]);
        assert_eq!(names(&db, "/out", true, "lond"), Vec::<String>::new());
        assert_eq!(names(&db, "/out", true, "blon"), Vec::<String>::new());
        assert_eq!(names(&db, "/out", true, "blon*"), ["a.png"]);
        assert_eq!(names(&db, "/out", true, "*onde"), ["a.png"]);
        assert_eq!(names(&db, "/out", true, "*LOND*"), ["a.png"]);
        assert_eq!(names(&db, "/out", true, "fox -*lond*"), ["c.png"]);
        // names match from the start of a word
        assert_eq!(names(&db, "/out", true, "flux"), ["a.png", "c.png"]);
        assert_eq!(names(&db, "/out", true, "dev"), ["a.png", "c.png"]);
        assert_eq!(names(&db, "/out", true, "lux1"), Vec::<String>::new());
        assert_eq!(names(&db, "/out", true, "*lux1"), ["a.png", "c.png"]);
        assert_eq!(names(&db, "/out", true, "grain"), ["b.png"]);
        assert_eq!(names(&db, "/out", true, "b.p"), ["b.png"]);
        // AND of terms, phrase, exclusion
        assert_eq!(names(&db, "/out", true, "fox snow"), ["a.png"]);
        assert_eq!(names(&db, "/out", true, "\"red fox\""), ["c.png"]);
        assert_eq!(names(&db, "/out", true, "fox -snow"), ["c.png"]);
        assert_eq!(names(&db, "/out", true, "-fox"), ["b.png"]);
        // fields
        assert_eq!(names(&db, "/out", true, "model:sdxl"), ["b.png"]);
        assert_eq!(names(&db, "/out", true, "lora:grain"), ["b.png"]);
        assert_eq!(names(&db, "/out", true, "name:c.p"), ["c.png"]);
        assert_eq!(names(&db, "/out", true, "seed:123"), ["a.png", "b.png", "c.png"]);
        assert_eq!(names(&db, "/out", true, "neg:watermark fox"), ["a.png", "c.png"]);
        // any length works, and SQL wildcards are just characters
        assert_eq!(names(&db, "/out", true, "50%"), ["b.png"]);
        assert_eq!(names(&db, "/out", true, "an"), ["b.png"]);
        assert_eq!(names(&db, "/out", true, "%"), ["b.png"]);
        assert_eq!(names(&db, "/out", true, "_"), ["a.png", "b.png"]);
        assert_eq!(names(&db, "/out", true, "seed:2"), Vec::<String>::new());
        // everything
        assert_eq!(names(&db, "/", true, "").len(), 5);

        // update replaces the indexed text
        db.upsert(&[rec("/out", "a.png", 9, "a wolf", "flux1-dev.safetensors", "")]).unwrap();
        assert_eq!(names(&db, "/out", true, "blonde"), Vec::<String>::new());
        assert_eq!(names(&db, "/out", true, "wolf"), ["a.png"]);
        assert_eq!(db.count(), 5);

        // delete removes from the index too
        db.delete_path("/out", "a.png").unwrap();
        assert_eq!(names(&db, "/out", true, "wolf"), Vec::<String>::new());
        db.delete_tree("/out").unwrap();
        assert_eq!(names(&db, "/", true, "").len(), 2);
    }

    #[test]
    fn whole_words() {
        let words = |text: &str, needle: &str| find_words(text, needle, Ends::default());
        assert_eq!(words("a red fox, and a fox", "fox"), Some((6, 2)));
        assert_eq!(words("foxglove, firefox, outfoxed", "fox"), None);
        // Punctuation, underscores and line ends are all edges.
        for text in ["fox", "(fox:1.2)", "red_fox_girl", "a\nfox\n", "fox's den", "blue-fox", "<lora:fox:0.8>"] {
            assert!(words(text, "fox").is_some(), "{text}");
        }
        // Digits are part of a word: 4k is not k, 1girl is not girl.
        assert_eq!(words("4k, 1girl", "k"), None);
        assert_eq!(words("4k, 1girl", "girl"), None);
        assert_eq!(words("4k, 1girl", "4k"), Some((0, 1)));
        // Phrases keep their inside as typed and need edges outside.
        assert_eq!(words("a dark red fox", "red fox"), Some((7, 1)));
        assert_eq!(words("a dark red foxglove", "red fox"), None);
        // What is typed with punctuation at an end needs no edge there.
        assert_eq!(words("a(fox)b", "(fox)"), Some((1, 1)));
        assert_eq!(words("50% grey", "50%"), Some((0, 1)));
        assert_eq!(words("c++ and c", "c++"), Some((0, 1)));
        // Accents and other alphabets have edges too; Japanese does not.
        assert_eq!(words("un café noir", "caf"), None);
        assert_eq!(words("un café noir", "café"), Some((3, 1)));
        assert_eq!(words("лиса в снегу", "снег"), None);
        assert_eq!(words("東京タワーの夜", "タワー"), Some((6, 1)));
        assert_eq!(words("anything", ""), None);
        assert_eq!(words("aaaa", "aa"), None);
        assert_eq!(words("aa aa", "aa"), Some((0, 2)));

        let open = |start, end| Ends { open_start: start, open_end: end };
        assert_eq!(find_words("foxglove, firefox, outfoxed", "fox", open(false, true)), Some((0, 1)));
        assert_eq!(find_words("foxglove, firefox, outfoxed", "fox", open(true, false)), Some((14, 1)));
        assert_eq!(find_words("foxglove, firefox, outfoxed", "fox", open(true, true)), Some((0, 3)));
        assert_eq!(Ends::from_flags(open(true, false).flags() as i64), open(true, false));
        assert_eq!(Ends::from_flags(open(false, true).flags() as i64), open(false, true));

        let term = |text: &str| Term { negate: false, field: None, exact: false, text: text.into() }.words();
        assert_eq!(term("Fox"), ("fox".into(), open(false, false)));
        assert_eq!(term("fox*"), ("fox".into(), open(false, true)));
        assert_eq!(term("*Lond*"), ("lond".into(), open(true, true)));
        assert_eq!(term("**"), ("**".into(), open(false, false)));
    }

    #[test]
    fn best_match_first() {
        let tmp = tempfile::tempdir().unwrap();
        let db = Db::open(tmp.path()).unwrap();
        let mut negative = rec("/out", "negative.png", 9, "a plain portrait", "sdxl", "");
        negative.info.negative = "fox, watermark".into();
        db.upsert(&[
            rec("/out", "late.png", 1, "a long walk through an autumn forest at dusk, mist, and far away a fox", "sdxl", ""),
            rec("/out", "first.png", 2, "fox in the snow", "sdxl", ""),
            rec("/out", "twice.png", 3, "fox in the snow, a red fox", "sdxl", ""),
            rec("/out", "apart.png", 4, "red barn, a fox", "sdxl", ""),
            rec("/out", "lora.png", 5, "a heron", "sdxl", "fox_style_v2"),
            rec("/out", "fox_0007.png", 6, "a heron", "sdxl", ""),
            rec("/out", "none.png", 7, "a foxglove meadow", "sdxl", ""),
            negative,
        ])
        .unwrap();
        let best = |text: &str| {
            let q = Query { dir: "/out".into(), recursive: true, text: text.into(), sort: "relevance".into(), ..Default::default() };
            db.query(&q).unwrap().rows.into_iter().map(|r| r.2).collect::<Vec<_>>()
        };
        let best_then = |text: &str, then: &str| {
            let q = Query { dir: "/out".into(), recursive: true, text: text.into(), sort: "relevance".into(), then: then.into() };
            db.query(&q).unwrap().rows.into_iter().map(|r| r.2).collect::<Vec<_>>()
        };
        // In the prompt, earliest and most often; then in a name, newest
        // first; last, only in the negative prompt.
        assert_eq!(best("fox"), ["twice.png", "first.png", "apart.png", "late.png", "fox_0007.png", "lora.png", "negative.png"]);
        // Words typed together count for more where they stand together.
        assert_eq!(best("red fox"), ["twice.png", "apart.png"]);
        assert_eq!(best("fox red"), ["twice.png", "apart.png"]);
        assert_eq!(best("prompt:fox -snow"), ["apart.png", "late.png"]);
        // Equally good matches fall back on the order asked for...
        assert_eq!(best_then("fox", "oldest")[4..6], ["lora.png", "fox_0007.png"]);
        assert_eq!(best_then("fox", "oldest")[..4], best("fox")[..4]);
        // ...which is the whole order when there is nothing to rank.
        assert_eq!(best("model:sdxl -fox"), ["none.png"]);
        assert_eq!(best("")[0], "negative.png");
        assert_eq!(best_then("", "oldest")[0], "late.png");
        assert_eq!(best_then("model:sdxl", "name")[..2], ["apart.png", "first.png"]);
        assert_eq!(best("nothing"), Vec::<String>::new());
        // Any other order ignores how well things match.
        assert_eq!(names(&db, "/out", true, "fox")[0], "apart.png");
    }

    /// A record with everything spelled out, dated at noon on a local day.
    fn made(name: &str, date: (i32, u32, u32), fill: impl FnOnce(&mut GenInfo)) -> FileRecord {
        let mut info = GenInfo::default();
        fill(&mut info);
        let mtime = dates::local_midnight_ms(dates::days_from_civil(date.0, date.1, date.2)) + 12 * 3_600_000;
        FileRecord { dir: "/out".into(), name: name.into(), size: 10, mtime, video: false, info }
    }

    fn library() -> (tempfile::TempDir, Db) {
        let tmp = tempfile::tempdir().unwrap();
        let db = Db::open(tmp.path()).unwrap();
        db.upsert(&[
            made("a.png", (2026, 10, 1), |i| {
                i.source = "comfyui".into();
                i.prompt = "a red fox in the snow <lora:detail_xl:0.8>".into();
                i.seed = "22".into();
                i.model = "Flux1-Dev.safetensors".into();
                i.add_model("unet", "Flux1-Dev.safetensors", "");
                i.add_model("vae", "ae.safetensors", "");
                i.add_lora("detail_xl", Some(0.8), None);
                i.add_lora("style/Ink  Wash.safetensors", Some(1.0), None);
                i.param("Steps", "20");
                i.param("CFG", "7.0");
                i.param("Sampler", "euler");
                i.param("Scheduler", "simple");
                (i.width, i.height) = (1024, 1024);
            }),
            made("b.png", (2026, 10, 2), |i| {
                i.source = "a1111".into();
                i.prompt = "foxglove meadow at dawn".into();
                i.seed = "2201".into();
                i.model = "flux1-dev.safetensors".into();
                i.add_model("checkpoint", "flux1-dev.safetensors", "");
                i.add_lora("detail_xl", Some(0.3), None);
                i.param("Steps", "30");
                i.param("CFG scale", "7");
                i.param("Sampler", "DPM++ 2M Karras");
                (i.width, i.height) = (832, 1216);
            }),
            made("c.png", (2026, 10, 9), |i| {
                i.source = "comfyui".into();
                i.prompt = "a clockwork fox".into();
                i.seed = "22".into();
                i.model = "sd_xl_base_1.0".into();
                i.add_model("checkpoint", "sd_xl_base_1.0", "");
                i.add_model("vae", "ae.safetensors", "");
                i.add_lora("detail_xl_v2", None, None);
                i.param("Steps", "130");
                i.param("CFG", "6.5");
                (i.width, i.height) = (1024, 1024);
            }),
            made("d.png", (2026, 11, 3), |i| (i.width, i.height) = (640, 480)),
        ])
        .unwrap();
        (tmp, db)
    }

    #[test]
    fn exact_filters() {
        let (_tmp, db) = library();
        let find = |text: &str| names(&db, "/out", true, text);
        let none = Vec::<String>::new();

        // A seed in full, where plain seed: matches from the start.
        assert_eq!(find("seed:22"), ["a.png", "b.png", "c.png"]);
        assert_eq!(find("seed:=22"), ["a.png", "c.png"]);

        // A model by its whole name, however it is capitalised and whatever
        // it was used as.
        assert_eq!(find("model:flux1"), ["a.png", "b.png"]);
        assert_eq!(find("model:=flux1"), none);
        assert_eq!(find("model:=flux1-dev.safetensors"), ["a.png", "b.png"]);
        assert_eq!(find("model:=FLUX1-DEV.safetensors"), ["a.png", "b.png"]);
        assert_eq!(find("model:=ae.safetensors"), ["a.png", "c.png"]);

        // LoRAs: one, or all of several, at any strength.
        assert_eq!(find("lora:detail"), ["a.png", "b.png", "c.png"]);
        assert_eq!(find("lora:=detail_xl"), ["a.png", "b.png"]);
        assert_eq!(find(r#"lora:=detail_xl lora:="style/ink wash.safetensors""#), ["a.png"]);
        assert_eq!(find("-lora:=detail_xl"), ["c.png", "d.png"]);

        // Settings. Numbers compare as numbers and never match in part.
        assert_eq!(find("steps:30"), ["b.png"]);
        assert_eq!(find("steps:=30.0"), ["b.png"]);
        assert_eq!(find("cfg:7"), ["a.png", "b.png"]);
        assert_eq!(find("cfg:=6.5"), ["c.png"]);
        assert_eq!(find("sampler:dpm"), ["b.png"]);
        assert_eq!(find("sampler:=dpm"), none);
        assert_eq!(find(r#"sampler:="dpm++ 2m karras""#), ["b.png"]);
        assert_eq!(find("sampler:=euler scheduler:=simple"), ["a.png"]);
        assert_eq!(find("size:=1024x1024"), ["a.png", "c.png"]);
        assert_eq!(find("size:1024×1024"), ["a.png", "c.png"]);
        assert_eq!(find("size:x12"), ["b.png"]);

        // Whole words in a prompt; a whole file name.
        assert_eq!(find("prompt:fox"), ["a.png", "c.png"]);
        assert_eq!(find("prompt:=fox"), ["a.png", "c.png"]);
        assert_eq!(find("prompt:fox*"), ["a.png", "b.png", "c.png"]);
        assert_eq!(find("prompt:*glove"), ["b.png"]);
        assert_eq!(find("fox"), ["a.png", "c.png"]);
        assert_eq!(find(r#"prompt:="red fox""#), ["a.png"]);
        assert_eq!(find("name:=a.png"), ["a.png"]);
        assert_eq!(find("name:=a"), none);

        // Dates, in this machine's time zone.
        assert_eq!(find("date:2026-10-02"), ["b.png"]);
        assert_eq!(find("date:2026-10"), ["a.png", "b.png", "c.png"]);
        assert_eq!(find("date:2026").len(), 4);
        assert_eq!(find("date:2026-10-01..2026-10-02"), ["a.png", "b.png"]);
        assert_eq!(find("-date:2026-10"), ["d.png"]);
        assert_eq!(find("date:soon"), none);
        assert_eq!(find("date:2026-10 model:=sd_xl_base_1.0"), ["c.png"]);
    }

    #[test]
    fn usage_counts() {
        let (_tmp, db) = library();
        let usage = db.usage("/out", true, "").unwrap();
        assert_eq!((usage.total, usage.generated), (4, 3));

        let group = |kind: &str| usage.groups.iter().find(|g| g.kind == kind).unwrap_or_else(|| panic!("no {kind} group"));
        let counts = |kind: &str| group(kind).items.iter().map(|i| (i.value.to_lowercase(), i.count)).collect::<Vec<_>>();
        let pairs = |list: &[(&str, u32)]| list.iter().map(|(v, n)| (v.to_string(), *n)).collect::<Vec<_>>();

        // Most used first; spellings that differ only in case are one model.
        assert_eq!(counts("model"), pairs(&[("flux1-dev.safetensors", 2), ("sd_xl_base_1.0", 1)]));
        assert_eq!(counts("lora"), pairs(&[("detail_xl", 2), ("detail_xl_v2", 1), ("style/ink wash.safetensors", 1)]));
        assert_eq!(counts("aux"), pairs(&[("ae.safetensors", 2)]));
        assert_eq!(group("aux").items[0].role, "vae");
        assert_eq!(counts("sampler"), pairs(&[("dpm++ 2m karras", 1), ("euler", 1)]));
        assert_eq!(counts("steps"), pairs(&[("130", 1), ("20", 1), ("30", 1)]));
        assert_eq!(counts("cfg"), pairs(&[("7", 2), ("6.5", 1)]));
        assert_eq!(counts("size"), pairs(&[("1024x1024", 2), ("640x480", 1), ("832x1216", 1)]));
        assert_eq!(counts("source"), pairs(&[("comfyui", 2), ("a1111", 1)]));
        assert_eq!(group("lora").distinct, 3);
        // Values keep the way they were written.
        assert!(group("sampler").items.iter().any(|i| i.value == "DPM++ 2M Karras"));

        // Prompt words: no filler, no LoRA tags, no part-words.
        let words = counts("word");
        assert_eq!(words[0], ("fox".to_string(), 2));
        assert!(words.contains(&("foxglove".to_string(), 1)));
        assert!(!words.iter().any(|(w, _)| w == "the" || w == "lora" || w == "detail_xl"), "{words:?}");

        // Every count is spread over the time span, and adds up.
        for g in &usage.groups {
            for item in &g.items {
                assert_eq!(item.trend.len(), TREND_SLOTS);
                assert_eq!(item.trend.iter().sum::<u32>(), item.count, "{} {}", g.kind, item.value);
            }
        }
        let flux = &group("model").items[0];
        assert!(flux.trend[0] == 2 && flux.trend[1..].iter().all(|n| *n == 0), "{:?}", flux.trend);

        // The timeline: a bar a day here, and each bar's search finds its images.
        assert_eq!(usage.unit, "day");
        assert_eq!(usage.timeline.len(), 34);
        assert_eq!((usage.timeline[0].label.as_str(), usage.timeline[0].count), ("2026-10-01", 1));
        assert_eq!(usage.timeline[33].label, "2026-11-03");
        assert_eq!(usage.timeline.iter().map(|b| b.count).sum::<u32>(), 4);
        for bucket in &usage.timeline {
            assert_eq!(names(&db, "/out", true, &bucket.query).len() as u32, bucket.count, "{}", bucket.query);
        }

        // Counting a facet and filtering by it agree.
        for (kind, field) in [("model", "model"), ("lora", "lora"), ("steps", "steps"), ("cfg", "cfg"), ("size", "size"), ("word", "prompt"), ("prompt", "fullprompt")] {
            for item in &group(kind).items {
                let found = names(&db, "/out", true, &format!("{field}:=\"{}\"", item.value)).len() as u32;
                assert_eq!(found, item.count, "{field}:={}", item.value);
            }
        }

        // Scope follows the folder.
        assert_eq!(db.usage("/elsewhere", true, "").unwrap().total, 0);
        assert!(db.usage("/elsewhere", true, "").unwrap().timeline.is_empty());
    }

    #[test]
    fn timeline_units() {
        let day = dates::days_from_civil;
        let series = |list: &[(dates::Day, u32)]| timeline(&list.iter().copied().collect());

        // Up to six weeks: a bar a day, gaps included.
        let (unit, bars) = series(&[(day(2026, 10, 1), 2), (day(2026, 10, 4), 1)]);
        assert_eq!(unit, "day");
        assert_eq!(bars.iter().map(|b| (b.label.as_str(), b.count)).collect::<Vec<_>>(), [("2026-10-01", 2), ("2026-10-02", 0), ("2026-10-03", 0), ("2026-10-04", 1)]);

        // Up to a year or so: weeks, Monday to Sunday.
        let (unit, bars) = series(&[(day(2026, 7, 1), 1), (day(2026, 7, 5), 2), (day(2026, 7, 6), 4), (day(2026, 10, 11), 8)]);
        assert_eq!(unit, "week");
        assert_eq!((bars[0].label.as_str(), bars[0].query.as_str(), bars[0].count), ("2026-06-29", "date:2026-06-29..2026-07-05", 3));
        assert_eq!((bars[1].label.as_str(), bars[1].count), ("2026-07-06", 4));
        let last = bars.last().unwrap();
        assert_eq!((last.query.as_str(), last.count), ("date:2026-10-05..2026-10-11", 8));
        assert_eq!(bars.len(), 15);

        // Longer: months, then years.
        let (unit, bars) = series(&[(day(2024, 11, 30), 1), (day(2026, 2, 1), 5)]);
        assert_eq!(unit, "month");
        assert_eq!(bars.len(), 16);
        assert_eq!((bars[0].query.as_str(), bars[0].count), ("date:2024-11", 1));
        assert_eq!((bars[15].query.as_str(), bars[15].count), ("date:2026-02", 5));
        let (unit, bars) = series(&[(day(2019, 6, 1), 1), (day(2026, 2, 1), 5)]);
        assert_eq!(unit, "year");
        assert_eq!(bars.iter().map(|b| b.label.as_str()).collect::<Vec<_>>(), ["2019", "2020", "2021", "2022", "2023", "2024", "2025", "2026"]);
        assert_eq!(bars[7].query, "date:2026");

        assert!(series(&[]).1.is_empty());
    }

    #[test]
    fn words() {
        assert_eq!(
            prompt_words("a red fox, (masterpiece:1.2), <lora:detail_xl:0.8> 4k uhd, x < y, the fox and 2024"),
            ["fox", "masterpiece", "red", "uhd"]
        );
        assert_eq!(prompt_words("<lora:a:1>"), Vec::<&str>::new());
        // The same edges as a search, so a count and its filter agree.
        assert_eq!(prompt_words("größe ünïcode_word long_hair"), ["größe", "hair", "long", "word", "ünïcode"]);

        assert!(facet_matches("\nmodel\tflux\tFlux\t\naux\tae\tae\tvae\n", "model", "ae", true));
        assert!(facet_matches("\nlora\tdetail_xl\tdetail_xl\t\n", "lora", "detail", false));
        assert!(!facet_matches("\nlora\tdetail_xl\tdetail_xl\t\n", "lora", "detail", true));
        assert!(!facet_matches("\nlora\tdetail_xl\tdetail_xl\t\n", "model", "detail_xl", true));
        assert!(!facet_matches("", "model", "", true));
    }

    #[test]
    fn packed_layout() {
        let r = QueryResult {
            dirs: vec!["/a".into(), "/a/bé".into()],
            rows: vec![(7, 0, "x.png".into(), 0, 640, 480, 1_700_000_000_123, 99, 0), (-2, 1, "ü.mp4".into(), 1, 1920, 1080, 5, 1 << 33, 2500)],
            marks: vec![0, mark(4, 1)],
        };
        let b = r.pack();
        let u32_at = |o: usize| u32::from_le_bytes(b[o..o + 4].try_into().unwrap()) as usize;
        let i64_at = |o: usize| i64::from_le_bytes(b[o..o + 8].try_into().unwrap());
        assert_eq!(&b[0..4], b"GVQ1");
        assert_eq!((u32_at(4), u32_at(8)), (2, 2));
        let strings = 16 + 2 * 48 + 2 * 8;
        assert_eq!(b.len(), strings + u32_at(12));
        let row = 16 + 48; // second row
        assert_eq!((i64_at(row), i64_at(row + 8), i64_at(row + 16)), (-2, 5, 1 << 33));
        assert_eq!((u32_at(row + 24), u32_at(row + 28), u32_at(row + 32)), (1920, 1080, 2500));
        let (off, len) = (u32_at(row + 36), u16::from_le_bytes([b[row + 40], b[row + 41]]) as usize);
        assert_eq!(std::str::from_utf8(&b[strings + off..strings + off + len]).unwrap(), "ü.mp4");
        assert_eq!((b[row + 42], u32_at(row + 44)), (1, 1));
        assert_eq!((b[16 + 43], b[row + 43]), (0, 4 | 1 << 3));
        let d = 16 + 2 * 48 + 8; // second dir
        assert_eq!(std::str::from_utf8(&b[strings + u32_at(d)..strings + u32_at(d) + u32_at(d + 4)]).unwrap(), "/a/bé");
    }

    #[test]
    fn notes_prompts_and_alternatives() {
        let tmp = tempfile::tempdir().unwrap();
        let db = Db::open(tmp.path()).unwrap();
        db.upsert(&[
            rec("/out", "a.png", 1, "A red   fox, in the \"snow\"", "flux1-dev.safetensors", "detail_xl"),
            rec("/out", "b.png", 2, "a red fox, in the snow, at night", "sdxl_base.safetensors", "film_grain"),
            rec("/out", "c.png", 3, "a heron", "other.safetensors", ""),
            rec("/out/sub", "d.png", 4, "a heron", "flux1-dev.safetensors", ""),
        ])
        .unwrap();
        let note = |rating, flag, collections: &[&str]| Note { rating, flag, collections: collections.iter().map(|c| c.to_string()).collect() };
        db.replace_notes("/out", &[("a.png".into(), note(5, Flag::Keep, &["Night city", "Foxes"])), ("b.png".into(), note(3, Flag::None, &["foxes"])), ("c.png".into(), note(0, Flag::Reject, &[]))]).unwrap();
        db.replace_notes("/out/sub", &[("d.png".into(), note(4, Flag::None, &["Night City"]))]).unwrap();

        assert_eq!(names(&db, "/out", true, "rating:>=4"), ["a.png", "d.png"]);
        assert_eq!(names(&db, "/out", true, "rating:3+"), ["a.png", "b.png", "d.png"]);
        assert_eq!(names(&db, "/out", true, "rating:none"), ["c.png"]);
        assert_eq!(names(&db, "/out", true, "rating:3|5"), ["a.png", "b.png"]);
        assert_eq!(names(&db, "/out", true, "rating:2..4"), ["b.png", "d.png"]);
        assert_eq!(names(&db, "/out", true, "rating:ten"), Vec::<String>::new());
        assert_eq!(names(&db, "/out", true, "flag:keep"), ["a.png"]);
        assert_eq!(names(&db, "/out", true, "flag:none"), ["b.png", "d.png"]);
        assert_eq!(names(&db, "/out", true, "-flag:reject fox"), ["a.png", "b.png"]);
        assert_eq!(names(&db, "/out", true, r#"collection:="night city""#), ["a.png", "d.png"]);
        assert_eq!(names(&db, "/out", true, "collection:fox"), ["a.png", "b.png"]);
        assert_eq!(names(&db, "/out", true, r#"collection:="Night city|foxes""#), ["a.png", "b.png", "d.png"]);
        // The whole prompt, give or take case, spacing and quotes.
        assert_eq!(names(&db, "/out", true, r#"fullprompt:="a red fox, in the snow""#), ["a.png"]);
        assert_eq!(names(&db, "/out", true, r#"fullprompt:"A RED FOX, in the snow""#), ["a.png"]);
        assert_eq!(names(&db, "/out", true, "fullprompt:=fox"), Vec::<String>::new());
        assert_eq!(names(&db, "/out", true, r#"-fullprompt:="a heron""#), ["a.png", "b.png"]);
        // Either of several whole values.
        assert_eq!(names(&db, "/out", true, r#"model:="sdxl_base.safetensors|other.safetensors""#), ["b.png", "c.png"]);
        assert_eq!(names(&db, "/out", true, "lora:=detail_xl|film_grain"), ["a.png", "b.png"]);
        assert_eq!(names(&db, "/out", true, "seed:=1|12345"), ["a.png", "b.png", "c.png", "d.png"]);
        // Best rated first, kept before plain before rejected.
        let q = Query { dir: "/out".into(), recursive: true, sort: "rating".into(), ..Default::default() };
        let rated = db.query(&q).unwrap();
        assert_eq!(rated.rows.iter().map(|r| r.2.as_str()).collect::<Vec<_>>(), ["a.png", "d.png", "b.png", "c.png"]);
        assert_eq!(rated.marks, [mark(5, 1), mark(4, 0), mark(3, 0), mark(0, 2)]);
        // `similar:` is left to content search.
        assert_eq!(names(&db, "/out", false, r#"similar:"/out/a.png""#).len(), 3);
        assert_eq!(similar_target(r#"fox similar:"/out/a b.png""#).as_deref(), Some("/out/a b.png"));
        // `is:duplicate` is left to the near-duplicate finder, and asked for.
        assert_eq!(names(&db, "/out", false, "is:duplicate"), names(&db, "/out", false, ""));
        assert!(wants_duplicates("fox is:duplicates"));
        assert!(!wants_duplicates("fox -is:duplicate type:image"));
        // `taste:` is left to the taste model, and asked for.
        assert_eq!(names(&db, "/out", false, "taste:reject"), names(&db, "/out", false, ""));
        assert_eq!(taste_term("fox taste:keep"), Some(crate::taste::Verdict::Keep));
        assert_eq!(taste_term("likely:reject"), Some(crate::taste::Verdict::Reject));
        assert_eq!(taste_term("fox -taste:keep"), None);
        assert_eq!(taste_term("taste:maybe"), None);

        let usage = db.usage("/out", true, "").unwrap();
        let group = |kind: &str| usage.groups.iter().find(|g| g.kind == kind).unwrap();
        let flux = group("model").items.iter().find(|i| i.value == "flux1-dev.safetensors").unwrap();
        assert_eq!((flux.count, flux.rated, flux.stars, flux.keeps), (2, 2, 9, 1));
        assert_eq!(flux.samples.iter().map(|s| s.path.as_str()).collect::<Vec<_>>(), ["/out/a.png", "/out/sub/d.png"]);
        // Rejected pictures are never samples.
        assert!(group("model").items.iter().find(|i| i.value == "other.safetensors").unwrap().samples.is_empty());
        let stars: Vec<(&str, u32)> = group("rating").items.iter().map(|i| (i.value.as_str(), i.count)).collect();
        assert_eq!(stars, [("5", 1), ("4", 1), ("3", 1), ("0", 1)]);
        let cols: Vec<(&str, u32)> = group("collection").items.iter().map(|i| (i.value.as_str(), i.count)).collect();
        // As first met, newest first.
        assert_eq!(cols, [("Night City", 2), ("foxes", 2)]);
        assert_eq!(group("prompt").items[0].value, "a heron");
        assert_eq!(group("flag").items.len(), 2);
        // Counted within a search.
        let narrowed = db.usage("/out", true, "fox").unwrap();
        assert_eq!(narrowed.total, 2);
        assert_eq!(db.collection_names().unwrap().len(), 2);
        assert!(db.vocabulary("/out", true, 2, 100).unwrap().contains(&"heron".to_string()));
    }

    #[test]
    fn settings_roundtrip() {
        let tmp = tempfile::tempdir().unwrap();
        let db = Db::open(tmp.path()).unwrap();
        assert_eq!(db.get_setting("tile"), None);
        db.set_setting("tile", "180").unwrap();
        db.set_setting("tile", "220").unwrap();
        assert_eq!(db.get_setting("tile").as_deref(), Some("220"));
        drop(db);
        let db = Db::open(tmp.path()).unwrap();
        assert_eq!(db.get_setting("tile").as_deref(), Some("220"));
    }
}
