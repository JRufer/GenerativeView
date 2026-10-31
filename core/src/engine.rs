//! The engine: everything the UI can ask for, independent of how it asks.
//! `ffi` wraps this for Dart; tests and the CLI tools call it directly.

use crate::clip::ContentSearch;
use crate::db::{Db, Query};
use crate::fsnav;
use crate::index::{normalize, EventSink, Indexer};
use crate::meta;
use crate::notes::{Change, Flag, Notes};
use crate::thumbs::Thumbs;
use serde_json::{json, Value};
use std::path::Path;
use rayon::prelude::*;
use std::sync::Arc;

/// A reply is JSON text, except where the UI wants raw bytes.
pub enum Reply {
    Json(String),
    Bytes(Vec<u8>),
}

pub struct Engine {
    pub db: Arc<Db>,
    pub thumbs: Arc<Thumbs>,
    pub indexer: Indexer,
    pub content: ContentSearch,
    pub notes: Arc<Notes>,
    pub dupes: crate::dupes::Duplicates,
    data_dir: std::path::PathBuf,
    sink: crate::index::EventSink,
    /// Upscales under way; one that is taken out of here stops.
    upscales: Arc<parking_lot::Mutex<Vec<u64>>>,
    /// The model of the user's taste, with a fingerprint of the ratings it
    /// learned from: fitted again only when they change.
    taste: parking_lot::Mutex<Option<(u64, Arc<Taste>)>>,
    /// MOCKUP: audience levels the user set by hand, by path. The real ones
    /// belong in the folder's notes file.
    audience_own: parking_lot::Mutex<std::collections::HashMap<String, crate::audience::Level>>,
    /// Prompt levels already worked out, by (id, mtime).
    audience_cache: parking_lot::Mutex<std::collections::HashMap<(i64, i64), crate::audience::Level>>,
}

/// The taste model, or why there is none yet, with how many of the
/// pictures the user judged have been looked at by content search.
pub struct Taste {
    pub model: Result<crate::taste::Model, crate::taste::NotYet>,
    pub judged: usize,
    pub seen: usize,
}

static NEXT_JOB: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

fn str_arg<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    args.get(key).and_then(Value::as_str).ok_or_else(|| format!("missing argument: {key}"))
}

/// A model as the index keys it (see `GenInfo::facets_text`).
fn model_key(name: &str) -> String {
    meta::facet_value("model", name).to_lowercase()
}

fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

fn bool_arg(args: &Value, key: &str) -> bool {
    args.get(key).and_then(Value::as_bool).unwrap_or(false)
}

impl Engine {
    pub fn open(data_dir: &Path, cache_dir: &Path, sink: EventSink) -> Result<Engine, String> {
        let db = Arc::new(Db::open(data_dir).map_err(|e| format!("cannot open index database: {e}"))?);
        let thumbs = Thumbs::start(cache_dir);
        let content = ContentSearch::start(data_dir, db.clone(), thumbs.clone(), sink.clone())?;
        let notes = Arc::new(Notes::new());
        let indexer = Indexer::start(db.clone(), notes.clone(), sink.clone());
        let dupes = crate::dupes::Duplicates::open(data_dir);
        Ok(Engine { db, thumbs, indexer, content, notes, dupes, data_dir: data_dir.to_path_buf(), sink, upscales: Default::default(), taste: Default::default(), audience_own: Default::default(), audience_cache: Default::default() })
    }

    pub fn close(&self) {
        self.content.close();
        self.indexer.close();
        self.thumbs.close();
    }

    fn query_args(args: &Value) -> Result<Query, String> {
        Ok(Query {
            dir: normalize(str_arg(args, "dir")?),
            recursive: bool_arg(args, "recursive"),
            text: args.get("text").and_then(Value::as_str).unwrap_or("").to_string(),
            sort: args.get("sort").and_then(Value::as_str).unwrap_or("newest").to_string(),
            then: args.get("then").and_then(Value::as_str).unwrap_or("").to_string(),
        })
    }

    /// A metadata search; with a `similar:<path>` term in it, only the
    /// matches that look like that picture, most alike first; with
    /// `is:duplicate`, only those that have a near-duplicate among the
    /// matches, each group together.
    fn search(&self, args: &Value) -> Result<crate::db::QueryResult, String> {
        let found = self.search_plain(args)?;
        let text = args.get("text").and_then(Value::as_str).unwrap_or("");
        let sort = args.get("sort").and_then(Value::as_str).unwrap_or("newest");
        if crate::db::wants_duplicates(text) {
            // Duplicates stay in their groups, whatever the order asked for.
            let groups = self.dupes.only_duplicates(&self.thumbs, &found);
            return Ok(self.with_audience(self.by_taste(groups, "", text), text));
        }
        Ok(self.with_audience(self.by_taste(found, sort, text), text))
    }

