//! InvokeAI.
//!
//! v3+ writes an `invokeai_metadata` PNG text chunk: a flat JSON object of
//! generation settings in which models appear as `{key, hash, name, base, type}`
//! (older 3.x builds: `{model_name, base_model, model_type}`).
//! v2 wrote `sd-metadata` with the settings nested under `image`.

use super::json::{display, parse_lenient, scalar};
use super::GenInfo;
use serde_json::{Map, Value};

fn model_name(v: &Value) -> Option<(String, String)> {
    let o = v.as_object()?;
    let name = o.get("name").or_else(|| o.get("model_name")).and_then(Value::as_str)?;
    let hash = o.get("hash").and_then(Value::as_str).unwrap_or("");
    Some((name.to_string(), hash.to_string()))
}

fn label(key: &str) -> String {
    let mut s = key.replace('_', " ");
    if let Some(first) = s.get(..1) {
        let upper = first.to_ascii_uppercase();
        s.replace_range(..1, &upper);
    }
    s
}

pub fn parse_v3(text: &str, info: &mut GenInfo) {
    let Some(Value::Object(m)) = parse_lenient(text) else { return };
    info.source = "invokeai".into();
    let mut style_pos = String::new();
    let mut style_neg = String::new();

    for (k, v) in &m {
        match k.as_str() {
            "positive_prompt" => info.prompt = display(v),
            "negative_prompt" => info.negative = display(v),
            "positive_style_prompt" => style_pos = display(v),
            "negative_style_prompt" => style_neg = display(v),
            "seed" => info.seed = display(v),
            "model" => {
                if let Some((name, hash)) = model_name(v) {
                    info.model = name.clone();
                    info.add_model("checkpoint", &name, &hash);
                    if let Some(base) = v.get("base").or_else(|| v.get("base_model")).and_then(Value::as_str) {
                        info.param("Base", base);
                    }
                }
            }
            "loras" => {
                for l in v.as_array().into_iter().flatten() {
                    let m = l.get("model").or_else(|| l.get("lora"));
                    if let Some((name, hash)) = m.and_then(model_name) {
                        info.add_lora(&name, l.get("weight").and_then(Value::as_f64), None);
                        if let Some(entry) = info.loras.iter_mut().find(|x| x.name == name) {
                            entry.hash = hash;
                        }
                    }
                }
            }
            "controlnets" | "ipAdapters" | "t2iAdapters" | "controlLayers" | "regions" => {
                adapters(k, v, info);
            }
            "width" | "height" => {}
            _ => {
                if let Some((name, hash)) = model_name(v) {
                    // vae, refiner_model, wan_t5_encoder_model, ...
                    let kind = k.strip_suffix("_model").unwrap_or(k);
                    info.add_model(kind, &name, &hash);
                } else if let Some(s) = scalar(v) {
                    if !s.is_empty() {
                        info.param(&label(k), s);
                    }
                } else if !v.is_null() && !matches!(v, Value::Array(a) if a.is_empty()) {
                    let shown = v.to_string();
                    if shown.len() <= 600 {
                        info.param(&label(k), shown);
                    }
                }
            }
        }
    }
    if let (Some(w), Some(h)) = (m.get("width").and_then(Value::as_u64), m.get("height").and_then(Value::as_u64)) {
        info.params.insert(0, ("Size".into(), format!("{w}x{h}")));
    }
    if !style_pos.is_empty() && style_pos != info.prompt {
        info.param("Positive style prompt", style_pos);
    }
    if !style_neg.is_empty() && style_neg != info.negative {
        info.param("Negative style prompt", style_neg);
    }
}

fn adapters(key: &str, v: &Value, info: &mut GenInfo) {
    let kind = match key {
        "controlnets" => "controlnet",
        "ipAdapters" => "ipadapter",
        "t2iAdapters" => "t2i_adapter",
        _ => "adapter",
    };
    for item in v.as_array().into_iter().flatten() {
        let Some(obj) = item.as_object() else { continue };
        for field in ["control_model", "ip_adapter_model", "t2i_adapter_model", "model"] {
            if let Some((name, hash)) = obj.get(field).and_then(model_name) {
                info.add_model(kind, &name, &hash);
            }
        }
    }
}

pub fn parse_legacy(text: &str, info: &mut GenInfo) {
    let Some(Value::Object(m)) = parse_lenient(text) else { return };
    info.source = "invokeai".into();
    if let Some(w) = m.get("model_weights").and_then(Value::as_str) {
        let hash = m.get("model_hash").and_then(Value::as_str).unwrap_or("");
        info.model = w.to_string();
        info.add_model("checkpoint", w, hash);
    }
    if let Some(v) = m.get("app_version").and_then(Value::as_str) {
        info.param("App version", v);
    }
    let empty = Map::new();
    let image = m.get("image").and_then(Value::as_object).unwrap_or(&empty);
    for (k, v) in image {
        match k.as_str() {
            "prompt" => {
                let text = match v {
                    Value::String(s) => s.clone(),
                    Value::Array(a) => a
                        .iter()
                        .filter_map(|p| p.get("prompt").and_then(Value::as_str))
                        .collect::<Vec<_>>()
                        .join(", "),
                    _ => String::new(),
                };
                let (pos, neg) = split_bracket_negative(&text);
                info.prompt = pos;
                info.negative = neg;
            }
            "seed" => info.seed = display(v),
            "width" | "height" => {}
            _ => {
                if let Some(s) = scalar(v) {
                    info.param(&label(k), s);
                }
            }
        }
    }
    if let (Some(w), Some(h)) = (image.get("width").and_then(Value::as_u64), image.get("height").and_then(Value::as_u64)) {
        info.params.insert(0, ("Size".into(), format!("{w}x{h}")));
    }
}

