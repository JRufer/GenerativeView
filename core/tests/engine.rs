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
    // Whole words: "storm" is not the other image's "stormy sea", unless asked.
    assert_eq!(h.names(&root, true, "lighthouse storm"), ["ComfyUI_00001_.png"]);
    assert_eq!(h.names(&root, true, "lighthouse storm*"), ["00003-a1111.png", "ComfyUI_00001_.png"]);
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

    // ---- exact filters, and the usage counts that feed them ----------------
    assert_eq!(h.names(&root, true, "seed:=22"), ["ComfyUI_00002_.png"]);
    assert_eq!(h.names(&root, true, "seed:=2"), Vec::<String>::new());
    assert_eq!(h.names(&root, true, "model:=flux1-dev.safetensors"), ["ComfyUI_00001_.png"]);
    assert_eq!(h.names(&root, true, "model:=\"juggernaut xl v9\""), ["invoke.png"]);
    assert_eq!(h.names(&root, true, "lora:=add_detail"), ["00003-a1111.png"]);
    assert_eq!(h.names(&root, true, "lora:=add"), Vec::<String>::new());
    assert_eq!(h.names(&root, true, "sampler:=euler"), ["ComfyUI_00001_.png", "ComfyUI_00002_.png"]);
    let usage = h.call("usage", json!({ "dir": root.to_str().unwrap(), "recursive": true }));
    assert_eq!((usage["total"].as_u64(), usage["generated"].as_u64()), (Some(5), Some(5)));
    let group = |kind: &str| usage["groups"].as_array().unwrap().iter().find(|g| g["kind"] == kind).unwrap().clone();
    let models = group("model");
    assert_eq!(models["distinct"], 5, "{models}");
    assert!(models["items"].as_array().unwrap().iter().any(|i| i["value"] == "Juggernaut XL v9" && i["count"] == 1));
    assert_eq!(group("lora")["items"].as_array().unwrap().len(), 2);
    assert_eq!(group("source")["items"][0], json!({ "value": "comfyui", "count": 3, "trend": group("source")["items"][0]["trend"] }));
    assert_eq!(usage["timeline"].as_array().unwrap().iter().map(|b| b["count"].as_u64().unwrap()).sum::<u64>(), 5);
    let scoped = h.call("usage", json!({ "dir": root.join("portraits").to_str().unwrap(), "recursive": false }));
    assert_eq!(scoped["total"], 1);

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

/// Put the reference CLIP model where the engine looks for one.
fn install_mini_model(h: &Harness) {
    let dir = h._dirs.path().join("data/models").join(gvcore::clip::MODEL);
    std::fs::create_dir_all(&dir).unwrap();
    for name in ["config.json", "tokenizer.json", "model.safetensors"] {
        std::fs::copy(fixture_path("clip_mini").join(name), dir.join(name)).unwrap();
    }
}