    fn audience_source(&self) -> crate::audience::Source {
        crate::audience::Source::parse(self.db.get_setting(crate::audience::SOURCE_SETTING).as_deref())
    }

    /// Each row's audience level, as the user has chosen to judge it.
    fn audience_levels(&self, found: &crate::db::QueryResult) -> Vec<crate::audience::Level> {
        use crate::audience::{decide, from_prompt, Level};
        let source = self.audience_source();
        let missing: Vec<i64> = {
            let cache = self.audience_cache.lock();
            found.rows.iter().filter(|r| !cache.contains_key(&(r.0, r.6))).map(|r| r.0).collect()
        };
        if !missing.is_empty() {
            let prompts = self.db.prompts(&missing).unwrap_or_default();
            let mut cache = self.audience_cache.lock();
            for r in found.rows.iter().filter(|r| missing.contains(&r.0)) {
                let level = prompts.get(&r.0).map_or(Level::Unknown, |p| from_prompt(p).0);
                cache.insert((r.0, r.6), level);
            }
        }
        let cache = self.audience_cache.lock();
        let own = self.audience_own.lock();
        found
            .rows
            .iter()
            .map(|r| {
                let prompt = cache.get(&(r.0, r.6)).copied().unwrap_or_default();
                // The picture side is not built yet: no image score.
                decide(source, None, prompt, own.get(&join(&found.dirs[r.1 as usize], &r.2)).copied())
            })
            .collect()
    }

    /// `found` with each row's audience level in its mark (bits 5 to 7),
    /// narrowed by an `audience:` term in `text`.
    fn with_audience(&self, mut found: crate::db::QueryResult, text: &str) -> crate::db::QueryResult {
        let levels = self.audience_levels(&found);
        found.marks.resize(found.rows.len(), 0);
        for (m, l) in found.marks.iter_mut().zip(&levels) {
            *m = (*m & 0x1f) | (*l as u8) << 5;
        }
        match crate::db::audience_term(text) {
            Some(want) => {
                let keep: Vec<usize> = (0..found.rows.len()).filter(|&i| want.takes(levels[i])).collect();
                found.pick(keep)
            }
            None => found,
        }
    }

    /// The taste model, fitted to what the user has rated and flagged
    /// across every folder, kept until that changes.
    pub fn taste(&self) -> Arc<Taste> {
        use std::hash::{Hash, Hasher};
        let all = self.db.query(&Query { dir: String::new(), recursive: true, ..Default::default() }).unwrap_or_default();
        let mut samples: Vec<crate::taste::Sample> = Vec::new();
        let mut print = std::collections::hash_map::DefaultHasher::new();
        let mut judged = 0;
        for (i, row) in all.rows.iter().enumerate() {
            let mark = all.marks.get(i).copied().unwrap_or(0);
            let Some(target) = crate::taste::target(mark & 7, (mark >> 3) & 3) else { continue };
            judged += 1;
            let Some(vector) = self.content.vector(&all.dirs[row.1 as usize], row) else { continue };
            (row.0, mark, row.6, row.7).hash(&mut print);
            samples.push(crate::taste::Sample { vector, target });
        }
        // Vectors from another model, should there ever be one, are left out.
        if let Some(dim) = samples.first().map(|s| s.vector.len()) {
            samples.retain(|s| s.vector.len() == dim);
        }
        let print = print.finish();
        if let Some((known, taste)) = &*self.taste.lock() {
            if *known == print {
                return taste.clone();
            }
        }
        let taste = Arc::new(Taste { seen: samples.len(), judged, model: crate::taste::fit(&samples) });
        *self.taste.lock() = Some((print, taste.clone()));
        taste
    }

    /// `found` narrowed by a `taste:` term in `text` (to the pictures not
    /// yet judged that the model suggests keeping or rejecting) and, when
    /// `sort` is "taste", best liked first; pictures not looked at yet last.
    fn by_taste(&self, found: crate::db::QueryResult, sort: &str, text: &str) -> crate::db::QueryResult {
        let want = crate::db::taste_term(text);
        if want.is_none() && sort != "taste" {
            return found;
        }
        let taste = self.taste();
        let Ok(model) = &taste.model else {
            // No model yet: nothing to suggest, and the order as it was.
            return if want.is_some() { found.pick(std::iter::empty()) } else { found };
        };
        let scores: Vec<f32> = found
            .rows
            .iter()
            .map(|row| self.content.vector(&found.dirs[row.1 as usize], row).map_or(f32::NAN, |v| model.score(&v)))
            .collect();
        let mut keep: Vec<usize> = (0..found.rows.len()).collect();
        if let Some(want) = want {
            keep.retain(|&i| found.marks.get(i).copied().unwrap_or(0) == 0 && model.verdict(scores[i]) == want);
        }
        if sort == "taste" {
            keep.sort_by(|&a, &b| match (scores[a].is_nan(), scores[b].is_nan()) {
                (false, false) => scores[b].total_cmp(&scores[a]).then(a.cmp(&b)),
                (true, false) => std::cmp::Ordering::Greater,
                (false, true) => std::cmp::Ordering::Less,
                (true, true) => a.cmp(&b),
            });
        }
        found.pick(keep)
    }

