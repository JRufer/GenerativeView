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
