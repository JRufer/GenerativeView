//! Thumbnail generation and on-disk cache.
//!
//! Requests come in far faster than they can be served while the user flings
//! through a grid, so the queue is last-in-first-out with cancellation: tiles
//! that are on screen now are decoded first, and tiles that scrolled away
//! before their turn are dropped. A separate low-priority queue pre-renders
//! the rest of the folder when nothing urgent is waiting.

use fast_image_resize as fr;
use parking_lot::{Condvar, Mutex};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// Short-side target, in pixels, per tier.
pub const TIERS: [u32; 2] = [256, 512];
const JPEG_QUALITY: u8 = 84;
/// Thumbnails of transparent images are flattened onto this.
const BACKDROP: [u8; 3] = [24, 24, 27];

#[derive(Debug)]
pub enum ThumbError {
    /// This platform cannot decode the file itself (video on Android); the
    /// host app should supply a frame via `put`.
    NeedHost,
    Failed(String),
}

pub type ThumbResult = Result<Vec<u8>, ThumbError>;
type Reply = Box<dyn FnOnce(ThumbResult) + Send>;

pub struct Job {
    pub req: i64,
    pub path: String,
    pub mtime: i64,
    pub size: i64,
    pub tier: u8,
    pub reply: Reply,
}

struct Warm {
    path: String,
    mtime: i64,
    size: i64,
}

#[derive(Default)]
struct Queues {
    urgent: Vec<Job>,
    warm: VecDeque<Warm>,
    closed: bool,
}

pub struct Thumbs {
    dir: PathBuf,
    queues: Mutex<Queues>,
    wake: Condvar,
}

impl Thumbs {
    pub fn start(cache_dir: &Path) -> Arc<Thumbs> {
        let dir = cache_dir.join("thumbs");
        let _ = std::fs::create_dir_all(&dir);
        let thumbs = Arc::new(Thumbs { dir, queues: Mutex::new(Queues::default()), wake: Condvar::new() });
        let cores = std::thread::available_parallelism().map_or(2, |n| n.get());
        let workers = cores.saturating_sub(1).clamp(2, 8);
        for i in 0..workers {
            let t = thumbs.clone();
            // Only half the workers take pre-render jobs, so a burst of
            // on-screen requests never finds every worker mid-decode.
            let may_warm = i % 2 == 0;
            std::thread::Builder::new()
                .name(format!("gv-thumb-{i}"))
                .spawn(move || t.work(may_warm))
                .expect("thumb worker");
        }
        thumbs
    }

    pub fn request(&self, job: Job) {
        self.queues.lock().urgent.push(job);
        self.wake.notify_one();
    }

    /// Drop a request that has not started yet. Its reply is never called.
    pub fn cancel(&self, req: i64) {
        let mut q = self.queues.lock();
        if let Some(i) = q.urgent.iter().rposition(|j| j.req == req) {
            q.urgent.remove(i);
        }
    }

    /// Replace the pre-render list (small tier). Pass an empty list to stop.
    pub fn warm(&self, items: Vec<(String, i64, i64)>) {
        let mut q = self.queues.lock();
        q.warm = items.into_iter().map(|(path, mtime, size)| Warm { path, mtime, size }).collect();
        drop(q);
        self.wake.notify_all();
    }

    pub fn close(&self) {
        self.queues.lock().closed = true;
        self.wake.notify_all();
    }

    fn work(&self, may_warm: bool) {
        enum Task {
            Urgent(Job),
            Warm(Warm),
        }
        loop {
            let task = {
                let mut q = self.queues.lock();
                loop {
                    if q.closed {
                        return;
                    }
                    if let Some(job) = q.urgent.pop() {
                        break Task::Urgent(job);
                    }
                    if may_warm {
                        if let Some(w) = q.warm.pop_front() {
                            break Task::Warm(w);
                        }
                    }
                    self.wake.wait(&mut q);
                }
            };
            match task {
                Task::Urgent(job) => {
                    let result = self.get(&job.path, job.mtime, job.size, job.tier);
                    (job.reply)(result);
                }
                Task::Warm(w) => {
                    if !self.cache_path(&w.path, w.mtime, w.size, 0).exists() {
                        let _ = self.get(&w.path, w.mtime, w.size, 0);
                    }
                }
            }
        }
    }

    fn cache_path(&self, path: &str, mtime: i64, size: i64, tier: u8) -> PathBuf {
        let mut key = Vec::with_capacity(path.len() + 17);
        key.extend_from_slice(path.as_bytes());
        key.push(0);
        key.extend_from_slice(&mtime.to_le_bytes());
        key.extend_from_slice(&size.to_le_bytes());
        let h = xxhash_rust::xxh3::xxh3_128(&key);
        let hex = format!("{h:032x}");
        self.dir.join(format!("{tier}")).join(&hex[..2]).join(format!("{}.jpg", &hex[2..]))
    }

