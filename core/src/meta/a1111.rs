//! AUTOMATIC1111 / Forge "parameters" text, plus the JSON dialects that reuse
//! the same slot (SwarmUI, Fooocus) and NovelAI.
//!
//! The classic layout is:
//! ```text
//! positive prompt (may span lines)
//! Negative prompt: negative prompt (may span lines)
//! Steps: 20, Sampler: Euler a, CFG scale: 7, Seed: 1, Size: 512x512, Model: foo, ...
//! ```

use super::json::{display, parse_lenient, scalar};
use super::GenInfo;
use serde_json::Value;

pub fn looks_like(s: &str) -> bool {
    s.contains("Steps: ") && (s.contains("Sampler: ") || s.contains("Seed: "))
}

pub fn parse(text: &str, info: &mut GenInfo) {
    let text = text.trim_matches(|c: char| c.is_whitespace() || c == '\0');
    let lines: Vec<&str> = text.lines().collect();
    let (body, settings) = match lines.split_last() {
        Some((last, rest)) => {
            let pairs = settings_line(last);
            if pairs.len() >= 3 {
                (rest, pairs)
            } else {
                (&lines[..], Vec::new())
            }
        }
        None => return,
    };

    let mut prompt = String::new();
    let mut negative = String::new();
    let mut in_neg = false;
    for line in body {
        let trimmed = line.trim();
        if !in_neg {
            if let Some(rest) = trimmed.strip_prefix("Negative prompt:") {
                in_neg = true;
                negative.push_str(rest.trim_start());
                continue;
            }
        }
        let target = if in_neg { &mut negative } else { &mut prompt };
        if !target.is_empty() {
            target.push('\n');
        }
        target.push_str(trimmed);
    }

    if settings.is_empty() && !in_neg && !looks_like(text) {
        // Arbitrary text in a `parameters` slot; not ours.
        return;
    }

    info.source = "a1111".into();
    info.prompt = prompt;
    info.negative = negative;

    let lookup = |k: &str| settings.iter().find(|(key, _)| key == k).map(|(_, v)| v.as_str());
    let model_hash = lookup("Model hash").unwrap_or("").to_string();
    let vae_hash = lookup("VAE hash").unwrap_or("").to_string();

    for (k, v) in &settings {
        match k.as_str() {
            "Seed" => info.seed = v.clone(),
            "Model" => {
                info.model = v.clone();
                info.add_model("checkpoint", v, &model_hash);
            }
            "Model hash" | "VAE hash" => {}
            "VAE" => info.add_model("vae", v, &vae_hash),
            "Hires upscaler" => {
                info.add_model("upscaler", v, "");
                info.param(k, v.clone());
            }
            "Lora hashes" | "Lyco hashes" => {
                for part in v.split(',') {
                    if let Some((name, hash)) = part.split_once(':') {
                        info.add_lora(name, None, None);
                        if let Some(l) = info.loras.iter_mut().find(|l| l.name == name.trim()) {
                            l.hash = hash.trim().to_string();
                        }
                    }
                }
            }
            "Version" => {
                if v.starts_with('f') {
                    info.source = "forge".into();
                }
                info.param(k, v.clone());
            }
            _ => info.param(k, v.clone()),
        }
    }
    if info.model.is_empty() && !model_hash.is_empty() {
        info.param("Model hash", model_hash);
    }

    for text in [info.prompt.clone(), info.negative.clone()] {
        for (name, weight) in lora_tags(&text) {
            match info.loras.iter_mut().find(|l| l.name == name) {
                Some(l) => l.weight = l.weight.or(weight),
                None => info.add_lora(&name, weight, None),
            }
        }
    }
}

