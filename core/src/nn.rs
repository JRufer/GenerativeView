//! The few pieces small convolutional networks are made of, enough to run
//! the face and hand finders on the device: convolutions of any size,
//! stride and grouping (batch norm folded in), the usual activations,
//! pooling, upsampling and joining feature maps. Feature maps are planar
//! f32, channel by channel.

use crate::sr::pth::Tensor;
use gemm::Parallelism;
use std::collections::HashMap;

/// A feature map: `c` channels of `h` × `w`, planar.
#[derive(Debug, Clone)]
pub struct Feat {
    pub c: usize,
    pub h: usize,
    pub w: usize,
    pub data: Vec<f32>,
}

impl Feat {
    pub fn zeros(c: usize, h: usize, w: usize) -> Feat {
        Feat { c, h, w, data: vec![0.0; c * h * w] }
    }

    pub fn plane(&self, c: usize) -> &[f32] {
        let hw = self.h * self.w;
        &self.data[c * hw..(c + 1) * hw]
    }

    /// The channels `from..to` alone.
    pub fn channels(&self, from: usize, to: usize) -> Feat {
        let hw = self.h * self.w;
        Feat { c: to - from, h: self.h, w: self.w, data: self.data[from * hw..to * hw].to_vec() }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Act {
    None,
    Relu,
    Silu,
    Leaky(f32),
    Gelu,
}

fn act(v: &mut [f32], a: Act) {
    match a {
        Act::None => {}
        Act::Relu => v.iter_mut().for_each(|x| *x = x.max(0.0)),
        Act::Silu => v.iter_mut().for_each(|x| *x /= 1.0 + (-*x).exp()),
        Act::Leaky(s) => v.iter_mut().for_each(|x| {
            if *x < 0.0 {
                *x *= s
            }
        }),
        Act::Gelu => gelu(v),
    }
}

/// A 2D convolution with its bias, the batch norm after it folded in, and
/// the activation after that.
#[derive(Debug, Clone)]
pub struct Conv {
    pub cin: usize,
    pub cout: usize,
    pub k: usize,
    pub stride: usize,
    pub pad: usize,
    pub groups: usize,
    /// cout × (cin / groups) × k × k.
    weight: Vec<f32>,
    bias: Vec<f32>,
    pub act: Act,
}

fn threads() -> Parallelism {
    let n = std::thread::available_parallelism().map_or(1, |n| n.get());
    if n > 1 {
        Parallelism::Rayon(n)
    } else {
        Parallelism::None
    }
}

/// Take a named tensor out of a checkpoint's tensors.
pub fn take(t: &mut HashMap<String, Tensor>, name: &str) -> Result<Tensor, String> {
    t.remove(name).ok_or_else(|| format!("the model has no {name}"))
}

impl Conv {
    /// From `weight` (cout × cin/groups × k × k) and an optional bias.
    pub fn new(weight: Tensor, bias: Option<Tensor>, stride: usize, groups: usize, act: Act) -> Result<Conv, String> {
        if weight.shape.len() != 4 || weight.shape[2] != weight.shape[3] {
            return Err(format!("not a square convolution: {:?}", weight.shape));
        }
        let (cout, per, k) = (weight.shape[0], weight.shape[1], weight.shape[2]);
        let bias = match bias {
            Some(b) if b.data.len() == cout => b.data,
            Some(_) => return Err("bias does not fit the convolution".into()),
            None => vec![0.0; cout],
        };
        Ok(Conv { cin: per * groups, cout, k, stride, pad: k / 2, groups, weight: weight.data, bias, act })
    }

    /// `prefix.weight` (and `prefix.bias` if there is one).
    pub fn named(t: &mut HashMap<String, Tensor>, prefix: &str, stride: usize, groups: usize, act: Act) -> Result<Conv, String> {
        let w = take(t, &format!("{prefix}.weight"))?;
        let b = t.remove(&format!("{prefix}.bias"));
        Conv::new(w, b, stride, groups, act)
    }

    /// `conv` then the batch norm `bn`, as PyTorch names them, folded into
    /// one. Batch norm's `eps` is 1e-3 in Ultralytics' models, 1e-5 in most.
    pub fn with_bn(t: &mut HashMap<String, Tensor>, conv: &str, bn: &str, stride: usize, groups: usize, act: Act, eps: f32) -> Result<Conv, String> {
        let mut c = Conv::new(take(t, &format!("{conv}.weight"))?, t.remove(&format!("{conv}.bias")), stride, groups, act)?;
        let g = take(t, &format!("{bn}.weight"))?.data;
        let b = take(t, &format!("{bn}.bias"))?.data;
        let m = take(t, &format!("{bn}.running_mean"))?.data;
        let v = take(t, &format!("{bn}.running_var"))?.data;
        if g.len() != c.cout {
            return Err(format!("{bn} does not fit {conv}"));
        }
        let per = c.weight.len() / c.cout;
        for o in 0..c.cout {
            let s = g[o] / (v[o] + eps).sqrt();
            c.weight[o * per..(o + 1) * per].iter_mut().for_each(|w| *w *= s);
            c.bias[o] = (c.bias[o] - m[o]) * s + b[o];
        }
        Ok(c)
    }

    fn out_size(&self, n: usize) -> usize {
        (n + 2 * self.pad - self.k) / self.stride + 1
    }

    pub fn forward(&self, x: &Feat) -> Result<Feat, String> {
        if x.c != self.cin {
            return Err(format!("a convolution for {} channels was given {}", self.cin, x.c));
        }
        let (oh, ow) = (self.out_size(x.h), self.out_size(x.w));
        let ohw = oh * ow;
        let mut out = Feat::zeros(self.cout, oh, ow);
        if self.groups == 1 {
            self.dense(x, &mut out);
        } else if self.groups == self.cin && self.groups == self.cout {
            self.depthwise(x, &mut out);
        } else {
            return Err("only plain and depthwise convolutions are supported".into());
        }
        for (o, plane) in out.data.chunks_exact_mut(ohw).enumerate() {
            let b = self.bias[o];
            plane.iter_mut().for_each(|v| *v += b);
            act(plane, self.act);
        }
        Ok(out)
    }

    /// im2col, then one matrix product.
    fn dense(&self, x: &Feat, out: &mut Feat) {
        let (k, s, p) = (self.k, self.stride, self.pad as isize);
        let (oh, ow) = (out.h, out.w);
        let ohw = oh * ow;
        let rows = self.cin * k * k;
        let cols: std::borrow::Cow<[f32]> = if k == 1 && s == 1 {
            std::borrow::Cow::Borrowed(&x.data)
        } else {
            let mut cols = vec![0.0f32; rows * ohw];
            for c in 0..self.cin {
                let plane = x.plane(c);
                for dy in 0..k {
                    for dx in 0..k {
                        let row = &mut cols[((c * k + dy) * k + dx) * ohw..][..ohw];
                        for y in 0..oh {
                            let sy = (y * s) as isize + dy as isize - p;
                            if sy < 0 || sy >= x.h as isize {
                                continue;
                            }
                            let src = &plane[sy as usize * x.w..][..x.w];
                            let dst = &mut row[y * ow..][..ow];
                            for (xo, d) in dst.iter_mut().enumerate() {
                                let sx = (xo * s) as isize + dx as isize - p;
                                if sx >= 0 && sx < x.w as isize {
                                    *d = src[sx as usize];
                                }
                            }
                        }
                    }
                }
            }
            std::borrow::Cow::Owned(cols)
        };
        // SAFETY: out is cout×ohw, weight cout×rows, cols rows×ohw, all
        // row-major, as the strides say.
        unsafe {
            gemm::gemm(
                self.cout,
                ohw,
                rows,
                out.data.as_mut_ptr(),
                1,
                ohw as isize,
                false,
                self.weight.as_ptr(),
                1,
                rows as isize,
                cols.as_ptr(),
                1,
                ohw as isize,
                0.0,
                1.0,
                false,
                false,
                false,
                threads(),
            );
        }
    }

    fn depthwise(&self, x: &Feat, out: &mut Feat) {
        use rayon::prelude::*;
        let (k, s, p) = (self.k, self.stride, self.pad as isize);
        let (oh, ow) = (out.h, out.w);
        out.data.par_chunks_exact_mut(oh * ow).enumerate().for_each(|(c, dst)| {
            let plane = x.plane(c);
            let w = &self.weight[c * k * k..(c + 1) * k * k];
            for y in 0..oh {
                for xo in 0..ow {
                    let mut sum = 0.0;
                    for dy in 0..k {
                        let sy = (y * s) as isize + dy as isize - p;
                        if sy < 0 || sy >= x.h as isize {
                            continue;
                        }
                        for dx in 0..k {
                            let sx = (xo * s) as isize + dx as isize - p;
                            if sx >= 0 && sx < x.w as isize {
                                sum += plane[sy as usize * x.w + sx as usize] * w[dy * k + dx];
                            }
                        }
                    }
                    dst[y * ow + xo] = sum;
                }
            }
        });
    }
}

// ---------------------------------------------------------------- transformers

/// `a` (m × k) times `b` (k × n), both row-major; `bt` says `b` is given
/// transposed (n × k), as a linear layer's weight is.
pub fn matmul(a: &[f32], b: &[f32], m: usize, k: usize, n: usize, bt: bool) -> Vec<f32> {
    let mut out = vec![0.0f32; m * n];
    let (b_cs, b_rs) = if bt { (k as isize, 1) } else { (1, n as isize) };
    // SAFETY: the sizes and strides are those of the slices.
    unsafe {
        gemm::gemm(m, n, k, out.as_mut_ptr(), 1, n as isize, false, a.as_ptr(), 1, k as isize, b.as_ptr(), b_cs, b_rs, 0.0, 1.0, false, false, false, threads());
    }
    out
}

/// A linear layer: `weight` out × in, and a bias.
#[derive(Debug, Clone)]
pub struct Linear {
    pub inputs: usize,
    pub outputs: usize,
    weight: Vec<f32>,
    bias: Vec<f32>,
}

impl Linear {
    pub fn named(t: &mut HashMap<String, Tensor>, prefix: &str) -> Result<Linear, String> {
        let w = take(t, &format!("{prefix}.weight"))?;
        if w.shape.len() != 2 {
            return Err(format!("{prefix} is not a linear layer"));
        }
        let (outputs, inputs) = (w.shape[0], w.shape[1]);
        let bias = t.remove(&format!("{prefix}.bias")).map(|b| b.data).unwrap_or_else(|| vec![0.0; outputs]);
        Ok(Linear { inputs, outputs, weight: w.data, bias })
    }

    /// `rows` (n × inputs) to n × outputs.
    pub fn apply(&self, rows: &[f32]) -> Vec<f32> {
        let n = rows.len() / self.inputs;
        let mut out = matmul(rows, &self.weight, n, self.inputs, self.outputs, true);
        for row in out.chunks_exact_mut(self.outputs) {
            row.iter_mut().zip(&self.bias).for_each(|(v, b)| *v += b);
        }
        out
    }
}

/// Layer norm over each row of `width`.
#[derive(Debug, Clone)]
pub struct Norm {
    weight: Vec<f32>,
    bias: Vec<f32>,
    eps: f32,
}

impl Norm {
    pub fn named(t: &mut HashMap<String, Tensor>, prefix: &str, eps: f32) -> Result<Norm, String> {
        Ok(Norm { weight: take(t, &format!("{prefix}.weight"))?.data, bias: take(t, &format!("{prefix}.bias"))?.data, eps })
    }

    pub fn apply(&self, rows: &mut [f32]) {
        let w = self.weight.len();
        for row in rows.chunks_exact_mut(w) {
            let mean = row.iter().sum::<f32>() / w as f32;
            let var = row.iter().map(|v| (v - mean) * (v - mean)).sum::<f32>() / w as f32;
            let inv = 1.0 / (var + self.eps).sqrt();
            for (i, v) in row.iter_mut().enumerate() {
                *v = (*v - mean) * inv * self.weight[i] + self.bias[i];
            }
        }
    }

    /// Over the channels at each place of a planar feature map, as SAM's
    /// LayerNorm2d does.
    pub fn apply_channels(&self, x: &mut Feat) {
        let hw = x.h * x.w;
        for at in 0..hw {
            let mean = (0..x.c).map(|c| x.data[c * hw + at]).sum::<f32>() / x.c as f32;
            let var = (0..x.c).map(|c| (x.data[c * hw + at] - mean).powi(2)).sum::<f32>() / x.c as f32;
            let inv = 1.0 / (var + self.eps).sqrt();
            for c in 0..x.c {
                let v = &mut x.data[c * hw + at];
                *v = (*v - mean) * inv * self.weight[c] + self.bias[c];
            }
        }
    }
}

/// The error function, to about seven decimal places (Abramowitz & Stegun
/// 7.1.26).
fn erf(x: f32) -> f32 {
    let t = 1.0 / (1.0 + 0.327_591_1 * x.abs());
    let poly = t * (0.254_829_592 + t * (-0.284_496_736 + t * (1.421_413_741 + t * (-1.453_152_027 + t * 1.061_405_429))));
    let y = 1.0 - poly * (-x * x).exp();
    if x < 0.0 {
        -y
    } else {
        y
    }
}

pub fn gelu(v: &mut [f32]) {
    use rayon::prelude::*;
    v.par_chunks_mut(4096).for_each(|c| c.iter_mut().for_each(|x| *x = 0.5 * *x * (1.0 + erf(*x * std::f32::consts::FRAC_1_SQRT_2))));
}

pub fn relu_rows(v: &mut [f32]) {
    v.iter_mut().for_each(|x| *x = x.max(0.0));
}

/// Softmax over each row of `width`, in place.
pub fn softmax_rows(v: &mut [f32], width: usize) {
    for row in v.chunks_exact_mut(width) {
        let m = row.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
        let mut sum = 0.0;
        row.iter_mut().for_each(|x| {
            *x = (*x - m).exp();
            sum += *x;
        });
        row.iter_mut().for_each(|x| *x /= sum);
    }
}

/// Planar `c × h × w` as `h·w` rows of `c`, and back.
pub fn to_rows(x: &Feat) -> Vec<f32> {
    let hw = x.h * x.w;
    let mut out = vec![0.0; x.data.len()];
    for c in 0..x.c {
        for at in 0..hw {
            out[at * x.c + c] = x.data[c * hw + at];
        }
    }
    out
}

pub fn from_rows(rows: &[f32], c: usize, h: usize, w: usize) -> Feat {
    let hw = h * w;
    let mut data = vec![0.0; c * hw];
    for at in 0..hw {
        for ch in 0..c {
            data[ch * hw + at] = rows[at * c + ch];
        }
    }
    Feat { c, h, w, data }
}

/// Max pooling, `k` square, stride 1, padded to keep the size.
pub fn max_pool_same(x: &Feat, k: usize) -> Feat {
    let p = (k / 2) as isize;
    let mut out = Feat::zeros(x.c, x.h, x.w);
    for c in 0..x.c {
        let src = x.plane(c);
        let hw = x.h * x.w;
        let dst = &mut out.data[c * hw..(c + 1) * hw];
        for y in 0..x.h {
            for xo in 0..x.w {
                let mut m = f32::NEG_INFINITY;
                for dy in -p..=p {
                    let sy = y as isize + dy;
                    if sy < 0 || sy >= x.h as isize {
                        continue;
                    }
                    for dx in -p..=p {
                        let sx = xo as isize + dx;
                        if sx >= 0 && sx < x.w as isize {
                            m = m.max(src[sy as usize * x.w + sx as usize]);
                        }
                    }
                }
                dst[y * x.w + xo] = m;
            }
        }
    }
    out
}

/// Nearest-neighbour resize to `h` × `w` (twice the size, usually), as
/// PyTorch's `interpolate(mode="nearest")` picks.
pub fn upsample_nearest(x: &Feat, h: usize, w: usize) -> Feat {
    let mut out = Feat::zeros(x.c, h, w);
    for c in 0..x.c {
        let src = x.plane(c);
        let dst = &mut out.data[c * h * w..(c + 1) * h * w];
        for y in 0..h {
            let sy = (y * x.h / h).min(x.h - 1);
            for xo in 0..w {
                let sx = (xo * x.w / w).min(x.w - 1);
                dst[y * w + xo] = src[sy * x.w + sx];
            }
        }
    }
    out
}

/// The channels of each, one after another. All the same size.
pub fn concat(parts: &[&Feat]) -> Feat {
    let (h, w) = (parts[0].h, parts[0].w);
    let mut data = Vec::with_capacity(parts.iter().map(|p| p.data.len()).sum());
    for p in parts {
        data.extend_from_slice(&p.data);
    }
    Feat { c: parts.iter().map(|p| p.c).sum(), h, w, data }
}

/// `a` + `b`, in place in `a`.
pub fn add(a: &mut Feat, b: &Feat) {
    a.data.iter_mut().zip(&b.data).for_each(|(x, y)| *x += y);
}

pub fn relu(x: &mut Feat) {
    act(&mut x.data, Act::Relu);
}

/// A box, in pixels: left, top, right, bottom; and how sure.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Found {
    pub x0: f32,
    pub y0: f32,
    pub x1: f32,
    pub y1: f32,
    pub score: f32,
}

impl Found {
    fn area(&self) -> f32 {
        (self.x1 - self.x0).max(0.0) * (self.y1 - self.y0).max(0.0)
    }

