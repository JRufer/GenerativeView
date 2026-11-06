//! Finding faces and hands in a picture, on the device, for the detail
//! pass: RetinaFace (MobileNet 0.25) for faces in photographs and renders,
//! and two YOLOv8n models trained on anime and illustration, one for faces
//! and one for hands. Faces found by both are kept once.
//!
//! The models are downloaded by the app the first time they are needed
//! and read here from their PyTorch checkpoints with [`crate::sr::pth`].

use crate::nn::{self, concat, max_pool_same, nms, upsample_nearest, Act, Conv, Feat, Found};
use crate::sr::pth::{self, Tensor};
use image::{imageops::FilterType, DynamicImage};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// The models' files, where the app puts them under the data folder.
pub const RETINAFACE: &str = "retinaface_mobilenet0.25.pth";
pub const ANIME_FACE: &str = "anime_face_v1.4_n.pt";
pub const ANIME_HAND: &str = "anime_hand_v1.0_n.pt";

pub fn model_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("models").join("detail")
}

/// What was found: a face or a hand, its box in fractions of the
/// picture's width and height, and how sure.
#[derive(Debug, Clone, PartialEq)]
pub struct Region {
    pub kind: &'static str,
    pub x0: f32,
    pub y0: f32,
    pub x1: f32,
    pub y1: f32,
    pub score: f32,
}

// ---------------------------------------------------------------- YOLOv8

struct Bottleneck {
    cv1: Conv,
    cv2: Conv,
    add: bool,
}

struct C2f {
    cv1: Conv,
    cv2: Conv,
    m: Vec<Bottleneck>,
}

impl C2f {
    fn load(t: &mut HashMap<String, Tensor>, p: &str, shortcut: bool) -> Result<C2f, String> {
        let cv1 = conv(t, &format!("{p}.cv1"), 1)?;
        let cv2 = conv(t, &format!("{p}.cv2"), 1)?;
        let mut m = Vec::new();
        while t.contains_key(&format!("{p}.m.{}.cv1.conv.weight", m.len())) {
            let i = m.len();
            let b1 = conv(t, &format!("{p}.m.{i}.cv1"), 1)?;
            let b2 = conv(t, &format!("{p}.m.{i}.cv2"), 1)?;
            m.push(Bottleneck { add: shortcut && b1.cin == b2.cout, cv1: b1, cv2: b2 });
        }
        Ok(C2f { cv1, cv2, m })
    }

    fn forward(&self, x: &Feat) -> Result<Feat, String> {
        let y = self.cv1.forward(x)?;
        let half = y.c / 2;
        let mut parts = vec![y.channels(0, half), y.channels(half, y.c)];
        for b in &self.m {
            let last = parts.last().unwrap();
            let mut z = b.cv2.forward(&b.cv1.forward(last)?)?;
            if b.add {
                nn::add(&mut z, last);
            }
            parts.push(z);
        }
        self.cv2.forward(&concat(&parts.iter().collect::<Vec<_>>()))
    }
}

/// An Ultralytics `Conv`: convolution, batch norm, SiLU.
fn conv(t: &mut HashMap<String, Tensor>, p: &str, stride: usize) -> Result<Conv, String> {
    Conv::with_bn(t, &format!("{p}.conv"), &format!("{p}.bn"), stride, 1, Act::Silu, 1e-3)
}

pub struct Yolo {
    stem: Vec<Conv>,     // 0, 1, 3, 5, 7
    c2f: Vec<C2f>,       // 2, 4, 6, 8
    sppf: (Conv, Conv),  // 9
    head: Vec<C2f>,      // 12, 15, 18, 21
    down: Vec<Conv>,     // 16, 19
    boxes: Vec<[Conv; 3]>,
    classes: Vec<[Conv; 3]>,
    reg_max: usize,
}

