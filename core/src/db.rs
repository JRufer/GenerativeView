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
use parking_lot::Mutex;
use rusqlite::functions::FunctionFlags;
use rusqlite::{params, params_from_iter, Connection, OpenFlags};
use std::collections::{BTreeMap, HashMap};
use std::path::Path;

pub type DbResult<T> = Result<T, rusqlite::Error>;

const SCHEMA_VERSION: i64 = 4;

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
    /// newest | oldest | name | name_desc | size
    pub sort: String,
}

/// (id, dir index, name, kind, width, height, mtime, size, duration ms)
pub type Row = (i64, u32, String, u8, u32, u32, i64, i64, i64);

#[derive(Debug, Default, serde::Serialize)]
pub struct QueryResult {
    pub dirs: Vec<String>,
    pub rows: Vec<Row>,
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
    ///           u32 name offset, u16 name length, u8 kind, u8 0, u32 dir index
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
        for (id, dir, name, kind, width, height, mtime, size, duration) in &self.rows {
            out.extend_from_slice(&id.to_le_bytes());
            out.extend_from_slice(&mtime.to_le_bytes());
            out.extend_from_slice(&size.to_le_bytes());
            out.extend_from_slice(&width.to_le_bytes());
            out.extend_from_slice(&height.to_le_bytes());
            out.extend_from_slice(&(*duration as u32).to_le_bytes());
            out.extend_from_slice(&(strings.len() as u32).to_le_bytes());
            out.extend_from_slice(&(name.len() as u16).to_le_bytes());
            out.push(*kind);
            out.push(0);
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
                 DROP TABLE IF EXISTS files;",
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
        let (mut cond, mut args) = dir_condition(&q.dir, q.recursive, "f.");
        let mut needs_text = false;
        for term in parse_terms(&q.text) {
            needs_text |= term.to_sql(&mut cond, &mut args);
        }
        let order = match q.sort.as_str() {
            "oldest" => "f.mtime ASC, f.name ASC",
            "name" => "f.dir ASC, f.name COLLATE NOCASE ASC",
            "name_desc" => "f.dir DESC, f.name COLLATE NOCASE DESC",
            "size" => "f.size DESC, f.name ASC",
            _ => "f.mtime DESC, f.name DESC",
        };
        // Only pull in the text table when a term actually needs it.
        let join = if needs_text { "JOIN ftext t ON t.id = f.id" } else { "" };
        let sql = format!(
            "SELECT f.id, f.dir, f.name, f.kind, f.width, f.height, f.mtime, f.size, f.duration
             FROM files f {join} WHERE {cond} ORDER BY {order}"
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
        }
        Ok(out)
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
    /// `source`, `date`, and the facets `sampler`, `scheduler`, `steps`,
    /// `cfg`, `size`). None = anywhere.
    field: Option<&'static str>,
    /// `field:=text`: the whole value, not part of it.
    exact: bool,
    text: String,
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
        _ => return None,
    })
}

/// Split a search box string into terms: whitespace separated, "quoted
/// phrases" kept whole, `-term` to exclude, `field:term` to target a column,
/// `field:=term` to match the whole of a value rather than part of it.
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

