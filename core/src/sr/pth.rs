//! Reading a PyTorch checkpoint (`.pth`) without PyTorch.
//!
//! A `.pth` file is a zip archive: `data.pkl`, a pickle describing the
//! tensors, and `data/<n>`, each tensor's raw little-endian storage. The
//! pickle is run on a small machine that knows only what a saved state dict
//! uses: dicts, tuples, strings, ints, and the call that rebuilds a tensor
//! from a storage. Anything else is refused rather than guessed at; nothing
//! in the file is ever executed.

use std::collections::HashMap;

/// A float tensor: its shape and its values, row-major.
#[derive(Debug, Clone, PartialEq)]
pub struct Tensor {
    pub shape: Vec<usize>,
    pub data: Vec<f32>,
}

/// A checkpoint's pickled object and its storages by key, from either the
/// zip archive PyTorch has written since 1.6 or the older format: a run of
/// pickles (magic number, protocol, system info, the object, the storages'
/// keys) and then each storage's bytes, after its element count.
fn open_archive(bytes: &[u8], objects: bool) -> Result<(Value, HashMap<String, Vec<u8>>), String> {
    if bytes.starts_with(b"PK") {
        let files = unzip(bytes)?;
        let (pkl_name, pkl) = files.iter().find(|(name, _)| name.ends_with("/data.pkl") || *name == "data.pkl").ok_or("not a PyTorch checkpoint: no data.pkl")?;
        let prefix = format!("{}data/", pkl_name.strip_suffix("data.pkl").unwrap_or(""));
        let root = Machine { objects, ..Default::default() }.run(pkl)?;
        let storages = files.iter().filter_map(|(n, b)| n.strip_prefix(&prefix).map(|k| (k.to_string(), b.clone()))).collect();
        return Ok((root, storages));
    }
    let mut m = Machine { objects, ..Default::default() };
    let (_magic, at) = m.run_from(bytes, 0).map_err(|e| format!("not a PyTorch checkpoint: {e}"))?;
    let (_protocol, at) = m.run_from(bytes, at)?;
    let (_system, at) = m.run_from(bytes, at)?;
    let (root, at) = m.run_from(bytes, at)?;
    let (keys, mut at) = m.run_from(bytes, at)?;
    let Value::List(keys) = keys else { return Err("checkpoint does not list its storages".into()) };
    let size_of = |dtype: &str| match dtype {
        "DoubleStorage" | "LongStorage" => 8,
        "FloatStorage" | "IntStorage" => 4,
        "HalfStorage" | "BFloat16Storage" | "ShortStorage" => 2,
        _ => 1,
    };
    let mut storages = HashMap::new();
    for k in keys {
        let Value::Str(key) = k else { return Err("bad storage key".into()) };
        let dtype = m.seen.iter().find(|(s, _)| *s == key).map(|(_, d)| d.clone()).unwrap_or_else(|| "FloatStorage".into());
        let count = bytes.get(at..at + 8).map(|b| u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]) as usize).ok_or("truncated checkpoint")?;
        at += 8;
        let len = count * size_of(&dtype);
        let data = bytes.get(at..at + len).ok_or("truncated checkpoint")?;
        at += len;
        storages.insert(key, data.to_vec());
    }
    Ok((root, storages))
}

/// The tensors of a checkpoint by name, from its state dict (or the
/// `params` / `params_ema` / `state_dict` dict inside it).
pub fn load(bytes: &[u8]) -> Result<HashMap<String, Tensor>, String> {
    let (root, files) = open_archive(bytes, false)?;
    let storage = |key: &str| -> Result<&[u8], String> { files.get(key).map(|b| b.as_slice()).ok_or_else(|| format!("checkpoint is missing storage {key}")) };
    let mut dict = match root {
        Value::Dict(d) => d,
        _ => return Err("checkpoint does not hold a dict".into()),
    };
    for wrapper in ["params_ema", "params", "state_dict", "model"] {
        if let Some(pos) = dict.iter().position(|(k, v)| matches!(k, Value::Str(s) if s == wrapper) && matches!(v, Value::Dict(_))) {
            if let (_, Value::Dict(inner)) = dict.swap_remove(pos) {
                dict = inner;
                break;
            }
        }
    }
    let mut out = HashMap::new();
    for (key, value) in dict {
        let (Value::Str(name), Value::Tensor { key, dtype, offset, shape, stride }) = (key, value) else { continue };
        // Counters (a batch norm's num_batches_tracked) and the like.
        if dtype != "FloatStorage" && dtype != "HalfStorage" {
            continue;
        }
        let t = read_tensor(&name, storage(&key)?, &dtype, offset, shape, &stride)?;
        out.insert(name, t);
    }
    Ok(out)
}