    /// Cached thumbnail bytes, generating them if needed.
    pub fn get(&self, path: &str, mtime: i64, size: i64, tier: u8) -> ThumbResult {
        let tier = tier.min(TIERS.len() as u8 - 1);
        let target = self.cache_path(path, mtime, size, tier);
        if let Ok(bytes) = std::fs::read(&target) {
            if !bytes.is_empty() {
                return Ok(bytes);
            }
        }
        // A larger cached tier is a much cheaper source than the original.
        let source = (tier + 1..TIERS.len() as u8)
            .map(|t| self.cache_path(path, mtime, size, t))
            .find_map(|p| std::fs::read(p).ok())
            .and_then(|bytes| image::load_from_memory(&bytes).ok());
        let img = match source {
            Some(img) => img,
            None => load(Path::new(path))?,
        };
        let bytes = render(&img, TIERS[tier as usize])?;
        store(&target, &bytes);
        Ok(bytes)
    }

    /// Build thumbnails from an image the host decoded for us (a video frame).
    pub fn put(&self, path: &str, mtime: i64, size: i64, tier: u8, encoded: &[u8]) -> ThumbResult {
        let tier = tier.min(TIERS.len() as u8 - 1);
        let img = image::load_from_memory(encoded).map_err(|e| ThumbError::Failed(e.to_string()))?;
        let mut wanted = None;
        for t in 0..TIERS.len() as u8 {
            let bytes = render(&img, TIERS[t as usize])?;
            store(&self.cache_path(path, mtime, size, t), &bytes);
            if t == tier {
                wanted = Some(bytes);
            }
        }
        wanted.ok_or_else(|| ThumbError::Failed("no tier".into()))
    }
}

fn store(target: &Path, bytes: &[u8]) {
    let Some(parent) = target.parent() else { return };
    let _ = std::fs::create_dir_all(parent);
    // Write-then-rename so a reader never sees a half-written file.
    let tmp = target.with_extension(format!("tmp{:x}", std::process::id() as u64 ^ (bytes.as_ptr() as u64)));
    if std::fs::write(&tmp, bytes).is_ok() && std::fs::rename(&tmp, target).is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
}

fn load(path: &Path) -> Result<image::DynamicImage, ThumbError> {
    if crate::meta::media_kind(path) == Some(true) {
        return video_frame(path);
    }
    let fail = |e: &dyn std::fmt::Display| ThumbError::Failed(e.to_string());
    let mut reader = image::ImageReader::open(path).map_err(|e| fail(&e))?.with_guessed_format().map_err(|e| fail(&e))?;
    let mut limits = image::Limits::default();
    limits.max_alloc = Some(1 << 30);
    reader.limits(limits);
    reader.decode().map_err(|e| fail(&e))
}

#[cfg(target_os = "android")]
fn video_frame(_path: &Path) -> Result<image::DynamicImage, ThumbError> {
    Err(ThumbError::NeedHost)
}

