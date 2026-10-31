//! Content search: finding pictures by what they show.
//!
//! A CLIP model turns a picture and a description into vectors that point
//! the same way when one matches the other. `model` computes them, `image`
//! and `tokenizer` prepare its inputs, `store` keeps the pictures' vectors.
//! This file is the service the engine talks to: it embeds a folder's
//! pictures in the background and finds the ones a typed description fits.
//!
//! The model is not part of the app. It is three files in
//! `<data dir>/models/<MODEL>`, downloaded once by the UI (see [`FILES`])
//! and then rewritten in the layout the encoders read (see `convert`);
//! until it is there, every request here says so and does nothing else.

pub mod convert;
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

/// The model in use, which is also the name of its folder: CLIP ViT-B/32
/// trained by LAION on DataComp-1B. The size and speed of the original
/// CLIP ViT-B/32 (32-pixel patches), and well ahead of it: 72.7 % on the
/// usual ImageNet zero-shot test, against 63.3 % for OpenAI's and 59.8 %
/// for TinyCLIP ViT-40M/32, which the app used before.
pub const MODEL: &str = "datacomp-clip-vit-b-32";

/// Where the model's files come from.
pub const SOURCE: &str = "https://huggingface.co/laion/CLIP-ViT-B-32-DataComp.XL-s13B-b90K/resolve/main/";

/// The files the model is downloaded as (OpenCLIP's layout), and how many
/// bytes each must be.
pub const FILES: [(&str, u64); 3] = [
    (convert::OPEN_CLIP_CONFIG, 469),
    ("tokenizer.json", 2_224_053),
    (convert::OPEN_CLIP_WEIGHTS, 605_143_284),
];

/// The files the model is read from once converted (Hugging Face's layout).
const READY: [&str; 3] = ["config.json", "tokenizer.json", "model.safetensors"];

/// Models the app used before, removed (with their vectors) once the
/// current one is installed.
const OLD_MODELS: [&str; 1] = ["tinyclip-vit-40m-32-text-19m"];

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
    /// The vectors of prompt phrases checked (see [`ContentSearch::check_prompt`]):
    /// a folder's prompts share most of theirs.
    phrases: Mutex<HashMap<String, Arc<Vec<f32>>>>,
}

/// How many phrase vectors are kept before starting again (about 2 KB each).
const PHRASES_KEPT: usize = 4_000;

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
    /// A file was moved: keep what content search worked out about it
    /// under the new place, so it is not looked at again.
    pub fn moved(&self, from: &str, mtime: i64, size: i64, to: &str, new_mtime: i64, new_size: i64) {
        let old = store::key(MODEL, from, mtime, size);
        let Some(packed) = self.inner.vectors.get(&old) else { return };
        let new = store::key(MODEL, to, new_mtime, new_size);
        let _ = self.inner.vectors.put(&[(new, store::unpack(&packed))], &[]);
    }

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
            phrases: Mutex::new(HashMap::new()),
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

    /// The vector of the picture `row` (in `dir`), if it has been looked at.
    pub fn vector(&self, dir: &str, row: &crate::db::Row) -> Option<Vec<f32>> {
        self.inner.vectors.get(&self.inner.key(dir, row)).map(|v| store::unpack(&v))
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
        Ok(all.pick(matched.into_iter().map(|(_, i)| i)))
    }

    /// For each row of `found`, how clearly (as [`Fit::level`]) the picture
    /// fits each of `phrases`, in order; None for a picture not looked at
    /// yet, and for all of them when the model is not installed.
    pub fn fits(&self, found: &QueryResult, phrases: &[String]) -> Vec<Option<Vec<f32>>> {
        let inner = &self.inner;
        if found.rows.is_empty() || !inner.installed() {
            return vec![None; found.rows.len()];
        }
        let (Ok(reference), Ok(texts)) = (inner.reference(), inner.phrase_vectors(phrases)) else {
            return vec![None; found.rows.len()];
        };
        let pictures: Vec<Option<(Key, store::Packed)>> = found
            .rows
            .iter()
            .map(|row| {
                let key = inner.key(&found.dirs[row.1 as usize], row);
                inner.vectors.get(&key).filter(|vector| vector.len() == reference.dim).map(|vector| (key, vector))
            })
            .collect();
        let known = inner.usual.lock();
        let missing: Vec<&(Key, store::Packed)> = pictures.iter().flatten().filter(|(key, _)| !known.contains_key(key)).collect();
        drop(known);
        if !missing.is_empty() {
            let worked: Vec<(Key, Usual)> = missing.par_iter().map(|(key, vector)| (*key, usual(&reference, vector))).collect();
            inner.usual.lock().extend(worked);
        }
        let known = inner.usual.lock();
        pictures
            .iter()
            .map(|picture| {
                let (key, vector) = picture.as_ref()?;
                let usual = known.get(key)?;
                Some(texts.iter().map(|t| if t.len() == vector.len() { usual.fit(store::score(t.as_slice(), vector)).level() } else { 0.0 }).collect())
            })
            .collect()
    }
}

