//! What the user's own ratings say about how to prompt.
//!
//! Every picture the user has judged (rated or flagged) is liked or
//! disliked (see [`crate::taste::is_liked`]). Counting which prompt
//! phrases and which settings turn up among the liked ones more than among
//! the disliked ones answers "what works" for this user; the same counts
//! let Prompt Doctor suggest what to add to a prompt or take out of it.
//! Breed mixes the recipes of pictures the user likes into new ones, and
//! Best of Group picks the one of a set of near-duplicates to keep.
//!
//! Everything here is plain arithmetic on what the index already holds; the
//! engine feeds it and the content-search model scores what needs seeing.
use crate::clip::{is_quality_phrase, prompt_phrases};
use crate::taste::{is_disliked, is_liked};
use serde_json::{json, Value};
use std::collections::HashMap;

/// One indexed picture as these counts see it.
#[derive(Debug, Clone, Default)]
pub struct Recipe {
    pub path: String,
    pub mtime: i64,
    pub size: i64,
    /// Lower-cased, as indexed.
    pub prompt: String,
    /// See `GenInfo::facets_text`.
    pub facets: String,
    pub rating: u8,
    /// How liked, 0 to 1 (see [`crate::taste::target`]); None if not judged.
    pub target: Option<f32>,
}

impl Recipe {
    /// The values of facet `kind`, as indexed (keys, lower-cased).
    pub fn facet(&self, kind: &str) -> Vec<&str> {
        self.facets
            .split('\n')
            .filter_map(|line| {
                let mut parts = line.split('\t');
                (parts.next() == Some(kind)).then(|| parts.next()).flatten()
            })
            .collect()
    }

    fn liked(&self) -> bool {
        self.target.is_some_and(is_liked)
    }

    fn disliked(&self) -> bool {
        self.target.is_some_and(is_disliked)
    }
}

/// An item counted must turn up in at least this many judged pictures.
pub const LEAST_SEEN: u32 = 3;
/// Below this many judged pictures an item is shown as too few to trust.
pub const FEW: u32 = 8;
/// An item is listed when its share of the liked and of the disliked
/// pictures differs by at least this much.
pub const LEAST_LIFT: f32 = 0.05;
/// Pictures shown beside an item.
const SAMPLES: usize = 3;

/// How one item (a phrase, a setting range) is spread over the judged
/// pictures.
#[derive(Debug, Clone, Default)]
pub struct Count {
    pub label: String,
    /// phrase | cfg | steps | lora | sampler
    pub kind: &'static str,
    pub liked: u32,
    pub disliked: u32,
    /// Judged pictures with it.
    pub judged: u32,
    /// The search that shows its pictures.
    pub query: String,
    /// Indexes into the recipes: the best liked and the worst disliked.
    best: Vec<(f32, usize)>,
    worst: Vec<(f32, usize)>,
    /// The exact facet values met, for the search.
    values: Vec<String>,
}

impl Count {
    fn add(&mut self, i: usize, r: &Recipe) {
        let Some(t) = r.target else { return };
        self.judged += 1;
        if is_liked(t) {
            self.liked += 1;
            keep_top(&mut self.best, (t, i), |a, b| b.0.total_cmp(&a.0));
        } else if is_disliked(t) {
            self.disliked += 1;
            keep_top(&mut self.worst, (t, i), |a, b| a.0.total_cmp(&b.0));
        }
    }
}

fn keep_top(list: &mut Vec<(f32, usize)>, item: (f32, usize), order: impl Fn(&(f32, usize), &(f32, usize)) -> std::cmp::Ordering) {
    list.push(item);
    list.sort_by(&order);
    list.truncate(SAMPLES);
}

/// Every judged picture's phrases and settings, counted.
pub struct Table {
    pub liked: u32,
    pub disliked: u32,
    pub phrases: HashMap<String, Count>,
    pub settings: HashMap<String, Count>,
}

impl Table {
    /// The share of liked and of disliked pictures an item turns up in.
    pub fn shares(&self, c: &Count) -> (f32, f32) {
        let share = |n: u32, of: u32| if of == 0 { 0.0 } else { n as f32 / of as f32 };
        (share(c.liked, self.liked), share(c.disliked, self.disliked))
    }

    pub fn phrase(&self, phrase: &str) -> Option<&Count> {
        self.phrases.get(&phrase.to_lowercase())
    }
}