/// The tensors of a checkpoint that saves a whole model rather than its
/// state dict (as Ultralytics does), by their dotted names as a state dict
/// would have them: every parameter and buffer found by walking the
/// modules' `_modules`, `_parameters` and `_buffers`, in half or full
/// precision. The model is found under the checkpoint's `ema` or `model`.
/// Its classes are only named, never run.
pub fn load_modules(bytes: &[u8]) -> Result<HashMap<String, Tensor>, String> {
    let (root, files) = open_archive(bytes, true)?;
    let storage = |key: &str| -> Result<&[u8], String> { files.get(key).map(|b| b.as_slice()).ok_or_else(|| format!("checkpoint is missing storage {key}")) };
    let Value::Dict(dict) = root else { return Err("checkpoint does not hold a dict".into()) };
    let model = ["ema", "model"]
        .iter()
        .find_map(|want| dict.iter().find(|(k, v)| matches!(k, Value::Str(s) if s == want) && matches!(v, Value::Object { .. })).map(|(_, v)| v))
        .ok_or("checkpoint holds no model")?;
    let mut found = Vec::new();
    walk(model, "", &mut found);
    let mut out = HashMap::new();
    for (name, value) in found {
        let Value::Tensor { key, dtype, offset, shape, stride } = value else { continue };
        if dtype != "FloatStorage" && dtype != "HalfStorage" {
            continue;
        }
        let t = read_tensor(&name, storage(key)?, dtype, *offset, shape.clone(), stride)?;
        out.insert(name, t);
    }
    if out.is_empty() {
        return Err("checkpoint holds no tensors".into());
    }
    Ok(out)
}

/// Every tensor under `module`, named by its path.
fn walk<'a>(module: &'a Value, path: &str, out: &mut Vec<(String, &'a Value)>) {
    let Value::Object { state, .. } = module else { return };
    // A module's state is its __dict__, or (dict, slots).
    let dict = match state.as_ref() {
        Value::Dict(d) => d,
        Value::Tuple(parts) => match parts.first() {
            Some(Value::Dict(d)) => d,
            _ => return,
        },
        _ => return,
    };
    let field = |name: &str| dict.iter().find(|(k, _)| matches!(k, Value::Str(s) if s == name)).map(|(_, v)| v);
    for kind in ["_parameters", "_buffers"] {
        if let Some(Value::Dict(items)) = field(kind) {
            for (k, v) in items {
                if let (Value::Str(name), Value::Tensor { .. }) = (k, v) {
                    out.push((format!("{path}{name}"), v));
                }
            }
        }
    }
    if let Some(Value::Dict(children)) = field("_modules") {
        for (k, v) in children {
            if let Value::Str(name) = k {
                walk(v, &format!("{path}{name}."), out);
            }
        }
    }
}

/// A tensor's values from its storage, as f32: contiguous, row-major, from
/// float or half storage.
fn read_tensor(name: &str, raw: &[u8], dtype: &str, offset: usize, shape: Vec<usize>, stride: &[usize]) -> Result<Tensor, String> {
    let count: usize = shape.iter().product();
    let mut expect = 1;
    for (dim, st) in shape.iter().zip(stride).rev() {
        if *dim > 1 && *st != expect {
            return Err(format!("{name}: tensor is not contiguous"));
        }
        expect *= dim;
    }
    let size = match dtype {
        "FloatStorage" => 4,
        "HalfStorage" => 2,
        other => return Err(format!("{name}: {other} tensors are not supported")),
    };
    let start = offset * size;
    let end = start + count * size;
    if end > raw.len() {
        return Err(format!("{name}: storage is too short"));
    }
    let bytes = &raw[start..end];
    let data = if size == 4 {
        bytes.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect()
    } else {
        bytes.chunks_exact(2).map(|b| half_to_f32(u16::from_le_bytes([b[0], b[1]]))).collect()
    };
    Ok(Tensor { shape, data })
}

