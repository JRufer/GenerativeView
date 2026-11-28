//! NovelAI.
//!
//! Every picture carries the same few text chunks: `Description` (the
//! prompt), `Software` ("NovelAI"), `Source` (the model and its hash),
//! `Generation time` and `Comment`, a JSON object of every setting. A WebP
//! keeps them in EXIF instead, where `Software` holds the model,
//! `ImageDescription` the prompt and `UserComment` the JSON. The same
//! chunks are also hidden in the alpha channel (see `stealth`), which the
//! container reader falls back to.
//!
//! The JSON holds the settings worth showing (steps, scale, sampler...) and
//! some forty switches of NovelAI's own sampler (`wonky_vibe_correlation`,
//! `extra_passthrough_testing`...) that mean nothing elsewhere: those stay
//! in the raw Comment block, not the settings list.
//!
//! V4 and later prompt in parts: a base caption plus one caption per
//! character, each with where it stands in the picture. Their emphasis
//! syntax (`{more}`, `[less]`, `1.3::exact::`) and the `source#` /
//! `target#` / `mutual#` marks on actions between characters are
//! NovelAI's alone, so a prompt for other servers is built beside the
//! original: [`GenInfo::server_prompt`].

use super::json::{float, parse_lenient, scalar};
use super::{Character, GenInfo};
use serde_json::{Map, Value};

/// Settings only NovelAI writes: enough of them in a Comment object means
/// NovelAI made it, whatever `Software` says (WebP puts the model there).
const OWN_KEYS: &[&str] = &[
    "signed_hash",
    "v4_prompt",
    "v4_negative_prompt",
    "noise_schedule",
    "uncond_scale",
    "cfg_rescale",
    "sm_dyn",
    "request_type",
    "legacy_v3_extend",
];

fn get<'a>(texts: &'a [(String, String)], key: &str) -> Option<&'a str> {
    texts.iter().find(|(k, _)| k.eq_ignore_ascii_case(key)).map(|(_, v)| v.as_str())
}

/// NovelAI's settings object, when the file is one of its pictures.
pub fn comment(texts: &[(String, String)]) -> Option<Map<String, Value>> {
    let says_novelai = ["Software", "Source"].iter().any(|k| get(texts, k).is_some_and(|s| s.contains("NovelAI")));
    for key in ["Comment", "UserComment"] {
        let Some(text) = get(texts, key) else { continue };
        let t = text.trim_start();
        if !t.starts_with('{') {
            continue;
        }
        let Some(Value::Object(map)) = parse_lenient(t) else { continue };
        let own = OWN_KEYS.iter().filter(|k| map.contains_key(**k)).count();
        if own >= 2 || (says_novelai && (own >= 1 || map.contains_key("prompt") || map.contains_key("uc"))) {
            return Some(map);
        }
    }
    None
}

pub fn parse(texts: &[(String, String)], map: &Map<String, Value>, info: &mut GenInfo) {
    info.source = "novelai".into();
    let caption = |v: Option<&Value>| -> Option<String> {
        v?.get("caption")?.get("base_caption")?.as_str().map(str::to_string)
    };
    let text = |key: &str| map.get(key).and_then(Value::as_str).map(str::to_string);

    info.prompt = caption(map.get("v4_prompt"))
        .or_else(|| text("prompt"))
        .or_else(|| get(texts, "Description").or_else(|| get(texts, "ImageDescription")).map(str::to_string))
        .unwrap_or_default();
    info.negative = caption(map.get("v4_negative_prompt")).or_else(|| text("uc")).unwrap_or_default();
    if let Some(seed) = map.get("seed").and_then(scalar) {
        info.seed = seed;
    }
    info.characters = characters(map);

    // The model: its own fields since V5, else the Source chunk
    // ("NovelAI Diffusion V4.5 4BDE2A90"); WebP keeps that in Software.
    let source = get(texts, "Source")
        .or_else(|| get(texts, "Software").filter(|s| s.trim() != "NovelAI"))
        .unwrap_or("")
        .trim();
    let (mut name, mut hash) = split_hash(source);
    if let Some(n) = text("model_name").filter(|n| !n.is_empty()) {
        name = n;
    }
    if let Some(h) = text("model_hash").filter(|h| !h.is_empty()) {
        hash = h;
    }
    if name.is_empty() {
        name = "NovelAI".into();
    }
    info.model = name.clone();
    info.add_model("checkpoint", &name, &hash);

    settings(texts, map, info);
    let (prompt, negative) = server_prompts(info);
    info.server_prompt = prompt;
    info.server_negative = negative;
}

