//! Tap to select: MobileSAM (Apache 2.0), on the device. The picture is
//! encoded once by TinyViT into a 64 × 64 map of 256 features; each tap is
//! then a point prompt through SAM's prompt encoder and mask decoder, and
//! the mask's edge, traced and simplified, is the outline handed back.
//!
//! The model (`model.safetensors`, MobileSAM as its authors name the
//! layers) is downloaded by the app the first time Select is used.

use crate::nn::{self, from_rows, gelu, matmul, softmax_rows, to_rows, Act, Conv, Feat, Linear, Norm};
use crate::sr::pth::Tensor;
use image::{imageops::FilterType, DynamicImage};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub const FILE: &str = "model.safetensors";

pub fn model_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("models").join("mobilesam")
}

const SIDE: usize = 1024;
const MEAN: [f32; 3] = [123.675, 116.28, 103.53];
const STD: [f32; 3] = [58.395, 57.12, 57.375];

type T = HashMap<String, Tensor>;

fn cbn(t: &mut T, p: &str, stride: usize, groups: usize, act: Act) -> Result<Conv, String> {
    Conv::with_bn(t, &format!("{p}.c"), &format!("{p}.bn"), stride, groups, act, 1e-5)
}

// ---------------------------------------------------------------- TinyViT

struct MbConv {
    c1: Conv,
    c2: Conv,
    c3: Conv,
}

struct Merge {
    c1: Conv,
    c2: Conv,
    c3: Conv,
}

impl Merge {
    fn load(t: &mut T, p: &str) -> Result<Merge, String> {
        let c1 = cbn(t, &format!("{p}.conv1"), 1, 1, Act::Gelu)?;
        let out = c1.cout;
        // MobileSAM keeps the last downsample at stride 1, so the map stays
        // 64 × 64.
        let stride = if matches!(out, 320 | 448 | 576) { 1 } else { 2 };
        Ok(Merge { c1, c2: cbn(t, &format!("{p}.conv2"), stride, out, Act::Gelu)?, c3: cbn(t, &format!("{p}.conv3"), 1, 1, Act::None)? })
    }

    fn forward(&self, x: &Feat) -> Result<Feat, String> {
        self.c3.forward(&self.c2.forward(&self.c1.forward(x)?)?)
    }
}

struct Attention {
    norm: Norm,
    qkv: Linear,
    proj: Linear,
    heads: usize,
    key_dim: usize,
    /// heads × n × n, for a window of n tokens.
    bias: Vec<f32>,
}

impl Attention {
    fn load(t: &mut T, p: &str, dim: usize, heads: usize, window: usize) -> Result<Attention, String> {
        let biases = nn::take(t, &format!("{p}.attention_biases"))?;
        // Each pair of places in the window shares a bias with every pair
        // the same distance apart, numbered in the order first met.
        let points: Vec<(usize, usize)> = (0..window).flat_map(|a| (0..window).map(move |b| (a, b))).collect();
        let n = points.len();
        let mut offsets: HashMap<(usize, usize), usize> = HashMap::new();
        let mut idx = Vec::with_capacity(n * n);
        for p1 in &points {
            for p2 in &points {
                let off = (p1.0.abs_diff(p2.0), p1.1.abs_diff(p2.1));
                let next = offsets.len();
                idx.push(*offsets.entry(off).or_insert(next));
            }
        }
        let per = biases.shape[1];
        if offsets.len() != per {
            return Err(format!("{p}: {per} biases for a window that needs {}", offsets.len()));
        }
        let mut bias = vec![0.0; heads * n * n];
        for h in 0..heads {
            for (i, &k) in idx.iter().enumerate() {
                bias[h * n * n + i] = biases.data[h * per + k];
            }
        }
        Ok(Attention {
            norm: Norm::named(t, &format!("{p}.norm"), 1e-5)?,
            qkv: Linear::named(t, &format!("{p}.qkv"))?,
            proj: Linear::named(t, &format!("{p}.proj"))?,
            heads,
            key_dim: dim / heads,
            bias,
        })
    }

