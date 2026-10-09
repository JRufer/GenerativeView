//! ComfyUI graphs.
//!
//! The `prompt` blob is the executed graph in API format:
//! `{ "<id>": { "class_type": "...", "inputs": { name: literal | [src_id, slot] } } }`.
//! There is no fixed schema — any custom node can appear — so extraction is
//! structural: find the sampler, walk its conditioning inputs back to the text
//! that fed them, and classify model files by the input names that load them.

use super::json::{display, parse_lenient, scalar};
use super::{GenInfo, Node};
use serde_json::{Map, Value};
use std::collections::HashSet;

type Graph = Map<String, Value>;

const MODEL_EXTS: &[&str] = &[".safetensors", ".ckpt", ".pt", ".pth", ".gguf", ".sft", ".bin", ".onnx"];

/// Link inputs that never lead to prompt text; following them would only
/// wander off into loaders and image pipelines.
const NON_TEXT_LINKS: &[&str] = &[
    "model", "clip", "vae", "latent", "latent_image", "samples", "image", "images", "pixels", "mask",
    "control_net", "clip_vision", "clip_vision_output", "noise", "sigmas", "sampler", "style_model",
    "gligen_textbox_model", "unet", "upscale_model", "audio", "video", "reference_latents",
];

pub fn parse(prompt: Option<&str>, workflow: Option<&str>, info: &mut GenInfo) {
    let graph = prompt.and_then(parse_lenient).and_then(|v| match v {
        Value::Object(m) if looks_like_api_graph(&m) => Some(m),
        _ => None,
    });
    match graph {
        Some(g) => {
            info.source = "comfyui".into();
            parse_graph(&g, info);
        }
        None => {
            if let Some(Value::Object(w)) = workflow.and_then(parse_lenient) {
                if w.get("nodes").map_or(false, Value::is_array) {
                    info.source = "comfyui".into();
                    parse_ui_workflow(&w, info);
                }
            }
        }
    }
}

fn looks_like_api_graph(m: &Graph) -> bool {
    !m.is_empty() && m.values().any(|n| n.get("class_type").is_some())
}

fn inputs(node: &Value) -> Option<&Map<String, Value>> {
    node.get("inputs")?.as_object()
}

fn class(node: &Value) -> &str {
    node.get("class_type").and_then(Value::as_str).unwrap_or("")
}

fn title(node: &Value) -> &str {
    node.get("_meta")
        .and_then(|m| m.get("title"))
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| class(node))
}

/// `[source_id, slot]` -> source id, if that node exists.
fn link<'a>(g: &'a Graph, v: &Value) -> Option<(&'a str, &'a Value)> {
    let arr = v.as_array()?;
    if arr.len() != 2 || !arr[1].is_number() {
        return None;
    }
    let id = match &arr[0] {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => return None,
    };
    g.get_key_value(&id).map(|(k, v)| (k.as_str(), v))
}

/// Node ids in a stable, human order: numeric where possible.
fn ordered_ids(g: &Graph) -> Vec<&str> {
    let mut ids: Vec<&str> = g.keys().map(String::as_str).collect();
    ids.sort_by(|a, b| {
        let key = |s: &str| -> (Vec<u64>, String) {
            (s.split(':').map(|p| p.parse::<u64>().unwrap_or(u64::MAX)).collect(), s.to_string())
        };
        key(a).cmp(&key(b))
    });
    ids
}

