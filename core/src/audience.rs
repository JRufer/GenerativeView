//! Who a picture is suitable for, on the film-rating scale G, PG, PG-13, R
//! and NC-17, judged on nudity and violence.
//!
//! Two readings, and the user's own say over both:
//!
//! * The prompt: [`PHRASES`] read against the positive prompt (never the
//!   negative, where "nsfw" usually sits). Instant, worked out when a file is
//!   indexed, and only as honest as the prompt.
//! * The picture: the vector content search already keeps for it, scored
//!   against [`IMAGE_PHRASES`] the way a typed description is (see
//!   `clip::Fit`). Needs the content-search model and its pass over the
//!   folder; until a picture has been looked at it has no picture reading.
//!
//! A level set by hand is kept in the folder's notes file with the stars
//! and flags (see `crate::notes`), so it travels between devices, and always
//! wins.

use serde_json::{json, Value};

/// A level on the scale. `Unknown` is "not rated yet": no prompt to read
/// and no picture score.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub enum Level {
    #[default]
    Unknown = 0,
    G = 1,
    Pg = 2,
    Pg13 = 3,
    R = 4,
    Nc17 = 5,
}

impl Level {
    pub fn from_u8(n: u8) -> Level {
        match n {
            1 => Level::G,
            2 => Level::Pg,
            3 => Level::Pg13,
            4 => Level::R,
            5 => Level::Nc17,
            _ => Level::Unknown,
        }
    }

    /// As typed in a search: `g`, `pg`, `pg13`, `r`, `nc17` (dashes and
    /// case ignored), or `none` for not rated yet.
    pub fn parse(word: &str) -> Option<Level> {
        let w: String = word.trim().to_ascii_lowercase().chars().filter(|c| *c != '-' && *c != ' ').collect();
        Some(match w.as_str() {
            "g" => Level::G,
            "pg" => Level::Pg,
            "pg13" => Level::Pg13,
            "r" => Level::R,
            "nc17" | "x" => Level::Nc17,
            "none" | "unrated" | "unknown" => Level::Unknown,
            _ => return None,
        })
    }

    pub fn word(self) -> &'static str {
        match self {
            Level::Unknown => "none",
            Level::G => "g",
            Level::Pg => "pg",
            Level::Pg13 => "pg13",
            Level::R => "r",
            Level::Nc17 => "nc17",
        }
    }
}

/// Which judgement decides a picture's level.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Image,
    Prompt,
    /// Whichever of the two is higher: a picture is only as safe as the
    /// less forgiving reading.
    Strictest,
}

impl Source {
    pub fn parse(s: Option<&str>) -> Source {
        match s {
            Some("image") => Source::Image,
            Some("prompt") => Source::Prompt,
            _ => Source::Strictest,
        }
    }
}

/// The setting that holds the [`Source`].
pub const SOURCE_SETTING: &str = "audience_source";