/// Desktop: let ffmpeg pull the first frame. It is present wherever a video
/// player is; without it videos simply show a placeholder tile.
#[cfg(not(target_os = "android"))]
fn video_frame(path: &Path) -> Result<image::DynamicImage, ThumbError> {
    use std::process::{Command, Stdio};
    let out = Command::new("ffmpeg")
        .args(["-v", "error", "-nostdin", "-i"])
        .arg(path)
        .args(["-frames:v", "1", "-vf", "scale='min(1024,iw)':-2", "-c:v", "mjpeg", "-q:v", "3", "-f", "image2pipe", "-"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|e| ThumbError::Failed(format!("ffmpeg: {e}")))?;
    if out.stdout.is_empty() {
        return Err(ThumbError::Failed("ffmpeg produced no frame".into()));
    }
    image::load_from_memory(&out.stdout).map_err(|e| ThumbError::Failed(e.to_string()))
}

/// Scale so the short side is `short` px (never upscaling, and never letting
/// a panorama's long side run past 3x), then encode as JPEG.
fn render(img: &image::DynamicImage, short: u32) -> ThumbResult {
    let fail = |e: &dyn std::fmt::Display| ThumbError::Failed(e.to_string());
    let (w, h) = (img.width(), img.height());
    if w == 0 || h == 0 {
        return Err(ThumbError::Failed("empty image".into()));
    }
    let scale = (short as f64 / w.min(h) as f64).min((short * 3) as f64 / w.max(h) as f64).min(1.0);
    let tw = ((w as f64 * scale).round() as u32).clamp(1, u16::MAX as u32);
    let th = ((h as f64 * scale).round() as u32).clamp(1, u16::MAX as u32);

    let rgb = flatten(img);
    let pixels = if (tw, th) == (w, h) {
        rgb
    } else {
        let src = fr::images::Image::from_vec_u8(w, h, rgb, fr::PixelType::U8x3).map_err(|e| fail(&e))?;
        let mut dst = fr::images::Image::new(tw, th, fr::PixelType::U8x3);
        let options = fr::ResizeOptions::new().resize_alg(fr::ResizeAlg::Convolution(fr::FilterType::CatmullRom));
        fr::Resizer::new().resize(&src, &mut dst, &options).map_err(|e| fail(&e))?;
        dst.into_vec()
    };

    let mut out = Vec::with_capacity((tw * th / 4) as usize);
    jpeg_encoder::Encoder::new(&mut out, JPEG_QUALITY)
        .encode(&pixels, tw as u16, th as u16, jpeg_encoder::ColorType::Rgb)
        .map_err(|e| fail(&e))?;
    Ok(out)
}

/// 8-bit RGB with any transparency composited onto the backdrop.
fn flatten(img: &image::DynamicImage) -> Vec<u8> {
    if !img.color().has_alpha() {
        return img.to_rgb8().into_raw();
    }
    let rgba = img.to_rgba8();
    let mut out = Vec::with_capacity((rgba.width() * rgba.height() * 3) as usize);
    for px in rgba.as_raw().chunks_exact(4) {
        let a = px[3] as u32;
        for c in 0..3 {
            out.push(((px[c] as u32 * a + BACKDROP[c] as u32 * (255 - a) + 127) / 255) as u8);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_png(path: &Path, w: u32, h: u32, alpha: bool) {
        if alpha {
            let img = image::RgbaImage::from_fn(w, h, |x, y| image::Rgba([(x % 256) as u8, (y % 256) as u8, 128, if x < w / 2 { 0 } else { 255 }]));
            img.save(path).unwrap();
        } else {
            let img = image::RgbImage::from_fn(w, h, |x, y| image::Rgb([(x % 256) as u8, (y % 256) as u8, 128]));
            img.save(path).unwrap();
        }
    }

    fn dims(bytes: &[u8]) -> (u32, u32) {
        let img = image::load_from_memory(bytes).unwrap();
        (img.width(), img.height())
    }

    #[test]
    fn sizes_and_cache() {
        let tmp = tempfile::tempdir().unwrap();
        let thumbs = Thumbs::start(&tmp.path().join("cache"));
        let wide = tmp.path().join("wide.png");
        write_png(&wide, 1600, 800, false);
        let p = wide.to_str().unwrap();

        let big = thumbs.get(p, 1, 2, 1).unwrap();
        assert_eq!(dims(&big), (1024, 512));
        let small = thumbs.get(p, 1, 2, 0).unwrap();
        assert_eq!(dims(&small), (512, 256));

        // Served from cache: the source can disappear.
        std::fs::remove_file(&wide).unwrap();
        assert_eq!(thumbs.get(p, 1, 2, 0).unwrap(), small);
        // A different mtime is a different image.
        assert!(thumbs.get(p, 9, 2, 0).is_err());

        // Panoramas are capped, small images are not enlarged.
        let pano = tmp.path().join("pano.png");
        write_png(&pano, 4000, 200, false);
        assert_eq!(dims(&thumbs.get(pano.to_str().unwrap(), 1, 1, 0).unwrap()), (768, 38));
        let tiny = tmp.path().join("tiny.png");
        write_png(&tiny, 40, 30, true);
        assert_eq!(dims(&thumbs.get(tiny.to_str().unwrap(), 1, 1, 1).unwrap()), (40, 30));
        thumbs.close();
    }

    #[test]
    fn queue_is_lifo_and_cancellable() {
        let tmp = tempfile::tempdir().unwrap();
        // No workers: drive the queue by hand.
        let thumbs = Thumbs { dir: tmp.path().into(), queues: Mutex::new(Queues::default()), wake: Condvar::new() };
        for req in 1..=3 {
            thumbs.request(Job { req, path: String::new(), mtime: 0, size: 0, tier: 0, reply: Box::new(|_| {}) });
        }
        thumbs.cancel(2);
        let order: Vec<i64> = std::iter::from_fn(|| thumbs.queues.lock().urgent.pop().map(|j| j.req)).collect();
        assert_eq!(order, [3, 1]);
    }
}
