//! Saving an upscaled picture beside its original.
//!
//! The upscale itself happens elsewhere (a ComfyUI or Forge server); what
//! comes back is a picture in whatever format that server writes, usually
//! with metadata of its own. Here it is written out in the original's format
//! with either no metadata at all, or an exact copy of the original's: the
//! original's metadata chunks or segments are carried over byte for byte,
//! so every reader (this app included) finds the same prompt, seed and
//! workflow in the larger picture that it found in the original.

use image::{DynamicImage, ImageEncoder};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Metadata {
    /// Nothing but the picture.
    Strip,
    /// The original's metadata, byte for byte.
    Copy,
}

impl Metadata {
    pub fn parse(text: &str) -> Option<Metadata> {
        match text {
            "strip" | "none" => Some(Metadata::Strip),
            "copy" | "keep" => Some(Metadata::Copy),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Format {
    Png,
    Jpeg,
    WebP,
}

fn sniff(bytes: &[u8]) -> Option<Format> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some(Format::Png)
    } else if bytes.starts_with(&[0xFF, 0xD8]) {
        Some(Format::Jpeg)
    } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some(Format::WebP)
    } else {
        None
    }
}

/// Save `picture` (an upscaled version of the picture at `source`) beside
/// `source`, in `source`'s format, with its metadata as `metadata` says.
/// Returns where it went: the original's name with `_up2x` (or whatever the
/// factor is) added, never over an existing file.
pub fn save(source: &Path, picture: &DynamicImage, metadata: Metadata) -> Result<PathBuf, String> {
    let original = std::fs::read(source).map_err(|e| format!("cannot read {}: {e}", source.display()))?;
    let format = sniff(&original).ok_or("the original is not a PNG, JPEG or WebP picture")?;
    let (ow, _) = image::ImageReader::new(std::io::Cursor::new(&original))
        .with_guessed_format()
        .ok()
        .and_then(|r| r.into_dimensions().ok())
        .unwrap_or((0, 0));
    let bytes = encode(format, picture, &original, metadata)?;
    let dest = destination(source, ow, picture.width(), format);
    std::fs::write(&dest, bytes).map_err(|e| format!("cannot write {}: {e}", dest.display()))?;
    Ok(dest)
}

/// [`save`], from an encoded picture.
pub fn save_bytes(source: &Path, result: &[u8], metadata: Metadata) -> Result<PathBuf, String> {
    let picture = image::load_from_memory(result).map_err(|e| format!("cannot read the upscaled picture: {e}"))?;
    save(source, &picture, metadata)
}

/// `name_up2x.png` beside `source`, or `name_up2x-2.png` and so on if that is
/// taken.
fn destination(source: &Path, from_width: u32, to_width: u32, format: Format) -> PathBuf {
    let stem = source.file_stem().and_then(|s| s.to_str()).unwrap_or("upscaled");
    let ext = source.extension().and_then(|s| s.to_str()).unwrap_or(match format {
        Format::Png => "png",
        Format::Jpeg => "jpg",
        Format::WebP => "webp",
    });
    let factor = if from_width > 0 { to_width as f64 / from_width as f64 } else { 0.0 };
    let tag = if factor <= 0.0 {
        "up".to_string()
    } else if (factor - factor.round()).abs() < 0.05 {
        format!("up{}x", factor.round() as u32)
    } else {
        // 1.5, 1.25, 3.4: as few places as the factor needs.
        let text = format!("{factor:.2}");
        format!("up{}x", text.trim_end_matches('0').trim_end_matches('.'))
    };
    let dir = source.parent().unwrap_or(Path::new("."));
    let mut n = 1;
    loop {
        let name = if n == 1 { format!("{stem}_{tag}.{ext}") } else { format!("{stem}_{tag}-{n}.{ext}") };
        let path = dir.join(name);
        if !path.exists() {
            return path;
        }
        n += 1;
    }
}

