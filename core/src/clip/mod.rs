//! Content search: finding pictures by what they show.
//!
//! A CLIP model turns a picture and a description into vectors that point
//! the same way when one matches the other. `model` computes them, `image`
//! and `tokenizer` prepare its inputs, `store` keeps the pictures' vectors.
//! This file is the service the engine talks to: it embeds a folder's
//! pictures in the background and finds the ones a typed description fits.
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
use std::collections::HashMap;
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

/// Everyday things a picture might show, one to a line. Nobody searches
/// for these: they are the yardstick a search is measured against (see
/// [`Usual`]).
const EVERYDAY: &str = include_str!("everyday.txt");

/// A description matches a picture when it scores this many spreads above
/// the picture's ordinary run of scores (see [`Usual`]).
///
/// Measured, not reasoned, on a library of 4,500 generated pictures with
/// their prompts as the answer key (`examples/content_probe` prints the
/// same for any library):
///
/// * Of 98 everyday words that no prompt mentioned, the typical one turned
///   up in no picture at all at this bar, and plain absent things in a
///   handful (`car` in 12, `airplane` in 3).
/// * The word for what nearly every picture was of was found in 97% of
///   them; things a picture merely contains (a bed, something gold, water)
///   in a tenth to a quarter of the pictures prompted with them, about half
///   of what was found having been prompted for.
/// * A quarter of a spread lower lets several times as many absent things
///   in (`car` in 58). A quarter higher halves what is found, for a few
///   points of accuracy.
/// * Other ways of measuring a fit (rank among the everyday words, the
///   model's own odds, the raw score) told prompted pictures from the rest
///   no better than this one.
pub const CLEAR: f32 = 1.5;

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

/// The vectors of the [`EVERYDAY`] descriptions, end to end.
struct Reference {
    dim: usize,
    vectors: Vec<f32>,
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
    reference: Mutex<Option<Arc<Reference>>>,
    /// What is usual for each picture (see [`usual`]), worked out the first
    /// time it is searched.
    usual: Mutex<HashMap<Key, Usual>>,
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
            reference: Mutex::new(None),
            usual: Mutex::new(HashMap::new()),
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

    /// Every picture under `root`, in `sort` order, each with how well it
    /// fits a description; None for one not looked at yet.
    pub fn rate(&self, root: &str, recursive: bool, text: &str, sort: &str) -> Result<(QueryResult, Vec<Option<Fit>>), String> {
        let inner = &self.inner;
        let query = inner.describe(text)?;
        let reference = inner.reference()?;
        let all = inner.db.query(&Query { dir: root.to_string(), recursive, sort: sort.to_string(), ..Default::default() }).map_err(|e| e.to_string())?;
        let pictures: Vec<Option<(Key, store::Packed)>> = all
            .rows
            .iter()
            .map(|row| {
                let key = inner.key(&all.dirs[row.1 as usize], row);
                inner.vectors.get(&key).filter(|vector| vector.len() == query.len() && vector.len() == reference.dim).map(|vector| (key, vector))
            })
            .collect();
        // What is usual for each picture is the slow part, and does not
        // depend on the search: keep it.
        let known = inner.usual.lock();
        let missing: Vec<&(Key, store::Packed)> = pictures.iter().flatten().filter(|(key, _)| !known.contains_key(key)).collect();
        drop(known);
        if !missing.is_empty() {
            let worked: Vec<(Key, Usual)> = missing.par_iter().map(|(key, vector)| (*key, usual(&reference, vector))).collect();
            inner.usual.lock().extend(worked);
        }
        let known = inner.usual.lock();
        let fits = pictures.iter().map(|picture| picture.as_ref().and_then(|(key, vector)| known.get(key).map(|usual| usual.fit(store::score(&query, vector))))).collect();
        Ok((all, fits))
    }

    /// How the pictures under `root` score against the everyday descriptions.
    pub fn everyday(&self, root: &str, recursive: bool) -> Result<Everyday, String> {
        let inner = &self.inner;
        let reference = inner.reference()?;
        let all = inner.db.query(&Query { dir: root.to_string(), recursive, ..Default::default() }).map_err(|e| e.to_string())?;
        let pictures: Vec<Option<store::Packed>> =
            all.rows.iter().map(|row| inner.vectors.get(&inner.key(&all.dirs[row.1 as usize], row)).filter(|vector| vector.len() == reference.dim)).collect();
        let scores = pictures
            .par_iter()
            .map(|picture| {
                let picture = store::unpack(picture.as_ref()?);
                Some(reference.vectors.chunks_exact(reference.dim).map(|text| store::dot(text, &picture)).collect())
            })
            .collect();
        Ok(Everyday { words: everyday_lines(), all, scores })
    }

