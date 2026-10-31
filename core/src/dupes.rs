//! Near-duplicates: pictures that are all but the same picture (the same seed
//! run again, a LoRA nudged, a resave), found by comparing small fingerprints
//! of what they look like.
//!
//! A fingerprint is two 64-bit difference hashes of the picture shrunk to a
//! few pixels in grey, one comparing each pixel with its right-hand
//! neighbour and one with the one below, plus its average colour. Two
//! pictures are near-duplicates when their hashes differ in few bits, their
//! colours are close and their shapes are the same. It needs no model, and
//! is made from the small thumbnail, which the grid has usually made already.
//!
//! Fingerprints are kept in a small SQLite file of their own beside the
//! index, under the picture's path, date and size, like a thumbnail: edit
//! the file and it is fingerprinted afresh.

use crate::db::QueryResult;
use crate::thumbs::Thumbs;
use parking_lot::Mutex;
use rayon::prelude::*;
use rusqlite::{params, Connection};
use std::collections::HashMap;
use std::path::Path;

pub type Key = [u8; 16];

/// What a picture looks like, very roughly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Fingerprint {
    /// Each bit: is this grey pixel brighter than the one to its right
    /// (9×8 shrunk).
    pub across: u64,
    /// Each bit: is it brighter than the one below it (8×9 shrunk).
    pub down: u64,
    /// The average colour.
    pub rgb: [u8; 3],
}

/// At most this many of the 128 hash bits may differ...
pub const MAX_BITS: u32 = 12;
/// ...and no channel of the average colour by more than this.
pub const MAX_COLOUR: u8 = 24;
/// Width over height may differ by this share at most.
const MAX_SHAPE: f64 = 0.02;

impl Fingerprint {
    pub fn of(img: &image::DynamicImage) -> Fingerprint {
        use image::imageops::FilterType;
        let grey = img.to_luma8();
        let wide = image::imageops::resize(&grey, 9, 8, FilterType::Triangle);
        let tall = image::imageops::resize(&grey, 8, 9, FilterType::Triangle);
        let mut across = 0u64;
        let mut down = 0u64;
        for y in 0..8u32 {
            for x in 0..8u32 {
                let bit = y * 8 + x;
                if wide.get_pixel(x, y)[0] > wide.get_pixel(x + 1, y)[0] {
                    across |= 1 << bit;
                }
                if tall.get_pixel(x, y)[0] > tall.get_pixel(x, y + 1)[0] {
                    down |= 1 << bit;
                }
            }
        }
        let dot = image::imageops::resize(&img.to_rgb8(), 1, 1, FilterType::Triangle);
        let p = dot.get_pixel(0, 0);
        Fingerprint { across, down, rgb: [p[0], p[1], p[2]] }
    }

    /// How many hash bits differ.
    pub fn distance(&self, other: &Fingerprint) -> u32 {
        (self.across ^ other.across).count_ones() + (self.down ^ other.down).count_ones()
    }

    pub fn near(&self, other: &Fingerprint) -> bool {
        self.distance(other) <= MAX_BITS && self.rgb.iter().zip(other.rgb).all(|(a, b)| a.abs_diff(b) <= MAX_COLOUR)
    }

    fn to_bytes(self) -> [u8; 19] {
        let mut out = [0u8; 19];
        out[..8].copy_from_slice(&self.across.to_le_bytes());
        out[8..16].copy_from_slice(&self.down.to_le_bytes());
        out[16..].copy_from_slice(&self.rgb);
        out
    }

    fn from_bytes(b: &[u8]) -> Option<Fingerprint> {
        if b.len() != 19 {
            return None;
        }
        Some(Fingerprint {
            across: u64::from_le_bytes(b[..8].try_into().ok()?),
            down: u64::from_le_bytes(b[8..16].try_into().ok()?),
            rgb: [b[16], b[17], b[18]],
        })
    }
}

pub fn key(path: &str, mtime: i64, size: i64) -> Key {
    let mut bytes = Vec::with_capacity(path.len() + 17);
    bytes.extend_from_slice(path.as_bytes());
    bytes.push(0);
    bytes.extend_from_slice(&mtime.to_le_bytes());
    bytes.extend_from_slice(&size.to_le_bytes());
    xxhash_rust::xxh3::xxh3_128(&bytes).to_le_bytes()
}

pub struct Duplicates {
    conn: Option<Mutex<Connection>>,
    /// None = tried, and the picture could not be read.
    cache: Mutex<HashMap<Key, Option<Fingerprint>>>,
    /// One fingerprinting pass at a time: searches that arrive meanwhile
    /// wait, then find the work done.
    busy: Mutex<()>,
}

