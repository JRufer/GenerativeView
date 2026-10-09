//! Container readers. These never decode pixels: they walk the file's chunk /
//! box structure, pick up dimensions and collect text blobs. A typical 2 MB
//! PNG costs a handful of small reads.

use std::fs::File;
use std::io::{self, BufReader, Read, Seek, SeekFrom};
use std::path::Path;

/// Upper bound for any single metadata blob we are willing to load.
const MAX_BLOB: u64 = 64 * 1024 * 1024;

#[derive(Debug, Default, Clone)]
pub struct RawMeta {
    pub width: u32,
    pub height: u32,
    pub duration_ms: u64,
    /// (key, text) in file order.
    pub texts: Vec<(String, String)>,
}

type Rd = BufReader<File>;

pub fn read_raw(path: &Path) -> io::Result<RawMeta> {
    let file = File::open(path)?;
    let len = file.metadata()?.len();
    let mut r = BufReader::with_capacity(16 * 1024, file);
    let mut magic = [0u8; 12];
    let n = read_some(&mut r, &mut magic)?;
    let magic = &magic[..n];
    let mut out = RawMeta::default();

    if magic.starts_with(b"\x89PNG\r\n\x1a\n") {
        read_png(&mut r, &mut out)?;
    } else if magic.starts_with(&[0xFF, 0xD8]) {
        read_jpeg(&mut r, &mut out)?;
    } else if n >= 12 && &magic[0..4] == b"RIFF" && &magic[8..12] == b"WEBP" {
        read_webp(&mut r, len, &mut out)?;
    } else if magic.starts_with(b"GIF8") && n >= 10 {
        out.width = u16::from_le_bytes([magic[6], magic[7]]) as u32;
        out.height = u16::from_le_bytes([magic[8], magic[9]]) as u32;
    } else if magic.starts_with(b"BM") {
        let mut b = [0u8; 8];
        r.seek(SeekFrom::Start(18))?;
        r.read_exact(&mut b)?;
        out.width = i32::from_le_bytes([b[0], b[1], b[2], b[3]]).unsigned_abs();
        out.height = i32::from_le_bytes([b[4], b[5], b[6], b[7]]).unsigned_abs();
    } else if n >= 8 && matches!(&magic[4..8], b"ftyp" | b"moov" | b"mdat" | b"free" | b"wide" | b"skip") {
        read_mp4(&mut r, len, &mut out)?;
    } else if magic.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]) {
        read_ebml(&mut r, len, &mut out)?;
    }
    Ok(out)
}

fn read_some(r: &mut impl Read, buf: &mut [u8]) -> io::Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match r.read(&mut buf[n..])? {
            0 => break,
            k => n += k,
        }
    }
    Ok(n)
}

fn read_vec(r: &mut impl Read, len: u64) -> io::Result<Vec<u8>> {
    let mut v = Vec::new();
    r.take(len).read_to_end(&mut v)?;
    if v.len() as u64 != len {
        return Err(io::ErrorKind::UnexpectedEof.into());
    }
    Ok(v)
}

/// Bytes -> String. Valid UTF-8 is taken as is, anything else as Latin-1.
fn text_from(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(s) => s.to_string(),
        Err(_) => bytes.iter().map(|&b| b as char).collect(),
    }
}

fn inflate(data: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    flate2::read::ZlibDecoder::new(data).take(MAX_BLOB).read_to_end(&mut out).ok()?;
    Some(out)
}

// ---------------------------------------------------------------- PNG

/// Keys that mean "this is what we came for"; once one is seen there is no
/// reason to walk the image data that follows.
const GEN_KEYS: &[&str] = &[
    "prompt",
    "workflow",
    "parameters",
    "invokeai_metadata",
    "invokeai_graph",
    "sd-metadata",
    "dream",
    "comment",
    "usercomment",
];

fn has_gen_key(out: &RawMeta) -> bool {
    out.texts.iter().any(|(k, _)| GEN_KEYS.iter().any(|g| k.eq_ignore_ascii_case(g)))
}

