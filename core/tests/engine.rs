//! The engine end to end: open a folder, get it indexed, search it, and see
//! the index follow files being added, changed and removed on disk.

mod common;
use common::*;
use gvcore::engine::Engine;
use serde_json::{json, Value};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

struct Harness {
    engine: Engine,
    events: Arc<Mutex<Vec<Value>>>,
    _dirs: tempfile::TempDir,
}

impl Harness {
    fn new() -> Harness {
        let dirs = tempfile::tempdir().unwrap();
        let events: Arc<Mutex<Vec<Value>>> = Arc::default();
        let sink_events = events.clone();
        let engine = Engine::open(
            &dirs.path().join("data"),
            &dirs.path().join("cache"),
            Arc::new(move |e: String| sink_events.lock().unwrap().push(serde_json::from_str(&e).unwrap())),
        )
        .unwrap();
        Harness { engine, events, _dirs: dirs }
    }

    fn call(&self, method: &str, args: Value) -> Value {
        serde_json::from_str(&self.engine.call(method, &args).unwrap()).unwrap()
    }

    /// Wait until an event matching `pred` arrives, consuming events up to it.
    fn wait(&self, what: &str, pred: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            {
                let mut ev = self.events.lock().unwrap();
                if let Some(i) = ev.iter().position(|e| pred(e)) {
                    let found = ev[i].clone();
                    ev.drain(..=i);
                    return found;
                }
            }
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn wait_scan_done(&self) -> Value {
        self.wait("scan done", |e| e["t"] == "scan" && e["state"] == "done")
    }

    fn wait_changed(&self) {
        self.wait("index change", |e| e["t"] == "changed");
    }

    fn names(&self, dir: &Path, recursive: bool, text: &str) -> Vec<String> {
        let r = self.call("query", json!({ "dir": dir.to_str().unwrap(), "recursive": recursive, "text": text, "sort": "name" }));
        r["rows"].as_array().unwrap().iter().map(|row| row[2].as_str().unwrap().to_string()).collect()
    }

    /// Poll a query until it returns `expected` (the index is eventually consistent).
    fn expect_names(&self, dir: &Path, recursive: bool, text: &str, expected: &[&str]) {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let got = self.names(dir, recursive, text);
            if got == expected {
                return;
            }
            assert!(Instant::now() < deadline, "query {text:?}: expected {expected:?}, last saw {got:?}");
            std::thread::sleep(Duration::from_millis(25));
        }
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.engine.close();
    }
}

fn comfy_prompt(text: &str, seed: u64, ckpt: &str) -> String {
    json!({
        "1": {"class_type": "KSampler", "inputs": {"seed": seed, "steps": 20, "cfg": 7, "sampler_name": "euler", "scheduler": "normal", "denoise": 1,
              "positive": ["2", 0], "negative": ["3", 0], "model": ["4", 0], "latent_image": ["5", 0]}},
        "2": {"class_type": "CLIPTextEncode", "inputs": {"text": text, "clip": ["4", 1]}},
        "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "watermark", "clip": ["4", 1]}},
        "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": ckpt}},
        "5": {"class_type": "EmptyLatentImage", "inputs": {"width": 512, "height": 512, "batch_size": 1}}
    })
    .to_string()
}

