//! C ABI for the Flutter app.
//!
//! Everything is asynchronous from Dart's point of view: a call names a
//! `SendPort` and a request id, returns at once, and the answer is posted to
//! the port as `[request id, status, payload]`:
//!   status 0  ok        payload = JSON string; Uint8List for thumbnails and `query`
//!   status 1  error     payload = message
//!   status 2  need host payload = "" (video thumbnail on Android: the app
//!                       must supply a frame through `gv_thumb_put`)
//! Engine events (scan progress, index changes) are posted to the event port
//! as bare JSON strings.

use crate::engine::{Engine, Reply};
use crate::thumbs::{Job, ThumbError, ThumbResult};
use allo_isolate::{IntoDart, Isolate, ZeroCopyBuffer};
use crossbeam_channel::{unbounded, Sender};
use parking_lot::RwLock;
use serde_json::Value;
use std::ffi::{c_char, CStr};
use std::path::Path;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, OnceLock};

static ENGINE: RwLock<Option<Arc<Engine>>> = RwLock::new(None);
static EVENT_PORT: AtomicI64 = AtomicI64::new(0);
static CALLS: OnceLock<Sender<Call>> = OnceLock::new();

struct Call {
    port: i64,
    req: i64,
    request: String,
}

fn post_text(port: i64, req: i64, status: i32, text: String) {
    Isolate::new(port).post(vec![req.into_dart(), status.into_dart(), text.into_dart()]);
}

fn post_thumb(port: i64, req: i64, result: ThumbResult) {
    match result {
        Ok(bytes) => {
            Isolate::new(port).post(vec![req.into_dart(), 0i32.into_dart(), ZeroCopyBuffer(bytes).into_dart()]);
        }
        Err(ThumbError::NeedHost) => post_text(port, req, 2, String::new()),
        Err(ThumbError::Failed(msg)) => post_text(port, req, 1, msg),
    }
}

fn engine() -> Option<Arc<Engine>> {
    ENGINE.read().clone()
}

fn calls() -> &'static Sender<Call> {
    CALLS.get_or_init(|| {
        let (tx, rx) = unbounded::<Call>();
        for i in 0..3 {
            let rx = rx.clone();
            std::thread::Builder::new()
                .name(format!("gv-call-{i}"))
                .spawn(move || {
                    for call in rx {
                        let outcome = std::panic::catch_unwind(|| handle(&call.request));
                        match outcome {
                            Ok(Ok(Reply::Json(json))) => post_text(call.port, call.req, 0, json),
                            Ok(Ok(Reply::Bytes(bytes))) => {
                                Isolate::new(call.port).post(vec![call.req.into_dart(), 0i32.into_dart(), ZeroCopyBuffer(bytes).into_dart()]);
                            }
                            Ok(Err(msg)) => post_text(call.port, call.req, 1, msg),
                            Err(_) => post_text(call.port, call.req, 1, "internal error".into()),
                        }
                    }
                })
                .expect("call worker");
        }
        tx
    })
}

fn handle(request: &str) -> Result<Reply, String> {
    let value: Value = serde_json::from_str(request).map_err(|e| format!("bad request: {e}"))?;
    let method = value.get("m").and_then(Value::as_str).ok_or("bad request: no method")?;
    let engine = engine().ok_or("engine is not open")?;
    engine.request(method, &value)
}

unsafe fn text<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    std::str::from_utf8(std::slice::from_raw_parts(ptr, len)).ok()
}

/// Must be called once, with `NativeApi.postCObject`, before anything else.
///
/// # Safety
/// `post` must be the Dart VM's `Dart_PostCObject` function.
#[no_mangle]
pub unsafe extern "C" fn gv_init(post: allo_isolate::ffi::DartPostCObjectFnType) {
    allo_isolate::store_dart_post_cobject(post);
}

/// Open (or re-attach to) the engine. Returns 0 on success.
/// Calling it again — after a hot restart, say — just swaps the event port.
///
/// # Safety
/// Both paths must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn gv_open(data_dir: *const c_char, cache_dir: *const c_char, event_port: i64) -> i32 {
    EVENT_PORT.store(event_port, Ordering::SeqCst);
    if ENGINE.read().is_some() {
        return 0;
    }
    if data_dir.is_null() || cache_dir.is_null() {
        return 1;
    }
    let (Ok(data), Ok(cache)) = (CStr::from_ptr(data_dir).to_str(), CStr::from_ptr(cache_dir).to_str()) else {
        return 1;
    };
    let sink: crate::index::EventSink = Arc::new(|event: String| {
        let port = EVENT_PORT.load(Ordering::SeqCst);
        if port != 0 {
            Isolate::new(port).post(event);
        }
    });
    match Engine::open(Path::new(data), Path::new(cache), sink) {
        Ok(engine) => {
            *ENGINE.write() = Some(Arc::new(engine));
            0
        }
        Err(_) => 2,
    }
}

/// Run a JSON request `{"m": "<method>", ...}`.
///
/// # Safety
/// `json` must point to `len` bytes of UTF-8.
#[no_mangle]
pub unsafe extern "C" fn gv_call(port: i64, req: i64, json: *const u8, len: usize) {
    match text(json, len) {
        Some(request) => {
            let _ = calls().send(Call { port, req, request: request.to_string() });
        }
        None => post_text(port, req, 1, "bad request: not UTF-8".into()),
    }
}

/// Ask for a thumbnail. `tier` 0 is ~256 px, 1 is ~512 px on the short side.
///
/// # Safety
/// `path` must point to `path_len` bytes of UTF-8.
#[no_mangle]
pub unsafe extern "C" fn gv_thumb(port: i64, req: i64, path: *const u8, path_len: usize, mtime: i64, size: i64, tier: i32) {
    let (Some(path), Some(engine)) = (text(path, path_len), engine()) else {
        post_text(port, req, 1, "engine is not open".into());
        return;
    };
    engine.thumbs.request(Job {
        req,
        path: path.to_string(),
        mtime,
        size,
        tier: tier.clamp(0, 1) as u8,
        reply: Box::new(move |result| post_thumb(port, req, result)),
    });
}

/// Supply an encoded frame (JPEG/PNG) for a file the core could not decode,
/// and get its thumbnail back like a normal `gv_thumb` reply.
///
/// # Safety
/// `path` and `data` must point to `path_len` / `data_len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn gv_thumb_put(
    port: i64,
    req: i64,
    path: *const u8,
    path_len: usize,
    mtime: i64,
    size: i64,
    tier: i32,
    data: *const u8,
    data_len: usize,
) {
    let (Some(path), Some(engine)) = (text(path, path_len), engine()) else {
        post_text(port, req, 1, "engine is not open".into());
        return;
    };
    if data.is_null() {
        post_text(port, req, 1, "no image data".into());
        return;
    }
    let path = path.to_string();
    let bytes = std::slice::from_raw_parts(data, data_len).to_vec();
    std::thread::spawn(move || {
        post_thumb(port, req, engine.thumbs.put(&path, mtime, size, tier.clamp(0, 1) as u8, &bytes));
    });
}

/// Abandon a thumbnail request that has not started. No reply is sent.
#[no_mangle]
pub extern "C" fn gv_cancel(req: i64) {
    if let Some(engine) = engine() {
        engine.thumbs.cancel(req);
    }
}
