//! AI upscaling on the device: Real-ESRGAN's compact models, run on the CPU.
//!
//! The models are a plain stack of 3×3 convolutions with a learned
//! activation between them (SRVGGNetCompact): the last one makes 16 values
//! per pixel per colour, which are laid out as a 4×4 block of the bigger
//! picture, and added to the picture simply enlarged. There is nothing to
//! prompt; the picture is the only input.
//!
//! The models are not part of the app. Each is one `.pth` file from the
//! Real-ESRGAN project's releases (BSD-3-Clause), downloaded once by the UI
//! into `<data dir>/models/upscale/` and read here with [`pth`].
//!
//! A picture is upscaled in tiles, each with a margin that is thrown away
//! afterwards so that tiles meet without seams; each convolution is one
//! matrix multiplication over the tile.

pub mod pth;

use gemm::Parallelism;
use image::{DynamicImage, RgbImage, RgbaImage};
use std::path::{Path, PathBuf};

/// An upscale model the app knows how to fetch and run.
pub struct ModelInfo {
    pub id: &'static str,
    pub name: &'static str,
    pub detail: &'static str,
    pub file: &'static str,
    pub bytes: u64,
}

pub const SOURCE: &str = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/";

pub const MODELS: [ModelInfo; 2] = [
    ModelInfo {
        id: "general",
        name: "Real-ESRGAN general",
        detail: "Photos, renders and most generated pictures",
        file: "realesr-general-x4v3.pth",
        bytes: 4_885_111,
    },
    ModelInfo {
        id: "anime",
        name: "Real-ESRGAN anime",
        detail: "Illustration, anime and flat colour; about twice as fast",
        file: "realesr-animevideov3.pth",
        bytes: 2_504_012,
    },
];

pub fn model_info(id: &str) -> Option<&'static ModelInfo> {
    MODELS.iter().find(|m| m.id == id)
}

/// Where the models live under the app's data folder.
pub fn model_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("models").join("upscale")
}

/// Input pixels per side of a tile, and the margin around it. The margin
/// gives every kept pixel enough of its surroundings that a tile edge does
/// not show.
const TILE: usize = 160;
const MARGIN: usize = 12;

struct Conv {
    inputs: usize,
    outputs: usize,
    /// outputs × (inputs × 9), row-major.
    weight: Vec<f32>,
    bias: Vec<f32>,
    /// One slope per output channel for negative values, if an activation
    /// follows.
    prelu: Option<Vec<f32>>,
}

pub struct Upscaler {
    convs: Vec<Conv>,
    pub scale: usize,
}

fn threads() -> Parallelism {
    let n = std::thread::available_parallelism().map_or(1, |n| n.get());
    if n > 1 {
        Parallelism::Rayon(n)
    } else {
        Parallelism::None
    }
}