/// "NovelAI Diffusion V5 DB276663" -> ("NovelAI Diffusion V5", "DB276663")
fn split_hash(source: &str) -> (String, String) {
    match source.rsplit_once(' ') {
        Some((name, hash)) if hash.len() == 8 && hash.bytes().all(|b| b.is_ascii_hexdigit()) => {
            (name.trim().to_string(), hash.to_string())
        }
        _ => (source.to_string(), String::new()),
    }
}

fn characters(map: &Map<String, Value>) -> Vec<Character> {
    let list = |key: &str| -> Vec<Value> {
        map.get(key)
            .and_then(|v| v.get("caption"))
            .and_then(|c| c.get("char_captions"))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    };
    let placed = map.get("v4_prompt").and_then(|v| v.get("use_coords")).and_then(Value::as_bool).unwrap_or(false);
    let positives = list("v4_prompt");
    let negatives = list("v4_negative_prompt");
    positives
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let centre = c.get("centers").and_then(Value::as_array).and_then(|a| a.first());
            let at = |axis: &str| if placed { centre.and_then(|p| p.get(axis)).and_then(Value::as_f64) } else { None };
            Character {
                prompt: c.get("char_caption").and_then(Value::as_str).unwrap_or("").trim().to_string(),
                negative: negatives
                    .get(i)
                    .and_then(|n| n.get("char_caption"))
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_string(),
                x: at("x"),
                y: at("y"),
            }
        })
        .filter(|c| !c.prompt.is_empty() || !c.negative.is_empty())
        .collect()
}

/// The settings list, in the names the rest of the app reads (Steps, CFG,
/// Sampler, Scheduler, Size), then what is worth knowing about this run.
fn settings(texts: &[(String, String)], map: &Map<String, Value>, info: &mut GenInfo) {
    let s = |key: &str| map.get(key).and_then(scalar).filter(|v| !v.is_empty());
    let num = |key: &str| map.get(key).and_then(Value::as_f64);
    let on = |key: &str| map.get(key).and_then(Value::as_bool).unwrap_or(false);
    let list = |key: &str| -> Vec<String> {
        map.get(key).and_then(Value::as_array).map(|a| a.iter().filter_map(scalar).collect()).unwrap_or_default()
    };

    if let Some(v) = s("steps") {
        info.param("Steps", v);
    }
    if let Some(v) = s("scale") {
        info.param("CFG", v);
    }
    if let Some(v) = s("sampler") {
        info.param("Sampler", v);
    }
    if let Some(v) = s("noise_schedule") {
        info.param("Scheduler", v);
    }
    if let (Some(w), Some(h)) = (s("width"), s("height")) {
        info.param("Size", format!("{w}x{h}"));
    }
    if let Some(v) = num("cfg_rescale").filter(|v| *v != 0.0) {
        info.param("CFG rescale", float(v));
    }
    // Image to image: how far it was let go from the picture it started from.
    if let Some(v) = num("strength") {
        info.param("Strength", float(v));
        if let Some(n) = num("noise").filter(|n| *n != 0.0) {
            info.param("Noise", float(n));
        }
    }
    if on("sm") {
        info.param("SMEA", if on("sm_dyn") { "on, DYN" } else { "on" });
    }
    if on("dynamic_thresholding") {
        info.param("Decrisp", "on");
    }
    if map.get("skip_cfg_above_sigma").is_some_and(|v| !v.is_null()) {
        info.param("Variety+", "on");
    }
    if map.get("tag_hint_qt").and_then(Value::as_i64).is_some_and(|q| q != 0) {
        // Already written into the prompt by NovelAI; said so it is not a surprise.
        info.param("Quality tags", "on");
    }
    let vibes = list("reference_strength_multiple");
    if !vibes.is_empty() {
        info.param("Vibe transfer", vibes.join(", "));
    }
    let refs = list("director_reference_strengths");
    if !refs.is_empty() {
        info.param("Character reference", refs.join(", "));
    }
    if !info.characters.is_empty() {
        info.param("Characters", info.characters.len().to_string());
    }
    if let Some(t) = get(texts, "Generation time").and_then(|t| t.trim().parse::<f64>().ok()) {
        info.param("Generation time", format!("{} s", float((t * 10.0).round() / 10.0)));
    }
    if let Some(v) = s("request_type").filter(|r| r != "PromptGenerateRequest") {
        info.param("Request", v);
    }
}

