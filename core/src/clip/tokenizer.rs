//! CLIP's text tokenizer: lower-cased byte-pair encoding with `</w>` word
//! ends, read from the `tokenizer.json` that ships with a model.
//!
//! It mirrors what the Hugging Face tokenizer does with that file, step for
//! step, so the ids are the ones the model was trained on: normalise (NFC,
//! single spaces, lower case), split with CLIP's pattern, map each piece's
//! bytes to the vocabulary's alphabet, then merge pairs in learned order.

use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;
use unicode_normalization::UnicodeNormalization;
use unicode_properties::{GeneralCategoryGroup, UnicodeGeneralCategory};

/// Sequences are this long at most, start and end markers included.
pub const MAX_TOKENS: usize = 77;

pub struct Tokenizer {
    vocab: HashMap<String, u32>,
    /// Pairs that merge, and how early: lower merges first.
    ranks: HashMap<(String, String), u32>,
    /// The vocabulary's character for each byte value.
    alphabet: [char; 256],
    start: u32,
    end: u32,
}

/// GPT-2's byte alphabet: printable Latin-1 bytes stand for themselves, the
/// rest are moved up past U+0100 so every byte has a visible character.
fn byte_alphabet() -> [char; 256] {
    let printable = |b: u32| (33..=126).contains(&b) || (161..=172).contains(&b) || (174..=255).contains(&b);
    let mut out = ['\0'; 256];
    let mut moved = 0;
    for b in 0..256u32 {
        out[b as usize] = if printable(b) {
            char::from_u32(b).unwrap_or('\0')
        } else {
            moved += 1;
            char::from_u32(256 + moved - 1).unwrap_or('\0')
        };
    }
    out
}

fn is_letter(c: char) -> bool {
    c.general_category_group() == GeneralCategoryGroup::Letter
}

fn is_number(c: char) -> bool {
    c.general_category_group() == GeneralCategoryGroup::Number
}

/// CLIP's splitting pattern, by hand:
/// `'s|'t|'re|'ve|'m|'ll|'d|\p{L}+|\p{N}|[^\s\p{L}\p{N}]+`
fn split(text: &str) -> Vec<&str> {
    const CONTRACTIONS: [&str; 7] = ["'s", "'t", "'re", "'ve", "'m", "'ll", "'d"];
    let mut pieces = Vec::new();
    let mut at = 0;
    while at < text.len() {
        let rest = &text[at..];
        let c = rest.chars().next().unwrap_or(' ');
        if c.is_whitespace() {
            at += c.len_utf8();
            continue;
        }
        let len = if let Some(found) = CONTRACTIONS.iter().find(|s| rest.starts_with(**s)) {
            found.len()
        } else if is_letter(c) {
            rest.find(|c: char| !is_letter(c)).unwrap_or(rest.len())
        } else if is_number(c) {
            c.len_utf8()
        } else {
            rest.find(|c: char| c.is_whitespace() || is_letter(c) || is_number(c)).unwrap_or(rest.len())
        };
        pieces.push(&rest[..len]);
        at += len;
    }
    pieces
}