/// How alike two pictures must be for "more like this": the cosine of
/// their vectors. Measured on generated pictures: variations of one prompt
/// sit around 0.85 to 0.95, pictures of the same kind of thing around 0.7
/// to 0.8, unrelated ones well below.
pub const SIMILAR: f32 = 0.78;

/// However strict [`SIMILAR`] is, "more like this" shows at least this many
/// pictures, as long as they are not plainly unrelated ([`SIMILAR_FLOOR`]).
const SIMILAR_AT_LEAST: usize = 12;
const SIMILAR_FLOOR: f32 = 0.6;

/// Kinds of picture, for describing one: the best fitting is named first.
const STYLES: [&str; 14] = [
    "a photograph",
    "a cinematic film still",
    "a portrait photograph",
    "a landscape photograph",
    "digital art",
    "an anime illustration",
    "a comic book illustration",
    "an oil painting",
    "a watercolor painting",
    "a pencil sketch",
    "a 3d render",
    "pixel art",
    "concept art",
    "a vector illustration",
];

impl ContentSearch {
    /// The pictures of `all` that look like the picture at `target`, most
    /// alike first when `sort` is "relevance", otherwise in `all`'s order.
    /// `bar` overrides [`SIMILAR`].
    pub fn similar(&self, target: &str, all: &QueryResult, sort: &str, bar: Option<f32>) -> Result<QueryResult, String> {
        let inner = &self.inner;
        let wanted = store::unpack(&inner.picture_vector(target)?);
        let bar = bar.unwrap_or(SIMILAR);
        let scored: Vec<(f32, usize)> = all
            .rows
            .iter()
            .enumerate()
            .filter_map(|(i, row)| {
                let vector = inner.vectors.get(&inner.key(&all.dirs[row.1 as usize], row))?;
                (vector.len() == wanted.len()).then(|| (store::score(&wanted, &vector), i))
            })
            .collect();
        let mut best = scored.clone();
        best.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)));
        let mut keep: Vec<(f32, usize)> = best.iter().copied().filter(|(score, _)| *score >= bar).collect();
        if keep.len() < SIMILAR_AT_LEAST {
            let floor = SIMILAR_FLOOR.min(bar);
            keep = best.iter().copied().filter(|(score, _)| *score >= floor).take(SIMILAR_AT_LEAST.max(keep.len())).collect();
        }
        if sort != "relevance" {
            keep.sort_by_key(|(_, i)| *i);
        }
        Ok(all.pick(keep.into_iter().map(|(_, i)| i)))
    }

    /// Describe a picture in words, from what the model sees in it: the
    /// kind of picture it is and the everyday things that stand out in it.
    /// A starting prompt for whatever needs one (a diffusion upscale).
    pub fn describe(&self, path: &str) -> Result<Value, String> {
        let inner = &self.inner;
        let picture = inner.picture_vector(path)?;
        let reference = inner.reference()?;
        let lines = everyday_lines();
        let usual = usual(&reference, &picture);
        let mut seen: Vec<(f32, &str)> = reference
            .vectors
            .chunks_exact(reference.dim)
            .zip(&lines)
            .map(|(text, line)| (usual.fit(store::score(text, &picture)).level(), *line))
            .filter(|(level, _)| *level >= 1.0)
            .collect();
        seen.sort_by(|a, b| b.0.total_cmp(&a.0));
        seen.truncate(8);
        let styles = inner.styles()?;
        let style = styles
            .chunks_exact(reference.dim)
            .zip(STYLES)
            .map(|(text, name)| (store::score(text, &picture), name))
            .max_by(|a, b| a.0.total_cmp(&b.0))
            .map_or("a picture", |(_, name)| name);
        let subjects: Vec<&str> = seen.iter().map(|(_, w)| *w).collect();
        let mut prompt = style.to_string();
        if !subjects.is_empty() {
            prompt.push_str(" of ");
            prompt.push_str(&subjects.join(", "));
        }
        prompt.push_str(", highly detailed, sharp focus, high resolution");
        Ok(json!({ "prompt": prompt, "style": style, "subjects": subjects }))
    }

    /// How well the picture at `path` shows each part of `prompt`: the
    /// prompt cut into phrases (see [`prompt_phrases`]), each scored against
    /// the picture the way a content search is (see [`Usual`]), so a phrase
    /// at level 1 or more is seen in it. Phrases that only ask for quality
    /// ("masterpiece", "8k") are listed but not scored: the model cannot see
    /// them.
    ///
    /// The picture's vector is made now if `make`; otherwise a picture
    /// content search has not looked at yet gives `null`.
    pub fn check_prompt(&self, path: &str, prompt: &str, make: bool) -> Result<Value, String> {
        let inner = &self.inner;
        let phrases = prompt_phrases(prompt);
        let scored: Vec<String> = phrases.iter().filter(|p| !is_quality_phrase(p)).map(|p| p.to_lowercase()).collect();
        if scored.is_empty() {
            let list: Vec<Value> = phrases.iter().map(|p| json!({ "text": p, "checked": false })).collect();
            return Ok(json!({ "phrases": list, "seen": 0, "checked": 0 }));
        }
        let Some(picture) = inner.picture_vector_if(path, make)? else { return Ok(Value::Null) };
        let reference = inner.reference()?;
        let usual = usual(&reference, &picture);
        let vectors = inner.phrase_vectors(&scored)?;
        let mut vectors = vectors.iter();
        let mut seen = 0;
        let list: Vec<Value> = phrases
            .iter()
            .map(|p| {
                if is_quality_phrase(p) {
                    return json!({ "text": p, "checked": false });
                }
                let level = vectors.next().map_or(0.0, |v| usual.fit(store::score(v, &picture)).level());
                if level >= 1.0 {
                    seen += 1;
                }
                json!({ "text": p, "checked": true, "level": (level * 100.0).round() / 100.0, "seen": level >= 1.0 })
            })
            .collect();
        Ok(json!({ "phrases": list, "seen": seen, "checked": scored.len() }))
    }
}