fn parse_graph(g: &Graph, info: &mut GenInfo) {
    let ids = ordered_ids(g);

    // --- samplers ---------------------------------------------------------
    let samplers: Vec<&str> = ids.iter().copied().filter(|id| is_sampler(g, &g[*id])).collect();
    // Prefer a first-pass sampler: one whose latent does not come out of
    // another sampler (hires-fix / detailer passes sit downstream).
    let primary = samplers
        .iter()
        .copied()
        .find(|id| !has_upstream_sampler(g, id, &samplers))
        .or_else(|| samplers.first().copied());

    let mut all_pos: Vec<String> = Vec::new();
    let mut all_neg: Vec<String> = Vec::new();
    let mut order: Vec<&str> = Vec::new();
    order.extend(primary);
    order.extend(samplers.iter().copied().filter(|s| Some(*s) != primary));
    for (i, id) in order.iter().enumerate() {
        let (pos, neg) = sampler_texts(g, &g[*id]);
        if i == 0 || info.prompt.is_empty() {
            if !pos.is_empty() {
                info.prompt = pos.join("\n\n");
            }
        }
        if i == 0 || info.negative.is_empty() {
            if !neg.is_empty() {
                info.negative = neg.join("\n\n");
            }
        }
        all_pos.extend(pos);
        all_neg.extend(neg);
    }

    if let Some(id) = primary {
        sampler_params(g, &g[id], info);
    }

    // --- no sampler we recognise: fall back to text-encode nodes -----------
    if info.prompt.is_empty() && info.negative.is_empty() {
        let mut pos = Vec::new();
        let mut neg = Vec::new();
        for id in &ids {
            let node = &g[*id];
            let Some(inp) = inputs(node) else { continue };
            let cls = class(node);
            if !(cls.contains("TextEncode") || cls.contains("CLIPText") || (inp.contains_key("clip") && has_text_input(inp))) {
                continue;
            }
            let mut texts = Vec::new();
            collect_text(g, node, Polarity::Pos, false, &mut texts, &mut HashSet::new(), 0);
            let t = title(node).to_ascii_lowercase();
            if t.contains("neg") {
                neg.extend(texts);
            } else {
                pos.extend(texts);
            }
        }
        dedup(&mut pos);
        dedup(&mut neg);
        info.prompt = pos.join("\n\n");
        info.negative = neg.join("\n\n");
    }

    // --- models, loras and graph-wide settings -----------------------------
    for id in &ids {
        let node = &g[*id];
        let Some(inp) = inputs(node) else { continue };
        scan_models(class(node), inp, info);
        scan_settings(g, class(node), inp, info);
    }
    for text in [&info.prompt, &info.negative] {
        for (name, w) in super::a1111::lora_tags(text) {
            if !info.loras.iter().any(|l| stem(&l.name) == stem(&name)) {
                info.loras.push(super::Lora { name, weight: w, weight_clip: None, hash: String::new() });
            }
        }
    }

    // --- node dump + extra searchable text ---------------------------------
    let mut extra = String::new();
    for t in all_pos.iter().chain(all_neg.iter()) {
        if !info.prompt.contains(t.as_str()) && !info.negative.contains(t.as_str()) {
            extra.push_str(t);
            extra.push('\n');
        }
    }
    for id in &ids {
        let node = &g[*id];
        let mut n = Node { id: id.to_string(), class: class(node).to_string(), title: title(node).to_string(), inputs: Vec::new() };
        if let Some(inp) = inputs(node) {
            for (k, v) in inp {
                let shown = match link(g, v) {
                    Some((src, src_node)) => format!("→ {} #{}", title(src_node), src),
                    None => display(v),
                };
                if let (None, Value::String(s)) = (link(g, v), v) {
                    // Free text typed into any node is worth finding later.
                    if is_text_key(k) && s.len() > 2 && !info.prompt.contains(s.as_str()) && !info.negative.contains(s.as_str()) && !extra.contains(s.as_str()) {
                        extra.push_str(s);
                        extra.push('\n');
                    }
                }
                n.inputs.push((k.clone(), shown));
            }
        }
        info.nodes.push(n);
    }
    info.extra = extra;
}

// ---------------------------------------------------------------- samplers

fn is_sampler(g: &Graph, node: &Value) -> bool {
    let Some(inp) = inputs(node) else { return false };
    if inp.get("guider").and_then(|v| link(g, v)).is_some() {
        return true;
    }
    let linked = |k: &str| inp.get(k).and_then(|v| link(g, v)).is_some();
    if !(linked("positive") && linked("negative")) {
        return false;
    }
    ["seed", "noise_seed", "steps", "sigmas", "noise", "cfg", "denoise", "sampler_name"].iter().any(|k| inp.contains_key(*k))
}

