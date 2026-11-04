//! JPEG XL files: saving a picture as one, reading one back, and keeping
//! generation metadata in it.
//!
//! The picture is encoded by libjxl and decoded by the pure-Rust `jxl` crate,
//! both through `gamut-jxl`. Metadata lives in a box of its own after the
//! codestream, which readers that do not know the box step over.

use gamut_core::{DecodeImage, Dimensions, EncodeImage, ImageBuf, ImageRef, Rgb8, Rgba8};
use gamut_jxl::{Container, Distance, JxlDecoder, JxlEncoder};
use flate2::{read::ZlibDecoder, write::ZlibEncoder, Compression};
use image::{DynamicImage, RgbImage, RgbaImage};
use std::io::{Read, Write};
use std::path::Path;

/// The box the app's metadata is kept in.
pub const META_BOX: &[u8; 4] = b"gvmd";

/// What a `.jxl` file starts with: a bare codestream or the container.
pub fn is_jxl(bytes: &[u8]) -> bool {
    bytes.starts_with(&[0xFF, 0x0A]) || bytes.starts_with(b"\0\0\0\x0cJXL \r\n\x87\n")
}

/// The picture at `path`, whatever its format.
pub fn open(path: &Path) -> Result<DynamicImage, String> {
    let mut head = [0u8; 12];
    let n = std::fs::File::open(path).and_then(|mut f| f.read(&mut head)).map_err(|e| e.to_string())?;
    if is_jxl(&head[..n]) {
        return decode(&std::fs::read(path).map_err(|e| e.to_string())?);
    }
    image::ImageReader::open(path)
        .map_err(|e| e.to_string())?
        .with_guessed_format()
        .map_err(|e| e.to_string())?
        .decode()
        .map_err(|e| format!("cannot read the picture: {e}"))
}

/// The picture's width and height, from the start of the file.
pub fn dimensions(head: &[u8]) -> Result<(u32, u32), String> {
    let info = JxlDecoder::new().info(head).map_err(|e| e.to_string())?;
    Ok((info.dimensions.width, info.dimensions.height))
}

/// The text a file's metadata is made of, as the box holds it.
pub fn pack_texts(texts: &[(String, String)]) -> Result<Vec<u8>, String> {
    let json = serde_json::to_vec(texts).map_err(|e| e.to_string())?;
    let mut out = ZlibEncoder::new(Vec::new(), Compression::default());
    out.write_all(&json).map_err(|e| e.to_string())?;
    out.finish().map_err(|e| e.to_string())
}

/// What [`pack_texts`] packed; nothing if it cannot be read.
pub fn unpack_texts(packed: &[u8]) -> Vec<(String, String)> {
    let mut json = Vec::new();
    if ZlibDecoder::new(packed).read_to_end(&mut json).is_err() {
        return Vec::new();
    }
    serde_json::from_slice(&json).unwrap_or_default()
}

/// The picture at `path` as `width`, `height` (each 4 bytes, little endian)
/// and then premultiplied RGBA, for the app to show.
pub fn pixels(path: &Path) -> Result<Vec<u8>, String> {
    let picture = decode(&std::fs::read(path).map_err(|e| e.to_string())?)?;
    let alpha = picture.color().has_alpha();
    let rgba = picture.to_rgba8();
    let mut out = Vec::with_capacity(8 + rgba.as_raw().len());
    out.extend_from_slice(&rgba.width().to_le_bytes());
    out.extend_from_slice(&rgba.height().to_le_bytes());
    out.extend_from_slice(rgba.as_raw());
    if alpha {
        for px in out[8..].chunks_exact_mut(4) {
            let a = u32::from(px[3]);
            for c in &mut px[..3] {
                *c = ((u32::from(*c) * a + 127) / 255) as u8;
            }
        }
    }
    Ok(out)
}