/// The range of CFG a value falls in, as (label, key).
fn cfg_bin(v: f64) -> (&'static str, u8) {
    match v {
        v if v < 2.0 => ("CFG under 2", 0),
        v if v < 3.5 => ("CFG 2 – 3.5", 1),
        v if v < 4.5 => ("CFG 3.5 – 4.5", 2),
        v if v < 6.0 => ("CFG 4.5 – 6", 3),
        v if v < 8.0 => ("CFG 6 – 8", 4),
        _ => ("CFG 8 and over", 5),
    }
}

fn steps_bin(v: f64) -> (&'static str, u8) {
    match v {
        v if v < 10.0 => ("Under 10 steps", 0),
        v if v < 20.0 => ("10 – 20 steps", 1),
        v if v < 25.0 => ("20 – 25 steps", 2),
        v if v < 35.0 => ("25 – 35 steps", 3),
        v if v < 50.0 => ("35 – 50 steps", 4),
        _ => ("50 steps and over", 5),
    }
}

/// A LoRA's name without its folder or file extension.
pub fn short_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or(name);
    match base.rfind('.') {
        Some(dot) if dot > 0 && base.len() - dot <= 12 => base[..dot].to_string(),
        _ => base.to_string(),
    }
}

/// Quote a value for the search box when it needs it.
fn quoted(v: &str) -> String {
    if v.contains(char::is_whitespace) || v.contains('"') {
        format!("\"{}\"", v.replace('"', ""))
    } else {
        v.to_string()
    }
}

/// Count every judged recipe's phrases and settings. `model`, when not
/// empty, keeps only pictures made with that model (its facet key).
pub fn count(recipes: &[Recipe], model: &str) -> Table {
    let mut table = Table { liked: 0, disliked: 0, phrases: HashMap::new(), settings: HashMap::new() };
    for (i, r) in recipes.iter().enumerate() {
        // Pictures with no prompt (photos, screenshots) say nothing here.
        if r.target.is_none() || r.prompt.trim().is_empty() || (!model.is_empty() && !r.facet("model").contains(&model)) {
            continue;
        }
        if r.liked() {
            table.liked += 1;
        } else if r.disliked() {
            table.disliked += 1;
        }
        for phrase in prompt_phrases(&r.prompt) {
            let key = phrase.to_lowercase();
            let c = table.phrases.entry(key.clone()).or_insert_with(|| Count {
                label: key.clone(),
                kind: "phrase",
                query: format!("prompt:\"{}\"", key.replace('"', "")),
                ..Default::default()
            });
            c.add(i, r);
        }
        let mut setting = |key: String, label: String, kind: &'static str, value: &str| {
            let c = table.settings.entry(key).or_insert_with(|| Count { label, kind, ..Default::default() });
            if !c.values.iter().any(|v| v == value) {
                c.values.push(value.to_string());
            }
            c.add(i, r);
        };
        if let Some(v) = r.facet("cfg").first().and_then(|v| v.parse::<f64>().ok()) {
            let (label, bin) = cfg_bin(v);
            setting(format!("cfg/{bin}"), label.to_string(), "cfg", &format!("{v}"));
        }
        if let Some(v) = r.facet("steps").first().and_then(|v| v.parse::<f64>().ok()) {
            let (label, bin) = steps_bin(v);
            setting(format!("steps/{bin}"), label.to_string(), "steps", &format!("{v}"));
        }
        if let Some(v) = r.facet("sampler").first() {
            setting(format!("sampler/{v}"), format!("Sampler {v}"), "sampler", v);
        }
        for lw in r.facet("loraw") {
            let Some((name, weight)) = lw.rsplit_once('@') else { continue };
            let Ok(w) = weight.parse::<f64>() else { continue };
            let from = (w / 0.2).floor() * 0.2;
            let label = format!("{} at {} – {}", short_name(name), round2(from), round2(from + 0.2));
            setting(format!("loraw/{name}/{}", (w / 0.2).floor() as i64), label, "lora", lw);
        }
    }
    for c in table.settings.values_mut() {
        c.query = match c.kind {
            "cfg" => format!("cfg:{}", c.values.join("|")),
            "steps" => format!("steps:{}", c.values.join("|")),
            "sampler" => format!("sampler:={}", quoted(&c.values.join("|"))),
            _ => format!("loraweight:={}", quoted(&c.values.join("|"))),
        };
    }
    table
}

