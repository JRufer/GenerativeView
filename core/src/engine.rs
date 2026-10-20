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
}

static NEXT_JOB: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

fn str_arg<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    args.get(key).and_then(Value::as_str).ok_or_else(|| format!("missing argument: {key}"))
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
        Ok(Engine { db, thumbs, indexer, content, notes, dupes, data_dir: data_dir.to_path_buf(), sink, upscales: Default::default() })
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
        if crate::db::wants_duplicates(text) {
            return Ok(self.dupes.only_duplicates(&self.thumbs, &found));
        }
        Ok(found)
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
        self.content.search(&dir, bool_arg(args, "recursive"), str_arg(args, "text")?, sort, bar)
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
            return Ok(Reply::Bytes(self.content_query(args)?.pack()));
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
