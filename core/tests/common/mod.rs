//! Builders for image files carrying generation metadata, so the tests
//! exercise the real container readers rather than pre-parsed text.
#![allow(dead_code)]

use std::io::Cursor;
use std::path::Path;

pub fn fixture(name: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

pub fn fixture_path(name: &str) -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)
}

/// (prompt graph, workflow graph) from a `comfy_*.json` fixture.
pub fn comfy(name: &str) -> (String, String) {
    let v: serde_json::Value = serde_json::from_str(&fixture(name)).unwrap();
    (v["prompt"].to_string(), v["workflow"].to_string())
}

fn pixels(w: u32, h: u32, seed: u32) -> image::RgbImage {
    image::RgbImage::from_fn(w, h, |x, y| {
        image::Rgb([((x * 7 + seed * 31) % 256) as u8, ((y * 5 + seed * 17) % 256) as u8, ((x + y + seed * 3) % 256) as u8])
    })
}

fn chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + 12);
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let mut crc = flate2::Crc::new();
    crc.update(kind);
    crc.update(data);
    out.extend_from_slice(&crc.sum().to_be_bytes());
    out
}

/// A real PNG with `tEXt` chunks placed before the image data, the way
/// ComfyUI, InvokeAI and A1111 write them.
pub fn png_with_text(w: u32, h: u32, seed: u32, texts: &[(&str, &str)]) -> Vec<u8> {
    let mut png = Vec::new();
    pixels(w, h, seed).write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
    let mut out = png[..33].to_vec(); // signature + IHDR
    for (key, value) in texts {
        let mut data = key.as_bytes().to_vec();
        data.push(0);
        data.extend_from_slice(value.as_bytes());
        out.extend(chunk(b"tEXt", &data));
    }
    out.extend_from_slice(&png[33..]);
    out
}

pub fn write_png(path: &Path, seed: u32, texts: &[(&str, &str)]) {
    std::fs::write(path, png_with_text(96, 64, seed, texts)).unwrap();
}

/// PNG with compressed (`zTXt`) and international (`iTXt`) chunks, placed
/// after the image data for good measure.
pub fn png_with_ztxt_itxt(key_z: &str, value_z: &str, key_i: &str, value_i: &str) -> Vec<u8> {
    use std::io::Write;
    let mut png = Vec::new();
    pixels(32, 32, 1).write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
    let iend = png.len() - 12;
    let mut out = png[..iend].to_vec();

    let mut enc = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    enc.write_all(value_z.as_bytes()).unwrap();
    let mut z = key_z.as_bytes().to_vec();
    z.extend_from_slice(&[0, 0]);
    z.extend(enc.finish().unwrap());
    out.extend(chunk(b"zTXt", &z));

    let mut i = key_i.as_bytes().to_vec();
    i.extend_from_slice(&[0, 0, 0, 0, 0]); // uncompressed, no language, no translation
    i.extend_from_slice(value_i.as_bytes());
    out.extend(chunk(b"iTXt", &i));

    out.extend_from_slice(&png[iend..]);
    out
}

/// A JPEG whose EXIF UserComment holds `text` as big-endian UTF-16, which is
/// how A1111 saves parameters into JPEG and WebP.
pub fn jpeg_with_user_comment(text: &str) -> Vec<u8> {
    let mut jpeg = Vec::new();
    pixels(80, 48, 2).write_to(&mut Cursor::new(&mut jpeg), image::ImageFormat::Jpeg).unwrap();
    let exif = exif_user_comment(text);
    let mut out = jpeg[..2].to_vec();
    out.extend_from_slice(&[0xFF, 0xE1]);
    out.extend_from_slice(&((exif.len() + 2) as u16).to_be_bytes());
    out.extend_from_slice(&exif);
    out.extend_from_slice(&jpeg[2..]);
    out
}

fn exif_user_comment(text: &str) -> Vec<u8> {
    let mut comment = b"UNICODE\0".to_vec();
    for unit in text.encode_utf16() {
        comment.extend_from_slice(&unit.to_be_bytes());
    }
    let mut t = b"MM\0*".to_vec();
    t.extend_from_slice(&8u32.to_be_bytes()); // IFD0 at 8
    t.extend_from_slice(&1u16.to_be_bytes());
    t.extend_from_slice(&0x8769u16.to_be_bytes()); // Exif IFD pointer
    t.extend_from_slice(&4u16.to_be_bytes());
    t.extend_from_slice(&1u32.to_be_bytes());
    t.extend_from_slice(&26u32.to_be_bytes());
    t.extend_from_slice(&0u32.to_be_bytes()); // no next IFD
    assert_eq!(t.len(), 26);
    t.extend_from_slice(&1u16.to_be_bytes());
    t.extend_from_slice(&0x9286u16.to_be_bytes()); // UserComment
    t.extend_from_slice(&7u16.to_be_bytes());
    t.extend_from_slice(&(comment.len() as u32).to_be_bytes());
    t.extend_from_slice(&44u32.to_be_bytes());
    t.extend_from_slice(&0u32.to_be_bytes());
    assert_eq!(t.len(), 44);
    t.extend_from_slice(&comment);
    let mut out = b"Exif\0\0".to_vec();
    out.extend(t);
    out
}