    /// What the taste model is, for the UI: how much it learned from and
    /// how far to trust it, or what it still needs.
    fn taste_status(&self) -> Value {
        let taste = self.taste();
        let mut out = match &taste.model {
            Ok(m) => json!({
                "ready": true,
                "useful": m.useful(),
                "learned_from": m.learned_from,
                "liked": m.liked,
                "disliked": m.disliked,
                "agreement": m.agreement,
            }),
            Err(n) => json!({ "ready": false, "liked": n.liked, "disliked": n.disliked }),
        };
        out["needs"] = json!(crate::taste::AT_LEAST);
        out["judged"] = json!(taste.judged);
        out["seen"] = json!(taste.seen);
        out
    }

    /// What the taste model makes of the picture at `path`: stars it would
    /// likely get and whether it looks like a keeper or a reject. Null when
    /// there is no model yet or the picture has not been looked at.
    fn taste_score(&self, path: &str) -> Value {
        let path = normalize(path);
        let (dir, name) = match path.rfind('/') {
            Some(0) => ("/".to_string(), path[1..].to_string()),
            Some(i) => (path[..i].to_string(), path[i + 1..].to_string()),
            None => return Value::Null,
        };
        let taste = self.taste();
        let Ok(model) = &taste.model else { return Value::Null };
        let Ok(found) = self.db.query(&Query { dir: dir.clone(), recursive: false, ..Default::default() }) else { return Value::Null };
        let Some(row) = found.rows.iter().find(|row| row.2 == name) else { return Value::Null };
        let Some(vector) = self.content.vector(&dir, row) else { return Value::Null };
        let score = model.score(&vector);
        if score.is_nan() {
            return Value::Null;
        }
        let verdict = match model.verdict(score) {
            crate::taste::Verdict::Keep => "keep",
            crate::taste::Verdict::Reject => "reject",
            crate::taste::Verdict::Unsure => "unsure",
        };
        json!({ "stars": model.stars(score), "verdict": verdict, "useful": model.useful() })
    }

    /// Every indexed picture's recipe, across all folders: the user's
    /// ratings are theirs wherever the pictures are.
    fn all_recipes(&self) -> Vec<crate::works::Recipe> {
        self.db.recipes("", true, "").unwrap_or_default()
    }

    /// The phrases of the user's prompts that turn up in at least two of
    /// them, most used first.
    fn own_phrases(recipes: &[crate::works::Recipe], top: usize) -> Vec<String> {
        let mut counts: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
        for r in recipes {
            for p in crate::clip::prompt_phrases(&r.prompt) {
                *counts.entry(p.to_lowercase()).or_insert(0) += 1;
            }
        }
        let mut list: Vec<(String, u32)> = counts.into_iter().filter(|(p, n)| *n >= 2 && !crate::clip::is_quality_phrase(p)).collect();
        list.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        list.into_iter().take(top).map(|(p, _)| p).collect()
    }

    fn describe_groups(&self, path: &str) -> Result<String, String> {
        let own = Self::own_phrases(&self.all_recipes(), 300);
        Ok(self.content.describe_groups(&normalize(path), &own)?.to_string())
    }

    fn prompt_doctor(&self, args: &Value) -> Result<String, String> {
        let path = normalize(str_arg(args, "path")?);
        let prompt = str_arg(args, "prompt")?;
        let check = if self.content.installed() { self.content.check_prompt(&path, prompt, false).unwrap_or(Value::Null) } else { Value::Null };
        let model = model_key(args.get("model").and_then(Value::as_str).unwrap_or(""));
        Ok(crate::works::doctor(prompt, &check, &self.all_recipes(), &model).to_string())
    }

    /// Every judged picture content search has looked at, as (its vector,
    /// how liked 0 to 1).
    fn judged_vectors(&self) -> Vec<(Vec<f32>, f32)> {
        let all = self.db.query(&Query { dir: String::new(), recursive: true, ..Default::default() }).unwrap_or_default();
        all.rows
            .iter()
            .enumerate()
            .filter_map(|(i, row)| {
                let mark = all.marks.get(i).copied().unwrap_or(0);
                let target = crate::taste::target(mark & 7, (mark >> 3) & 3)?;
                Some((self.content.vector(&all.dirs[row.1 as usize], row)?, target))
            })
            .collect()
    }

