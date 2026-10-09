//! The lookup database: one SQLite file with a row per media file, holding
//! what the grid needs (name, size, dimensions) and lower-cased search text
//! (prompts, models, LoRAs, settings).
//!
//! Search is a plain substring scan over that text. A trigram full-text index
//! was measured and dropped: it made first-time indexing about four times
//! slower and bought nothing at the size of an image folder, where scanning
//! ten thousand rows takes a few milliseconds.

use crate::meta::GenInfo;
use parking_lot::Mutex;
use rusqlite::{params, params_from_iter, Connection, OpenFlags};
use std::collections::HashMap;
use std::path::Path;

pub type DbResult<T> = Result<T, rusqlite::Error>;

const SCHEMA_VERSION: i64 = 3;

// `files` stays narrow so listing a folder touches few pages. The search
// text lives beside it in `ftext`, lower-cased; it is only ever searched,
// never shown (the UI reads full metadata straight from the file when
// asked). `blob` is every field joined, so an unqualified term is one scan.
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
    blob     TEXT NOT NULL DEFAULT ''
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
                "INSERT OR REPLACE INTO ftext (id, lname, prompt, negative, model, loras, extra, blob)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
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
                text.execute(params![id, lname, prompt, negative, model, loras, extra, blob])?;
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
    /// Column to search, or "seed" / "source" for exact fields; None = anywhere.
    field: Option<&'static str>,
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
        "sampler" | "scheduler" | "steps" | "cfg" => "extra",
        _ => return None,
    })
}

/// Split a search box string into terms: whitespace separated, "quoted
/// phrases" kept whole, `-term` to exclude, `field:term` to target a column.
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
                    continue;
                }
            }
            raw.push(c);
            chars.next();
        }
        if !raw.is_empty() {
            terms.push(Term { negate, field, text: raw });
        }
    }
    terms
}

impl Term {
    /// Append this term's predicate. Returns true if it reads the `ftext` table.
    fn to_sql(&self, cond: &mut String, args: &mut Vec<String>) -> bool {
        let not = if self.negate { "NOT " } else { "" };
        match self.field {
            Some("seed") => {
                // Seeds are matched from the start: seed:123 finds 1234567.
                args.push(self.text.clone());
                let n = args.len();
                cond.push_str(&format!(" AND {not}(substr(f.seed, 1, length(?{n})) = ?{n})"));
                false
            }
            Some("source") => {
                args.push(self.text.to_lowercase());
                cond.push_str(&format!(" AND {not}(f.source = ?{})", args.len()));
                false
            }
            field => {
                args.push(self.text.to_lowercase());
                let col = field.unwrap_or("blob");
                cond.push_str(&format!(" AND {not}(instr(t.{col}, ?{}) > 0)", args.len()));
                true
            }
        }
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
        assert_eq!(t[0], Term { negate: false, field: None, text: "blue".into() });
        assert_eq!(t[1], Term { negate: false, field: None, text: "red fox".into() });
        assert_eq!(t[2], Term { negate: true, field: None, text: "ugly".into() });
        assert_eq!(t[3], Term { negate: false, field: Some("model"), text: "flux".into() });
        assert_eq!(parse_terms("name:IMG")[0].field, Some("lname"));
        assert_eq!(t[4], Term { negate: true, field: Some("loras"), text: "detail xl".into() });
        assert_eq!(t[5], Term { negate: false, field: None, text: "a-b".into() });
        // A URL-ish token is not mistaken for a field.
        assert_eq!(parse_terms("http://x")[0].field, None);
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