fn encode(format: Format, picture: &DynamicImage, original: &[u8], metadata: Metadata) -> Result<Vec<u8>, String> {
    match format {
        Format::Png => {
            let mut out = Vec::new();
            let rgba = has_alpha(picture);
            let encoder = image::codecs::png::PngEncoder::new(&mut out);
            if rgba {
                let p = picture.to_rgba8();
                encoder.write_image(&p, p.width(), p.height(), image::ExtendedColorType::Rgba8).map_err(|e| e.to_string())?;
            } else {
                let p = picture.to_rgb8();
                encoder.write_image(&p, p.width(), p.height(), image::ExtendedColorType::Rgb8).map_err(|e| e.to_string())?;
            }
            Ok(match metadata {
                Metadata::Strip => out,
                Metadata::Copy => png_with_chunks(&out, &png_meta_chunks(original)),
            })
        }
        Format::Jpeg => {
            let rgb = picture.to_rgb8();
            let mut out = Vec::new();
            let encoder = jpeg_encoder::Encoder::new(&mut out, 95);
            encoder
                .encode(&rgb, rgb.width() as u16, rgb.height() as u16, jpeg_encoder::ColorType::Rgb)
                .map_err(|e| format!("cannot write the JPEG: {e}"))?;
            Ok(match metadata {
                Metadata::Strip => out,
                Metadata::Copy => jpeg_with_segments(&out, &jpeg_meta_segments(original)),
            })
        }
        Format::WebP => {
            let rgba = picture.to_rgba8();
            let mut out = Vec::new();
            image::codecs::webp::WebPEncoder::new_lossless(&mut out)
                .write_image(&rgba, rgba.width(), rgba.height(), image::ExtendedColorType::Rgba8)
                .map_err(|e| format!("cannot write the WebP: {e}"))?;
            Ok(match metadata {
                Metadata::Strip => out,
                Metadata::Copy => webp_with_chunks(&out, &webp_meta_chunks(original), rgba.width(), rgba.height()),
            })
        }
    }
}

fn has_alpha(picture: &DynamicImage) -> bool {
    picture.color().has_alpha() && picture.to_rgba8().pixels().any(|p| p.0[3] != 255)
}

// ---------------------------------------------------------------- PNG

/// Each chunk of a PNG: (type, whole chunk bytes including length and CRC).
fn png_chunks(bytes: &[u8]) -> Vec<([u8; 4], &[u8])> {
    let mut out = Vec::new();
    let mut at = 8;
    while at + 12 <= bytes.len() {
        let len = u32::from_be_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]]) as usize;
        let end = at + 12 + len;
        if end > bytes.len() {
            break;
        }
        let kind = [bytes[at + 4], bytes[at + 5], bytes[at + 6], bytes[at + 7]];
        out.push((kind, &bytes[at..end]));
        at = end;
        if &kind == b"IEND" {
            break;
        }
    }
    out
}

/// The chunks of a PNG that carry metadata rather than the picture.
fn png_meta_chunks(bytes: &[u8]) -> Vec<Vec<u8>> {
    if sniff(bytes) != Some(Format::Png) {
        return Vec::new();
    }
    png_chunks(bytes).into_iter().filter(|(kind, _)| matches!(kind, b"tEXt" | b"zTXt" | b"iTXt" | b"eXIf")).map(|(_, c)| c.to_vec()).collect()
}

/// `png` with its own metadata chunks dropped and `chunks` put in right
/// after the header, where readers look first.
fn png_with_chunks(png: &[u8], chunks: &[Vec<u8>]) -> Vec<u8> {
    let mut out = png[..8].to_vec();
    for (kind, chunk) in png_chunks(png) {
        if matches!(&kind, b"tEXt" | b"zTXt" | b"iTXt" | b"eXIf") {
            continue;
        }
        out.extend_from_slice(chunk);
        if &kind == b"IHDR" {
            for c in chunks {
                out.extend_from_slice(c);
            }
        }
    }
    out
}

// ---------------------------------------------------------------- JPEG

/// The segments of a JPEG before its image data: (marker, whole segment).
fn jpeg_segments(bytes: &[u8]) -> Vec<(u8, &[u8])> {
    let mut out = Vec::new();
    let mut at = 2;
    while at + 4 <= bytes.len() && bytes[at] == 0xFF {
        let marker = bytes[at + 1];
        if marker == 0xDA || marker == 0xD9 {
            break;
        }
        let len = u16::from_be_bytes([bytes[at + 2], bytes[at + 3]]) as usize;
        let end = at + 2 + len;
        if end > bytes.len() {
            break;
        }
        out.push((marker, &bytes[at..end]));
        at = end;
    }
    out
}

/// The metadata segments of a JPEG: EXIF and XMP (APP1), anything in the
/// other application segments except the JFIF header, and comments.
fn jpeg_meta_segments(bytes: &[u8]) -> Vec<Vec<u8>> {
    if sniff(bytes) != Some(Format::Jpeg) {
        return Vec::new();
    }
    jpeg_segments(bytes)
        .into_iter()
        .filter(|(marker, seg)| (*marker == 0xFE || (0xE1..=0xEF).contains(marker)) && !(*marker == 0xEE && seg.len() > 4 && seg[4..].starts_with(b"Adobe")))
        .map(|(_, s)| s.to_vec())
        .collect()
}

