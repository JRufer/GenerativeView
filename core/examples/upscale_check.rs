//! Upscale a picture with a Real-ESRGAN `.pth` and save the result, timing
//! it: `cargo run --release --example upscale_check -- model.pth in.png out.png [factor]`.

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: upscale_check MODEL.pth IN OUT [2|4]");
        std::process::exit(2);
    }
    let factor = args.get(4).and_then(|f| f.parse().ok()).unwrap_or(4);
    let t = std::time::Instant::now();
    let model = gvcore::sr::Upscaler::load(std::path::Path::new(&args[1])).expect("model");
    println!("model loaded in {:.0?}: ×{}", t.elapsed(), model.scale);
    let picture = image::open(&args[2]).expect("picture");
    let t = std::time::Instant::now();
    let big = gvcore::sr::upscale_picture(&model, &picture, factor, &mut |done, total| {
        eprint!("\r{done}/{total} tiles");
        true
    })
    .expect("upscale");
    eprintln!();
    println!("{}×{} → {}×{} in {:.1?}", picture.width(), picture.height(), big.width(), big.height(), t.elapsed());
    big.save(&args[3]).expect("save");
}
