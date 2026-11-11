//! The hires fix in tiles: the upscaled picture cut into overlapping tiles
//! for a server to redraw one at a time, and the redrawn tiles put back
//! together, each held to the tile it was made from and giving way to its
//! neighbours in a narrow band, so no seam shows, nothing is drawn in that
//! was not there, and no tile needs more of the server than one tile's worth.

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

/// A redrawn tile to put back: the file the server sent, where it goes,
/// and the tile as it was before the server redrew it (as [`split`] wrote
/// it), which the redraw is held to. Without `before` it is taken as it is.
#[derive(Debug, Clone)]
pub struct Redrawn {
    pub after: PathBuf,
    pub before: Option<PathBuf>,
    pub tile: Tile,
}

/// How sharply one tile gives way to the next where they share ground. The
/// tiles are separate drawings of the same place and never agree in the
/// fine detail, so a cross fade over all they share shows both at once: a
/// soft, doubled band along every join. At this power the change takes
/// about a quarter of the shared width, half way across it.
const SEAM_POWER: i32 = 4;

/// What a redraw is held to, as a share of the tile's longer side: the
/// reach of the colour and shading it has to keep from the tile it was
/// given.
const KEEP_REACH: f32 = 1.0 / 64.0;

/// A redraw that moves the picture this much (levels out of 255, in
/// brightness, at the scale of an eye or a mouth) is still detail; at
/// [`NEW_THING`] it has drawn something that was not there.
const STILL_DETAIL: f32 = 4.0;
const NEW_THING: f32 = 10.0;

