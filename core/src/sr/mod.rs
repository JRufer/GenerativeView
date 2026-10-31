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
        let s = self.scale as u32;
        self.upscale_to(picture, picture.width() * s, picture.height() * s, progress)
    }

    /// Upscale a picture to `width` × `height`, which is at least its own
    /// size and at most the model's factor larger: one run of the model.
    /// Each tile is brought down to the asked-for size as soon as the model
    /// has drawn it, so what is held is the result, never the model's full
    /// size, and a 1.5× of a large picture costs no more memory than its
    /// output.
    pub fn upscale_to(&self, picture: &RgbImage, width: u32, height: u32, progress: &mut dyn FnMut(usize, usize) -> bool) -> Result<RgbImage, String> {
        let (w, h) = (picture.width() as usize, picture.height() as usize);
        let s = self.scale;
        let (ow, oh) = (width as usize, height as usize);
        if w == 0 || h == 0 || ow < w || oh < h || ow > w * s || oh > h * s {
            return Err(format!("cannot upscale {w} × {h} to {ow} × {oh} in one pass"));
        }
        let (fx, fy) = (ow as f64 / w as f64, oh as f64 / h as f64);
        let mut out = RgbImage::new(width, height);
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
                // The output pixels whose centres fall in this tile, and for
                // each, the model's pixels it is made from.
                let cols = taps(x0, x1, mx0, bw, fx, s, ow);
                let rows = taps(y0, y1, my0, bh, fy, s, oh);
                let (ox0, oy0) = (first_out(x0, fx), first_out(y0, fy));
                for c in 0..3 {
                    let plane = &big[c * bw * bh..(c + 1) * bw * bh];
                    // Across first, every row of the model's tile, then down.
                    let mut wide = vec![0.0f32; bh * cols.len()];
                    for by in 0..bh {
                        let row = &plane[by * bw..(by + 1) * bw];
                        for (i, tap) in cols.iter().enumerate() {
                            wide[by * cols.len() + i] = tap.iter().map(|&(k, wt)| row[k] * wt).sum();
                        }
                    }
                    for (j, tap) in rows.iter().enumerate() {
                        for i in 0..cols.len() {
                            let v: f32 = tap.iter().map(|&(k, wt)| wide[k * cols.len() + i] * wt).sum();
                            let px = (v.clamp(0.0, 1.0) * 255.0).round() as u8;
                            out.get_pixel_mut((ox0 + i) as u32, (oy0 + j) as u32).0[c] = px;
                        }
                    }
                }
                done += 1;
            }
        }
        progress(total, total);
        Ok(out)
    }
}

/// The first output pixel whose centre lies at or past input column `x`, at
/// `f` output pixels per input pixel. Consecutive tiles share none and miss
/// none.
fn first_out(x: usize, f: f64) -> usize {
    (x as f64 * f - 0.5).ceil().max(0.0) as usize
}

/// For each output pixel along one side of the tile from `a` to `b` (input
/// pixels; its margin starts at `m`), the model's pixels (indexes into the
/// tile's `n` pixels at the model's factor `s`) that make it and their
/// weights. A tent as wide as one output pixel averages what the model drew
/// under it, so bringing 4× down to 1.5× keeps its detail and does not
/// shimmer; at the model's own factor it is each pixel as it is.
fn taps(a: usize, b: usize, m: usize, n: usize, f: f64, s: usize, size: usize) -> Vec<Vec<(usize, f32)>> {
    let r = s as f64 / f;
    let end = if b == 0 { 0 } else { first_out(b, f).min(size) };
    (first_out(a, f)..end)
        .map(|o| {
            // The output pixel's centre, in the tile's model pixels.
            let g = (o as f64 + 0.5) / f * s as f64 - 0.5 - (m * s) as f64;
            let lo = (g - r).floor().max(0.0) as usize;
            let hi = ((g + r).ceil() as usize).min(n - 1);
            let mut tap: Vec<(usize, f32)> = (lo..=hi)
                .filter_map(|k| {
                    let wt = 1.0 - (k as f64 - g).abs() / r;
                    (wt > 0.0).then_some((k, wt as f32))
                })
                .collect();
            if tap.is_empty() {
                tap.push((g.round().clamp(0.0, (n - 1) as f64) as usize, 1.0));
            }
            let sum: f32 = tap.iter().map(|t| t.1).sum();
            tap.iter_mut().for_each(|t| t.1 /= sum);
            tap
        })
        .collect()
}

/// The longest side an upscale here may have, its pixels in all, and how
/// many times larger it may make a picture. Past these, saving it (and on a
/// phone, holding it) is more than it is worth.
pub const MAX_SIDE: u32 = 8192;
pub const MAX_PIXELS: u64 = 40_000_000;
pub const MAX_FACTOR: f64 = 16.0;

/// The size a `width` × `height` picture comes out at `factor` times as
/// large, or why it may not be made.
pub fn upscaled_size(width: u32, height: u32, factor: f64) -> Result<(u32, u32), String> {
    if !(factor > 1.0 && factor <= MAX_FACTOR) {
        return Err(format!("the factor is more than 1 and at most {MAX_FACTOR}"));
    }
    let (tw, th) = ((width as f64 * factor).round() as u32, (height as f64 * factor).round() as u32);
    if tw.max(th) > MAX_SIDE || tw as u64 * th as u64 > MAX_PIXELS {
        return Err(format!(
            "{width} × {height} at {factor}× would be {tw} × {th}, past the largest upscale ({MAX_SIDE} on a side, {} megapixels)",
            MAX_PIXELS / 1_000_000
        ));
    }
    Ok((tw, th))
}