impl Tokenizer {
    pub fn load(path: &Path) -> Result<Tokenizer, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        Tokenizer::from_json(&text)
    }

    pub fn from_json(text: &str) -> Result<Tokenizer, String> {
        let json: Value = serde_json::from_str(text).map_err(|e| format!("tokenizer.json: {e}"))?;
        let model = &json["model"];
        let vocab: HashMap<String, u32> = model["vocab"]
            .as_object()
            .ok_or("tokenizer.json: no vocabulary")?
            .iter()
            .filter_map(|(token, id)| Some((token.clone(), id.as_u64()? as u32)))
            .collect();
        let mut ranks = HashMap::new();
        for (rank, merge) in model["merges"].as_array().ok_or("tokenizer.json: no merges")?.iter().enumerate() {
            // Written as "a b" by older versions of the library, ["a", "b"] by newer ones.
            let pair = match merge {
                Value::String(s) => s.split_once(' ').map(|(a, b)| (a.to_string(), b.to_string())),
                Value::Array(a) if a.len() == 2 => a[0].as_str().zip(a[1].as_str()).map(|(a, b)| (a.to_string(), b.to_string())),
                _ => None,
            };
            ranks.insert(pair.ok_or("tokenizer.json: unreadable merge")?, rank as u32);
        }
        let id = |token: &str| vocab.get(token).copied().ok_or_else(|| format!("tokenizer.json: no {token} token"));
        let (start, end) = (id("<|startoftext|>")?, id("<|endoftext|>")?);
        Ok(Tokenizer { vocab, ranks, alphabet: byte_alphabet(), start, end })
    }

    /// The id that ends every sequence (and is the largest id there is).
    pub fn end_token(&self) -> u32 {
        self.end
    }

    /// One piece of text as vocabulary entries.
    fn bpe(&self, piece: &str, out: &mut Vec<u32>) {
        let mut word: Vec<String> = piece.bytes().map(|b| self.alphabet[b as usize].to_string()).collect();
        match word.last_mut() {
            Some(last) => last.push_str("</w>"),
            None => return,
        }
        loop {
            // The pair learned earliest merges first, everywhere it occurs.
            let best = word
                .windows(2)
                .filter_map(|pair| self.ranks.get(&(pair[0].clone(), pair[1].clone())).map(|rank| (*rank, pair[0].clone(), pair[1].clone())))
                .min_by_key(|(rank, _, _)| *rank);
            let Some((_, first, second)) = best else { break };
            let mut merged = Vec::with_capacity(word.len());
            let mut i = 0;
            while i < word.len() {
                if i + 1 < word.len() && word[i] == first && word[i + 1] == second {
                    merged.push(format!("{first}{second}"));
                    i += 2;
                } else {
                    merged.push(std::mem::take(&mut word[i]));
                    i += 1;
                }
            }
            word = merged;
            if word.len() == 1 {
                break;
            }
        }
        // Nothing should be missing (every byte is in the vocabulary), but
        // the end marker is the tokenizer's stand-in for the unknown.
        out.extend(word.iter().map(|symbol| self.vocab.get(symbol).copied().unwrap_or(self.end)));
    }

    /// `text` as token ids: start marker, the text, end marker. Text that
    /// runs past [`MAX_TOKENS`] is cut short.
    pub fn encode(&self, text: &str) -> Vec<u32> {
        let composed: String = text.nfc().collect();
        let spaced = composed.split_whitespace().collect::<Vec<_>>().join(" ");
        let normal = spaced.to_lowercase();
        let mut ids = vec![self.start];
        for piece in split(&normal) {
            self.bpe(piece, &mut ids);
            if ids.len() >= MAX_TOKENS {
                break;
            }
        }
        ids.truncate(MAX_TOKENS - 1);
        ids.push(self.end);
        ids
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splitting() {
        assert_eq!(split("it's the cat's 2nd, they're 10!"), ["it", "'s", "the", "cat", "'s", "2", "nd", ",", "they", "'re", "1", "0", "!"]);
        assert_eq!(split("a...b ''s <x:0.8>"), ["a", "...", "b", "''", "s", "<", "x", ":", "0", ".", "8", ">"]);
        assert_eq!(split("  naïve 東京 "), ["naïve", "東京"]);
        assert_eq!(split(""), Vec::<&str>::new());
    }

    #[test]
    fn alphabet() {
        let a = byte_alphabet();
        assert_eq!((a[b'a' as usize], a[b'!' as usize], a[0xff]), ('a', '!', 'ÿ'));
        // Unprintable bytes are moved up, in order: 0..=32, 127..=160, 173.
        assert_eq!((a[0], a[b' ' as usize], a[127], a[173]), ('Ā', 'Ġ', 'ġ', 'Ń'));
        let mut seen: Vec<char> = a.to_vec();
        seen.sort_unstable();
        seen.dedup();
        assert_eq!(seen.len(), 256);
    }
}
