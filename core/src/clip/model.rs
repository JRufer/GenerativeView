//! CLIP's two encoders, run on the CPU.
//!
//! Reads a model in Hugging Face's layout (`config.json` beside
//! `model.safetensors`) and computes the same embeddings `transformers`
//! does: the tests compare the two on a reference model. It is plain
//! arithmetic over `Vec<f32>` with one fast matrix multiply underneath, so
//! there is nothing to install and it builds for Android as it stands.
//!
//! Both encoders are the same stack of pre-norm transformer blocks. The
//! picture encoder cuts the image into patches and reads its answer off a
//! class token; the text encoder masks attention so each token sees only
//! what came before it, and reads its answer off the last token.

use gemm::Parallelism;
use rayon::prelude::*;
use serde_json::Value;
use std::collections::HashMap;
use std::fs::File;
use std::path::Path;

#[cfg(unix)]
use std::os::unix::fs::FileExt;

#[cfg(windows)]
trait FileExt {
    fn read_exact_at(&self, buf: &mut [u8], offset: u64) -> std::io::Result<()>;
}

#[cfg(windows)]
impl FileExt for File {
    fn read_exact_at(&self, mut buf: &mut [u8], mut offset: u64) -> std::io::Result<()> {
        use std::os::windows::fs::FileExt as WinFileExt;
        while !buf.is_empty() {
            match self.seek_read(buf, offset) {
                Ok(0) => {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::UnexpectedEof,
                        "failed to fill whole buffer",
                    ))
                }
                Ok(n) => {
                    buf = &mut buf[n..];
                    offset += n as u64;
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }
}

// ---------------------------------------------------------------- weights

struct Entry {
    shape: Vec<usize>,
    offset: u64,
    bytes: usize,
}

/// A `.safetensors` file: a JSON table of contents, then raw little-endian
/// tensors. Tensors are read from disk when asked for, never all at once.
pub struct Weights {
    file: File,
    entries: HashMap<String, Entry>,
}

impl Weights {
    pub fn open(path: &Path) -> Result<Weights, String> {
        let fail = |e: &dyn std::fmt::Display| format!("{}: {e}", path.display());
        let file = File::open(path).map_err(|e| fail(&e))?;
        let size = file.metadata().map_err(|e| fail(&e))?.len();
        let mut head = [0u8; 8];
        file.read_exact_at(&mut head, 0).map_err(|e| fail(&e))?;
        let header_len = u64::from_le_bytes(head);
        if header_len > 64 << 20 || 8 + header_len > size {
            return Err(fail(&"not a safetensors file"));
        }
        let mut header = vec![0u8; header_len as usize];
        file.read_exact_at(&mut header, 8).map_err(|e| fail(&e))?;
        let table: Value = serde_json::from_slice(&header).map_err(|e| fail(&e))?;
        let mut entries = HashMap::new();
        for (name, info) in table.as_object().ok_or_else(|| fail(&"no table of contents"))? {
            if name == "__metadata__" {
                continue;
            }
            let shape: Vec<usize> = info["shape"].as_array().into_iter().flatten().filter_map(|d| d.as_u64().map(|d| d as usize)).collect();
            let (Some(start), Some(end)) = (info["data_offsets"][0].as_u64(), info["data_offsets"][1].as_u64()) else {
                return Err(fail(&format!("{name}: no data")));
            };
            if info["dtype"] != "F32" {
                // Position ids and the like; nothing we read.
                continue;
            }
            let bytes = (end - start) as usize;
            if bytes != shape.iter().product::<usize>() * 4 || 8 + header_len + end > size {
                return Err(fail(&format!("{name}: truncated")));
            }
            entries.insert(name.clone(), Entry { shape, offset: 8 + header_len + start, bytes });
        }
        Ok(Weights { file, entries })
    }

    fn entry(&self, name: &str) -> Result<&Entry, String> {
        self.entries.get(name).ok_or_else(|| format!("model has no tensor named {name}"))
    }

    pub fn shape(&self, name: &str) -> Result<&[usize], String> {
        Ok(&self.entry(name)?.shape)
    }

    fn read(&self, offset: u64, bytes: usize) -> Result<Vec<f32>, String> {
        let mut raw = vec![0u8; bytes];
        self.file.read_exact_at(&mut raw, offset).map_err(|e| format!("reading the model: {e}"))?;
        Ok(raw.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect())
    }

    /// A whole tensor, which must have this shape.
    pub fn get(&self, name: &str, shape: &[usize]) -> Result<Vec<f32>, String> {
        let entry = self.entry(name)?;
        if entry.shape != shape {
            return Err(format!("{name} is {:?}, expected {shape:?}", entry.shape));
        }
        self.read(entry.offset, entry.bytes)
    }

