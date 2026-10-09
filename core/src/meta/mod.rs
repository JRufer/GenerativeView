//! Generation-metadata extraction.
//!
//! Two layers:
//!  * `container` pulls dimensions and raw text blobs out of the file format
//!    (PNG text chunks, EXIF in JPEG/WebP, tags in MP4/WebM) without decoding
//!    any pixels.
//!  * the per-tool parsers (`comfy`, `a1111`, `invoke`) turn those blobs into
//!    one normalised [`GenInfo`].

pub mod a1111;
pub mod comfy;
pub mod container;
pub mod invoke;
mod json;

use serde::Serialize;
use std::path::Path;

pub use container::{read_raw, RawMeta};

#[derive(Debug, Default, Clone, Serialize, PartialEq)]
pub struct ModelRef {
    /// checkpoint, unet, vae, clip, controlnet, upscaler, refiner, ...
    pub kind: String,
    pub name: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub hash: String,
}

#[derive(Debug, Default, Clone, Serialize, PartialEq)]
pub struct Lora {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub weight: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub weight_clip: Option<f64>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub hash: String,
}

/// One node of a ComfyUI graph, flattened for display.
#[derive(Debug, Default, Clone, Serialize)]
pub struct Node {
    pub id: String,
    pub class: String,
    pub title: String,
    /// (input name, value). Links are rendered as "→ Title #id".
    pub inputs: Vec<(String, String)>,
}

#[derive(Debug, Default, Clone, Serialize)]
pub struct GenInfo {
    /// comfyui | invokeai | a1111 | novelai | swarmui | fooocus | "" (none found)
    pub source: String,
    pub prompt: String,
    pub negative: String,
    pub seed: String,
    /// Main model (checkpoint / diffusion model) name.
    pub model: String,
    pub models: Vec<ModelRef>,
    pub loras: Vec<Lora>,
    /// Everything else worth showing, in display order: Steps, CFG, Sampler...
    pub params: Vec<(String, String)>,
    /// ComfyUI graph, one entry per node.
    pub nodes: Vec<Node>,
    pub width: u32,
    pub height: u32,
    pub duration_ms: u64,
    /// Raw text blobs exactly as stored in the file (workflow JSON etc.).
    pub raw: Vec<(String, String)>,
    /// Additional searchable text that is not shown as a field of its own.
    #[serde(skip)]
    pub extra: String,
}

impl GenInfo {
    pub fn param(&mut self, key: &str, value: impl Into<String>) {
        let value = value.into();
        if value.is_empty() {
            return;
        }
        if let Some(p) = self.params.iter_mut().find(|p| p.0 == key) {
            p.1 = value;
        } else {
            self.params.push((key.to_string(), value));
        }
    }

    pub fn add_model(&mut self, kind: &str, name: &str, hash: &str) {
        let name = name.trim();
        if name.is_empty() || name.eq_ignore_ascii_case("none") {
            return;
        }
        if let Some(m) = self.models.iter_mut().find(|m| m.name == name && m.kind == kind) {
            if m.hash.is_empty() {
                m.hash = hash.to_string();
            }
            return;
        }
        self.models.push(ModelRef { kind: kind.into(), name: name.into(), hash: hash.into() });
    }

    pub fn add_lora(&mut self, name: &str, weight: Option<f64>, weight_clip: Option<f64>) {
        let name = name.trim();
        if name.is_empty() || name.eq_ignore_ascii_case("none") {
            return;
        }
        if let Some(l) = self.loras.iter_mut().find(|l| l.name == name) {
            if l.weight.is_none() {
                l.weight = weight;
            }
            if l.weight_clip.is_none() {
                l.weight_clip = weight_clip;
            }
            return;
        }
        self.loras.push(Lora { name: name.into(), weight, weight_clip, hash: String::new() });
    }

    /// Space-joined model names, for the search index.
    pub fn models_text(&self) -> String {
        let mut s = String::new();
        if !self.model.is_empty() {
            s.push_str(&self.model);
        }
        for m in &self.models {
            if m.name != self.model {
                if !s.is_empty() {
                    s.push('\n');
                }
                s.push_str(&m.name);
            }
        }
        s
    }

    pub fn loras_text(&self) -> String {
        self.loras.iter().map(|l| l.name.as_str()).collect::<Vec<_>>().join("\n")
    }

    /// Everything else that should be findable by search.
    pub fn extra_text(&self) -> String {
        let mut s = String::new();
        if !self.source.is_empty() {
            s.push_str(&self.source);
            s.push('\n');
        }
        if !self.seed.is_empty() {
            s.push_str(&self.seed);
            s.push('\n');
        }
        for (k, v) in &self.params {
            s.push_str(k);
            s.push_str(": ");
            s.push_str(v);
            s.push('\n');
        }
        s.push_str(&self.extra);
        s
    }

