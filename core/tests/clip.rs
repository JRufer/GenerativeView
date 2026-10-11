//! The CLIP implementation against Hugging Face's.
//!
//! `tests/fixtures/clip_mini` holds a small CLIP model with made-up weights,
//! and what `transformers` and `tokenizers` computed with it (see `make.py`
//! there). The same inputs must give the same answers here.

mod common;
use common::fixture_path;
use gvcore::clip::image::prepare;
use gvcore::clip::model::{Text, Vision};
use gvcore::clip::tokenizer::Tokenizer;
use serde_json::Value;

fn reference() -> Value {
    serde_json::from_str(&std::fs::read_to_string(fixture_path("clip_mini/reference.json")).unwrap()).unwrap()
}

fn floats(v: &Value) -> Vec<f32> {
    v.as_array().unwrap().iter().map(|x| x.as_f64().unwrap() as f32).collect()
}

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    assert_eq!(a.len(), b.len());
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let len = |v: &[f32]| v.iter().map(|x| x * x).sum::<f32>().sqrt();
    dot / (len(a) * len(b))
}

fn largest_gap(a: &[f32], b: &[f32]) -> f32 {
    assert_eq!(a.len(), b.len());
    a.iter().zip(b).map(|(x, y)| (x - y).abs()).fold(0.0, f32::max)
}

#[test]
fn tokens_match_the_reference_tokenizer() {
    let r = reference();
    let tokenizer = Tokenizer::load(&fixture_path("clip_mini/tokenizer.json")).unwrap();
    for (text, ids) in r["texts"].as_array().unwrap().iter().zip(r["ids"].as_array().unwrap()) {
        let expected: Vec<u32> = ids.as_array().unwrap().iter().map(|i| i.as_u64().unwrap() as u32).collect();
        assert_eq!(tokenizer.encode(text.as_str().unwrap()), expected, "{text}");
    }
    // Long text is cut to the model's limit, markers included.
    let long = tokenizer.encode(&"owl ".repeat(200));
    assert_eq!(long.len(), 77);
    assert_eq!(*long.last().unwrap(), tokenizer.end_token());
}

#[test]
fn text_embeddings_match_transformers() {
    let r = reference();
    let text = Text::load(&fixture_path("clip_mini")).unwrap();
    assert_eq!(text.dim, 24);
    for (ids, expected) in r["ids"].as_array().unwrap().iter().zip(r["text_embeddings"].as_array().unwrap()) {
        let ids: Vec<u32> = ids.as_array().unwrap().iter().map(|i| i.as_u64().unwrap() as u32).collect();
        let got = text.embed(&ids).unwrap();
        let expected = floats(expected);
        assert!(largest_gap(&got, &expected) < 2e-4, "{} tokens: off by {}", ids.len(), largest_gap(&got, &expected));
    }
    assert!(text.embed(&[]).is_err());
    assert!(text.embed(&[9_999_999]).is_err());
    assert!(text.embed(&vec![1; 78]).is_err());
}

#[test]
fn picture_embeddings_match_transformers() {
    let r = reference();
    let vision = Vision::load(&fixture_path("clip_mini")).unwrap();
    assert_eq!((vision.dim, vision.image_size, vision.pixels()), (24, 64, 3 * 64 * 64));

    // The model alone: the very pixels transformers was given.
    let pixels = floats(&r["exact_pixels"]);
    let expected = floats(&r["exact_embedding"]);
    let got = vision.embed(&pixels);
    assert!(largest_gap(&got, &expected) < 2e-4, "off by {}", largest_gap(&got, &expected));

    // Several at once come out the same as one at a time.
    let photo = floats(&r["photo_pixels"]);
    let both = vision.embed(&[pixels.clone(), photo.clone(), pixels.clone()].concat());
    assert_eq!(both.len(), 3 * 24);
    assert!(largest_gap(&both[..24], &expected) < 2e-4);
    assert!(largest_gap(&both[24..48], &floats(&r["photo_embedding"])) < 2e-4);
    assert!(largest_gap(&both[48..], &expected) < 2e-4);

    // And from a file: our resizing is not PIL's to the last digit, but the
    // picture the model sees, and what it makes of it, are the same.
    let img = image::open(fixture_path("clip_mini/photo.png")).unwrap();
    let prepared = prepare(&img, vision.image_size).unwrap();
    assert_eq!(prepared.len(), photo.len());
    let mean_gap = prepared.iter().zip(&photo).map(|(a, b)| (a - b).abs()).sum::<f32>() / photo.len() as f32;
    assert!(mean_gap < 0.02, "prepared pixels differ by {mean_gap} on average");
    let from_file = vision.embed(&prepared);
    let agreement = cosine(&from_file, &floats(&r["photo_embedding"]));
    assert!(agreement > 0.995, "embedding from the file agrees only {agreement}");
}

#[test]
fn preparing_pictures() {
    // Wide, tall, exact and tiny all come out the model's size.
    for (w, h) in [(150, 90), (90, 150), (64, 64), (7, 5), (1, 300)] {
        let img = image::DynamicImage::ImageRgb8(image::RgbImage::from_fn(w, h, |x, y| image::Rgb([(x * 3) as u8, (y * 2) as u8, 99])));
        assert_eq!(prepare(&img, 64).unwrap().len(), 3 * 64 * 64, "{w}x{h}");
    }
    // The middle square is what is kept: a picture white in the middle third
    // and black at the ends comes out all white.
    let img = image::DynamicImage::ImageRgb8(image::RgbImage::from_fn(192, 64, |x, _| if (64..128).contains(&x) { image::Rgb([255; 3]) } else { image::Rgb([0; 3]) }));
    let prepared = prepare(&img, 64).unwrap();
    let white = (1.0 - 0.481_454_66) / 0.268_629_54;
    assert!(prepared[..64 * 64].iter().all(|v| (v - white).abs() < 1e-4));
}
