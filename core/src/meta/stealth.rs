//! Metadata hidden in the pixels: the lowest bit of every alpha value.
//!
//! NovelAI writes a copy of its settings this way into every picture, so it
//! survives sites and apps that strip the text chunks; A1111's
//! stealth-pnginfo extension uses the same layout. The bits run down each
//! column, then across (the first column's top eight pixels make the first
//! byte), most significant bit first:
//!
//! ```text
//! magic (15 bytes) | payload length in bits (u32, big-endian) | payload
//! ```
//!
//! `stealth_pngcomp` means a gzipped payload, `stealth_pnginfo` a plain one.
//! NovelAI's payload is a JSON object of its text chunks (`Description`,
//! `Software`, `Source`, `Comment`...); A1111's is its `parameters` text.
//! Only lossless files keep it: a lossy re-save scrambles the low bits.

use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

const MAGIC_COMP: &[u8; 15] = b"stealth_pngcomp";
const MAGIC_PLAIN: &[u8; 15] = b"stealth_pnginfo";
const MAGIC_BITS: usize = 15 * 8;
const HEADER_BYTES: usize = 15 + 4;

/// Largest payload worth reading: a few KB is normal.
const MAX_PAYLOAD: usize = 8 * 1024 * 1024;

/// The text hidden in a PNG's alpha channel, as (key, text) pairs; empty
/// when there is none. Only 8-bit RGBA or grey + alpha pictures can carry
/// it. Pictures tall enough to hold the magic in their first column are
/// given up on after that many rows, so a plain transparent PNG costs a
/// fraction of a decode.
pub fn from_png(path: &Path) -> Vec<(String, String)> {
    png_bits(path).map(|bits| unpack(&bits)).unwrap_or_default()
}

fn png_bits(path: &Path) -> Option<Bits> {
    let file = File::open(path).ok()?;
    let mut decoder = png::Decoder::new(BufReader::new(file));
    decoder.set_ignore_text_chunk(true);
    decoder.set_transformations(png::Transformations::IDENTITY);
    let mut reader = decoder.read_info().ok()?;
    let info = reader.info();
    if info.bit_depth != png::BitDepth::Eight || info.interlaced {
        return None;
    }
    let (channels, alpha) = match info.color_type {
        png::ColorType::Rgba => (4, 3),
        png::ColorType::GrayscaleAlpha => (2, 1),
        _ => return None,
    };
    let (w, h) = (info.width as usize, info.height as usize);
    let mut bits = Bits::new(w, h)?;
    for y in 0..h {
        let row = reader.next_row().ok()??;
        let data = row.data();
        if data.len() < w * channels {
            return None;
        }
        for x in 0..w {
            bits.set(x, y, data[x * channels + alpha]);
        }
        // The magic is all in the first column by now: stop early when it
        // is not there.
        if y + 1 == MAGIC_BITS && !bits.magic_ok() {
            return None;
        }
    }
    Some(bits)
}

/// The same for any picture already decoded (a WebP, say).
pub fn from_rgba(img: &image::RgbaImage) -> Vec<(String, String)> {
    let (w, h) = (img.width() as usize, img.height() as usize);
    let Some(mut bits) = Bits::new(w, h) else { return Vec::new() };
    for (x, y, p) in img.enumerate_pixels() {
        bits.set(x as usize, y as usize, p.0[3]);
    }
    unpack(&bits)
}

/// A WebP's hidden text. WebP gives no rows one at a time, so this decodes
/// the whole picture: only called for a WebP with alpha and no other
/// metadata.
pub fn from_webp(path: &Path) -> Vec<(String, String)> {
    let Ok(reader) = image::ImageReader::open(path).and_then(|r| r.with_guessed_format()) else { return Vec::new() };
    let Ok(img) = reader.decode() else { return Vec::new() };
    if !img.color().has_alpha() {
        return Vec::new();
    }
    from_rgba(&img.to_rgba8())
}

/// The alpha low bits in reading order: column-major.
struct Bits {
    h: usize,
    bits: Vec<u8>,
}

impl Bits {
    fn new(w: usize, h: usize) -> Option<Bits> {
        let n = w.checked_mul(h)?;
        if !(HEADER_BYTES * 8..=256 * 1024 * 1024).contains(&n) {
            return None;
        }
        Some(Bits { h, bits: vec![0; n] })
    }

    fn set(&mut self, x: usize, y: usize, alpha: u8) {
        self.bits[x * self.h + y] = alpha & 1;
    }

    fn byte(&self, i: usize) -> Option<u8> {
        let chunk = self.bits.get(i * 8..i * 8 + 8)?;
        Some(chunk.iter().fold(0u8, |b, &bit| (b << 1) | bit))
    }

    fn bytes(&self, from: usize, n: usize) -> Option<Vec<u8>> {
        (from..from + n).map(|i| self.byte(i)).collect()
    }

    /// Whether the first fifteen bytes are one of the magics. Only the
    /// first [`MAGIC_BITS`] bits need to be filled in.
    fn magic_ok(&self) -> bool {
        matches!(self.bytes(0, 15), Some(m) if m == MAGIC_COMP || m == MAGIC_PLAIN)
    }
}