fn r3(v: f32) -> f64 {
    (v as f64 * 1000.0).round() / 1000.0
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

fn item_json(table: &Table, c: &Count, recipes: &[Recipe], toward_liked: bool) -> Value {
    let (keep, reject) = table.shares(c);
    let samples: Vec<&str> = (if toward_liked { &c.best } else { &c.worst }).iter().map(|(_, i)| recipes[*i].path.as_str()).collect();
    json!({
        "label": c.label,
        "kind": c.kind,
        "keep": (keep as f64 * 1000.0).round() / 1000.0,
        "reject": (reject as f64 * 1000.0).round() / 1000.0,
        "judged": c.judged,
        "few": c.judged < FEW,
        "query": c.query,
        "samples": samples,
    })
}

/// What the Usage page's What Works view shows: the phrases most common in
/// liked pictures, those most common in disliked ones, and the settings
/// that set them apart, with the models there are to narrow it to.
pub fn what_works(recipes: &[Recipe], model: &str) -> Value {
    let table = count(recipes, model);
    let lift = |c: &Count| {
        let (k, r) = table.shares(c);
        k - r
    };
    // A difference seen in more pictures counts for more.
    let weight = |c: &Count| lift(c) * (c.judged as f32 / FEW as f32).min(1.0).sqrt();
    let mut phrases: Vec<&Count> = table.phrases.values().filter(|c| c.judged >= LEAST_SEEN).collect();
    phrases.sort_by(|a, b| weight(b).total_cmp(&weight(a)).then(a.label.cmp(&b.label)));
    let keepers: Vec<Value> =
        phrases.iter().filter(|c| lift(c) >= LEAST_LIFT && !is_quality_phrase(&c.label)).take(10).map(|c| item_json(&table, c, recipes, true)).collect();
    let rejects: Vec<Value> = phrases.iter().rev().filter(|c| lift(c) <= -LEAST_LIFT).take(10).map(|c| item_json(&table, c, recipes, false)).collect();
    let mut settings: Vec<&Count> = table.settings.values().filter(|c| c.judged >= LEAST_SEEN && lift(c).abs() >= LEAST_LIFT).collect();
    settings.sort_by(|a, b| weight(b).abs().total_cmp(&weight(a).abs()).then(a.label.cmp(&b.label)));
    let settings: Vec<Value> = settings.iter().take(10).map(|c| item_json(&table, c, recipes, lift(c) > 0.0)).collect();
    // The models the judged pictures were made with, most used first.
    let mut models: HashMap<&str, u32> = HashMap::new();
    for r in recipes.iter().filter(|r| r.target.is_some()) {
        for m in r.facet("model").into_iter().take(1) {
            *models.entry(m).or_insert(0) += 1;
        }
    }
    let mut models: Vec<(&str, u32)> = models.into_iter().collect();
    models.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
    json!({
        "liked": table.liked,
        "disliked": table.disliked,
        "model": model,
        "models": models.iter().take(20).map(|(m, n)| json!({ "key": m, "label": short_name(m), "count": n })).collect::<Vec<_>>(),
        "groups": [
            { "kind": "keep", "items": keepers },
            { "kind": "reject", "items": rejects },
            { "kind": "settings", "items": settings },
        ],
    })
}

/// Most suggestions Prompt Doctor makes at once.
pub const MOST_SUGGESTIONS: usize = 6;
/// A phrase is suggested for adding, or for taking out as common in
/// rejects, when its shares differ by this much.
pub const SUGGEST_LIFT: f32 = 0.12;
/// Quality phrases "make no difference" when their shares are this close.
pub const NO_DIFFERENCE: f32 = 0.05;

/// The weight a phrase is written with in `prompt` (`(red fox:1.2)`), or 1.
pub fn written_weight(prompt: &str, phrase: &str) -> f64 {
    let lower = prompt.to_lowercase();
    let wanted = phrase.to_lowercase();
    let Some(at) = lower.find(&format!("({wanted}:")) else { return 1.0 };
    let rest = &lower[at + wanted.len() + 2..];
    rest.split(')').next().and_then(|n| n.trim().parse().ok()).unwrap_or(1.0)
}

/// Prompt Doctor: what to change in `prompt` (for a picture made with the
/// model whose facet key is `model`), from `check` (what
/// `ContentSearch::check_prompt` says the picture shows, or Null) and from
/// the user's judged `recipes`.
pub fn doctor(prompt: &str, check: &Value, recipes: &[Recipe], model: &str) -> Value {
    let mut out: Vec<Value> = Vec::new();
    // Phrases the picture does not show: weight them up.
    if let Some(list) = check["phrases"].as_array() {
        for p in list {
            if p["checked"].as_bool() != Some(true) || p["seen"].as_bool() == Some(true) {
                continue;
            }
            let Some(text) = p["text"].as_str() else { continue };
            let level = p["level"].as_f64().unwrap_or(0.0);
            let weight = if level < 0.5 { 1.3 } else { 1.2 };
            if written_weight(prompt, text) >= weight {
                continue;
            }
            out.push(json!({ "kind": "missed", "phrases": [text], "weight": weight, "level": level }));
        }
    }
    // What the user's own ratings say, for this model where there are enough
    // of its pictures, otherwise for all.
    let mut table = count(recipes, model);
    let mut scope = model.to_string();
    if table.liked + table.disliked < 2 * FEW {
        table = count(recipes, "");
        scope.clear();
    }
    let phrases = prompt_phrases(prompt);
    let mut quality_same: Vec<String> = Vec::new();
    for phrase in &phrases {
        let Some(c) = table.phrase(phrase) else { continue };
        if c.judged < FEW {
            continue;
        }
        let (k, r) = table.shares(c);
        if is_quality_phrase(phrase) && (k - r).abs() < NO_DIFFERENCE {
            quality_same.push(phrase.clone());
        } else if r - k >= SUGGEST_LIFT {
            out.push(json!({ "kind": "remove", "reason": "in_rejects", "phrases": [phrase], "keep": r3(k), "reject": r3(r), "judged": c.judged }));
        }
    }
    if !quality_same.is_empty() {
        out.push(json!({ "kind": "remove", "reason": "no_difference", "phrases": quality_same }));
    }
    // Phrases common in liked pictures that this prompt lacks.
    let have = prompt.to_lowercase();
    let mut adds: Vec<(&String, f32, f32, u32)> = table
        .phrases
        .iter()
        .filter(|(p, c)| c.liked >= LEAST_SEEN && !is_quality_phrase(p) && !have.contains(p.as_str()) && p.split_whitespace().count() <= 5)
        .map(|(p, c)| {
            let (k, r) = table.shares(c);
            (p, k, r, c.judged)
        })
        .filter(|(_, k, r, _)| k - r >= SUGGEST_LIFT)
        .collect();
    adds.sort_by(|a, b| (b.1 - b.2).total_cmp(&(a.1 - a.2)).then(a.0.cmp(b.0)));
    for (p, k, r, judged) in adds.into_iter().take(2) {
        out.push(json!({ "kind": "add", "reason": "in_keepers", "phrases": [p], "keep": r3(k), "reject": r3(r), "judged": judged }));
    }
    out.truncate(MOST_SUGGESTIONS);
    json!({ "suggestions": out, "model": scope, "model_label": short_name(&scope), "checked": !check.is_null() })
}

// ------------------------------------------------------------------ breed

/// What a parent picture brings to Breed.
#[derive(Debug, Clone, Default)]
pub struct Parent {
    pub phrases: Vec<String>,
    /// (name as written, weight)
    pub loras: Vec<(String, f64)>,
    pub steps: Option<f64>,
    pub cfg: Option<f64>,
}

/// What Breed is allowed to mix between the parents.
#[derive(Debug, Clone, Copy, Default)]
pub struct Mix {
    pub phrases: bool,
    pub loras: bool,
    pub settings: bool,
    /// Whether a child may be made on any parent's recipe (and so its
    /// model), or always on the first parent's.
    pub model: bool,
}

/// One new recipe.
#[derive(Debug, Clone, PartialEq)]
pub struct Child {
    /// The parent whose recipe (workflow, model, size) it is made on.
    pub base: usize,
    /// Each phrase with the parent it came from; None for a new one.
    pub phrases: Vec<(String, Option<usize>)>,
    pub loras: Vec<(String, f64)>,
    pub steps: Option<f64>,
    pub cfg: Option<f64>,
}

impl Child {
    pub fn prompt(&self) -> String {
        self.phrases.iter().map(|(p, _)| p.as_str()).collect::<Vec<_>>().join(", ")
    }

    fn signature(&self) -> String {
        let loras: Vec<String> = self.loras.iter().map(|(n, w)| format!("{n}@{w}")).collect();
        format!("{}|{}|{}|{:?}|{:?}", self.base, self.prompt().to_lowercase(), loras.join(","), self.steps, self.cfg)
    }

    pub fn to_json(&self, likely: Option<f32>) -> Value {
        json!({
            "base": self.base,
            "prompt": self.prompt(),
            "phrases": self.phrases.iter().map(|(p, from)| json!({ "text": p, "from": from })).collect::<Vec<_>>(),
            "loras": self.loras.iter().map(|(n, w)| json!({ "name": n, "weight": w })).collect::<Vec<_>>(),
            "steps": self.steps,
            "cfg": self.cfg,
            "likely": likely.map(|l| (l as f64 * 1000.0).round() / 1000.0),
            "stars": likely.map(|l| ((1.0 + 4.0 * l as f64) * 10.0).round() / 10.0),
        })
    }
}

/// A small, seeded random source: Breed is repeatable for a seed.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Rng {
        Rng(seed ^ 0x9E37_79B9_7F4A_7C15 | 1)
    }

    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    /// 0 to 1.
    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }

    fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            0
        } else {
            (self.next() % n as u64) as usize
        }
    }
}

