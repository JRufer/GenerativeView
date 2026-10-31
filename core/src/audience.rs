//! Who a picture is suitable for, on the film-rating scale G, PG, PG-13, R
//! and NC-17, judged on nudity and violence.
//!
//! MOCKUP: this is the stand-in behind the audience UI, there so the
//! screens can be reviewed working. The prompt side is real but rough: a
//! phrase list read against the positive prompt (never the negative, where
//! "nsfw" usually sits). The image side is not built yet: it will score the
//! content-search vectors the app already keeps against phrases for each
//! level, calibrated on a real library, and until then reports nothing.
//! Overrides live in memory only; the real ones go in the folder's notes
//! file, so they travel between devices with stars and flags.

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

/// The reasons for one picture, for the info panel.
pub fn explain(source: Source, prompt_text: &str, image: Option<Level>, own: Option<Level>) -> Value {
    let (prompt, found) = from_prompt(prompt_text);
    let level = decide(source, image, prompt, own);
    json!({
        "level": level as u8,
        "source": match source { Source::Image => "image", Source::Prompt => "prompt", Source::Strictest => "both" },
        "prompt": prompt as u8,
        "prompt_reasons": found.iter().map(|(p, l)| json!({ "phrase": p, "level": *l as u8, "topic": topic(p) })).collect::<Vec<_>>(),
        // Not built yet: null means "no picture score".
        "image": image.map(|l| l as u8),
        "image_ready": false,
        "own": own.map(|l| l as u8),
    })
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
    json!({
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
    }

    #[test]
    fn the_strictest_reading_and_the_users_say() {
        assert_eq!(decide(Source::Strictest, Some(Level::R), Level::Pg, None), Level::R);
        assert_eq!(decide(Source::Strictest, None, Level::Pg, None), Level::Pg);
        assert_eq!(decide(Source::Image, None, Level::Pg, None), Level::Unknown);
        assert_eq!(decide(Source::Prompt, Some(Level::R), Level::Pg, Some(Level::G)), Level::G);
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