    /// One window of `n` tokens of `dim`.
    fn forward(&self, x: &mut [f32], n: usize) -> Vec<f32> {
        self.norm.apply(x);
        let qkv = self.qkv.apply(x);
        let (h, kd) = (self.heads, self.key_dim);
        let width = h * 3 * kd;
        let scale = (kd as f32).powf(-0.5);
        let mut out = vec![0.0; n * h * kd];
        for head in 0..h {
            // Each head's q, k and v sit together in its slice of qkv.
            let base = head * 3 * kd;
            let pick = |o: usize| -> Vec<f32> { (0..n).flat_map(|i| qkv[i * width + base + o..i * width + base + o + kd].iter().cloned()).collect() };
            let (q, k, v) = (pick(0), pick(kd), pick(2 * kd));
            let mut att = matmul(&q, &k, n, kd, n, true);
            let b = &self.bias[head * n * n..(head + 1) * n * n];
            att.iter_mut().zip(b).for_each(|(a, b)| *a = *a * scale + b);
            softmax_rows(&mut att, n);
            let o = matmul(&att, &v, n, n, kd, false);
            for i in 0..n {
                out[i * h * kd + head * kd..i * h * kd + (head + 1) * kd].copy_from_slice(&o[i * kd..(i + 1) * kd]);
            }
        }
        self.proj.apply(&out)
    }
}

struct Block {
    attn: Attention,
    local: Conv,
    norm: Norm,
    fc1: Linear,
    fc2: Linear,
    window: usize,
}

impl Block {
    /// `x`: the map's tokens, row by row, `dim` each.
    fn forward(&self, x: &mut Vec<f32>, res: usize, dim: usize) -> Result<(), String> {
        let ws = self.window;
        let pad = (ws - res % ws) % ws;
        let p = res + pad;
        let nw = p / ws;
        let n = ws * ws;
        // Windows, padded with zeros past the map's edge.
        let mut attended = vec![0.0; res * res * dim];
        for wy in 0..nw {
            for wx in 0..nw {
                let mut win = vec![0.0; n * dim];
                for y in 0..ws {
                    for xx in 0..ws {
                        let (gy, gx) = (wy * ws + y, wx * ws + xx);
                        if gy < res && gx < res {
                            let src = (gy * res + gx) * dim;
                            win[(y * ws + xx) * dim..][..dim].copy_from_slice(&x[src..src + dim]);
                        }
                    }
                }
                let out = self.attn.forward(&mut win, n);
                for y in 0..ws {
                    for xx in 0..ws {
                        let (gy, gx) = (wy * ws + y, wx * ws + xx);
                        if gy < res && gx < res {
                            let dst = (gy * res + gx) * dim;
                            attended[dst..dst + dim].copy_from_slice(&out[(y * ws + xx) * dim..][..dim]);
                        }
                    }
                }
            }
        }
        x.iter_mut().zip(&attended).for_each(|(a, b)| *a += b);
        // The depthwise local convolution, on the map.
        let map = self.local.forward(&from_rows(x, dim, res, res))?;
        *x = to_rows(&map);
        // Then the MLP, added.
        let mut m = x.clone();
        self.norm.apply(&mut m);
        let mut hidden = self.fc1.apply(&m);
        gelu(&mut hidden);
        let out = self.fc2.apply(&hidden);
        x.iter_mut().zip(&out).for_each(|(a, b)| *a += b);
        Ok(())
    }
}

struct Stage {
    blocks: Vec<Block>,
    dim: usize,
    merge: Option<Merge>,
}

pub struct Encoder {
    embed: (Conv, Conv),
    mbconv: Vec<MbConv>,
    merge0: Merge,
    stages: Vec<Stage>,
    neck: (Conv, Norm, Conv, Norm),
}