/// What a picture can be described by, beyond the everyday things in it:
/// where it is, what kind of picture it is, and its light. One to a line.
const SETTINGS: &str = include_str!("vocab/setting.txt");
const KINDS: &str = include_str!("vocab/style.txt");
const LIGHTS: &str = include_str!("vocab/light.txt");

/// Of the phrases a group offers, how many are put in the described prompt
/// (those the model clearly sees) and how many more are offered switched
/// off (those it half sees).
const DESCRIBE_ON: usize = 3;
const DESCRIBE_OFF: usize = 2;
/// The level (see [`Fit::level`]) a phrase offered switched off has to reach.
const DESCRIBE_MAYBE: f32 = 0.6;
/// Most of the user's own prompt phrases weighed when describing a picture.
const DESCRIBE_OWN: usize = 300;

/// How finely a heat map divides a picture, each way.
pub const HEAT_GRID: usize = 16;

/// A part of a picture looked at on its own: its edges as fractions of the
/// picture's width and height, and how well it fits what was asked for.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Window {
    pub x0: f32,
    pub y0: f32,
    pub x1: f32,
    pub y1: f32,
    pub score: f32,
}

/// The parts of a picture a heat map looks at: the whole, then three by
/// three windows of half its size, then five by five of a third, each row
/// and column overlapping the next.
pub fn heat_windows() -> Vec<(f32, f32, f32, f32)> {
    let mut out = vec![(0.0, 0.0, 1.0, 1.0)];
    for (size, steps) in [(0.5f32, 3usize), (0.34, 5)] {
        for iy in 0..steps {
            for ix in 0..steps {
                let x0 = (1.0 - size) * ix as f32 / (steps - 1) as f32;
                let y0 = (1.0 - size) * iy as f32 / (steps - 1) as f32;
                out.push((x0, y0, x0 + size, y0 + size));
            }
        }
    }
    out
}

/// Spread the windows' scores over a `grid` × `grid` map, 0 where the
/// picture fits least and 1 where it fits most. Each cell takes the windows
/// that cover its middle, the smaller ones counting for more (they say more
/// precisely where); a window's score counts as how much better it fits
/// than the whole picture does. All zero when nothing stands out.
pub fn heat_grid(windows: &[Window], grid: usize) -> Vec<f32> {
    let whole = windows.iter().find(|w| w.x1 - w.x0 >= 0.999 && w.y1 - w.y0 >= 0.999).map_or(0.0, |w| w.score);
    let mut cells = vec![0.0f32; grid * grid];
    for (i, cell) in cells.iter_mut().enumerate() {
        let (cx, cy) = (((i % grid) as f32 + 0.5) / grid as f32, ((i / grid) as f32 + 0.5) / grid as f32);
        let (mut sum, mut weight) = (0.0, 0.0);
        for w in windows {
            if cx >= w.x0 && cx <= w.x1 && cy >= w.y0 && cy <= w.y1 {
                let area = ((w.x1 - w.x0) * (w.y1 - w.y0)).max(1e-3);
                sum += (w.score - whole) / area;
                weight += 1.0 / area;
            }
        }
        *cell = if weight > 0.0 { sum / weight } else { 0.0 };
    }
    let (lo, hi) = cells.iter().fold((f32::MAX, f32::MIN), |(lo, hi), &v| (lo.min(v), hi.max(v)));
    if hi.is_nan() || lo.is_nan() || hi - lo <= 1e-4 {
        return vec![0.0; grid * grid];
    }
    cells.iter().map(|v| (v - lo) / (hi - lo)).collect()
}