// ---------------------------------------------------------------- prompts for other servers

/// The whole prompt (base caption and every character's) and negative, in
/// the `(words:1.2)` syntax ComfyUI, A1111, Forge and InvokeAI read.
fn server_prompts(info: &GenInfo) -> (String, String) {
    let mut moved = Vec::new();
    let mut parts = vec![standard(&info.prompt, &mut moved)];
    for c in &info.characters {
        parts.push(standard(&strip_actions(&c.prompt), &mut moved));
    }
    let prompt = unique(&tidy(&parts.join(", ")));

    let mut ignored = Vec::new();
    let mut negs = vec![standard(&info.negative, &mut ignored)];
    for c in &info.characters {
        negs.push(standard(&strip_actions(&c.negative), &mut ignored));
    }
    // Words NovelAI was told to steer away from (negative emphasis) are
    // what a negative prompt is for elsewhere.
    negs.extend(moved);
    (prompt, unique(&tidy(&negs.join(", "))))
}

/// Each item once: several characters sharing a tag ("girl", "hand on
/// another's shoulder" on both ends of an action) say it once in one prompt.
fn unique(text: &str) -> String {
    let mut seen = std::collections::HashSet::new();
    text.split(", ").filter(|i| seen.insert(i.to_lowercase())).collect::<Vec<_>>().join(", ")
}

/// `source#hand on another's shoulder` -> `hand on another's shoulder`.
fn strip_actions(text: &str) -> String {
    let mut out = text.to_string();
    for mark in ["source#", "target#", "mutual#"] {
        loop {
            let lower = out.to_ascii_lowercase();
            let Some(at) = lower.find(mark) else { break };
            out.replace_range(at..at + mark.len(), "");
        }
    }
    out
}

/// NovelAI emphasis to the parenthesis syntax. `{x}` is ×1.05 per brace,
/// `[x]` ÷1.05, `1.3::x::` exactly 1.3 (up to the next `::` or the end).
/// Literal parentheses (tags such as `miku (cosplay)`) are escaped, since
/// elsewhere they would weigh. Text NovelAI was told to weigh below zero
/// goes to [moved], for the negative prompt.
fn standard(text: &str, moved: &mut Vec<String>) -> String {
    let mut segs: Vec<(String, f64)> = Vec::new();
    let mut cur = String::new();
    let mut braces: Vec<char> = Vec::new();
    let mut exact: Option<f64> = None;
    let weight = |braces: &[char], exact: Option<f64>| {
        let b: f64 = braces.iter().map(|c| if *c == '{' { 1.05 } else { 1.0 / 1.05 }).product();
        b * exact.unwrap_or(1.0)
    };
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        match c {
            '{' | '[' => {
                segs.push((std::mem::take(&mut cur), weight(&braces, exact)));
                braces.push(c);
            }
            '}' | ']' => {
                let open = if c == '}' { '{' } else { '[' };
                if braces.last() == Some(&open) {
                    segs.push((std::mem::take(&mut cur), weight(&braces, exact)));
                    braces.pop();
                }
                // An unmatched closer means nothing to NovelAI either.
            }
            ':' if chars.get(i + 1) == Some(&':') => {
                if exact.is_some() {
                    segs.push((std::mem::take(&mut cur), weight(&braces, exact)));
                    exact = None;
                } else if let Some((head, n)) = trailing_number(&cur) {
                    cur.truncate(head);
                    segs.push((std::mem::take(&mut cur), weight(&braces, exact)));
                    exact = Some(n);
                }
                i += 2;
                continue;
            }
            '(' => cur.push_str("\\("),
            ')' => cur.push_str("\\)"),
            _ => cur.push(c),
        }
        i += 1;
    }
    segs.push((cur, weight(&braces, exact)));

    // Neighbours at the same weight are one group.
    let mut merged: Vec<(String, f64)> = Vec::new();
    for (t, w) in segs {
        if t.is_empty() {
            continue;
        }
        let w = (w * 100.0).round() / 100.0;
        match merged.last_mut() {
            Some((lt, lw)) if *lw == w => lt.push_str(&t),
            _ => merged.push((t, w)),
        }
    }

    let mut out = String::new();
    for (t, w) in merged {
        if w == 1.0 {
            out.push_str(&t);
            continue;
        }
        // Commas and spaces at the edges stay outside the brackets.
        let core = t.trim_matches(|c: char| c == ',' || c.is_whitespace());
        if core.is_empty() {
            out.push_str(&t);
            continue;
        }
        let start = t.find(core).unwrap_or(0);
        let (lead, trail) = (&t[..start], &t[start + core.len()..]);
        if w <= 0.0 {
            if w < 0.0 {
                moved.push(if w == -1.0 { core.to_string() } else { format!("({core}:{})", float(-w)) });
            }
            out.push_str(lead);
            out.push_str(trail);
        } else {
            out.push_str(&format!("{lead}({core}:{}){trail}", float(w)));
        }
    }
    out
}