/// Save the picture at `source` as a `.jxl` at `dest`, with its metadata.
pub fn convert(source: &Path, dest: &Path, quality: Quality) -> Result<(), String> {
    let picture = open(source)?;
    let texts = crate::meta::container::read_raw(source).map_err(|e| e.to_string())?.texts;
    let meta = if texts.is_empty() { Vec::new() } else { pack_texts(&texts)? };
    let bytes = encode(&picture, quality, &meta)?;
    let name = dest.file_name().and_then(|n| n.to_str()).unwrap_or("picture.jxl");
    let part = dest.with_file_name(format!(".{name}.part"));
    std::fs::write(&part, bytes).map_err(|e| format!("cannot write {}: {e}", part.display()))?;
    std::fs::rename(&part, dest).map_err(|e| format!("cannot write {}: {e}", dest.display()))
}

/// How a picture is compressed.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Quality {
    /// Every pixel kept.
    Lossless,
    /// Butteraugli distance: 0.5 looks the same at normal viewing.
    Distance(f32),
}

fn encoder(quality: Quality) -> Result<JxlEncoder, String> {
    let encoder = match quality {
        Quality::Lossless => JxlEncoder::lossless(),
        Quality::Distance(d) => JxlEncoder::lossy(Distance::new(d).map_err(|e| e.to_string())?),
    };
    Ok(encoder.with_container(Container::IsoBmff))
}

/// `picture` as a `.jxl` file, carrying `meta` when there is any.
pub fn encode(picture: &DynamicImage, quality: Quality, meta: &[u8]) -> Result<Vec<u8>, String> {
    let dims = Dimensions { width: picture.width(), height: picture.height() };
    let encoder = encoder(quality)?;
    let mut out = if picture.color().has_alpha() {
        let pixels = picture.to_rgba8();
        let image = ImageRef::<Rgba8>::new(pixels.as_raw(), dims).map_err(|e| e.to_string())?;
        encoder.encode_to_vec(image)
    } else {
        let pixels = picture.to_rgb8();
        let image = ImageRef::<Rgb8>::new(pixels.as_raw(), dims).map_err(|e| e.to_string())?;
        encoder.encode_to_vec(image)
    }
    .map_err(|e| e.to_string())?;
    if !meta.is_empty() {
        let size = u32::try_from(meta.len() + 8).map_err(|_| "metadata too large")?;
        out.extend_from_slice(&size.to_be_bytes());
        out.extend_from_slice(META_BOX);
        out.extend_from_slice(meta);
    }
    Ok(out)
}

/// The picture in a `.jxl` file.
pub fn decode(bytes: &[u8]) -> Result<DynamicImage, String> {
    let decoder = JxlDecoder::new();
    let info = decoder.info(bytes).map_err(|e| e.to_string())?;
    let (width, height) = (info.dimensions.width, info.dimensions.height);
    if info.has_alpha {
        let image: ImageBuf<Rgba8> = decoder.decode_image(bytes).map_err(|e| e.to_string())?;
        RgbaImage::from_raw(width, height, image.as_samples().to_vec())
            .map(DynamicImage::ImageRgba8)
            .ok_or_else(|| "wrong picture size".to_string())
    } else {
        let image: ImageBuf<Rgb8> = decoder.decode_image(bytes).map_err(|e| e.to_string())?;
        RgbImage::from_raw(width, height, image.as_samples().to_vec())
            .map(DynamicImage::ImageRgb8)
            .ok_or_else(|| "wrong picture size".to_string())
    }
}