    /// The pictures under `root` that match a description: best match first
    /// when `sort` is "relevance", otherwise in that order. `bar` is the
    /// [`Fit::level`] a picture has to reach; None is 1, a match.
    pub fn search(&self, root: &str, recursive: bool, text: &str, sort: &str, bar: Option<f32>) -> Result<QueryResult, String> {
        let (all, fits) = self.rate(root, recursive, text, sort)?;
        let bar = bar.unwrap_or(1.0);
        let mut matched: Vec<(f32, usize)> = fits.iter().enumerate().filter_map(|(i, fit)| fit.map(|fit| fit.level()).filter(|level| *level >= bar).map(|level| (level, i))).collect();
        if sort == "relevance" {
            matched.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)));
        }
        Ok(QueryResult { dirs: all.dirs.clone(), rows: matched.into_iter().map(|(_, i)| all.rows[i].clone()).collect() })
    }
}

/// What is usual for one picture: how the everyday descriptions score
/// against it.
///
/// A model's scores have no fixed meaning. Where they sit and how far apart
/// they lie differs from model to model and from picture to picture: a busy
/// picture is a little like everything, a plain one like nothing much. But
/// whatever a picture shows, most of a few hundred everyday things are
/// *not* in it, so the run of their scores says what "not a match" looks
/// like for this picture.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Usual {
    /// The middle score: the median.
    middle: f32,
    /// How widely the scores spread around it: the median distance from the
    /// middle, scaled so that for bell-shaped scores it is their standard
    /// deviation.
    spread: f32,
}

fn usual(reference: &Reference, picture: &[i16]) -> Usual {
    let picture = store::unpack(picture);
    let mut scores: Vec<f32> = reference.vectors.chunks_exact(reference.dim).map(|text| store::dot(text, &picture)).collect();
    if scores.is_empty() {
        return Usual { middle: 0.0, spread: 0.0 };
    }
    let half = scores.len() / 2;
    let middle = *scores.select_nth_unstable_by(half, f32::total_cmp).1;
    scores.iter_mut().for_each(|score| *score = (*score - middle).abs());
    let spread = *scores.select_nth_unstable_by(half, f32::total_cmp).1 * 1.4826;
    Usual { middle, spread }
}

impl Usual {
    fn fit(&self, score: f32) -> Fit {
        Fit { above: if self.spread > 0.0 { (score - self.middle) / self.spread } else { 0.0 } }
    }
}

/// How well a picture fits a description.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Fit {
    /// How many spreads above the picture's ordinary run of scores the
    /// description landed.
    pub above: f32,
}

impl Fit {
    /// 1 or more is a match (see [`CLEAR`]), and more is a better one.
    pub fn level(&self) -> f32 {
        self.above / CLEAR
    }
}

/// The everyday descriptions and how every picture of a folder scores
/// against each of them: what `examples/content_probe` works from.
pub struct Everyday {
    pub words: Vec<&'static str>,
    pub all: QueryResult,
    /// For each row of `all`, its score against each of `words`; None for a
    /// picture not looked at yet.
    pub scores: Vec<Option<Vec<f32>>>,
}

