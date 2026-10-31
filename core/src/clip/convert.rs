//! The content-search model is published in OpenCLIP's layout
//! (`open_clip_config.json` beside `open_clip_model.safetensors`); the
//! encoders in [`super::model`] read Hugging Face's (`config.json` beside
//! `model.safetensors`), which they are checked against. Once downloaded,
//! the model is rewritten in that layout here, once, on the device.
//!
//! The two hold the same numbers under other names, except that:
//! * OpenCLIP keeps each block's query, key and value projections as one
//!   matrix (`attn.in_proj_weight`, three times as tall), split here;
//! * its two final projections are applied as `x @ proj`, so they are
//!   stored the other way round from a linear layer's weight: transposed.

use super::model::Weights;
use serde_json::{json, Map, Value};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::Path;

/// The files OpenCLIP's layout is downloaded as.
pub const OPEN_CLIP_CONFIG: &str = "open_clip_config.json";
pub const OPEN_CLIP_WEIGHTS: &str = "open_clip_model.safetensors";

/// Where one tensor of the Hugging Face layout comes from.
enum From {
    Same(String),
    /// A matrix the other way round.
    Transposed(String),
    /// One third of an `in_proj` tensor: 0 query, 1 key, 2 value.
    Third(String, usize),
}

/// The Hugging Face `config.json` for a model with this OpenCLIP config.
/// Only the plain CLIP transformer is taken: other designs OpenCLIP can
/// describe (a ResNet or timm picture encoder, a Hugging Face text model,
/// layer scaling, attention pooling) are not what the encoders here run.
pub fn hf_config(open_clip: &Value) -> Result<Value, String> {
    let model = &open_clip["model_cfg"];
    let (vision, text) = (&model["vision_cfg"], &model["text_cfg"]);
    let unsupported = |what: &str| Err(format!("the model's {what} is not supported"));
    if !vision.is_object() || !text.is_object() {
        return unsupported("configuration");
    }
    if vision["layers"].is_array() || vision.get("timm_model_name").is_some_and(|v| !v.is_null()) {
        return unsupported("picture encoder");
    }
    if text.get("hf_model_name").is_some_and(|v| !v.is_null()) {
        return unsupported("text encoder");
    }
    for side in [vision, text] {
        for key in ["ls_init_value", "attentional_pool", "no_ln_pre", "final_ln_after_pool", "attn_pooler_queries", "output_tokens"] {
            if side.get(key).is_some_and(|v| !v.is_null() && v != &json!(false)) {
                return unsupported(key);
            }
        }
        if side.get("pool_type").and_then(Value::as_str).is_some_and(|p| p != "tok" && p != "argmax") {
            return unsupported("pooling");
        }
    }
    if vision.get("pool_type").and_then(Value::as_str).is_some_and(|p| p != "tok") {
        return unsupported("picture pooling");
    }
    let number = |side: &Value, key: &str, default: u64| side[key].as_u64().unwrap_or(default);
    let wide = |side: &Value, width: u64| (width as f64 * side["mlp_ratio"].as_f64().unwrap_or(4.0)).round() as u64;
    let activation = if model["quick_gelu"].as_bool() == Some(true) { "quick_gelu" } else { "gelu" };

    let vision_width = number(vision, "width", 768);
    let head_width = number(vision, "head_width", 64);
    if head_width == 0 || vision_width % head_width != 0 {
        return unsupported("picture attention heads");
    }
    let Some(image_size) = vision["image_size"].as_u64() else { return unsupported("picture size") };
    let text_width = number(text, "width", 512);
    Ok(json!({
        "projection_dim": number(model, "embed_dim", 512),
        "vision_config": {
            "hidden_size": vision_width,
            "intermediate_size": wide(vision, vision_width),
            "num_hidden_layers": number(vision, "layers", 12),
            "num_attention_heads": vision_width / head_width,
            "image_size": image_size,
            "patch_size": number(vision, "patch_size", 16),
            "hidden_act": activation,
            "layer_norm_eps": 1e-5,
        },
        "text_config": {
            "hidden_size": text_width,
            "intermediate_size": wide(text, text_width),
            "num_hidden_layers": number(text, "layers", 12),
            "num_attention_heads": number(text, "heads", 8),
            "max_position_embeddings": number(text, "context_length", 77),
            "vocab_size": number(text, "vocab_size", 49408),
            "hidden_act": activation,
            "layer_norm_eps": 1e-5,
        },
    }))
}

