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
/// [`fit`]).
const EVERYDAY: &str = include_str!("everyday.txt");

/// A description matches a picture when it clears two bars, both set by
/// how the everyday descriptions score against that same picture.
///
/// It has to stand clear of chance: this many spreads above the picture's
/// ordinary run of scores. Of the descriptions that have nothing to do with
/// a picture, about one in a thousand gets that far.
pub const CLEAR: f32 = 3.0;
/// And it has to suit the picture nearly as well as the things that are in
/// it: this share of the way from the ordinary run up to the picture's best
/// few everyday descriptions. That is what keeps out the merely related: a
/// picture of a dog is a little like "cat" without showing one.
pub const NEARLY: f32 = 0.75;
/// How many of the best-scoring everyday descriptions say what a picture
/// that matches looks like.
const BEST_FEW: usize = 5;

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
/// whatever a picture shows, nearly all of a few hundred everyday things
/// are *not* in it, and a few are. So the run of their scores says what "not
/// a match" looks like for this picture, and the top of it what a match does.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Usual {
    /// The middle score: the median, which the few everyday things that are
    /// in the picture do not move.
    middle: f32,
    /// How widely the scores spread around it: the median distance from the
    /// middle, scaled so that for bell-shaped scores it is their standard
    /// deviation.
    spread: f32,
    /// The average of the best few.
    best: f32,
}

fn usual(reference: &Reference, picture: &[i16]) -> Usual {
    let picture = store::unpack(picture);
    let mut scores: Vec<f32> = reference.vectors.chunks_exact(reference.dim).map(|text| store::dot(text, &picture)).collect();
    if scores.is_empty() {
        return Usual { middle: 0.0, spread: 0.0, best: 0.0 };
    }
    scores.sort_unstable_by(|a, b| b.total_cmp(a));
    let few = BEST_FEW.min(scores.len());
    let best = scores[..few].iter().sum::<f32>() / few as f32;
    let half = scores.len() / 2;
    let middle = scores[half];
    scores.iter_mut().for_each(|score| *score = (*score - middle).abs());
    let spread = *scores.select_nth_unstable_by(half, f32::total_cmp).1 * 1.4826;
    Usual { middle, spread, best }
}

impl Usual {
    fn fit(&self, score: f32) -> Fit {
        let over = score - self.middle;
        let reach = self.best - self.middle;
        Fit { above: if self.spread > 0.0 { over / self.spread } else { 0.0 }, share: if reach > 0.0 { over / reach } else { 0.0 } }
    }
}

/// How well a picture fits a description.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Fit {
    /// How many spreads above the picture's ordinary run of scores the
    /// description landed (see [`CLEAR`]).
    pub above: f32,
    /// How far it got from the ordinary run towards the picture's best
    /// everyday descriptions: 0 is ordinary, 1 is as good as those (see
    /// [`NEARLY`]).
    pub share: f32,
}

impl Fit {
    /// One number for both: 1 or more is a match, and more is a better one.
    pub fn level(&self) -> f32 {
        (self.above / CLEAR).min(self.share / NEARLY)
    }
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
        if !self.installed() {
            return Err("the content search model is not installed".into());
        }
        let lines: Vec<&str> = EVERYDAY.lines().map(str::trim).filter(|line| !line.is_empty()).collect();
        let name = format!("{MODEL}/everyday/{:016x}", xxhash_rust::xxh3::xxh3_64(EVERYDAY.as_bytes()));
        let vectors = match self.vectors.texts(&name).filter(|saved| !saved.is_empty() && saved.len() % lines.len() == 0) {
            Some(saved) => saved,
            None => {
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
        // A picture of things 3, 5, 8, 13 and 21 in equal parts, with a
        // trace of thing 4.
        let mut picture = vec![0.0; dim];
        for shown in [3, 5, 8, 13, 21] {
            picture[shown] = 1.0;
        }
        picture[4] = 0.3;
        picture[dim - 1] = 1.0;
        let length = picture.iter().map(|x| x * x).sum::<f32>().sqrt();
        let picture = store::pack(&picture.iter().map(|x| x / length).collect::<Vec<_>>());
        let usual = usual(&reference, &picture);
        assert!(usual.middle > 0.02 && usual.spread > 0.0 && usual.best > usual.middle + 5.0 * usual.spread, "{usual:?}");
        let fits = |description: &[f32]| usual.fit(store::score(description, &picture));

        // What it shows matches, whichever of those it is...
        for shown in [3, 5, 8, 13, 21] {
            let fit = fits(&thing(shown));
            assert!(fit.level() >= 1.0 && fit.above > CLEAR && (fit.share - 1.0).abs() < 0.1, "{shown}: {fit:?}");
        }
        // ...what it does not show is ordinary...
        for absent in [0, 7, 22, 39] {
            let fit = fits(&thing(absent));
            assert!(fit.level() < 0.5 && fit.above.abs() < CLEAR && fit.share.abs() < 0.2, "{absent}: {fit:?}");
        }
        // ...and what is only faintly there stands clear of chance, but is
        // nowhere near as good as the real thing: not a match.
        let trace = fits(&thing(4));
        assert!(trace.above > CLEAR && trace.share < NEARLY && trace.level() < 1.0, "{trace:?}");
        // A description that says more scores higher still.
        let both = fits(&towards(dim, 3, 5, 0.5));
        assert!(both.share > 1.1 && both.level() > fits(&thing(3)).level(), "{both:?}");

        // None of this depends on the range the model's scores happen to
        // fall in: halve every score and the fit is what it was.
        let halved = Usual { middle: usual.middle / 2.0, spread: usual.spread / 2.0, best: usual.best / 2.0 };
        let score = store::score(&thing(4), &picture);
        assert!((halved.fit(score / 2.0).level() - usual.fit(score).level()).abs() < 1e-3);
        // Nothing to measure against, or a picture everything scores the
        // same on: nothing fits.
        let nothing = super::usual(&Reference { dim, vectors: Vec::new() }, &picture);
        assert_eq!(nothing.fit(0.3).level(), 0.0);
        assert_eq!(Usual { middle: 0.2, spread: 0.0, best: 0.2 }.fit(0.9).level(), 0.0);
    }
}
