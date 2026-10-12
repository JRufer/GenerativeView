//! What the user says about their pictures: a rating, a keep-or-reject flag,
//! and the collections a picture is in.
//!
//! None of it lives only in the app. Each folder gets a small file,
//! [`FILE_NAME`], beside its pictures, holding the notes for the pictures in
//! that folder, so that a folder synced between machines (or opened from a
//! tablet and from a desktop) carries its ratings with it. The index keeps a
//! copy in its `notes` table so searches can use them; that copy is a cache,
//! reloaded from the folder files whenever they change on disk.
//!
//! The file looks like this, and anything else found in it is kept as it is:
//!
//! ```json
//! {
//!   "generativeview": 1,
//!   "images": {
//!     "ComfyUI_00012_.png": { "rating": 4, "flag": "keep", "collections": ["Night city"] }
//!   }
//! }
//! ```

use crate::db::Db;
use parking_lot::Mutex;
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

/// The notes file in each folder. Hidden, so file managers and the folder
/// walk leave it be.
pub const FILE_NAME: &str = ".generativeview.json";

/// The highest rating; 0 is "not rated".
pub const MAX_RATING: u8 = 5;

/// A picture's keep-or-reject flag.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Flag {
    #[default]
    None = 0,
    Keep = 1,
    Reject = 2,
}

impl Flag {
    pub fn parse(text: &str) -> Option<Flag> {
        Some(match text.trim().to_ascii_lowercase().as_str() {
            "" | "none" | "unflagged" | "clear" => Flag::None,
            "keep" | "pick" | "picked" | "keeper" | "kept" => Flag::Keep,
            "reject" | "rejected" | "rej" | "x" => Flag::Reject,
            _ => return None,
        })
    }

    pub fn from_i64(v: i64) -> Flag {
        match v {
            1 => Flag::Keep,
            2 => Flag::Reject,
            _ => Flag::None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Flag::None => "",
            Flag::Keep => "keep",
            Flag::Reject => "reject",
        }
    }
}

/// The notes for one picture.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Note {
    pub rating: u8,
    pub flag: Flag,
    /// As the user wrote them, in the order they were added.
    pub collections: Vec<String>,
}

impl Note {
    pub fn is_empty(&self) -> bool {
        self.rating == 0 && self.flag == Flag::None && self.collections.is_empty()
    }

    fn from_json(value: &Value) -> Note {
        let rating = value.get("rating").and_then(Value::as_u64).unwrap_or(0).min(MAX_RATING as u64) as u8;
        let flag = value.get("flag").and_then(Value::as_str).and_then(Flag::parse).unwrap_or_default();
        let mut collections: Vec<String> = Vec::new();
        for name in value.get("collections").and_then(Value::as_array).into_iter().flatten() {
            if let Some(name) = name.as_str().map(clean_name).filter(|n| !n.is_empty()) {
                if !collections.iter().any(|c| c.eq_ignore_ascii_case(&name)) {
                    collections.push(name);
                }
            }
        }
        Note { rating, flag, collections }
    }

    /// Write this note's fields into `entry`, leaving anything else in it.
    fn write_into(&self, entry: &mut Map<String, Value>) {
        if self.rating > 0 {
            entry.insert("rating".into(), json!(self.rating));
        } else {
            entry.remove("rating");
        }
        if self.flag != Flag::None {
            entry.insert("flag".into(), json!(self.flag.name()));
        } else {
            entry.remove("flag");
        }
        if self.collections.is_empty() {
            entry.remove("collections");
        } else {
            entry.insert("collections".into(), json!(self.collections));
        }
    }

    pub fn to_json(&self) -> Value {
        json!({ "rating": self.rating, "flag": self.flag.name(), "collections": self.collections })
    }
}

