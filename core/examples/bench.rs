//! Time the core against a real folder:
//!
//!     cargo run --release --example bench -- /path/to/images [search terms]
//!
//! Uses a throwaway index and thumbnail cache, so it always measures a cold
//! first visit followed by a warm revisit.

use gvcore::engine::Engine;
use serde_json::{json, Value};
use std::sync::mpsc;
use std::sync::Arc;
use std::time::Instant;

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(dir) = args.next() else {
        eprintln!("usage: bench <folder> [search terms]");
        std::process::exit(2);
    };
    let search: Vec<String> = args.collect();
    let scratch = std::env::temp_dir().join(format!("gv-bench-{}", std::process::id()));
    let (tx, rx) = mpsc::channel::<Value>();
    let tx = std::sync::Mutex::new(tx);
    let engine = Engine::open(
        &scratch.join("data"),
        &scratch.join("cache"),
        Arc::new(move |e: String| {
            let _ = tx.lock().unwrap().send(serde_json::from_str(&e).unwrap());
        }),
    )
    .expect("open engine");
    let wait_done = || loop {
        let e = rx.recv().expect("engine event");
        if e["t"] == "scan" && (e["state"] == "done" || e["state"] == "error") {
            return e;
        }
    };

    let folder = json!({ "dir": dir, "recursive": true, "poll_ms": 0 });
    let t = Instant::now();
    engine.call("set_folder", &folder).unwrap();
    let done = wait_done();
    let cold = t.elapsed();
    let files = done["files"].as_u64().unwrap_or(0);
    println!("first visit : {files} files indexed in {:.2?} ({:.0} files/s)", cold, files as f64 / cold.as_secs_f64());

    let t = Instant::now();
    engine.call("set_folder", &folder).unwrap();
    let done = wait_done();
    println!("revisit     : {:.2?} to confirm nothing changed ({} re-parsed)", t.elapsed(), done["total"]);

    let query = |text: &str| {
        let t = Instant::now();
        let out = engine.call("query", &json!({ "dir": dir, "recursive": true, "text": text, "sort": "newest" })).unwrap();
        let elapsed = t.elapsed();
        let v: Value = serde_json::from_str(&out).unwrap();
        let n = v["rows"].as_array().map_or(0, Vec::len);
        println!("query {:<22}: {n:>6} hits in {elapsed:.2?} ({} KB of JSON)", format!("{text:?}"), out.len() / 1024);
        v
    };
    let all = query("");
    for term in ["fox", "blonde fox snow", "model:flux", "-fox", "ox", "lora:detail seed:1"] {
        query(term);
    }
    for term in &search {
        query(term);
    }

    // Thumbnails: the first screenful or two, cold then cached.
    let rows = all["rows"].as_array().cloned().unwrap_or_default();
    let dirs = all["dirs"].as_array().cloned().unwrap_or_default();
    let sample: Vec<(String, i64, i64)> = rows
        .iter()
        .filter(|r| r[3] == 0)
        .take(200)
        .map(|r| {
            let d = dirs[r[1].as_u64().unwrap() as usize].as_str().unwrap();
            (format!("{d}/{}", r[2].as_str().unwrap()), r[6].as_i64().unwrap(), r[7].as_i64().unwrap())
        })
        .collect();
    if !sample.is_empty() {
        let threads = std::thread::available_parallelism().map_or(2, |n| n.get());
        let run = |label: &str| {
            let t = Instant::now();
            let bytes: usize = std::thread::scope(|s| {
                let handles: Vec<_> = (0..threads)
                    .map(|k| {
                        let sample = &sample;
                        let engine = &engine;
                        s.spawn(move || {
                            sample.iter().skip(k).step_by(threads).map(|(p, m, sz)| engine.thumbs.get(p, *m, *sz, 0).map_or(0, |b| b.len())).sum::<usize>()
                        })
                    })
                    .collect();
                handles.into_iter().map(|h| h.join().unwrap()).sum()
            });
            let e = t.elapsed();
            println!(
                "thumbs {label:<6}: {} in {e:.2?} = {:.1} ms each wall, {:.0}/s on {threads} threads, avg {} KB",
                sample.len(),
                e.as_secs_f64() * 1000.0 / sample.len() as f64,
                sample.len() as f64 / e.as_secs_f64(),
                bytes / sample.len() / 1024
            );
        };
        run("cold");
        run("cached");
    }
    engine.close();
    let _ = std::fs::remove_dir_all(&scratch);
}