/// The phrases of one group that describe a picture best: up to `on` it
/// clearly shows, then up to `off` it half shows, each with its level.
fn pick_phrases(mut scored: Vec<(f32, String)>, on: usize, off: usize, taken: &mut Vec<String>) -> Vec<Value> {
    scored.sort_by(|a, b| b.0.total_cmp(&a.0));
    let mut out = Vec::new();
    let (mut n_on, mut n_off) = (0, 0);
    for (level, phrase) in scored {
        let key = phrase.trim_start_matches("a ").trim_start_matches("an ").trim_start_matches("the ").to_string();
        if taken.iter().any(|t| t == &key || t.contains(&key) || key.contains(t.as_str())) {
            continue;
        }
        let clear = level >= 1.0;
        if clear && n_on < on {
            n_on += 1;
        } else if level >= DESCRIBE_MAYBE && n_off < off {
            n_off += 1;
        } else {
            continue;
        }
        taken.push(key);
        out.push(json!({ "text": phrase, "level": (level * 100.0).round() / 100.0, "on": clear }));
        if n_on == on && n_off == off {
            break;
        }
    }
    out
}

fn lines(text: &str) -> Vec<String> {
    text.lines().map(str::trim).filter(|l| !l.is_empty()).map(str::to_string).collect()
}

impl ContentSearch {
    /// Describe a picture that carries no prompt of its own, as groups of
    /// phrases (subject, setting, style, light), each phrase with how
    /// clearly the model sees it and whether it belongs in the prompt.
    /// Subjects come from the everyday list and from `own`, phrases of the
    /// user's own prompts, so a description uses the user's words.
    pub fn describe_groups(&self, path: &str, own: &[String]) -> Result<Value, String> {
        let inner = &self.inner;
        let picture = inner.picture_vector(path)?;
        let reference = inner.reference()?;
        let usual = usual(&reference, &picture);
        let level = |v: &[f32]| usual.fit(store::score(v, &picture)).level();
        let groups_text = [("setting", SETTINGS), ("style", KINDS), ("light", LIGHTS)];
        let listed: Vec<String> = groups_text.iter().flat_map(|(_, t)| lines(t)).collect();
        let own: Vec<String> = own
            .iter()
            .map(|p| p.to_lowercase())
            .filter(|p| !is_quality_phrase(p) && p.split_whitespace().count() <= 6 && !listed.contains(p))
            .take(DESCRIBE_OWN)
            .collect();
        let mut subjects: Vec<(f32, String)> = reference.vectors.chunks_exact(reference.dim).zip(everyday_lines()).map(|(v, l)| (level(v), l.to_string())).collect();
        if !own.is_empty() {
            let vectors = inner.phrase_vectors(&own)?;
            // A phrase of the user's says more than an everyday word: it
            // wins a near tie.
            subjects.extend(vectors.iter().zip(&own).map(|(v, p)| (level(v) + 0.1, p.clone())));
        }
        let mut taken = Vec::new();
        let mut groups = vec![json!({ "name": "subject", "phrases": pick_phrases(subjects, DESCRIBE_ON, DESCRIBE_OFF + 1, &mut taken) })];
        for (name, text) in groups_text {
            let list = lines(text);
            let vectors = inner.list_vectors(name, text, &list)?;
            let scored = vectors.chunks_exact(reference.dim).zip(&list).map(|(v, l)| (level(v), l.clone())).collect();
            let (on, off) = if name == "light" { (2, DESCRIBE_OFF) } else { (DESCRIBE_ON, DESCRIBE_OFF) };
            groups.push(json!({ "name": name, "phrases": pick_phrases(scored, on, off, &mut taken) }));
        }
        let prompt: Vec<String> = groups
            .iter()
            .flat_map(|g| g["phrases"].as_array().cloned().unwrap_or_default())
            .filter(|p| p["on"].as_bool() == Some(true))
            .filter_map(|p| p["text"].as_str().map(str::to_string))
            .collect();
        Ok(json!({ "groups": groups, "prompt": prompt.join(", ") }))
    }

    /// The vectors of `texts`, made by the text side of the model.
    pub fn text_vectors(&self, texts: &[String]) -> Result<Vec<Arc<Vec<f32>>>, String> {
        let lowered: Vec<String> = texts.iter().map(|t| t.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()).collect();
        self.inner.phrase_vectors(&lowered)
    }

    /// Whether the model is installed.
    pub fn installed(&self) -> bool {
        self.inner.installed()
    }