/// InvokeAI 2.x wrote negatives inline: `a castle [blurry, ugly]`.
fn split_bracket_negative(text: &str) -> (String, String) {
    let mut pos = String::new();
    let mut neg: Vec<String> = Vec::new();
    let mut depth = 0usize;
    let mut cur = String::new();
    for c in text.chars() {
        match c {
            '[' => {
                depth += 1;
                if depth > 1 {
                    cur.push(c);
                }
            }
            ']' if depth > 0 => {
                depth -= 1;
                if depth == 0 {
                    if !cur.trim().is_empty() {
                        neg.push(cur.trim().to_string());
                    }
                    cur.clear();
                } else {
                    cur.push(c);
                }
            }
            _ if depth > 0 => cur.push(c),
            _ => pos.push(c),
        }
    }
    (pos.trim().trim_end_matches(',').trim().to_string(), neg.join(", "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn v4_metadata() {
        let text = r#"{"generation_mode":"sdxl_txt2img","positive_prompt":"a lighthouse at dusk","negative_prompt":"people","width":1024,"height":1024,"seed":987654321,"rand_device":"cpu","cfg_scale":5.5,"steps":30,"scheduler":"dpmpp_2m_k","model":{"key":"k1","hash":"blake3:aa","name":"Juggernaut XL v9","base":"sdxl","type":"main"},"loras":[{"model":{"key":"k2","hash":"blake3:bb","name":"add-detail-xl","base":"sdxl","type":"lora"},"weight":0.75}],"vae":{"key":"k3","hash":"blake3:cc","name":"sdxl-vae-fp16-fix","base":"sdxl","type":"vae"},"positive_style_prompt":"cinematic","negative_style_prompt":"","controlnets":[],"app_version":"5.4.2"}"#;
        let mut info = GenInfo::default();
        parse_v3(text, &mut info);
        assert_eq!(info.source, "invokeai");
        assert_eq!(info.prompt, "a lighthouse at dusk");
        assert_eq!(info.negative, "people");
        assert_eq!(info.seed, "987654321");
        assert_eq!(info.model, "Juggernaut XL v9");
        assert_eq!(info.loras.len(), 1);
        assert_eq!(info.loras[0].name, "add-detail-xl");
        assert_eq!(info.loras[0].weight, Some(0.75));
        assert!(info.models.iter().any(|m| m.kind == "vae" && m.name == "sdxl-vae-fp16-fix"));
        let p = |k: &str| info.params.iter().find(|p| p.0 == k).map(|p| p.1.as_str());
        assert_eq!(p("Size"), Some("1024x1024"));
        assert_eq!(p("Steps"), Some("30"));
        assert_eq!(p("Cfg scale"), Some("5.5"));
        assert_eq!(p("Scheduler"), Some("dpmpp_2m_k"));
        assert_eq!(p("Positive style prompt"), Some("cinematic"));
    }

    #[test]
    fn v3_model_shape() {
        let text = r#"{"positive_prompt":"x","seed":1,"model":{"model_name":"dreamshaper-8","base_model":"sd-1","model_type":"main"},"loras":[{"lora":{"model_name":"epi_noiseoffset","base_model":"sd-1"},"weight":0.5}]}"#;
        let mut info = GenInfo::default();
        parse_v3(text, &mut info);
        assert_eq!(info.model, "dreamshaper-8");
        assert_eq!(info.loras[0].name, "epi_noiseoffset");
    }

    #[test]
    fn v2_metadata() {
        let text = r#"{"model":"stable diffusion","model_weights":"stable-diffusion-1.5","model_hash":"cc6c","app_id":"invoke-ai/InvokeAI","app_version":"2.3.5","image":{"prompt":[{"prompt":"a red barn [fog, blur]","weight":1.0}],"steps":50,"cfg_scale":7.5,"height":512,"width":768,"seed":3141592,"sampler":"k_euler_a","type":"txt2img"}}"#;
        let mut info = GenInfo::default();
        parse_legacy(text, &mut info);
        assert_eq!(info.prompt, "a red barn");
        assert_eq!(info.negative, "fog, blur");
        assert_eq!(info.seed, "3141592");
        assert_eq!(info.model, "stable-diffusion-1.5");
        assert_eq!(info.params[0], ("Size".to_string(), "768x512".to_string()));
    }
}