impl Encoder {
    fn load(t: &mut T) -> Result<Encoder, String> {
        let p = "image_encoder";
        let embed = (cbn(t, &format!("{p}.patch_embed.seq.0"), 2, 1, Act::Gelu)?, cbn(t, &format!("{p}.patch_embed.seq.2"), 2, 1, Act::None)?);
        let mut mbconv = Vec::new();
        while t.contains_key(&format!("{p}.layers.0.blocks.{}.conv1.c.weight", mbconv.len())) {
            let b = format!("{p}.layers.0.blocks.{}", mbconv.len());
            let c1 = cbn(t, &format!("{b}.conv1"), 1, 1, Act::Gelu)?;
            let hidden = c1.cout;
            mbconv.push(MbConv { c1, c2: cbn(t, &format!("{b}.conv2"), 1, hidden, Act::Gelu)?, c3: cbn(t, &format!("{b}.conv3"), 1, 1, Act::None)? });
        }
        let merge0 = Merge::load(t, &format!("{p}.layers.0.downsample"))?;
        // Heads and windows per stage, as MobileSAM's TinyViT has them.
        let shape = [(4usize, 7usize), (5, 14), (10, 7)];
        let mut stages = Vec::new();
        for (i, (heads, window)) in shape.iter().enumerate() {
            let l = format!("{p}.layers.{}", i + 1);
            let mut blocks = Vec::new();
            let mut dim = 0;
            while t.contains_key(&format!("{l}.blocks.{}.attn.qkv.weight", blocks.len())) {
                let b = format!("{l}.blocks.{}", blocks.len());
                dim = t[&format!("{b}.attn.norm.weight")].shape[0];
                blocks.push(Block {
                    attn: Attention::load(t, &format!("{b}.attn"), dim, *heads, *window)?,
                    local: cbn(t, &format!("{b}.local_conv"), 1, dim, Act::None)?,
                    norm: Norm::named(t, &format!("{b}.mlp.norm"), 1e-5)?,
                    fc1: Linear::named(t, &format!("{b}.mlp.fc1"))?,
                    fc2: Linear::named(t, &format!("{b}.mlp.fc2"))?,
                    window: *window,
                });
            }
            let merge = if t.contains_key(&format!("{l}.downsample.conv1.c.weight")) { Some(Merge::load(t, &format!("{l}.downsample"))?) } else { None };
            stages.push(Stage { blocks, dim, merge });
        }
        let neck = (
            Conv::named(t, &format!("{p}.neck.0"), 1, 1, Act::None)?,
            Norm::named(t, &format!("{p}.neck.1"), 1e-6)?,
            Conv::named(t, &format!("{p}.neck.2"), 1, 1, Act::None)?,
            Norm::named(t, &format!("{p}.neck.3"), 1e-6)?,
        );
        Ok(Encoder { embed, mbconv, merge0, stages, neck })
    }

    /// The picture's features: 256 × 64 × 64.
    fn forward(&self, x: &Feat) -> Result<Feat, String> {
        let mut f = self.embed.1.forward(&self.embed.0.forward(x)?)?;
        for b in &self.mbconv {
            let mut y = b.c3.forward(&b.c2.forward(&b.c1.forward(&f)?)?)?;
            nn::add(&mut y, &f);
            nn::gelu(&mut y.data);
            f = y;
        }
        let mut map = self.merge0.forward(&f)?;
        for s in &self.stages {
            let res = map.h;
            let mut rows = to_rows(&map);
            for b in &s.blocks {
                b.forward(&mut rows, res, s.dim)?;
            }
            map = from_rows(&rows, s.dim, res, res);
            if let Some(m) = &s.merge {
                map = m.forward(&map)?;
            }
        }
        let mut y = self.neck.0.forward(&map)?;
        self.neck.1.apply_channels(&mut y);
        let mut y = self.neck.2.forward(&y)?;
        self.neck.3.apply_channels(&mut y);
        Ok(y)
    }
}

// ---------------------------------------------------------------- decoder

struct Attn {
    q: Linear,
    k: Linear,
    v: Linear,
    out: Linear,
    heads: usize,
}

impl Attn {
    fn load(t: &mut T, p: &str) -> Result<Attn, String> {
        Ok(Attn {
            q: Linear::named(t, &format!("{p}.q_proj"))?,
            k: Linear::named(t, &format!("{p}.k_proj"))?,
            v: Linear::named(t, &format!("{p}.v_proj"))?,
            out: Linear::named(t, &format!("{p}.out_proj"))?,
            heads: 8,
        })
    }

    /// `q` (nq rows), `k` and `v` (nk rows), each of the model's 256.
    fn forward(&self, q: &[f32], k: &[f32], v: &[f32]) -> Vec<f32> {
        let (q, k, v) = (self.q.apply(q), self.k.apply(k), self.v.apply(v));
        let inner = self.q.outputs;
        let (nq, nk) = (q.len() / inner, k.len() / inner);
        let per = inner / self.heads;
        let scale = 1.0 / (per as f32).sqrt();
        let mut out = vec![0.0; nq * inner];
        for h in 0..self.heads {
            let pick = |m: &[f32], n: usize| -> Vec<f32> { (0..n).flat_map(|i| m[i * inner + h * per..i * inner + (h + 1) * per].iter().cloned()).collect() };
            let (qh, kh, vh) = (pick(&q, nq), pick(&k, nk), pick(&v, nk));
            let mut att = matmul(&qh, &kh, nq, per, nk, true);
            att.iter_mut().for_each(|a| *a *= scale);
            softmax_rows(&mut att, nk);
            let o = matmul(&att, &vh, nq, nk, per, false);
            for i in 0..nq {
                out[i * inner + h * per..i * inner + (h + 1) * per].copy_from_slice(&o[i * per..(i + 1) * per]);
            }
        }
        self.out.apply(&out)
    }
}