    /// Make the model ready once its files are downloaded: rewrite it in
    /// the layout the encoders read (a few seconds, once), then let go of
    /// any model used before, and of its vectors. Answers whether the model
    /// is installed.
    pub fn prepare(&self) -> Result<bool, String> {
        let inner = &self.inner;
        let fresh = !inner.installed();
        if fresh {
            let downloaded = FILES.iter().all(|(name, bytes)| std::fs::metadata(inner.model_dir.join(name)).is_ok_and(|m| m.is_file() && m.len() == *bytes));
            if !downloaded {
                return Ok(false);
            }
            convert::convert(&inner.model_dir)?;
        }
        inner.forget_old_models(fresh);
        Ok(true)
    }

    /// Where in the picture at `path` the model sees `phrase`, or where it
    /// would fit best: a [`HEAT_GRID`]-square map of 0 to 1, row by row from
    /// the top, with how clearly the whole picture shows the phrase.
    pub fn heat(&self, path: &str, phrase: &str) -> Result<Value, String> {
        let inner = &self.inner;
        if !inner.installed() {
            return Err("the content search model is not installed".into());
        }
        let md = std::fs::metadata(path).map_err(|e| format!("cannot read {path}: {e}"))?;
        let mtime = md.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_millis() as i64);
        let jpeg = match inner.thumbs.get(path, mtime, md.len() as i64, 1) {
            Ok(jpeg) => jpeg,
            Err(ThumbError::NeedHost) => return Err("this picture has not been shown yet; open it once and try again".into()),
            Err(ThumbError::Failed(e)) => return Err(e),
        };
        let img = ::image::load_from_memory(&jpeg).map_err(|e| e.to_string())?;
        let (w, h) = (img.width() as f32, img.height() as f32);
        let encoder = model::Vision::load(&inner.model_dir)?;
        let spots = heat_windows();
        let prepared: Result<Vec<Vec<f32>>, String> = spots
            .par_iter()
            .map(|&(x0, y0, x1, y1)| {
                let crop = img.crop_imm((x0 * w) as u32, (y0 * h) as u32, (((x1 - x0) * w) as u32).max(1), (((y1 - y0) * h) as u32).max(1));
                image::prepare(&crop, encoder.image_size)
            })
            .collect();
        let vectors = encoder.embed(&prepared?.concat());
        let wanted = inner.phrase_vectors(&[phrase.to_lowercase()])?;
        let wanted = wanted.first().ok_or("no vector for the phrase")?;
        let windows: Vec<Window> = spots
            .iter()
            .zip(vectors.chunks_exact(encoder.dim))
            .map(|(&(x0, y0, x1, y1), v)| Window { x0, y0, x1, y1, score: store::dot(v, wanted) })
            .collect();
        let level = inner
            .picture_vector_if(path, false)
            .ok()
            .flatten()
            .and_then(|picture| inner.reference().ok().map(|reference| usual(&reference, &picture).fit(store::score(wanted, &picture)).level()));
        Ok(json!({
            "grid": HEAT_GRID,
            "heat": heat_grid(&windows, HEAT_GRID).iter().map(|v| (v * 1000.0).round() / 1000.0).collect::<Vec<f32>>(),
            "level": level.map(|l| (l * 100.0).round() / 100.0),
        }))
    }

    /// For each of `texts`, the judged pictures whose look it describes best
    /// and how well: `samples` are (picture vector, how liked 0 to 1). The
    /// answer is how liked, 0 to 1, weighted by fit over the closest
    /// [`LIKELY_NEIGHBOURS`]; None when nothing was judged.
    pub fn likely(&self, texts: &[String], samples: &[(Vec<f32>, f32)]) -> Result<Vec<Option<f32>>, String> {
        let vectors = self.text_vectors(texts)?;
        Ok(vectors.iter().map(|v| likely_liked(v, samples)).collect())
    }
}

/// How many of the closest judged pictures a text's likely liking is
/// taken from.
pub const LIKELY_NEIGHBOURS: usize = 24;

/// How liked (0 to 1) the judged pictures that `text` (a vector) describes
/// best are, each counted by how well it fits, sharpened so the closest
/// count most.
pub fn likely_liked(text: &[f32], samples: &[(Vec<f32>, f32)]) -> Option<f32> {
    let mut near: Vec<(f32, f32)> = samples.iter().filter(|(v, _)| v.len() == text.len()).map(|(v, t)| (store::dot(v, text), *t)).collect();
    if near.is_empty() {
        return None;
    }
    near.sort_by(|a, b| b.0.total_cmp(&a.0));
    near.truncate(LIKELY_NEIGHBOURS);
    let top = near[0].0;
    let (mut sum, mut weight) = (0.0, 0.0);
    for (score, target) in near {
        let w = (-(top - score) * 40.0).exp();
        sum += w * target;
        weight += w;
    }
    (weight > 0.0).then(|| sum / weight)
}