/// Every tensor the encoders read, by its Hugging Face name, and where it
/// is in OpenCLIP's.
fn plan(vision_layers: u64, text_layers: u64) -> Vec<(String, From)> {
    let same = |s: &str| From::Same(s.to_string());
    let mut out: Vec<(String, From)> = vec![
        ("vision_model.embeddings.patch_embedding.weight".into(), same("visual.conv1.weight")),
        ("vision_model.embeddings.class_embedding".into(), same("visual.class_embedding")),
        ("vision_model.embeddings.position_embedding.weight".into(), same("visual.positional_embedding")),
        ("vision_model.pre_layrnorm.weight".into(), same("visual.ln_pre.weight")),
        ("vision_model.pre_layrnorm.bias".into(), same("visual.ln_pre.bias")),
        ("vision_model.post_layernorm.weight".into(), same("visual.ln_post.weight")),
        ("vision_model.post_layernorm.bias".into(), same("visual.ln_post.bias")),
        ("visual_projection.weight".into(), From::Transposed("visual.proj".into())),
        ("text_model.embeddings.token_embedding.weight".into(), same("token_embedding.weight")),
        ("text_model.embeddings.position_embedding.weight".into(), same("positional_embedding")),
        ("text_model.final_layer_norm.weight".into(), same("ln_final.weight")),
        ("text_model.final_layer_norm.bias".into(), same("ln_final.bias")),
        ("text_projection.weight".into(), From::Transposed("text_projection".into())),
    ];
    for (to, from, layers) in [("vision_model", "visual.transformer", vision_layers), ("text_model", "transformer", text_layers)] {
        for i in 0..layers {
            let (to, from) = (format!("{to}.encoder.layers.{i}"), format!("{from}.resblocks.{i}"));
            for kind in ["weight", "bias"] {
                out.push((format!("{to}.layer_norm1.{kind}"), From::Same(format!("{from}.ln_1.{kind}"))));
                out.push((format!("{to}.layer_norm2.{kind}"), From::Same(format!("{from}.ln_2.{kind}"))));
                for (part, name) in ["q_proj", "k_proj", "v_proj"].iter().enumerate() {
                    out.push((format!("{to}.self_attn.{name}.{kind}"), From::Third(format!("{from}.attn.in_proj_{kind}"), part)));
                }
                out.push((format!("{to}.self_attn.out_proj.{kind}"), From::Same(format!("{from}.attn.out_proj.{kind}"))));
                out.push((format!("{to}.mlp.fc1.{kind}"), From::Same(format!("{from}.mlp.c_fc.{kind}"))));
                out.push((format!("{to}.mlp.fc2.{kind}"), From::Same(format!("{from}.mlp.c_proj.{kind}"))));
            }
        }
    }
    out
}

/// The shape a tensor has once taken from `source` (whose shape is `of`).
fn shape_of(from: &From, of: &[usize]) -> Result<Vec<usize>, String> {
    match (from, of) {
        (From::Same(_), _) => Ok(of.to_vec()),
        (From::Transposed(_), &[rows, cols]) => Ok(vec![cols, rows]),
        (From::Third(_, _), &[rows, cols]) if rows % 3 == 0 => Ok(vec![rows / 3, cols]),
        (From::Third(_, _), &[len]) if len % 3 == 0 => Ok(vec![len / 3]),
        (From::Transposed(name) | From::Third(name, _), _) => Err(format!("{name} is {of:?}, which cannot be converted")),
    }
}

fn source_name(from: &From) -> &str {
    match from {
        From::Same(n) | From::Transposed(n) | From::Third(n, _) => n,
    }
}

/// The values of one tensor of the Hugging Face layout.
fn values(w: &Weights, from: &From) -> Result<Vec<f32>, String> {
    let name = source_name(from);
    let of = w.shape(name)?.to_vec();
    let all = w.get(name, &of)?;
    Ok(match (from, of.as_slice()) {
        (From::Same(_), _) => all,
        (From::Transposed(_), &[rows, cols]) => {
            let mut out = vec![0f32; all.len()];
            for r in 0..rows {
                for c in 0..cols {
                    out[c * rows + r] = all[r * cols + c];
                }
            }
            out
        }
        (From::Third(_, part), _) => {
            let third = all.len() / 3;
            all[part * third..(part + 1) * third].to_vec()
        }
        _ => return Err(format!("{name} cannot be converted")),
    })
}