fn read_png(r: &mut Rd, out: &mut RawMeta) -> io::Result<()> {
    r.seek(SeekFrom::Start(8))?;
    let mut hdr = [0u8; 8];
    let mut seen_idat = false;
    loop {
        if r.read_exact(&mut hdr).is_err() {
            break;
        }
        let len = u32::from_be_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]) as u64;
        match &hdr[4..8] {
            b"IHDR" if len >= 8 => {
                let mut b = [0u8; 8];
                r.read_exact(&mut b)?;
                out.width = u32::from_be_bytes([b[0], b[1], b[2], b[3]]);
                out.height = u32::from_be_bytes([b[4], b[5], b[6], b[7]]);
                r.seek_relative(len as i64 - 8 + 4)?;
            }
            kind @ (b"tEXt" | b"zTXt" | b"iTXt" | b"eXIf") if len <= MAX_BLOB => {
                let kind = [kind[0], kind[1], kind[2], kind[3]];
                let Ok(data) = read_vec(r, len) else { break };
                r.seek_relative(4)?;
                png_text(&kind, &data, &mut out.texts);
            }
            b"IDAT" => {
                if !seen_idat {
                    seen_idat = true;
                    if has_gen_key(out) {
                        break;
                    }
                }
                r.seek_relative(len as i64 + 4)?;
            }
            b"IEND" => break,
            _ => r.seek_relative(len as i64 + 4)?,
        }
    }
    Ok(())
}

fn png_text(kind: &[u8; 4], data: &[u8], texts: &mut Vec<(String, String)>) {
    if kind == b"eXIf" {
        parse_exif(data, texts);
        return;
    }
    let Some(nul) = data.iter().position(|&b| b == 0) else { return };
    let key = text_from(&data[..nul]);
    let rest = &data[nul + 1..];
    let value = match kind {
        b"tEXt" => Some(text_from(rest)),
        b"zTXt" => rest.get(1..).and_then(inflate).map(|v| text_from(&v)),
        _ => {
            // iTXt: compression flag, method, language\0, translated keyword\0, text
            (|| {
                let flag = *rest.first()?;
                let rest = rest.get(2..)?;
                let lang_end = rest.iter().position(|&b| b == 0)?;
                let rest = &rest[lang_end + 1..];
                let trans_end = rest.iter().position(|&b| b == 0)?;
                let body = &rest[trans_end + 1..];
                if flag == 1 {
                    inflate(body).map(|v| text_from(&v))
                } else {
                    Some(text_from(body))
                }
            })()
        }
    };
    if let Some(v) = value {
        texts.push((key, v));
    }
}

// ---------------------------------------------------------------- EXIF

/// Pull the few text-bearing tags out of an EXIF/TIFF block.
pub(crate) fn parse_exif(data: &[u8], texts: &mut Vec<(String, String)>) {
    let data = data.strip_prefix(b"Exif\0\0").unwrap_or(data);
    if data.len() < 8 {
        return;
    }
    let le = match &data[0..2] {
        b"II" => true,
        b"MM" => false,
        _ => return,
    };
    let u16_at = |o: usize| -> Option<u16> {
        let b = data.get(o..o + 2)?;
        Some(if le { u16::from_le_bytes([b[0], b[1]]) } else { u16::from_be_bytes([b[0], b[1]]) })
    };
    let u32_at = |o: usize| -> Option<u32> {
        let b = data.get(o..o + 4)?;
        Some(if le {
            u32::from_le_bytes([b[0], b[1], b[2], b[3]])
        } else {
            u32::from_be_bytes([b[0], b[1], b[2], b[3]])
        })
    };

    // (ifd offset, is Exif sub-IFD)
    let mut pending = vec![(u32_at(4).unwrap_or(0) as usize, false)];
    let mut visited = 0;
    while let Some((ifd, is_exif)) = pending.pop() {
        visited += 1;
        if visited > 4 {
            break;
        }
        let Some(count) = u16_at(ifd) else { continue };
        for i in 0..count as usize {
            let e = ifd + 2 + i * 12;
            let (Some(tag), Some(typ), Some(n)) = (u16_at(e), u16_at(e + 2), u32_at(e + 4)) else { break };
            if tag == 0x8769 && !is_exif {
                if let Some(off) = u32_at(e + 8) {
                    pending.push((off as usize, true));
                }
                continue;
            }
            // BYTE, ASCII, UNDEFINED are the one-byte types that carry text.
            if !matches!(typ, 1 | 2 | 7) {
                continue;
            }
            let n = n as usize;
            let bytes = if n <= 4 {
                data.get(e + 8..e + 8 + n)
            } else {
                u32_at(e + 8).and_then(|off| data.get(off as usize..(off as usize).checked_add(n)?))
            };
            let Some(bytes) = bytes else { continue };
            if is_exif {
                if tag == 0x9286 {
                    let text = user_comment(bytes, le);
                    if !text.trim().is_empty() {
                        texts.push(("UserComment".into(), text));
                    }
                }
                continue;
            }
            if typ != 2 {
                continue;
            }
            let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
            let value = text_from(&bytes[..end]);
            // ComfyUI stores `key:{json}` in ordinary ASCII tags (Make, Model...).
            if let Some((k, v)) = split_keyed_json(&value) {
                texts.push((k.to_string(), v.to_string()));
                continue;
            }
            let name = match tag {
                0x010e => "ImageDescription",
                0x0131 => "Software",
                _ => continue,
            };
            if !value.trim().is_empty() {
                texts.push((name.into(), value));
            }
        }
    }
}