fn step(v: f64, by: f64) -> f64 {
    ((v / by).round() * by * 100.0).round() / 100.0
}

/// Up to `count` new recipes mixed from `parents` as `mix` allows. `change`
/// (0 to 1) is how far from the parents they may go: phrases swapped for
/// `fresh` ones (phrases the user's liked pictures share), weights and
/// settings nudged. The same seed gives the same children.
pub fn breed(parents: &[Parent], mix: Mix, change: f32, fresh: &[String], count: usize, seed: u64) -> Vec<Child> {
    let mut rng = Rng::new(seed);
    let change = change.clamp(0.0, 1.0) as f64;
    let mut out: Vec<Child> = Vec::new();
    if parents.is_empty() {
        return out;
    }
    let mean_len = parents.iter().map(|p| p.phrases.len()).sum::<usize>() as f64 / parents.len() as f64;
    for _ in 0..count * 6 {
        if out.len() >= count {
            break;
        }
        let base = if mix.model { rng.below(parents.len()) } else { 0 };
        let b = &parents[base];
        let mut phrases: Vec<(String, Option<usize>)> = Vec::new();
        if mix.phrases {
            // The base's first phrase is usually what the picture is of.
            if let Some(first) = b.phrases.first() {
                phrases.push((first.clone(), Some(base)));
            }
            let mut pool: Vec<(String, usize)> = Vec::new();
            for (i, p) in parents.iter().enumerate() {
                for (j, phrase) in p.phrases.iter().enumerate() {
                    if (i == base && j == 0) || pool.iter().any(|(q, _)| q.eq_ignore_ascii_case(phrase)) {
                        continue;
                    }
                    pool.push((phrase.clone(), i));
                }
            }
            let jitter = rng.below(3) as f64 - 1.0;
            let want = (mean_len + jitter).round().max(1.0) as usize;
            while phrases.len() < want && !pool.is_empty() {
                let (p, from) = pool.swap_remove(rng.below(pool.len()));
                phrases.push((p, Some(from)));
            }
        } else {
            phrases = b.phrases.iter().map(|p| (p.clone(), Some(base))).collect();
        }
        // New phrases in place of some, and now and then one more.
        let unused = |phrases: &Vec<(String, Option<usize>)>| -> Vec<&String> {
            fresh.iter().filter(|f| !phrases.iter().any(|(p, _)| p.eq_ignore_ascii_case(f))).collect()
        };
        for k in 1..phrases.len() {
            if rng.unit() < change * 0.35 {
                let options = unused(&phrases);
                if !options.is_empty() {
                    phrases[k] = (options[rng.below(options.len())].clone(), None);
                }
            }
        }
        if rng.unit() < change * 0.5 {
            let options = unused(&phrases);
            if !options.is_empty() {
                phrases.push((options[rng.below(options.len())].clone(), None));
            }
        }
        let loras: Vec<(String, f64)> = b
            .loras
            .iter()
            .map(|(name, w)| {
                let mut w = *w;
                if mix.loras {
                    let others: Vec<f64> = parents.iter().flat_map(|p| p.loras.iter()).filter(|(n, _)| n.eq_ignore_ascii_case(name)).map(|(_, w)| *w).collect();
                    if !others.is_empty() {
                        w = others[rng.below(others.len())];
                    }
                    w += (rng.unit() * 2.0 - 1.0) * change * 0.3;
                }
                (name.clone(), step(w.clamp(-1.0, 2.0), 0.05))
            })
            .collect();
        let pick = |rng: &mut Rng, get: &dyn Fn(&Parent) -> Option<f64>| -> Option<f64> {
            if !mix.settings {
                return get(b);
            }
            let have: Vec<f64> = parents.iter().filter_map(get).collect();
            if have.is_empty() {
                None
            } else {
                Some(have[rng.below(have.len())])
            }
        };
        let mut cfg = pick(&mut rng, &|p| p.cfg);
        let mut steps = pick(&mut rng, &|p| p.steps);
        if mix.settings {
            cfg = cfg.map(|c| step((c + (rng.unit() * 2.0 - 1.0) * change * 1.5).max(1.0), 0.5));
            steps = steps.map(|s| (s + (rng.unit() * 2.0 - 1.0) * change * 10.0).round().max(1.0));
        }
        let child = Child { base, phrases, loras, steps, cfg };
        if !out.iter().any(|c| c.signature() == child.signature()) {
            out.push(child);
        }
    }
    out
}