/// Parse `Key: value, Key: "quoted, value", ...`.
fn settings_line(line: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut rest = line;
    loop {
        rest = rest.trim_start_matches([' ', ',']);
        if rest.is_empty() {
            break;
        }
        let Some(colon) = rest.find(':') else { break };
        let key = rest[..colon].trim();
        let key_ok = !key.is_empty()
            && key.len() <= 64
            && key.chars().next().map_or(false, |c| c.is_alphanumeric())
            && key.chars().all(|c| c.is_alphanumeric() || matches!(c, ' ' | '-' | '/' | '_' | '.' | '(' | ')'));
        let after = rest[colon + 1..].trim_start();
        if !key_ok {
            // Not a key: skip to the next comma and resynchronise.
            match rest.find(',') {
                Some(c) => {
                    rest = &rest[c + 1..];
                    continue;
                }
                None => break,
            }
        }
        if let Some(quoted) = after.strip_prefix('"') {
            let mut value = String::new();
            let mut chars = quoted.char_indices();
            let mut end = quoted.len();
            while let Some((i, c)) = chars.next() {
                match c {
                    '\\' => {
                        if let Some((_, n)) = chars.next() {
                            match n {
                                'n' => value.push('\n'),
                                't' => value.push('\t'),
                                other => value.push(other),
                            }
                        }
                    }
                    '"' => {
                        end = i + 1;
                        break;
                    }
                    other => value.push(other),
                }
            }
            out.push((key.to_string(), value));
            rest = &quoted[end.min(quoted.len())..];
        } else {
            let end = after.find(',').unwrap_or(after.len());
            out.push((key.to_string(), after[..end].trim().to_string()));
            rest = &after[end..];
        }
    }
    out
}

/// `<lora:name:0.8>` / `<lyco:name:1>` tags inside prompt text.
pub fn lora_tags(text: &str) -> Vec<(String, Option<f64>)> {
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(start) = rest.find('<') {
        rest = &rest[start + 1..];
        let Some(end) = rest.find('>') else { break };
        let inner = &rest[..end];
        let mut parts = inner.split(':');
        let kind = parts.next().unwrap_or("");
        if matches!(kind, "lora" | "lyco" | "lycoris") {
            if let Some(name) = parts.next().map(str::trim).filter(|n| !n.is_empty()) {
                let weight = parts.next().and_then(|w| w.trim().parse::<f64>().ok());
                if !out.iter().any(|(n, _)| n == name) {
                    out.push((name.to_string(), weight));
                }
            }
            rest = &rest[end + 1..];
        }
    }
    out
}

/// JSON stored where A1111 would put text: SwarmUI (`sui_image_params`),
/// Fooocus, and anything else with recognisable keys.
pub fn parse_json_params(text: &str, info: &mut GenInfo) {
    let Some(Value::Object(root)) = parse_lenient(text) else { return };
    let (map, source) = match root.get("sui_image_params") {
        Some(Value::Object(m)) => (m, "swarmui"),
        _ => {
            let fooocus = root.contains_key("base_model") || root.contains_key("performance");
            (&root, if fooocus { "fooocus" } else { "json" })
        }
    };
    let mut found = false;
    let mut lora_names: Vec<String> = Vec::new();
    let mut lora_weights: Vec<f64> = Vec::new();
    for (k, v) in map {
        let kl = k.to_ascii_lowercase().replace([' ', '_'], "");
        match kl.as_str() {
            "prompt" | "positiveprompt" | "fullprompt" => {
                if let Some(s) = v.as_str() {
                    info.prompt = s.to_string();
                    found = true;
                }
            }
            "negativeprompt" | "fullnegativeprompt" | "uc" => {
                if let Some(s) = v.as_str() {
                    info.negative = s.to_string();
                    found = true;
                }
            }
            "seed" => {
                info.seed = display(v);
                found = true;
            }
            "model" | "basemodel" | "basemodelname" => {
                if let Some(s) = scalar(v) {
                    info.model = s.clone();
                    info.add_model("checkpoint", &s, "");
                }
            }
            "refinermodel" => {
                if let Some(s) = scalar(v) {
                    info.add_model("refiner", &s, "");
                }
            }
            "vae" => {
                if let Some(s) = scalar(v) {
                    info.add_model("vae", &s, "");
                }
            }
            "loras" => match v {
                Value::Array(a) => {
                    for item in a {
                        match item {
                            Value::String(s) => lora_names.push(s.clone()),
                            // Fooocus: [name, weight] or [enabled, name, weight]
                            Value::Array(pair) => {
                                let name = pair.iter().find_map(Value::as_str);
                                let weight = pair.iter().rev().find_map(Value::as_f64);
                                if let Some(n) = name {
                                    info.add_lora(n, weight, None);
                                }
                            }
                            _ => {}
                        }
                    }
                }
                Value::String(s) => lora_names.extend(s.split(',').map(|x| x.trim().to_string())),
                _ => {}
            },
            "loraweights" => match v {
                Value::Array(a) => lora_weights.extend(a.iter().filter_map(|x| x.as_f64().or_else(|| x.as_str()?.parse().ok()))),
                Value::String(s) => lora_weights.extend(s.split(',').filter_map(|x| x.trim().parse::<f64>().ok())),
                _ => {}
            },
            _ => {
                let shown = display(v);
                if !shown.is_empty() && shown.len() < 400 {
                    info.param(k, shown);
                }
            }
        }
    }
    for (i, name) in lora_names.iter().enumerate() {
        info.add_lora(name, lora_weights.get(i).copied(), None);
    }
    if found {
        info.source = source.into();
        for (name, weight) in lora_tags(&info.prompt.clone()) {
            info.add_lora(&name, weight, None);
        }
    } else {
        info.params.clear();
        info.models.clear();
        info.loras.clear();
        info.model.clear();
    }
}

