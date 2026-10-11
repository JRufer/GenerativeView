//! Content search: finding pictures by what they show.
//!
//! A CLIP model turns a picture and a description into vectors that point
//! the same way when one matches the other. `model` computes them, `image`
//! and `tokenizer` prepare its inputs, `store` keeps the pictures' vectors.
//! This file is the service the engine talks to: it embeds a folder's
//! pictures in the background and ranks them against a typed description.
//!
//! The model is not part of the app. It is three files in
//! `<data dir>/models/<MODEL>`, downloaded once by the UI (see [`FILES`]);
//! until they are there, every request here says so and does nothing else.

pub mod image;
pub mod model;
pub mod store;
pub mod tokenizer;

use crate::db::{Db, Query, QueryResult};
use crate::index::EventSink;
use crate::thumbs::{ThumbError, Thumbs};
use crossbeam_channel::{unbounded, Receiver, RecvTimeoutError, Sender};
use parking_lot::Mutex;
use rayon::prelude::*;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use store::{Key, Vectors};

/// The model in use, which is also the name of its folder. TinyCLIP's
/// 40M-parameter picture encoder with 32-pixel patches and its 19M text
/// encoder: about half the size and twice the speed of the original CLIP
/// ViT-B/32 for nearly the same accuracy.
pub const MODEL: &str = "tinyclip-vit-40m-32-text-19m";

/// Where the model's files come from.
pub const SOURCE: &str = "https://huggingface.co/wkcn/TinyCLIP-ViT-40M-32-Text-19M-LAION400M/resolve/main/";

/// The files that make up the model, and how many bytes each must be.
pub const FILES: [(&str, u64); 3] = [("config.json", 4_602), ("tokenizer.json", 2_224_041), ("model.safetensors", 336_859_508)];

/// Pictures embedded per pass through the model.
const BATCH: usize = 8;
/// The picture encoder is dropped after this long with nothing to do.
const IDLE: Duration = Duration::from_secs(90);

/// A search answers with the closest tenth of the folder's pictures...
const KEEP_ONE_IN: usize = 10;
/// ...or, if there are more of them, with every picture that stands out from
/// the folder's general run of scores by this many standard deviations...
const STAND_OUT: f32 = 2.0;
/// ...but never fewer than this (when there are that many), nor more than this.
const KEEP_AT_LEAST: usize = 24;
const KEEP_AT_MOST: usize = 300;

enum Job {
    Index { root: String, recursive: bool, generation: u64 },
    Close,
}

#[derive(Clone, Default)]
struct Progress {
    root: String,
    running: bool,
    done: usize,
    total: usize,
}

struct TextSide {
    tokenizer: tokenizer::Tokenizer,
    encoder: model::Text,
}

struct Inner {
    model_dir: PathBuf,
    vectors: Vectors,
    db: Arc<Db>,
    thumbs: Arc<Thumbs>,
    sink: EventSink,
    generation: AtomicU64,
    progress: Mutex<Progress>,
    text: Mutex<Option<Arc<TextSide>>>,
    /// The last few descriptions searched for, with their vectors.
    recent: Mutex<Vec<(String, Arc<Vec<f32>>)>>,
}

pub struct ContentSearch {
    inner: Arc<Inner>,
    tx: Sender<Job>,
}

fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

impl ContentSearch {
    pub fn start(data_dir: &Path, db: Arc<Db>, thumbs: Arc<Thumbs>, sink: EventSink) -> Result<ContentSearch, String> {
        let inner = Arc::new(Inner {
            model_dir: data_dir.join("models").join(MODEL),
            vectors: Vectors::open(data_dir)?,
            db,
            thumbs,
            sink,
            generation: AtomicU64::new(0),
            progress: Mutex::new(Progress::default()),
            text: Mutex::new(None),
            recent: Mutex::new(Vec::new()),
        });
        let (tx, rx) = unbounded();
        let worker = inner.clone();
        std::thread::Builder::new().name("gv-content".into()).spawn(move || worker.work(rx)).map_err(|e| e.to_string())?;
        Ok(ContentSearch { inner, tx })
    }

    /// Embed whatever pictures under `root` have not been embedded yet.
    /// Replaces any pass still running, for this folder or another.
    pub fn index(&self, root: &str, recursive: bool) {
        let generation = self.inner.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let _ = self.tx.send(Job::Index { root: root.to_string(), recursive, generation });
    }

    pub fn close(&self) {
        self.inner.generation.fetch_add(1, Ordering::SeqCst);
        let _ = self.tx.send(Job::Close);
    }