fn has_upstream_sampler(g: &Graph, id: &str, samplers: &[&str]) -> bool {
    let mut stack = vec![id];
    let mut seen: HashSet<&str> = HashSet::new();
    let mut first = true;
    while let Some(cur) = stack.pop() {
        if !seen.insert(cur) || seen.len() > 512 {
            continue;
        }
        if !first && samplers.contains(&cur) {
            return true;
        }
        let Some(inp) = g.get(cur).and_then(inputs) else { continue };
        for (k, v) in inp {
            // Only the image/latent path counts as "upstream"; conditioning
            // and model inputs are shared between passes.
            let follows = if first {
                matches!(k.as_str(), "latent_image" | "latent" | "samples" | "image" | "images")
            } else {
                !matches!(k.as_str(), "model" | "clip" | "vae" | "positive" | "negative" | "conditioning")
            };
            if follows {
                if let Some((src, _)) = link(g, v) {
                    stack.push(src);
                }
            }
        }
        first = false;
    }
    false
}

#[derive(Clone, Copy, PartialEq)]
enum Polarity {
    Pos,
    Neg,
}

fn sampler_texts(g: &Graph, node: &Value) -> (Vec<String>, Vec<String>) {
    let mut pos = Vec::new();
    let mut neg = Vec::new();
    let Some(inp) = inputs(node) else { return (pos, neg) };
    let follow = |key: &str, pol: Polarity, out: &mut Vec<String>| {
        if let Some((_, src)) = inp.get(key).and_then(|v| link(g, v)) {
            collect_text(g, src, pol, false, out, &mut HashSet::new(), 0);
        }
    };
    follow("positive", Polarity::Pos, &mut pos);
    follow("negative", Polarity::Neg, &mut neg);
    if let Some((_, guider)) = inp.get("guider").and_then(|v| link(g, v)) {
        if let Some(gi) = inputs(guider) {
            for (k, v) in gi {
                let Some((_, src)) = link(g, v) else { continue };
                match k.as_str() {
                    "negative" => collect_text(g, src, Polarity::Neg, false, &mut neg, &mut HashSet::new(), 0),
                    "positive" | "conditioning" | "cond1" | "cond2" | "cond" => {
                        collect_text(g, src, Polarity::Pos, false, &mut pos, &mut HashSet::new(), 0)
                    }
                    _ => {}
                }
            }
        }
    }
    dedup(&mut pos);
    dedup(&mut neg);
    (pos, neg)
}

fn is_text_key(k: &str) -> bool {
    let k = k.to_ascii_lowercase();
    matches!(k.as_str(), "t5xxl" | "clip_l" | "clip_g" | "llama" | "string" | "positive" | "negative" | "caption" | "tags" | "wildcard")
        || k.contains("text")
        || k.contains("prompt")
}

fn has_text_input(inp: &Map<String, Value>) -> bool {
    inp.iter().any(|(k, v)| is_text_key(k) && (v.is_string() || v.is_array()))
}

fn looks_like_setting(s: &str) -> bool {
    let l = s.trim();
    l.is_empty()
        || matches!(l, "true" | "false" | "enable" | "disable" | "none" | "None" | "fixed" | "randomize" | "default")
        || MODEL_EXTS.iter().any(|e| l.to_ascii_lowercase().ends_with(e))
}

