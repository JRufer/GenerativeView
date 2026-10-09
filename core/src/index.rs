//! Keeps the database in step with the folder on screen.
//!
//! One background thread owns the current "session" (root folder + recursive
//! flag). On entering a folder it diffs disk against the index and parses only
//! what is new or changed; after that it stays current through file-system
//! notifications, with a cheap directory-mtime poll as a safety net for
//! filesystems that do not deliver them (Android shared storage, network
//! mounts).

use crate::db::{Db, FileRecord};
use crate::meta;
use crossbeam_channel::{unbounded, Receiver, RecvTimeoutError, Sender};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use rayon::prelude::*;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, UNIX_EPOCH};

pub type EventSink = Arc<dyn Fn(String) + Send + Sync>;

/// Quiet time after the last file event before changes are applied.
const DEBOUNCE: Duration = Duration::from_millis(250);
/// ...but never hold changes back longer than this during a steady stream.
const DEBOUNCE_MAX: Duration = Duration::from_millis(1500);
const CHUNK: usize = 256;

enum Cmd {
    SetFolder { root: String, recursive: bool, poll_ms: u64, generation: u64 },
    Fs { generation: u64, paths: Vec<PathBuf>, rescan: bool },
    Rescan,
    Close,
}

pub struct Indexer {
    tx: Sender<Cmd>,
    generation: Arc<AtomicU64>,
}

impl Indexer {
    pub fn start(db: Arc<Db>, sink: EventSink) -> Indexer {
        let (tx, rx) = unbounded();
        let generation = Arc::new(AtomicU64::new(0));
        let worker = Worker {
            db,
            sink,
            tx: tx.clone(),
            generation: generation.clone(),
            pool: rayon::ThreadPoolBuilder::new()
                .num_threads(std::thread::available_parallelism().map_or(2, |n| n.get()).clamp(1, 4))
                .thread_name(|i| format!("gv-parse-{i}"))
                .build()
                .expect("parse pool"),
        };
        std::thread::Builder::new()
            .name("gv-index".into())
            .spawn(move || worker.run(rx))
            .expect("index thread");
        Indexer { tx, generation }
    }

    /// Switch to a folder. Any scan still running for the previous one stops.
    pub fn set_folder(&self, root: &str, recursive: bool, poll_ms: u64) {
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let _ = self.tx.send(Cmd::SetFolder { root: normalize(root), recursive, poll_ms, generation });
    }

    pub fn rescan(&self) {
        let _ = self.tx.send(Cmd::Rescan);
    }

    pub fn close(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        let _ = self.tx.send(Cmd::Close);
    }
}

pub fn normalize(path: &str) -> String {
    if path.len() > 1 {
        path.trim_end_matches('/').to_string()
    } else {
        path.to_string()
    }
}

fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

fn mtime_ms(md: &std::fs::Metadata) -> i64 {
    md.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_millis() as i64)
}

struct Entry {
    dir: String,
    name: String,
    size: i64,
    mtime: i64,
    video: bool,
}

impl Entry {
    fn path(&self) -> String {
        join(&self.dir, &self.name)
    }
}

/// List media files under `root`. `dirs` receives every directory visited
/// with its mtime, for change polling.
fn walk(
    root: &str,
    recursive: bool,
    cancelled: &dyn Fn() -> bool,
    entries: &mut Vec<Entry>,
    dirs: &mut HashMap<String, i64>,
) -> std::io::Result<()> {
    let mut stack = vec![root.to_string()];
    let mut first = true;
    while let Some(dir) = stack.pop() {
        if cancelled() {
            return Ok(());
        }
        let rd = match std::fs::read_dir(&dir) {
            Ok(rd) => rd,
            Err(e) if first => return Err(e),
            Err(_) => continue,
        };
        first = false;
        if let Ok(md) = std::fs::metadata(&dir) {
            dirs.insert(dir.clone(), mtime_ms(&md));
        }
        for ent in rd.flatten() {
            let Ok(ft) = ent.file_type() else { continue };
            let os_name = ent.file_name();
            let Some(name) = os_name.to_str() else { continue };
            if ft.is_dir() {
                if recursive && !name.starts_with('.') {
                    stack.push(join(&dir, name));
                }
                continue;
            }
            let Some(video) = meta::media_kind(Path::new(name)) else { continue };
            // Follow symlinks for files; a dangling link is simply skipped.
            let md = if ft.is_symlink() { std::fs::metadata(ent.path()) } else { ent.metadata() };
            let Ok(md) = md else { continue };
            if !md.is_file() {
                continue;
            }
            entries.push(Entry { dir: dir.clone(), name: name.to_string(), size: md.len() as i64, mtime: mtime_ms(&md), video });
        }
    }
    Ok(())
}

struct Session {
    root: String,
    recursive: bool,
    generation: u64,
    poll: Option<Duration>,
    next_poll: Instant,
    dir_mtimes: HashMap<String, i64>,
    pending: HashSet<PathBuf>,
    pending_rescan: bool,
    first_pending: Option<Instant>,
    flush_at: Option<Instant>,
    _watcher: Option<RecommendedWatcher>,
    rev: u64,
}