    /// One row of a two-dimensional tensor.
    pub fn row(&self, name: &str, row: usize) -> Result<Vec<f32>, String> {
        let entry = self.entry(name)?;
        let &[rows, width] = entry.shape.as_slice() else { return Err(format!("{name} is not a table")) };
        if row >= rows {
            return Err(format!("{name} has no row {row}"));
        }
        self.read(entry.offset + (row * width * 4) as u64, width * 4)
    }
}

// ---------------------------------------------------------------- layers

/// How many threads the big multiplications may use.
fn threads() -> Parallelism {
    static COUNT: std::sync::OnceLock<usize> = std::sync::OnceLock::new();
    // Half the cores: the rest stay free for thumbnails and the UI.
    let count = *COUNT.get_or_init(|| (std::thread::available_parallelism().map_or(2, |n| n.get()) / 2).max(1));
    if count > 1 {
        Parallelism::Rayon(count)
    } else {
        Parallelism::None
    }
}

/// `out = bias + input × weight`, one input per row.
struct Linear {
    /// Stored inputs × outputs, the transpose of how the file has it, so the
    /// multiply reads both operands row by row.
    weight: Vec<f32>,
    bias: Vec<f32>,
    inputs: usize,
    outputs: usize,
}

impl Linear {
    fn load(w: &Weights, name: &str, inputs: usize, outputs: usize, bias: bool) -> Result<Linear, String> {
        let by_output = w.get(&format!("{name}.weight"), &[outputs, inputs])?;
        let mut weight = vec![0f32; inputs * outputs];
        for (o, row) in by_output.chunks_exact(inputs).enumerate() {
            for (i, value) in row.iter().enumerate() {
                weight[i * outputs + o] = *value;
            }
        }
        let bias = if bias { w.get(&format!("{name}.bias"), &[outputs])? } else { vec![0.0; outputs] };
        Ok(Linear { weight, bias, inputs, outputs })
    }

    fn apply(&self, input: &[f32]) -> Vec<f32> {
        let rows = input.len() / self.inputs;
        let mut out = Vec::with_capacity(rows * self.outputs);
        for _ in 0..rows {
            out.extend_from_slice(&self.bias);
        }
        // SAFETY: the three buffers are rows×outputs, rows×inputs and
        // inputs×outputs long, as the strides passed alongside them say.
        unsafe {
            gemm::gemm(
                rows,
                self.outputs,
                self.inputs,
                out.as_mut_ptr(),
                1,
                self.outputs as isize,
                true,
                input.as_ptr(),
                1,
                self.inputs as isize,
                self.weight.as_ptr(),
                1,
                self.outputs as isize,
                1.0,
                1.0,
                false,
                false,
                false,
                threads(),
            );
        }
        out
    }
}

struct Norm {
    weight: Vec<f32>,
    bias: Vec<f32>,
    eps: f32,
}

impl Norm {
    fn load(w: &Weights, name: &str, width: usize, eps: f32) -> Result<Norm, String> {
        Ok(Norm { weight: w.get(&format!("{name}.weight"), &[width])?, bias: w.get(&format!("{name}.bias"), &[width])?, eps })
    }