/// The redrawn tiles put back into one `width` × `height` picture; a tile
/// that came back at another size is fitted to its place.
///
/// Each redraw is first held to the tile it was made from (see [`held`]),
/// so it adds detail and nothing else: no shift of colour from tile to
/// tile, and no face or figure drawn where there was none. Where tiles
/// share ground each counts by how far inside it the place is, sharpened
/// (see [`SEAM_POWER`]) so one gives way to the next in a narrow band down
/// the middle of what they share.
pub fn merge(tiles: &[Redrawn], width: u32, height: u32) -> Result<RgbImage, String> {
    let (w, h) = (width as usize, height as usize);
    let mut sum = vec![0f32; w * h * 3];
    let mut weight = vec![0f32; w * h];
    for Redrawn { after, before, tile: t } in tiles {
        let fitted = |path: &Path| -> Result<RgbImage, String> {
            let piece = crate::jxl::open(path)?;
            Ok(if piece.width() == t.w && piece.height() == t.h {
                piece.to_rgb8()
            } else {
                piece.resize_exact(t.w, t.h, FilterType::Lanczos3).to_rgb8()
            })
        };
        let after = fitted(after)?;
        let piece: Vec<f32> = match before {
            Some(before) => held(&fitted(before)?, &after),
            None => after.as_raw().iter().map(|&v| v as f32).collect(),
        };
        // How far inside the tile a place is, from the sides another tile
        // shares; a side at the picture's edge does not count.
        let inside = |at: u32, start: u32, length: u32, whole: u32| -> f32 {
            let from_start = if start > 0 { at as f32 + 0.5 } else { f32::INFINITY };
            let to_end = if start + length < whole { (length - at) as f32 - 0.5 } else { f32::INFINITY };
            let d = from_start.min(to_end);
            if d.is_finite() {
                d
            } else {
                1.0
            }
        };
        let wx: Vec<f32> = (0..t.w).map(|px| inside(px, t.x, t.w, width)).collect();
        for py in 0..t.h {
            let wy = inside(py, t.y, t.h, height);
            let y = (t.y + py) as usize;
            if y >= h {
                break;
            }
            for (px, &wxv) in wx.iter().enumerate() {
                let x = t.x as usize + px;
                if x >= w {
                    break;
                }
                let k = (wxv * wy).powi(SEAM_POWER);
                let from = (py as usize * t.w as usize + px) * 3;
                let at = y * w + x;
                sum[at * 3] += piece[from] * k;
                sum[at * 3 + 1] += piece[from + 1] * k;
                sum[at * 3 + 2] += piece[from + 2] * k;
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

/// A redrawn tile held to the tile it was made from: `before` with only
/// the fine detail of what `after` changed. Red, green, blue for each
/// pixel, 0 to 255.
///
/// A server redrawing a tile knows nothing of the rest of the picture. It
/// drifts in colour and brightness, differently in each tile, which shows
/// as a step where two meet; and given room it draws a whole new subject
/// into a tile of sky or cloth. Neither is detail. So of the change the
/// redraw made, the broad part (anything wider than [`KEEP_REACH`]) is
/// dropped, which keeps the tile's own colour and shading; and where the
/// rest still moves the picture at the scale of a feature, past
/// [`NEW_THING`], something new was drawn and the tile is left as it was
/// there.
fn held(before: &RgbImage, after: &RgbImage) -> Vec<f32> {
    let (w, h) = (before.width() as usize, before.height() as usize);
    let n = w * h;
    let reach = (w.max(h) as f32 * KEEP_REACH).max(2.0);
    let (b, a) = (before.as_raw(), after.as_raw());
    // What the redraw changed, by colour, and the broad part of it.
    let change: Vec<Vec<f32>> = (0..3).map(|c| (0..n).map(|i| a[i * 3 + c] as f32 - b[i * 3 + c] as f32).collect()).collect();
    let broad: Vec<Vec<f32>> = change
        .iter()
        .map(|plane| {
            let mut p = plane.clone();
            blur(&mut p, w, h, reach);
            p
        })
        .collect();
    let brightness = |planes: &[Vec<f32>], i: usize| 0.299 * planes[0][i] + 0.587 * planes[1][i] + 0.114 * planes[2][i];
    // The change in brightness at the scale of a feature: finer than the
    // broad part, coarser than texture, which evens out when smoothed.
    let mut feature: Vec<f32> = (0..n).map(|i| brightness(&change, i)).collect();
    blur(&mut feature, w, h, reach / 2.0);
    for (i, f) in feature.iter_mut().enumerate() {
        *f = (*f - brightness(&broad, i)).abs();
    }
    // Spread, so all of a new thing goes and not just its darkest lines.
    blur(&mut feature, w, h, reach);
    let mut out = Vec::with_capacity(n * 3);
    for i in 0..n {
        let t = ((feature[i] - STILL_DETAIL) / (NEW_THING - STILL_DETAIL)).clamp(0.0, 1.0);
        let keep = 1.0 - t * t * (3.0 - 2.0 * t);
        for c in 0..3 {
            out.push(b[i * 3 + c] as f32 + keep * (change[c][i] - broad[c][i]));
        }
    }
    out
}

/// `plane` (`w` × `h`) smoothed about as a Gaussian of `sigma` would: three
/// passes of a running mean each way, the edge pixels repeated past the
/// edge.
fn blur(plane: &mut [f32], w: usize, h: usize, sigma: f32) {
    // Three running means of this half width come to the Gaussian's spread.
    let r = (((sigma * sigma * 4.0 + 1.0).sqrt() - 1.0) / 2.0).round().max(1.0) as usize;
    let mut line = vec![0f32; w.max(h)];
    let mut pass = |plane: &mut [f32], start: usize, step: usize, len: usize| {
        if len < 2 {
            return;
        }
        for (k, v) in line[..len].iter_mut().enumerate() {
            *v = plane[start + k * step];
        }
        let at = |k: isize| line[k.clamp(0, len as isize - 1) as usize];
        let mut acc: f32 = (-(r as isize)..=r as isize).map(at).sum();
        let span = (2 * r + 1) as f32;
        for k in 0..len {
            plane[start + k * step] = acc / span;
            acc += at(k as isize + r as isize + 1) - at(k as isize - r as isize);
        }
    };
    for _ in 0..3 {
        for y in 0..h {
            pass(plane, y * w, 1, w);
        }
        for x in 0..w {
            pass(plane, x, w, h);
        }
    }
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
        let redrawn: Vec<Redrawn> =
            paths.iter().zip(tiles).map(|(p, tile)| Redrawn { after: p.clone(), before: Some(p.clone()), tile }).collect();
        let back = merge(&redrawn, 300, 200).unwrap();
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
            &[
                Redrawn { after: black, before: None, tile: Tile { x: 0, y: 0, w: 60, h: 10 } },
                Redrawn { after: white, before: None, tile: Tile { x: 40, y: 0, w: 60, h: 10 } },
            ],
            100,
            10,
        )
        .unwrap();
        assert_eq!(out.get_pixel(10, 5).0[0], 0);
        assert_eq!(out.get_pixel(90, 5).0[0], 255);
        let middle = out.get_pixel(50, 5).0[0];
        assert!((100..=155).contains(&middle), "half way across the overlap: {middle}");
        // It rises steadily across the overlap.
        let row: Vec<u8> = (40..60).map(|x| out.get_pixel(x, 5).0[0]).collect();
        assert!(row.windows(2).all(|p| p[1] >= p[0]), "{row:?}");
        // And in a narrow band: a quarter of the way in, the first tile
        // still has it nearly to itself, so two redraws are not shown at
        // once over all they share.
        assert!(out.get_pixel(45, 5).0[0] < 8, "{row:?}");
        assert!(out.get_pixel(54, 5).0[0] > 247, "{row:?}");
    }

    /// A picture with broad shapes and fine texture, as an upscale has.
    fn scene(w: u32, h: u32) -> RgbImage {
        RgbImage::from_fn(w, h, |x, y| {
            let v = 110.0 + 50.0 * (x as f32 / 90.0).sin() + 30.0 * (y as f32 / 70.0).cos();
            image::Rgb([v as u8, (v * 0.9) as u8, (v * 0.8 + 20.0) as u8])
        })
    }

    /// Fine detail a redraw adds: a pattern a few pixels across.
    fn grit(x: u32, y: u32) -> f32 {
        if (x / 2 + y / 2) % 2 == 0 {
            12.0
        } else {
            -12.0
        }
    }

    fn redraw(dir: &Path, name: &str, before: &RgbImage, change: impl Fn(u32, u32) -> f32) -> PathBuf {
        let path = dir.join(name);
        RgbImage::from_fn(before.width(), before.height(), |x, y| {
            let p = before.get_pixel(x, y).0;
            let d = change(x, y);
            image::Rgb([0, 1, 2].map(|c| (p[c] as f32 + d).round().clamp(0.0, 255.0) as u8))
        })
        .save(&path)
        .unwrap();
        path
    }

    #[test]
    fn a_tile_that_drifts_in_brightness_leaves_no_step() {
        let dir = tempfile::tempdir().unwrap();
        let whole = scene(896, 512);
        let src = dir.path().join("p.png");
        whole.save(&src).unwrap();
        let tiles = [Tile { x: 0, y: 0, w: 512, h: 512 }, Tile { x: 384, y: 0, w: 512, h: 512 }];
        let cut = split(&src, 896, 512, &tiles, &dir.path().join("t")).unwrap();
        // The server made one tile lighter and the other darker, and gave
        // both fine detail.
        let redrawn: Vec<Redrawn> = [14.0f32, -14.0]
            .iter()
            .enumerate()
            .map(|(i, &drift)| {
                let before = image::open(&cut[i]).unwrap().to_rgb8();
                let after = redraw(dir.path(), &format!("d{i}.png"), &before, |x, y| drift + grit(x, y));
                Redrawn { after, before: Some(cut[i].clone()), tile: tiles[i] }
            })
            .collect();
        let out = merge(&redrawn, 896, 512).unwrap();
        // Averaged over a patch (so the detail evens out), the picture is
        // the brightness it was on both sides of the join and across it.
        let patch = |img: &RgbImage, x0: u32| -> f32 {
            (0..32).flat_map(|dx| (240..272).map(move |y| (dx, y))).map(|(dx, y)| img.get_pixel(x0 + dx, y).0[1] as f32).sum::<f32>() / 1024.0
        };
        for x0 in [200, 400, 432, 464, 660] {
            let (got, was) = (patch(&out, x0), patch(&whole, x0));
            assert!((got - was).abs() < 2.0, "at {x0}: {got} for {was}");
        }
        // The detail is still there.
        let (a, b) = (out.get_pixel(200, 250).0[1] as i32, out.get_pixel(202, 250).0[1] as i32);
        assert!((a - b).abs() >= 16, "detail kept: {a} {b}");
    }

    #[test]
    fn a_thing_drawn_into_a_tile_is_left_out() {
        let dir = tempfile::tempdir().unwrap();
        let before = scene(512, 512);
        let src = dir.path().join("b.png");
        before.save(&src).unwrap();
        // A face in the sky: a lighter oval with two dark eyes and a mouth,
        // and fine detail everywhere.
        let face = |x: u32, y: u32| -> f32 {
            let (fx, fy) = (x as f32 - 300.0, y as f32 - 200.0);
            let eye = |cx: f32| ((fx - cx).powi(2) + (fy + 20.0).powi(2)).sqrt() < 11.0;
            if eye(-28.0) || eye(28.0) || (fx.abs() < 30.0 && (fy - 40.0).abs() < 5.0) {
                -70.0
            } else if (fx / 75.0).powi(2) + (fy / 95.0).powi(2) < 1.0 {
                35.0
            } else {
                0.0
            }
        };
        let after = redraw(dir.path(), "a.png", &before, |x, y| face(x, y) + grit(x, y));
        let tile = Tile { x: 0, y: 0, w: 512, h: 512 };
        let out = merge(&[Redrawn { after, before: Some(src), tile }], 512, 512).unwrap();
        // Where the eyes and mouth were drawn, the picture is as it was.
        for (x, y) in [(272, 180), (328, 180), (300, 240)] {
            let (got, was) = (out.get_pixel(x, y).0[1] as i32, before.get_pixel(x, y).0[1] as i32);
            assert!((got - was).abs() <= 6, "at {x},{y}: {got} for {was}");
        }
        // Away from it the detail was taken.
        let (a, b) = (out.get_pixel(80, 400).0[1] as i32, out.get_pixel(82, 400).0[1] as i32);
        assert!((a - b).abs() >= 16, "detail kept: {a} {b}");
    }

    #[test]
    fn soft_edges_made_sharp_stay_sharp() {
        let dir = tempfile::tempdir().unwrap();
        // Stripes with soft edges, as an upscale leaves them, and the same
        // stripes redrawn crisp.
        let stripes = |soft: f32| {
            RgbImage::from_fn(512, 512, |x, _| {
                let d = (x % 128) as f32 - 64.0;
                let v = 60.0 + 140.0 * (0.5 + d / soft).clamp(0.0, 1.0);
                image::Rgb([v as u8; 3])
            })
        };
        let (before, after) = (dir.path().join("b.png"), dir.path().join("a.png"));
        stripes(8.0).save(&before).unwrap();
        stripes(1.0).save(&after).unwrap();
        let tile = Tile { x: 0, y: 0, w: 512, h: 512 };
        let out = merge(&[Redrawn { after, before: Some(before), tile }], 512, 512).unwrap();
        let sharp = stripes(1.0);
        for x in [60u32, 62, 66, 68, 190, 194] {
            let (got, want) = (out.get_pixel(x, 256).0[0] as i32, sharp.get_pixel(x, 256).0[0] as i32);
            assert!((got - want).abs() <= 12, "at {x}: {got} for {want}");
        }
    }
}