#[test]
fn content_search_embeds_and_ranks() {
    use gvcore::clip::{image::prepare, model, store, tokenizer::Tokenizer};

    let h = Harness::new();
    let lib = tempfile::tempdir().unwrap();
    let root = lib.path().canonicalize().unwrap();
    let dir = root.to_str().unwrap().to_string();
    let names: Vec<String> = (0..11).map(|i| format!("img{i:02}.png")).collect();
    for (i, name) in names.iter().enumerate() {
        std::fs::write(root.join(name), png_with_text(200 + 13 * i as u32, 160, i as u32 * 7 + 1, &[])).unwrap();
    }
    std::fs::write(root.join("broken.png"), b"not a picture at all").unwrap();
    h.call("set_folder", json!({ "dir": dir, "recursive": true, "poll_ms": 0 }));
    h.wait_scan_done();
    let scope = json!({ "dir": dir, "recursive": true });
    let content_done = |h: &Harness| h.wait("content pass", |e| e["t"] == "content" && e["state"] != "indexing");

    // ---- without the model: says so, and does nothing ----------------------
    let status = h.call("content_status", scope.clone());
    assert_eq!((status["installed"].as_bool(), status["embedded"].as_u64(), status["total"].as_u64()), (Some(false), Some(0), Some(12)));
    assert_eq!(status["model"], gvcore::clip::MODEL);
    assert_eq!(status["files"].as_array().unwrap().len(), 3);
    assert!(status["source"].as_str().unwrap().starts_with("https://huggingface.co/"));
    h.call("content_index", scope.clone());
    assert_eq!(content_done(&h)["state"], "no_model");
    let refused = h.engine.call("content_query_json", &json!({ "dir": dir, "recursive": true, "text": "a fox" }));
    assert!(refused.unwrap_err().contains("not installed"));

    // ---- with it: every readable picture gets a vector ---------------------
    install_mini_model(&h);
    assert_eq!(h.call("content_status", scope.clone())["installed"], true);
    h.call("content_index", scope.clone());
    let done = content_done(&h);
    assert_eq!((done["state"].as_str(), done["done"].as_u64(), done["total"].as_u64()), (Some("done"), Some(12), Some(12)), "{done}");
    let status = h.call("content_status", scope.clone());
    assert_eq!((status["embedded"].as_u64(), status["total"].as_u64(), status["indexing"].as_bool()), (Some(11), Some(12), Some(false)));

    // A second pass has nothing to do: the broken file is not tried again.
    h.call("content_index", scope.clone());
    let again = content_done(&h);
    assert_eq!((again["state"].as_str(), again["total"].as_u64()), (Some("done"), Some(0)));

    // ---- a search answers as the model itself would ------------------------
    // Worked out here from scratch: each picture's vector, how the everyday
    // descriptions score against it, and so how well a description fits.
    let model_dir = h._dirs.path().join("data/models").join(gvcore::clip::MODEL);
    let vision = model::Vision::load(&model_dir).unwrap();
    let text = model::Text::load(&model_dir).unwrap();
    let tokenizer = Tokenizer::load(&model_dir.join("tokenizer.json")).unwrap();
    let embed = |description: &str| text.embed(&tokenizer.encode(&description.to_lowercase())).unwrap();
    let everyday: Vec<Vec<f32>> = include_str!("../src/clip/everyday.txt").lines().map(embed).collect();
    let all = h.call("query", json!({ "dir": dir, "recursive": true, "sort": "name" }));
    let pictures: Vec<(String, Vec<f32>)> = all["rows"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|row| row[2] != "broken.png")
        .map(|row| {
            let name = row[2].as_str().unwrap().to_string();
            let path = root.join(&name);
            let jpeg = h.engine.thumbs.get(path.to_str().unwrap(), row[6].as_i64().unwrap(), row[7].as_i64().unwrap(), 0).unwrap();
            let picture = prepare(&image::load_from_memory(&jpeg).unwrap(), vision.image_size).unwrap();
            (name, store::unpack(&store::pack(&vision.embed(&picture))))
        })
        .collect();
    let dot = |a: &[f32], b: &[f32]| a.iter().zip(b).map(|(x, y)| x * y).sum::<f32>();
    // (level, name) for every picture, best first. The level is how far the
    // description stands above the picture's ordinary run of scores, in
    // spreads of that run, with 1 where a match begins.
    let fits = |description: &str| {
        let query = embed(description);
        let mut out: Vec<(f32, String)> = pictures
            .iter()
            .map(|(name, picture)| {
                let mut scores: Vec<f32> = everyday.iter().map(|line| dot(line, picture)).collect();
                scores.sort_by(f32::total_cmp);
                let middle = scores[scores.len() / 2];
                let mut apart: Vec<f32> = scores.iter().map(|score| (score - middle).abs()).collect();
                apart.sort_by(f32::total_cmp);
                let spread = apart[apart.len() / 2] * 1.4826;
                ((dot(&query, picture) - middle) / spread / gvcore::clip::CLEAR, name.clone())
            })
            .collect();
        out.sort_by(|a, b| b.0.total_cmp(&a.0));
        out
    };
    let found = |description: &str, bar: Option<f64>, sort: Option<&str>| {
        let mut args = json!({ "dir": dir, "recursive": true, "text": description });
        if let Some(bar) = bar {
            args["bar"] = json!(bar);
        }
        if let Some(sort) = sort {
            args["sort"] = json!(sort);
        }
        let r = h.call("content_query_json", args);
        r["rows"].as_array().unwrap().iter().map(|row| row[2].as_str().unwrap().to_string()).collect::<Vec<_>>()
    };
    let names_of = |fits: &[(f32, String)]| fits.iter().map(|(_, name)| name.clone()).collect::<Vec<_>>();
    for description in ["a red fox asleep in fresh snow", "lighthouse", "A  Red FOX asleep in fresh snow"] {
        let expected = fits(description);
        // The sums are added up in a different order here than in the app,
        // so the two can differ in the last digits: stay clear of ties, and
        // of pictures that sit right on the bar.
        let gap = expected.windows(2).map(|pair| pair[0].0 - pair[1].0).fold(f32::MAX, f32::min);
        let edge = expected.iter().map(|(level, _)| (level - 1.0).abs()).fold(f32::MAX, f32::min);
        println!("{description}: closest two {gap:.1e} apart, closest to the bar {edge:.1e} from it");
        assert!(gap > 2e-4 && edge > 2e-4, "{description}: {expected:?}");
        // With the bar on the floor: every picture, best match first.
        assert_eq!(found(description, Some(-1e6), None), names_of(&expected), "{description}");
        // With the bar where the app has it: only what clears it.
        let clear: Vec<(f32, String)> = expected.iter().filter(|(level, _)| *level >= 1.0).cloned().collect();
        assert_eq!(found(description, None, None), names_of(&clear), "{description}");
        // With the bar between two pictures: the better ones and no others.
        let between = (expected[3].0 + expected[4].0) as f64 / 2.0;
        assert_eq!(found(description, Some(between), None), names_of(&expected[..4]), "{description}");
        // In another order: the same pictures, in that order.
        let mut by_name = names_of(&expected[..4]);
        by_name.sort();
        assert_eq!(found(description, Some(between), Some("name")), by_name, "{description}");
        by_name.reverse();
        assert_eq!(found(description, Some(between), Some("name_desc")), by_name, "{description}");
        // And with the bar out of reach: nothing, rather than the least bad.
        assert_eq!(found(description, Some(1e6), None), Vec::<String>::new(), "{description}");
    }
    assert_ne!(found("a red fox asleep in fresh snow", Some(-1e6), None), found("lighthouse", Some(-1e6), None));

    // ---- more like this: the pictures nearest one, nearest first -----------
    let target = root.join("img03.png");
    let by_likeness = {
        let (_, mine) = pictures.iter().find(|(n, _)| n == "img03.png").unwrap();
        let mut all: Vec<(f32, String)> = pictures.iter().map(|(n, v)| (dot(mine, v), n.clone())).collect();
        all.sort_by(|a, b| b.0.total_cmp(&a.0));
        all
    };
    let similar = |bar: f64, extra: &str| {
        let text = format!("{extra} similar:\"{}\"", target.display());
        let r = h.call("query", json!({ "dir": dir, "recursive": true, "text": text, "sort": "relevance", "bar": bar }));
        r["rows"].as_array().unwrap().iter().map(|row| row[2].as_str().unwrap().to_string()).collect::<Vec<_>>()
    };
    let everything = similar(-1.0, "");
    assert_eq!(everything, names_of(&by_likeness), "every picture, most alike first");
    assert_eq!(everything[0], "img03.png");
    // Other terms narrow it as usual.
    assert_eq!(similar(-1.0, "-name:=img03.png"), names_of(&by_likeness[1..]));
    // Asked for a picture not looked at yet, it is looked at there and then.
    let fresh = root.join("unseen.png");
    std::fs::write(&fresh, png_with_text(90, 90, 123, &[])).unwrap();
    // The prompt check: nothing for a picture not looked at, unless asked
    // to look.
    let prompt = "masterpiece, a lighthouse, (stormy sea:1.3), <lora:waves:0.7> best quality";
    let check = |make: bool| h.call("check_prompt", json!({ "path": fresh.to_str().unwrap(), "prompt": prompt, "make": make }));
    assert!(check(false).is_null());
    let checked = check(true);
    let phrases = checked["phrases"].as_array().unwrap();
    let texts: Vec<&str> = phrases.iter().map(|p| p["text"].as_str().unwrap()).collect();
    assert_eq!(texts, ["masterpiece", "a lighthouse", "stormy sea", "best quality"]);
    let scored: Vec<bool> = phrases.iter().map(|p| p["checked"].as_bool().unwrap()).collect();
    assert_eq!(scored, [false, true, true, false]);
    assert!(phrases[1]["level"].as_f64().is_some() && phrases[1]["seen"].is_boolean(), "{checked}");
    assert_eq!(checked["checked"], 2);
    // Looked at now, so it answers without being asked to look.
    assert_eq!(check(false)["checked"], 2);
    let described = h.call("describe", json!({ "path": fresh.to_str().unwrap() }));
    assert!(described["prompt"].as_str().unwrap().contains("highly detailed"), "{described}");
    assert!(described["style"].as_str().is_some());
    std::fs::remove_file(&fresh).unwrap();

    // The packed form the UI reads carries the same rows.
    let packed = match h.engine.request("content_query", &json!({ "dir": dir, "recursive": true, "text": "lighthouse", "bar": -1e6 })).unwrap() {
        gvcore::engine::Reply::Bytes(bytes) => bytes,
        gvcore::engine::Reply::Json(_) => panic!("content_query should answer in the packed layout"),
    };
    assert_eq!(&packed[0..4], b"GVQ1");
    assert_eq!(u32::from_le_bytes(packed[4..8].try_into().unwrap()), 11);

    // ---- new and changed pictures are picked up by the next pass -----------
    std::fs::write(root.join("new.png"), png_with_text(300, 300, 99, &[])).unwrap();
    std::fs::write(root.join("img00.png"), png_with_text(120, 400, 55, &[])).unwrap();
    h.expect_names(&root, true, "name:=new.png", &["new.png"]);
    std::thread::sleep(Duration::from_millis(400));
    h.call("content_index", scope.clone());
    let done = content_done(&h);
    assert_eq!(done["state"], "done");
    assert!(done["total"].as_u64().unwrap() >= 1, "{done}");
    h.call("content_index", scope.clone());
    content_done(&h);
    assert_eq!(h.call("content_status", scope)["embedded"], 12);
    assert_eq!(found("lighthouse", Some(-1e6), None).len(), 12);
}

