//! Lenient JSON helpers. ComfyUI happily writes `NaN` and `Infinity` (Python's
//! json module allows them), which strict parsers reject.

use serde_json::Value;

pub fn parse_lenient(s: &str) -> Option<Value> {
    match serde_json::from_str::<Value>(s) {
        Ok(v) => Some(v),
        Err(_) => serde_json::from_str::<Value>(&sanitize(s)).ok(),
    }
}

/// Replace bare NaN / Infinity / -Infinity tokens (outside strings) with null.
fn sanitize(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    let mut in_str = false;
    let mut start = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if in_str {
            if b == b'\\' {
                i += 2;
                continue;
            }
            if b == b'"' {
                in_str = false;
            }
            i += 1;
            continue;
        }
        if b == b'"' {
            in_str = true;
            i += 1;
            continue;
        }
        let rest = &bytes[i..];
        let token = if rest.starts_with(b"NaN") {
            3
        } else if rest.starts_with(b"-Infinity") {
            9
        } else if rest.starts_with(b"Infinity") {
            8
        } else {
            0
        };
        if token > 0 {
            out.push_str(&s[start..i]);
            out.push_str("null");
            i += token;
            start = i;
            continue;
        }
        i += 1;
    }
    out.push_str(&s[start.min(s.len())..]);
    out
}

/// Render a scalar JSON value the way a person would type it.
pub fn scalar(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(number(n)),
        Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

pub fn number(n: &serde_json::Number) -> String {
    if let Some(i) = n.as_i64() {
        return i.to_string();
    }
    if let Some(u) = n.as_u64() {
        return u.to_string();
    }
    match n.as_f64() {
        Some(f) => float(f),
        None => n.to_string(),
    }
}

/// 7.0 -> "7", 0.30000000000000004 -> "0.3"
pub fn float(f: f64) -> String {
    if f.is_finite() && f == f.trunc() && f.abs() < 1e15 {
        return format!("{}", f as i64);
    }
    let s = format!("{:.6}", f);
    let s = s.trim_end_matches('0').trim_end_matches('.');
    s.to_string()
}

/// Any JSON value as display text: scalars bare, containers compact.
pub fn display(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        other => scalar(other).unwrap_or_else(|| other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nan_is_tolerated() {
        let v = parse_lenient(r#"{"a": NaN, "b": "NaN stays", "c": [Infinity, -Infinity, 1]}"#).unwrap();
        assert!(v["a"].is_null());
        assert_eq!(v["b"], "NaN stays");
        assert_eq!(v["c"][2], 1);
    }

    #[test]
    fn floats_are_tidy() {
        assert_eq!(float(7.0), "7");
        assert_eq!(float(0.30000000000000004), "0.3");
        assert_eq!(float(1.25), "1.25");
    }
}
