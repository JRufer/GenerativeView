//! Folder navigation for the side panel: starting points and child listings.

use serde::Serialize;
use std::path::Path;

#[derive(Debug, Serialize, PartialEq)]
pub struct Place {
    pub name: String,
    pub path: String,
    /// home | folder | drive | root
    pub kind: &'static str,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct DirEntry {
    pub name: String,
    pub path: String,
    /// Whether it has sub-folders of its own (controls the expand arrow).
    pub has_sub: bool,
}

fn place(name: &str, path: &str, kind: &'static str) -> Option<Place> {
    Path::new(path).is_dir().then(|| Place { name: name.to_string(), path: path.to_string(), kind })
}

/// Sensible places to start browsing from on this device.
pub fn roots() -> Vec<Place> {
    let mut out: Vec<Place> = Vec::new();
    let mut add = |p: Option<Place>| {
        if let Some(p) = p {
            if !out.iter().any(|o| o.path == p.path) {
                out.push(p);
            }
        }
    };

    if cfg!(target_os = "android") {
        let internal = "/storage/emulated/0";
        add(place("Internal storage", internal, "home"));
        for sub in ["Pictures", "DCIM", "Download", "Documents"] {
            add(place(sub, &format!("{internal}/{sub}"), "folder"));
        }
        // Removable volumes show up as /storage/XXXX-XXXX.
        if let Ok(rd) = std::fs::read_dir("/storage") {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().to_string();
                if name != "emulated" && name != "self" && e.path().is_dir() {
                    add(place(&format!("Storage {name}"), &format!("/storage/{name}"), "drive"));
                }
            }
        }
        return out;
    }

    if let Ok(home) = std::env::var("HOME") {
        let home = home.trim_end_matches('/').to_string();
        add(place("Home", &home, "home"));
        for sub in ["Pictures", "Downloads", "ComfyUI/output", "invokeai/outputs", "stable-diffusion-webui/outputs"] {
            let name = sub.rsplit('/').next().unwrap_or(sub);
            let label = if sub.contains('/') { sub.to_string() } else { name.to_string() };
            add(place(&label, &format!("{home}/{sub}"), "folder"));
        }
    }
    // Mounted drives.
    if let Ok(mounts) = std::fs::read_to_string("/proc/mounts") {
        for line in mounts.lines() {
            let Some(mount) = line.split(' ').nth(1) else { continue };
            // /proc/mounts escapes spaces as \040.
            let mount = mount.replace("\\040", " ");
            if ["/run/media/", "/media/", "/mnt/"].iter().any(|p| mount.starts_with(p)) {
                let name = mount.rsplit('/').next().unwrap_or(&mount).to_string();
                add(place(&name, &mount, "drive"));
            }
        }
    }
    add(place("File system", "/", "root"));
    out
}

/// Case-insensitive ordering that treats digit runs as numbers, so
/// "batch2" sorts before "batch10".
pub fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let (mut ai, mut bi) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (ai.peek().copied(), bi.peek().copied()) {
            (None, None) => return a.cmp(b),
            (None, _) => return Ordering::Less,
            (_, None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let take = |it: &mut std::iter::Peekable<std::str::Chars>| {
                    let mut n = String::new();
                    while let Some(c) = it.peek().filter(|c| c.is_ascii_digit()) {
                        n.push(*c);
                        it.next();
                    }
                    n
                };
                let (na, nb) = (take(&mut ai), take(&mut bi));
                let (ta, tb) = (na.trim_start_matches('0'), nb.trim_start_matches('0'));
                let ord = ta.len().cmp(&tb.len()).then_with(|| ta.cmp(tb));
                if ord != Ordering::Equal {
                    return ord;
                }
            }
            (Some(x), Some(y)) => {
                let ord = x.to_lowercase().cmp(y.to_lowercase());
                if ord != Ordering::Equal {
                    return ord;
                }
                ai.next();
                bi.next();
            }
        }
    }
}

/// Sub-folders of `path`, sorted. Hidden folders are left out.
pub fn list_dirs(path: &str) -> std::io::Result<Vec<DirEntry>> {
    let mut out = Vec::new();
    for e in std::fs::read_dir(path)?.flatten() {
        let Ok(name) = e.file_name().into_string() else { continue };
        if name.starts_with('.') {
            continue;
        }
        // is_dir() follows symlinks, so linked folders are browsable.
        let p = e.path();
        if !p.is_dir() {
            continue;
        }
        let Some(full) = p.to_str() else { continue };
        out.push(DirEntry { has_sub: has_subdir(&p), name, path: full.to_string() });
    }
    out.sort_by(|a, b| natural_cmp(&a.name, &b.name));
    Ok(out)
}

fn has_subdir(path: &Path) -> bool {
    let Ok(rd) = std::fs::read_dir(path) else { return false };
    // Bounded peek: in a folder of ten thousand images, give up and call it
    // expandable rather than read the whole listing.
    for (i, e) in rd.flatten().enumerate() {
        if i >= 512 {
            return true;
        }
        if e.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        if e.file_type().map_or(false, |t| t.is_dir() || t.is_symlink() && e.path().is_dir()) {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn natural_order() {
        let mut v = vec!["batch10", "Batch2", "batch1", "alpha", "batch02b", "Zed"];
        v.sort_by(|a, b| natural_cmp(a, b));
        assert_eq!(v, ["alpha", "batch1", "Batch2", "batch02b", "batch10", "Zed"]);
    }

    #[test]
    fn lists_folders_only() {
        let tmp = tempfile::tempdir().unwrap();
        for d in ["b/inner", "a", ".hidden", "c10", "c9"] {
            std::fs::create_dir_all(tmp.path().join(d)).unwrap();
        }
        std::fs::write(tmp.path().join("file.png"), b"x").unwrap();
        let dirs = list_dirs(tmp.path().to_str().unwrap()).unwrap();
        let names: Vec<_> = dirs.iter().map(|d| (d.name.as_str(), d.has_sub)).collect();
        assert_eq!(names, [("a", false), ("b", true), ("c9", false), ("c10", false)]);
        assert!(list_dirs("/definitely/not/here").is_err());
    }
}