impl Yolo {
    pub fn load(path: &Path) -> Result<Yolo, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        Self::from_tensors(pth::load_modules(&bytes)?)
    }

    pub fn from_tensors(mut t: HashMap<String, Tensor>) -> Result<Yolo, String> {
        let t = &mut t;
        let stem = vec![conv(t, "model.0", 2)?, conv(t, "model.1", 2)?, conv(t, "model.3", 2)?, conv(t, "model.5", 2)?, conv(t, "model.7", 2)?];
        let c2f = vec![C2f::load(t, "model.2", true)?, C2f::load(t, "model.4", true)?, C2f::load(t, "model.6", true)?, C2f::load(t, "model.8", true)?];
        let sppf = (conv(t, "model.9.cv1", 1)?, conv(t, "model.9.cv2", 1)?);
        let head = vec![C2f::load(t, "model.12", false)?, C2f::load(t, "model.15", false)?, C2f::load(t, "model.18", false)?, C2f::load(t, "model.21", false)?];
        let down = vec![conv(t, "model.16", 2)?, conv(t, "model.19", 2)?];
        let mut boxes = Vec::new();
        let mut classes = Vec::new();
        for i in 0..3 {
            for (kind, out) in [("cv2", &mut boxes), ("cv3", &mut classes)] {
                let p = format!("model.22.{kind}.{i}");
                out.push([conv(t, &format!("{p}.0"), 1)?, conv(t, &format!("{p}.1"), 1)?, Conv::named(t, &format!("{p}.2"), 1, 1, Act::None)?]);
            }
        }
        let reg_max = boxes[0][2].cout / 4;
        Ok(Yolo { stem, c2f, sppf, head, down, boxes, classes, reg_max })
    }

    /// The boxes in `x` (3 × h × w, RGB 0 to 1; h and w multiples of 32)
    /// scoring at least `threshold`, in its pixels.
    fn run(&self, x: &Feat, threshold: f32) -> Result<Vec<Found>, String> {
        let s = &self.stem;
        let p1 = s[1].forward(&s[0].forward(x)?)?;
        let p2 = self.c2f[0].forward(&p1)?;
        let p3 = self.c2f[1].forward(&s[2].forward(&p2)?)?; // stride 8
        let p4 = self.c2f[2].forward(&s[3].forward(&p3)?)?; // stride 16
        let p5 = self.c2f[3].forward(&s[4].forward(&p4)?)?;
        // SPPF
        let a = self.sppf.0.forward(&p5)?;
        let b = max_pool_same(&a, 5);
        let c = max_pool_same(&b, 5);
        let d = max_pool_same(&c, 5);
        let p5 = self.sppf.1.forward(&concat(&[&a, &b, &c, &d]))?;
        // Neck
        let up = upsample_nearest(&p5, p4.h, p4.w);
        let h12 = self.head[0].forward(&concat(&[&up, &p4]))?;
        let up = upsample_nearest(&h12, p3.h, p3.w);
        let out3 = self.head[1].forward(&concat(&[&up, &p3]))?;
        let dn = self.down[0].forward(&out3)?;
        let out4 = self.head[2].forward(&concat(&[&dn, &h12]))?;
        let dn = self.down[1].forward(&out4)?;
        let out5 = self.head[3].forward(&concat(&[&dn, &p5]))?;
        let mut found = Vec::new();
        for (level, (feat, stride)) in [(&out3, 8.0f32), (&out4, 16.0), (&out5, 32.0)].into_iter().enumerate() {
            let [b0, b1, b2] = &self.boxes[level];
            let [c0, c1, c2] = &self.classes[level];
            let bx = b2.forward(&b1.forward(&b0.forward(feat)?)?)?;
            let cl = c2.forward(&c1.forward(&c0.forward(feat)?)?)?;
            let hw = feat.h * feat.w;
            let r = self.reg_max;
            for at in 0..hw {
                let score = (0..cl.c).map(|k| cl.data[k * hw + at]).fold(f32::NEG_INFINITY, f32::max);
                let score = 1.0 / (1.0 + (-score).exp());
                if score < threshold {
                    continue;
                }
                // Distribution focal loss: each side is the expected bin.
                let mut side = [0f32; 4];
                for (j, sd) in side.iter_mut().enumerate() {
                    let logits: Vec<f32> = (0..r).map(|k| bx.data[(j * r + k) * hw + at]).collect();
                    let m = logits.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
                    let e: Vec<f32> = logits.iter().map(|v| (v - m).exp()).collect();
                    let sum: f32 = e.iter().sum();
                    *sd = e.iter().enumerate().map(|(k, v)| k as f32 * v).sum::<f32>() / sum;
                }
                let (ax, ay) = ((at % feat.w) as f32 + 0.5, (at / feat.w) as f32 + 0.5);
                found.push(Found {
                    x0: (ax - side[0]) * stride,
                    y0: (ay - side[1]) * stride,
                    x1: (ax + side[2]) * stride,
                    y1: (ay + side[3]) * stride,
                    score,
                });
            }
        }
        Ok(nms(found, 0.7))
    }

    /// The boxes in `picture`, in fractions of its size.
    pub fn find(&self, picture: &DynamicImage, threshold: f32) -> Result<Vec<Found>, String> {
        let (input, scale, (px, py)) = letterbox(picture, 640, 32);
        let found = self.run(&input, threshold)?;
        let (w, h) = (picture.width() as f32, picture.height() as f32);
        Ok(found
            .into_iter()
            .map(|f| Found {
                x0: ((f.x0 - px) / scale / w).clamp(0.0, 1.0),
                y0: ((f.y0 - py) / scale / h).clamp(0.0, 1.0),
                x1: ((f.x1 - px) / scale / w).clamp(0.0, 1.0),
                y1: ((f.y1 - py) / scale / h).clamp(0.0, 1.0),
                score: f.score,
            })
            .collect())
    }
}

