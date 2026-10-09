//! The engine: everything the UI can ask for, independent of how it asks.
//! `ffi` wraps this for Dart; tests and the CLI tools call it directly.

use crate::db::{Db, Query};
use crate::fsnav;
use crate::index::{normalize, EventSink, Indexer};
use crate::meta;
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
}

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
        let indexer = Indexer::start(db.clone(), sink);
        Ok(Engine { db, thumbs, indexer })
    }

    pub fn close(&self) {
        self.indexer.close();
        self.thumbs.close();
    }

    fn query_args(args: &Value) -> Result<Query, String> {
        Ok(Query {
            dir: normalize(str_arg(args, "dir")?),
            recursive: bool_arg(args, "recursive"),
            text: args.get("text").and_then(Value::as_str).unwrap_or("").to_string(),
            sort: args.get("sort").and_then(Value::as_str).unwrap_or("newest").to_string(),
        })
    }

    /// Handle one request. `query` answers in the packed binary layout
    /// (see `QueryResult::pack`); everything else is JSON.
    pub fn request(&self, method: &str, args: &Value) -> Result<Reply, String> {
        if method == "query" {
            let result = self.db.query(&Self::query_args(args)?).map_err(|e| e.to_string())?;
            return Ok(Reply::Bytes(result.pack()));
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
            "query" | "query_json" => {
                let result = self.db.query(&Self::query_args(args)?).map_err(db_err)?;
                Ok(serde_json::to_string(&result).unwrap_or_default())
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
