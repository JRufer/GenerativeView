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

/// Normalize a filesystem path to use forward slashes (`/`) across all platforms,
/// stripping Windows extended-length verbatim prefixes (`\\?\`) and redundant
/// trailing slashes while preserving Unix root (`/`) and Windows drive roots (`C:/`).
pub fn normalize_path(raw: &str) -> String {
    let stripped = if let Some(unc) = raw.strip_prefix(r"\\?\UNC\") {
        format!("//{unc}")
    } else if let Some(verbatim) = raw.strip_prefix(r"\\?\") {
        verbatim.to_string()
    } else {
        raw.to_string()
    };
    let mut s = stripped.replace('\\', "/");
    while s.len() > 1 && s.ends_with('/') {
        // Keep the trailing slash on bare Windows drive roots like `C:/`.
        if s.len() == 3 && s.as_bytes()[1] == b':' && s.as_bytes()[0].is_ascii_alphabetic() {
            break;
        }
        s.pop();
    }
    s
}

fn place(name: &str, path: &str, kind: &'static str) -> Option<Place> {
    let norm = normalize_path(path);
    Path::new(&norm).is_dir().then(|| Place { name: name.to_string(), path: norm, kind })
}

/// Parse Linux `/proc/mounts` lines into `(label, mount_path)` pairs for
/// removable and user-mounted media under `/run/media/`, `/media/`, or `/mnt/`.
pub fn parse_proc_mounts(mounts: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for line in mounts.lines() {
        let Some(mount) = line.split(' ').nth(1) else { continue };
        // /proc/mounts escapes spaces as \040.
        let mount = mount.replace("\\040", " ");
        if ["/run/media/", "/media/", "/mnt/"].iter().any(|p| mount.starts_with(p)) {
            let name = mount.rsplit('/').next().unwrap_or(&mount).to_string();
            out.push((name, mount));
        }
    }
    out
}