fn jpeg_with_segments(jpeg: &[u8], segments: &[Vec<u8>]) -> Vec<u8> {
    let own = jpeg_segments(jpeg);
    // After the encoder's own JFIF header, if it wrote one.
    let mut cut = 2;
    if let Some((0xE0, seg)) = own.first() {
        cut += seg.len();
    }
    let mut out = jpeg[..cut].to_vec();
    for s in segments {
        out.extend_from_slice(s);
    }
    out.extend_from_slice(&jpeg[cut..]);
    out
}

// ---------------------------------------------------------------- WebP

/// Each chunk of a WebP file: (fourcc, whole chunk including padding).
fn webp_chunks(bytes: &[u8]) -> Vec<([u8; 4], &[u8])> {
    let mut out = Vec::new();
    let mut at = 12;
    while at + 8 <= bytes.len() {
        let kind = [bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]];
        let len = u32::from_le_bytes([bytes[at + 4], bytes[at + 5], bytes[at + 6], bytes[at + 7]]) as usize;
        let end = (at + 8 + len + (len & 1)).min(bytes.len());
        out.push((kind, &bytes[at..end]));
        at = end;
    }
    out
}

fn webp_meta_chunks(bytes: &[u8]) -> Vec<Vec<u8>> {
    if sniff(bytes) != Some(Format::WebP) {
        return Vec::new();
    }
    webp_chunks(bytes).into_iter().filter(|(kind, _)| matches!(kind, b"EXIF" | b"XMP ")).map(|(_, c)| c.to_vec()).collect()
}

/// A WebP in the extended layout: the picture from `webp` plus `chunks`
/// (EXIF and XMP), flagged in the header as the format requires.
fn webp_with_chunks(webp: &[u8], chunks: &[Vec<u8>], width: u32, height: u32) -> Vec<u8> {
    if chunks.is_empty() {
        return webp.to_vec();
    }
    let own = webp_chunks(webp);
    let mut flags = 0u8;
    let mut picture: Vec<u8> = Vec::new();
    for (kind, chunk) in &own {
        match kind {
            b"VP8X" => {
                if chunk.len() > 8 {
                    flags |= chunk[8] & !0x0C;
                }
            }
            b"EXIF" | b"XMP " => {}
            _ => picture.extend_from_slice(chunk),
        }
    }
    for c in chunks {
        match &c[..4] {
            b"EXIF" => flags |= 0x08,
            b"XMP " => flags |= 0x04,
            _ => {}
        }
    }
    if own.iter().any(|(k, _)| k == b"ALPH") || webp_has_alpha(&own) {
        flags |= 0x10;
    }
    let mut vp8x = b"VP8X".to_vec();
    vp8x.extend_from_slice(&10u32.to_le_bytes());
    vp8x.push(flags);
    vp8x.extend_from_slice(&[0, 0, 0]);
    let (w, h) = (width.saturating_sub(1), height.saturating_sub(1));
    vp8x.extend_from_slice(&w.to_le_bytes()[..3]);
    vp8x.extend_from_slice(&h.to_le_bytes()[..3]);
    let mut body = b"WEBP".to_vec();
    body.extend_from_slice(&vp8x);
    body.extend_from_slice(&picture);
    for c in chunks {
        body.extend_from_slice(c);
    }
    let mut out = b"RIFF".to_vec();
    out.extend_from_slice(&(body.len() as u32).to_le_bytes());
    out.extend_from_slice(&body);
    out
}