/// Phrases and the level each one raises a prompt to, by what it is about.
/// Matched as whole words, after LoRA tags, weights and underscores are
/// taken out. Kept clinical on purpose; a real list is tuned on a library.
const PHRASES: &[(&str, Level, &str)] = &[
    // Nudity and sexual content.
    ("nsfw", Level::R, "nudity"),
    ("nude", Level::R, "nudity"),
    ("naked", Level::R, "nudity"),
    ("nudity", Level::R, "nudity"),
    ("topless", Level::R, "nudity"),
    ("bare breasts", Level::R, "nudity"),
    ("nipples", Level::R, "nudity"),
    ("explicit", Level::Nc17, "sexual content"),
    ("porn", Level::Nc17, "sexual content"),
    ("pornographic", Level::Nc17, "sexual content"),
    ("hentai", Level::Nc17, "sexual content"),
    ("sex", Level::Nc17, "sexual content"),
    ("genitals", Level::Nc17, "sexual content"),
    ("lingerie", Level::Pg13, "suggestive"),
    ("cleavage", Level::Pg13, "suggestive"),
    ("underwear", Level::Pg13, "suggestive"),
    ("seductive", Level::Pg13, "suggestive"),
    ("sensual", Level::Pg13, "suggestive"),
    ("sexy", Level::Pg13, "suggestive"),
    ("bikini", Level::Pg, "suggestive"),
    ("swimsuit", Level::Pg, "suggestive"),
    ("kiss", Level::Pg, "romance"),
    // Violence and gore.
    ("dismembered", Level::Nc17, "graphic violence"),
    ("decapitated", Level::Nc17, "graphic violence"),
    ("disemboweled", Level::Nc17, "graphic violence"),
    ("torture", Level::Nc17, "graphic violence"),
    ("gore", Level::R, "gore"),
    ("gory", Level::R, "gore"),
    ("guro", Level::R, "gore"),
    ("mutilated", Level::R, "gore"),
    ("severed", Level::R, "gore"),
    ("corpse", Level::R, "violence"),
    ("dead body", Level::R, "violence"),
    ("blood splatter", Level::R, "gore"),
    ("bloody", Level::Pg13, "violence"),
    ("blood", Level::Pg13, "violence"),
    ("wound", Level::Pg13, "violence"),
    ("gun", Level::Pg13, "weapons"),
    ("rifle", Level::Pg13, "weapons"),
    ("pistol", Level::Pg13, "weapons"),
    ("shooting", Level::Pg13, "violence"),
    ("zombie", Level::Pg13, "horror"),
    ("horror", Level::Pg13, "horror"),
    ("war", Level::Pg13, "violence"),
    ("battle", Level::Pg, "action"),
    ("fight", Level::Pg, "action"),
    ("fighting", Level::Pg, "action"),
    ("sword", Level::Pg, "action"),
    ("monster", Level::Pg, "scary"),
    ("skull", Level::Pg, "scary"),
    ("creepy", Level::Pg, "scary"),
];

/// What a prompt asks for: its level and the phrases that set it, highest
/// first. A prompt with nothing in it is not rated; one with none of the
/// phrases is G.
pub fn from_prompt(prompt: &str) -> (Level, Vec<(String, Level)>) {
    let clean = clean(prompt);
    if clean.trim().is_empty() {
        return (Level::Unknown, Vec::new());
    }
    let words: Vec<&str> = clean.split_whitespace().collect();
    let mut found: Vec<(String, Level)> = Vec::new();
    for (phrase, level, _) in PHRASES {
        let want: Vec<&str> = phrase.split(' ').collect();
        if words.windows(want.len()).any(|w| w == want.as_slice()) && !found.iter().any(|(p, _)| p == phrase) {
            found.push((phrase.to_string(), *level));
        }
    }
    // A phrase found only inside a longer one ("blood" in "blood
    // splatter") is not a reason of its own.
    let all = found.clone();
    found.retain(|(p, _)| {
        let n = words.windows(p.split(' ').count()).filter(|w| w.join(" ") == *p).count();
        let inside = all.iter().filter(|(q, _)| q != p && q.split(' ').count() > p.split(' ').count() && format!(" {q} ").contains(&format!(" {p} "))).map(|(q, _)| words.windows(q.split(' ').count()).filter(|w| w.join(" ") == *q).count()).sum::<usize>();
        n > inside
    });
    found.sort_by(|a, b| b.1.cmp(&a.1));
    let level = found.first().map_or(Level::G, |f| f.1);
    (level, found)
}

/// What a phrase is about ("nudity", "violence"…), for the reasons shown.
pub fn topic(phrase: &str) -> &'static str {
    PHRASES.iter().find(|(p, _, _)| *p == phrase).map_or("", |(_, _, t)| t)
}

/// The prompt as words: LoRA tags out, weights and brackets out,
/// underscores and punctuation as spaces, lower case.
fn clean(prompt: &str) -> String {
    let mut out = String::with_capacity(prompt.len());
    let mut in_tag = false;
    for c in prompt.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if in_tag => {}
            c if c.is_alphanumeric() => out.extend(c.to_lowercase()),
            '\'' => {}
            _ => out.push(' '),
        }
    }
    out
}