/// Rewrite the OpenCLIP model in `dir` in Hugging Face's layout: write
/// `model.safetensors` and `config.json` beside it, then remove OpenCLIP's
/// weights, which are no longer needed. Each file is written aside and
/// renamed into place, the config last, so a model that is there is whole.
pub fn convert(dir: &Path) -> Result<(), String> {
    let config_text = std::fs::read_to_string(dir.join(OPEN_CLIP_CONFIG)).map_err(|e| format!("cannot read the model's settings: {e}"))?;
    let open_clip: Value = serde_json::from_str(&config_text).map_err(|e| format!("the model's settings are not readable: {e}"))?;
    let config = hf_config(&open_clip)?;
    let layers = |side: &str| config[side]["num_hidden_layers"].as_u64().unwrap_or(0);
    let w = Weights::open(&dir.join(OPEN_CLIP_WEIGHTS))?;

    // The table of contents first: every tensor's shape and place.
    let plan = plan(layers("vision_config"), layers("text_config"));
    let mut table = Map::new();
    let mut offset = 0usize;
    for (to, from) in &plan {
        let shape = shape_of(from, w.shape(source_name(from))?)?;
        let bytes = shape.iter().product::<usize>() * 4;
        table.insert(to.clone(), json!({ "dtype": "F32", "shape": shape, "data_offsets": [offset, offset + bytes] }));
        offset += bytes;
    }
    let mut header = serde_json::to_vec(&Value::Object(table)).map_err(|e| e.to_string())?;
    // Padded with spaces so the tensors start on an eight-byte boundary.
    while header.len() % 8 != 0 {
        header.push(b' ');
    }

    let target = dir.join("model.safetensors");
    let part = dir.join("model.safetensors.part");
    let write = || -> std::io::Result<()> {
        let mut out = BufWriter::with_capacity(1 << 20, File::create(&part)?);
        out.write_all(&(header.len() as u64).to_le_bytes())?;
        out.write_all(&header)?;
        for (_, from) in &plan {
            let values = values(&w, from).map_err(std::io::Error::other)?;
            for v in values {
                out.write_all(&v.to_le_bytes())?;
            }
        }
        out.into_inner().map_err(|e| e.into_error())?.sync_all()
    };
    if let Err(e) = write() {
        let _ = std::fs::remove_file(&part);
        return Err(format!("cannot convert the model: {e}"));
    }
    std::fs::rename(&part, &target).map_err(|e| format!("cannot convert the model: {e}"))?;
    let config_part = dir.join("config.json.part");
    std::fs::write(&config_part, serde_json::to_vec_pretty(&config).unwrap_or_default()).map_err(|e| format!("cannot write the model's settings: {e}"))?;
    std::fs::rename(&config_part, dir.join("config.json")).map_err(|e| format!("cannot write the model's settings: {e}"))?;
    drop(w);
    let _ = std::fs::remove_file(dir.join(OPEN_CLIP_WEIGHTS));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn datacomp_settings_become_a_clip_config() {
        // open_clip_config.json of laion/CLIP-ViT-B-32-DataComp.XL-s13B-b90K.
        let open_clip = json!({
            "model_cfg": {
                "embed_dim": 512,
                "vision_cfg": { "image_size": 224, "layers": 12, "width": 768, "patch_size": 32 },
                "text_cfg": { "context_length": 77, "vocab_size": 49408, "width": 512, "heads": 8, "layers": 12 }
            },
            "preprocess_cfg": { "mean": [0.48145466, 0.4578275, 0.40821073], "std": [0.26862954, 0.26130258, 0.27577711] }
        });
        let c = hf_config(&open_clip).unwrap();
        assert_eq!(c["projection_dim"], 512);
        let v = &c["vision_config"];
        assert_eq!(
            (&v["hidden_size"], &v["intermediate_size"], &v["num_hidden_layers"], &v["num_attention_heads"], &v["image_size"], &v["patch_size"], &v["hidden_act"]),
            (&json!(768), &json!(3072), &json!(12), &json!(12), &json!(224), &json!(32), &json!("gelu"))
        );
        let t = &c["text_config"];
        assert_eq!(
            (&t["hidden_size"], &t["intermediate_size"], &t["num_hidden_layers"], &t["num_attention_heads"], &t["max_position_embeddings"], &t["vocab_size"], &t["hidden_act"]),
            (&json!(512), &json!(2048), &json!(12), &json!(8), &json!(77), &json!(49408), &json!("gelu"))
        );
        // OpenAI's own weights use the quick approximation.
        let mut quick = open_clip.clone();
        quick["model_cfg"]["quick_gelu"] = json!(true);
        assert_eq!(hf_config(&quick).unwrap()["text_config"]["hidden_act"], "quick_gelu");
        // Other designs are refused rather than run wrongly.
        let mut resnet = open_clip.clone();
        resnet["model_cfg"]["vision_cfg"]["layers"] = json!([3, 4, 6, 3]);
        assert!(hf_config(&resnet).is_err());
        let mut scaled = open_clip;
        scaled["model_cfg"]["text_cfg"]["ls_init_value"] = json!(1e-4);
        assert!(hf_config(&scaled).is_err());
    }

    #[test]
    fn the_plan_covers_every_tensor_once() {
        let plan = plan(2, 3);
        let mut names: Vec<&str> = plan.iter().map(|(n, _)| n.as_str()).collect();
        let count = names.len();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), count);
        // 13 outside the blocks, 16 in each.
        assert_eq!(count, 13 + 16 * 5);
    }
}