    pub fn iou(&self, o: &Found) -> f32 {
        let w = (self.x1.min(o.x1) - self.x0.max(o.x0)).max(0.0);
        let h = (self.y1.min(o.y1) - self.y0.max(o.y0)).max(0.0);
        let both = w * h;
        let either = self.area() + o.area() - both;
        if either <= 0.0 {
            0.0
        } else {
            both / either
        }
    }
}

/// The boxes that are not mostly another, surer one (by `iou`), surest
/// first.
pub fn nms(mut boxes: Vec<Found>, iou: f32) -> Vec<Found> {
    boxes.sort_by(|a, b| b.score.total_cmp(&a.score));
    let mut kept: Vec<Found> = Vec::new();
    for b in boxes {
        if kept.iter().all(|k| k.iou(&b) < iou) {
            kept.push(b);
        }
    }
    kept
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tensor(shape: &[usize], data: Vec<f32>) -> Tensor {
        Tensor { shape: shape.to_vec(), data }
    }

    #[test]
    fn a_strided_convolution_with_padding() {
        // One channel in, one out, 3×3 of ones: each output sums the 3×3
        // around every other pixel.
        let conv = Conv::new(tensor(&[1, 1, 3, 3], vec![1.0; 9]), None, 2, 1, Act::None).unwrap();
        let x = Feat { c: 1, h: 4, w: 4, data: (1..=16).map(|v| v as f32).collect() };
        let y = conv.forward(&x).unwrap();
        assert_eq!((y.h, y.w), (2, 2));
        // Top-left: 1+2+5+6 (the rest is padding).
        assert_eq!(y.data[0], 14.0);
        // Bottom-right, centred on 11: 6+7+8+10+11+12+14+15+16.
        assert_eq!(y.data[3], 99.0);
    }

    #[test]
    fn depthwise_keeps_channels_apart() {
        let conv = Conv::new(tensor(&[2, 1, 1, 1], vec![2.0, -1.0]), Some(tensor(&[2], vec![0.5, 0.0])), 1, 2, Act::Relu).unwrap();
        let x = Feat { c: 2, h: 1, w: 2, data: vec![1.0, 2.0, 3.0, 4.0] };
        let y = conv.forward(&x).unwrap();
        assert_eq!(y.data, vec![2.5, 4.5, 0.0, 0.0]);
    }

    #[test]
    fn a_product_with_the_second_given_transposed() {
        // [1 2; 3 4] × [5 6; 7 8] = [19 22; 43 50], and with B given as its
        // transpose, the same.
        let a = [1.0, 2.0, 3.0, 4.0];
        assert_eq!(matmul(&a, &[5.0, 6.0, 7.0, 8.0], 2, 2, 2, false), vec![19.0, 22.0, 43.0, 50.0]);
        assert_eq!(matmul(&a, &[5.0, 7.0, 6.0, 8.0], 2, 2, 2, true), vec![19.0, 22.0, 43.0, 50.0]);
        // Not square: 1×3 times 3×2.
        assert_eq!(matmul(&[1.0, 2.0, 3.0], &[1.0, 0.0, 0.0, 1.0, 1.0, 1.0], 1, 3, 2, false), vec![4.0, 5.0]);
    }

    #[test]
    fn overlapping_boxes_keep_the_surer() {
        let a = Found { x0: 0.0, y0: 0.0, x1: 10.0, y1: 10.0, score: 0.9 };
        let b = Found { x0: 1.0, y0: 1.0, x1: 10.0, y1: 10.0, score: 0.8 };
        let c = Found { x0: 20.0, y0: 20.0, x1: 30.0, y1: 30.0, score: 0.5 };
        assert_eq!(nms(vec![b, c, a], 0.5), vec![a, c]);
    }
}