/// A number ending [s] at a word boundary: its start and value.
fn trailing_number(s: &str) -> Option<(usize, f64)> {
    let b = s.as_bytes();
    let mut start = b.len();
    while start > 0 && (b[start - 1].is_ascii_digit() || b[start - 1] == b'.') {
        start -= 1;
    }
    if start > 0 && b[start - 1] == b'-' {
        start -= 1;
    }
    if start == b.len() || (start > 0 && (b[start - 1].is_ascii_alphanumeric() || b[start - 1] == b'_')) {
        return None;
    }
    s[start..].parse::<f64>().ok().filter(|n| n.is_finite()).map(|n| (start, n))
}

/// Single spaces, no empty items (`a, , b`), no stray commas at the ends.
fn tidy(text: &str) -> String {
    let mut items: Vec<String> = Vec::new();
    for line in text.split(',') {
        let item = line.split_whitespace().collect::<Vec<_>>().join(" ");
        if !item.is_empty() {
            items.push(item);
        }
    }
    items.join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn std1(t: &str) -> String {
        let mut moved = Vec::new();
        let out = tidy(&standard(t, &mut moved));
        assert!(moved.is_empty(), "{moved:?}");
        out
    }

    #[test]
    fn emphasis_becomes_weights() {
        assert_eq!(std1("1girl, {smile}, [hat]"), "1girl, (smile:1.05), (hat:0.95)");
        assert_eq!(std1("{{{red eyes}}}, cat"), "(red eyes:1.16), cat");
        assert_eq!(std1("1girl, 1.5::red dress, hat::, night"), "1girl, (red dress, hat:1.5), night");
        assert_eq!(std1("0.6::blurry"), "(blurry:0.6)");
        assert_eq!(std1("hatsune miku (cosplay)"), "hatsune miku \\(cosplay\\)");
        assert_eq!(std1("1girl::"), "1girl");
        assert_eq!(std1("girl sandwich, , holding microphone"), "girl sandwich, holding microphone");
        assert_eq!(std1("{unclosed, a] b"), "(unclosed, a b:1.05)");
    }

    #[test]
    fn negative_emphasis_moves_to_the_negative() {
        let mut moved = Vec::new();
        assert_eq!(tidy(&standard("cat, -1::hat::, -2::glasses::, dog", &mut moved)), "cat, dog");
        assert_eq!(moved, ["hat", "(glasses:2)"]);
    }

    #[test]
    fn action_marks_go() {
        assert_eq!(strip_actions("girl, target#hand on another's shoulder, Mutual#hug"), "girl, hand on another's shoulder, hug");
    }

    #[test]
    fn hash_split() {
        assert_eq!(split_hash("NovelAI Diffusion V4.5 4BDE2A90"), ("NovelAI Diffusion V4.5".into(), "4BDE2A90".into()));
        assert_eq!(split_hash("Stable Diffusion"), ("Stable Diffusion".into(), String::new()));
    }
}