/// `picture` scaled so its long side is `side`, padded with grey (114) to
/// the next multiple of `multiple` both ways, centred, as RGB from 0 to 1.
/// Returns it, the scale, and the padding on the left and top.
fn letterbox(picture: &DynamicImage, side: u32, multiple: u32) -> (Feat, f32, (f32, f32)) {
    let (w, h) = (picture.width(), picture.height());
    let scale = side as f32 / w.max(h) as f32;
    let (nw, nh) = (((w as f32 * scale).round() as u32).max(1), ((h as f32 * scale).round() as u32).max(1));
    let small = picture.resize_exact(nw, nh, FilterType::Triangle).to_rgb8();
    let round = |n: u32| n.div_ceil(multiple) * multiple;
    let (fw, fh) = (round(nw) as usize, round(nh) as usize);
    let (px, py) = ((fw - nw as usize) / 2, (fh - nh as usize) / 2);
    let mut x = Feat { c: 3, h: fh, w: fw, data: vec![114.0 / 255.0; 3 * fh * fw] };
    for (sx, sy, p) in small.enumerate_pixels() {
        let at = (sy as usize + py) * fw + sx as usize + px;
        for c in 0..3 {
            x.data[c * fh * fw + at] = p.0[c] as f32 / 255.0;
        }
    }
    (x, scale, (px as f32, py as f32))
}

// ---------------------------------------------------------------- RetinaFace

struct Ssh {
    c3: Conv,
    c5_1: Conv,
    c5_2: Conv,
    c7_2: Conv,
    c7_3: Conv,
}

pub struct RetinaFace {
    body: Vec<Conv>,
    /// Where stage 1 and stage 2 end in [`Self::body`].
    stage_ends: [usize; 3],
    fpn_out: [Conv; 3],
    fpn_merge: [Conv; 2],
    ssh: Vec<Ssh>,
    class_heads: Vec<Conv>,
    box_heads: Vec<Conv>,
}

const LEAKY: Act = Act::Leaky(0.1);

fn bn_conv(t: &mut HashMap<String, Tensor>, p: &str, conv: usize, stride: usize, groups: usize, act: Act) -> Result<Conv, String> {
    Conv::with_bn(t, &format!("{p}.{conv}"), &format!("{p}.{}", conv + 1), stride, groups, act, 1e-5)
}