/// "workflow:{...}" -> ("workflow", "{...}")
fn split_keyed_json(s: &str) -> Option<(&str, &str)> {
    let colon = s.find(':')?;
    let (key, rest) = (&s[..colon], &s[colon + 1..]);
    if key.is_empty() || key.len() > 64 || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-') {
        return None;
    }
    let first = rest.trim_start().bytes().next()?;
    matches!(first, b'{' | b'[').then_some((key, rest))
}

/// EXIF UserComment: 8-byte charset id followed by the text.
fn user_comment(bytes: &[u8], tiff_le: bool) -> String {
    if bytes.len() < 8 {
        return text_from(bytes);
    }
    let (id, body) = bytes.split_at(8);
    if id.starts_with(b"UNICODE") {
        // Byte order is whatever the writer felt like (piexif: big-endian,
        // others: the TIFF order). Zero high bytes give ASCII-heavy text away.
        let even_zero = body.iter().step_by(2).filter(|&&b| b == 0).count();
        let odd_zero = body.iter().skip(1).step_by(2).filter(|&&b| b == 0).count();
        let be = if even_zero != odd_zero { even_zero > odd_zero } else { !tiff_le };
        let units: Vec<u16> = body
            .chunks_exact(2)
            .map(|c| if be { u16::from_be_bytes([c[0], c[1]]) } else { u16::from_le_bytes([c[0], c[1]]) })
            .collect();
        return String::from_utf16_lossy(&units).trim_end_matches('\0').to_string();
    }
    if id.starts_with(b"ASCII") || id.iter().all(|&b| b == 0) {
        return text_from(body).trim_end_matches('\0').to_string();
    }
    // No recognisable header: some writers put the text straight in.
    text_from(bytes).trim_end_matches('\0').to_string()
}

// ---------------------------------------------------------------- JPEG

fn read_jpeg(r: &mut Rd, out: &mut RawMeta) -> io::Result<()> {
    r.seek(SeekFrom::Start(2))?;
    let mut b = [0u8; 1];
    loop {
        if r.read_exact(&mut b).is_err() {
            break;
        }
        if b[0] != 0xFF {
            continue;
        }
        let mut marker = 0xFF;
        while marker == 0xFF {
            if r.read_exact(&mut b).is_err() {
                return Ok(());
            }
            marker = b[0];
        }
        match marker {
            0x00 | 0x01 | 0xD0..=0xD8 => continue,
            0xD9 | 0xDA => break,
            _ => {}
        }
        let mut lb = [0u8; 2];
        if r.read_exact(&mut lb).is_err() {
            break;
        }
        let len = u16::from_be_bytes(lb) as u64;
        if len < 2 {
            break;
        }
        let len = len - 2;
        match marker {
            0xE1 => {
                let Ok(data) = read_vec(r, len) else { break };
                if data.starts_with(b"Exif\0\0") {
                    parse_exif(&data, &mut out.texts);
                }
            }
            0xFE => {
                let Ok(data) = read_vec(r, len) else { break };
                let text = text_from(&data).trim_end_matches('\0').to_string();
                if !text.trim().is_empty() {
                    out.texts.push(("Comment".into(), text));
                }
            }
            0xC0..=0xCF if !matches!(marker, 0xC4 | 0xC8 | 0xCC) && len >= 5 => {
                let mut s = [0u8; 5];
                r.read_exact(&mut s)?;
                out.height = u16::from_be_bytes([s[1], s[2]]) as u32;
                out.width = u16::from_be_bytes([s[3], s[4]]) as u32;
                r.seek_relative(len as i64 - 5)?;
            }
            _ => r.seek_relative(len as i64)?,
        }
    }
    Ok(())
}

// ---------------------------------------------------------------- WebP