impl Term {
    /// Append this term's predicate. Returns true if it reads the `ftext` table.
    fn to_sql(&self, cond: &mut String, args: &mut Vec<String>) -> bool {
        let not = if self.negate { "NOT " } else { "" };
        let mut bind = |value: String| {
            args.push(value);
            args.len()
        };
        // One of the image's values under `kind`: all of it, or part of it.
        let mut facet = |kind: &str, exact: bool| {
            let n = bind(facet_value(kind, &self.text).to_lowercase());
            format!(" AND {not}gv_facet(t.facets, '{kind}', ?{n}, {})", exact as u8)
        };
        match (self.field, self.exact) {
            (Some("seed"), true) => {
                let n = bind(self.text.clone());
                cond.push_str(&format!(" AND {not}(f.seed = ?{n})"));
                false
            }
            (Some("seed"), false) => {
                // Seeds are matched from the start: seed:123 finds 1234567.
                let n = bind(self.text.clone());
                cond.push_str(&format!(" AND {not}(substr(f.seed, 1, length(?{n})) = ?{n})"));
                false
            }
            (Some("source"), _) => {
                let n = bind(self.text.to_lowercase());
                cond.push_str(&format!(" AND {not}(f.source = ?{n})"));
                false
            }
            (Some("date"), _) => {
                // Numbers we worked out ourselves, so they go in as they are.
                match dates::parse_range(&self.text) {
                    Some((from, to)) => cond.push_str(&format!(" AND {not}(f.mtime >= {from} AND f.mtime < {to})")),
                    None => cond.push_str(&format!(" AND {not}(0)")),
                }
                false
            }
            (Some("lname"), true) => {
                let n = bind(self.text.to_lowercase());
                cond.push_str(&format!(" AND {not}(t.lname = ?{n})"));
                true
            }
            (Some(col @ ("prompt" | "negative")), true) => {
                // As whole words: prompt:=fox leaves foxglove out.
                let n = bind(self.text.to_lowercase());
                cond.push_str(&format!(" AND {not}gv_word(t.{col}, ?{n})"));
                true
            }
            (Some("model"), true) => {
                cond.push_str(&facet("model", true));
                true
            }
            (Some("loras"), true) => {
                cond.push_str(&facet("lora", true));
                true
            }
            (Some(kind @ ("sampler" | "scheduler" | "size")), exact) => {
                cond.push_str(&facet(kind, exact));
                true
            }
            // Numbers have no "part of": steps:30 is not steps 130.
            (Some(kind @ ("steps" | "cfg")), _) => {
                cond.push_str(&facet(kind, true));
                true
            }
            (field, _) => {
                let n = bind(self.text.to_lowercase());
                let col = field.unwrap_or("blob");
                cond.push_str(&format!(" AND {not}(instr(t.{col}, ?{n}) > 0)"));
                true
            }
        }
    }
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

fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Whether `needle` occurs in `text` as whole words, not inside longer ones.
fn has_word(text: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return false;
    }
    let mut from = 0;
    while let Some(at) = text[from..].find(needle) {
        let start = from + at;
        let end = start + needle.len();
        let before = text[..start].chars().next_back().map_or(false, is_word_char);
        let after = text[end..].chars().next().map_or(false, is_word_char);
        if !before && !after {
            return true;
        }
        from = start + text[start..].chars().next().map_or(1, char::len_utf8);
    }
    false
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
    conn.create_scalar_function("gv_word", 2, flags, |ctx| {
        let text = ctx.get_raw(0).as_str().unwrap_or("");
        let needle = ctx.get_raw(1).as_str().unwrap_or("");
        Ok(has_word(text, needle))
    })
}

// ---------------------------------------------------------------- usage

/// The facet kinds that are counted, in the order they are reported.
const USAGE_KINDS: [&str; 9] = ["model", "lora", "aux", "sampler", "scheduler", "steps", "cfg", "size", "source"];
/// How many values of a kind are reported, most used first.
const USAGE_TOP: usize = 100;
const USAGE_WORDS: usize = 60;
/// How finely each value's use is spread over the folder's time span.
pub const TREND_SLOTS: usize = 24;

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
}