#[test]
fn index_search_and_live_updates() {
    let h = Harness::new();
    let lib = tempfile::tempdir().unwrap();
    let root = lib.path().canonicalize().unwrap();
    std::fs::create_dir_all(root.join("portraits")).unwrap();
    std::fs::create_dir_all(root.join(".thumbnails")).unwrap();

    write_png(&root.join("ComfyUI_00001_.png"), 1, &[("prompt", &comfy_prompt("a lighthouse in a storm", 11, "flux1-dev.safetensors"))]);
    write_png(&root.join("ComfyUI_00002_.png"), 2, &[("prompt", &comfy_prompt("a red fox in the snow", 22, "sdxl_base.safetensors"))]);
    write_png(&root.join("00003-a1111.png"), 3, &[("parameters", A1111_TEXT)]);
    write_png(&root.join("portraits").join("invoke.png"), 4, &[("invokeai_metadata", INVOKE_TEXT)]);
    write_png(&root.join(".thumbnails").join("hidden.png"), 5, &[]);
    std::fs::write(root.join("notes.txt"), "not an image").unwrap();
    std::fs::copy(fixture_path("comfy_tags.mp4"), root.join("clip.mp4")).unwrap();

    // ---- first visit: everything gets parsed -------------------------------
    h.call("set_folder", json!({ "dir": root.to_str().unwrap(), "recursive": true, "poll_ms": 0 }));
    let done = h.wait_scan_done();
    assert_eq!(done["total"], 5);
    assert_eq!(done["files"], 5);

    assert_eq!(h.names(&root, true, ""), ["00003-a1111.png", "clip.mp4", "ComfyUI_00001_.png", "ComfyUI_00002_.png", "invoke.png"]);
    assert_eq!(h.names(&root, false, "").len(), 4);
    assert_eq!(h.names(&root.join("portraits"), false, ""), ["invoke.png"]);

    // Rows carry what the grid needs: kind, dimensions, duration.
    let all = h.call("query", json!({ "dir": root.to_str().unwrap(), "recursive": true, "sort": "name" }));
    let clip = all["rows"].as_array().unwrap().iter().find(|r| r[2] == "clip.mp4").unwrap();
    assert_eq!((clip[3].as_i64(), clip[4].as_i64(), clip[5].as_i64(), clip[8].as_i64()), (Some(1), Some(64), Some(48), Some(1000)));

    // ---- search by prompt contents, across tools ---------------------------
    assert_eq!(h.names(&root, true, "lighthouse"), ["00003-a1111.png", "ComfyUI_00001_.png"]);
    // Substring matching: "storm" also finds the other image's "stormy sea".
    assert_eq!(h.names(&root, true, "lighthouse storm"), ["00003-a1111.png", "ComfyUI_00001_.png"]);
    assert_eq!(h.names(&root, true, "lighthouse \"a storm\""), ["ComfyUI_00001_.png"]);
    assert_eq!(h.names(&root, true, "lighthouse -stormy"), ["ComfyUI_00001_.png"]);
    assert_eq!(h.names(&root, true, "submarine"), ["invoke.png"]);
    assert_eq!(h.names(&root, true, "model:juggernaut"), ["invoke.png"]);
    assert_eq!(h.names(&root, true, "lora:add_detail"), ["00003-a1111.png"]);
    assert_eq!(h.names(&root, true, "comfyui_0000"), ["ComfyUI_00001_.png", "ComfyUI_00002_.png"]);
    assert_eq!(h.names(&root, true, "seed:22"), ["ComfyUI_00002_.png"]);
    assert_eq!(h.names(&root, true, "source:invokeai"), ["invoke.png"]);
    assert_eq!(h.names(&root, true, "fox -quickly"), ["ComfyUI_00002_.png"]);
    assert_eq!(h.names(&root, true, "nothing matches this"), Vec::<String>::new());

    // ---- a new image appears while the folder is open ----------------------
    write_png(&root.join("ComfyUI_00003_.png"), 6, &[("prompt", &comfy_prompt("a clockwork owl", 33, "flux1-dev.safetensors"))]);
    h.wait_changed();
    h.expect_names(&root, true, "clockwork", &["ComfyUI_00003_.png"]);

    // ---- ...is overwritten with a different prompt -------------------------
    std::thread::sleep(Duration::from_millis(20));
    write_png(&root.join("ComfyUI_00003_.png"), 7, &[("prompt", &comfy_prompt("a brass heron", 34, "flux1-dev.safetensors"))]);
    h.expect_names(&root, true, "heron", &["ComfyUI_00003_.png"]);
    h.expect_names(&root, true, "clockwork", &[]);

    // ---- ...and is deleted; so is a whole sub-folder ----------------------
    std::fs::remove_file(root.join("ComfyUI_00003_.png")).unwrap();
    h.expect_names(&root, true, "heron", &[]);
    std::fs::remove_dir_all(root.join("portraits")).unwrap();
    h.expect_names(&root, true, "submarine", &[]);

    // ---- a new sub-folder with images is picked up -------------------------
    std::fs::create_dir_all(root.join("batch2")).unwrap();
    write_png(&root.join("batch2").join("new.png"), 8, &[("prompt", &comfy_prompt("a glass violin", 44, "flux1-dev.safetensors"))]);
    h.expect_names(&root, true, "violin", &["new.png"]);

    // ---- second visit: nothing to parse, the index is reused ---------------
    h.events.lock().unwrap().clear();
    h.call("set_folder", json!({ "dir": root.to_str().unwrap(), "recursive": true, "poll_ms": 0 }));
    let done = h.wait_scan_done();
    assert_eq!(done["total"], 0, "revisit should parse nothing: {done}");
    assert_eq!(done["files"], 5);
}

#[test]
fn polling_catches_changes_without_notifications() {
    // Watch one folder, then change another that the watcher cannot see by
    // swapping the session: emulates a filesystem that sends no events by
    // relying on the directory-mtime poll alone.
    let h = Harness::new();
    let lib = tempfile::tempdir().unwrap();
    let root = lib.path().canonicalize().unwrap();
    write_png(&root.join("a.png"), 1, &[("parameters", A1111_TEXT)]);
    h.call("set_folder", json!({ "dir": root.to_str().unwrap(), "recursive": false, "poll_ms": 50 }));
    h.wait_scan_done();
    assert_eq!(h.names(&root, false, ""), ["a.png"]);
    write_png(&root.join("b.png"), 2, &[("parameters", A1111_TEXT)]);
    h.expect_names(&root, false, "", &["a.png", "b.png"]);
    std::fs::remove_file(root.join("a.png")).unwrap();
    h.expect_names(&root, false, "", &["b.png"]);
}

