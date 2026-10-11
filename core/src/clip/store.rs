//! Where picture embeddings are kept: one small SQLite file beside the
//! index, and a copy in memory of every vector that has been used.
//!
//! Unlike the index, embeddings are slow to make (a tenth of a second or so
//! per picture), so they get a file of their own that a rebuild of the index
//! leaves alone. A vector is filed under the picture's path, date and size,
//! like a thumbnail: edit the file and it is embedded afresh.

use parking_lot::Mutex;
use rusqlite::{params, Connection};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

pub type Key = [u8; 16];

/// A unit vector as 16-bit fractions: half the space of floats, and close
/// enough (a few parts in 100,000) that rankings do not change.
pub type Packed = Arc<[i16]>;

const SCALE: f32 = 32767.0;

pub fn key(model: &str, path: &str, mtime: i64, size: i64) -> Key {
    let mut bytes = Vec::with_capacity(model.len() + path.len() + 18);
    bytes.extend_from_slice(model.as_bytes());
    bytes.push(0);
    bytes.extend_from_slice(path.as_bytes());
    bytes.push(0);
    bytes.extend_from_slice(&mtime.to_le_bytes());
    bytes.extend_from_slice(&size.to_le_bytes());
    xxhash_rust::xxh3::xxh3_128(&bytes).to_le_bytes()
}

pub fn pack(vector: &[f32]) -> Packed {
    vector.iter().map(|v| (v.clamp(-1.0, 1.0) * SCALE).round() as i16).collect()
}

/// How alike a (float) query and a packed vector are: their dot product.
pub fn score(query: &[f32], packed: &[i16]) -> f32 {
    query.iter().zip(packed).map(|(q, p)| q * *p as f32).sum::<f32>() / SCALE
}

pub struct Vectors {
    conn: Mutex<Connection>,
    /// None = looked for and not there.
    cache: Mutex<HashMap<Key, Option<Packed>>>,
}

impl Vectors {
    pub fn open(dir: &Path) -> Result<Vectors, String> {
        let _ = std::fs::create_dir_all(dir);
        let conn = Connection::open(dir.join("vectors.db")).map_err(|e| format!("cannot open the embedding store: {e}"))?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             CREATE TABLE IF NOT EXISTS vectors (key BLOB PRIMARY KEY, vec BLOB NOT NULL) WITHOUT ROWID;
             -- Files that could not be embedded (unreadable, or a video with
             -- no frame to look at), so they are not tried again every time.
             CREATE TABLE IF NOT EXISTS skipped (key BLOB PRIMARY KEY) WITHOUT ROWID;",
        )
        .map_err(|e| format!("cannot open the embedding store: {e}"))?;
        Ok(Vectors { conn: Mutex::new(conn), cache: Mutex::new(HashMap::new()) })
    }

    /// The vector filed under `key`, if there is one.
    pub fn get(&self, key: &Key) -> Option<Packed> {
        if let Some(hit) = self.cache.lock().get(key) {
            return hit.clone();
        }
        let found: Option<Packed> = self
            .conn
            .lock()
            .query_row("SELECT vec FROM vectors WHERE key = ?1", [key.as_slice()], |r| r.get::<_, Vec<u8>>(0))
            .ok()
            .map(|blob| blob.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect());
        self.cache.lock().insert(*key, found.clone());
        found
    }

    /// Whether `key` has been dealt with: embedded, or given up on.
    pub fn done(&self, key: &Key) -> bool {
        if self.get(key).is_some() {
            return true;
        }
        self.conn.lock().query_row("SELECT 1 FROM skipped WHERE key = ?1", [key.as_slice()], |_| Ok(())).is_ok()
    }

    pub fn put(&self, vectors: &[(Key, Vec<f32>)], skipped: &[Key]) -> Result<(), String> {
        let fail = |e: rusqlite::Error| format!("cannot save embeddings: {e}");
        let packed: Vec<(Key, Packed)> = vectors.iter().map(|(key, vector)| (*key, pack(vector))).collect();
        {
            let mut conn = self.conn.lock();
            let tx = conn.transaction().map_err(fail)?;
            for (key, vector) in &packed {
                let blob: Vec<u8> = vector.iter().flat_map(|v| v.to_le_bytes()).collect();
                tx.execute("INSERT OR REPLACE INTO vectors (key, vec) VALUES (?1, ?2)", params![key.as_slice(), blob]).map_err(fail)?;
            }
            for key in skipped {
                tx.execute("INSERT OR IGNORE INTO skipped (key) VALUES (?1)", [key.as_slice()]).map_err(fail)?;
            }
            tx.commit().map_err(fail)?;
        }
        let mut cache = self.cache.lock();
        for (key, vector) in packed {
            cache.insert(key, Some(vector));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let tmp = tempfile::tempdir().unwrap();
        let (a, b, c) = (key("m", "/a.png", 1, 2), key("m", "/b.png", 1, 2), key("m", "/c.mp4", 1, 2));
        assert_ne!(a, key("m", "/a.png", 1, 3));
        assert_ne!(a, key("other", "/a.png", 1, 2));
        let vector = vec![0.6, -0.8, 0.0, 1.0e-3];
        {
            let store = Vectors::open(tmp.path()).unwrap();
            assert!(store.get(&a).is_none() && !store.done(&a));
            store.put(&[(a, vector.clone())], &[c]).unwrap();
            assert!(store.done(&a) && store.done(&c) && !store.done(&b));
            assert!(store.get(&c).is_none());
        }
        // Still there after a restart, and as good as the original.
        let store = Vectors::open(tmp.path()).unwrap();
        let back = store.get(&a).unwrap();
        assert!((score(&vector, &back) - 1.0).abs() < 1e-4);
        assert!((score(&[0.0, 0.0, 1.0, 0.0], &back)).abs() < 1e-4);
        assert!(store.done(&c));
    }
}