    /// New recipes mixed from two to four pictures, the likeliest liked
    /// first (see [`crate::works::breed`]).
    fn breed(&self, args: &Value) -> Result<String, String> {
        let paths: Vec<String> = args.get("paths").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).map(normalize).collect()).unwrap_or_default();
        if paths.len() < 2 {
            return Err("pick two to four pictures to breed".into());
        }
        let infos: Vec<meta::GenInfo> = paths.iter().map(|p| meta::extract(Path::new(p))).collect();
        let parents: Vec<crate::works::Parent> = infos
            .iter()
            .map(|info| {
                let param = |names: &[&str]| info.params.iter().find(|(k, _)| names.contains(&k.to_ascii_lowercase().as_str())).and_then(|(_, v)| v.trim().parse::<f64>().ok());
                crate::works::Parent {
                    phrases: crate::clip::prompt_phrases(&info.prompt),
                    loras: info.loras.iter().filter_map(|l| l.weight.map(|w| (l.name.clone(), w))).collect(),
                    steps: param(&["steps"]),
                    cfg: param(&["cfg", "cfg scale"]),
                }
            })
            .collect();
        let mix = args.get("mix").cloned().unwrap_or(Value::Null);
        let flag = |name: &str, default: bool| mix.get(name).and_then(Value::as_bool).unwrap_or(default);
        let mix = crate::works::Mix { phrases: flag("phrases", true), loras: flag("loras", true), settings: flag("settings", true), model: flag("model", false) };
        let change = args.get("change").and_then(Value::as_f64).unwrap_or(0.35) as f32;
        let count = args.get("count").and_then(Value::as_u64).unwrap_or(6).clamp(1, 12) as usize;
        let seed = args.get("seed").and_then(Value::as_u64).unwrap_or(1);
        // New phrases come from what the user's liked pictures share.
        let recipes = self.all_recipes();
        let model = model_key(&infos[0].model);
        let works = crate::works::what_works(&recipes, &model);
        let mut fresh: Vec<String> = works["groups"][0]["items"].as_array().map(|a| a.iter().filter_map(|i| i["label"].as_str().map(str::to_string)).collect()).unwrap_or_default();
        if fresh.len() < 6 {
            let more: Vec<String> = Self::own_phrases(&recipes, 40).into_iter().filter(|p| !fresh.contains(p)).take(12).collect();
            fresh.extend(more);
        }
        // Make more than asked for, and keep the likeliest liked.
        let children = crate::works::breed(&parents, mix, change, &fresh, count * 2, seed);
        let samples = if self.content.installed() { self.judged_vectors() } else { Vec::new() };
        let likely: Vec<Option<f32>> = if samples.is_empty() {
            vec![None; children.len()]
        } else {
            self.content.likely(&children.iter().map(|c| c.prompt()).collect::<Vec<_>>(), &samples).unwrap_or_else(|_| vec![None; children.len()])
        };
        let mut ranked: Vec<(Option<f32>, &crate::works::Child)> = likely.into_iter().zip(&children).collect();
        ranked.sort_by(|a, b| b.0.unwrap_or(-1.0).total_cmp(&a.0.unwrap_or(-1.0)));
        ranked.truncate(count);
        Ok(json!({
            "paths": paths,
            "rated": !samples.is_empty(),
            "children": ranked.iter().map(|(l, c)| c.to_json(*l)).collect::<Vec<_>>(),
        })
        .to_string())
    }

    /// The groups of near-duplicates a duplicates search shows, each with
    /// the one to keep and why (see [`crate::works::best_of`]).
    /// With `only` (a list of paths), those pictures are taken as one group,
    /// whatever they look like: the best of a batch.
    fn duplicate_groups(&self, args: &Value) -> Result<String, String> {
        let only: Option<Vec<String>> = args.get("only").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).map(normalize).collect());
        let (found, groups) = match &only {
            Some(paths) => {
                let mut plain = args.clone();
                plain["text"] = json!("");
                let found = self.search_plain(&plain)?;
                let group: Vec<usize> = (0..found.rows.len()).filter(|&i| paths.contains(&join(&found.dirs[found.rows[i].1 as usize], &found.rows[i].2))).collect();
                (found, if group.len() >= 2 { vec![group] } else { Vec::new() })
            }
            None => {
                let found = self.search_plain(args)?;
                let groups = self.dupes.groups(&self.thumbs, &found);
                (found, groups)
            }
        };
        let taste = self.taste();
        let installed = self.content.installed();
        let out: Vec<Value> = groups
            .iter()
            .map(|group| {
                let members: Vec<crate::works::Member> = group
                    .par_iter()
                    .map(|&i| {
                        let row = &found.rows[i];
                        let dir = &found.dirs[row.1 as usize];
                        let path = join(dir, &row.2);
                        let mark = found.marks.get(i).copied().unwrap_or(0);
                        let likely = taste.model.as_ref().ok().and_then(|m| {
                            let v = self.content.vector(dir, row)?;
                            let s = m.score(&v);
                            (!s.is_nan()).then(|| m.stars(s))
                        });
                        let seen = if installed {
                            let prompt = meta::extract(Path::new(&path)).prompt;
                            self.content.check_prompt(&path, &prompt, false).ok().filter(|c| !c.is_null()).and_then(|c| Some((c["seen"].as_u64()? as u32, c["checked"].as_u64()? as u32)))
                        } else {
                            None
                        };
                        let sharpness = self.thumbs.get(&path, row.6, row.7, 0).ok().and_then(|jpeg| image::load_from_memory(&jpeg).ok()).map(|img| crate::works::sharpness(&img));
                        crate::works::Member { rating: Some(mark & 7), kept: (mark >> 3) & 3 == 1, rejected: (mark >> 3) & 3 == 2, likely, seen, sharpness }
                    })
                    .collect();
                let (best, why) = crate::works::best_of(&members);
                let paths: Vec<String> = group.iter().map(|&i| join(&found.dirs[found.rows[i].1 as usize], &found.rows[i].2)).collect();
                json!({ "paths": paths, "best": best, "why": why })
            })
            .collect();
        Ok(Value::Array(out).to_string())
    }

    fn search_plain(&self, args: &Value) -> Result<crate::db::QueryResult, String> {
        let query = Self::query_args(args)?;
        let similar = crate::db::similar_target(&query.text);
        let Some(target) = similar else {
            return self.db.query(&query).map_err(|e| e.to_string());
        };
        // Everything else in the search, in the order asked for; then the
        // look-alikes among it.
        let sort = query.sort.clone();
        let plain = Query { sort: if sort == "relevance" { query.then.clone() } else { sort.clone() }, ..query };
        let all = self.db.query(&plain).map_err(|e| e.to_string())?;
        let bar = args.get("bar").and_then(Value::as_f64).map(|bar| bar as f32);
        self.content.similar(&target, &all, &sort, bar)
    }

    /// Upscale the picture at `path` with `model` by `factor` (2 or 4) in the
    /// background, and save it beside the original with its `metadata`
    /// (strip or copy). Answers at once with a job number; how it goes is
    /// told as `upscale` events with that number.
    fn start_upscale(&self, args: &Value) -> Result<String, String> {
        let path = std::path::PathBuf::from(str_arg(args, "path")?);
        let info = crate::sr::model_info(str_arg(args, "model")?).ok_or("unknown upscale model")?;
        let factor = args.get("factor").and_then(Value::as_u64).unwrap_or(4) as u32;
        if factor != 2 && factor != 4 {
            return Err("the factor is 2 or 4".into());
        }
        let metadata = crate::upscale::Metadata::parse(args.get("metadata").and_then(Value::as_str).unwrap_or("copy")).ok_or("metadata is strip or copy")?;
        let model_path = crate::sr::model_dir(&self.data_dir).join(info.file);
        let job = NEXT_JOB.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.upscales.lock().push(job);
        let (sink, jobs) = (self.sink.clone(), self.upscales.clone());
        let source = path.to_string_lossy().into_owned();
        std::thread::Builder::new()
            .name("gv-upscale".into())
            .spawn(move || {
                let emit = |state: &str, extra: Value| {
                    let mut event = json!({ "t": "upscale", "job": job, "source": source, "state": state });
                    if let (Value::Object(e), Value::Object(x)) = (&mut event, extra) {
                        e.extend(x);
                    }
                    sink(event.to_string());
                };
                let run = || -> Result<std::path::PathBuf, String> {
                    let model = crate::sr::Upscaler::load(&model_path)?;
                    let picture = image::ImageReader::open(&path)
                        .map_err(|e| e.to_string())?
                        .with_guessed_format()
                        .map_err(|e| e.to_string())?
                        .decode()
                        .map_err(|e| format!("cannot read the picture: {e}"))?;
                    let mut last = std::time::Instant::now() - std::time::Duration::from_secs(1);
                    let big = crate::sr::upscale_picture(&model, &picture, factor, &mut |done, total| {
                        if last.elapsed().as_millis() >= 200 || done == total {
                            last = std::time::Instant::now();
                            emit("running", json!({ "done": done, "total": total }));
                        }
                        jobs.lock().contains(&job)
                    })?;
                    crate::upscale::save(&path, &big, metadata)
                };
                match run() {
                    Ok(dest) => emit("done", json!({ "path": dest.to_string_lossy() })),
                    Err(e) if !jobs.lock().contains(&job) => emit("cancelled", json!({ "error": e })),
                    Err(e) => emit("error", json!({ "error": e })),
                }
                jobs.lock().retain(|j| *j != job);
            })
            .map_err(|e| e.to_string())?;
        Ok(json!({ "job": job }).to_string())
    }

    /// Change the notes of the pictures at `paths`: `rating` (0 to 5),
    /// `flag` (keep, reject or none), collections to `add` and `remove`.
    /// Answers with each picture's notes as they now are.
    fn set_notes(&self, args: &Value) -> Result<String, String> {
        let paths: Vec<&str> = args.get("paths").and_then(Value::as_array).ok_or("missing argument: paths")?.iter().filter_map(Value::as_str).collect();
        let names = |key: &str| -> Vec<String> {
            args.get(key).and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect()).unwrap_or_default()
        };
        let change = Change {
            rating: args.get("rating").and_then(Value::as_u64).map(|r| r.min(crate::notes::MAX_RATING as u64) as u8),
            flag: match args.get("flag").and_then(Value::as_str) {
                Some(text) => Some(Flag::parse(text).ok_or_else(|| format!("not a flag: {text}"))?),
                None => None,
            },
            add: names("add"),
            remove: names("remove"),
        };
        // One write per folder.
        let mut by_dir: Vec<(String, Vec<String>, Vec<usize>)> = Vec::new();
        for (i, path) in paths.iter().enumerate() {
            let (dir, name) = split_path(path)?;
            match by_dir.iter_mut().find(|(d, ..)| *d == dir) {
                Some((_, names, at)) => {
                    names.push(name);
                    at.push(i);
                }
                None => by_dir.push((dir, vec![name], vec![i])),
            }
        }
        let mut out = vec![Value::Null; paths.len()];
        for (dir, names, at) in by_dir {
            let notes = self.notes.change(&self.db, &dir, &names, &change)?;
            for (i, note) in at.into_iter().zip(notes) {
                out[i] = note.to_json();
            }
        }
        Ok(Value::Array(out).to_string())
    }

    /// A picture was deleted (or moved to the trash): drop it from the
    /// index, and its stars, flag and collections from its folder's notes,
    /// so it stops counting anywhere.
    fn forget(&self, path: &str) -> Result<String, String> {
        let (dir, name) = split_path(path)?;
        let note = self.db.note(&dir, &name);
        if !note.is_empty() {
            let change = Change { rating: Some(0), flag: Some(Flag::None), add: Vec::new(), remove: note.collections.clone() };
            self.notes.change(&self.db, &dir, std::slice::from_ref(&name), &change)?;
        }
        self.db.delete_path(&dir, &name).map_err(|e| e.to_string())?;
        Ok("null".into())
    }

    /// Take every picture out of the collection `name`, which then no
    /// longer exists. The pictures themselves are left alone. Returns how
    /// many were in it.
    fn delete_collection(&self, name: &str) -> Result<String, String> {
        let members = self.db.collection_members(name).map_err(|e| e.to_string())?;
        let count = members.len();
        // One write per folder, removing each spelling found there.
        let mut by_dir: Vec<(String, Vec<String>, Vec<String>)> = Vec::new();
        for (dir, file, spelt) in members {
            let at = match by_dir.iter().position(|(d, ..)| *d == dir) {
                Some(at) => at,
                None => {
                    by_dir.push((dir, Vec::new(), Vec::new()));
                    by_dir.len() - 1
                }
            };
            let (_, files, spellings) = &mut by_dir[at];
            files.push(file);
            if !spellings.contains(&spelt) {
                spellings.push(spelt);
            }
        }
        for (dir, files, spellings) in by_dir {
            let change = Change { remove: spellings, ..Change::default() };
            self.notes.change(&self.db, &dir, &files, &change)?;
        }
        Ok(json!({ "removed": count }).to_string())
    }

    /// The pictures that match a description. `sort` is as for `query`, and
    /// "relevance" (best match first) if left out; `bar` overrides how well
    /// a picture has to fit (see `clip::BAR`).
    fn content_query(&self, args: &Value) -> Result<crate::db::QueryResult, String> {
        let dir = normalize(str_arg(args, "dir")?);
        let sort = args.get("sort").and_then(Value::as_str).unwrap_or("relevance");
        let bar = args.get("bar").and_then(Value::as_f64).map(|bar| bar as f32);
        let found = self.content.search(&dir, bool_arg(args, "recursive"), str_arg(args, "text")?, sort, bar)?;
        // A description is not search terms: only the order can be taste's.
        Ok(self.by_taste(found, sort, ""))
    }

    /// The smart collections that apply to the folder being viewed: those
    /// saved in it and in every folder above it, the nearest first when two
    /// share a name. Each comes with where it is saved and how many of the
    /// pictures in view (`dir`, `recursive`) it matches now.
    fn smart_list(&self, args: &Value) -> Result<String, String> {
        let dir = normalize(str_arg(args, "dir")?);
        let recursive = bool_arg(args, "recursive");
        let mut out: Vec<Value> = Vec::new();
        let mut seen: Vec<String> = Vec::new();
        for place in Path::new(&dir).ancestors() {
            let Some(place) = place.to_str().filter(|p| !p.is_empty()) else { continue };
            let place = normalize(place);
            for smart in self.notes.smart(&place) {
                let key = smart.name.to_lowercase();
                if seen.contains(&key) {
                    continue;
                }
                seen.push(key);
                let count = self
                    .search(&json!({ "dir": dir, "recursive": recursive, "text": smart.query }))
                    .map(|found| found.rows.len() as i64)
                    .unwrap_or(-1);
                out.push(json!({ "name": smart.name, "query": smart.query, "dir": place, "count": count }));
            }
        }
        Ok(Value::Array(out).to_string())
    }

    /// Handle one request. `query` answers in the packed binary layout
    /// (see `QueryResult::pack`); everything else is JSON.
    pub fn request(&self, method: &str, args: &Value) -> Result<Reply, String> {
        if method == "query" {
            return Ok(Reply::Bytes(self.search(args)?.pack()));
        }
        if method == "content_query" {
            // The same packed rows as `query`.
            return Ok(Reply::Bytes(self.with_audience(self.content_query(args)?, "").pack()));
        }
        self.call(method, args).map(Reply::Json)
    }

    /// Handle one request, returning JSON text.
    pub fn call(&self, method: &str, args: &Value) -> Result<String, String> {
        let db_err = |e: rusqlite::Error| e.to_string();
        match method {
            "settings" => Ok(serde_json::to_string(&self.db.all_settings()).unwrap_or_default()),
            "set_setting" => {
                self.db.set_setting(str_arg(args, "key")?, str_arg(args, "value")?).map_err(db_err)?;
                Ok("null".into())
            }
            "roots" => Ok(serde_json::to_string(&fsnav::roots()).unwrap_or_default()),
            "list_dirs" => {
                let dirs = fsnav::list_dirs(str_arg(args, "path")?).map_err(|e| e.to_string())?;
                Ok(serde_json::to_string(&dirs).unwrap_or_default())
            }
            "set_folder" => {
                let poll = args.get("poll_ms").and_then(Value::as_u64).unwrap_or(0);
                self.thumbs.warm(Vec::new());
                self.indexer.set_folder(str_arg(args, "dir")?, bool_arg(args, "recursive"), poll);
                Ok("null".into())
            }
            "rescan" => {
                self.indexer.rescan();
                Ok("null".into())
            }
            "query" | "query_json" => Ok(serde_json::to_string(&self.search(args)?).unwrap_or_default()),
            "content_status" => Ok(self.content.status(&normalize(str_arg(args, "dir")?), bool_arg(args, "recursive")).to_string()),
            "content_index" => {
                self.content.index(&normalize(str_arg(args, "dir")?), bool_arg(args, "recursive"));
                Ok("null".into())
            }
            "content_query_json" => Ok(serde_json::to_string(&self.content_query(args)?).unwrap_or_default()),
            "usage" => {
                let text = args.get("text").and_then(Value::as_str).unwrap_or("");
                let usage = self.db.usage(&normalize(str_arg(args, "dir")?), bool_arg(args, "recursive"), text).map_err(db_err)?;
                Ok(serde_json::to_string(&usage).unwrap_or_default())
            }
            "vocabulary" => {
                let words = self.db.vocabulary(&normalize(str_arg(args, "dir")?), bool_arg(args, "recursive"), 2, 20_000).map_err(db_err)?;
                Ok(serde_json::to_string(&words).unwrap_or_default())
            }
            "notes_get" => {
                let (dir, name) = split_path(str_arg(args, "path")?)?;
                Ok(self.db.note(&dir, &name).to_json().to_string())
            }
            "notes_set" => self.set_notes(args),
            "collections" => {
                let names = self.db.collection_names().map_err(db_err)?;
                Ok(Value::Array(names.into_iter().map(|(name, count)| json!({ "name": name, "count": count })).collect()).to_string())
            }
            "smart_list" => self.smart_list(args),
            "smart_set" => {
                let old = args.get("old_name").and_then(Value::as_str);
                self.notes.set_smart(&normalize(str_arg(args, "dir")?), str_arg(args, "name")?, str_arg(args, "query")?, old)?;
                Ok("null".into())
            }
            "smart_delete" => {
                self.notes.delete_smart(&normalize(str_arg(args, "dir")?), str_arg(args, "name")?)?;
                Ok("null".into())
            }
            "count" => {
                // How many pictures a search would list, without listing them.
                let found = self.search(args)?;
                Ok(json!({ "count": found.rows.len() }).to_string())
            }
            "forget" => self.forget(str_arg(args, "path")?),
            "collection_delete" => self.delete_collection(str_arg(args, "name")?),
            "describe" => Ok(self.content.describe(str_arg(args, "path")?)?.to_string()),
            "check_prompt" => {
                let make = args.get("make").and_then(Value::as_bool).unwrap_or(false);
                Ok(self.content.check_prompt(&normalize(str_arg(args, "path")?), str_arg(args, "prompt")?, make)?.to_string())
            }
            "taste_status" => Ok(self.taste_status().to_string()),
            "audience_info" => {
                let path = normalize(str_arg(args, "path")?);
                let own = self.audience_own.lock().get(&path).copied();
                Ok(crate::audience::explain(self.audience_source(), str_arg(args, "prompt")?, None, own).to_string())
            }
            "audience_set" => {
                // A level 1 to 5, or 0 to go back to the app's own reading.
                let path = normalize(str_arg(args, "path")?);
                let level = crate::audience::Level::from_u8(args.get("level").and_then(Value::as_u64).unwrap_or(0) as u8);
                let mut own = self.audience_own.lock();
                if level == crate::audience::Level::Unknown {
                    own.remove(&path);
                } else {
                    own.insert(path, level);
                }
                Ok("null".into())
            }
            "audience_steer" => {
                let target = crate::audience::Level::from_u8(args.get("target").and_then(Value::as_u64).unwrap_or(0) as u8);
                let negative = args.get("negative").and_then(Value::as_str).unwrap_or("");
                Ok(crate::audience::steer(str_arg(args, "prompt")?, negative, target).to_string())
            }
            "describe_groups" => self.describe_groups(str_arg(args, "path")?),
            "what_works" => {
                let recipes = self.db.recipes(&normalize(args.get("dir").and_then(Value::as_str).unwrap_or("")), bool_arg(args, "recursive"), args.get("text").and_then(Value::as_str).unwrap_or("")).map_err(db_err)?;
                Ok(crate::works::what_works(&recipes, &model_key(args.get("model").and_then(Value::as_str).unwrap_or(""))).to_string())
            }
            "prompt_doctor" => self.prompt_doctor(args),
            "phrase_heat" => Ok(self.content.heat(&normalize(str_arg(args, "path")?), str_arg(args, "phrase")?)?.to_string()),
            "breed" => self.breed(args),
            "duplicate_groups" => self.duplicate_groups(args),
            "taste_score" => Ok(self.taste_score(str_arg(args, "path")?).to_string()),
            "upscale_models" => {
                let dir = crate::sr::model_dir(&self.data_dir);
                let models: Vec<Value> = crate::sr::MODELS
                    .iter()
                    .map(|m| {
                        let installed = std::fs::metadata(dir.join(m.file)).map_or(false, |md| md.len() == m.bytes);
                        json!({ "id": m.id, "name": m.name, "detail": m.detail, "file": m.file, "bytes": m.bytes, "installed": installed })
                    })
                    .collect();
                Ok(json!({ "dir": dir.to_string_lossy(), "source": crate::sr::SOURCE, "models": models }).to_string())
            }
            "upscale" => self.start_upscale(args),
            "upscale_cancel" => {
                let job = args.get("job").and_then(Value::as_u64).ok_or("missing argument: job")?;
                self.upscales.lock().retain(|j| *j != job);
                Ok("null".into())
            }
            "meta" => {
                let info = meta::extract(Path::new(str_arg(args, "path")?));
                Ok(serde_json::to_string(&info).unwrap_or_default())
            }
            "warm" => {
                // Pre-render small thumbnails for a whole view, in view order.
                let result = self.db.query(&Self::query_args(args)?).map_err(db_err)?;
                let items = result
                    .rows
                    .iter()
                    // Videos need the host on Android; leave them on demand.
                    .filter(|r| !(cfg!(target_os = "android") && r.3 == 1))
                    .map(|r| {
                        let dir = &result.dirs[r.1 as usize];
                        let path = if dir.ends_with('/') { format!("{dir}{}", r.2) } else { format!("{dir}/{}", r.2) };
                        (path, r.6, r.7)
                    })
                    .collect::<Vec<_>>();
                let n = items.len();
                self.thumbs.warm(items);
                Ok(json!({ "queued": n }).to_string())
            }
            "stop_warm" => {
                self.thumbs.warm(Vec::new());
                Ok("null".into())
            }
            "stats" => Ok(json!({ "files": self.db.count(), "version": env!("CARGO_PKG_VERSION") }).to_string()),
            other => Err(format!("unknown method: {other}")),
        }
    }
}

/// A file's folder and name.
fn split_path(path: &str) -> Result<(String, String), String> {
    let path = Path::new(path);
    let name = path.file_name().and_then(|n| n.to_str()).ok_or("not a file path")?;
    let dir = path.parent().and_then(|d| d.to_str()).ok_or("not a file path")?;
    Ok((normalize(dir), name.to_string()))
}