struct Worker {
    db: Arc<Db>,
    sink: EventSink,
    tx: Sender<Cmd>,
    generation: Arc<AtomicU64>,
    pool: rayon::ThreadPool,
}

impl Worker {
    fn run(self, rx: Receiver<Cmd>) {
        let mut session: Option<Session> = None;
        loop {
            let now = Instant::now();
            let wait = match &session {
                Some(s) => {
                    let mut deadline = now + Duration::from_secs(3600);
                    if let Some(f) = s.flush_at {
                        deadline = deadline.min(f);
                    }
                    if s.poll.is_some() {
                        deadline = deadline.min(s.next_poll);
                    }
                    deadline.saturating_duration_since(now)
                }
                None => Duration::from_secs(3600),
            };
            match rx.recv_timeout(wait) {
                Ok(Cmd::SetFolder { root, recursive, poll_ms, generation }) => {
                    // Superseded before we even started? Skip straight on.
                    if generation != self.generation.load(Ordering::SeqCst) {
                        continue;
                    }
                    drop(session.take()); // stops the old watcher
                    let watcher = self.watch(&root, recursive, generation);
                    let mut s = Session {
                        root,
                        recursive,
                        generation,
                        poll: (poll_ms > 0).then(|| Duration::from_millis(poll_ms)),
                        next_poll: Instant::now() + Duration::from_millis(poll_ms.max(1)),
                        dir_mtimes: HashMap::new(),
                        pending: HashSet::new(),
                        pending_rescan: false,
                        first_pending: None,
                        flush_at: None,
                        _watcher: watcher,
                        rev: 0,
                    };
                    self.full_scan(&mut s);
                    session = Some(s);
                }
                Ok(Cmd::Fs { generation, paths, rescan }) => {
                    let Some(s) = session.as_mut().filter(|s| s.generation == generation) else { continue };
                    s.pending.extend(paths);
                    s.pending_rescan |= rescan;
                    let now = Instant::now();
                    let first = *s.first_pending.get_or_insert(now);
                    s.flush_at = Some((now + DEBOUNCE).min(first + DEBOUNCE_MAX));
                }
                Ok(Cmd::Rescan) => {
                    if let Some(s) = session.as_mut() {
                        self.full_scan(s);
                    }
                }
                Ok(Cmd::Close) | Err(RecvTimeoutError::Disconnected) => break,
                Err(RecvTimeoutError::Timeout) => {
                    let Some(s) = session.as_mut() else { continue };
                    let now = Instant::now();
                    if s.flush_at.map_or(false, |f| f <= now) {
                        self.apply_pending(s);
                    }
                    if let Some(every) = s.poll {
                        if s.next_poll <= now {
                            s.next_poll = now + every;
                            if self.dirs_changed(s) {
                                self.full_scan(s);
                            }
                        }
                    }
                }
            }
        }
    }

    fn emit(&self, value: serde_json::Value) {
        (self.sink)(value.to_string());
    }

    fn changed(&self, s: &mut Session) {
        s.rev += 1;
        self.emit(json!({ "t": "changed", "root": s.root, "rev": s.rev }));
    }