fn read_webp(r: &mut Rd, file_len: u64, out: &mut RawMeta) -> io::Result<()> {
    let mut pos = 12u64;
    let mut hdr = [0u8; 8];
    while pos + 8 <= file_len {
        r.seek(SeekFrom::Start(pos))?;
        if r.read_exact(&mut hdr).is_err() {
            break;
        }
        let size = u32::from_le_bytes([hdr[4], hdr[5], hdr[6], hdr[7]]) as u64;
        match &hdr[0..4] {
            b"VP8X" if size >= 10 => {
                let mut b = [0u8; 10];
                r.read_exact(&mut b)?;
                out.width = 1 + u32::from_le_bytes([b[4], b[5], b[6], 0]);
                out.height = 1 + u32::from_le_bytes([b[7], b[8], b[9], 0]);
            }
            b"VP8 " if out.width == 0 && size >= 10 => {
                let mut b = [0u8; 10];
                r.read_exact(&mut b)?;
                if b[3..6] == [0x9d, 0x01, 0x2a] {
                    out.width = (u16::from_le_bytes([b[6], b[7]]) & 0x3fff) as u32;
                    out.height = (u16::from_le_bytes([b[8], b[9]]) & 0x3fff) as u32;
                }
            }
            b"VP8L" if out.width == 0 && size >= 5 => {
                let mut b = [0u8; 5];
                r.read_exact(&mut b)?;
                if b[0] == 0x2f {
                    let bits = u32::from_le_bytes([b[1], b[2], b[3], b[4]]);
                    out.width = (bits & 0x3fff) + 1;
                    out.height = ((bits >> 14) & 0x3fff) + 1;
                }
            }
            b"EXIF" if size <= MAX_BLOB => {
                if let Ok(data) = read_vec(r, size) {
                    parse_exif(&data, &mut out.texts);
                }
            }
            _ => {}
        }
        pos += 8 + size + (size & 1);
    }
    Ok(())
}

// ---------------------------------------------------------------- MP4 / MOV

fn read_mp4(r: &mut Rd, file_len: u64, out: &mut RawMeta) -> io::Result<()> {
    let mut pos = 0u64;
    let mut hdr = [0u8; 8];
    while pos + 8 <= file_len {
        r.seek(SeekFrom::Start(pos))?;
        if r.read_exact(&mut hdr).is_err() {
            break;
        }
        let mut size = u32::from_be_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]) as u64;
        let mut header = 8u64;
        if size == 1 {
            let mut big = [0u8; 8];
            r.read_exact(&mut big)?;
            size = u64::from_be_bytes(big);
            header = 16;
        } else if size == 0 {
            size = file_len - pos;
        }
        if size < header {
            break;
        }
        if &hdr[4..8] == b"moov" {
            if size - header <= MAX_BLOB {
                if let Ok(data) = read_vec(r, size - header) {
                    parse_moov(&data, out);
                }
            }
            break;
        }
        pos += size;
    }
    Ok(())
}

/// Iterate the child boxes of an ISO-BMFF container payload.
fn boxes(data: &[u8]) -> impl Iterator<Item = ([u8; 4], &[u8])> {
    let mut pos = 0usize;
    std::iter::from_fn(move || {
        let hdr = data.get(pos..pos + 8)?;
        let mut size = u32::from_be_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]) as usize;
        let kind = [hdr[4], hdr[5], hdr[6], hdr[7]];
        let mut header = 8;
        if size == 1 {
            let big = data.get(pos + 8..pos + 16)?;
            size = u64::from_be_bytes(big.try_into().ok()?) as usize;
            header = 16;
        } else if size == 0 {
            size = data.len() - pos;
        }
        if size < header {
            return None;
        }
        let payload = data.get(pos + header..pos.checked_add(size)?)?;
        pos += size;
        Some((kind, payload))
    })
}

fn be32(b: &[u8], o: usize) -> Option<u32> {
    let s = b.get(o..o + 4)?;
    Some(u32::from_be_bytes([s[0], s[1], s[2], s[3]]))
}

fn be64(b: &[u8], o: usize) -> Option<u64> {
    let s = b.get(o..o + 8)?;
    Some(u64::from_be_bytes(s.try_into().ok()?))
}