    /// Each row to zero mean and unit variance, then scaled and shifted.
    fn apply(&self, rows: &[f32]) -> Vec<f32> {
        let width = self.weight.len();
        let mut out = vec![0f32; rows.len()];
        out.par_chunks_mut(width).zip(rows.par_chunks(width)).for_each(|(out, row)| {
            let mean = row.iter().sum::<f32>() / width as f32;
            let variance = row.iter().map(|v| (v - mean) * (v - mean)).sum::<f32>() / width as f32;
            let scale = 1.0 / (variance + self.eps).sqrt();
            for i in 0..width {
                out[i] = (row[i] - mean) * scale * self.weight[i] + self.bias[i];
            }
        });
        out
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Activation {
    /// x·Φ(x), the exact form.
    Gelu,
    /// x·σ(1.702x), the approximation OpenAI's own CLIP models were trained with.
    QuickGelu,
}

/// The error function, to about seven decimal places (Abramowitz & Stegun
/// 7.1.26): plenty for single precision, and much cheaper than exact.
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

impl Activation {
    fn apply(self, values: &mut [f32]) {
        values.par_chunks_mut(4096).for_each(|chunk| match self {
            Activation::Gelu => chunk.iter_mut().for_each(|v| *v = 0.5 * *v * (1.0 + erf(*v * std::f32::consts::FRAC_1_SQRT_2))),
            Activation::QuickGelu => chunk.iter_mut().for_each(|v| *v /= 1.0 + (-1.702 * *v).exp()),
        });
    }
}

struct Block {
    norm1: Norm,
    query: Linear,
    key: Linear,
    value: Linear,
    out: Linear,
    norm2: Norm,
    wide: Linear,
    narrow: Linear,
}

/// The shape of one encoder, from `config.json`.
#[derive(Clone, Copy, Debug)]
struct Shape {
    width: usize,
    hidden: usize,
    layers: usize,
    heads: usize,
    activation: Activation,
    eps: f32,
}

impl Shape {
    /// `defaults` are what `transformers` assumes for a field the file leaves out.
    fn read(config: &Value, defaults: (usize, usize, usize, usize)) -> Result<Shape, String> {
        let number = |key: &str, default: usize| config[key].as_u64().map_or(default, |n| n as usize);
        let activation = match config["hidden_act"].as_str().unwrap_or("quick_gelu") {
            "quick_gelu" => Activation::QuickGelu,
            "gelu" => Activation::Gelu,
            other => return Err(format!("model uses the {other} activation, which is not supported")),
        };
        let shape = Shape {
            width: number("hidden_size", defaults.0),
            hidden: number("intermediate_size", defaults.1),
            layers: number("num_hidden_layers", defaults.2),
            heads: number("num_attention_heads", defaults.3),
            activation,
            eps: config["layer_norm_eps"].as_f64().unwrap_or(1e-5) as f32,
        };
        if shape.heads == 0 || shape.width % shape.heads != 0 {
            return Err("model's attention heads do not divide its width".into());
        }
        Ok(shape)
    }
}

struct Stack {
    blocks: Vec<Block>,
    shape: Shape,
}

impl Stack {
    fn load(w: &Weights, prefix: &str, shape: Shape) -> Result<Stack, String> {
        let (d, h) = (shape.width, shape.hidden);
        let blocks = (0..shape.layers)
            .map(|i| {
                let at = format!("{prefix}.encoder.layers.{i}");
                Ok(Block {
                    norm1: Norm::load(w, &format!("{at}.layer_norm1"), d, shape.eps)?,
                    query: Linear::load(w, &format!("{at}.self_attn.q_proj"), d, d, true)?,
                    key: Linear::load(w, &format!("{at}.self_attn.k_proj"), d, d, true)?,
                    value: Linear::load(w, &format!("{at}.self_attn.v_proj"), d, d, true)?,
                    out: Linear::load(w, &format!("{at}.self_attn.out_proj"), d, d, true)?,
                    norm2: Norm::load(w, &format!("{at}.layer_norm2"), d, shape.eps)?,
                    wide: Linear::load(w, &format!("{at}.mlp.fc1"), d, h, true)?,
                    narrow: Linear::load(w, &format!("{at}.mlp.fc2"), h, d, true)?,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        Ok(Stack { blocks, shape })
    }

    /// Run sequences of `len` tokens each (rows of `x`, one sequence after
    /// another) through every block, in place.
    fn run(&self, x: &mut Vec<f32>, len: usize, causal: bool) {
        for block in &self.blocks {
            let mixed = block.out.apply(&self.attend(block, &block.norm1.apply(x), len, causal));
            x.iter_mut().zip(&mixed).for_each(|(x, m)| *x += m);
            let mut wide = block.wide.apply(&block.norm2.apply(x));
            self.shape.activation.apply(&mut wide);
            let narrow = block.narrow.apply(&wide);
            x.iter_mut().zip(&narrow).for_each(|(x, n)| *x += n);
        }
    }

    /// Self-attention: every token of a sequence gathers from the others in
    /// proportion to how well its query matches their keys, head by head.
    fn attend(&self, block: &Block, x: &[f32], len: usize, causal: bool) -> Vec<f32> {
        let width = self.shape.width;
        let head = width / self.shape.heads;
        let scale = 1.0 / (head as f32).sqrt();
        let (q, k, v) = (block.query.apply(x), block.key.apply(x), block.value.apply(x));
        let mut out = vec![0f32; x.len()];
        let span = len * width;
        // A sequence at a time, on its own thread; the multiplies inside
        // are small.
        out.par_chunks_mut(span).enumerate().for_each(|(s, out)| {
            let (q, k, v) = (&q[s * span..][..span], &k[s * span..][..span], &v[s * span..][..span]);
            let mut scores = vec![0f32; len * len];
            for h in 0..self.shape.heads {
                let at = h * head;
                // SAFETY: each pointer starts `at` columns into a len×width
                // buffer and is read (or written) as len×head with the
                // buffer's own row stride; `scores` is len×len.
                unsafe {
                    // scores = Q × Kᵀ
                    gemm::gemm(
                        len,
                        len,
                        head,
                        scores.as_mut_ptr(),
                        1,
                        len as isize,
                        false,
                        q.as_ptr().add(at),
                        1,
                        width as isize,
                        k.as_ptr().add(at),
                        width as isize,
                        1,
                        0.0,
                        scale,
                        false,
                        false,
                        false,
                        Parallelism::None,
                    );
                }
                for (i, row) in scores.chunks_exact_mut(len).enumerate() {
                    let seen = if causal { i + 1 } else { len };
                    let peak = row[..seen].iter().copied().fold(f32::NEG_INFINITY, f32::max);
                    let mut total = 0.0;
                    for value in &mut row[..seen] {
                        *value = (*value - peak).exp();
                        total += *value;
                    }
                    row[..seen].iter_mut().for_each(|value| *value /= total);
                    row[seen..].iter_mut().for_each(|value| *value = 0.0);
                }
                unsafe {
                    // out = scores × V
                    gemm::gemm(
                        len,
                        head,
                        len,
                        out.as_mut_ptr().add(at),
                        1,
                        width as isize,
                        false,
                        scores.as_ptr(),
                        1,
                        len as isize,
                        v.as_ptr().add(at),
                        1,
                        width as isize,
                        0.0,
                        1.0,
                        false,
                        false,
                        false,
                        Parallelism::None,
                    );
                }
            }
        });
        out
    }
}

fn normalize(vector: &mut [f32]) {
    let length = vector.iter().map(|v| v * v).sum::<f32>().sqrt();
    if length > 0.0 {
        vector.iter_mut().for_each(|v| *v /= length);
    }
}

fn read_config(dir: &Path) -> Result<Value, String> {
    let path = dir.join("config.json");
    let text = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
}

// ---------------------------------------------------------------- pictures

/// Turns pictures into embeddings.
pub struct Vision {
    stack: Stack,
    patches: Linear,
    class: Vec<f32>,
    positions: Vec<f32>,
    before: Norm,
    after: Norm,
    project: Linear,
    /// Pictures are this many pixels on a side...
    pub image_size: usize,
    /// ...cut into squares this size.
    patch_size: usize,
    /// How long an embedding is.
    pub dim: usize,
}

impl Vision {
    pub fn load(dir: &Path) -> Result<Vision, String> {
        let config = read_config(dir)?;
        let vision = &config["vision_config"];
        let shape = Shape::read(vision, (768, 3072, 12, 12))?;
        let image_size = vision["image_size"].as_u64().unwrap_or(224) as usize;
        let patch_size = vision["patch_size"].as_u64().unwrap_or(32) as usize;
        if patch_size == 0 || image_size % patch_size != 0 {
            return Err("model's patch size does not divide its image size".into());
        }
        let w = Weights::open(&dir.join("model.safetensors"))?;
        let dim = w.shape("visual_projection.weight")?.first().copied().unwrap_or(0);
        let d = shape.width;
        let side = image_size / patch_size;
        // The patch "convolution" has one position per patch, so it is a
        // plain linear layer over each patch's pixels.
        let filters = w.get("vision_model.embeddings.patch_embedding.weight", &[d, 3, patch_size, patch_size])?;
        let inputs = 3 * patch_size * patch_size;
        let mut weight = vec![0f32; inputs * d];
        for (o, row) in filters.chunks_exact(inputs).enumerate() {
            for (i, value) in row.iter().enumerate() {
                weight[i * d + o] = *value;
            }
        }
        Ok(Vision {
            patches: Linear { weight, bias: vec![0.0; d], inputs, outputs: d },
            class: w.get("vision_model.embeddings.class_embedding", &[d])?,
            positions: w.get("vision_model.embeddings.position_embedding.weight", &[side * side + 1, d])?,
            // (The misspelling is the model format's own.)
            before: Norm::load(&w, "vision_model.pre_layrnorm", d, shape.eps)?,
            after: Norm::load(&w, "vision_model.post_layernorm", d, shape.eps)?,
            project: Linear::load(&w, "visual_projection", d, dim, false)?,
            stack: Stack::load(&w, "vision_model", shape)?,
            image_size,
            patch_size,
            dim,
        })
    }

    /// How many values one prepared picture is: three colour planes.
    pub fn pixels(&self) -> usize {
        3 * self.image_size * self.image_size
    }

    /// Embed pictures prepared by [`super::image::prepare`], laid end to
    /// end. Returns one unit-length embedding per picture, end to end.
    pub fn embed(&self, pictures: &[f32]) -> Vec<f32> {
        let count = pictures.len() / self.pixels();
        let (size, patch, d) = (self.image_size, self.patch_size, self.stack.shape.width);
        let side = size / patch;
        let per_patch = 3 * patch * patch;
        // Each patch's pixels in a row: colour, then down, then across.
        let mut rows = vec![0f32; count * side * side * per_patch];
        rows.par_chunks_mut(per_patch).enumerate().for_each(|(index, row)| {
            let picture = &pictures[index / (side * side) * self.pixels()..][..self.pixels()];
            let (py, px) = (index % (side * side) / side, index % side);
            for c in 0..3 {
                for y in 0..patch {
                    let from = c * size * size + (py * patch + y) * size + px * patch;
                    row[(c * patch + y) * patch..][..patch].copy_from_slice(&picture[from..from + patch]);
                }
            }
        });
        let embedded = self.patches.apply(&rows);

        // A class token, then the patches, each with its position added.
        let len = side * side + 1;
        let mut x = vec![0f32; count * len * d];
        x.par_chunks_mut(len * d).zip(embedded.par_chunks(side * side * d)).for_each(|(tokens, patches)| {
            tokens[..d].copy_from_slice(&self.class);
            tokens[d..].copy_from_slice(patches);
            tokens.iter_mut().zip(&self.positions).for_each(|(t, p)| *t += p);
        });
        let mut x = self.before.apply(&x);
        self.stack.run(&mut x, len, false);

        // The class token carries the answer.
        let pooled: Vec<f32> = x.chunks_exact(len * d).flat_map(|tokens| &tokens[..d]).copied().collect();
        let mut out = self.project.apply(&self.after.apply(&pooled));
        out.chunks_exact_mut(self.dim).for_each(normalize);
        out
    }
}

// ---------------------------------------------------------------- text

/// Turns a tokenized description into an embedding in the same space.
pub struct Text {
    stack: Stack,
    weights: Weights,
    positions: Vec<f32>,
    last: Norm,
    project: Linear,
    max_tokens: usize,
    vocabulary: usize,
    pub dim: usize,
}

impl Text {
    pub fn load(dir: &Path) -> Result<Text, String> {
        let config = read_config(dir)?;
        let text = &config["text_config"];
        let shape = Shape::read(text, (512, 2048, 12, 8))?;
        let max_tokens = text["max_position_embeddings"].as_u64().unwrap_or(77) as usize;
        let w = Weights::open(&dir.join("model.safetensors"))?;
        let dim = w.shape("text_projection.weight")?.first().copied().unwrap_or(0);
        let d = shape.width;
        let table = w.shape("text_model.embeddings.token_embedding.weight")?;
        if table.len() != 2 || table[1] != d {
            return Err("model's token table does not match its width".into());
        }
        Ok(Text {
            vocabulary: table[0],
            positions: w.get("text_model.embeddings.position_embedding.weight", &[max_tokens, d])?,
            last: Norm::load(&w, "text_model.final_layer_norm", d, shape.eps)?,
            project: Linear::load(&w, "text_projection", d, dim, false)?,
            stack: Stack::load(&w, "text_model", shape)?,
            // Kept open: token rows are read as they are needed rather than
            // holding the whole table (a third of the model) in memory.
            weights: w,
            max_tokens,
            dim,
        })
    }

    /// Embed one sequence of token ids (start marker ... end marker).
    pub fn embed(&self, tokens: &[u32]) -> Result<Vec<f32>, String> {
        if tokens.is_empty() || tokens.len() > self.max_tokens {
            return Err(format!("{} tokens, where the model takes 1 to {}", tokens.len(), self.max_tokens));
        }
        let d = self.stack.shape.width;
        let mut x = Vec::with_capacity(tokens.len() * d);
        for (at, &token) in tokens.iter().enumerate() {
            if token as usize >= self.vocabulary {
                return Err(format!("token {token} is not in the model's vocabulary"));
            }
            let row = self.weights.row("text_model.embeddings.token_embedding.weight", token as usize)?;
            x.extend(row.iter().zip(&self.positions[at * d..][..d]).map(|(t, p)| t + p));
        }
        self.stack.run(&mut x, tokens.len(), true);
        // The end marker, last in line, has seen everything before it.
        let pooled = &x[(tokens.len() - 1) * d..];
        let mut out = self.project.apply(&self.last.apply(pooled));
        normalize(&mut out);
        Ok(out)
    }
}