struct TwoWay {
    self_attn: Attn,
    norm1: Norm,
    to_image: Attn,
    norm2: Norm,
    lin1: Linear,
    lin2: Linear,
    norm3: Norm,
    norm4: Norm,
    to_token: Attn,
}

fn add(a: &[f32], b: &[f32]) -> Vec<f32> {
    a.iter().zip(b).map(|(x, y)| x + y).collect()
}

fn add_into(a: &mut [f32], b: &[f32]) {
    a.iter_mut().zip(b).for_each(|(x, y)| *x += y);
}

/// A small MLP, ReLU between its layers.
struct Mlp(Vec<Linear>);

impl Mlp {
    fn load(t: &mut T, p: &str) -> Result<Mlp, String> {
        let mut layers = Vec::new();
        while t.contains_key(&format!("{p}.layers.{}.weight", layers.len())) {
            layers.push(Linear::named(t, &format!("{p}.layers.{}", layers.len()))?);
        }
        Ok(Mlp(layers))
    }

    fn apply(&self, x: &[f32]) -> Vec<f32> {
        let mut y = x.to_vec();
        for (i, l) in self.0.iter().enumerate() {
            y = l.apply(&y);
            if i + 1 < self.0.len() {
                nn::relu_rows(&mut y);
            }
        }
        y
    }
}

pub struct Decoder {
    gaussian: Vec<f32>,
    point_embeddings: Vec<Vec<f32>>,
    not_a_point: Vec<f32>,
    no_mask: Vec<f32>,
    iou_token: Vec<f32>,
    mask_tokens: Vec<f32>,
    layers: Vec<TwoWay>,
    final_attn: Attn,
    norm_final: Norm,
    up1: (Vec<f32>, Vec<f32>),
    up_norm: Norm,
    up2: (Vec<f32>, Vec<f32>),
    hyper: Vec<Mlp>,
    iou_head: Mlp,
}

/// A 2 × 2, stride 2 transposed convolution: weight in × out × 2 × 2.
fn conv_t2(x: &Feat, w: &[f32], b: &[f32]) -> Feat {
    let cout = b.len();
    let (h, wd) = (x.h, x.w);
    let mut out = Feat::zeros(cout, h * 2, wd * 2);
    let rows = to_rows(x); // hw × cin
    // For each of the four offsets, a product: (hw × cin) × (cin × cout).
    for dy in 0..2 {
        for dx in 0..2 {
            let k: Vec<f32> = (0..x.c).flat_map(|c| (0..cout).map(move |o| (c, o))).map(|(c, o)| w[((c * cout + o) * 2 + dy) * 2 + dx]).collect();
            let y = matmul(&rows, &k, h * wd, x.c, cout, false);
            for at in 0..h * wd {
                let (yy, xx) = (at / wd, at % wd);
                let dst = (2 * yy + dy) * (2 * wd) + 2 * xx + dx;
                for o in 0..cout {
                    out.data[o * 4 * h * wd + dst] = y[at * cout + o] + b[o];
                }
            }
        }
    }
    out
}