impl Upscaler {
    pub fn load(path: &Path) -> Result<Upscaler, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        Self::from_tensors(pth::load(&bytes)?)
    }

    /// Build from a state dict: `body.<n>.weight` and `.bias` for the
    /// convolutions, `body.<n>.weight` alone for the activation after one.
    pub fn from_tensors(mut tensors: std::collections::HashMap<String, pth::Tensor>) -> Result<Upscaler, String> {
        let mut convs: Vec<Conv> = Vec::new();
        let mut n = 0;
        loop {
            let Some(weight) = tensors.remove(&format!("body.{n}.weight")) else { break };
            if weight.shape.len() == 4 {
                if weight.shape[2] != 3 || weight.shape[3] != 3 {
                    return Err("only 3×3 convolutions are supported".into());
                }
                let bias = tensors.remove(&format!("body.{n}.bias")).ok_or("convolution without a bias")?;
                convs.push(Conv { outputs: weight.shape[0], inputs: weight.shape[1], weight: weight.data, bias: bias.data, prelu: None });
            } else if weight.shape.len() == 1 {
                let last = convs.last_mut().ok_or("activation before any convolution")?;
                if weight.data.len() != last.outputs && weight.data.len() != 1 {
                    return Err("activation does not fit its convolution".into());
                }
                last.prelu = Some(if weight.data.len() == 1 { vec![weight.data[0]; last.outputs] } else { weight.data });
            } else {
                return Err(format!("unexpected tensor body.{n}.weight"));
            }
            n += 1;
        }
        let (Some(first), Some(last)) = (convs.first(), convs.last()) else { return Err("not an upscale model".into()) };
        if first.inputs != 3 || last.outputs % 3 != 0 {
            return Err("not an RGB upscale model".into());
        }
        let scale = ((last.outputs / 3) as f64).sqrt() as usize;
        if scale * scale * 3 != last.outputs || scale < 2 {
            return Err("not an upscale model".into());
        }
        for pair in convs.windows(2) {
            if pair[0].outputs != pair[1].inputs {
                return Err("layers do not fit together".into());
            }
        }
        Ok(Upscaler { convs, scale })
    }

    /// Run the network over one tile: `input` is 3 × h × w, planar, values
    /// 0 to 1. Returns 3 × (h·s) × (w·s).
    fn run(&self, input: &[f32], h: usize, w: usize) -> Vec<f32> {
        let hw = h * w;
        let mut x = input.to_vec();
        let mut cols: Vec<f32> = Vec::new();
        for conv in &self.convs {
            let k = conv.inputs * 9;
            cols.clear();
            cols.resize(k * hw, 0.0);
            // im2col with zero padding: row (c, dy, dx) holds channel c
            // shifted by (dy-1, dx-1).
            for c in 0..conv.inputs {
                let plane = &x[c * hw..(c + 1) * hw];
                for dy in 0..3 {
                    for dx in 0..3 {
                        let row = &mut cols[((c * 9) + dy * 3 + dx) * hw..((c * 9) + dy * 3 + dx + 1) * hw];
                        for y in 0..h {
                            let sy = y as isize + dy as isize - 1;
                            if sy < 0 || sy >= h as isize {
                                continue;
                            }
                            let src = &plane[sy as usize * w..sy as usize * w + w];
                            let dst = &mut row[y * w..y * w + w];
                            match dx {
                                0 => dst[1..].copy_from_slice(&src[..w - 1]),
                                1 => dst.copy_from_slice(src),
                                _ => dst[..w - 1].copy_from_slice(&src[1..]),
                            }
                        }
                    }
                }
            }
            let mut out = vec![0.0f32; conv.outputs * hw];
            // SAFETY: out is outputs×hw, weight outputs×k, cols k×hw, all
            // row-major, as the strides say.
            unsafe {
                gemm::gemm(
                    conv.outputs,
                    hw,
                    k,
                    out.as_mut_ptr(),
                    1,
                    hw as isize,
                    false,
                    conv.weight.as_ptr(),
                    1,
                    k as isize,
                    cols.as_ptr(),
                    1,
                    hw as isize,
                    0.0,
                    1.0,
                    false,
                    false,
                    false,
                    threads(),
                );
            }
            for (o, plane) in out.chunks_exact_mut(hw).enumerate() {
                let b = conv.bias[o];
                match &conv.prelu {
                    Some(slopes) => {
                        let a = slopes[o];
                        plane.iter_mut().for_each(|v| {
                            *v += b;
                            if *v < 0.0 {
                                *v *= a;
                            }
                        });
                    }
                    None => plane.iter_mut().for_each(|v| *v += b),
                }
            }
            x = out;
        }
        // Pixel shuffle, plus the input simply enlarged.
        let s = self.scale;
        let (oh, ow) = (h * s, w * s);
        let mut big = vec![0.0f32; 3 * oh * ow];
        for c in 0..3 {
            for i in 0..s {
                for j in 0..s {
                    let plane = &x[(c * s * s + i * s + j) * hw..(c * s * s + i * s + j + 1) * hw];
                    for y in 0..h {
                        for xx in 0..w {
                            big[c * oh * ow + (y * s + i) * ow + xx * s + j] = plane[y * w + xx] + input[c * hw + y * w + xx];
                        }
                    }
                }
            }
        }
        big
    }

    /// Upscale a whole picture by the model's own factor. `progress` hears
    /// (tiles done, tiles in all) and returns false to stop.
    pub fn upscale(&self, picture: &RgbImage, progress: &mut dyn FnMut(usize, usize) -> bool) -> Result<RgbImage, String> {
        let (w, h) = (picture.width() as usize, picture.height() as usize);
        let s = self.scale;
        let mut out = RgbImage::new((w * s) as u32, (h * s) as u32);
        let across = w.div_ceil(TILE);
        let down = h.div_ceil(TILE);
        let total = across * down;
        let mut done = 0;
        for ty in 0..down {
            for tx in 0..across {
                if !progress(done, total) {
                    return Err("cancelled".into());
                }
                // The tile, and the margin around it that is clipped to the
                // picture.
                let (x0, y0) = (tx * TILE, ty * TILE);
                let (x1, y1) = ((x0 + TILE).min(w), (y0 + TILE).min(h));
                let (mx0, my0) = (x0.saturating_sub(MARGIN), y0.saturating_sub(MARGIN));
                let (mx1, my1) = ((x1 + MARGIN).min(w), (y1 + MARGIN).min(h));
                let (tw, th) = (mx1 - mx0, my1 - my0);
                let mut input = vec![0.0f32; 3 * tw * th];
                for y in 0..th {
                    for x in 0..tw {
                        let p = picture.get_pixel((mx0 + x) as u32, (my0 + y) as u32).0;
                        for c in 0..3 {
                            input[c * tw * th + y * tw + x] = p[c] as f32 / 255.0;
                        }
                    }
                }
                let big = self.run(&input, th, tw);
                let (bw, bh) = (tw * s, th * s);
                for y in (y0 - my0) * s..(y1 - my0) * s {
                    for x in (x0 - mx0) * s..(x1 - mx0) * s {
                        let px = |c: usize| (big[c * bw * bh + y * bw + x].clamp(0.0, 1.0) * 255.0).round() as u8;
                        out.put_pixel((mx0 * s + x) as u32, (my0 * s + y) as u32, image::Rgb([px(0), px(1), px(2)]));
                    }
                }
                done += 1;
            }
        }
        progress(total, total);
        Ok(out)
    }
}