fn unpack(bits: &Bits) -> Vec<(String, String)> {
    let Some(magic) = bits.bytes(0, 15) else { return Vec::new() };
    let compressed = match magic.as_slice() {
        m if m == MAGIC_COMP => true,
        m if m == MAGIC_PLAIN => false,
        _ => return Vec::new(),
    };
    let Some(len) = bits.bytes(15, 4) else { return Vec::new() };
    let len = u32::from_be_bytes([len[0], len[1], len[2], len[3]]) as usize / 8;
    if len == 0 || len > MAX_PAYLOAD {
        return Vec::new();
    }
    let Some(payload) = bits.bytes(HEADER_BYTES, len) else { return Vec::new() };
    let text = if compressed {
        let mut out = Vec::new();
        let gz = flate2::read::GzDecoder::new(payload.as_slice());
        if gz.take(MAX_PAYLOAD as u64 * 4).read_to_end(&mut out).is_err() {
            return Vec::new();
        }
        out
    } else {
        payload
    };
    let Ok(text) = String::from_utf8(text) else { return Vec::new() };
    texts_of(&text)
}

/// NovelAI's JSON object becomes its text chunks again, as the file would
/// have had them; anything else is A1111's `parameters` text.
fn texts_of(text: &str) -> Vec<(String, String)> {
    if let Ok(serde_json::Value::Object(map)) = serde_json::from_str::<serde_json::Value>(text) {
        return map
            .into_iter()
            .filter_map(|(k, v)| match v {
                serde_json::Value::Null => None,
                serde_json::Value::String(s) => Some((k, s)),
                v => Some((k, v.to_string())),
            })
            .collect();
    }
    if text.trim().is_empty() {
        return Vec::new();
    }
    vec![("parameters".to_string(), text.to_string())]
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::io::Write;

    /// `payload` hidden in a w×h RGBA picture the way NovelAI hides it.
    pub(crate) fn hide(w: u32, h: u32, payload: &[u8], compress: bool) -> image::RgbaImage {
        let body = if compress {
            let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
            gz.write_all(payload).unwrap();
            gz.finish().unwrap()
        } else {
            payload.to_vec()
        };
        let mut bytes = if compress { MAGIC_COMP.to_vec() } else { MAGIC_PLAIN.to_vec() };
        bytes.extend(((body.len() * 8) as u32).to_be_bytes());
        bytes.extend(body);
        let mut img = image::RgbaImage::from_fn(w, h, |x, y| image::Rgba([(x % 256) as u8, (y % 256) as u8, 90, 255]));
        let mut i = 0usize;
        'out: for x in 0..w {
            for y in 0..h {
                let byte = i / 8;
                if byte >= bytes.len() {
                    break 'out;
                }
                let bit = (bytes[byte] >> (7 - i % 8)) & 1;
                img.get_pixel_mut(x, y).0[3] = 0xfe | bit;
                i += 1;
            }
        }
        img
    }

    #[test]
    fn novelai_json_comes_back_as_text_chunks() {
        let json = r#"{"Description":"a fox","Software":"NovelAI","Source":"NovelAI Diffusion V5 DB276663","Generation time":"2.0","Comment":"{\"prompt\": \"a fox\", \"seed\": 1}"}"#;
        let img = hide(64, 300, json.as_bytes(), true);
        let texts = from_rgba(&img);
        assert_eq!(texts.len(), 5);
        assert_eq!(texts[0], ("Description".to_string(), "a fox".to_string()));
        assert!(texts.iter().any(|(k, v)| k == "Comment" && v.contains("\"seed\": 1")));
    }

    #[test]
    fn a1111_plain_text_is_parameters() {
        let img = hide(40, 100, b"a dog\nSteps: 20, Seed: 5", false);
        assert_eq!(from_rgba(&img), [("parameters".to_string(), "a dog\nSteps: 20, Seed: 5".to_string())]);
    }

    #[test]
    fn ordinary_transparency_has_nothing() {
        let img = image::RgbaImage::from_fn(64, 64, |x, _| image::Rgba([0, 0, 0, (x * 4) as u8]));
        assert!(from_rgba(&img).is_empty());
    }

    #[test]
    fn png_reader_matches_and_stops_early() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.png");
        hide(48, 400, br#"{"Software":"NovelAI","Comment":"{}"}"#, true).save(&path).unwrap();
        assert_eq!(from_png(&path), [("Software".to_string(), "NovelAI".to_string()), ("Comment".to_string(), "{}".to_string())]);

        // Short pictures keep the magic across columns: still found.
        let short = dir.path().join("b.png");
        hide(400, 40, br#"{"Software":"NovelAI"}"#, true).save(&short).unwrap();
        assert_eq!(from_png(&short), [("Software".to_string(), "NovelAI".to_string())]);

        let plain = dir.path().join("c.png");
        image::RgbaImage::from_pixel(48, 400, image::Rgba([1, 2, 3, 200])).save(&plain).unwrap();
        assert!(from_png(&plain).is_empty());
        // No alpha at all: not even opened past the header.
        let rgb = dir.path().join("d.png");
        image::RgbImage::from_pixel(48, 48, image::Rgb([1, 2, 3])).save(&rgb).unwrap();
        assert!(from_png(&rgb).is_empty());
    }
}