/// Most phrases checked in one prompt; past these the rest are left out.
const MOST_PHRASES: usize = 40;

/// `prompt` cut into the phrases it asks for, in order, each once: split at
/// commas, full stops, semicolons, line breaks and `BREAK`; with weights
/// (`(red fox:1.2)`, `[snow]`), escapes (`\(`), LoRA and embedding tags
/// taken off; and what is left with a letter in it kept.
pub fn prompt_phrases(prompt: &str) -> Vec<String> {
    // LoRA, hypernetwork and wildcard tags say what was loaded, not what to
    // draw.
    let mut text = String::with_capacity(prompt.len());
    let mut rest = prompt;
    while let Some(at) = rest.find('<') {
        text.push_str(&rest[..at]);
        match rest[at..].find('>') {
            Some(end) => {
                text.push(',');
                rest = &rest[at + end + 1..];
            }
            None => {
                rest = &rest[at + 1..];
            }
        }
    }
    text.push_str(rest);
    let text = text.replace("BREAK", ",");
    // Weights, brackets and escapes first, so a weight's decimal point is
    // not taken for a full stop.
    let mut clean = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            // An escaped bracket is part of the text.
            '\\' => {
                if let Some(next) = chars.next() {
                    clean.push(next);
                }
            }
            '(' | ')' | '[' | ']' | '{' | '}' => clean.push(' '),
            // A weight: `:1.2` up to the bracket.
            ':' => {
                let mut number = String::new();
                while let Some(&d) = chars.peek() {
                    if d.is_ascii_digit() || d == '.' || d == '-' || d == ' ' {
                        number.push(d);
                        chars.next();
                    } else {
                        break;
                    }
                }
                if !number.chars().any(|d| d.is_ascii_digit()) {
                    clean.push(':');
                    clean.push_str(&number);
                }
            }
            '_' => clean.push(' '),
            _ => clean.push(c),
        }
    }
    let mut out: Vec<String> = Vec::new();
    for piece in clean.split(|c: char| matches!(c, ',' | ';' | '.' | '\n' | '\r' | '|')) {
        let words: Vec<&str> = piece.split_whitespace().collect();
        let phrase = words.join(" ");
        let phrase = phrase.trim_matches(|c: char| c.is_whitespace() || matches!(c, '-' | '"' | '\'' | '!' | '?' | '*' | '#' | '/' | ':' | '+')).to_string();
        if !phrase.chars().any(char::is_alphabetic) || phrase.starts_with("embedding") {
            continue;
        }
        if out.iter().any(|known| known.eq_ignore_ascii_case(&phrase)) {
            continue;
        }
        out.push(phrase);
        if out.len() == MOST_PHRASES {
            break;
        }
    }
    out
}

/// Words that ask for quality rather than for anything to be in the
/// picture: a phrase made of only these is not checked.
const QUALITY_WORDS: &[&str] = &[
    "masterpiece", "best", "high", "higher", "highest", "top", "good", "great", "quality", "detailed", "detail", "details",
    "highly", "ultra", "very", "extremely", "super", "hyper", "intricate", "sharp", "focus", "resolution", "res", "highres",
    "absurdres", "hd", "hdr", "uhd", "4k", "8k", "16k", "32k", "raw", "photo", "realistic", "photorealistic", "hyperrealistic",
    "professional", "award", "winning", "trending", "on", "artstation", "pixiv", "deviantart", "amazing", "beautiful",
    "stunning", "perfect", "official", "art", "aesthetic", "aesthetics", "newest", "recent", "score", "up", "source",
    "rating", "safe", "general", "illustration", "wallpaper", "unity", "cg", "rendered", "render", "octane", "unreal", "engine",
    "the", "a", "an", "and", "of", "in", "with",
];