/// Upscale `picture` by `factor` (2 or 4) with `model`. The models enlarge
/// four times; a 2× result is the 4× one brought down, which keeps the
/// detail the model added. Transparency is enlarged plainly alongside.
pub fn upscale_picture(model: &Upscaler, picture: &DynamicImage, factor: u32, progress: &mut dyn FnMut(usize, usize) -> bool) -> Result<DynamicImage, String> {
    let rgb = picture.to_rgb8();
    let big = model.upscale(&rgb, progress)?;
    let (tw, th) = (picture.width() * factor, picture.height() * factor);
    let big = if big.width() != tw || big.height() != th {
        image::imageops::resize(&big, tw, th, image::imageops::FilterType::Lanczos3)
    } else {
        big
    };
    if picture.color().has_alpha() {
        let alpha = picture.to_rgba8();
        if alpha.pixels().any(|p| p.0[3] != 255) {
            let alpha = image::imageops::resize(&alpha, tw, th, image::imageops::FilterType::Lanczos3);
            let mut out = RgbaImage::new(tw, th);
            for (x, y, p) in out.enumerate_pixels_mut() {
                let c = big.get_pixel(x, y).0;
                *p = image::Rgba([c[0], c[1], c[2], alpha.get_pixel(x, y).0[3]]);
            }
            return Ok(DynamicImage::ImageRgba8(out));
        }
    }
    Ok(DynamicImage::ImageRgb8(big))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    /// A two-layer model whose first convolution passes each colour through
    /// and whose last adds nothing: the result is the picture enlarged.
    fn identity_model(scale: usize) -> Upscaler {
        let mut t = HashMap::new();
        let mut w0 = vec![0.0; 4 * 3 * 9];
        for c in 0..3 {
            w0[(c * 3 + c) * 9 + 4] = 1.0;
        }
        t.insert("body.0.weight".into(), pth::Tensor { shape: vec![4, 3, 3, 3], data: w0 });
        t.insert("body.0.bias".into(), pth::Tensor { shape: vec![4], data: vec![0.0; 4] });
        t.insert("body.1.weight".into(), pth::Tensor { shape: vec![4], data: vec![0.25; 4] });
        let outs = 3 * scale * scale;
        t.insert("body.2.weight".into(), pth::Tensor { shape: vec![outs, 4, 3, 3], data: vec![0.0; outs * 4 * 9] });
        t.insert("body.2.bias".into(), pth::Tensor { shape: vec![outs], data: vec![0.0; outs] });
        Upscaler::from_tensors(t).unwrap()
    }

    #[test]
    fn enlarges_in_tiles_without_seams() {
        let model = identity_model(4);
        assert_eq!(model.scale, 4);
        let picture = RgbImage::from_fn(TILE as u32 + 37, 50, |x, y| image::Rgb([(x * 3 % 256) as u8, (y * 5 % 256) as u8, 77]));
        let mut calls = 0;
        let big = model.upscale(&picture, &mut |_, _| {
            calls += 1;
            true
        }).unwrap();
        assert_eq!((big.width(), big.height()), (picture.width() * 4, 200));
        assert_eq!(calls, 3);
        for (x, y, p) in big.enumerate_pixels() {
            assert_eq!(*p, *picture.get_pixel(x / 4, y / 4), "{x},{y}");
        }
        let half = upscale_picture(&model, &DynamicImage::ImageRgb8(picture.clone()), 2, &mut |_, _| true).unwrap();
        assert_eq!((half.width(), half.height()), (picture.width() * 2, 100));
        assert!(model.upscale(&picture, &mut |_, _| false).is_err());
    }

    #[test]
    fn convolution_matches_a_direct_sum() {
        // One random-ish 3→3 layer and a final layer, compared with the
        // convolution written out the slow way.
        let mut t = HashMap::new();
        let w0: Vec<f32> = (0..3 * 3 * 9).map(|i| ((i * 37 % 19) as f32 - 9.0) / 20.0).collect();
        t.insert("body.0.weight".into(), pth::Tensor { shape: vec![3, 3, 3, 3], data: w0.clone() });
        t.insert("body.0.bias".into(), pth::Tensor { shape: vec![3], data: vec![0.1, -0.2, 0.05] });
        t.insert("body.1.weight".into(), pth::Tensor { shape: vec![3], data: vec![0.1, 0.2, 0.3] });
        let outs = 12;
        let w2: Vec<f32> = (0..outs * 3 * 9).map(|i| ((i * 13 % 7) as f32 - 3.0) / 10.0).collect();
        t.insert("body.2.weight".into(), pth::Tensor { shape: vec![outs, 3, 3, 3], data: w2.clone() });
        t.insert("body.2.bias".into(), pth::Tensor { shape: vec![outs], data: vec![0.0; outs] });
        let model = Upscaler::from_tensors(t).unwrap();
        let (h, w) = (5, 7);
        let input: Vec<f32> = (0..3 * h * w).map(|i| (i % 11) as f32 / 10.0).collect();
        let conv = |x: &[f32], wt: &[f32], bias: &[f32], cin: usize, cout: usize| {
            let mut out = vec![0.0; cout * h * w];
            for o in 0..cout {
                for y in 0..h {
                    for xx in 0..w {
                        let mut acc = bias[o];
                        for c in 0..cin {
                            for dy in 0..3 {
                                for dx in 0..3 {
                                    let (sy, sx) = (y as isize + dy as isize - 1, xx as isize + dx as isize - 1);
                                    if sy >= 0 && sy < h as isize && sx >= 0 && sx < w as isize {
                                        acc += wt[((o * cin + c) * 3 + dy) * 3 + dx] * x[c * h * w + sy as usize * w + sx as usize];
                                    }
                                }
                            }
                        }
                        out[o * h * w + y * w + xx] = acc;
                    }
                }
            }
            out
        };
        let mut mid = conv(&input, &w0, &[0.1, -0.2, 0.05], 3, 3);
        for (i, v) in mid.iter_mut().enumerate() {
            if *v < 0.0 {
                *v *= [0.1, 0.2, 0.3][i / (h * w)];
            }
        }
        let last = conv(&mid, &w2, &vec![0.0; outs], 3, outs);
        let got = model.run(&input, h, w);
        for c in 0..3 {
            for y in 0..h * 2 {
                for x in 0..w * 2 {
                    let (i, j) = (y % 2, x % 2);
                    let want = last[(c * 4 + i * 2 + j) * h * w + (y / 2) * w + x / 2] + input[c * h * w + (y / 2) * w + x / 2];
                    let have = got[c * h * w * 4 + y * w * 2 + x];
                    assert!((want - have).abs() < 1e-4, "{c} {y} {x}: {want} vs {have}");
                }
            }
        }
    }
}