/// Walk backwards from a conditioning input, gathering the prompt text that
/// produced it. `from_text` means we arrived through a text-carrying link, so
/// any string on the node is the text itself (primitive / concat nodes).
fn collect_text<'a>(
    g: &'a Graph,
    node: &'a Value,
    pol: Polarity,
    from_text: bool,
    out: &mut Vec<String>,
    seen: &mut HashSet<*const Value>,
    depth: usize,
) {
    if depth > 24 || !seen.insert(node as *const Value) {
        return;
    }
    // A zeroed conditioning carries no prompt, whatever text fed it.
    if class(node).contains("ZeroOut") {
        return;
    }
    let Some(inp) = inputs(node) else { return };

    // Nodes that pass both polarities through (ControlNet apply, inpaint
    // conditioning...): stay on our side.
    if !from_text && inp.contains_key("positive") && inp.contains_key("negative") {
        let key = if pol == Polarity::Pos { "positive" } else { "negative" };
        match inp.get(key) {
            Some(v) => match link(g, v) {
                Some((_, src)) => collect_text(g, src, pol, false, out, seen, depth + 1),
                None => {
                    if let Value::String(s) = v {
                        push_text(out, s);
                    }
                }
            },
            None => {}
        }
        return;
    }

    for (k, v) in inp {
        match link(g, v) {
            Some((_, src)) => {
                let text_link = is_text_key(k) || from_text;
                if text_link {
                    collect_text(g, src, pol, true, out, seen, depth + 1);
                } else if !NON_TEXT_LINKS.contains(&k.as_str()) {
                    collect_text(g, src, pol, false, out, seen, depth + 1);
                }
            }
            None => {
                let Value::String(s) = v else { continue };
                if from_text {
                    let kl = k.to_ascii_lowercase();
                    if matches!(kl.as_str(), "delimiter" | "separator" | "mode" | "seed_mode" | "clean_whitespace") || looks_like_setting(s) {
                        continue;
                    }
                    push_text(out, s);
                } else if is_text_key(k) && !looks_like_setting(s) {
                    push_text(out, s);
                }
            }
        }
    }
}

fn push_text(out: &mut Vec<String>, s: &str) {
    let t = s.trim();
    if !t.is_empty() {
        out.push(t.to_string());
    }
}

fn dedup(v: &mut Vec<String>) {
    let mut seen = HashSet::new();
    v.retain(|s| seen.insert(s.clone()));
}

/// Resolve an input to a scalar, following links to whichever node supplies
/// the value (primitives, seed generators, scheduler nodes...).
fn resolve(g: &Graph, node: &Value, key: &str, depth: usize) -> Option<String> {
    let v = inputs(node)?.get(key)?;
    match link(g, v) {
        None => scalar(v),
        Some((_, src)) if depth < 8 => {
            let si = inputs(src)?;
            let candidates = [key, "value", "seed", "noise_seed", "int", "float", "number", "string", "text", "Value"];
            for c in candidates {
                if si.contains_key(c) {
                    if let Some(r) = resolve(g, src, c, depth + 1) {
                        return Some(r);
                    }
                }
            }
            // A node with exactly one literal input is a primitive in disguise.
            let mut lits = si.values().filter(|v| link(g, v).is_none()).filter_map(scalar);
            match (lits.next(), lits.next()) {
                (Some(one), None) => Some(one),
                _ => None,
            }
        }
        _ => None,
    }
}

fn sampler_params(g: &Graph, node: &Value, info: &mut GenInfo) {
    let Some(inp) = inputs(node) else { return };
    let via = |link_key: &str, key: &str| -> Option<String> {
        let (_, src) = inp.get(link_key).and_then(|v| link(g, v))?;
        resolve(g, src, key, 0)
    };

    let seed = resolve(g, node, "seed", 0)
        .or_else(|| resolve(g, node, "noise_seed", 0))
        .or_else(|| via("noise", "noise_seed"))
        .or_else(|| via("noise", "seed"));
    if let Some(s) = seed {
        info.seed = s;
    }

    let steps = resolve(g, node, "steps", 0).or_else(|| via("sigmas", "steps"));
    let cfg = resolve(g, node, "cfg", 0).or_else(|| via("guider", "cfg"));
    let sampler = resolve(g, node, "sampler_name", 0).or_else(|| via("sampler", "sampler_name"));
    let scheduler = resolve(g, node, "scheduler", 0).or_else(|| via("sigmas", "scheduler"));
    let denoise = resolve(g, node, "denoise", 0).or_else(|| via("sigmas", "denoise"));

    if let Some(v) = steps {
        info.param("Steps", v);
    }
    if let Some(v) = cfg {
        info.param("CFG", v);
    }
    if let Some(v) = sampler {
        info.param("Sampler", v);
    }
    if let Some(v) = scheduler {
        info.param("Scheduler", v);
    }
    if let Some(v) = denoise {
        info.param("Denoise", v);
    }
    for (key, label) in [("start_at_step", "Start step"), ("end_at_step", "End step"), ("add_noise", "Add noise")] {
        if let Some(v) = resolve(g, node, key, 0) {
            info.param(label, v);
        }
    }
}