/// What [`encode`] stored in the file, if it stored anything.
pub fn metadata(bytes: &[u8]) -> Option<&[u8]> {
    let mut at = 0usize;
    while at + 8 <= bytes.len() {
        let size = u32::from_be_bytes(bytes[at..at + 4].try_into().ok()?) as usize;
        let kind = &bytes[at + 4..at + 8];
        let (start, end) = match size {
            0 => (at + 8, bytes.len()),
            1 => {
                let long = u64::from_be_bytes(bytes.get(at + 8..at + 16)?.try_into().ok()?);
                (at + 16, at.checked_add(usize::try_from(long).ok()?)?)
            }
            n if n >= 8 => (at + 8, at.checked_add(n)?),
            _ => return None,
        };
        if end > bytes.len() || start > end {
            return None;
        }
        if kind == META_BOX {
            return Some(&bytes[start..end]);
        }
        at = end;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn picture(alpha: bool) -> DynamicImage {
        let rgba = RgbaImage::from_fn(48, 32, |x, y| {
            image::Rgba([(x * 5) as u8, (y * 7) as u8, ((x ^ y) * 3) as u8, if alpha { (x + y) as u8 } else { 255 }])
        });
        if alpha {
            DynamicImage::ImageRgba8(rgba)
        } else {
            DynamicImage::ImageRgb8(DynamicImage::ImageRgba8(rgba).to_rgb8())
        }
    }

    #[test]
    fn lossless_keeps_every_pixel_and_the_metadata() {
        for alpha in [false, true] {
            let original = picture(alpha);
            let bytes = encode(&original, Quality::Lossless, br#"{"prompt":"a fox"}"#).unwrap();
            assert_eq!(decode(&bytes).unwrap().to_rgba8(), original.to_rgba8());
            assert_eq!(metadata(&bytes), Some(&br#"{"prompt":"a fox"}"#[..]));
        }
    }

    #[test]
    fn lossy_keeps_the_size_and_the_metadata() {
        let bytes = encode(&picture(false), Quality::Distance(0.5), b"meta").unwrap();
        let back = decode(&bytes).unwrap();
        assert_eq!((back.width(), back.height()), (48, 32));
        assert_eq!(metadata(&bytes), Some(&b"meta"[..]));
    }

    #[test]
    fn convert_keeps_the_text_the_metadata_reader_sees() {
        let tmp = tempfile::tempdir().unwrap();
        let (png, jxl) = (tmp.path().join("a.png"), tmp.path().join("a.jxl"));
        let mut bytes = Vec::new();
        picture(false).write_to(&mut std::io::Cursor::new(&mut bytes), image::ImageFormat::Png).unwrap();
        // A tEXt chunk after the header, as a generator would write it.
        let mut chunk = b"tEXtparameters\0a fox\nSteps: 20".to_vec();
        let crc = {
            let mut c = !0u32;
            for b in &chunk {
                c ^= u32::from(*b);
                for _ in 0..8 {
                    c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
                }
            }
            !c
        };
        let length = (chunk.len() as u32 - 4).to_be_bytes();
        chunk.extend_from_slice(&crc.to_be_bytes());
        let at = 8 + 25;
        let tail = bytes.split_off(at);
        bytes.extend_from_slice(&length);
        bytes.extend_from_slice(&chunk);
        bytes.extend_from_slice(&tail);
        std::fs::write(&png, bytes).unwrap();

        convert(&png, &jxl, Quality::Lossless).unwrap();
        let before = crate::meta::container::read_raw(&png).unwrap();
        let after = crate::meta::container::read_raw(&jxl).unwrap();
        assert_eq!(after.texts, before.texts);
        assert!(!after.texts.is_empty());
        assert_eq!((after.width, after.height), (48, 32));
        assert_eq!(open(&jxl).unwrap().to_rgba8(), open(&png).unwrap().to_rgba8());
        let px = pixels(&jxl).unwrap();
        assert_eq!(px.len(), 8 + 48 * 32 * 4);
        assert_eq!(&px[..4], &48u32.to_le_bytes());
    }

    #[test]
    fn no_metadata_is_none_and_a_broken_file_is_an_error() {
        assert_eq!(metadata(&encode(&picture(false), Quality::Lossless, b"").unwrap()), None);
        assert!(decode(b"not a picture").is_err());
    }
}