fn parse_moov(data: &[u8], out: &mut RawMeta) {
    for (kind, p) in boxes(data) {
        match &kind {
            b"mvhd" => {
                let (scale, dur) = if p.first() == Some(&1) {
                    (be32(p, 20), be64(p, 24))
                } else {
                    (be32(p, 12), be32(p, 16).map(u64::from))
                };
                if let (Some(scale), Some(dur)) = (scale, dur) {
                    if scale > 0 {
                        out.duration_ms = dur.saturating_mul(1000) / scale as u64;
                    }
                }
            }
            b"trak" => {
                for (k2, p2) in boxes(p) {
                    if &k2 == b"tkhd" && p2.len() >= 8 {
                        // Width and height are the last two 16.16 fields.
                        let w = be32(p2, p2.len() - 8).unwrap_or(0) >> 16;
                        let h = be32(p2, p2.len() - 4).unwrap_or(0) >> 16;
                        if w > 0 && h > 0 && out.width == 0 {
                            out.width = w;
                            out.height = h;
                        }
                    }
                }
            }
            b"udta" => {
                for (k2, p2) in boxes(p) {
                    if &k2 == b"meta" {
                        parse_mp4_meta(p2, &mut out.texts);
                    } else if k2[0] == 0xA9 && p2.len() > 4 {
                        // QuickTime text atom: u16 length, u16 language, text.
                        let n = u16::from_be_bytes([p2[0], p2[1]]) as usize;
                        if let Some(t) = p2.get(4..4 + n) {
                            texts_push(&mut out.texts, itunes_name(&k2), text_from(t));
                        }
                    }
                }
            }
            b"meta" => parse_mp4_meta(p, &mut out.texts),
            _ => {}
        }
    }
}

fn itunes_name(kind: &[u8; 4]) -> String {
    match kind {
        [0xA9, b'c', b'm', b't'] => "comment".into(),
        [0xA9, b'n', b'a', b'm'] => "title".into(),
        [0xA9, b'd', b'e', b's'] | b"desc" => "description".into(),
        [0xA9, b't', b'o', b'o'] => "encoder".into(),
        _ => kind.iter().filter(|b| b.is_ascii_graphic()).map(|&b| b as char).collect(),
    }
}

fn texts_push(texts: &mut Vec<(String, String)>, key: String, value: String) {
    if !key.is_empty() && !value.trim().is_empty() {
        texts.push((key, value));
    }
}

fn parse_mp4_meta(p: &[u8], texts: &mut Vec<(String, String)>) {
    // ISO files make `meta` a FullBox (4 bytes of version/flags); QuickTime
    // files do not. Look for the hdlr box to tell them apart.
    let body = if p.get(4..8) == Some(b"hdlr") { p } else { p.get(4..).unwrap_or(&[]) };
    let mut keys: Vec<String> = Vec::new();
    for (kind, payload) in boxes(body) {
        match &kind {
            b"keys" => {
                let count = be32(payload, 4).unwrap_or(0) as usize;
                let mut pos = 8;
                for _ in 0..count.min(4096) {
                    let Some(size) = be32(payload, pos) else { break };
                    let size = size as usize;
                    let Some(name) = payload.get(pos + 8..pos + size) else { break };
                    keys.push(text_from(name));
                    pos += size.max(8);
                }
            }
            b"ilst" => {
                for (item, ip) in boxes(payload) {
                    let idx = u32::from_be_bytes(item) as usize;
                    let name = if idx >= 1 && idx <= keys.len() { keys[idx - 1].clone() } else { itunes_name(&item) };
                    for (dk, dp) in boxes(ip) {
                        if &dk == b"data" && dp.len() >= 8 {
                            texts_push(texts, name.clone(), text_from(&dp[8..]));
                        }
                    }
                }
            }
            _ => {}
        }
    }
}

// ---------------------------------------------------------------- WebM / MKV

/// Read an EBML element id (marker bits kept).
fn ebml_id(d: &[u8], pos: &mut usize) -> Option<u32> {
    let first = *d.get(*pos)?;
    let len = first.leading_zeros() as usize + 1;
    if len > 4 {
        return None;
    }
    let bytes = d.get(*pos..*pos + len)?;
    *pos += len;
    Some(bytes.iter().fold(0u32, |a, &b| (a << 8) | b as u32))
}