fn everyday_lines() -> Vec<&'static str> {
    EVERYDAY.lines().map(str::trim).filter(|line| !line.is_empty()).collect()
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
        let side = self.text_side()?;
        let vector = Arc::new(side.encoder.embed(&side.tokenizer.encode(&wanted))?);
        let mut recent = self.recent.lock();
        recent.insert(0, (wanted, vector.clone()));
        recent.truncate(32);
        Ok(vector)
    }

    fn text_side(&self) -> Result<Arc<TextSide>, String> {
        let mut slot = self.text.lock();
        if let Some(side) = slot.as_ref() {
            return Ok(side.clone());
        }
        let side = Arc::new(TextSide { tokenizer: tokenizer::Tokenizer::load(&self.model_dir.join("tokenizer.json"))?, encoder: model::Text::load(&self.model_dir)? });
        *slot = Some(side.clone());
        Ok(side)
    }

    /// The everyday descriptions' vectors: from memory, from the store, or
    /// (once per model, a second or a few) from the model.
    fn reference(&self) -> Result<Arc<Reference>, String> {
        let mut slot = self.reference.lock();
        if let Some(reference) = slot.as_ref() {
            return Ok(reference.clone());
        }
        let lines = everyday_lines();
        let name = format!("{MODEL}/everyday/{:016x}", xxhash_rust::xxh3::xxh3_64(EVERYDAY.as_bytes()));
        let vectors = match self.vectors.texts(&name).filter(|saved| !saved.is_empty() && saved.len() % lines.len() == 0) {
            Some(saved) => saved,
            None => {
                if !self.installed() {
                    return Err("the content search model is not installed".into());
                }
                let side = self.text_side()?;
                let made: Result<Vec<Vec<f32>>, String> = lines.par_iter().map(|line| side.encoder.embed(&side.tokenizer.encode(line))).collect();
                let made = made?.concat();
                // Not saved? Then it is made again next time.
                let _ = self.vectors.put_texts(&name, &made);
                made
            }
        };
        let reference = Arc::new(Reference { dim: vectors.len() / lines.len(), vectors });
        *slot = Some(reference.clone());
        Ok(reference)
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
        // Have the yardstick ready by the time there is something to search.
        let _ = self.reference();
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
    fn everyday_list() {
        let lines: Vec<&str> = EVERYDAY.lines().collect();
        assert!(lines.len() >= 300, "{}", lines.len());
        let mut seen = std::collections::HashSet::new();
        for line in &lines {
            assert!(!line.is_empty() && *line == line.trim() && *line == line.to_lowercase(), "{line:?}");
            assert!(seen.insert(line), "{line} is listed twice");
        }
    }

    /// A unit vector along axis `axis`, tilted `tilt` of the way to `to`.
    fn towards(dim: usize, axis: usize, to: usize, tilt: f32) -> Vec<f32> {
        let mut v = vec![0.0; dim];
        v[axis] = 1.0 - tilt;
        v[to] += tilt;
        let length = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        v.iter().map(|x| x / length).collect()
    }

    #[test]
    fn fitting_a_description() {
        // Forty everyday things, each its own direction with a little of
        // every picture's common ground (the last axis) mixed in.
        let dim = 48;
        let thing = |i: usize| towards(dim, i, dim - 1, 0.2 + (i % 5) as f32 * 0.01);
        let reference = Reference { dim, vectors: (0..40).flat_map(thing).collect() };
        // A picture of things 3, 5 and 8.
        let mut picture = vec![0.0; dim];
        for shown in [3, 5, 8] {
            picture[shown] = 1.0;
        }
        picture[dim - 1] = 1.0;
        let length = picture.iter().map(|x| x * x).sum::<f32>().sqrt();
        let picture = store::pack(&picture.iter().map(|x| x / length).collect::<Vec<_>>());
        let usual = usual(&reference, &picture);
        assert!(usual.middle > 0.02 && usual.spread > 0.0, "{usual:?}");
        let fits = |description: &[f32]| usual.fit(store::score(description, &picture));

        // What it shows matches, whichever of those it is...
        for shown in [3, 5, 8] {
            let fit = fits(&thing(shown));
            assert!(fit.level() >= 1.0 && fit.above > 3.0 * CLEAR, "{shown}: {fit:?}");
        }
        // ...and what it does not show is ordinary.
        for absent in [0, 4, 7, 22, 39] {
            let fit = fits(&thing(absent));
            assert!(fit.level() < 1.0 && fit.above.abs() < CLEAR, "{absent}: {fit:?}");
        }
        // A description that says more of what is there fits better still.
        assert!(fits(&towards(dim, 3, 5, 0.5)).level() > fits(&thing(3)).level());

        // None of this depends on the range the model's scores happen to
        // fall in: halve every score and the fit is what it was.
        let halved = Usual { middle: usual.middle / 2.0, spread: usual.spread / 2.0 };
        let score = store::score(&thing(3), &picture);
        assert!((halved.fit(score / 2.0).level() - usual.fit(score).level()).abs() < 1e-3);
        // Nothing to measure against, or a picture everything scores the
        // same on: nothing fits.
        let nothing = super::usual(&Reference { dim, vectors: Vec::new() }, &picture);
        assert_eq!(nothing.fit(0.3).level(), 0.0);
        assert_eq!(Usual { middle: 0.2, spread: 0.0 }.fit(0.9).level(), 0.0);
    }
}