    fn finish(&mut self) {
        if self.model.is_empty() {
            let pick = ["checkpoint", "unet", "model"]
                .iter()
                .find_map(|k| self.models.iter().find(|m| m.kind == *k));
            if let Some(m) = pick {
                self.model = m.name.clone();
            }
        }
        // Main model first, then the supporting cast.
        let rank = |kind: &str| match kind {
            "checkpoint" => 0,
            "unet" | "model" => 1,
            "refiner" => 2,
            "vae" => 3,
            "clip" => 4,
            _ => 5,
        };
        self.models.sort_by_key(|m| rank(&m.kind));
        self.prompt = self.prompt.trim().to_string();
        self.negative = self.negative.trim().to_string();
    }
}

/// Turn raw container text into normalised generation info.
pub fn parse(raw: RawMeta) -> GenInfo {
    let mut info = GenInfo {
        width: raw.width,
        height: raw.height,
        duration_ms: raw.duration_ms,
        ..Default::default()
    };
    let mut texts = raw.texts;
    expand_embedded(&mut texts);

    let get = |texts: &[(String, String)], key: &str| -> Option<String> {
        texts.iter().find(|(k, _)| k.eq_ignore_ascii_case(key)).map(|(_, v)| v.clone())
    };

    // InvokeAI first: it never co-exists with the others.
    if let Some(m) = get(&texts, "invokeai_metadata") {
        invoke::parse_v3(&m, &mut info);
    } else if let Some(m) = get(&texts, "sd-metadata") {
        invoke::parse_legacy(&m, &mut info);
    }

    // ComfyUI: API-format graph in `prompt`, UI graph in `workflow`.
    if info.source.is_empty() {
        let prompt = get(&texts, "prompt").filter(|p| p.trim_start().starts_with('{'));
        let workflow = get(&texts, "workflow").filter(|p| p.trim_start().starts_with('{'));
        if prompt.is_some() || workflow.is_some() {
            comfy::parse(prompt.as_deref(), workflow.as_deref(), &mut info);
        }
    }

    // A1111 / Forge and friends: the `parameters` blob (PNG) or EXIF
    // UserComment (JPEG/WebP).
    if info.source.is_empty() {
        let params = get(&texts, "parameters")
            .or_else(|| get(&texts, "UserComment"))
            .or_else(|| get(&texts, "ImageDescription").filter(|d| a1111::looks_like(d)));
        if let Some(p) = params {
            let t = p.trim_start();
            if t.starts_with('{') {
                a1111::parse_json_params(t, &mut info);
            } else if !t.is_empty() {
                a1111::parse(&p, &mut info);
            }
        }
    }

    // NovelAI: Description = prompt, Comment = JSON settings.
    if info.source.is_empty() {
        let software = get(&texts, "Software").unwrap_or_default();
        if software.contains("NovelAI") {
            a1111::parse_novelai(
                get(&texts, "Description").as_deref().unwrap_or(""),
                get(&texts, "Comment").as_deref().unwrap_or(""),
                &mut info,
            );
        }
    }

    info.raw = texts;
    info.finish();
    info
}

/// Some writers nest everything in one tag: VideoHelperSuite stores
/// `comment = {"prompt": "...", "workflow": {...}}` in MP4/WebM. Lift those
/// members up so the normal parsers see them.
fn expand_embedded(texts: &mut Vec<(String, String)>) {
    let has = |texts: &[(String, String)], key: &str| texts.iter().any(|(k, _)| k.eq_ignore_ascii_case(key));
    if has(texts, "prompt") || has(texts, "workflow") {
        return;
    }
    let mut lifted = Vec::new();
    for (key, value) in texts.iter() {
        if !key.eq_ignore_ascii_case("comment") && !key.eq_ignore_ascii_case("description") {
            continue;
        }
        let t = value.trim_start();
        if !t.starts_with('{') {
            continue;
        }
        let Some(serde_json::Value::Object(map)) = json::parse_lenient(t) else { continue };
        for name in ["prompt", "workflow"] {
            match map.get(name) {
                Some(serde_json::Value::String(s)) => lifted.push((name.to_string(), s.clone())),
                Some(v @ serde_json::Value::Object(_)) => lifted.push((name.to_string(), v.to_string())),
                _ => {}
            }
        }
        if !lifted.is_empty() {
            break;
        }
    }
    texts.extend(lifted);
}

/// Read and parse a file in one go.
pub fn extract(path: &Path) -> GenInfo {
    match read_raw(path) {
        Ok(raw) => parse(raw),
        Err(_) => GenInfo::default(),
    }
}

/// Media kind by file extension: Some(false) image, Some(true) video.
pub fn media_kind(path: &Path) -> Option<bool> {
    let ext = path.extension()?.to_str()?;
    let mut buf = [0u8; 8];
    if ext.len() > buf.len() {
        return None;
    }
    let lower = &mut buf[..ext.len()];
    lower.copy_from_slice(ext.as_bytes());
    lower.make_ascii_lowercase();
    match &*lower {
        b"png" | b"jpg" | b"jpeg" | b"webp" | b"gif" | b"bmp" => Some(false),
        b"mp4" | b"webm" | b"mov" | b"mkv" | b"m4v" => Some(true),
        _ => None,
    }
}