/// An IEEE half-precision number as f32.
pub fn half_to_f32(h: u16) -> f32 {
    let sign = ((h >> 15) & 1) as u32;
    let exp = ((h >> 10) & 0x1f) as u32;
    let frac = (h & 0x3ff) as u32;
    let bits = if exp == 0 {
        if frac == 0 {
            sign << 31
        } else {
            // Subnormal: normalise it.
            let mut e = 127 - 15 + 1;
            let mut f = frac;
            while f & 0x400 == 0 {
                f <<= 1;
                e -= 1;
            }
            (sign << 31) | ((e as u32) << 23) | ((f & 0x3ff) << 13)
        }
    } else if exp == 0x1f {
        (sign << 31) | (0xff << 23) | (frac << 13)
    } else {
        (sign << 31) | ((exp + 127 - 15) << 23) | (frac << 13)
    };
    f32::from_bits(bits)
}

// ---------------------------------------------------------------- zip

fn u16_at(b: &[u8], at: usize) -> Result<usize, String> {
    b.get(at..at + 2).map(|s| u16::from_le_bytes([s[0], s[1]]) as usize).ok_or_else(|| "truncated zip".to_string())
}

fn u32_at(b: &[u8], at: usize) -> Result<usize, String> {
    b.get(at..at + 4).map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]) as usize).ok_or_else(|| "truncated zip".to_string())
}

/// Every file in a zip archive, by name. Stored and deflated entries only.
fn unzip(bytes: &[u8]) -> Result<Vec<(String, Vec<u8>)>, String> {
    // The end-of-directory record is in the last 64 KB + 22 bytes.
    let floor = bytes.len().saturating_sub(65_557);
    let eocd = (floor..bytes.len().saturating_sub(21)).rev().find(|&i| bytes[i..].starts_with(b"PK\x05\x06")).ok_or("not a zip archive")?;
    let count = u16_at(bytes, eocd + 10)?;
    let mut at = u32_at(bytes, eocd + 16)?;
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        if !bytes.get(at..).is_some_and(|b| b.starts_with(b"PK\x01\x02")) {
            return Err("damaged zip directory".into());
        }
        let method = u16_at(bytes, at + 10)?;
        let packed = u32_at(bytes, at + 20)?;
        let size = u32_at(bytes, at + 24)?;
        let name_len = u16_at(bytes, at + 28)?;
        let extra_len = u16_at(bytes, at + 30)?;
        let comment_len = u16_at(bytes, at + 32)?;
        let local = u32_at(bytes, at + 42)?;
        let name = String::from_utf8_lossy(bytes.get(at + 46..at + 46 + name_len).ok_or("truncated zip")?).into_owned();
        at += 46 + name_len + extra_len + comment_len;
        let data_at = local + 30 + u16_at(bytes, local + 26)? + u16_at(bytes, local + 28)?;
        let data = bytes.get(data_at..data_at + packed).ok_or("truncated zip entry")?;
        let content = match method {
            0 => data.to_vec(),
            8 => {
                use std::io::Read;
                let mut v = Vec::with_capacity(size);
                flate2::read::DeflateDecoder::new(data).read_to_end(&mut v).map_err(|e| e.to_string())?;
                v
            }
            m => return Err(format!("zip compression {m} is not supported")),
        };
        out.push((name, content));
    }
    Ok(out)
}

// ---------------------------------------------------------------- pickle

#[derive(Debug, Clone)]
enum Value {
    None,
    Bool,
    Int(i64),
    Str(String),
    Tuple(Vec<Value>),
    Dict(Vec<(Value, Value)>),
    /// A class or function named by GLOBAL.
    Global(String),
    /// A storage reference from BINPERSID: (dtype name, key).
    Storage(String, String),
    Tensor { key: String, dtype: String, offset: usize, shape: Vec<usize>, stride: Vec<usize> },
    Mark,
    Float,
    Bytes,
    List(Vec<Value>),
    /// An instance of a class the machine does not know (a module, say), as
    /// inert data: its class's name and the state BUILD gave it. Nothing of
    /// the class is ever run.
    Object {
        /// Named for debugging; nothing of it is used.
        #[allow(dead_code)]
        class: String,
        state: Box<Value>,
    },
}