    /// Whether the model is here, what fetching it involves, and how far
    /// along the folder's pictures are.
    pub fn status(&self, root: &str, recursive: bool) -> Value {
        let inner = &self.inner;
        let (mut embedded, mut total) = (0, 0);
        if let Ok(all) = inner.db.query(&Query { dir: root.to_string(), recursive, ..Default::default() }) {
            total = all.rows.len();
            embedded = all.rows.iter().filter(|row| inner.vectors.get(&inner.key(&all.dirs[row.1 as usize], row)).is_some()).count();
        }
        let progress = inner.progress.lock().clone();
        let running = progress.running && progress.root == root;
        json!({
            "installed": inner.installed(),
            "model": MODEL,
            "model_dir": inner.model_dir.to_string_lossy(),
            "source": SOURCE,
            "files": FILES.iter().map(|(name, bytes)| json!({ "name": name, "bytes": bytes })).collect::<Vec<_>>(),
            "embedded": embedded,
            "total": total,
            "indexing": running,
            "done": if running { progress.done } else { 0 },
            "todo": if running { progress.total } else { 0 },
        })
    }

    /// The pictures under `root` that best match a description, best first.
    pub fn search(&self, root: &str, recursive: bool, text: &str) -> Result<QueryResult, String> {
        let inner = &self.inner;
        let query = inner.describe(text)?;
        let all = inner.db.query(&Query { dir: root.to_string(), recursive, ..Default::default() }).map_err(|e| e.to_string())?;
        let mut scored: Vec<(f32, usize)> = all
            .rows
            .iter()
            .enumerate()
            .filter_map(|(i, row)| {
                let vector = inner.vectors.get(&inner.key(&all.dirs[row.1 as usize], row))?;
                (vector.len() == query.len()).then(|| (store::score(&query, &vector), i))
            })
            .collect();
        scored.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)));
        scored.truncate(keep(&scored));
        Ok(QueryResult { dirs: all.dirs.clone(), rows: scored.into_iter().map(|(_, i)| all.rows[i].clone()).collect() })
    }
}

/// How many of the best-first `scored` pictures a search answers with.
///
/// The scores say which pictures are closer to the description, not which
/// "match" it, and where they fall depends on the folder: so the answer is
/// a share of the folder, grown to take in everything that clearly stands
/// out, within fixed bounds.
fn keep(scored: &[(f32, usize)]) -> usize {
    let count = scored.len();
    if count <= KEEP_AT_LEAST {
        return count;
    }
    let mean = scored.iter().map(|s| s.0).sum::<f32>() / count as f32;
    let spread = (scored.iter().map(|s| (s.0 - mean) * (s.0 - mean)).sum::<f32>() / count as f32).sqrt();
    let bar = mean + STAND_OUT * spread;
    let standing_out = scored.iter().take_while(|s| s.0 >= bar).count();
    standing_out.max(count / KEEP_ONE_IN).clamp(KEEP_AT_LEAST, KEEP_AT_MOST.min(count))
}

impl Inner {
    fn installed(&self) -> bool {
        FILES.iter().all(|(name, _)| std::fs::metadata(self.model_dir.join(name)).map_or(false, |m| m.is_file() && m.len() > 0))
    }

    fn key(&self, dir: &str, row: &crate::db::Row) -> Key {
        store::key(MODEL, &join(dir, &row.2), row.6, row.7)
    }

    fn emit(&self, root: &str, state: &str, done: usize, total: usize, error: Option<&str>) {
        {
            let mut progress = self.progress.lock();
            *progress = Progress { root: root.to_string(), running: state == "indexing", done, total };
        }
        let mut event = json!({ "t": "content", "root": root, "state": state, "done": done, "total": total });
        if let Some(error) = error {
            event["error"] = json!(error);
        }
        (self.sink)(event.to_string());
    }

    /// The vector for a typed description.
    fn describe(&self, text: &str) -> Result<Arc<Vec<f32>>, String> {
        let wanted = text.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase();
        if let Some(hit) = self.recent.lock().iter().find(|(known, _)| *known == wanted) {
            return Ok(hit.1.clone());
        }
        if !self.installed() {
            return Err("the content search model is not installed".into());
        }
        let side = {
            let mut slot = self.text.lock();
            match slot.as_ref() {
                Some(side) => side.clone(),
                None => {
                    let side = Arc::new(TextSide {
                        tokenizer: tokenizer::Tokenizer::load(&self.model_dir.join("tokenizer.json"))?,
                        encoder: model::Text::load(&self.model_dir)?,
                    });
                    *slot = Some(side.clone());
                    side
                }
            }
        };
        let vector = Arc::new(side.encoder.embed(&side.tokenizer.encode(&wanted))?);
        let mut recent = self.recent.lock();
        recent.insert(0, (wanted, vector.clone()));
        recent.truncate(32);
        Ok(vector)
    }

    fn work(&self, rx: Receiver<Job>) {
        let mut vision: Option<model::Vision> = None;
        loop {
            match rx.recv_timeout(IDLE) {
                Ok(Job::Index { root, recursive, generation }) => {
                    if generation == self.generation.load(Ordering::SeqCst) {
                        self.embed_folder(&mut vision, &root, recursive, generation);
                    }
                }
                // Nothing to do for a while: give the model's memory back.
                Err(RecvTimeoutError::Timeout) => vision = None,
                Ok(Job::Close) | Err(RecvTimeoutError::Disconnected) => break,
            }
        }
    }