impl RetinaFace {
    pub fn load(path: &Path) -> Result<RetinaFace, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        let mut t = pth::load(&bytes)?;
        // Saved from DataParallel, the names start "module.".
        if t.keys().any(|k| k.starts_with("module.")) {
            t = t.into_iter().map(|(k, v)| (k.strip_prefix("module.").unwrap_or(&k).to_string(), v)).collect();
        }
        Self::from_tensors(t)
    }

    pub fn from_tensors(mut t: HashMap<String, Tensor>) -> Result<RetinaFace, String> {
        let t = &mut t;
        let mut body = Vec::new();
        let mut stage_ends = [0; 3];
        // MobileNet 0.25: conv_bn first, then depthwise-separable blocks
        // (3×3 depthwise, then 1×1), the strides as the network has them.
        let strides: [&[usize]; 3] = [&[2, 1, 2, 1, 2, 1], &[2, 1, 1, 1, 1, 1], &[2, 1]];
        for (stage, list) in strides.iter().enumerate() {
            for (i, &stride) in list.iter().enumerate() {
                let p = format!("body.stage{}.{i}", stage + 1);
                if stage == 0 && i == 0 {
                    body.push(bn_conv(t, &p, 0, stride, 1, LEAKY)?);
                } else {
                    let groups = t.get(&format!("{p}.0.weight")).map(|w| w.shape[0]).ok_or_else(|| format!("the model has no {p}.0.weight"))?;
                    body.push(bn_conv(t, &p, 0, stride, groups, LEAKY)?);
                    body.push(bn_conv(t, &p, 3, 1, 1, LEAKY)?);
                }
            }
            stage_ends[stage] = body.len();
        }
        let fpn_out = [bn_conv(t, "fpn.output1", 0, 1, 1, LEAKY)?, bn_conv(t, "fpn.output2", 0, 1, 1, LEAKY)?, bn_conv(t, "fpn.output3", 0, 1, 1, LEAKY)?];
        let fpn_merge = [bn_conv(t, "fpn.merge1", 0, 1, 1, LEAKY)?, bn_conv(t, "fpn.merge2", 0, 1, 1, LEAKY)?];
        let mut ssh = Vec::new();
        for i in 1..=3 {
            let p = format!("ssh{i}");
            ssh.push(Ssh {
                c3: bn_conv(t, &format!("{p}.conv3X3"), 0, 1, 1, Act::None)?,
                c5_1: bn_conv(t, &format!("{p}.conv5X5_1"), 0, 1, 1, LEAKY)?,
                c5_2: bn_conv(t, &format!("{p}.conv5X5_2"), 0, 1, 1, Act::None)?,
                c7_2: bn_conv(t, &format!("{p}.conv7X7_2"), 0, 1, 1, LEAKY)?,
                c7_3: bn_conv(t, &format!("{p}.conv7x7_3"), 0, 1, 1, Act::None)?,
            });
        }
        let mut class_heads = Vec::new();
        let mut box_heads = Vec::new();
        for i in 0..3 {
            class_heads.push(Conv::named(t, &format!("ClassHead.{i}.conv1x1"), 1, 1, Act::None)?);
            box_heads.push(Conv::named(t, &format!("BboxHead.{i}.conv1x1"), 1, 1, Act::None)?);
        }
        Ok(RetinaFace { body, stage_ends, fpn_out, fpn_merge, ssh, class_heads, box_heads })
    }

    /// Faces in `picture` scoring at least `threshold`, in fractions.
    pub fn find(&self, picture: &DynamicImage, threshold: f32) -> Result<Vec<Found>, String> {
        let (w0, h0) = (picture.width(), picture.height());
        let scale = 640.0 / w0.max(h0) as f32;
        let (w, h) = (((w0 as f32 * scale).round() as usize).max(32), ((h0 as f32 * scale).round() as usize).max(32));
        let small = picture.resize_exact(w as u32, h as u32, FilterType::Triangle).to_rgb8();
        // BGR, less the mean, as it was trained.
        let mut x = Feat::zeros(3, h, w);
        let mean = [104.0, 117.0, 123.0];
        for (sx, sy, p) in small.enumerate_pixels() {
            let at = sy as usize * w + sx as usize;
            for c in 0..3 {
                x.data[c * h * w + at] = p.0[2 - c] as f32 - mean[c];
            }
        }
        let mut f = x;
        let mut stages = Vec::new();
        for (i, c) in self.body.iter().enumerate() {
            f = c.forward(&f)?;
            if self.stage_ends.contains(&(i + 1)) {
                stages.push(f.clone());
            }
        }
        let mut o1 = self.fpn_out[0].forward(&stages[0])?;
        let mut o2 = self.fpn_out[1].forward(&stages[1])?;
        let o3 = self.fpn_out[2].forward(&stages[2])?;
        let up = upsample_nearest(&o3, o2.h, o2.w);
        nn::add(&mut o2, &up);
        let o2 = self.fpn_merge[1].forward(&o2)?;
        let up = upsample_nearest(&o2, o1.h, o1.w);
        nn::add(&mut o1, &up);
        let o1 = self.fpn_merge[0].forward(&o1)?;
        let mut found = Vec::new();
        let min_sizes = [[16.0f32, 32.0], [64.0, 128.0], [256.0, 512.0]];
        let steps = [8.0f32, 16.0, 32.0];
        for (level, feat) in [o1, o2, o3].iter().enumerate() {
            let s = &self.ssh[level];
            let c3 = s.c3.forward(feat)?;
            let c5_1 = s.c5_1.forward(feat)?;
            let c5 = s.c5_2.forward(&c5_1)?;
            let c7 = s.c7_3.forward(&s.c7_2.forward(&c5_1)?)?;
            let mut out = concat(&[&c3, &c5, &c7]);
            nn::relu(&mut out);
            let cls = self.class_heads[level].forward(&out)?;
            let bx = self.box_heads[level].forward(&out)?;
            let hw = out.h * out.w;
            let anchors = cls.c / 2;
            for at in 0..hw {
                let (j, i) = ((at % out.w) as f32, (at / out.w) as f32);
                for a in 0..anchors {
                    let (no, yes) = (cls.data[(a * 2) * hw + at], cls.data[(a * 2 + 1) * hw + at]);
                    let score = 1.0 / (1.0 + (no - yes).exp());
                    if score < threshold {
                        continue;
                    }
                    let m = min_sizes[level][a.min(1)];
                    let (pcx, pcy) = ((j + 0.5) * steps[level], (i + 0.5) * steps[level]);
                    let l = |k: usize| bx.data[(a * 4 + k) * hw + at];
                    let cx = pcx + l(0) * 0.1 * m;
                    let cy = pcy + l(1) * 0.1 * m;
                    let bw = m * (l(2) * 0.2).exp();
                    let bh = m * (l(3) * 0.2).exp();
                    found.push(Found {
                        x0: ((cx - bw / 2.0) / w as f32).clamp(0.0, 1.0),
                        y0: ((cy - bh / 2.0) / h as f32).clamp(0.0, 1.0),
                        x1: ((cx + bw / 2.0) / w as f32).clamp(0.0, 1.0),
                        y1: ((cy + bh / 2.0) / h as f32).clamp(0.0, 1.0),
                        score,
                    });
                }
            }
        }
        Ok(nms(found, 0.4))
    }
}