/// Whether `phrase` only asks for quality ("best quality", "8k uhd",
/// "score_9 score_8_up"), which the model has no way to see.
pub fn is_quality_phrase(phrase: &str) -> bool {
    let words: Vec<String> = phrase
        .split(|c: char| c.is_whitespace() || c == '_' || c == '-')
        .filter(|w| !w.is_empty())
        .map(|w| w.to_lowercase())
        .collect();
    !words.is_empty()
        && words.iter().all(|w| {
            QUALITY_WORDS.contains(&w.as_str()) || w.chars().all(|c| c.is_ascii_digit())
        })
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
        READY.iter().all(|name| std::fs::metadata(self.model_dir.join(name)).is_ok_and(|m| m.is_file() && m.len() > 0))
    }

    /// Remove the models used before this one and, when this one has just
    /// been installed (`fresh`), every vector they made: those are of no use
    /// to this model, which embeds the pictures afresh. Tidying, best effort.
    fn forget_old_models(&self, fresh: bool) {
        let Some(models) = self.model_dir.parent() else { return };
        let old: Vec<PathBuf> = OLD_MODELS.iter().map(|m| models.join(m)).filter(|d| d.exists()).collect();
        if old.is_empty() {
            return;
        }
        // Only an old model's vectors can be in the store yet, as nothing
        // has been embedded with this one.
        if fresh {
            let _ = self.vectors.forget_all_but(MODEL);
        }
        for dir in old {
            let _ = std::fs::remove_dir_all(&dir);
        }
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

    /// A picture's vector: as stored, or made now (and stored) if the
    /// folder pass has not got to it yet.
    fn picture_vector(&self, path: &str) -> Result<store::Packed, String> {
        self.picture_vector_if(path, true)?.ok_or_else(|| "this picture has not been looked at yet".to_string())
    }

    /// A picture's vector as stored; when it is not, made now if `make`,
    /// or else None.
    fn picture_vector_if(&self, path: &str, make: bool) -> Result<Option<store::Packed>, String> {
        let md = std::fs::metadata(path).map_err(|e| format!("cannot read {path}: {e}"))?;
        let mtime = md.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_millis() as i64);
        let size = md.len() as i64;
        let key = store::key(MODEL, path, mtime, size);
        if let Some(vector) = self.vectors.get(&key) {
            return Ok(Some(vector));
        }
        if !make {
            return Ok(None);
        }
        if !self.installed() {
            return Err("the content search model is not installed".into());
        }
        let jpeg = match self.thumbs.get(path, mtime, size, 0) {
            Ok(jpeg) => jpeg,
            Err(ThumbError::NeedHost) => return Err("this picture has not been shown yet; open it once and try again".into()),
            Err(ThumbError::Failed(e)) => return Err(e),
        };
        let encoder = model::Vision::load(&self.model_dir)?;
        let img = ::image::load_from_memory(&jpeg).map_err(|e| e.to_string())?;
        let prepared = image::prepare(&img, encoder.image_size)?;
        let vector = encoder.embed(&prepared);
        let vector: Vec<f32> = vector.chunks_exact(encoder.dim).next().ok_or("the model gave nothing back")?.to_vec();
        let _ = self.vectors.put(&[(key, vector.clone())], &[]);
        Ok(Some(store::pack(&vector)))
    }

    /// The vector of each of `phrases`, from the ones kept or from the model.
    fn phrase_vectors(&self, phrases: &[String]) -> Result<Vec<Arc<Vec<f32>>>, String> {
        let missing: Vec<&String> = {
            let kept = self.phrases.lock();
            phrases.iter().filter(|p| !kept.contains_key(*p)).collect()
        };
        if !missing.is_empty() {
            if !self.installed() {
                return Err("the content search model is not installed".into());
            }
            let side = self.text_side()?;
            let made: Result<Vec<(String, Arc<Vec<f32>>)>, String> = missing
                .par_iter()
                .map(|p| side.encoder.embed(&side.tokenizer.encode(p)).map(|v| ((*p).clone(), Arc::new(v))))
                .collect();
            let mut kept = self.phrases.lock();
            if kept.len() > PHRASES_KEPT {
                kept.clear();
            }
            kept.extend(made?);
        }
        let kept = self.phrases.lock();
        phrases.iter().map(|p| kept.get(p).cloned().ok_or_else(|| "a phrase went missing".to_string())).collect()
    }

    /// The vectors of [`STYLES`], end to end.
    fn styles(&self) -> Result<Vec<f32>, String> {
        let name = format!("{MODEL}/styles/{:016x}", xxhash_rust::xxh3::xxh3_64(STYLES.join("\n").as_bytes()));
        if let Some(saved) = self.vectors.texts(&name).filter(|saved| !saved.is_empty() && saved.len() % STYLES.len() == 0) {
            return Ok(saved);
        }
        let side = self.text_side()?;
        let made: Result<Vec<Vec<f32>>, String> = STYLES.par_iter().map(|line| side.encoder.embed(&side.tokenizer.encode(line))).collect();
        let made = made?.concat();
        let _ = self.vectors.put_texts(&name, &made);
        Ok(made)
    }

    /// The vectors of a fixed list of phrases, `list` being `text`'s lines,
    /// end to end: from the store, or made once and stored.
    fn list_vectors(&self, name: &str, text: &str, list: &[String]) -> Result<Vec<f32>, String> {
        let key = format!("{MODEL}/{name}/{:016x}", xxhash_rust::xxh3::xxh3_64(text.as_bytes()));
        if let Some(saved) = self.vectors.texts(&key).filter(|saved| !saved.is_empty() && saved.len() % list.len() == 0) {
            return Ok(saved);
        }
        let side = self.text_side()?;
        let made: Result<Vec<Vec<f32>>, String> = list.par_iter().map(|line| side.encoder.embed(&side.tokenizer.encode(line))).collect();
        let made = made?.concat();
        let _ = self.vectors.put_texts(&key, &made);
        Ok(made)
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
    fn a_prompt_cut_into_what_it_asks_for() {
        assert_eq!(
            prompt_phrases("masterpiece, (a red fox:1.2), [snow], <lora:fur_detail:0.8> misty_forest, a red fox"),
            vec!["masterpiece", "a red fox", "snow", "misty forest"]
        );
        // Prose is cut at its sentences; a weight's point is not one.
        assert_eq!(
            prompt_phrases("A heron stands in a pond. (Soft light:1.15) falls on it; BREAK\nbrass feathers"),
            vec!["A heron stands in a pond", "Soft light falls on it", "brass feathers"]
        );
        // Escaped brackets stay; empty and number-only pieces go.
        assert_eq!(prompt_phrases("Link \\(Zelda\\), , 1.5, embedding:bad_hands"), vec!["Link (Zelda)"]);
        assert!(prompt_phrases("").is_empty());
    }

    #[test]
    fn quality_tags_are_not_checked() {
        for phrase in ["masterpiece", "best quality", "8k uhd", "score_9 score_8_up", "highly detailed", "trending on artstation"] {
            assert!(is_quality_phrase(phrase), "{phrase}");
        }
        for phrase in ["a red fox", "snow", "detailed fur", "golden hour"] {
            assert!(!is_quality_phrase(phrase), "{phrase}");
        }
    }

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

    #[test]
    fn vocabularies() {
        for text in [SETTINGS, KINDS, LIGHTS] {
            let list = lines(text);
            assert!(list.len() >= 25);
            let mut seen = std::collections::HashSet::new();
            for line in &list {
                assert!(*line == line.to_lowercase() && seen.insert(line.clone()), "{line}");
                assert!(!is_quality_phrase(line), "{line} would never be looked for");
            }
        }
    }

    #[test]
    fn heat_falls_where_the_phrase_fits() {
        // Windows that fit best in the top left corner.
        let windows: Vec<Window> = heat_windows()
            .into_iter()
            .map(|(x0, y0, x1, y1)| {
                let (cx, cy) = ((x0 + x1) / 2.0, (y0 + y1) / 2.0);
                Window { x0, y0, x1, y1, score: 0.3 - 0.1 * (cx * cx + cy * cy).sqrt() }
            })
            .collect();
        assert_eq!(windows.len(), 1 + 9 + 25);
        let heat = heat_grid(&windows, HEAT_GRID);
        assert_eq!(heat.len(), HEAT_GRID * HEAT_GRID);
        let at = |x: usize, y: usize| heat[y * HEAT_GRID + x];
        assert!(heat.iter().all(|v| (0.0..=1.0).contains(v)));
        assert!(at(0, 0) > 0.9, "{}", at(0, 0));
        assert!(at(HEAT_GRID - 1, HEAT_GRID - 1) < 0.1);
        assert!(at(2, 2) > at(10, 10));
        // Every window the same: nothing stands out.
        let flat: Vec<Window> = windows.iter().map(|w| Window { score: 0.2, ..*w }).collect();
        assert!(heat_grid(&flat, 8).iter().all(|v| *v == 0.0));
    }

    #[test]
    fn describing_picks_clear_phrases_then_maybes() {
        let scored = vec![
            (2.0, "a red fox".to_string()),
            (1.4, "fox".to_string()),
            (1.2, "snow".to_string()),
            (0.8, "a tree".to_string()),
            (0.3, "a car".to_string()),
        ];
        let mut taken = vec!["snowy field".to_string()];
        let picked = pick_phrases(scored, 2, 2, &mut taken);
        let texts: Vec<&str> = picked.iter().map(|p| p["text"].as_str().unwrap()).collect();
        // "fox" is part of "red fox", "snow" of "snowy field": said already.
        assert_eq!(texts, vec!["a red fox", "a tree"]);
        assert_eq!(picked[0]["on"], true);
        assert_eq!(picked[1]["on"], false);
    }

    #[test]
    fn likely_liking_follows_the_closest_pictures() {
        let dim = 8;
        let axis = |i: usize| (0..dim).map(|j| if j == i { 1.0 } else { 0.0 }).collect::<Vec<f32>>();
        let samples = vec![(axis(0), 1.0), (axis(0), 0.9), (axis(1), 0.0), (axis(1), 0.1)];
        let liked = likely_liked(&axis(0), &samples).unwrap();
        let disliked = likely_liked(&axis(1), &samples).unwrap();
        assert!(liked > 0.85 && disliked < 0.15, "{liked} {disliked}");
        assert_eq!(likely_liked(&axis(0), &[]), None);
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