impl Decoder {
    fn load(t: &mut T) -> Result<Decoder, String> {
        let pe = "prompt_encoder";
        let md = "mask_decoder";
        let mut layers = Vec::new();
        while t.contains_key(&format!("{md}.transformer.layers.{}.norm1.weight", layers.len())) {
            let l = format!("{md}.transformer.layers.{}", layers.len());
            layers.push(TwoWay {
                self_attn: Attn::load(t, &format!("{l}.self_attn"))?,
                norm1: Norm::named(t, &format!("{l}.norm1"), 1e-5)?,
                to_image: Attn::load(t, &format!("{l}.cross_attn_token_to_image"))?,
                norm2: Norm::named(t, &format!("{l}.norm2"), 1e-5)?,
                lin1: Linear::named(t, &format!("{l}.mlp.lin1"))?,
                lin2: Linear::named(t, &format!("{l}.mlp.lin2"))?,
                norm3: Norm::named(t, &format!("{l}.norm3"), 1e-5)?,
                norm4: Norm::named(t, &format!("{l}.norm4"), 1e-5)?,
                to_token: Attn::load(t, &format!("{l}.cross_attn_image_to_token"))?,
            });
        }
        let mut hyper = Vec::new();
        while t.contains_key(&format!("{md}.output_hypernetworks_mlps.{}.layers.0.weight", hyper.len())) {
            hyper.push(Mlp::load(t, &format!("{md}.output_hypernetworks_mlps.{}", hyper.len()))?);
        }
        let mut points = Vec::new();
        while let Some(p) = t.remove(&format!("{pe}.point_embeddings.{}.weight", points.len())) {
            points.push(p.data);
        }
        Ok(Decoder {
            gaussian: nn::take(t, &format!("{pe}.pe_layer.positional_encoding_gaussian_matrix"))?.data,
            point_embeddings: points,
            not_a_point: nn::take(t, &format!("{pe}.not_a_point_embed.weight"))?.data,
            no_mask: nn::take(t, &format!("{pe}.no_mask_embed.weight"))?.data,
            iou_token: nn::take(t, &format!("{md}.iou_token.weight"))?.data,
            mask_tokens: nn::take(t, &format!("{md}.mask_tokens.weight"))?.data,
            layers,
            final_attn: Attn::load(t, &format!("{md}.transformer.final_attn_token_to_image"))?,
            norm_final: Norm::named(t, &format!("{md}.transformer.norm_final_attn"), 1e-5)?,
            up1: (nn::take(t, &format!("{md}.output_upscaling.0.weight"))?.data, nn::take(t, &format!("{md}.output_upscaling.0.bias"))?.data),
            up_norm: Norm::named(t, &format!("{md}.output_upscaling.1"), 1e-6)?,
            up2: (nn::take(t, &format!("{md}.output_upscaling.3.weight"))?.data, nn::take(t, &format!("{md}.output_upscaling.3.bias"))?.data),
            hyper,
            iou_head: Mlp::load(t, &format!("{md}.iou_prediction_head"))?,
        })
    }

    /// Random Fourier features of a point given in 0..1 both ways.
    fn pe(&self, x: f32, y: f32) -> Vec<f32> {
        let half = self.gaussian.len() / 2;
        let (x, y) = (2.0 * x - 1.0, 2.0 * y - 1.0);
        let mut out = vec![0.0; 2 * half];
        for j in 0..half {
            let v = 2.0 * std::f32::consts::PI * (x * self.gaussian[j] + y * self.gaussian[half + j]);
            out[j] = v.sin();
            out[half + j] = v.cos();
        }
        out
    }

