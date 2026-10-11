//! Getting a picture into the shape CLIP's picture encoder takes: scaled so
//! its short side fits, cropped to the middle square, and each colour
//! shifted and scaled the way the model's training data was.

use fast_image_resize as fr;

const MEAN: [f32; 3] = [0.481_454_66, 0.457_827_5, 0.408_210_73];
const STD: [f32; 3] = [0.268_629_54, 0.261_302_58, 0.275_777_11];

/// `size`×`size` pixels as three planes (red, green, blue), row by row.
pub fn prepare(img: &image::DynamicImage, size: usize) -> Result<Vec<f32>, String> {
    let (w, h) = (img.width() as usize, img.height() as usize);
    if w == 0 || h == 0 || size == 0 {
        return Err("empty image".into());
    }
    // Short side to `size`, the long side in proportion (rounded down).
    let (tw, th) = if w <= h { (size, (size * h / w).max(size)) } else { ((size * w / h).max(size), size) };
    let rgb = img.to_rgb8().into_raw();
    let pixels = if (tw, th) == (w, h) {
        rgb
    } else {
        let fail = |e: &dyn std::fmt::Display| e.to_string();
        let src = fr::images::Image::from_vec_u8(w as u32, h as u32, rgb, fr::PixelType::U8x3).map_err(|e| fail(&e))?;
        let mut dst = fr::images::Image::new(tw as u32, th as u32, fr::PixelType::U8x3);
        let options = fr::ResizeOptions::new().resize_alg(fr::ResizeAlg::Convolution(fr::FilterType::CatmullRom));
        fr::Resizer::new().resize(&src, &mut dst, &options).map_err(|e| fail(&e))?;
        dst.into_vec()
    };
    let (left, top) = ((tw - size) / 2, (th - size) / 2);
    let mut out = vec![0f32; 3 * size * size];
    for y in 0..size {
        let row = &pixels[((top + y) * tw + left) * 3..][..size * 3];
        for (x, pixel) in row.chunks_exact(3).enumerate() {
            for c in 0..3 {
                out[c * size * size + y * size + x] = (pixel[c] as f32 / 255.0 - MEAN[c]) / STD[c];
            }
        }
    }
    Ok(out)
}