    fn watch(&self, root: &str, recursive: bool, generation: u64) -> Option<RecommendedWatcher> {
        let tx = self.tx.clone();
        let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| match res {
            Ok(ev) => {
                // Reads and opens are noise.
                if matches!(ev.kind, notify::EventKind::Access(notify::event::AccessKind::Close(notify::event::AccessMode::Write)))
                    || !matches!(ev.kind, notify::EventKind::Access(_))
                {
                    let rescan = ev.need_rescan();
                    let _ = tx.send(Cmd::Fs { generation, paths: ev.paths, rescan });
                }
            }
            Err(_) => {
                let _ = tx.send(Cmd::Fs { generation, paths: Vec::new(), rescan: true });
            }
        })
        .ok()?;
        let mode = if recursive { RecursiveMode::Recursive } else { RecursiveMode::NonRecursive };
        watcher.watch(Path::new(root), mode).ok()?;
        Some(watcher)
    }

    fn dirs_changed(&self, s: &Session) -> bool {
        s.dir_mtimes.iter().any(|(dir, &known)| match std::fs::metadata(dir) {
            Ok(md) => mtime_ms(&md) != known,
            Err(_) => true,
        })
    }

    /// Diff disk against the index and bring the index up to date.
    fn full_scan(&self, s: &mut Session) {
        let (current, mine) = (&self.generation, s.generation);
        let cancelled = || current.load(Ordering::SeqCst) != mine;
        s.pending.clear();
        s.pending_rescan = false;
        s.first_pending = None;
        s.flush_at = None;
        let started = Instant::now();
        self.emit(json!({ "t": "scan", "root": s.root, "state": "start", "done": 0, "total": 0 }));

        let mut entries = Vec::new();
        let mut dirs = HashMap::new();
        if let Err(e) = walk(&s.root, s.recursive, &cancelled, &mut entries, &mut dirs) {
            // Unreadable root (unmounted drive, missing permission): leave the
            // index alone rather than wiping what we know about it.
            self.emit(json!({ "t": "scan", "root": s.root, "state": "error", "error": e.to_string(), "done": 0, "total": 0 }));
            return;
        }
        if cancelled() {
            return;
        }
        s.dir_mtimes = dirs;

        let known = match self.db.snapshot(&s.root, s.recursive) {
            Ok(k) => k,
            Err(e) => {
                self.emit(json!({ "t": "scan", "root": s.root, "state": "error", "error": e.to_string(), "done": 0, "total": 0 }));
                return;
            }
        };
        let mut seen: HashSet<i64> = HashSet::with_capacity(known.len());
        let mut todo: Vec<Entry> = Vec::new();
        for e in entries {
            match known.get(&(e.dir.clone(), e.name.clone())) {
                Some(&(id, size, mtime)) => {
                    seen.insert(id);
                    if size != e.size || mtime != e.mtime {
                        todo.push(e);
                    }
                }
                None => todo.push(e),
            }
        }
        let gone: Vec<i64> = known.values().map(|v| v.0).filter(|id| !seen.contains(id)).collect();
        let files = seen.len() + todo.iter().filter(|e| !known.contains_key(&(e.dir.clone(), e.name.clone()))).count();

        if !gone.is_empty() && self.db.delete_ids(&gone).is_ok() {
            self.changed(s);
        }

        // Newest first, so the default view fills in from the top.
        todo.sort_by(|a, b| b.mtime.cmp(&a.mtime));
        let total = todo.len();
        let mut done = 0;
        for chunk in todo.chunks(CHUNK) {
            if cancelled() {
                return;
            }
            let records = self.parse(chunk);
            if self.db.upsert(&records).is_ok() {
                done += chunk.len();
                self.emit(json!({ "t": "scan", "root": s.root, "state": "progress", "done": done, "total": total }));
                self.changed(s);
            }
        }
        self.emit(json!({
            "t": "scan", "root": s.root, "state": "done", "done": done, "total": total,
            "files": files, "removed": gone.len(), "ms": started.elapsed().as_millis() as u64,
        }));
    }

    fn parse(&self, entries: &[Entry]) -> Vec<FileRecord> {
        self.pool.install(|| {
            entries
                .par_iter()
                .map(|e| FileRecord {
                    dir: e.dir.clone(),
                    name: e.name.clone(),
                    size: e.size,
                    mtime: e.mtime,
                    video: e.video,
                    info: meta::extract(Path::new(&e.path())),
                })
                .collect()
        })
    }

    /// Apply a debounced batch of file-system events.
    fn apply_pending(&self, s: &mut Session) {
        let paths: Vec<PathBuf> = s.pending.drain().collect();
        let rescan = std::mem::take(&mut s.pending_rescan);
        s.first_pending = None;
        s.flush_at = None;
        if rescan || paths.len() > 2000 {
            self.full_scan(s);
            return;
        }

        let mut upserts: Vec<Entry> = Vec::new();
        let mut touched_dirs: HashSet<String> = HashSet::new();
        let mut removed = 0usize;
        let mut need_full = false;
        for path in &paths {
            let Some(full) = path.to_str() else { continue };
            let (Some(parent), Some(name)) = (path.parent().and_then(Path::to_str), path.file_name().and_then(|n| n.to_str())) else {
                continue;
            };
            let parent = normalize(parent);
            if full == s.root {
                continue;
            }
            let in_scope = if s.recursive { parent == s.root || parent.starts_with(&join(&s.root, "")) } else { parent == s.root };
            if !in_scope {
                continue;
            }
            match std::fs::metadata(path) {
                Ok(md) if md.is_dir() => {
                    // A folder appeared or changed: its contents need a walk.
                    if s.recursive && !s.dir_mtimes.contains_key(full) {
                        need_full = true;
                    }
                }
                Ok(md) => {
                    if let Some(video) = meta::media_kind(path) {
                        touched_dirs.insert(parent.clone());
                        upserts.push(Entry { dir: parent, name: name.to_string(), size: md.len() as i64, mtime: mtime_ms(&md), video });
                    }
                }
                Err(_) => {
                    touched_dirs.insert(parent.clone());
                    if meta::media_kind(path).is_some() {
                        removed += self.db.delete_path(&parent, name).unwrap_or(0);
                    } else if s.recursive {
                        // Possibly a folder that was deleted or moved away.
                        removed += self.db.delete_tree(full).unwrap_or(0);
                        s.dir_mtimes.retain(|d, _| d != full && !d.starts_with(&join(full, "")));
                    }
                }
            }
        }

        let mut dirty = removed > 0;
        for chunk in upserts.chunks(CHUNK) {
            let records = self.parse(chunk);
            dirty |= self.db.upsert(&records).is_ok();
        }
        // We have accounted for these directories; do not let the poll
        // mistake our own bookkeeping lag for a change.
        for dir in touched_dirs {
            if let Ok(md) = std::fs::metadata(&dir) {
                if s.dir_mtimes.contains_key(&dir) {
                    s.dir_mtimes.insert(dir, mtime_ms(&md));
                }
            }
        }
        if dirty {
            self.changed(s);
        }
        if need_full {
            self.full_scan(s);
        }
    }
}
