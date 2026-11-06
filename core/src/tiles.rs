//! The hires fix in tiles: the upscaled picture cut into overlapping tiles
//! for a server to redraw one at a time, and the redrawn tiles put back
//! together, each fading into its neighbours across what they share, so no
//! seam shows and no tile needs more of the server than one tile's worth.

use image::{imageops::FilterType, DynamicImage, RgbImage};
use serde::Deserialize;
use std::path::{Path, PathBuf};

/// Where a tile sits in the whole picture, in pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct Tile {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

/// The picture at `source`, brought to `width` × `height` if it is not
/// that already, cut into `tiles`, each written as `tile-N.png` in `dir`.
/// Returns the tiles' paths, in order.
pub fn split(source: &Path, width: u32, height: u32, tiles: &[Tile], dir: &Path) -> Result<Vec<PathBuf>, String> {
    let picture = crate::jxl::open(source)?;
    let picture = if picture.width() == width && picture.height() == height {
        picture
    } else {
        picture.resize_exact(width, height, FilterType::Lanczos3)
    };
    std::fs::create_dir_all(dir).map_err(|e| format!("cannot make {}: {e}", dir.display()))?;
    let mut out = Vec::with_capacity(tiles.len());
    for (i, t) in tiles.iter().enumerate() {
        if t.w == 0 || t.h == 0 || t.x + t.w > width || t.y + t.h > height {
            return Err(format!("tile {i} does not fit the picture"));
        }
        let piece = DynamicImage::ImageRgb8(picture.crop_imm(t.x, t.y, t.w, t.h).to_rgb8());
        let path = dir.join(format!("tile-{i}.png"));
        piece.save_with_format(&path, image::ImageFormat::Png).map_err(|e| format!("cannot write {}: {e}", path.display()))?;
        out.push(path);
    }
    Ok(out)
}

/// The redrawn tiles (each file, and where it goes) put back into one
/// `width` × `height` picture. Each fades in across `overlap` pixels on
/// the sides it shares with another tile, so where two meet they cross
/// fade; a tile that came back at another size is fitted to its place.
pub fn merge(tiles: &[(PathBuf, Tile)], width: u32, height: u32, overlap: u32) -> Result<RgbImage, String> {
    let (w, h) = (width as usize, height as usize);
    let mut sum = vec![0f32; w * h * 3];
    let mut weight = vec![0f32; w * h];
    let ramp = overlap.max(1) as f32;
    for (path, t) in tiles {
        let piece = crate::jxl::open(path)?;
        let piece = if piece.width() == t.w && piece.height() == t.h {
            piece.to_rgb8()
        } else {
            piece.resize_exact(t.w, t.h, FilterType::Lanczos3).to_rgb8()
        };
        // How much of the tile counts at each place along it: full in the
        // middle, rising from nothing at a side another tile shares.
        let along = |at: u32, start: u32, length: u32, whole: u32| -> f32 {
            let from_start = if start > 0 { (at as f32 + 0.5) / ramp } else { 1.0 };
            let to_end = if start + length < whole { ((length - at) as f32 - 0.5) / ramp } else { 1.0 };
            from_start.min(to_end).clamp(1e-3, 1.0)
        };
        let wx: Vec<f32> = (0..t.w).map(|px| along(px, t.x, t.w, width)).collect();
        for py in 0..t.h {
            let wy = along(py, t.y, t.h, height);
            let y = (t.y + py) as usize;
            if y >= h {
                break;
            }
            for (px, &wxv) in wx.iter().enumerate() {
                let x = t.x as usize + px;
                if x >= w {
                    break;
                }
                let k = wxv * wy;
                let p = piece.get_pixel(px as u32, py).0;
                let at = y * w + x;
                sum[at * 3] += p[0] as f32 * k;
                sum[at * 3 + 1] += p[1] as f32 * k;
                sum[at * 3 + 2] += p[2] as f32 * k;
                weight[at] += k;
            }
        }
    }
    let mut out = RgbImage::new(width, height);
    for (i, pixel) in out.pixels_mut().enumerate() {
        let k = weight[i];
        if k > 0.0 {
            for c in 0..3 {
                pixel.0[c] = (sum[i * 3 + c] / k).round().clamp(0.0, 255.0) as u8;
            }
        }
    }
    Ok(out)
}