/// A WebP carrying `key:{json}` strings in EXIF Make/Model, the layout
/// ComfyUI's WebP writers use.
pub fn webp_with_comfy_exif(prompt: &str, workflow: &str) -> Vec<u8> {
    let (w, h) = (72u32, 40u32);
    let mut plain = Vec::new();
    pixels(w, h, 3).write_to(&mut Cursor::new(&mut plain), image::ImageFormat::WebP).unwrap();
    let image_chunks = &plain[12..];

    let make = format!("workflow:{workflow}\0");
    let model = format!("prompt:{prompt}\0");
    let mut t = b"II*\0".to_vec();
    t.extend_from_slice(&8u32.to_le_bytes());
    t.extend_from_slice(&2u16.to_le_bytes());
    let data_start = 8 + 2 + 2 * 12 + 4;
    for (tag, value, offset) in [(0x010fu16, &make, data_start), (0x0110u16, &model, data_start + make.len())] {
        t.extend_from_slice(&tag.to_le_bytes());
        t.extend_from_slice(&2u16.to_le_bytes());
        t.extend_from_slice(&(value.len() as u32).to_le_bytes());
        t.extend_from_slice(&(offset as u32).to_le_bytes());
    }
    t.extend_from_slice(&0u32.to_le_bytes());
    t.extend_from_slice(make.as_bytes());
    t.extend_from_slice(model.as_bytes());

    let mut body = b"WEBP".to_vec();
    body.extend_from_slice(b"VP8X");
    body.extend_from_slice(&10u32.to_le_bytes());
    body.push(0x08); // EXIF present
    body.extend_from_slice(&[0, 0, 0]);
    body.extend_from_slice(&(w - 1).to_le_bytes()[..3]);
    body.extend_from_slice(&(h - 1).to_le_bytes()[..3]);
    body.extend_from_slice(image_chunks);
    body.extend_from_slice(b"EXIF");
    body.extend_from_slice(&(t.len() as u32).to_le_bytes());
    body.extend_from_slice(&t);
    if t.len() % 2 == 1 {
        body.push(0);
    }
    let mut out = b"RIFF".to_vec();
    out.extend_from_slice(&(body.len() as u32).to_le_bytes());
    out.extend(body);
    out
}

pub const A1111_TEXT: &str = "cinematic photo of a lighthouse on a cliff, stormy sea <lora:add_detail:0.7>\nNegative prompt: cartoon, lowres, text\nSteps: 30, Sampler: DPM++ 2M Karras, CFG scale: 7, Seed: 3958203417, Size: 768x1152, Model hash: 31e35c80fc, Model: sd_xl_base_1.0, VAE: sdxl_vae.safetensors, Lora hashes: \"add_detail: 7c6bad76eb54\", Version: v1.7.0";

pub const INVOKE_TEXT: &str = r#"{"generation_mode":"sdxl_txt2img","positive_prompt":"an isometric cutaway of a cozy submarine cabin","negative_prompt":"blurry, people","width":1216,"height":832,"seed":2718281828,"rand_device":"cpu","cfg_scale":6.0,"cfg_rescale_multiplier":0.0,"steps":28,"scheduler":"dpmpp_2m_sde_k","model":{"key":"3b0f","hash":"blake3:1f2e","name":"Juggernaut XL v9","base":"sdxl","type":"main"},"loras":[{"model":{"key":"77aa","hash":"blake3:9c","name":"cutaway-diagram-xl","base":"sdxl","type":"lora"},"weight":0.85}],"vae":{"key":"aa01","hash":"blake3:44","name":"sdxl-vae-fp16-fix","base":"sdxl","type":"vae"},"positive_style_prompt":"an isometric cutaway of a cozy submarine cabin","negative_style_prompt":"","controlnets":[],"ipAdapters":[],"t2iAdapters":[],"app_version":"5.6.0"}"#;