// ---------------------------------------------------------------- together

/// The three models, loaded once and kept.
pub struct Finder {
    faces: RetinaFace,
    anime_faces: Yolo,
    anime_hands: Yolo,
}

impl Finder {
    pub fn load(dir: &Path) -> Result<Finder, String> {
        Ok(Finder {
            faces: RetinaFace::load(&dir.join(RETINAFACE))?,
            anime_faces: Yolo::load(&dir.join(ANIME_FACE))?,
            anime_hands: Yolo::load(&dir.join(ANIME_HAND))?,
        })
    }

    pub fn installed(dir: &Path) -> bool {
        [RETINAFACE, ANIME_FACE, ANIME_HAND].iter().all(|f| dir.join(f).is_file())
    }

    /// The faces and hands in `picture`, surest first. A face both face
    /// models find is kept once.
    pub fn find(&self, picture: &DynamicImage) -> Result<Vec<Region>, String> {
        let mut faces = self.faces.find(picture, 0.6)?;
        faces.extend(self.anime_faces.find(picture, 0.278)?);
        let faces = nms(faces, 0.4);
        let hands = self.anime_hands.find(picture, 0.264)?;
        let region = |kind: &'static str| move |f: Found| Region { kind, x0: f.x0, y0: f.y0, x1: f.x1, y1: f.y1, score: f.score };
        let mut out: Vec<Region> = faces.into_iter().map(region("face")).chain(hands.into_iter().map(region("hand"))).collect();
        // Too small to redraw is not worth a pass.
        out.retain(|r| (r.x1 - r.x0) * picture.width() as f32 >= 12.0 && (r.y1 - r.y0) * picture.height() as f32 >= 12.0);
        out.sort_by(|a, b| b.score.total_cmp(&a.score));
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// With the real models in GV_DETAIL_MODELS and the ComfyUI examples in
    /// GV_SAMPLE_DIR (CI has both): the woman in the field has one face,
    /// where it is.
    #[test]
    fn finds_the_face_in_the_field() {
        let (Ok(models), Ok(samples)) = (std::env::var("GV_DETAIL_MODELS"), std::env::var("GV_SAMPLE_DIR")) else { return };
        let finder = Finder::load(Path::new(&models)).expect("models load");
        let picture = image::open(Path::new(&samples).join("flux/girl_in_field.png")).unwrap();
        let found = finder.find(&picture).unwrap();
        println!("girl_in_field: {found:?}");
        let faces: Vec<_> = found.iter().filter(|r| r.kind == "face").collect();
        assert_eq!(faces.len(), 1, "{found:?}");
        let f = faces[0];
        // Her face spans about 0.42 to 0.60 across and 0.27 to 0.46 down.
        let (cx, cy) = ((f.x0 + f.x1) / 2.0, (f.y0 + f.y1) / 2.0);
        assert!((0.44..0.58).contains(&cx) && (0.30..0.46).contains(&cy), "{f:?}");
        for name in ["chroma/fennec_girl_flowers.png", "z_image/z_image_turbo_example.png", "sdxl/sdxl_simple_example.png"] {
            let p = image::open(Path::new(&samples).join(name)).unwrap();
            println!("{name}: {:?}", finder.find(&p).unwrap());
        }
    }
}