/// Regions of a picture to redraw up close (the detail pass): each box
/// (fractions of the picture) grown to take in what is round it, cut out,
/// and enlarged so its long side is `side` (each side a multiple of 16, as
/// servers take), written as `region-N.png` in `dir`. Returns each file,
/// where it came from in the picture, and the size it was written at.
pub fn crop_regions(source: &Path, boxes: &[[f32; 4]], side: u32, dir: &Path) -> Result<Vec<(PathBuf, Tile, (u32, u32))>, String> {
    let picture = crate::jxl::open(source)?;
    let (w, h) = (picture.width() as f32, picture.height() as f32);
    std::fs::create_dir_all(dir).map_err(|e| format!("cannot make {}: {e}", dir.display()))?;
    let mut out = Vec::new();
    for (i, b) in boxes.iter().enumerate() {
        let (bw, bh) = ((b[2] - b[0]) * w, (b[3] - b[1]) * h);
        // Half as much again round it, and at least 32 pixels.
        let (gw, gh) = ((bw * 1.6).max(bw + 64.0), (bh * 1.6).max(bh + 64.0));
        let (cx, cy) = ((b[0] + b[2]) / 2.0 * w, (b[1] + b[3]) / 2.0 * h);
        let x0 = (cx - gw / 2.0).clamp(0.0, w - 1.0).floor() as u32;
        let y0 = (cy - gh / 2.0).clamp(0.0, h - 1.0).floor() as u32;
        let x1 = (cx + gw / 2.0).clamp(1.0, w).ceil() as u32;
        let y1 = (cy + gh / 2.0).clamp(1.0, h).ceil() as u32;
        let t = Tile { x: x0, y: y0, w: (x1 - x0).max(1), h: (y1 - y0).max(1) };
        let scale = side as f32 / t.w.max(t.h) as f32;
        let snap = |v: f32| (((v / 16.0).round() as u32) * 16).max(64);
        let size = (snap(t.w as f32 * scale), snap(t.h as f32 * scale));
        let piece = picture.crop_imm(t.x, t.y, t.w, t.h).resize_exact(size.0, size.1, FilterType::Lanczos3);
        let path = dir.join(format!("region-{i}.png"));
        DynamicImage::ImageRgb8(piece.to_rgb8()).save_with_format(&path, image::ImageFormat::Png).map_err(|e| format!("cannot write {}: {e}", path.display()))?;
        out.push((path, t, size));
    }
    Ok(out)
}