/// A collection name as it is kept: one line, trimmed.
pub fn clean_name(name: &str) -> String {
    name.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// A change to make to some pictures' notes. Fields left as None stay as
/// they are.
#[derive(Debug, Clone, Default)]
pub struct Change {
    pub rating: Option<u8>,
    pub flag: Option<Flag>,
    pub add: Vec<String>,
    pub remove: Vec<String>,
}

impl Change {
    fn apply(&self, note: &mut Note) {
        if let Some(rating) = self.rating {
            note.rating = rating.min(MAX_RATING);
        }
        if let Some(flag) = self.flag {
            note.flag = flag;
        }
        note.collections.retain(|c| !self.remove.iter().any(|r| r.eq_ignore_ascii_case(c)));
        for name in &self.add {
            let name = clean_name(name);
            if !name.is_empty() && !note.collections.iter().any(|c| c.eq_ignore_ascii_case(&name)) {
                note.collections.push(name);
            }
        }
    }
}

fn join(dir: &str, name: &str) -> PathBuf {
    Path::new(dir).join(name)
}

fn stamp(path: &Path) -> Option<(i64, i64)> {
    let md = std::fs::metadata(path).ok()?;
    let mtime = md.modified().ok()?.duration_since(UNIX_EPOCH).ok()?.as_millis() as i64;
    Some((mtime, md.len() as i64))
}

/// Read a folder's notes file as JSON; an empty object when there is none
/// or it cannot be read.
fn read_file(path: &Path) -> Map<String, Value> {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|v| match v {
            Value::Object(map) => Some(map),
            _ => None,
        })
        .unwrap_or_default()
}

/// Every note in a folder's notes file, by file name.
pub fn parse(file: &Map<String, Value>) -> Vec<(String, Note)> {
    let Some(Value::Object(images)) = file.get("images") else { return Vec::new() };
    images
        .iter()
        .map(|(name, v)| (name.clone(), Note::from_json(v)))
        .filter(|(_, note)| !note.is_empty())
        .collect()
}

/// Reads and writes the notes files, and keeps the index's copy in step.
pub struct Notes {
    /// One change at a time: each is a read, a merge and a write of a file.
    lock: Mutex<()>,
}

impl Default for Notes {
    fn default() -> Self {
        Self::new()
    }
}

impl Notes {
    pub fn new() -> Notes {
        Notes { lock: Mutex::new(()) }
    }

    /// Bring the index's copy of `dir`'s notes up to date with its file, if
    /// the file changed since it was last read (or `force`). Returns whether
    /// anything the index holds changed.
    pub fn load_dir(&self, db: &Db, dir: &str, force: bool) -> bool {
        let path = join(dir, FILE_NAME);
        let now = stamp(&path);
        let known = db.notes_stamp(dir);
        if !force && now == known {
            return false;
        }
        let notes = if now.is_some() { parse(&read_file(&path)) } else { Vec::new() };
        let before = db.notes_in(dir).unwrap_or_default();
        let mut after = notes.clone();
        after.sort_by(|a, b| a.0.cmp(&b.0));
        let changed = before != after;
        if changed {
            let _ = db.replace_notes(dir, &notes);
        }
        let _ = db.set_notes_stamp(dir, now);
        changed
    }

    /// Change the notes of some pictures, all in one folder, and write the
    /// folder's file. Returns the notes as they now are, in the same order.
    pub fn change(&self, db: &Db, dir: &str, names: &[String], change: &Change) -> Result<Vec<Note>, String> {
        let _guard = self.lock.lock();
        let path = join(dir, FILE_NAME);
        // Start from what is on disk now, which another machine may have
        // changed since it was last read.
        let mut file = read_file(&path);
        file.insert("generativeview".into(), json!(1));
        let images = file.entry("images").or_insert_with(|| Value::Object(Map::new()));
        if !images.is_object() {
            *images = Value::Object(Map::new());
        }
        let Value::Object(images) = images else { unreachable!() };
        let mut out = Vec::with_capacity(names.len());
        for name in names {
            let mut note = images.get(name).map(Note::from_json).unwrap_or_default();
            change.apply(&mut note);
            let entry = images.entry(name.clone()).or_insert_with(|| Value::Object(Map::new()));
            if !entry.is_object() {
                *entry = Value::Object(Map::new());
            }
            if let Value::Object(entry) = entry {
                note.write_into(entry);
                if entry.is_empty() {
                    images.remove(name);
                }
            }
            out.push(note);
        }
        let empty = images.is_empty() && file.len() <= 2;
        if empty {
            match std::fs::remove_file(&path) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(format!("cannot update {}: {e}", path.display())),
            }
        } else {
            write_atomic(&path, &file)?;
        }
        // The index follows the file.
        self.load_dir(db, dir, true);
        Ok(out)
    }
}