#[derive(Debug, Default, serde::Serialize)]
pub struct UsageGroup {
    /// model | lora | aux | sampler | scheduler | steps | cfg | size | source | word
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

struct Tally {
    value: String,
    role: String,
    count: u32,
    trend: [u32; TREND_SLOTS],
}

fn tally(map: &mut HashMap<String, Tally>, key: &str, value: &str, role: &str, slot: usize) {
    if let Some(t) = map.get_mut(key) {
        t.count += 1;
        t.trend[slot] += 1;
        return;
    }
    let mut trend = [0; TREND_SLOTS];
    trend[slot] = 1;
    map.insert(key.to_string(), Tally { value: value.to_string(), role: role.to_string(), count: 1, trend });
}

fn ranked(kind: &'static str, map: HashMap<String, Tally>, top: usize) -> UsageGroup {
    let distinct = map.len();
    let mut all: Vec<Tally> = map.into_values().collect();
    all.sort_by(|a, b| b.count.cmp(&a.count).then_with(|| a.value.cmp(&b.value)));
    all.truncate(top);
    let items = all.into_iter().map(|t| UsageItem { value: t.value, count: t.count, role: t.role, trend: t.trend.to_vec() }).collect();
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
    /// Count what the images under `dir` were made with. One pass over the
    /// same rows a search reads; ten thousand images take a few milliseconds.
    pub fn usage(&self, dir: &str, recursive: bool) -> DbResult<Usage> {
        let (cond, args) = dir_condition(dir, recursive, "f.");
        let conn = self.read.lock();
        let (first, last): (Option<i64>, Option<i64>) = conn.query_row(
            &format!("SELECT min(f.mtime), max(f.mtime) FROM files f WHERE {cond}"),
            params_from_iter(args.iter()),
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        let mut usage = Usage { unit: "day", ..Default::default() };
        let (Some(first), Some(last)) = (first, last) else { return Ok(usage) };
        let span = (last - first).max(0) as i128 + 1;
        let slot = |mtime: i64| (((mtime - first).max(0) as i128 * TREND_SLOTS as i128) / span) as usize;

        let mut kinds: Vec<HashMap<String, Tally>> = USAGE_KINDS.iter().map(|_| HashMap::new()).collect();
        let mut words: HashMap<String, Tally> = HashMap::new();
        let mut days: BTreeMap<dates::Day, u32> = BTreeMap::new();

        let sql = format!("SELECT f.mtime, f.source, t.facets, t.prompt FROM files f JOIN ftext t ON t.id = f.id WHERE {cond}");
        let mut stmt = conn.prepare_cached(&sql)?;
        let mut rows = stmt.query(params_from_iter(args.iter()))?;
        while let Some(r) = rows.next()? {
            let mtime: i64 = r.get(0)?;
            let at = slot(mtime).min(TREND_SLOTS - 1);
            usage.total += 1;
            if !r.get_ref(1)?.as_str()?.is_empty() {
                usage.generated += 1;
            }
            *days.entry(dates::local_day(mtime)).or_insert(0) += 1;
            for line in r.get_ref(2)?.as_str()?.split('\n') {
                let mut parts = line.split('\t');
                let (Some(kind), Some(key), Some(value)) = (parts.next(), parts.next(), parts.next()) else { continue };
                let Some(k) = USAGE_KINDS.iter().position(|x| *x == kind) else { continue };
                tally(&mut kinds[k], key, value, parts.next().unwrap_or(""), at);
            }
            for word in prompt_words(r.get_ref(3)?.as_str()?) {
                tally(&mut words, word, word, "", at);
            }
        }

        usage.groups = USAGE_KINDS.iter().zip(kinds).map(|(kind, map)| ranked(kind, map, USAGE_TOP)).collect();
        usage.groups.push(ranked("word", words, USAGE_WORDS));
        (usage.unit, usage.timeline) = timeline(&days);
        Ok(usage)
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
        let q = Query { dir: dir.into(), recursive, text: text.into(), sort: "name".into() };
        db.query(&q).unwrap().rows.into_iter().map(|r| r.2).collect()
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
        // substring, case-insensitive
        assert_eq!(names(&db, "/out", true, "LOND"), ["a.png"]);
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
        assert_eq!(find("prompt:fox"), ["a.png", "b.png", "c.png"]);
        assert_eq!(find("prompt:=fox"), ["a.png", "c.png"]);
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
        let usage = db.usage("/out", true).unwrap();
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
        for (kind, field) in [("model", "model"), ("lora", "lora"), ("steps", "steps"), ("cfg", "cfg"), ("size", "size"), ("word", "prompt")] {
            for item in &group(kind).items {
                let found = names(&db, "/out", true, &format!("{field}:=\"{}\"", item.value)).len() as u32;
                assert_eq!(found, item.count, "{field}:={}", item.value);
            }
        }

        // Scope follows the folder.
        assert_eq!(db.usage("/elsewhere", true).unwrap().total, 0);
        assert!(db.usage("/elsewhere", true).unwrap().timeline.is_empty());
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
        assert_eq!(prompt_words("größe ünïcode_word"), ["größe", "ünïcode_word"]);

        assert!(has_word("a red fox.", "fox"));
        assert!(has_word("fox", "fox"));
        assert!(has_word("a red fox", "red fox"));
        assert!(has_word("foxglove, fox2, fox", "fox"));
        assert!(!has_word("foxglove", "fox"));
        assert!(!has_word("fox_like", "fox"));
        assert!(!has_word("éfox", "fox"));
        assert!(!has_word("anything", ""));

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
        let d = 16 + 2 * 48 + 8; // second dir
        assert_eq!(std::str::from_utf8(&b[strings + u32_at(d)..strings + u32_at(d) + u32_at(d + 4)]).unwrap(), "/a/bé");
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