#[test]
fn unreadable_root_keeps_index() {
    let h = Harness::new();
    let lib = tempfile::tempdir().unwrap();
    let root = lib.path().canonicalize().unwrap().join("drive");
    std::fs::create_dir_all(&root).unwrap();
    write_png(&root.join("a.png"), 1, &[("parameters", A1111_TEXT)]);
    h.call("set_folder", json!({ "dir": root.to_str().unwrap(), "recursive": true, "poll_ms": 0 }));
    h.wait_scan_done();

    // The "drive" goes away (unmounted). The index must survive.
    let parked = root.with_file_name("drive-unmounted");
    std::fs::rename(&root, &parked).unwrap();
    h.call("set_folder", json!({ "dir": root.to_str().unwrap(), "recursive": true, "poll_ms": 0 }));
    h.wait("scan error", |e| e["t"] == "scan" && e["state"] == "error");
    assert_eq!(h.names(&root, true, ""), ["a.png"]);
}

#[test]
fn meta_settings_and_navigation() {
    let h = Harness::new();
    let lib = tempfile::tempdir().unwrap();
    let root = lib.path().canonicalize().unwrap();
    std::fs::create_dir_all(root.join("sub/deeper")).unwrap();
    let png = root.join("x.png");
    write_png(&png, 1, &[("invokeai_metadata", INVOKE_TEXT)]);

    let meta = h.call("meta", json!({ "path": png.to_str().unwrap() }));
    assert_eq!(meta["source"], "invokeai");
    assert_eq!(meta["seed"], "2718281828");
    assert_eq!(meta["loras"][0]["name"], "cutaway-diagram-xl");
    assert_eq!(meta["raw"][0][0], "invokeai_metadata");

    assert_eq!(h.call("settings", json!({})), json!({}));
    h.call("set_setting", json!({ "key": "tile", "value": "240" }));
    assert_eq!(h.call("settings", json!({}))["tile"], "240");

    let dirs = h.call("list_dirs", json!({ "path": root.to_str().unwrap() }));
    assert_eq!(dirs, json!([{ "name": "sub", "path": root.join("sub").to_str().unwrap(), "has_sub": true }]));
    assert!(h.call("roots", json!({})).as_array().unwrap().iter().any(|p| p["path"] == "/"));
    assert!(h.engine.call("no_such_method", &json!({})).is_err());
    assert!(h.engine.call("list_dirs", &json!({ "path": "/no/such/dir" })).is_err());
}

#[test]
fn thumbnails_for_images_and_warm_queue() {
    let h = Harness::new();
    let lib = tempfile::tempdir().unwrap();
    let root = lib.path().canonicalize().unwrap();
    for i in 0..6 {
        std::fs::write(root.join(format!("img{i}.png")), png_with_text(640, 400, i, &[])).unwrap();
    }
    h.call("set_folder", json!({ "dir": root.to_str().unwrap(), "recursive": false, "poll_ms": 0 }));
    h.wait_scan_done();
    let r = h.call("query", json!({ "dir": root.to_str().unwrap(), "sort": "name" }));
    let row = &r["rows"][0];
    let path = root.join(row[2].as_str().unwrap());
    let (mtime, size) = (row[6].as_i64().unwrap(), row[7].as_i64().unwrap());

    let bytes = h.engine.thumbs.get(path.to_str().unwrap(), mtime, size, 0).unwrap();
    let img = image::load_from_memory(&bytes).unwrap();
    assert_eq!((img.width(), img.height()), (410, 256));

    // Pre-rendering fills the cache for the rest of the folder.
    let queued = h.call("warm", json!({ "dir": root.to_str().unwrap(), "sort": "name" }));
    assert_eq!(queued["queued"], 6);
    let cache = h._dirs.path().join("cache/thumbs/0");
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let n = walk_count(&cache);
        if n == 6 {
            break;
        }
        assert!(Instant::now() < deadline, "only {n} of 6 thumbnails were pre-rendered");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn walk_count(dir: &Path) -> usize {
    let Ok(rd) = std::fs::read_dir(dir) else { return 0 };
    rd.flatten().map(|e| if e.path().is_dir() { walk_count(&e.path()) } else { e.path().extension().map_or(0, |x| (x == "jpg") as usize) }).sum()
}