    fn embed_folder(&self, vision: &mut Option<model::Vision>, root: &str, recursive: bool, generation: u64) {
        let cancelled = || self.generation.load(Ordering::SeqCst) != generation;
        if !self.installed() {
            self.emit(root, "no_model", 0, 0, None);
            return;
        }
        let all = match self.db.query(&Query { dir: root.to_string(), recursive, ..Default::default() }) {
            Ok(all) => all,
            Err(e) => return self.emit(root, "error", 0, 0, Some(&e.to_string())),
        };
        // Newest first, like the grid: what is on screen gets done first.
        let todo: Vec<(Key, String, i64, i64)> = all
            .rows
            .iter()
            .map(|row| (self.key(&all.dirs[row.1 as usize], row), join(&all.dirs[row.1 as usize], &row.2), row.6, row.7))
            .filter(|(key, ..)| !self.vectors.done(key))
            .collect();
        let total = todo.len();
        if total == 0 {
            return self.emit(root, "done", 0, 0, None);
        }
        if vision.is_none() {
            match model::Vision::load(&self.model_dir) {
                Ok(loaded) => *vision = Some(loaded),
                Err(e) => return self.emit(root, "error", 0, total, Some(&e)),
            }
        }
        let Some(encoder) = vision.as_ref() else { return };
        self.emit(root, "indexing", 0, total, None);
        let mut done = 0;
        for chunk in todo.chunks(BATCH) {
            if cancelled() {
                return;
            }
            // The small thumbnail is all the model needs, and is usually
            // already made.
            let prepared: Vec<Result<Vec<f32>, bool>> = chunk
                .par_iter()
                .map(|(_, path, mtime, size)| match self.thumbs.get(path, *mtime, *size, 0) {
                    Ok(jpeg) => ::image::load_from_memory(&jpeg).ok().and_then(|img| image::prepare(&img, encoder.image_size).ok()).ok_or(false),
                    // A video on Android: there will be a frame once the
                    // grid has shown it. Try again another time.
                    Err(ThumbError::NeedHost) => Err(true),
                    Err(ThumbError::Failed(_)) => Err(false),
                })
                .collect();
            let mut pictures = Vec::with_capacity(chunk.len() * encoder.pixels());
            let mut keys = Vec::new();
            let mut skipped = Vec::new();
            for ((key, ..), result) in chunk.iter().zip(prepared) {
                match result {
                    Ok(picture) => {
                        pictures.extend_from_slice(&picture);
                        keys.push(*key);
                    }
                    Err(later) => {
                        if !later {
                            skipped.push(*key);
                        }
                    }
                }
            }
            let vectors = encoder.embed(&pictures);
            let filed: Vec<(Key, Vec<f32>)> = keys.into_iter().zip(vectors.chunks_exact(encoder.dim)).map(|(key, v)| (key, v.to_vec())).collect();
            if let Err(e) = self.vectors.put(&filed, &skipped) {
                return self.emit(root, "error", done, total, Some(&e));
            }
            done += chunk.len();
            if cancelled() {
                return;
            }
            self.emit(root, "indexing", done, total, None);
        }
        self.emit(root, "done", done, total, None);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeping_what_stands_out() {
        let scored = |values: &[f32]| values.iter().copied().enumerate().map(|(i, v)| (v, i)).collect::<Vec<_>>();
        // A small folder: everything, in order.
        assert_eq!(keep(&scored(&[0.3, 0.2, 0.1])), 3);
        assert_eq!(keep(&[]), 0);
        // Five clear matches among a hundred: those, padded to the minimum.
        let mut values = vec![0.31, 0.3, 0.3, 0.29, 0.29];
        values.extend((0..100).map(|i| 0.15 + (i % 7) as f32 * 0.002));
        assert_eq!(keep(&scored(&values)), KEEP_AT_LEAST);
        // Among five hundred: the closest tenth.
        values.extend((0..400).map(|i| 0.15 + (i % 7) as f32 * 0.002));
        assert_eq!(keep(&scored(&values)), 50);
        // Forty-five that stand out among three hundred: all of them, though
        // that is more than a tenth.
        let mut values = vec![0.3; 45];
        values.extend((0..255).map(|i| 0.15 + (i % 7) as f32 * 0.002));
        assert_eq!(keep(&scored(&values)), 45);
        // A folder that is all one subject still answers with its tenth...
        assert_eq!(keep(&scored(&vec![0.3; 1000])), 100);
        // ...and a big one is capped.
        let mut values = vec![0.3; 900];
        values.extend(vec![0.1; 9000]);
        assert_eq!(keep(&scored(&values)), KEEP_AT_MOST);
    }
}