#[derive(Default)]
struct Machine {
    stack: Vec<Value>,
    memo: HashMap<usize, Value>,
    /// Make unknown classes into [`Value::Object`]s rather than refuse
    /// them: for a checkpoint that saves whole modules.
    objects: bool,
    /// Every storage named, with its type, in the order first met.
    seen: Vec<(String, String)>,
}

fn ints(v: &Value) -> Result<Vec<usize>, String> {
    match v {
        Value::Tuple(items) => items.iter().map(|i| if let Value::Int(n) = i { Ok(*n as usize) } else { Err("expected ints".to_string()) }).collect(),
        _ => Err("expected a tuple".into()),
    }
}

impl Machine {
    fn pop(&mut self) -> Result<Value, String> {
        self.stack.pop().ok_or_else(|| "pickle stack underflow".to_string())
    }

    fn pop_mark(&mut self) -> Result<Vec<Value>, String> {
        let at = self.stack.iter().rposition(|v| matches!(v, Value::Mark)).ok_or("pickle has no mark")?;
        let items = self.stack.split_off(at + 1);
        self.stack.pop();
        Ok(items)
    }

    fn run(mut self, code: &[u8]) -> Result<Value, String> {
        self.run_from(code, 0).map(|(v, _)| v)
    }

    /// Run the pickle that starts at `start`; its value, and where it ends.
    fn run_from(&mut self, code: &[u8], start: usize) -> Result<(Value, usize), String> {
        self.stack.clear();
        self.memo.clear();
        let mut at = start;
        let take = |at: &mut usize, n: usize| -> Result<&[u8], String> {
            let s = code.get(*at..*at + n).ok_or("truncated pickle")?;
            *at += n;
            Ok(s)
        };
        loop {
            let op = *code.get(at).ok_or("truncated pickle")?;
            at += 1;
            match op {
                0x80 => {
                    take(&mut at, 1)?; // PROTO
                }
                b'}' => self.stack.push(Value::Dict(Vec::new())),
                b')' => self.stack.push(Value::Tuple(Vec::new())),
                b'N' => self.stack.push(Value::None),
                0x88 => self.stack.push(Value::Bool),
                0x89 => self.stack.push(Value::Bool),
                b'(' => self.stack.push(Value::Mark),
                b'K' => {
                    let b = take(&mut at, 1)?;
                    self.stack.push(Value::Int(b[0] as i64));
                }
                b'M' => {
                    let b = take(&mut at, 2)?;
                    self.stack.push(Value::Int(u16::from_le_bytes([b[0], b[1]]) as i64));
                }
                b'J' => {
                    let b = take(&mut at, 4)?;
                    self.stack.push(Value::Int(i32::from_le_bytes([b[0], b[1], b[2], b[3]]) as i64));
                }
                0x8a => {
                    // LONG1
                    let n = take(&mut at, 1)?[0] as usize;
                    let b = take(&mut at, n)?;
                    let mut v: i64 = 0;
                    for (i, byte) in b.iter().enumerate().take(8) {
                        v |= (*byte as i64) << (8 * i);
                    }
                    if n > 0 && n < 8 && b[n - 1] & 0x80 != 0 {
                        v -= 1i64 << (8 * n);
                    }
                    self.stack.push(Value::Int(v));
                }
                b'X' => {
                    let b = take(&mut at, 4)?;
                    let n = u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize;
                    let s = take(&mut at, n)?;
                    self.stack.push(Value::Str(String::from_utf8_lossy(s).into_owned()));
                }
                0x8c => {
                    // SHORT_BINUNICODE
                    let n = take(&mut at, 1)?[0] as usize;
                    let s = take(&mut at, n)?;
                    self.stack.push(Value::Str(String::from_utf8_lossy(s).into_owned()));
                }
                b'c' => {
                    // GLOBAL: "module\nname\n"
                    let rest = &code[at..];
                    let first = rest.iter().position(|&c| c == b'\n').ok_or("bad GLOBAL")?;
                    let second = rest[first + 1..].iter().position(|&c| c == b'\n').ok_or("bad GLOBAL")?;
                    let module = String::from_utf8_lossy(&rest[..first]);
                    let name = String::from_utf8_lossy(&rest[first + 1..first + 1 + second]);
                    at += first + second + 2;
                    self.stack.push(Value::Global(format!("{module}.{name}")));
                }
                0x93 => {
                    // STACK_GLOBAL
                    let name = self.pop()?;
                    let module = self.pop()?;
                    let (Value::Str(m), Value::Str(n)) = (module, name) else { return Err("bad STACK_GLOBAL".into()) };
                    self.stack.push(Value::Global(format!("{m}.{n}")));
                }
                b'q' => {
                    let i = take(&mut at, 1)?[0] as usize;
                    let top = self.stack.last().ok_or("empty stack")?.clone();
                    self.memo.insert(i, top);
                }
                b'r' => {
                    let b = take(&mut at, 4)?;
                    let i = u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize;
                    let top = self.stack.last().ok_or("empty stack")?.clone();
                    self.memo.insert(i, top);
                }
                0x94 => {
                    // MEMOIZE
                    let top = self.stack.last().ok_or("empty stack")?.clone();
                    self.memo.insert(self.memo.len(), top);
                }
                b'h' => {
                    let i = take(&mut at, 1)?[0] as usize;
                    self.stack.push(self.memo.get(&i).cloned().ok_or("bad memo")?);
                }
                b'j' => {
                    let b = take(&mut at, 4)?;
                    let i = u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize;
                    self.stack.push(self.memo.get(&i).cloned().ok_or("bad memo")?);
                }
                b't' => {
                    let items = self.pop_mark()?;
                    self.stack.push(Value::Tuple(items));
                }
                0x85 | 0x86 | 0x87 => {
                    let n = (op - 0x84) as usize;
                    if self.stack.len() < n {
                        return Err("pickle stack underflow".into());
                    }
                    let items = self.stack.split_off(self.stack.len() - n);
                    self.stack.push(Value::Tuple(items));
                }
                b'Q' => {
                    // BINPERSID: ('storage', <class>, key, location, numel)
                    let pid = self.pop()?;
                    let Value::Tuple(parts) = pid else { return Err("bad persistent id".into()) };
                    let dtype = match parts.get(1) {
                        Some(Value::Global(g)) => g.rsplit('.').next().unwrap_or("").to_string(),
                        Some(Value::Str(s)) => s.clone(),
                        _ => return Err("bad storage type".into()),
                    };
                    let key = match parts.get(2) {
                        Some(Value::Str(s)) => s.clone(),
                        Some(Value::Int(n)) => n.to_string(),
                        _ => return Err("bad storage key".into()),
                    };
                    if !self.seen.iter().any(|(k, _)| *k == key) {
                        self.seen.push((key.clone(), dtype.clone()));
                    }
                    self.stack.push(Value::Storage(dtype, key));
                }
                b'R' => {
                    let args = self.pop()?;
                    let func = self.pop()?;
                    let Value::Global(name) = func else { return Err("REDUCE on something not callable".into()) };
                    let Value::Tuple(args) = args else { return Err("REDUCE without arguments".into()) };
                    let value = match name.as_str() {
                        "torch._utils._rebuild_tensor_v2" | "torch._utils._rebuild_tensor" => {
                            let Some(Value::Storage(dtype, key)) = args.first().cloned() else { return Err("tensor without storage".into()) };
                            let offset = match args.get(1) {
                                Some(Value::Int(n)) => *n as usize,
                                _ => 0,
                            };
                            let shape = ints(args.get(2).ok_or("tensor without shape")?)?;
                            let stride = ints(args.get(3).ok_or("tensor without stride")?)?;
                            Value::Tensor { key, dtype, offset, shape, stride }
                        }
                        "collections.OrderedDict" => Value::Dict(Vec::new()),
                        // A Parameter is its tensor.
                        "torch._utils._rebuild_parameter" | "torch._utils._rebuild_parameter_with_state" if self.objects => {
                            args.into_iter().next().ok_or("parameter without a tensor")?
                        }
                        other if self.objects => Value::Object { class: other.to_string(), state: Box::new(Value::None) },
                        other => return Err(format!("checkpoint calls {other}, which is not allowed")),
                    };
                    self.stack.push(value);
                }
                b's' => {
                    let value = self.pop()?;
                    let key = self.pop()?;
                    match self.stack.last_mut() {
                        Some(Value::Dict(d)) => d.push((key, value)),
                        _ => return Err("SETITEM on something not a dict".into()),
                    }
                }
                b'u' => {
                    let items = self.pop_mark()?;
                    let Some(Value::Dict(d)) = self.stack.last_mut() else { return Err("SETITEMS on something not a dict".into()) };
                    let mut it = items.into_iter();
                    while let (Some(k), Some(v)) = (it.next(), it.next()) {
                        d.push((k, v));
                    }
                }
                b'b' => {
                    // BUILD: state for an object; dicts and tensors ignore it.
                    let state = self.pop()?;
                    if let Some(Value::Object { state: slot, .. }) = self.stack.last_mut() {
                        **slot = state;
                    }
                }
                0x81 | 0x92 if self.objects => {
                    // NEWOBJ / NEWOBJ_EX: an instance, made inert.
                    if op == 0x92 {
                        self.pop()?; // kwargs
                    }
                    self.pop()?; // args
                    let class = match self.pop()? {
                        Value::Global(name) => name,
                        _ => "object".to_string(),
                    };
                    self.stack.push(Value::Object { class, state: Box::new(Value::None) });
                }
                0x95 => {
                    take(&mut at, 8)?; // FRAME
                }
                b'G' => {
                    take(&mut at, 8)?;
                    self.stack.push(Value::Float);
                }
                b']' => self.stack.push(Value::List(Vec::new())),
                b'a' => {
                    let v = self.pop()?;
                    if let Some(Value::List(l)) = self.stack.last_mut() {
                        l.push(v);
                    }
                }
                b'e' => {
                    let items = self.pop_mark()?;
                    if let Some(Value::List(l)) = self.stack.last_mut() {
                        l.extend(items);
                    }
                }
                0x8f => self.stack.push(Value::List(Vec::new())), // EMPTY_SET
                0x90 => {
                    // ADDITEMS
                    self.pop_mark()?;
                }
                0x91 => {
                    // FROZENSET
                    self.pop_mark()?;
                    self.stack.push(Value::List(Vec::new()));
                }
                b'B' | 0x8e => {
                    let n = if op == b'B' { 4 } else { 8 };
                    let b = take(&mut at, n)?;
                    let mut len = 0usize;
                    for (i, byte) in b.iter().enumerate() {
                        len |= (*byte as usize) << (8 * i);
                    }
                    take(&mut at, len)?;
                    self.stack.push(Value::Bytes);
                }
                b'C' => {
                    let n = take(&mut at, 1)?[0] as usize;
                    take(&mut at, n)?;
                    self.stack.push(Value::Bytes);
                }
                0x8d => {
                    // BINUNICODE8
                    let b = take(&mut at, 8)?;
                    let n = u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]) as usize;
                    let s = take(&mut at, n)?;
                    self.stack.push(Value::Str(String::from_utf8_lossy(s).into_owned()));
                }
                b'I' | b'L' | b'F' | b'V' | b'S' => {
                    // Text forms of numbers and strings (protocol 0).
                    let rest = &code[at..];
                    let end = rest.iter().position(|&c| c == b'\n').ok_or("bad text value")?;
                    let text = String::from_utf8_lossy(&rest[..end]).into_owned();
                    at += end + 1;
                    self.stack.push(match op {
                        b'I' | b'L' => text.trim_end_matches('L').parse().map(Value::Int).unwrap_or(Value::Bool),
                        b'F' => Value::Float,
                        _ => Value::Str(text.trim_matches(|c| c == '\'' || c == '"').to_string()),
                    });
                }
                b'.' => return Ok((self.pop()?, at)),
                other => return Err(format!("unsupported pickle opcode 0x{other:02x}")),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A stored zip of `files`, as PyTorch writes them.
    pub fn zip(files: &[(&str, &[u8])]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut central = Vec::new();
        for (name, data) in files {
            let local = out.len() as u32;
            let mut crc = flate2::Crc::new();
            crc.update(data);
            let header = |sig: &[u8], central: bool| {
                let mut h = sig.to_vec();
                if central {
                    h.extend_from_slice(&[20, 0]);
                }
                h.extend_from_slice(&[20, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
                h.extend_from_slice(&crc.sum().to_le_bytes());
                h.extend_from_slice(&(data.len() as u32).to_le_bytes());
                h.extend_from_slice(&(data.len() as u32).to_le_bytes());
                h.extend_from_slice(&(name.len() as u16).to_le_bytes());
                h.extend_from_slice(&[0, 0]);
                if central {
                    h.extend_from_slice(&[0; 6]);
                    h.extend_from_slice(&[0; 4]);
                    h.extend_from_slice(&local.to_le_bytes());
                }
                h.extend_from_slice(name.as_bytes());
                h
            };
            out.extend(header(b"PK\x03\x04", false));
            out.extend_from_slice(data);
            central.extend(header(b"PK\x01\x02", true));
        }
        let dir_at = out.len() as u32;
        out.extend_from_slice(&central);
        out.extend_from_slice(b"PK\x05\x06\0\0\0\0");
        out.extend_from_slice(&(files.len() as u16).to_le_bytes());
        out.extend_from_slice(&(files.len() as u16).to_le_bytes());
        out.extend_from_slice(&(central.len() as u32).to_le_bytes());
        out.extend_from_slice(&dir_at.to_le_bytes());
        out.extend_from_slice(&[0, 0]);
        out
    }

    #[test]
    fn half_precision_reads_as_float() {
        assert_eq!(half_to_f32(0x3c00), 1.0);
        assert_eq!(half_to_f32(0xc000), -2.0);
        assert_eq!(half_to_f32(0x3555), 0.33325195);
        assert_eq!(half_to_f32(0x0001), 5.9604645e-8);
        assert_eq!(half_to_f32(0), 0.0);
    }

    #[test]
    fn reads_a_state_dict() {
        // {'params': OrderedDict(w=tensor 2x2 at offset 1 of storage "0")},
        // as torch.save writes it (protocol 2).
        let mut pkl: Vec<u8> = vec![0x80, 2, b'}', b'q', 0];
        let s = |p: &mut Vec<u8>, text: &str| {
            p.push(b'X');
            p.extend_from_slice(&(text.len() as u32).to_le_bytes());
            p.extend_from_slice(text.as_bytes());
        };
        s(&mut pkl, "params");
        pkl.extend_from_slice(b"ccollections\nOrderedDict\nq\x01)R");
        s(&mut pkl, "w");
        pkl.extend_from_slice(b"ctorch._utils\n_rebuild_tensor_v2\n(");
        pkl.push(b'(');
        s(&mut pkl, "storage");
        pkl.extend_from_slice(b"ctorch\nFloatStorage\n");
        s(&mut pkl, "0");
        s(&mut pkl, "cpu");
        pkl.extend_from_slice(&[b'K', 5, b't', b'Q', b'K', 1, b'K', 2, b'K', 2, 0x86, b'K', 2, b'K', 1, 0x86, 0x89]);
        pkl.extend_from_slice(b"ccollections\nOrderedDict\n)R");
        pkl.extend_from_slice(b"tRs");
        pkl.extend_from_slice(b"s.");
        let floats: Vec<u8> = [9.0f32, 1.0, 2.0, 3.0, 4.0].iter().flat_map(|f| f.to_le_bytes()).collect();
        let file = zip(&[("archive/data.pkl", &pkl), ("archive/data/0", &floats)]);
        let tensors = load(&file).unwrap();
        assert_eq!(tensors["w"], Tensor { shape: vec![2, 2], data: vec![1.0, 2.0, 3.0, 4.0] });
    }
}
