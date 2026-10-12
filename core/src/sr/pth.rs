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

/// The tensors of a checkpoint by name, from its state dict (or the
/// `params` / `params_ema` / `state_dict` dict inside it).
pub fn load(bytes: &[u8]) -> Result<HashMap<String, Tensor>, String> {
    let files = unzip(bytes)?;
    let (pkl_name, pkl) = files.iter().find(|(name, _)| name.ends_with("/data.pkl") || *name == "data.pkl").ok_or("not a PyTorch checkpoint: no data.pkl")?;
    let prefix = pkl_name.strip_suffix("data.pkl").unwrap_or("");
    let storage = |key: &str| -> Result<&[u8], String> {
        let name = format!("{prefix}data/{key}");
        files.iter().find(|(n, _)| *n == name).map(|(_, b)| b.as_slice()).ok_or_else(|| format!("checkpoint is missing {name}"))
    };
    let root = Machine::default().run(pkl)?;
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
        if dtype != "FloatStorage" {
            return Err(format!("{name}: {dtype} tensors are not supported"));
        }
        let raw = storage(&key)?;
        let count: usize = shape.iter().product();
        // Contiguous, row-major: what a saved state dict holds.
        let mut expect = 1;
        for (dim, st) in shape.iter().zip(&stride).rev() {
            if *dim > 1 && *st != expect {
                return Err(format!("{name}: tensor is not contiguous"));
            }
            expect *= dim;
        }
        let start = offset * 4;
        let end = start + count * 4;
        if end > raw.len() {
            return Err(format!("{name}: storage is too short"));
        }
        let data = raw[start..end].chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect();
        out.insert(name, Tensor { shape, data });
    }
    Ok(out)
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
}

#[derive(Default)]
struct Machine {
    stack: Vec<Value>,
    memo: HashMap<usize, Value>,
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
        let mut at = 0;
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
                    self.pop()?;
                }
                b'.' => return self.pop(),
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