/// The picture at `base` with each redrawn piece put back where it came
/// from, fitted to its place and faded in from its edges across `feather`
/// of its shorter side, so no edge shows.
pub fn paste_regions(base: &Path, pieces: &[(PathBuf, Tile)], feather: f32) -> Result<RgbImage, String> {
    let mut out = crate::jxl::open(base)?.to_rgb8();
    for (path, t) in pieces {
        let piece = crate::jxl::open(path)?.resize_exact(t.w, t.h, FilterType::Lanczos3).to_rgb8();
        let f = (t.w.min(t.h) as f32 * feather).max(1.0);
        for py in 0..t.h {
            for px in 0..t.w {
                let (x, y) = (t.x + px, t.y + py);
                if x >= out.width() || y >= out.height() {
                    continue;
                }
                let edge = (px as f32 + 0.5).min(py as f32 + 0.5).min(t.w as f32 - px as f32 - 0.5).min(t.h as f32 - py as f32 - 0.5);
                let a = (edge / f).clamp(0.0, 1.0);
                // Smoothstep, so the fade has no visible start or end.
                let a = a * a * (3.0 - 2.0 * a);
                let new = piece.get_pixel(px, py).0;
                let old = out.get_pixel_mut(x, y);
                for c in 0..3 {
                    old.0[c] = (old.0[c] as f32 * (1.0 - a) + new[c] as f32 * a).round() as u8;
                }
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn picture(w: u32, h: u32) -> RgbImage {
        RgbImage::from_fn(w, h, |x, y| image::Rgb([(x * 7 % 256) as u8, (y * 5 % 256) as u8, ((x + y) % 256) as u8]))
    }

    #[test]
    fn tiles_cut_and_put_back_give_the_picture() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("p.png");
        let original = picture(300, 200);
        original.save(&src).unwrap();
        let tiles = [
            Tile { x: 0, y: 0, w: 160, h: 120 },
            Tile { x: 140, y: 0, w: 160, h: 120 },
            Tile { x: 0, y: 80, w: 160, h: 120 },
            Tile { x: 140, y: 80, w: 160, h: 120 },
        ];
        let paths = split(&src, 300, 200, &tiles, &dir.path().join("t")).unwrap();
        assert_eq!(paths.len(), 4);
        let back = merge(&paths.iter().cloned().zip(tiles).collect::<Vec<_>>(), 300, 200, 20).unwrap();
        for (a, b) in back.pixels().zip(original.pixels()) {
            for c in 0..3 {
                assert!((a.0[c] as i32 - b.0[c] as i32).abs() <= 1);
            }
        }
    }

    #[test]
    fn a_region_cut_out_and_pasted_back() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("p.png");
        picture(400, 300).save(&src).unwrap();
        let crops = crop_regions(&src, &[[0.4, 0.4, 0.5, 0.5]], 1024, &dir.path().join("r")).unwrap();
        let (path, t, size) = &crops[0];
        // 40 × 30 grown to 104 × 94 round its middle (200, 135).
        assert_eq!((t.w, t.h), (104, 94));
        assert!(t.x <= 160 && t.x + t.w >= 200);
        assert_eq!(size.0.max(size.1) % 16, 0);
        assert!(size.0.max(size.1) >= 1008);
        // A white piece pasted back: white in its middle, untouched outside,
        // blended at its edge.
        let white = dir.path().join("w.png");
        RgbImage::from_pixel(size.0, size.1, image::Rgb([255, 255, 255])).save(&white).unwrap();
        let out = paste_regions(&src, &[(white, *t)], 0.15).unwrap();
        assert_eq!(out.get_pixel(t.x + t.w / 2, t.y + t.h / 2).0, [255, 255, 255]);
        assert_eq!(out.get_pixel(5, 5), picture(400, 300).get_pixel(5, 5));
        let _ = path;
    }

    #[test]
    fn where_tiles_meet_they_cross_fade() {
        let dir = tempfile::tempdir().unwrap();
        let black = dir.path().join("a.png");
        let white = dir.path().join("b.png");
        RgbImage::from_pixel(60, 10, image::Rgb([0, 0, 0])).save(&black).unwrap();
        RgbImage::from_pixel(60, 10, image::Rgb([255, 255, 255])).save(&white).unwrap();
        let out = merge(
            &[(black, Tile { x: 0, y: 0, w: 60, h: 10 }), (white, Tile { x: 40, y: 0, w: 60, h: 10 })],
            100,
            10,
            20,
        )
        .unwrap();
        assert_eq!(out.get_pixel(10, 5).0[0], 0);
        assert_eq!(out.get_pixel(90, 5).0[0], 255);
        let middle = out.get_pixel(50, 5).0[0];
        assert!((100..=155).contains(&middle), "half way across the overlap: {middle}");
        // It rises steadily across the overlap.
        let row: Vec<u8> = (40..60).map(|x| out.get_pixel(x, 5).0[0]).collect();
        assert!(row.windows(2).all(|p| p[1] >= p[0]), "{row:?}");
    }
}