pub fn parse_novelai(description: &str, comment: &str, info: &mut GenInfo) {
    info.source = "novelai".into();
    info.prompt = description.to_string();
    if let Some(Value::Object(map)) = parse_lenient(comment) {
        for (k, v) in &map {
            match k.as_str() {
                "prompt" => {
                    if let Some(s) = v.as_str() {
                        info.prompt = s.to_string();
                    }
                }
                "uc" => info.negative = display(v),
                "seed" => info.seed = display(v),
                _ => {
                    let shown = display(v);
                    if !shown.is_empty() && shown.len() < 400 {
                        info.param(k, shown);
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classic_block() {
        let text = "masterpiece, a cat <lora:fluffy_v2:0.8>\nsecond line\nNegative prompt: blurry, lowres\nmore negative\nSteps: 28, Sampler: DPM++ 2M, Schedule type: Karras, CFG scale: 6.5, Seed: 1234567890, Size: 832x1216, Model hash: abc123, Model: ponyXL_v6, VAE: sdxl_vae.safetensors, Lora hashes: \"fluffy_v2: deadbeef, other: 1234\", Version: v1.9.4";
        let mut info = GenInfo::default();
        parse(text, &mut info);
        assert_eq!(info.source, "a1111");
        assert_eq!(info.prompt, "masterpiece, a cat <lora:fluffy_v2:0.8>\nsecond line");
        assert_eq!(info.negative, "blurry, lowres\nmore negative");
        assert_eq!(info.seed, "1234567890");
        assert_eq!(info.model, "ponyXL_v6");
        assert_eq!(info.models[0].hash, "abc123");
        assert!(info.models.iter().any(|m| m.kind == "vae" && m.name == "sdxl_vae.safetensors"));
        let fluffy = info.loras.iter().find(|l| l.name == "fluffy_v2").unwrap();
        assert_eq!(fluffy.weight, Some(0.8));
        assert_eq!(fluffy.hash, "deadbeef");
        assert!(info.loras.iter().any(|l| l.name == "other"));
        let p = |k: &str| info.params.iter().find(|p| p.0 == k).map(|p| p.1.as_str());
        assert_eq!(p("Steps"), Some("28"));
        assert_eq!(p("Sampler"), Some("DPM++ 2M"));
        assert_eq!(p("CFG scale"), Some("6.5"));
        assert_eq!(p("Size"), Some("832x1216"));
    }

    #[test]
    fn forge_and_no_negative() {
        let text = "a dog\nSteps: 20, Sampler: Euler, Seed: 5, Size: 512x512, Model: flux1-dev, Version: f2.0.1v1.10.1";
        let mut info = GenInfo::default();
        parse(text, &mut info);
        assert_eq!(info.source, "forge");
        assert_eq!(info.prompt, "a dog");
        assert_eq!(info.negative, "");
        assert_eq!(info.seed, "5");
    }

    #[test]
    fn plain_text_is_not_claimed() {
        let mut info = GenInfo::default();
        parse("just a note someone left", &mut info);
        assert_eq!(info.source, "");
    }

    #[test]
    fn swarm_json() {
        let text = r#"{"sui_image_params":{"prompt":"a fox","negativeprompt":"bad","model":"sdxl/juggernaut","seed":42,"steps":30,"cfgscale":7.0,"loras":["detail"],"loraweights":["0.6"]}}"#;
        let mut info = GenInfo::default();
        parse_json_params(text, &mut info);
        assert_eq!(info.source, "swarmui");
        assert_eq!(info.prompt, "a fox");
        assert_eq!(info.negative, "bad");
        assert_eq!(info.seed, "42");
        assert_eq!(info.model, "sdxl/juggernaut");
        assert_eq!(info.loras[0].name, "detail");
        assert_eq!(info.loras[0].weight, Some(0.6));
    }
}