// ---------------------------------------------------------- best of group

/// What is known about one picture of a group of near-duplicates.
#[derive(Debug, Clone, Default)]
pub struct Member {
    /// The user's own stars, if rated.
    pub rating: Option<u8>,
    pub kept: bool,
    pub rejected: bool,
    /// The taste model's guess at its stars, if it has one.
    pub likely: Option<f32>,
    /// Prompt phrases seen, of those checked.
    pub seen: Option<(u32, u32)>,
    /// How sharp it is (see [`sharpness`]); only compared within a group.
    pub sharpness: Option<f32>,
}

/// How sharp a picture is: the variance of its Laplacian, on grey levels.
/// Blur flattens edges, and with them this number.
pub fn sharpness(img: &image::DynamicImage) -> f32 {
    let grey = img.to_luma8();
    let (w, h) = grey.dimensions();
    if w < 3 || h < 3 {
        return 0.0;
    }
    let px = |x: u32, y: u32| grey.get_pixel(x, y)[0] as f32;
    let (mut sum, mut sq, mut n) = (0.0f64, 0.0f64, 0.0f64);
    for y in 1..h - 1 {
        for x in 1..w - 1 {
            let l = (px(x - 1, y) + px(x + 1, y) + px(x, y - 1) + px(x, y + 1) - 4.0 * px(x, y)) as f64;
            sum += l;
            sq += l * l;
            n += 1.0;
        }
    }
    let mean = sum / n;
    (sq / n - mean * mean) as f32
}