/// Read an EBML size (marker bit stripped). None in the Option = unknown size.
fn ebml_size(d: &[u8], pos: &mut usize) -> Option<Option<u64>> {
    let first = *d.get(*pos)?;
    let len = first.leading_zeros() as usize + 1;
    if len > 8 {
        return None;
    }
    let bytes = d.get(*pos..*pos + len)?;
    *pos += len;
    let mut v = (first as u64) & ((1u64 << (8 - len)) - 1);
    for &b in &bytes[1..] {
        v = (v << 8) | b as u64;
    }
    let all_ones = v == (1u64 << (7 * len)) - 1;
    Some(if all_ones { None } else { Some(v) })
}

fn ebml_children(d: &[u8]) -> impl Iterator<Item = (u32, &[u8])> {
    let mut pos = 0usize;
    std::iter::from_fn(move || {
        let id = ebml_id(d, &mut pos)?;
        let size = ebml_size(d, &mut pos)??;
        let payload = d.get(pos..pos.checked_add(size as usize)?)?;
        pos += size as usize;
        Some((id, payload))
    })
}

fn ebml_uint(d: &[u8]) -> u64 {
    d.iter().take(8).fold(0u64, |a, &b| (a << 8) | b as u64)
}

fn read_ebml(r: &mut Rd, file_len: u64, out: &mut RawMeta) -> io::Result<()> {
    let mut pos = 0u64;
    let mut segment_seen = false;
    let mut timecode_scale = 1_000_000u64;
    let mut duration = 0f64;
    let mut hdr = [0u8; 12];
    while pos < file_len {
        r.seek(SeekFrom::Start(pos))?;
        let n = read_some(r, &mut hdr)?;
        let mut p = 0usize;
        let Some(id) = ebml_id(&hdr[..n], &mut p) else { break };
        let Some(size) = ebml_size(&hdr[..n], &mut p) else { break };
        let body = pos + p as u64;
        match id {
            // Segment: descend rather than skip.
            0x18538067 if !segment_seen => {
                segment_seen = true;
                pos = body;
                continue;
            }
            // Info, Tracks, Tags
            0x1549A966 | 0x1654AE6B | 0x1254C367 => {
                let Some(size) = size else { break };
                if size > MAX_BLOB {
                    break;
                }
                r.seek(SeekFrom::Start(body))?;
                let Ok(data) = read_vec(r, size) else { break };
                match id {
                    0x1549A966 => {
                        for (cid, cp) in ebml_children(&data) {
                            match cid {
                                0x2AD7B1 => timecode_scale = ebml_uint(cp).max(1),
                                0x4489 => {
                                    duration = match cp.len() {
                                        4 => f32::from_be_bytes(cp.try_into().unwrap()) as f64,
                                        8 => f64::from_be_bytes(cp.try_into().unwrap()),
                                        _ => 0.0,
                                    }
                                }
                                _ => {}
                            }
                        }
                    }
                    0x1654AE6B => {
                        for (cid, entry) in ebml_children(&data) {
                            if cid != 0xAE {
                                continue;
                            }
                            for (eid, video) in ebml_children(entry) {
                                if eid != 0xE0 {
                                    continue;
                                }
                                for (vid, vp) in ebml_children(video) {
                                    match vid {
                                        0xB0 if out.width == 0 => out.width = ebml_uint(vp) as u32,
                                        0xBA if out.height == 0 => out.height = ebml_uint(vp) as u32,
                                        _ => {}
                                    }
                                }
                            }
                        }
                    }
                    _ => {
                        for (cid, tag) in ebml_children(&data) {
                            if cid == 0x7373 {
                                for (tid, simple) in ebml_children(tag) {
                                    if tid == 0x67C8 {
                                        ebml_simple_tag(simple, &mut out.texts);
                                    }
                                }
                            }
                        }
                    }
                }
                pos = body + size;
            }
            _ => match size {
                Some(size) => pos = body + size,
                // Unknown-size element (live-streamed cluster): nothing more
                // can be located without parsing the stream itself.
                None => break,
            },
        }
    }
    if duration > 0.0 {
        out.duration_ms = (duration * timecode_scale as f64 / 1_000_000.0) as u64;
    }
    Ok(())
}

fn ebml_simple_tag(d: &[u8], texts: &mut Vec<(String, String)>) {
    let mut name = String::new();
    let mut value = String::new();
    for (id, p) in ebml_children(d) {
        match id {
            0x45A3 => name = text_from(p),
            0x4487 => value = text_from(p),
            _ => {}
        }
    }
    // Matroska tag names are conventionally upper case; normalise so the
    // parsers can look for "prompt" / "workflow" / "comment".
    texts_push(texts, name.to_ascii_lowercase(), value);
}
