//! Check and time the CLIP implementation on a model directory:
//!
//!     cargo run --release --example clip_check -- /path/to/model [ref.json] [tokenizer.json]
//!
//! With a `ref.json` (pixels, image, ids, text) it reports how far the
//! embeddings are from the reference; either way it times the encoders.

use gvcore::clip::model::{Text, Vision};
use gvcore::clip::tokenizer::Tokenizer;
use std::path::Path;
use std::time::Instant;

fn floats(v: &serde_json::Value) -> Vec<f32> {
    v.as_array().map(|a| a.iter().map(|x| x.as_f64().unwrap_or(0.0) as f32).collect()).unwrap_or_default()
}

fn gap(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| (x - y).abs()).fold(0.0, f32::max)
}

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = args.next().expect("usage: clip_check <model dir> [ref.json] [tokenizer.json]");
    let dir = Path::new(&dir);
    let t = Instant::now();
    let vision = Vision::load(dir).expect("picture encoder");
    println!("picture encoder loaded in {:.2?}", t.elapsed());
    let t = Instant::now();
    let text = Text::load(dir).expect("text encoder");
    println!("text encoder loaded in {:.2?}", t.elapsed());

    if let Some(reference) = args.next() {
        let r: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(reference).unwrap()).unwrap();
        let got = vision.embed(&floats(&r["pixels"]));
        println!("pictures: largest difference from the reference {:.2e}", gap(&got, &floats(&r["image"])));
        let ids: Vec<u32> = r["ids"].as_array().unwrap().iter().map(|i| i.as_u64().unwrap() as u32).collect();
        println!("text    : largest difference from the reference {:.2e}", gap(&text.embed(&ids).unwrap(), &floats(&r["text"])));
    }
    if let Some(tokenizer) = args.next() {
        let tokenizer = Tokenizer::load(Path::new(&tokenizer)).expect("tokenizer");
        println!("\"a photo of a cat\" -> {:?}", tokenizer.encode("a photo of a cat"));
    }

    let pictures: Vec<f32> = (0..8 * vision.pixels()).map(|i| ((i * 37 % 255) as f32 / 255.0 - 0.5) * 3.0).collect();
    for batch in [1, 8] {
        let t = Instant::now();
        let rounds = 3;
        for _ in 0..rounds {
            vision.embed(&pictures[..batch * vision.pixels()]);
        }
        println!("pictures: {:.1} ms each in batches of {batch}", t.elapsed().as_secs_f64() * 1000.0 / (rounds * batch) as f64);
    }
    let t = Instant::now();
    for _ in 0..10 {
        text.embed(&[1, 320, 1125, 539, 320, 2368, 2]).unwrap();
    }
    println!("text    : {:.1} ms per query", t.elapsed().as_secs_f64() * 100.0);
}