/// Which member of a group to keep, and why: the user's own judgement
/// first, then how liked it likely is, how much of its prompt it shows, and
/// how sharp it is.
pub fn best_of(group: &[Member]) -> (usize, Value) {
    let stars = |m: &Member| -> Option<f32> { m.rating.filter(|r| *r > 0).map(|r| r as f32).or(m.likely) };
    let adherence = |m: &Member| m.seen.filter(|(_, of)| *of > 0).map(|(s, of)| s as f32 / of as f32);
    let sharp_max = group.iter().filter_map(|m| m.sharpness).fold(0.0f32, f32::max);
    let mean = |values: Vec<f32>| if values.is_empty() { 0.5 } else { values.iter().sum::<f32>() / values.len() as f32 };
    let stars_mean = mean(group.iter().filter_map(|m| stars(m).map(|s| (s - 1.0) / 4.0)).collect());
    let adh_mean = mean(group.iter().filter_map(adherence).collect());
    let score = |m: &Member| -> f32 {
        if m.rejected {
            return f32::MIN;
        }
        let s = stars(m).map_or(stars_mean, |s| (s - 1.0) / 4.0);
        let a = adherence(m).unwrap_or(adh_mean);
        let sh = match (m.sharpness, sharp_max > 0.0) {
            (Some(v), true) => v / sharp_max,
            _ => 0.5,
        };
        // The user's own stars are known, not guessed: they count for more.
        let trust = if m.rating.unwrap_or(0) > 0 { 0.8 } else { 0.55 };
        trust * s + 0.3 * a + 0.15 * sh + if m.kept { 0.5 } else { 0.0 }
    };
    let best = (0..group.len()).max_by(|&a, &b| score(&group[a]).total_cmp(&score(&group[b])).then(b.cmp(&a))).unwrap_or(0);
    let m = &group[best];
    let sharpest = m.sharpness.is_some() && group.iter().filter(|o| o.sharpness.is_some()).count() > 1 && m.sharpness == Some(sharp_max);
    let why = json!({
        "rated": m.rating.filter(|r| *r > 0),
        "kept": m.kept,
        "likely": if m.rating.unwrap_or(0) == 0 { m.likely.map(|l| (l as f64 * 10.0).round() / 10.0) } else { None },
        "seen": m.seen.map(|(s, _)| s),
        "checked": m.seen.map(|(_, of)| of),
        "sharpest": sharpest,
    });
    (best, why)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn recipe(prompt: &str, facets: &str, rating: u8, flag: u8) -> Recipe {
        Recipe { path: format!("/p/{prompt}{rating}"), prompt: prompt.to_lowercase(), facets: facets.to_string(), rating, target: crate::taste::target(rating, flag), ..Default::default() }
    }

    fn library() -> Vec<Recipe> {
        let mut all = Vec::new();
        let m = "\nmodel\thidream.safetensors\thidream.safetensors\t\n";
        for i in 0..10 {
            // Liked: rim lighting, cfg 4, detail at 0.7.
            all.push(recipe(&format!("a fox {i}, rim lighting, masterpiece"), &format!("{m}cfg\t4\t4\t\nloraw\tdetail.safetensors@0.7\tdetail.safetensors@0.7\t\n"), 5, 0));
            // Disliked: 8k, cfg 7.
            all.push(recipe(&format!("a fox {i}, 8k, masterpiece"), &format!("{m}cfg\t7\t7\t\n"), 1, 0));
        }
        // Not judged: not counted.
        all.push(recipe("a fox, rim lighting", m, 0, 0));
        all
    }

    #[test]
    fn what_works_sets_liked_apart_from_disliked() {
        let works = what_works(&library(), "");
        assert_eq!(works["liked"], 10);
        assert_eq!(works["disliked"], 10);
        let keep = &works["groups"][0]["items"];
        assert_eq!(keep[0]["label"], "rim lighting");
        assert_eq!(keep[0]["keep"], 1.0);
        assert_eq!(keep[0]["reject"], 0.0);
        assert_eq!(keep[0]["query"], "prompt:\"rim lighting\"");
        assert_eq!(keep[0]["samples"].as_array().unwrap().len(), 3);
        let reject = &works["groups"][1]["items"];
        assert_eq!(reject[0]["label"], "8k");
        // In both alike: in neither list.
        let all: Vec<&str> = works["groups"].as_array().unwrap().iter().flat_map(|g| g["items"].as_array().unwrap()).map(|i| i["label"].as_str().unwrap()).collect();
        assert!(!all.contains(&"masterpiece"));
        let settings = &works["groups"][2]["items"];
        let labels: Vec<&str> = settings.as_array().unwrap().iter().map(|i| i["label"].as_str().unwrap()).collect();
        assert!(labels.contains(&"CFG 3.5 – 4.5") && labels.contains(&"CFG 6 – 8") && labels.contains(&"detail at 0.6 – 0.8"), "{labels:?}");
        let lora = settings.as_array().unwrap().iter().find(|i| i["kind"] == "lora").unwrap();
        assert_eq!(lora["query"], "loraweight:=detail.safetensors@0.7");
        assert_eq!(works["models"][0]["label"], "hidream");
        // Narrowed to a model nothing was made with: nothing.
        assert_eq!(what_works(&library(), "flux.safetensors")["liked"], 0);
    }

    #[test]
    fn doctor_suggests_from_the_check_and_the_ratings() {
        let check = json!({ "phrases": [
            { "text": "a fox", "checked": true, "seen": true, "level": 2.0 },
            { "text": "golden hour", "checked": true, "seen": false, "level": 0.2 },
            { "text": "masterpiece", "checked": false },
        ]});
        let found = doctor("a fox, golden hour, masterpiece, 8k", &check, &library(), "hidream.safetensors");
        let kinds: Vec<(&str, &str)> = found["suggestions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| (s["kind"].as_str().unwrap(), s["phrases"][0].as_str().unwrap()))
            .collect();
        assert_eq!(kinds, vec![("missed", "golden hour"), ("remove", "8k"), ("remove", "masterpiece"), ("add", "rim lighting")]);
        assert_eq!(found["suggestions"][0]["weight"], 1.3);
        assert_eq!(found["suggestions"][2]["reason"], "no_difference");
        assert_eq!(found["model_label"], "hidream");
        // Already weighted up: not suggested again.
        let weighted = doctor("a fox, (golden hour:1.4)", &check, &[], "");
        assert!(weighted["suggestions"].as_array().unwrap().is_empty(), "{weighted}");
        assert_eq!(written_weight("a, (Golden Hour:1.25), b", "golden hour"), 1.25);
    }

    #[test]
    fn breeding_mixes_what_it_may() {
        let parents = vec![
            Parent { phrases: vec!["a fox".into(), "snow".into(), "red scarf".into()], loras: vec![("detail".into(), 0.6)], steps: Some(30.0), cfg: Some(5.0) },
            Parent { phrases: vec!["a girl".into(), "flowers".into(), "sunset".into()], loras: vec![("detail".into(), 0.9)], steps: Some(20.0), cfg: Some(3.5) },
        ];
        let all = Mix { phrases: true, loras: true, settings: true, model: false };
        let children = breed(&parents, all, 0.4, &["rim lighting".to_string()], 6, 7);
        assert_eq!(children.len(), 6);
        assert_eq!(breed(&parents, all, 0.4, &["rim lighting".to_string()], 6, 7), children, "a seed gives the same children");
        for c in &children {
            assert_eq!(c.base, 0);
            assert_eq!(c.phrases[0], ("a fox".to_string(), Some(0)));
            for (p, from) in &c.phrases {
                match from {
                    Some(i) => assert!(parents[*i].phrases.contains(p), "{p}"),
                    None => assert_eq!(p, "rim lighting"),
                }
            }
            assert!((-1.0..=2.0).contains(&c.loras[0].1));
        }
        assert!(children.iter().any(|c| c.phrases.iter().any(|(_, f)| *f == Some(1))), "phrases come from both parents");
        // Nothing mixed, no change: the first parent's recipe again.
        let none = breed(&parents, Mix::default(), 0.0, &[], 3, 1);
        assert_eq!(none.len(), 1);
        assert_eq!(none[0].prompt(), "a fox, snow, red scarf");
        assert_eq!(none[0].loras, vec![("detail".to_string(), 0.6)]);
        assert_eq!((none[0].steps, none[0].cfg), (Some(30.0), Some(5.0)));
        // Any parent's recipe, when the model may mix.
        let any = breed(&parents, Mix { model: true, ..Mix::default() }, 0.0, &[], 6, 3);
        assert!(any.iter().any(|c| c.base == 1));
    }

    #[test]
    fn best_of_a_group() {
        let plain = Member { likely: Some(3.0), seen: Some((5, 6)), sharpness: Some(50.0), ..Default::default() };
        // The user's own five stars win over a better guess.
        let rated = Member { rating: Some(5), seen: Some((4, 6)), sharpness: Some(40.0), ..Default::default() };
        let guess = Member { likely: Some(4.4), seen: Some((6, 6)), sharpness: Some(60.0), ..Default::default() };
        let (best, why) = best_of(&[plain.clone(), rated.clone(), guess.clone()]);
        assert_eq!(best, 1);
        assert_eq!(why["rated"], 5);
        let (best, why) = best_of(&[plain.clone(), guess.clone()]);
        assert_eq!(best, 1);
        assert_eq!(why["likely"], 4.4);
        assert_eq!(why["seen"], 6);
        assert_eq!(why["sharpest"], true);
        // A rejected one never wins; a kept one does.
        let rejected = Member { rejected: true, ..guess.clone() };
        assert_eq!(best_of(&[rejected, plain.clone()]).0, 1);
        let kept = Member { kept: true, ..plain.clone() };
        assert_eq!(best_of(&[guess, kept]).0, 1);
    }

    #[test]
    fn sharper_pictures_score_higher() {
        let mut sharp = image::GrayImage::new(32, 32);
        for (x, y, p) in sharp.enumerate_pixels_mut() {
            p[0] = if (x / 4 + y / 4) % 2 == 0 { 255 } else { 0 };
        }
        let sharp = image::DynamicImage::ImageLuma8(sharp);
        let soft = sharp.blur(2.0);
        assert!(sharpness(&sharp) > 4.0 * sharpness(&soft));
    }
}