/// The level that counts, given what each side found and the user's own
/// say, which always wins.
pub fn decide(source: Source, image: Option<Level>, prompt: Level, own: Option<Level>) -> Level {
    if let Some(own) = own {
        return own;
    }
    let image = image.unwrap_or(Level::Unknown);
    match source {
        Source::Image => image,
        Source::Prompt => prompt,
        Source::Strictest => image.max(prompt),
    }
}

/// What an `audience:` term asks for, as a test on a level. Its value is
/// one or more alternatives split by `|`: a level (`pg13`), a range
/// (`pg..r`, `..pg13`, `r..`), or `none` for not rated yet. Ranges never
/// take in the unrated: "up to PG-13" means rated PG-13 or lower.
pub struct Want(Vec<(Level, Level)>);

impl Want {
    pub fn parse(value: &str) -> Option<Want> {
        let mut out = Vec::new();
        for part in value.split('|').map(str::trim).filter(|p| !p.is_empty()) {
            if let Some((from, to)) = part.split_once("..") {
                let from = if from.trim().is_empty() { Level::G } else { Level::parse(from)? };
                let to = if to.trim().is_empty() { Level::Nc17 } else { Level::parse(to)? };
                out.push((from.max(Level::G), to));
            } else {
                let l = Level::parse(part)?;
                out.push((l, l));
            }
        }
        (!out.is_empty()).then_some(Want(out))
    }

    pub fn takes(&self, level: Level) -> bool {
        self.0.iter().any(|(from, to)| *from <= level && level <= *to)
    }
}