    /// The mask's logits (256 × 256, for the 1024 input) for one point at
    /// (x, y) in input pixels, the best of its three masks by predicted IoU.
    fn decode(&self, emb: &Feat, x: f32, y: f32) -> Vec<f32> {
        let d = emb.c;
        let (h, w) = (emb.h, emb.w);
        // The point, and a padding point after it.
        let mut point = self.pe((x + 0.5) / SIDE as f32, (y + 0.5) / SIDE as f32);
        add_into(&mut point, &self.point_embeddings[1]);
        let mut tokens = Vec::with_capacity(7 * d);
        tokens.extend_from_slice(&self.iou_token);
        tokens.extend_from_slice(&self.mask_tokens);
        tokens.extend_from_slice(&point);
        tokens.extend_from_slice(&self.not_a_point);
        // The image, with no mask given, and its position encoding.
        let mut keys = to_rows(emb);
        for row in keys.chunks_exact_mut(d) {
            add_into(row, &self.no_mask);
        }
        let mut key_pe = Vec::with_capacity(h * w * d);
        for yy in 0..h {
            for xx in 0..w {
                key_pe.extend(self.pe((xx as f32 + 0.5) / w as f32, (yy as f32 + 0.5) / h as f32));
            }
        }
        let query_pe = tokens.clone();
        let mut queries = tokens;
        for (i, l) in self.layers.iter().enumerate() {
            if i == 0 {
                queries = l.self_attn.forward(&queries, &queries, &queries);
            } else {
                let q = add(&queries, &query_pe);
                let a = l.self_attn.forward(&q, &q, &queries);
                add_into(&mut queries, &a);
            }
            l.norm1.apply(&mut queries);
            let q = add(&queries, &query_pe);
            let k = add(&keys, &key_pe);
            let a = l.to_image.forward(&q, &k, &keys);
            add_into(&mut queries, &a);
            l.norm2.apply(&mut queries);
            let mut m = l.lin1.apply(&queries);
            nn::relu_rows(&mut m);
            let m = l.lin2.apply(&m);
            add_into(&mut queries, &m);
            l.norm3.apply(&mut queries);
            let q = add(&queries, &query_pe);
            let k = add(&keys, &key_pe);
            let a = l.to_token.forward(&k, &q, &queries);
            add_into(&mut keys, &a);
            l.norm4.apply(&mut keys);
        }
        let q = add(&queries, &query_pe);
        let k = add(&keys, &key_pe);
        let a = self.final_attn.forward(&q, &k, &keys);
        add_into(&mut queries, &a);
        self.norm_final.apply(&mut queries);
        // Masks: the image's features enlarged four times, weighted by what
        // each mask token makes of them.
        let src = from_rows(&keys, d, h, w);
        let mut up = conv_t2(&src, &self.up1.0, &self.up1.1);
        self.up_norm.apply_channels(&mut up);
        gelu(&mut up.data);
        let mut up = conv_t2(&up, &self.up2.0, &self.up2.1);
        gelu(&mut up.data);
        let iou = self.iou_head.apply(&queries[..d]);
        // The three masks after the first, the best by predicted IoU.
        let best = (1..self.hyper.len()).max_by(|a, b| iou[*a].total_cmp(&iou[*b])).unwrap_or(1);
        let token = &queries[(1 + best) * d..(2 + best) * d];
        let hyper = self.hyper[best].apply(token);
        matmul(&hyper, &up.data, 1, up.c, up.h * up.w, false)
    }
}

// ---------------------------------------------------------------- together

pub struct Sam {
    encoder: Encoder,
    decoder: Decoder,
}

/// A picture made ready to tap: its features, and how it was fitted.
pub struct Prepared {
    embedding: Feat,
    /// The picture's size, fitted into the 1024 square.
    fitted: (usize, usize),
}

impl Sam {
    pub fn load(path: &Path) -> Result<Sam, String> {
        let mut t = crate::clip::model::Weights::open(path)?.all()?;
        Ok(Sam { encoder: Encoder::load(&mut t)?, decoder: Decoder::load(&mut t)? })
    }

    pub fn prepare(&self, picture: &DynamicImage) -> Result<Prepared, String> {
        let (w, h) = (picture.width() as usize, picture.height() as usize);
        let scale = SIDE as f32 / w.max(h) as f32;
        let (fw, fh) = (((w as f32 * scale).round() as usize).clamp(1, SIDE), ((h as f32 * scale).round() as usize).clamp(1, SIDE));
        let small = picture.resize_exact(fw as u32, fh as u32, FilterType::Triangle).to_rgb8();
        let mut x = Feat::zeros(3, SIDE, SIDE);
        for (sx, sy, p) in small.enumerate_pixels() {
            for c in 0..3 {
                x.data[c * SIDE * SIDE + sy as usize * SIDE + sx as usize] = (p.0[c] as f32 - MEAN[c]) / STD[c];
            }
        }
        Ok(Prepared { embedding: self.encoder.forward(&x)?, fitted: (fw, fh) })
    }

    /// The outline of what is at (x, y), in fractions of the picture: the
    /// edge of the mask's piece that holds the point (or its largest),
    /// simplified. Empty when there is nothing there.
    pub fn outline(&self, p: &Prepared, x: f32, y: f32) -> Vec<(f32, f32)> {
        let (fw, fh) = p.fitted;
        let logits = self.decoder.decode(&p.embedding, x * fw as f32, y * fh as f32);
        let n = 256usize;
        // The part of the 256 grid the picture covers.
        let (gw, gh) = (((fw * n) as f32 / SIDE as f32).ceil() as usize, ((fh * n) as f32 / SIDE as f32).ceil() as usize);
        let cell = |gx: f32, gy: f32| ((gx * 4.0) / fw as f32, (gy * 4.0) / fh as f32);
        let loops = contours(&logits, n, gw.min(n), gh.min(n));
        let (px, py) = (x * fw as f32 / 4.0, y * fh as f32 / 4.0);
        let pick = loops
            .iter()
            .filter(|l| inside(l, px, py))
            .max_by(|a, b| area(a).total_cmp(&area(b)))
            .or_else(|| loops.iter().max_by(|a, b| area(a).total_cmp(&area(b))));
        match pick {
            Some(l) if area(l) >= 4.0 => simplify(l, 0.6).into_iter().map(|(a, b)| cell(a, b)).map(|(a, b)| (a.clamp(0.0, 1.0), b.clamp(0.0, 1.0))).collect(),
            _ => Vec::new(),
        }
    }
}