impl Duplicates {
    pub fn open(dir: &Path) -> Duplicates {
        let _ = std::fs::create_dir_all(dir);
        // Without its file it still works, only without remembering.
        let conn = Connection::open(dir.join("fingerprints.db")).ok().filter(|conn| {
            conn.execute_batch(
                "PRAGMA journal_mode = WAL;
                 PRAGMA synchronous = NORMAL;
                 CREATE TABLE IF NOT EXISTS prints (key BLOB PRIMARY KEY, fp BLOB) WITHOUT ROWID;",
            )
            .is_ok()
        });
        let mut cache = HashMap::new();
        if let Some(conn) = &conn {
            if let Ok(mut stmt) = conn.prepare("SELECT key, fp FROM prints") {
                let rows = stmt.query_map([], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, Option<Vec<u8>>>(1)?)));
                if let Ok(rows) = rows {
                    for (k, fp) in rows.flatten() {
                        if let Ok(k) = Key::try_from(k.as_slice()) {
                            cache.insert(k, fp.as_deref().and_then(Fingerprint::from_bytes));
                        }
                    }
                }
            }
        }
        Duplicates { conn: conn.map(Mutex::new), cache: Mutex::new(cache), busy: Mutex::new(()) }
    }

    /// The fingerprint of each picture in `result` (None for videos and
    /// pictures that cannot be read), making those not yet made.
    fn prints(&self, thumbs: &Thumbs, result: &QueryResult) -> Vec<Option<Fingerprint>> {
        let path = |i: usize| {
            let r = &result.rows[i];
            let dir = &result.dirs[r.1 as usize];
            if dir.ends_with('/') {
                format!("{dir}{}", r.2)
            } else {
                format!("{dir}/{}", r.2)
            }
        };
        let keys: Vec<Key> = (0..result.rows.len()).map(|i| key(&path(i), result.rows[i].6, result.rows[i].7)).collect();
        let _pass = self.busy.lock();
        let missing: Vec<usize> = {
            let cache = self.cache.lock();
            (0..keys.len()).filter(|&i| result.rows[i].3 == 0 && !cache.contains_key(&keys[i])).collect()
        };
        if !missing.is_empty() {
            let made: Vec<(Key, Option<Fingerprint>)> = missing
                .par_iter()
                .map(|&i| {
                    let r = &result.rows[i];
                    let fp = thumbs
                        .get(&path(i), r.6, r.7, 0)
                        .ok()
                        .and_then(|jpeg| image::load_from_memory(&jpeg).ok())
                        .map(|img| Fingerprint::of(&img));
                    (keys[i], fp)
                })
                .collect();
            if let Some(conn) = &self.conn {
                let mut conn = conn.lock();
                if let Ok(tx) = conn.transaction() {
                    for (k, fp) in &made {
                        let bytes = fp.map(|f| f.to_bytes().to_vec());
                        let _ = tx.execute("INSERT OR REPLACE INTO prints (key, fp) VALUES (?1, ?2)", params![k.as_slice(), bytes]);
                    }
                    let _ = tx.commit();
                };
            }
            self.cache.lock().extend(made);
        }
        let cache = self.cache.lock();
        (0..keys.len()).map(|i| if result.rows[i].3 == 0 { cache.get(&keys[i]).copied().flatten() } else { None }).collect()
    }

    /// The pictures of `result` that have a near-duplicate among it, each
    /// group together: groups in the order of their first picture, and the
    /// pictures of a group in the order they came.
    /// The groups of near-duplicates among `result`, as indexes into it,
    /// in the order [`Duplicates::only_duplicates`] lists them.
    pub fn groups(&self, thumbs: &Thumbs, result: &QueryResult) -> Vec<Vec<usize>> {
        let prints = self.prints(thumbs, result);
        let shapes: Vec<f64> = result.rows.iter().map(|r| if r.5 > 0 { r.4 as f64 / r.5 as f64 } else { 0.0 }).collect();
        group(&prints, &shapes)
    }

    pub fn only_duplicates(&self, thumbs: &Thumbs, result: &QueryResult) -> QueryResult {
        let prints = self.prints(thumbs, result);
        let shapes: Vec<f64> = result.rows.iter().map(|r| if r.5 > 0 { r.4 as f64 / r.5 as f64 } else { 0.0 }).collect();
        let groups = group(&prints, &shapes);
        result.pick(groups.into_iter().flatten())
    }
}