/// Whether a lossless picture chunk says it uses its alpha channel.
fn webp_has_alpha(chunks: &[([u8; 4], &[u8])]) -> bool {
    chunks.iter().any(|(kind, c)| kind == b"VP8L" && c.len() > 12 && (c[12] & 0x10) != 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn picture(w: u32, h: u32) -> DynamicImage {
        DynamicImage::ImageRgb8(image::RgbImage::from_fn(w, h, |x, y| image::Rgb([(x * 3) as u8, (y * 5) as u8, 90])))
    }

    fn png(w: u32, h: u32) -> Vec<u8> {
        let mut out = Vec::new();
        picture(w, h).write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png).unwrap();
        out
    }

    #[test]
    fn png_metadata_is_copied_or_stripped() {
        let tmp = tempfile::tempdir().unwrap();
        // An original with a text chunk, and an "upscale" carrying another.
        let text = |key: &str, value: &str| {
            let mut data = key.as_bytes().to_vec();
            data.push(0);
            data.extend_from_slice(value.as_bytes());
            let mut c = (data.len() as u32).to_be_bytes().to_vec();
            c.extend_from_slice(b"tEXt");
            c.extend_from_slice(&data);
            let mut crc = flate2::Crc::new();
            crc.update(b"tEXt");
            crc.update(&data);
            c.extend_from_slice(&crc.sum().to_be_bytes());
            c
        };
        let original = png_with_chunks(&png(16, 12), &[text("parameters", "a fox\nSteps: 20, Sampler: Euler, Seed: 7")]);
        let source = tmp.path().join("fox.png");
        std::fs::write(&source, &original).unwrap();
        let result = png_with_chunks(&png(32, 24), &[text("prompt", "{\"server\": true}")]);

        let kept = save_bytes(&source, &result, Metadata::Copy).unwrap();
        assert_eq!(kept.file_name().unwrap(), "fox_up2x.png");
        let bytes = std::fs::read(&kept).unwrap();
        assert_eq!(png_meta_chunks(&bytes), png_meta_chunks(&original));
        assert_eq!(image::load_from_memory(&bytes).unwrap().width(), 32);
        assert_eq!(crate::meta::extract(&kept).prompt, "a fox");

        let bare = save_bytes(&source, &result, Metadata::Strip).unwrap();
        assert_eq!(bare.file_name().unwrap(), "fox_up2x-2.png");
        assert!(png_meta_chunks(&std::fs::read(&bare).unwrap()).is_empty());
    }

    #[test]
    fn jpeg_and_webp_metadata_is_copied() {
        let tmp = tempfile::tempdir().unwrap();
        // JPEG with an EXIF segment and a comment.
        let mut jpeg = Vec::new();
        jpeg_encoder::Encoder::new(&mut jpeg, 90).encode(picture(16, 12).to_rgb8().as_raw(), 16, 12, jpeg_encoder::ColorType::Rgb).unwrap();
        let mut exif = vec![0xFF, 0xE1];
        let payload = b"Exif\0\0II*\0\x08\0\0\0\0\0";
        exif.extend_from_slice(&((payload.len() + 2) as u16).to_be_bytes());
        exif.extend_from_slice(payload);
        let mut com = vec![0xFF, 0xFE, 0, 9];
        com.extend_from_slice(b"a fox!!");
        let original = jpeg_with_segments(&jpeg, &[exif.clone(), com.clone()]);
        let source = tmp.path().join("fox.jpg");
        std::fs::write(&source, &original).unwrap();
        let out = save_bytes(&source, &png(48, 36), Metadata::Copy).unwrap();
        assert_eq!(out.file_name().unwrap(), "fox_up3x.jpg");
        let bytes = std::fs::read(&out).unwrap();
        assert_eq!(jpeg_meta_segments(&bytes), vec![exif, com]);
        assert_eq!(image::load_from_memory(&bytes).unwrap().width(), 48);

        // WebP with an EXIF chunk.
        let mut webp = Vec::new();
        image::codecs::webp::WebPEncoder::new_lossless(&mut webp).write_image(picture(16, 12).to_rgba8().as_raw(), 16, 12, image::ExtendedColorType::Rgba8).unwrap();
        let mut chunk = b"EXIF".to_vec();
        chunk.extend_from_slice(&(payload.len() as u32 - 6).to_le_bytes());
        chunk.extend_from_slice(&payload[6..]);
        let original = webp_with_chunks(&webp, &[chunk.clone()], 16, 12);
        let source = tmp.path().join("fox.webp");
        std::fs::write(&source, &original).unwrap();
        let out = save_bytes(&source, &png(32, 24), Metadata::Copy).unwrap();
        let bytes = std::fs::read(&out).unwrap();
        assert_eq!(webp_meta_chunks(&bytes), vec![chunk]);
        let back = image::load_from_memory(&bytes).unwrap();
        assert_eq!((back.width(), back.height()), (32, 24));
        let stripped = save_bytes(&source, &png(32, 24), Metadata::Strip).unwrap();
        assert!(webp_meta_chunks(&std::fs::read(&stripped).unwrap()).is_empty());
    }
}