// ---------------------------------------------------------------- models

fn is_model_file(s: &str) -> bool {
    let l = s.to_ascii_lowercase();
    MODEL_EXTS.iter().any(|e| l.ends_with(e))
}

fn stem(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or(name);
    let l = base.to_ascii_lowercase();
    for e in MODEL_EXTS {
        if l.ends_with(e) {
            return l[..l.len() - e.len()].to_string();
        }
    }
    l
}

fn num(v: Option<&Value>) -> Option<f64> {
    v.and_then(Value::as_f64)
}

fn scan_models(cls: &str, inp: &Map<String, Value>, info: &mut GenInfo) {
    let cl = cls.to_ascii_lowercase();
    for (k, v) in inp {
        // rgthree Power Lora Loader: lora_1: {on, lora, strength, strengthTwo}
        if let Value::Object(o) = v {
            if let Some(name) = o.get("lora").and_then(Value::as_str) {
                if o.get("on").and_then(Value::as_bool).unwrap_or(true) {
                    info.add_lora(name, num(o.get("strength")), num(o.get("strengthTwo")));
                }
            }
            continue;
        }
        let Value::String(s) = v else { continue };
        let kl = k.to_ascii_lowercase();
        // Loader inputs by convention end in `_name`; accept those even when
        // the value has no file extension (diffusers folders), and accept
        // anything else only when it is unmistakably a model file.
        let loader_key = matches!(kl.as_str(), "ckpt_name" | "unet_name" | "vae_name" | "lora_name" | "control_net_name")
            || kl.starts_with("clip_name");
        if !(is_model_file(s) || loader_key) {
            continue;
        }
        if kl.contains("lora") || (cl.contains("lora") && !kl.contains("ckpt")) {
            // Weights live next to the name: strength_model/strength_clip, or
            // numbered siblings in stacker nodes (lora_wt_1, strength_01...).
            let suffix: String = kl.chars().rev().take_while(|c| c.is_ascii_digit() || *c == '_').collect::<Vec<_>>().into_iter().rev().collect();
            let digits = suffix.trim_matches('_');
            let pick = |names: &[&str]| -> Option<f64> { names.iter().find_map(|n| num(inp.get(*n))) };
            let (w, wc) = if digits.is_empty() {
                (pick(&["strength_model", "strength", "lora_strength", "weight", "lora_weight", "model_strength"]), pick(&["strength_clip", "clip_strength"]))
            } else {
                let d = digits;
                let cands: Vec<String> = ["lora_wt_", "strength_", "model_str_", "lora_strength_", "weight_", "model_weight_", "lora_weight_"]
                    .iter()
                    .map(|p| format!("{p}{d}"))
                    .collect();
                let clip: Vec<String> = ["clip_str_", "clip_strength_", "clip_weight_"].iter().map(|p| format!("{p}{d}")).collect();
                (cands.iter().find_map(|n| num(inp.get(n))), clip.iter().find_map(|n| num(inp.get(n))))
            };
            info.add_lora(s, w, wc);
            continue;
        }
        let kind = if kl.contains("ckpt") {
            "checkpoint"
        } else if kl.contains("unet") || cl.contains("unetloader") || cl.contains("diffusionmodel") {
            "unet"
        } else if kl.contains("vae") {
            "vae"
        } else if kl.contains("control_net") || kl.contains("controlnet") {
            "controlnet"
        } else if kl.starts_with("clip_name") || kl.contains("text_encoder") {
            "clip"
        } else if kl.contains("clip_vision") || (cl.contains("clipvision") && kl.contains("clip")) {
            "clip_vision"
        } else if cl.contains("upscale") {
            "upscaler"
        } else if kl.contains("hypernetwork") {
            "hypernetwork"
        } else if kl.contains("style_model") {
            "style_model"
        } else if kl.contains("ipadapter") || cl.contains("ipadapter") {
            "ipadapter"
        } else if cl.contains("checkpoint") {
            "checkpoint"
        } else {
            "model"
        };
        info.add_model(kind, s, "");
    }
}