/// Write `file` to `path` so that a reader (or a sync tool) never sees half
/// of it: to a temporary file beside it, then renamed over it.
fn write_atomic(path: &Path, file: &Map<String, Value>) -> Result<(), String> {
    let text = serde_json::to_string_pretty(&Value::Object(file.clone())).map_err(|e| e.to_string())? + "\n";
    let tmp = path.with_file_name(format!("{FILE_NAME}.{}.tmp", std::process::id()));
    std::fs::write(&tmp, text).map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("cannot write {}: {e}", path.display())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn change_writes_and_merges() {
        let tmp = tempfile::tempdir().unwrap();
        let db = Db::open(&tmp.path().join("data")).unwrap();
        let dir = tmp.path().join("pics");
        std::fs::create_dir_all(&dir).unwrap();
        let dir = dir.to_str().unwrap().to_string();
        let notes = Notes::new();

        // Something else wrote the file first, with fields we do not know.
        std::fs::write(
            Path::new(&dir).join(FILE_NAME),
            r#"{"generativeview":1,"by":"other","images":{"b.png":{"rating":2,"color":"red"}}}"#,
        )
        .unwrap();
        assert!(notes.load_dir(&db, &dir, false));
        assert!(!notes.load_dir(&db, &dir, false), "unchanged file is not reloaded");
        assert_eq!(db.note(&dir, "b.png").rating, 2);

        let change = Change { rating: Some(4), flag: Some(Flag::Keep), add: vec!["  Night   city ".into()], ..Default::default() };
        let out = notes.change(&db, &dir, &["a.png".into(), "b.png".into()], &change).unwrap();
        assert_eq!(out[0], Note { rating: 4, flag: Flag::Keep, collections: vec!["Night city".into()] });
        assert_eq!(db.note(&dir, "b.png").flag, Flag::Keep);

        let file: Value = serde_json::from_str(&std::fs::read_to_string(Path::new(&dir).join(FILE_NAME)).unwrap()).unwrap();
        assert_eq!(file["by"], "other");
        assert_eq!(file["images"]["b.png"]["color"], "red");
        assert_eq!(file["images"]["a.png"]["collections"][0], "Night city");

        // Adding a name twice in another case keeps one; removing ignores case.
        notes.change(&db, &dir, &["a.png".into()], &Change { add: vec!["night CITY".into()], ..Default::default() }).unwrap();
        assert_eq!(db.note(&dir, "a.png").collections, ["Night city"]);
        notes
            .change(&db, &dir, &["a.png".into()], &Change { rating: Some(0), flag: Some(Flag::None), remove: vec!["NIGHT city".into()], ..Default::default() })
            .unwrap();
        assert!(db.note(&dir, "a.png").is_empty());
        let file: Value = serde_json::from_str(&std::fs::read_to_string(Path::new(&dir).join(FILE_NAME)).unwrap()).unwrap();
        assert!(file["images"].get("a.png").is_none(), "an empty note leaves the file");

        // A file deleted elsewhere takes its notes with it.
        std::fs::remove_file(Path::new(&dir).join(FILE_NAME)).unwrap();
        assert!(notes.load_dir(&db, &dir, false));
        assert!(db.note(&dir, "b.png").is_empty());
    }
}