/// Closed loops where `v` (a `n`-wide grid, looked at over `w` × `h`)
/// crosses zero, by marching squares, in grid units (cell centres at
/// i + 0.5). The grid is taken as below zero past its edges, so every loop
/// closes.
fn contours(v: &[f32], n: usize, w: usize, h: usize) -> Vec<Vec<(f32, f32)>> {
    let at = |x: isize, y: isize| -> f32 {
        if x < 0 || y < 0 || x >= w as isize || y >= h as isize {
            -1.0
        } else {
            v[y as usize * n + x as usize]
        }
    };
    // A crossing is named by the grid edge it lies on (its two corners, in
    // order), and placed from those corners the same way whichever cell
    // finds it, so neighbouring cells meet exactly.
    type Edge = ((isize, isize), (isize, isize));
    let place = |e: Edge| -> (f32, f32) {
        let ((ax, ay), (bx, by)) = e;
        let (va, vb) = (at(ax, ay), at(bx, by));
        let t = va / (va - vb);
        (ax as f32 + 0.5 + t * (bx - ax) as f32, ay as f32 + 0.5 + t * (by - ay) as f32)
    };
    let mut next: HashMap<Edge, Edge> = HashMap::new();
    let mut starts = Vec::new();
    for y in -1..h as isize {
        for x in -1..w as isize {
            let corner = [(x, y), (x + 1, y), (x + 1, y + 1), (x, y + 1)];
            let c = [at(x, y), at(x + 1, y), at(x + 1, y + 1), at(x, y + 1)];
            let edge = |i: usize| -> Edge {
                let (a, b) = (corner[i], corner[(i + 1) % 4]);
                if a <= b { (a, b) } else { (b, a) }
            };
            let inside = |i: usize| c[i] > 0.0;
            let crossings: Vec<usize> = (0..4).filter(|&i| inside(i) != inside((i + 1) % 4)).collect();
            // Each segment runs from the edge going in (clockwise) to the
            // edge coming out, the same way round in every cell.
            let mut link = |a: usize, b: usize| {
                let (p, q) = if inside((a + 1) % 4) { (edge(a), edge(b)) } else { (edge(b), edge(a)) };
                next.insert(p, q);
                starts.push(p);
            };
            if crossings.len() == 2 {
                link(crossings[0], crossings[1]);
            } else if crossings.len() == 4 {
                // A saddle: join by the sign of its middle.
                let mid = c.iter().sum::<f32>() / 4.0;
                if (mid > 0.0) == inside(0) {
                    link(3, 0);
                    link(1, 2);
                } else {
                    link(0, 1);
                    link(2, 3);
                }
            }
        }
    }
    let mut loops = Vec::new();
    let mut used = std::collections::HashSet::new();
    for s in starts {
        if used.contains(&s) {
            continue;
        }
        let mut l = vec![place(s)];
        let mut cur = s;
        used.insert(s);
        while let Some(&q) = next.get(&cur) {
            if used.contains(&q) {
                break;
            }
            used.insert(q);
            l.push(place(q));
            cur = q;
        }
        if l.len() >= 3 {
            loops.push(l);
        }
    }
    loops
}

fn area(l: &[(f32, f32)]) -> f32 {
    let mut a = 0.0;
    for i in 0..l.len() {
        let (p, q) = (l[i], l[(i + 1) % l.len()]);
        a += p.0 * q.1 - q.0 * p.1;
    }
    (a / 2.0).abs()
}

fn inside(l: &[(f32, f32)], x: f32, y: f32) -> bool {
    let mut odd = false;
    for i in 0..l.len() {
        let (a, b) = (l[i], l[(i + 1) % l.len()]);
        if (a.1 > y) != (b.1 > y) && x < a.0 + (y - a.1) / (b.1 - a.1) * (b.0 - a.0) {
            odd = !odd;
        }
    }
    odd
}