#[test]
fn notes_live_in_the_folder() {
    let h = Harness::new();
    let lib = tempfile::tempdir().unwrap();
    let root = lib.path().canonicalize().unwrap();
    let dir = root.to_str().unwrap().to_string();
    std::fs::create_dir(root.join("sub")).unwrap();
    for (i, name) in ["a.png", "b.png", "sub/c.png"].iter().enumerate() {
        write_png(&root.join(name), i as u32, &[("prompt", &comfy_prompt("a fox", i as u64, "flux.safetensors"))]);
    }
    h.call("set_folder", json!({ "dir": dir, "recursive": true, "poll_ms": 0 }));
    h.wait_scan_done();
    let path = |name: &str| root.join(name).to_str().unwrap().to_string();

    // Rated from the app: written beside the pictures, one file per folder.
    let out = h.call("notes_set", json!({ "paths": [path("a.png"), path("sub/c.png")], "rating": 4, "flag": "keep", "add": ["Best"] }));
    assert_eq!(out[1], json!({ "rating": 4, "flag": "keep", "collections": ["Best"], "audience": 0 }));
    let file: Value = serde_json::from_str(&std::fs::read_to_string(root.join(".generativeview.json")).unwrap()).unwrap();
    assert_eq!(file["images"]["a.png"]["rating"], 4);
    assert!(root.join("sub/.generativeview.json").exists());
    h.expect_names(&root, true, "rating:4 flag:keep collection:=best", &["a.png", "c.png"]);
    assert_eq!(h.call("notes_get", json!({ "path": path("a.png") }))["collections"], json!(["Best"]));
    assert_eq!(h.call("collections", json!({}))[0], json!({ "name": "Best", "count": 2 }));

    // Changed on another machine and synced in: the index follows.
    std::fs::write(root.join(".generativeview.json"), r#"{"generativeview":1,"images":{"b.png":{"rating":5,"flag":"reject"}}}"#).unwrap();
    h.expect_names(&root, true, "rating:5", &["b.png"]);
    h.expect_names(&root, true, "rating:4", &["c.png"]);
    assert!(h.call("notes_get", json!({ "path": path("a.png") }))["collections"].as_array().unwrap().is_empty());

    // Opened afresh (another session, an index rebuilt): read from the files.
    drop(h);
    let h = Harness::new();
    h.call("set_folder", json!({ "dir": dir, "recursive": true, "poll_ms": 0 }));
    h.wait_scan_done();
    h.expect_names(&root, true, "flag:reject", &["b.png"]);
    h.expect_names(&root, true, "collection:best", &["c.png"]);
    let usage = h.call("usage", json!({ "dir": dir, "recursive": true, "text": "fox" }));
    let ratings = usage["groups"].as_array().unwrap().iter().find(|g| g["kind"] == "rating").unwrap();
    assert_eq!(ratings["items"].as_array().unwrap().len(), 3);
}

#[test]
fn audience_levels_filter_and_set_by_hand() {
    let h = Harness::new();
    let lib = tempfile::tempdir().unwrap();
    let root = lib.path().canonicalize().unwrap();
    let dir = root.to_str().unwrap().to_string();
    let pictures = [
        ("fox.png", "a red fox in snow"),
        ("knight.png", "a knight with a sword"),
        ("soldier.png", "a soldier on a battlefield, blood, smoke"),
        ("zombie.png", "a zombie, gore, horror"),
    ];
    for (i, (name, prompt)) in pictures.iter().enumerate() {
        write_png(&root.join(name), i as u32, &[("prompt", &comfy_prompt(prompt, i as u64, "flux.safetensors"))]);
    }
    write_png(&root.join("bare.png"), 9, &[]);
    h.call("set_folder", json!({ "dir": dir, "recursive": true, "poll_ms": 0 }));
    h.wait_scan_done();
    let path = |name: &str| root.join(name).to_str().unwrap().to_string();
    let levels = |h: &Harness| -> Vec<(String, u64)> {
        let r = h.call("query", json!({ "dir": dir, "recursive": true, "text": "", "sort": "name" }));
        let marks = r["marks"].as_array().unwrap();
        r["rows"].as_array().unwrap().iter().zip(marks).map(|(row, m)| (row[2].as_str().unwrap().to_string(), m.as_u64().unwrap() >> 5)).collect()
    };

    // No content-search model: the prompt decides, and each level rides in
    // the top bits of the row's mark.
    assert_eq!(
        levels(&h),
        [("bare.png".to_string(), 0), ("fox.png".into(), 1), ("knight.png".into(), 2), ("soldier.png".into(), 3), ("zombie.png".into(), 4)]
    );
    h.expect_names(&root, true, "audience:..pg13", &["fox.png", "knight.png", "soldier.png"]);
    h.expect_names(&root, true, "audience:..pg|none", &["bare.png", "fox.png", "knight.png"]);
    h.expect_names(&root, true, "aud:r..", &["zombie.png"]);
    assert_eq!(h.call("count", json!({ "dir": dir, "recursive": true, "text": "audience:g" }))["count"], 1);

    // Set by hand: it wins, and is kept in the folder's notes file.
    h.call("audience_set", json!({ "path": path("fox.png"), "level": 4 }));
    h.expect_names(&root, true, "audience:r..", &["fox.png", "zombie.png"]);
    let file: Value = serde_json::from_str(&std::fs::read_to_string(root.join(".generativeview.json")).unwrap()).unwrap();
    assert_eq!(file["images"]["fox.png"]["audience"], "r");
    let info = h.call("audience_info", json!({ "path": path("fox.png"), "prompt": "a red fox in snow" }));
    assert_eq!((info["level"].as_u64(), info["own"].as_u64(), info["prompt"].as_u64()), (Some(4), Some(4), Some(1)));
    assert_eq!(info["model"], false);
    assert!(info["image"].is_null());
    h.call("audience_set", json!({ "path": path("fox.png"), "level": 0 }));
    h.expect_names(&root, true, "audience:g", &["fox.png"]);

    // By the picture alone, with no model: nothing is rated.
    h.call("set_setting", json!({ "key": "audience_source", "value": "image" }));
    assert!(levels(&h).iter().all(|(_, l)| *l == 0));

    // With the model, once it has looked: every picture has a picture reading.
    install_mini_model(&h);
    h.call("content_index", json!({ "dir": dir, "recursive": true }));
    h.wait("content pass", |e| e["t"] == "content" && e["state"] == "done");
    assert!(levels(&h).iter().all(|(_, l)| *l >= 1), "{:?}", levels(&h));
    let info = h.call("audience_info", json!({ "path": path("zombie.png"), "prompt": "a zombie, gore, horror" }));
    assert_eq!(info["model"], true);
    assert!(info["image"].as_u64().unwrap() >= 1);
    // The stricter reading is never below the prompt's.
    h.call("set_setting", json!({ "key": "audience_source", "value": "both" }));
    assert!(levels(&h).iter().find(|(n, _)| n == "zombie.png").unwrap().1 >= 4);

    // Aiming a prompt lower takes parts out and guards the negative.
    let aimed = h.call("audience_steer", json!({ "prompt": "a zombie, gore, horror", "negative": "lowres", "target": 3 }));
    assert_eq!(aimed["prompt"], "a zombie, horror");
    assert_eq!(aimed["negative"], "lowres, blood, gore");
}

#[test]
fn upscale_runs_and_reports() {
    let h = Harness::new();
    let lib = tempfile::tempdir().unwrap();
    let root = lib.path().canonicalize().unwrap();
    let models = h.call("upscale_models", json!({}));
    assert_eq!(models["models"].as_array().unwrap().len(), 2);
    assert_eq!(models["models"][0]["installed"], false);
    assert!(models["source"].as_str().unwrap().starts_with("https://github.com/xinntao/Real-ESRGAN/"));
    write_png(&root.join("a.png"), 3, &[("parameters", "a fox\nSteps: 20, Seed: 7")]);
    // Without the model: an error event, not a crash.
    let job = h.call("upscale", json!({ "path": root.join("a.png").to_str().unwrap(), "model": "general", "factor": 2, "metadata": "copy" }))["job"].clone();
    let e = h.wait("upscale end", |e| e["t"] == "upscale" && e["state"] != "running");
    assert_eq!((e["job"].clone(), e["state"].as_str()), (job, Some("error")));
    assert!(h.engine.call("upscale", &json!({ "path": "x", "model": "nope" })).is_err());
    // The limits are given to the panel, and a size past them is refused at
    // once rather than after the model has run; any factor within them is
    // taken, not only 2 and 4.
    assert_eq!(models["max_side"], 8192);
    assert_eq!(models["max_pixels"], 40_000_000);
    assert_eq!(models["max_factor"], 16.0);
    let a = root.join("a.png").to_str().unwrap().to_string();
    assert!(h.engine.call("upscale", &json!({ "path": a, "model": "general", "factor": 1.0 })).is_err());
    assert!(h.engine.call("upscale", &json!({ "path": a, "model": "general", "factor": 20.0 })).is_err());
    let job = h.call("upscale", json!({ "path": a, "model": "general", "factor": 2.5, "metadata": "copy" }))["job"].clone();
    let e = h.wait("upscale end", |e| e["t"] == "upscale" && e["state"] != "running" && e["job"] == job);
    // Taken, then an error only for want of the model.
    assert_eq!(e["state"], "error");
}

#[test]
fn collections_are_deleted_and_deleted_pictures_forgotten() {
    let tmp = tempfile::tempdir().unwrap();
    let h = Harness::new();
    let root = tmp.path().join("pics");
    std::fs::create_dir_all(root.join("sub")).unwrap();
    let dir = root.to_str().unwrap().to_string();
    for (i, name) in ["a.png", "b.png", "sub/c.png"].iter().enumerate() {
        write_png(&root.join(name), i as u32, &[("prompt", &comfy_prompt("a heron", i as u64, "flux.safetensors"))]);
    }
    h.call("set_folder", json!({ "dir": dir, "recursive": true, "poll_ms": 0 }));
    h.wait_scan_done();
    let path = |name: &str| root.join(name).to_str().unwrap().to_string();

    h.call("notes_set", json!({ "paths": [path("a.png"), path("sub/c.png")], "add": ["Herons", "Keep"] }));
    h.call("notes_set", json!({ "paths": [path("b.png")], "add": ["herons"], "rating": 3 }));
    assert_eq!(h.call("collections", json!({}))[0], json!({ "name": "Herons", "count": 3 }));

    // Deleting a collection empties it in every folder, whatever the case;
    // the pictures, their stars and other collections stay.
    assert_eq!(h.call("collection_delete", json!({ "name": "HERONS" })), json!({ "removed": 3 }));
    let names: Vec<Value> = h.call("collections", json!({})).as_array().unwrap().iter().map(|c| c["name"].clone()).collect();
    assert_eq!(names, vec![json!("Keep")]);
    assert_eq!(h.call("notes_get", json!({ "path": path("b.png") }))["rating"], 3);
    assert_eq!(h.call("notes_get", json!({ "path": path("sub/c.png") }))["collections"], json!(["Keep"]));
    assert!(root.join("a.png").exists());

    // A deleted picture leaves the index and its folder's notes.
    std::fs::remove_file(root.join("a.png")).unwrap();
    h.call("forget", json!({ "path": path("a.png") }));
    h.expect_names(&root, true, "", &["b.png", "c.png"]);
    let file: Value = serde_json::from_str(&std::fs::read_to_string(root.join(".generativeview.json")).unwrap()).unwrap();
    assert!(file["images"].get("a.png").is_none());
    assert_eq!(h.call("collections", json!({}))[0], json!({ "name": "Keep", "count": 1 }));
}

#[test]
fn near_duplicates_are_found_and_grouped() {
    let h = Harness::new();
    let lib = tempfile::tempdir().unwrap();
    let root = lib.path().canonicalize().unwrap();
    // A disc on a ramp, placed at (cx, cy), lifted by `lift`.
    let picture = |cx: f32, cy: f32, lift: u8| {
        image::RgbImage::from_fn(320, 480, |x, y| {
            let ramp = (x + y) as f32 / 800.0 * 120.0;
            let d = ((x as f32 - cx * 320.0).powi(2) + (y as f32 - cy * 480.0).powi(2)).sqrt();
            let v = (ramp + if d < 60.0 { 110.0 } else { 0.0 }) as u8;
            image::Rgb([v.saturating_add(lift), v, v])
        })
    };
    for (name, cx, cy, lift) in [("a.png", 0.3, 0.4, 0), ("b.png", 0.8, 0.8, 0), ("c.png", 0.3, 0.4, 5), ("d.png", 0.7, 0.2, 0), ("e.png", 0.7, 0.2, 3)] {
        let mut png = Vec::new();
        picture(cx, cy, lift).write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        std::fs::write(root.join(name), png).unwrap();
    }
    h.call("set_folder", json!({ "dir": root.to_str().unwrap(), "recursive": false, "poll_ms": 0 }));
    h.wait_scan_done();
    // a and c, then d and e: each group together, in the order asked for.
    assert_eq!(h.names(&root, false, "is:duplicate"), ["a.png", "c.png", "d.png", "e.png"]);
    // With other terms too, the groups are found among what they leave.
    assert_eq!(h.names(&root, false, "is:duplicate -name:e.png"), ["a.png", "c.png"]);
    // Asked again, the fingerprints are remembered.
    assert_eq!(h.names(&root, false, "is:dupes"), ["a.png", "c.png", "d.png", "e.png"]);
    assert_eq!(h.names(&root, false, "").len(), 5);
}

#[test]
fn smart_collections_are_saved_beside_the_pictures() {
    let h = Harness::new();
    let lib = tempfile::tempdir().unwrap();
    let root = lib.path().canonicalize().unwrap();
    let dir = root.to_str().unwrap().to_string();
    let sub = root.join("sub");
    std::fs::create_dir(&sub).unwrap();
    for (i, name) in ["a.png", "b.png", "sub/c.png"].iter().enumerate() {
        let model = if i == 1 { "sdxl.safetensors" } else { "flux.safetensors" };
        write_png(&root.join(name), i as u32, &[("prompt", &comfy_prompt("a fox", i as u64, model))]);
    }
    h.call("set_folder", json!({ "dir": dir, "recursive": true, "poll_ms": 0 }));
    h.wait_scan_done();
    let path = |name: &str| root.join(name).to_str().unwrap().to_string();
    h.call("notes_set", json!({ "paths": [path("a.png"), path("sub/c.png")], "rating": 5, "add": ["Mine"] }));
    h.expect_names(&root, true, "rating:5", &["a.png", "c.png"]);

    h.call("smart_set", json!({ "dir": dir, "name": "Flux five", "query": "model:=flux.safetensors rating:>=5" }));
    let file: Value = serde_json::from_str(&std::fs::read_to_string(root.join(".generativeview.json")).unwrap()).unwrap();
    assert_eq!(file["smart"], json!([{ "name": "Flux five", "query": "model:=flux.safetensors rating:>=5" }]));

    // Listed with how many pictures in view match it now.
    let list = h.call("smart_list", json!({ "dir": dir, "recursive": true }));
    assert_eq!(list, json!([{ "name": "Flux five", "query": "model:=flux.safetensors rating:>=5", "dir": dir, "count": 2 }]));
    assert_eq!(h.call("count", json!({ "dir": dir, "recursive": false, "text": "model:=flux.safetensors rating:>=5" })), json!({ "count": 1 }));

    // A sub-folder sees the ones saved above it; its own come first and win a shared name.
    let sub_dir = sub.to_str().unwrap().to_string();
    h.call("smart_set", json!({ "dir": sub_dir, "name": "flux FIVE", "query": "rating:5" }));
    h.call("smart_set", json!({ "dir": sub_dir, "name": "Sub only", "query": "fox" }));
    let list = h.call("smart_list", json!({ "dir": sub_dir, "recursive": false }));
    let names: Vec<&str> = list.as_array().unwrap().iter().map(|s| s["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["flux FIVE", "Sub only"]);
    assert_eq!(list[0]["dir"], json!(sub_dir));

    // Rename in place, then delete; ratings and collections in the file stay.
    h.call("smart_set", json!({ "dir": dir, "name": "Best flux", "query": "model:=flux.safetensors", "old_name": "flux five" }));
    assert_eq!(h.call("smart_list", json!({ "dir": dir, "recursive": true }))[0]["name"], "Best flux");
    assert!(h.engine.call("smart_set", &json!({ "dir": dir, "name": "", "query": "x" })).is_err());
    h.call("collection_delete", json!({ "name": "Mine" }));
    assert_eq!(h.call("smart_list", json!({ "dir": dir, "recursive": true }))[0]["count"], 2, "deleting a collection leaves smart ones");
    h.call("smart_delete", json!({ "dir": dir, "name": "BEST FLUX" }));
    assert_eq!(h.call("smart_list", json!({ "dir": dir, "recursive": true })), json!([]));
    assert_eq!(h.call("notes_get", json!({ "path": path("a.png") }))["rating"], 5);
}

#[test]
fn artist_tools_learn_from_ratings() {
    let h = Harness::new();
    let lib = tempfile::tempdir().unwrap();
    let root = lib.path().canonicalize().unwrap();
    let dir = root.to_str().unwrap().to_string();
    std::fs::create_dir(root.join("dupes")).unwrap();
    let path = |name: &str| root.join(name).to_str().unwrap().to_string();
    // Ten liked pictures with rim lighting, ten disliked with 8k.
    let mut liked = Vec::new();
    let mut disliked = Vec::new();
    for i in 0..10u32 {
        let good = format!("good{i}.png");
        let bad = format!("bad{i}.png");
        write_png(&root.join(&good), i * 2 + 1, &[("prompt", &comfy_prompt(&format!("a red fox {i}, rim lighting, snow"), i as u64, "flux.safetensors"))]);
        write_png(&root.join(&bad), i * 2 + 2, &[("prompt", &comfy_prompt(&format!("a red fox {i}, 8k, snow"), i as u64, "flux.safetensors"))]);
        liked.push(path(&good));
        disliked.push(path(&bad));
    }
    // Two near-duplicates, one rated better.
    let disc = |lift: u8| {
        let img = image::RgbImage::from_fn(320, 480, |x, y| {
            let d = ((x as f32 - 100.0).powi(2) + (y as f32 - 200.0).powi(2)).sqrt();
            let v = ((x + y) as f32 / 800.0 * 120.0 + if d < 60.0 { 110.0 } else { 0.0 }) as u8;
            image::Rgb([v.saturating_add(lift), v, v])
        });
        let mut png = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        png
    };
    std::fs::write(root.join("dupes/a.png"), disc(0)).unwrap();
    std::fs::write(root.join("dupes/b.png"), disc(4)).unwrap();
    h.call("set_folder", json!({ "dir": dir, "recursive": true, "poll_ms": 0 }));
    h.wait_scan_done();
    h.call("notes_set", json!({ "paths": liked, "rating": 5 }));
    h.call("notes_set", json!({ "paths": disliked, "rating": 1 }));
    h.call("notes_set", json!({ "paths": [path("dupes/b.png")], "rating": 4 }));
    h.expect_names(&root, true, "rating:5", &(0..10).map(|i| format!("good{i}.png")).collect::<Vec<_>>().iter().map(String::as_str).collect::<Vec<_>>());

    // ---- What works -------------------------------------------------------
    let works = h.call("what_works", json!({ "dir": dir, "recursive": true }));
    // The rated picture with no prompt is not counted.
    assert_eq!((works["liked"].as_u64(), works["disliked"].as_u64()), (Some(10), Some(10)), "{works}");
    // In every picture alike: not listed.
    assert_eq!(works["groups"][1]["items"].as_array().unwrap().len(), 1, "{works}");
    assert!(works["groups"][2]["items"].as_array().unwrap().is_empty(), "{works}");
    let keep = &works["groups"][0]["items"][0];
    assert_eq!(keep["label"], "rim lighting");
    assert_eq!(works["groups"][1]["items"][0]["label"], "8k");
    // Its search shows its pictures.
    assert_eq!(h.names(&root, true, keep["query"].as_str().unwrap()).len(), 10);
    assert_eq!(works["models"][0]["label"], "flux");
    let flux = h.call("what_works", json!({ "dir": dir, "recursive": true, "model": "flux.safetensors" }));
    assert_eq!(flux["liked"], 10);

    // ---- Prompt Doctor, before content search has a model ------------------
    let doctor = h.call("prompt_doctor", json!({ "path": path("bad0.png"), "prompt": "a red fox, 8k, snow", "model": "flux.safetensors" }));
    let kinds: Vec<(&str, &str)> = doctor["suggestions"].as_array().unwrap().iter().map(|s| (s["kind"].as_str().unwrap(), s["phrases"][0].as_str().unwrap())).collect();
    assert_eq!(kinds, vec![("remove", "8k"), ("add", "rim lighting")], "{doctor}");
    assert_eq!(doctor["checked"], false);

    // ---- with the model: describe, heat, breed, best of group ---------------
    install_mini_model(&h);
    h.call("content_index", json!({ "dir": dir, "recursive": true }));
    h.wait("content pass", |e| e["t"] == "content" && e["state"] == "done" && e["total"].as_u64().unwrap_or(0) > 0);
    let described = h.call("describe_groups", json!({ "path": path("good0.png") }));
    let names: Vec<&str> = described["groups"].as_array().unwrap().iter().map(|g| g["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["subject", "setting", "style", "light"]);
    assert!(described["prompt"].is_string());
    let heat = h.call("phrase_heat", json!({ "path": path("good0.png"), "phrase": "a red fox" }));
    assert_eq!(heat["grid"], 16);
    assert_eq!(heat["heat"].as_array().unwrap().len(), 256);
    assert!(heat["heat"].as_array().unwrap().iter().all(|v| (0.0..=1.0).contains(&v.as_f64().unwrap())));

    let bred = h.call("breed", json!({ "paths": [path("good0.png"), path("good1.png")], "count": 4, "seed": 5, "change": 0.5 }));
    let children = bred["children"].as_array().unwrap();
    assert!(!children.is_empty() && children.len() <= 4, "{bred}");
    assert_eq!(bred["rated"], true);
    for c in children {
        assert!(c["prompt"].as_str().unwrap().starts_with("a red fox"), "{c}");
        let stars = c["stars"].as_f64().unwrap();
        assert!((1.0..=5.0).contains(&stars));
        assert_eq!(c["cfg"].as_f64().map(|v| v >= 1.0), Some(true));
    }
    // Best first.
    let stars: Vec<f64> = children.iter().map(|c| c["stars"].as_f64().unwrap()).collect();
    assert!(stars.windows(2).all(|w| w[0] >= w[1]), "{stars:?}");
    assert!(h.engine.call("breed", &json!({ "paths": [path("good0.png")] })).is_err());

    let groups = h.call("duplicate_groups", json!({ "dir": root.join("dupes").to_str().unwrap(), "recursive": false, "text": "is:duplicate" }));
    assert_eq!(groups.as_array().unwrap().len(), 1, "{groups}");
    let group = &groups[0];
    let best = group["best"].as_u64().unwrap() as usize;
    assert!(group["paths"][best].as_str().unwrap().ends_with("b.png"), "{group}");
    assert_eq!(group["why"]["rated"], 4);
    // Any set of pictures, taken as one group: the best of a batch.
    let batch = h.call("duplicate_groups", json!({ "dir": dir, "recursive": true, "only": [path("bad0.png"), path("good3.png"), path("bad1.png")] }));
    assert_eq!(batch[0]["paths"].as_array().unwrap().len(), 3, "{batch}");
    assert!(batch[0]["paths"][batch[0]["best"].as_u64().unwrap() as usize].as_str().unwrap().ends_with("good3.png"));
}