/// Union–find over everything that is near something else. Returns the
/// groups of two or more, as indexes into `prints`, ordered as above.
pub fn group(prints: &[Option<Fingerprint>], shapes: &[f64]) -> Vec<Vec<usize>> {
    let n = prints.len();
    let mut parent: Vec<usize> = (0..n).collect();
    fn root(parent: &mut [usize], mut i: usize) -> usize {
        while parent[i] != i {
            parent[i] = parent[parent[i]];
            i = parent[i];
        }
        i
    }
    // Sorted by shape, so only pictures of (nearly) the same shape are
    // compared: a slice of the list rather than all of it.
    let mut order: Vec<usize> = (0..n).filter(|&i| prints[i].is_some() && shapes[i] > 0.0).collect();
    order.sort_by(|&a, &b| shapes[a].total_cmp(&shapes[b]));
    for (at, &a) in order.iter().enumerate() {
        let fa = prints[a].unwrap();
        for &b in &order[at + 1..] {
            if shapes[b] > shapes[a] * (1.0 + MAX_SHAPE) {
                break;
            }
            if fa.near(&prints[b].unwrap()) {
                let (ra, rb) = (root(&mut parent, a), root(&mut parent, b));
                if ra != rb {
                    parent[ra.max(rb)] = ra.min(rb);
                }
            }
        }
    }
    let mut members: HashMap<usize, Vec<usize>> = HashMap::new();
    for i in 0..n {
        if prints[i].is_some() && shapes[i] > 0.0 {
            let r = root(&mut parent, i);
            members.entry(r).or_default().push(i);
        }
    }
    let mut groups: Vec<Vec<usize>> = members.into_values().filter(|g| g.len() > 1).collect();
    for g in &mut groups {
        g.sort_unstable();
    }
    groups.sort_by_key(|g| g[0]);
    groups
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{DynamicImage, Rgb, RgbImage};

    /// A picture: a soft diagonal ramp with a bright disc at (`cx`, `cy`).
    fn picture(w: u32, h: u32, cx: f32, cy: f32, tint: [u8; 3]) -> DynamicImage {
        DynamicImage::ImageRgb8(RgbImage::from_fn(w, h, |x, y| {
            let ramp = (x + y) as f32 / (w + h) as f32 * 120.0;
            let d = ((x as f32 - cx * w as f32).powi(2) + (y as f32 - cy * h as f32).powi(2)).sqrt();
            let disc = if d < w as f32 * 0.18 { 110.0 } else { 0.0 };
            let v = (ramp + disc) as u8;
            Rgb([v.saturating_add(tint[0]), v.saturating_add(tint[1]), v.saturating_add(tint[2])])
        }))
    }

    #[test]
    fn the_same_picture_a_little_changed_is_near_and_another_is_not() {
        let a = Fingerprint::of(&picture(256, 384, 0.3, 0.4, [0, 0, 0]));
        // Lighter by a few levels, and a little noise from a resave.
        let mut b_img = picture(256, 384, 0.3, 0.4, [6, 6, 6]).to_rgb8();
        for (i, p) in b_img.pixels_mut().enumerate() {
            if i % 7 == 0 {
                p[0] = p[0].saturating_add(3);
            }
        }
        let b = Fingerprint::of(&DynamicImage::ImageRgb8(b_img));
        // Shrunk, as a thumbnail is.
        let small = Fingerprint::of(&picture(256, 384, 0.3, 0.4, [0, 0, 0]).thumbnail(128, 192));
        let other = Fingerprint::of(&picture(256, 384, 0.75, 0.8, [0, 0, 0]));
        let tinted = Fingerprint::of(&picture(256, 384, 0.3, 0.4, [0, 90, 0]));
        assert!(a.near(&b), "distance {}", a.distance(&b));
        assert!(a.near(&small), "distance {}", a.distance(&small));
        assert!(!a.near(&other), "distance {}", a.distance(&other));
        assert!(!a.near(&tinted), "another colour altogether");
        assert_eq!(Fingerprint::from_bytes(&a.to_bytes()), Some(a));
    }

    #[test]
    fn groups_are_of_near_pictures_of_one_shape_in_order() {
        let fp = |cx, cy, w, h| Some(Fingerprint::of(&picture(w, h, cx, cy, [0, 0, 0])));
        let prints = vec![
            fp(0.3, 0.4, 256, 384),  // 0: group A
            fp(0.8, 0.2, 256, 384),  // 1: alone
            fp(0.3, 0.4, 256, 384),  // 2: group A
            None,                    // 3: a video
            fp(0.7, 0.7, 384, 256),  // 4: group B
            fp(0.3, 0.4, 384, 256),  // 5: same look as A, another shape: alone
            fp(0.7, 0.7, 384, 256),  // 6: group B
            fp(0.3, 0.4, 256, 384),  // 7: group A
        ];
        let shapes = vec![256.0 / 384.0, 256.0 / 384.0, 256.0 / 384.0, 1.0, 1.5, 1.5, 1.5, 256.0 / 384.0];
        assert_eq!(group(&prints, &shapes), vec![vec![0, 2, 7], vec![4, 6]]);
    }
}