/// The reasons for one picture, for the info panel. `image` is the
/// picture reading with what set it, None when there is none yet;
/// `model` whether the content-search model is installed.
pub fn explain(source: Source, prompt_text: &str, image: Option<(Level, Vec<(&'static str, Level, f32)>)>, own: Option<Level>, model: bool) -> Value {
    let (prompt, found) = from_prompt(prompt_text);
    let level = decide(source, image.as_ref().map(|i| i.0), prompt, own);
    let image_topic = |p: &str| IMAGE_PHRASES.iter().find(|(q, _, _)| *q == p).map_or("", |(_, _, t)| t);
    json!({
        "level": level as u8,
        "source": match source { Source::Image => "image", Source::Prompt => "prompt", Source::Strictest => "both" },
        "prompt": prompt as u8,
        "prompt_reasons": found.iter().map(|(p, l)| json!({ "phrase": p, "level": *l as u8, "topic": topic(p) })).collect::<Vec<_>>(),
        "image": image.as_ref().map(|i| i.0 as u8),
        "image_reasons": image.as_ref().map(|i| i.1.iter().take(4).map(|(p, l, f)| json!({ "phrase": p, "level": *l as u8, "topic": image_topic(p), "fit": f })).collect::<Vec<_>>()).unwrap_or_default(),
        "model": model,
        "own": own.map(|l| l as u8),
    })
}

/// What the picture reading looks for: a description content search scores
/// each picture against, the level it stands for, and what it is about.
/// A picture's reading is the highest level any of them clearly fits; one
/// fitting none of them is G.
pub const IMAGE_PHRASES: &[(&str, Level, &str)] = &[
    ("explicit sexual activity", Level::Nc17, "sexual content"),
    ("pornography", Level::Nc17, "sexual content"),
    ("graphic dismemberment", Level::Nc17, "graphic violence"),
    ("a tortured body", Level::Nc17, "graphic violence"),
    ("a nude person", Level::R, "nudity"),
    ("a naked body", Level::R, "nudity"),
    ("bare breasts", Level::R, "nudity"),
    ("gore", Level::R, "gore"),
    ("a bloody corpse", Level::R, "gore"),
    ("graphic bloody wounds", Level::R, "gore"),
    ("a woman in lingerie", Level::Pg13, "suggestive"),
    ("a person in underwear", Level::Pg13, "suggestive"),
    ("revealing clothing", Level::Pg13, "suggestive"),
    ("blood", Level::Pg13, "violence"),
    ("a gun", Level::Pg13, "weapons"),
    ("violent combat", Level::Pg13, "violence"),
    ("a person in a swimsuit", Level::Pg, "swimwear"),
    ("a sword fight", Level::Pg, "action"),
    ("a scary monster", Level::Pg, "scary"),
    ("a skull", Level::Pg, "scary"),
];

/// How clearly (in `clip::Fit::level` units, where 1 is a match) a picture
/// has to fit a description of `level` for it to count. The higher the
/// level, the surer the reading has to be before it rates a picture there:
/// a G picture wrongly shown as R costs a look; an R one wrongly let
/// through "up to PG-13" costs more, so PG-13 is the easiest bar.
/// Tune them for a library with `examples/audience_probe`.
pub fn image_bar(level: Level) -> f32 {
    match level {
        Level::Nc17 => 1.3,
        Level::R => 1.1,
        _ => 1.0,
    }
}

/// The picture reading from how clearly a picture fits each of
/// [`IMAGE_PHRASES`] (in order), with the descriptions that set it,
/// clearest first.
pub fn from_fits(fits: &[f32]) -> (Level, Vec<(&'static str, Level, f32)>) {
    let mut found: Vec<(&'static str, Level, f32)> = IMAGE_PHRASES
        .iter()
        .zip(fits)
        .filter(|((_, level, _), fit)| **fit >= image_bar(*level))
        .map(|((phrase, level, _), fit)| (*phrase, *level, *fit))
        .collect();
    found.sort_by(|a, b| b.1.cmp(&a.1).then(b.2.total_cmp(&a.2)));
    (found.first().map_or(Level::G, |f| f.1), found)
}

/// Words added to the negative prompt to keep each topic out, for steering
/// a remix down to a level.
fn guards(topic: &str) -> &'static [&'static str] {
    match topic {
        "sexual content" => &["explicit"],
        "nudity" => &["nsfw", "nudity"],
        "suggestive" | "romance" => &["suggestive"],
        "graphic violence" => &["graphic violence"],
        "gore" => &["blood", "gore"],
        "violence" | "weapons" | "action" => &["violence"],
        "horror" | "scary" => &["horror"],
        _ => &[],
    }
}

/// Words that lean toward a level without reaching it, which aiming a
/// prompt higher may weight up: (word, family). "body" leans toward
/// suggestive content and nudity, "violence" toward blood and gore. Only
/// words already in the prompt are ever weighted; none are added.
const LEANING: &[(&str, &str)] = &[
    ("breasts", "body"),
    ("cleavage", "body"),
    ("chest", "body"),
    ("bare skin", "body"),
    ("skin", "body"),
    ("bare shoulders", "body"),
    ("curves", "body"),
    ("curvy", "body"),
    ("thighs", "body"),
    ("hips", "body"),
    ("figure", "body"),
    ("lingerie", "body"),
    ("underwear", "body"),
    ("bikini", "body"),
    ("swimsuit", "body"),
    ("sensual", "body"),
    ("seductive", "body"),
    ("blood", "violence"),
    ("bloody", "violence"),
    ("wound", "violence"),
    ("wounds", "violence"),
    ("injury", "violence"),
    ("scars", "violence"),
    ("weapon", "violence"),
    ("knife", "violence"),
    ("sword", "violence"),
    ("gun", "violence"),
    ("fight", "violence"),
    ("battle", "violence"),
    ("combat", "violence"),
    ("war", "violence"),
    ("zombie", "violence"),
];

/// How strongly to weight a leaning word for a prompt aimed `steps` levels
/// above where it reads.
fn emphasis(steps: u8) -> f64 {
    match steps {
        0 => 1.0,
        1 => 1.3,
        2 => 1.5,
        _ => 1.75,
    }
}

/// Words that say a prompt is about a child or a teenager. Such a prompt is
/// never aimed higher: no guard is lifted and nothing is weighted up.
const MINOR_WORDS: &[&str] = &[
    "child", "children", "kid", "kids", "minor", "minors", "teen", "teens", "teenage", "teenager", "teenagers", "toddler", "baby",
    "infant", "preteen", "tween", "schoolgirl", "schoolboy", "loli", "lolita", "shota", "underage", "young girl", "young boy",
    "little girl", "little boy", "middle school", "high school", "elementary school", "junior high",
];

/// Whether `prompt` mentions a child or a teenager, by word or by an age
/// under 18 ("12 years old", "15yo", "aged 16").
pub fn mentions_minor(prompt: &str) -> bool {
    let words: Vec<String> = clean(prompt).split_whitespace().map(str::to_string).collect();
    let has = |phrase: &str| {
        let want: Vec<&str> = phrase.split(' ').collect();
        words.windows(want.len()).any(|w| w.iter().map(String::as_str).eq(want.iter().copied()))
    };
    if MINOR_WORDS.iter().any(|w| has(w)) {
        return true;
    }
    let young = |n: &str| n.parse::<u32>().is_ok_and(|n| n < 18);
    words.iter().enumerate().any(|(i, w)| {
        // "15yo", "15y" or "15 years old", "15 year old", "aged 15", "age 15".
        let stem = w.trim_end_matches("yo").trim_end_matches('y');
        (stem != w && young(stem))
            || (young(w) && words.get(i + 1).is_some_and(|n| n == "years" || n == "year" || n == "yo" || n == "yrs"))
            || ((w == "aged" || w == "age") && words.get(i + 1).is_some_and(|n| young(n)))
    })
}

/// The leaning words of `prompt` that aiming it at `target` should weight
/// up, and by how much: words of a family the target opens up (both from
/// PG-13), not already rating at or above the target themselves.
fn leaning(prompt: &str, from: Level, target: Level) -> Vec<(String, f64)> {
    if target < Level::Pg13 || target <= from {
        return Vec::new();
    }
    let steps = target as u8 - from.max(Level::G) as u8;
    let words: Vec<String> = clean(prompt).split_whitespace().map(str::to_string).collect();
    let mut out: Vec<(String, f64)> = Vec::new();
    for (word, _) in LEANING {
        let want: Vec<&str> = word.split(' ').collect();
        let present = words.windows(want.len()).any(|w| w.iter().map(String::as_str).eq(want.iter().copied()));
        let own = PHRASES.iter().find(|(p, _, _)| p == word).map_or(Level::G, |(_, l, _)| *l);
        // "skin" inside "bare skin" is weighted once, as the longer.
        let inside = out.iter().any(|(o, _)| o.split(' ').count() > 1 && format!(" {o} ").contains(&format!(" {word} ")));
        if present && own < target && !inside {
            out.push((word.to_string(), emphasis(steps)));
        }
    }
    out
}

/// Every guard word steering may add, so steering up can take them out.
fn all_guards() -> Vec<&'static str> {
    let mut all: Vec<&str> = PHRASES.iter().flat_map(|(_, _, t)| guards(t).iter().copied()).collect();
    all.sort_unstable();
    all.dedup();
    all
}

/// A prompt's comma-separated parts, with brackets kept together.
fn parts(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut depth = 0i32;
    let mut cur = String::new();
    for c in text.chars() {
        match c {
            '(' | '[' | '{' | '<' => depth += 1,
            ')' | ']' | '}' | '>' => depth -= 1,
            ',' if depth <= 0 => {
                out.push(std::mem::take(&mut cur).trim().to_string());
                continue;
            }
            _ => {}
        }
        cur.push(c);
    }
    out.push(cur.trim().to_string());
    out.retain(|p| !p.is_empty());
    out
}

/// A prompt and negative prompt changed to aim at `target`. Going down,
/// every part of the prompt whose phrases rate above the target comes out
/// and guard words for what was taken out go into the negative prompt.
/// Going up, guard words above the target come out of the negative prompt;
/// nothing is ever added to the prompt.
pub fn steer(prompt: &str, negative: &str, target: Level) -> Value {
    let (now, _) = from_prompt(prompt);
    let mut removed = Vec::new();
    let mut topics: Vec<&str> = Vec::new();
    let mut kept = Vec::new();
    for part in parts(prompt) {
        let (level, found) = from_prompt(&part);
        if target != Level::Unknown && level > target {
            for (p, l) in &found {
                if *l > target && !topics.contains(&topic(p)) {
                    topics.push(topic(p));
                }
            }
            removed.push(part);
        } else {
            kept.push(part);
        }
    }
    let mut neg = parts(negative);
    let mut added = Vec::new();
    for t in &topics {
        for g in guards(t) {
            if !neg.iter().any(|n| clean(n).trim() == *g) && !added.contains(g) {
                added.push(*g);
            }
        }
    }
    // Going up: guard words for topics the target now allows come out.
    let mut lifted = Vec::new();
    if target >= Level::Pg13 {
        let allowed: Vec<&str> = PHRASES.iter().filter(|(_, l, _)| *l <= target).flat_map(|(_, _, t)| guards(t).iter().copied()).collect();
        let still: Vec<&str> = PHRASES.iter().filter(|(_, l, _)| *l > target).flat_map(|(_, _, t)| guards(t).iter().copied()).collect();
        let guard_words = all_guards();
        neg.retain(|n| {
            let w = clean(n).trim().to_string();
            let lift = guard_words.contains(&w.as_str()) && allowed.contains(&w.as_str()) && !still.contains(&w.as_str());
            if lift {
                lifted.push(n.clone());
            }
            !lift
        });
    }
    neg.extend(added.iter().map(|s| s.to_string()));
    let new_prompt = kept.join(", ");
    let minor = target > now && mentions_minor(prompt);
    if minor {
        // Not aimed higher: everything stays as it was.
        return json!({
            "from": now as u8, "to": now as u8, "prompt": prompt, "negative": negative,
            "removed": [], "added_negative": [], "lifted_negative": [], "emphasize": [], "blocked": "minor",
        });
    }
    let emphasize: Vec<Value> = leaning(&new_prompt, now, target).into_iter().map(|(w, x)| json!({ "phrase": w, "weight": x })).collect();
    json!({
        "emphasize": emphasize,
        "from": now as u8,
        "to": from_prompt(&new_prompt).0 as u8,
        "prompt": new_prompt,
        "negative": neg.join(", "),
        "removed": removed,
        "added_negative": added,
        "lifted_negative": lifted,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn steering_down_takes_parts_out_and_guards_the_negative() {
        let out = steer("a soldier, (gore:1.2), battlefield, blood splatter, sunset", "lowres", Level::Pg13);
        assert_eq!(out["prompt"], "a soldier, battlefield, sunset");
        assert_eq!(out["negative"], "lowres, blood, gore");
        assert_eq!(out["to"], Level::G as u8);
        // Already within the target: nothing changes.
        let same = steer("a knight with a sword", "", Level::Pg13);
        assert_eq!(same["prompt"], "a knight with a sword");
        assert_eq!(same["removed"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn steering_up_weights_leaning_words_never_adds() {
        let out = steer("a woman on a beach, breasts, sunset", "nsfw", Level::R);
        assert_eq!(out["prompt"], "a woman on a beach, breasts, sunset");
        assert_eq!(out["emphasize"], json!([{ "phrase": "breasts", "weight": 1.75 }]));
        // One level up is a lighter touch.
        let out = steer("a soldier, blood, rain", "", Level::R);
        assert_eq!(out["emphasize"], json!([{ "phrase": "blood", "weight": 1.3 }]));
        // Nothing leaning, nothing weighted; going down weights nothing.
        assert_eq!(steer("a red fox in snow", "", Level::Nc17)["emphasize"], json!([]));
        assert_eq!(steer("a soldier, gore, blood", "", Level::Pg13)["emphasize"], json!([]));
    }

    #[test]
    fn a_prompt_about_a_minor_is_never_aimed_higher() {
        for prompt in ["a teen at the beach, swimsuit", "a girl, 15 years old, bikini", "16yo, lingerie", "aged 12, blood", "schoolgirl, cleavage"] {
            let out = steer(prompt, "nsfw, nudity", Level::Nc17);
            assert_eq!(out["blocked"], "minor", "{prompt}");
            assert_eq!(out["negative"], "nsfw, nudity");
            assert_eq!(out["emphasize"], json!([]));
        }
        // Adults and plain numbers are not caught.
        assert!(!mentions_minor("a woman, 25 years old, 1girl, 8k, 30yo"));
        assert!(!mentions_minor("a kidney bean salad"));
        // Aiming lower still works.
        assert_eq!(steer("a teen, gore", "", Level::Pg)["prompt"], "a teen");
    }

    #[test]
    fn steering_up_only_lifts_guards() {
        let out = steer("a soldier, battlefield", "lowres, blood, gore, nsfw", Level::R);
        assert_eq!(out["prompt"], "a soldier, battlefield");
        // Gore and nudity are allowed at R; the NC-17 guard stays.
        assert_eq!(out["negative"], "lowres");
        let kept = steer("a soldier", "explicit, gore", Level::R);
        assert_eq!(kept["negative"], "explicit");
    }

    #[test]
    fn a_prompt_is_rated_by_its_strongest_phrase() {
        assert_eq!(from_prompt("a red fox in snow, masterpiece").0, Level::G);
        assert_eq!(from_prompt("a knight with a sword").0, Level::Pg);
        assert_eq!(from_prompt("a soldier, (blood:1.2), battlefield").0, Level::Pg13);
        assert_eq!(from_prompt("<lora:x:0.8> nude_portrait, studio").0, Level::R);
        assert_eq!(from_prompt("").0, Level::Unknown);
        // Whole words only.
        assert_eq!(from_prompt("a gunmetal sculpture, sexton beetle").0, Level::G);
        let (_, why) = from_prompt("a zombie, gore, dead body");
        assert_eq!(why[0].1, Level::R);
        // "blood" inside "blood splatter" is not counted twice; on its own it is.
        let names = |p: &str| from_prompt(p).1.into_iter().map(|(p, _)| p).collect::<Vec<_>>();
        assert_eq!(names("blood splatter, dusk"), ["blood splatter"]);
        assert_eq!(names("blood splatter, blood"), ["blood splatter", "blood"]);
    }

    #[test]
    fn the_strictest_reading_and_the_users_say() {
        assert_eq!(decide(Source::Strictest, Some(Level::R), Level::Pg, None), Level::R);
        assert_eq!(decide(Source::Strictest, None, Level::Pg, None), Level::Pg);
        assert_eq!(decide(Source::Image, None, Level::Pg, None), Level::Unknown);
        assert_eq!(decide(Source::Prompt, Some(Level::R), Level::Pg, Some(Level::G)), Level::G);
    }

    #[test]
    fn a_picture_is_rated_by_the_highest_level_it_clearly_fits() {
        let mut fits = vec![0.0; IMAGE_PHRASES.len()];
        assert_eq!(from_fits(&fits).0, Level::G);
        let at = |p: &str| IMAGE_PHRASES.iter().position(|(q, _, _)| *q == p).unwrap();
        fits[at("a sword fight")] = 1.4;
        fits[at("blood")] = 1.05;
        assert_eq!(from_fits(&fits).0, Level::Pg13);
        // R needs a surer fit than PG-13.
        fits[at("gore")] = 1.05;
        assert_eq!(from_fits(&fits).0, Level::Pg13);
        fits[at("gore")] = 1.2;
        let (level, why) = from_fits(&fits);
        assert_eq!((level, why[0].0), (Level::R, "gore"));
    }

    #[test]
    fn audience_terms() {
        let up_to = Want::parse("..pg13").unwrap();
        assert!(up_to.takes(Level::G) && up_to.takes(Level::Pg13));
        assert!(!up_to.takes(Level::R) && !up_to.takes(Level::Unknown));
        let with_unrated = Want::parse("..pg|none").unwrap();
        assert!(with_unrated.takes(Level::Unknown));
        assert!(Want::parse("R..").unwrap().takes(Level::Nc17));
        assert!(Want::parse("pg-13").unwrap().takes(Level::Pg13));
        assert!(Want::parse("teen").is_none());
    }
}