/// Douglas–Peucker, for a closed loop.
fn simplify(l: &[(f32, f32)], eps: f32) -> Vec<(f32, f32)> {
    fn dp(pts: &[(f32, f32)], eps: f32, out: &mut Vec<(f32, f32)>) {
        let (a, b) = (pts[0], pts[pts.len() - 1]);
        let (dx, dy) = (b.0 - a.0, b.1 - a.1);
        let len = (dx * dx + dy * dy).sqrt().max(1e-6);
        let (mut far, mut at) = (0.0, 0);
        for (i, p) in pts.iter().enumerate().take(pts.len() - 1).skip(1) {
            let d = ((p.0 - a.0) * dy - (p.1 - a.1) * dx).abs() / len;
            if d > far {
                far = d;
                at = i;
            }
        }
        if far > eps {
            dp(&pts[..=at], eps, out);
            dp(&pts[at..], eps, out);
        } else {
            out.push(a);
        }
    }
    if l.len() < 4 {
        return l.to_vec();
    }
    // Split at the point farthest from the first, so each half is a path.
    let far = (1..l.len()).max_by(|&i, &j| {
        let d = |k: usize| (l[k].0 - l[0].0).powi(2) + (l[k].1 - l[0].1).powi(2);
        d(i).total_cmp(&d(j))
    });
    let far = far.unwrap_or(l.len() / 2);
    let mut out = Vec::new();
    dp(&l[..=far], eps, &mut out);
    let mut back: Vec<(f32, f32)> = l[far..].to_vec();
    back.push(l[0]);
    dp(&back, eps, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_edge_of_a_disc_is_a_loop_round_it() {
        let n = 64;
        let mut v = vec![-1.0f32; n * n];
        for y in 0..n {
            for x in 0..n {
                let d = ((x as f32 - 32.0).powi(2) + (y as f32 - 30.0).powi(2)).sqrt();
                v[y * n + x] = 10.0 - d;
            }
        }
        let loops = contours(&v, n, n, n);
        assert_eq!(loops.len(), 1);
        let l = &loops[0];
        assert!(inside(l, 32.5, 30.5));
        assert!(!inside(l, 5.0, 5.0));
        let a = area(l);
        assert!((a - std::f32::consts::PI * 100.0).abs() < 25.0, "area {a}");
        let s = simplify(l, 0.6);
        assert!(s.len() >= 8 && s.len() < l.len(), "{} of {}", s.len(), l.len());
    }

    /// With the real model in GV_SAM_MODEL and the ComfyUI examples in
    /// GV_SAMPLE_DIR (CI has both): tapping the woman in the field outlines
    /// her, not the field.
    #[test]
    fn outlines_the_woman_in_the_field() {
        let (Ok(model), Ok(samples)) = (std::env::var("GV_SAM_MODEL"), std::env::var("GV_SAMPLE_DIR")) else { return };
        let sam = Sam::load(Path::new(&model)).expect("model loads");
        let picture = image::open(Path::new(&samples).join("flux/girl_in_field.png")).unwrap();
        let start = std::time::Instant::now();
        let p = sam.prepare(&picture).unwrap();
        println!("encoded in {:?}; embedding mean {}", start.elapsed(), p.embedding.data.iter().sum::<f32>() / p.embedding.data.len() as f32);
        let start = std::time::Instant::now();
        let outline = sam.outline(&p, 0.5, 0.7);
        println!("outlined in {:?}: {} points: {:?}", start.elapsed(), outline.len(), outline);
        assert!(outline.len() >= 6);
        let xs: Vec<f32> = outline.iter().map(|p| p.0).collect();
        let ys: Vec<f32> = outline.iter().map(|p| p.1).collect();
        let (x0, x1) = (xs.iter().cloned().fold(1.0, f32::min), xs.iter().cloned().fold(0.0, f32::max));
        let (y0, y1) = (ys.iter().cloned().fold(1.0, f32::min), ys.iter().cloned().fold(0.0, f32::max));
        println!("box {x0} {y0} {x1} {y1}");
        // Her body: roughly the middle third across, from her shoulders down.
        assert!(x0 > 0.15 && x1 < 0.85 && x1 - x0 > 0.25, "{x0} {x1}");
        assert!(y1 > 0.9, "{y1}");
    }
}
