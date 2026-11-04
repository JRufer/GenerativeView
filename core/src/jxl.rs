//! JPEG XL files: saving a picture as one, reading one back, and keeping
//! generation metadata in it.
//!
//! The picture is encoded by libjxl and decoded by the pure-Rust `jxl` crate,
//! both through `gamut-jxl`. Metadata lives in a box of its own after the
//! codestream, which readers that do not know the box step over.

use gamut_core::{DecodeImage, Dimensions, EncodeImage, ImageBuf, ImageRef, Rgb8, Rgba8};
use gamut_jxl::{Container, Distance, JxlDecoder, JxlEncoder};
use image::{DynamicImage, RgbImage, RgbaImage};

/// The box the app's metadata is kept in.
const META_BOX: &[u8; 4] = b"gvmd";

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
    fn no_metadata_is_none_and_a_broken_file_is_an_error() {
        assert_eq!(metadata(&encode(&picture(false), Quality::Lossless, b"").unwrap()), None);
        assert!(decode(b"not a picture").is_err());
    }
}
