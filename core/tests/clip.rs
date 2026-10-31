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

/// A safetensors file of F32 tensors, in the order given.
fn write_safetensors(path: &std::path::Path, tensors: &[(String, Vec<usize>, Vec<f32>)]) {
    let mut table = serde_json::Map::new();
    let mut offset = 0usize;
    for (name, shape, values) in tensors {
        assert_eq!(shape.iter().product::<usize>(), values.len(), "{name}");
        table.insert(name.clone(), serde_json::json!({ "dtype": "F32", "shape": shape, "data_offsets": [offset, offset + values.len() * 4] }));
        offset += values.len() * 4;
    }
    let header = serde_json::to_vec(&Value::Object(table)).unwrap();
    let mut out = (header.len() as u64).to_le_bytes().to_vec();
    out.extend_from_slice(&header);
    for (_, _, values) in tensors {
        out.extend(values.iter().flat_map(|v| v.to_le_bytes()));
    }
    std::fs::write(path, out).unwrap();
}

fn transpose(values: &[f32], rows: usize, cols: usize) -> Vec<f32> {
    let mut out = vec![0f32; values.len()];
    for r in 0..rows {
        for c in 0..cols {
            out[c * rows + r] = values[r * cols + c];
        }
    }
    out
}

/// The DataComp model comes in OpenCLIP's layout and is converted to the
/// one the encoders read. The small model, written out in OpenCLIP's layout
/// (query, key and value fused, the projections the other way round) and
/// converted back, must give exactly the same answers.
#[test]
fn an_open_clip_model_converts_to_the_same_answers() {
    use gvcore::clip::convert::{convert, OPEN_CLIP_CONFIG, OPEN_CLIP_WEIGHTS};
    use gvcore::clip::model::Weights;

    let mini = fixture_path("clip_mini");
    let config: Value = serde_json::from_str(&std::fs::read_to_string(mini.join("config.json")).unwrap()).unwrap();
    let w = Weights::open(&mini.join("model.safetensors")).unwrap();
    let get = |name: &str| {
        let shape = w.shape(name).unwrap().to_vec();
        (shape.clone(), w.get(name, &shape).unwrap())
    };
    let mut tensors: Vec<(String, Vec<usize>, Vec<f32>)> = Vec::new();
    let mut same = |to: &str, from: &str| {
        let (shape, values) = get(from);
        tensors.push((to.to_string(), shape, values));
    };
    for (to, from) in [
        ("visual.conv1.weight", "vision_model.embeddings.patch_embedding.weight"),
        ("visual.class_embedding", "vision_model.embeddings.class_embedding"),
        ("visual.positional_embedding", "vision_model.embeddings.position_embedding.weight"),
        ("visual.ln_pre.weight", "vision_model.pre_layrnorm.weight"),
        ("visual.ln_pre.bias", "vision_model.pre_layrnorm.bias"),
        ("visual.ln_post.weight", "vision_model.post_layernorm.weight"),
        ("visual.ln_post.bias", "vision_model.post_layernorm.bias"),
        ("token_embedding.weight", "text_model.embeddings.token_embedding.weight"),
        ("positional_embedding", "text_model.embeddings.position_embedding.weight"),
        ("ln_final.weight", "text_model.final_layer_norm.weight"),
        ("ln_final.bias", "text_model.final_layer_norm.bias"),
        ("logit_scale", "logit_scale"),
    ] {
        same(to, from);
    }
    for (to, from) in [("visual.proj", "visual_projection.weight"), ("text_projection", "text_projection.weight")] {
        let (shape, values) = get(from);
        tensors.push((to.to_string(), vec![shape[1], shape[0]], transpose(&values, shape[0], shape[1])));
    }
    for (to, from, side) in [("visual.transformer", "vision_model", "vision_config"), ("transformer", "text_model", "text_config")] {
        for i in 0..config[side]["num_hidden_layers"].as_u64().unwrap() {
            let (to, from) = (format!("{to}.resblocks.{i}"), format!("{from}.encoder.layers.{i}"));
            for kind in ["weight", "bias"] {
                for (a, b) in [("ln_1", "layer_norm1"), ("ln_2", "layer_norm2"), ("attn.out_proj", "self_attn.out_proj"), ("mlp.c_fc", "mlp.fc1"), ("mlp.c_proj", "mlp.fc2")] {
                    let (shape, values) = get(&format!("{from}.{b}.{kind}"));
                    tensors.push((format!("{to}.{a}.{kind}"), shape, values));
                }
                // Query, key and value, one above the other.
                let parts: Vec<(Vec<usize>, Vec<f32>)> = ["q_proj", "k_proj", "v_proj"].iter().map(|p| get(&format!("{from}.self_attn.{p}.{kind}"))).collect();
                let mut shape = parts[0].0.clone();
                shape[0] *= 3;
                tensors.push((format!("{to}.attn.in_proj_{kind}"), shape, parts.into_iter().flat_map(|(_, v)| v).collect()));
            }
        }
    }

    let dir = tempfile::tempdir().unwrap();
    write_safetensors(&dir.path().join(OPEN_CLIP_WEIGHTS), &tensors);
    std::fs::copy(mini.join("tokenizer.json"), dir.path().join("tokenizer.json")).unwrap();
    // The small model's settings in OpenCLIP's terms.
    let (v, t) = (&config["vision_config"], &config["text_config"]);
    let open_clip = serde_json::json!({
        "model_cfg": {
            "embed_dim": config["projection_dim"],
            "vision_cfg": { "image_size": v["image_size"], "layers": v["num_hidden_layers"], "width": v["hidden_size"], "patch_size": v["patch_size"],
                            "head_width": v["hidden_size"].as_u64().unwrap() / v["num_attention_heads"].as_u64().unwrap(),
                            "mlp_ratio": v["intermediate_size"].as_f64().unwrap() / v["hidden_size"].as_f64().unwrap() },
            "text_cfg": { "context_length": t["max_position_embeddings"], "vocab_size": t["vocab_size"], "width": t["hidden_size"], "heads": t["num_attention_heads"],
                          "layers": t["num_hidden_layers"], "mlp_ratio": t["intermediate_size"].as_f64().unwrap() / t["hidden_size"].as_f64().unwrap() }
        }
    });
    std::fs::write(dir.path().join(OPEN_CLIP_CONFIG), serde_json::to_vec(&open_clip).unwrap()).unwrap();

    convert(dir.path()).unwrap();
    assert!(dir.path().join("model.safetensors").is_file());
    assert!(!dir.path().join(OPEN_CLIP_WEIGHTS).exists(), "OpenCLIP's copy is let go");
    let made: Value = serde_json::from_str(&std::fs::read_to_string(dir.path().join("config.json")).unwrap()).unwrap();
    for side in ["vision_config", "text_config"] {
        for key in ["hidden_size", "intermediate_size", "num_hidden_layers", "num_attention_heads"] {
            assert_eq!(made[side][key], config[side][key], "{side}.{key}");
        }
    }
    assert_eq!((&made["vision_config"]["image_size"], &made["vision_config"]["patch_size"]), (&v["image_size"], &v["patch_size"]));
    // OpenCLIP names one activation for both sides; this small model has a
    // different one on each, so its own settings stand in for the rest.
    std::fs::copy(mini.join("config.json"), dir.path().join("config.json")).unwrap();

    let picture = image::open(mini.join("photo.png")).unwrap();
    let (original, converted) = (Vision::load(&mini).unwrap(), Vision::load(dir.path()).unwrap());
    let pixels = prepare(&picture, original.image_size).unwrap();
    assert_eq!(original.embed(&pixels), converted.embed(&pixels));
    let tokens = Tokenizer::load(&mini.join("tokenizer.json")).unwrap().encode("a red fox in the snow");
    let (original, converted) = (Text::load(&mini).unwrap(), Text::load(dir.path()).unwrap());
    assert_eq!(original.embed(&tokens).unwrap(), converted.embed(&tokens).unwrap());
}