/// The sizes each run of the model makes on the way to `target` from
/// `from`: one run for up to the model's factor, more past it, each but the
/// last at its full factor where it can be.
fn passes(from: (u32, u32), target: (u32, u32), s: u32) -> Vec<(u32, u32)> {
    let mut chain = vec![target];
    loop {
        let &(tw, th) = chain.last().unwrap();
        if tw <= from.0 * s && th <= from.1 * s {
            break;
        }
        chain.push((tw.div_ceil(s).max(from.0), th.div_ceil(s).max(from.1)));
    }
    chain.reverse();
    chain
}

/// Upscale `picture` by `factor` with `model`: any factor over 1 that
/// [upscaled_size] allows. The models enlarge four times; less than that is
/// the model's picture brought down tile by tile, which keeps the detail it
/// added, and more is the model run again on its own result. Transparency is
/// enlarged plainly alongside.
pub fn upscale_picture(model: &Upscaler, picture: &DynamicImage, factor: f64, progress: &mut dyn FnMut(usize, usize) -> bool) -> Result<DynamicImage, String> {
    let (tw, th) = upscaled_size(picture.width(), picture.height(), factor)?;
    let mut big = picture.to_rgb8();
    let steps = passes((big.width(), big.height()), (tw, th), model.scale as u32);
    // Progress over every run of the model together.
    let mut sizes = vec![(big.width(), big.height())];
    sizes.extend(steps.iter().take(steps.len() - 1));
    let tiles: Vec<usize> = sizes.iter().map(|&(w, h)| (w as usize).div_ceil(TILE) * (h as usize).div_ceil(TILE)).collect();
    let all: usize = tiles.iter().sum();
    let mut before = 0;
    for (i, &(w, h)) in steps.iter().enumerate() {
        big = model.upscale_to(&big, w, h, &mut |done, _| progress(before + done, all))?;
        before += tiles[i];
    }
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
        let half = upscale_picture(&model, &DynamicImage::ImageRgb8(picture.clone()), 2.0, &mut |_, _| true).unwrap();
        assert_eq!((half.width(), half.height()), (picture.width() * 2, 100));
        assert!(model.upscale(&picture, &mut |_, _| false).is_err());
    }

    #[test]
    fn any_factor_and_the_limits() {
        let model = identity_model(4);
        // A smooth ramp across several tiles: brought down from the model's
        // 4× to 1.5×, 2.5× and 3× it stays a ramp, with no seam at a tile.
        let picture = RgbImage::from_fn(TILE as u32 * 2 + 21, 40, |x, _| image::Rgb([(x * 3 / 4) as u8, 128, 200]));
        let pic = DynamicImage::ImageRgb8(picture.clone());
        for f in [1.5, 2.5, 3.0, 1.1] {
            let big = upscale_picture(&model, &pic, f, &mut |_, _| true).unwrap().to_rgb8();
            assert_eq!(big.width(), (picture.width() as f64 * f).round() as u32, "{f}");
            assert_eq!(big.height(), (40.0 * f).round() as u32, "{f}");
            for x in 0..big.width() {
                // Where this column's centre falls in the original.
                let at = ((x as f64 + 0.5) / (big.width() as f64 / picture.width() as f64) - 0.5).clamp(0.0, (picture.width() - 1) as f64);
                let want = at * 0.75;
                let have = big.get_pixel(x, 10).0[0] as f64;
                assert!((have - want).abs() <= 1.5, "{f}× column {x}: {have} vs {want}");
                assert_eq!(big.get_pixel(x, 0).0[1], 128);
            }
        }
        // Past the model's 4×, it is run again: 6× and 10×.
        let small = DynamicImage::ImageRgb8(RgbImage::from_fn(30, 20, |x, y| image::Rgb([(x * 8) as u8, (y * 12) as u8, 9])));
        let mut seen = Vec::new();
        let six = upscale_picture(&model, &small, 6.0, &mut |d, t| {
            seen.push((d, t));
            true
        })
        .unwrap();
        assert_eq!((six.width(), six.height()), (180, 120));
        // One tile at 30×20, then the 45×30 between, counted together.
        assert_eq!(seen.last(), Some(&(2, 2)));
        assert_eq!(passes((30, 20), (180, 120), 4), vec![(45, 30), (180, 120)]);
        assert_eq!(passes((30, 20), (300, 200), 4), vec![(75, 50), (300, 200)]);
        assert_eq!(passes((30, 20), (60, 40), 4), vec![(60, 40)]);
        let ten = upscale_picture(&model, &small, 10.0, &mut |_, _| true).unwrap().to_rgb8();
        assert_eq!((ten.width(), ten.height()), (300, 200));
        assert_eq!(ten.get_pixel(150, 100).0[2], 9);
        // The limits: by side, by pixels, and the factor itself.
        assert!(upscaled_size(1024, 1024, 8.0).is_err()); // 67 megapixels
        assert_eq!(upscaled_size(1024, 512, 8.0), Ok((8192, 4096)));
        assert!(upscaled_size(2048, 1024, 4.0).is_ok());
        assert!(upscaled_size(2049, 1024, 4.0).is_err());
        assert!(upscaled_size(4000, 4000, 2.0).is_err());
        assert!(upscaled_size(64, 64, 17.0).is_err());
        assert!(upscaled_size(64, 64, 1.0).is_err());
        assert_eq!(upscaled_size(832, 1216, 1.5), Ok((1248, 1824)));
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