fn scan_settings(g: &Graph, cls: &str, inp: &Map<String, Value>, info: &mut GenInfo) {
    let get = |k: &str| inp.get(k).filter(|v| link(g, v).is_none()).and_then(scalar);
    if cls.contains("Empty") && cls.contains("Latent") {
        if let (Some(w), Some(h)) = (get("width"), get("height")) {
            if !info.params.iter().any(|p| p.0 == "Size") {
                info.param("Size", format!("{w}x{h}"));
                if let Some(b) = get("batch_size").filter(|b| b != "1") {
                    info.param("Batch", b);
                }
                if let Some(l) = get("length").filter(|l| l != "1") {
                    info.param("Frames", l);
                }
            }
        }
    }
    match cls {
        "FluxGuidance" => {
            if let Some(v) = get("guidance") {
                info.param("Guidance", v);
            }
        }
        "CLIPSetLastLayer" => {
            if let Some(v) = get("stop_at_clip_layer") {
                info.param("Clip skip", v);
            }
        }
        _ => {}
    }
    if cls.starts_with("ModelSampling") {
        if let Some(v) = get("shift") {
            if !info.params.iter().any(|p| p.0 == "Shift") {
                info.param("Shift", v);
            }
        }
    }
}

// ---------------------------------------------------------------- UI workflow only

/// Fallback when the file carries only the editor's `workflow` JSON. Widget
/// values are positional there, so this is best effort: prompt text from
/// text-encode nodes, model files by extension, seed from the sampler.
fn parse_ui_workflow(w: &Graph, info: &mut GenInfo) {
    let Some(nodes) = w.get("nodes").and_then(Value::as_array) else { return };
    let mut pos = Vec::new();
    let mut neg = Vec::new();
    for node in nodes {
        let ty = node.get("type").and_then(Value::as_str).unwrap_or("");
        let ttl = node.get("title").and_then(Value::as_str).unwrap_or(ty);
        let values: Vec<&Value> = match node.get("widgets_values") {
            Some(Value::Array(a)) => a.iter().collect(),
            Some(Value::Object(o)) => o.values().collect(),
            _ => Vec::new(),
        };
        let tl = ty.to_ascii_lowercase();
        let mut shown = Vec::new();
        for (i, v) in values.iter().enumerate() {
            let text = display(v);
            if text.is_empty() {
                continue;
            }
            if let Value::String(s) = v {
                if is_model_file(s) {
                    if tl.contains("lora") {
                        let weight = values.get(i + 1).and_then(|v| v.as_f64());
                        info.add_lora(s, weight, None);
                    } else {
                        let kind = if tl.contains("checkpoint") {
                            "checkpoint"
                        } else if tl.contains("unet") || tl.contains("diffusion") {
                            "unet"
                        } else if tl.contains("vae") {
                            "vae"
                        } else if tl.contains("controlnet") {
                            "controlnet"
                        } else if tl.contains("clip") {
                            "clip"
                        } else if tl.contains("upscale") {
                            "upscaler"
                        } else {
                            "model"
                        };
                        info.add_model(kind, s, "");
                    }
                } else if tl.contains("textencode") || tl.contains("cliptext") {
                    if ttl.to_ascii_lowercase().contains("neg") {
                        push_text(&mut neg, s);
                    } else {
                        push_text(&mut pos, s);
                    }
                }
            }
            shown.push((format!("widget {i}"), text));
        }
        if tl.starts_with("ksampler") && info.seed.is_empty() {
            if let Some(seed) = values.first().and_then(|v| v.as_u64()) {
                info.seed = seed.to_string();
            }
        }
        info.nodes.push(Node {
            id: node.get("id").map(display).unwrap_or_default(),
            class: ty.to_string(),
            title: ttl.to_string(),
            inputs: shown,
        });
    }
    dedup(&mut pos);
    dedup(&mut neg);
    info.prompt = pos.join("\n\n");
    info.negative = neg.join("\n\n");
}