/// Discover mounted volumes inside a macOS `/Volumes`-style directory, skipping
/// hidden entries and the `/` boot-volume symlink.
pub fn discover_volumes_in(volumes_dir: &Path) -> Vec<Place> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(volumes_dir) else { return out };
    for e in rd.flatten() {
        let Ok(name) = e.file_name().into_string() else { continue };
        if is_hidden_or_system_name(&name) {
            continue;
        }
        let p = e.path();
        // Skip the `/Volumes/Macintosh HD -> /` root symlink so it does not
        // duplicate the "File system" root entry.
        if let Ok(target) = std::fs::read_link(&p) {
            if target == Path::new("/") {
                continue;
            }
        }
        if let Some(full) = p.to_str() {
            if let Some(pl) = place(&name, full, "drive") {
                out.push(pl);
            }
        }
    }
    out.sort_by(|a, b| natural_cmp(&a.name, &b.name));
    out
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

    // Desktop home directory: `HOME` on Linux/macOS, `USERPROFILE` fallback on Windows.
    if let Ok(home) = std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")) {
        let home = normalize_path(&home);
        add(place("Home", &home, "home"));
        for sub in [
            "Pictures",
            "Downloads",
            "Documents",
            "Desktop",
            "ComfyUI/output",
            "invokeai/outputs",
            "stable-diffusion-webui/outputs",
        ] {
            let name = sub.rsplit('/').next().unwrap_or(sub);
            let label = if sub.contains('/') { sub.to_string() } else { name.to_string() };
            add(place(&label, &format!("{home}/{sub}"), "folder"));
        }
    }

    if cfg!(target_os = "windows") {
        // Enumerate mounted Windows drive letters (A:/ through Z:/).
        for letter in b'A'..=b'Z' {
            let drive = letter as char;
            let root = format!("{drive}:/");
            add(place(&format!("Drive {drive}:"), &root, "drive"));
        }
        return out;
    }

    if cfg!(target_os = "macos") {
        for vol in discover_volumes_in(Path::new("/Volumes")) {
            add(Some(vol));
        }
        add(place("File system", "/", "root"));
        return out;
    }

    // Linux mounted drives.
    if let Ok(mounts) = std::fs::read_to_string("/proc/mounts") {
        for (name, mount) in parse_proc_mounts(&mounts) {
            add(place(&name, &mount, "drive"));
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

/// Whether `name` is a dot-hidden folder or well-known OS system folder.
pub fn is_hidden_or_system_name(name: &str) -> bool {
    name.starts_with('.')
        || name.eq_ignore_ascii_case("$RECYCLE.BIN")
        || name.eq_ignore_ascii_case("System Volume Information")
}

#[cfg(windows)]
fn has_windows_hidden_attr(entry: &std::fs::DirEntry) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_SYSTEM: u32 = 0x4;
    entry
        .metadata()
        .map(|m| (m.file_attributes() & FILE_ATTRIBUTE_SYSTEM) != 0)
        .unwrap_or(false)
}

#[cfg(not(windows))]
fn has_windows_hidden_attr(_entry: &std::fs::DirEntry) -> bool {
    false
}

/// Sub-folders of `path`, sorted. Hidden folders are left out.
pub fn list_dirs(path: &str) -> std::io::Result<Vec<DirEntry>> {
    let mut out = Vec::new();
    for e in std::fs::read_dir(path)?.flatten() {
        let Ok(name) = e.file_name().into_string() else { continue };
        if is_hidden_or_system_name(&name) || has_windows_hidden_attr(&e) {
            continue;
        }
        // is_dir() follows symlinks, so linked folders are browsable.
        let p = e.path();
        if !p.is_dir() {
            continue;
        }
        let Some(full) = p.to_str() else { continue };
        out.push(DirEntry { has_sub: has_subdir(&p), name, path: normalize_path(full) });
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
        let name = e.file_name();
        let name_str = name.to_string_lossy();
        if is_hidden_or_system_name(&name_str) || has_windows_hidden_attr(&e) {
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
        for d in ["b/inner", "a", ".hidden", "$RECYCLE.BIN", "System Volume Information", "c10", "c9"] {
            std::fs::create_dir_all(tmp.path().join(d)).unwrap();
        }
        std::fs::write(tmp.path().join("file.png"), b"x").unwrap();
        let dirs = list_dirs(tmp.path().to_str().unwrap()).unwrap();
        let names: Vec<_> = dirs.iter().map(|d| (d.name.as_str(), d.has_sub)).collect();
        assert_eq!(names, [("a", false), ("b", true), ("c9", false), ("c10", false)]);
        for d in &dirs {
            assert!(!d.path.contains('\\'), "path must use forward slashes: {}", d.path);
        }
        assert!(list_dirs("/definitely/not/here").is_err());
    }

    #[test]
    fn normalizes_windows_and_unix_paths() {
        assert_eq!(normalize_path("/"), "/");
        assert_eq!(normalize_path("/home/josh/Pictures/"), "/home/josh/Pictures");
        assert_eq!(normalize_path(r"C:\"), "C:/");
        assert_eq!(normalize_path("C:/"), "C:/");
        assert_eq!(normalize_path(r"C:\Users\josh\Pictures\"), "C:/Users/josh/Pictures");
        assert_eq!(normalize_path(r"\\?\D:\AI\ComfyUI\output\"), "D:/AI/ComfyUI/output");
        assert_eq!(normalize_path(r"\\?\UNC\nas\renders\"), "//nas/renders");
    }

    #[test]
    fn parses_linux_proc_mounts_and_macos_volumes() {
        let sample_mounts = "\
/dev/nvme0n1p2 / ext4 rw,relatime 0 0
/dev/sda1 /run/media/josh/Fast\\040SSD exfat rw,nosuid 0 0
/dev/sdb1 /mnt/renders ext4 rw 0 0
";
        assert_eq!(
            parse_proc_mounts(sample_mounts),
            vec![
                ("Fast SSD".to_string(), "/run/media/josh/Fast SSD".to_string()),
                ("renders".to_string(), "/mnt/renders".to_string()),
            ]
        );

        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(tmp.path().join("ExternalDrive")).unwrap();
        std::fs::create_dir_all(tmp.path().join(".Spotlight-V100")).unwrap();
        let vols = discover_volumes_in(tmp.path());
        assert_eq!(vols.len(), 1);
        assert_eq!(vols[0].name, "ExternalDrive");
        assert_eq!(vols[0].kind, "drive");
    }
}
