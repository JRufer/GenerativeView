//! See how the picture reading of audience levels lines up with the prompt
//! reading across a real library, to judge where its bars
//! (`audience::image_bar`) belong:
//!
//!     cargo run --release --example audience_probe -- <data dir> <folder>
//!
//! `<data dir>` is the app's own (`~/.local/share/com.jrufer.generativeview`):
//! the model, the index and the vectors of pictures content search has
//! already looked at are read from there. Nothing is embedded here. Close
//! the app first.
//!
//! The prompts are the answer key, and a rough one: a prompt can ask for
//! more than the picture shows, or less. So read the figures against each
//! other. Printed:
//!
//!   * a table of prompt level against picture level;
//!   * for each description, at several bars, how many pictures whose
//!     prompt reads at its level or above it catches, and how many below.
//!     A good bar catches many of the first and few of the second.

use gvcore::audience::{from_fits, image_bar, Level, IMAGE_PHRASES};
use gvcore::clip::ContentSearch;
use gvcore::db::{Db, Query};
use gvcore::thumbs::Thumbs;
use std::path::Path;
use std::sync::Arc;

const BARS: [f32; 6] = [0.8, 1.0, 1.1, 1.2, 1.3, 1.5];
const NAMES: [&str; 6] = ["?", "G", "PG", "PG-13", "R", "NC-17"];

fn main() {
    let mut args = std::env::args().skip(1);
    let (Some(data), Some(folder)) = (args.next(), args.next()) else {
        eprintln!("usage: audience_probe <data dir> <folder>");
        std::process::exit(2);
    };
    let folder = if folder.len() > 1 { folder.trim_end_matches('/').to_string() } else { folder };
    let db = Arc::new(Db::open(Path::new(&data)).expect("open the index"));
    let scratch = std::env::temp_dir().join(format!("gv-audience-probe-{}", std::process::id()));
    let thumbs = Thumbs::start(&scratch);
    let content = ContentSearch::start(Path::new(&data), db.clone(), thumbs, Arc::new(|_| {})).expect("open the vectors");
    if !content.installed() {
        eprintln!("the content search model is not installed in {data}");
        std::process::exit(1);
    }
    let all = db.query(&Query { dir: folder.clone(), recursive: true, ..Default::default() }).expect("list the folder");
    let ids: Vec<i64> = all.rows.iter().map(|r| r.0).collect();
    let marks = db.audience_of(&ids).expect("read the prompt levels");
    let phrases: Vec<String> = IMAGE_PHRASES.iter().map(|p| p.0.to_string()).collect();
    let fits = content.fits(&all, &phrases);

    let mut seen: Vec<(Level, Vec<f32>)> = Vec::new();
    for (id, fit) in ids.iter().zip(fits) {
        let prompt = Level::from_u8(marks.get(id).map_or(0, |m| m.0));
        if let (Some(fit), true) = (fit, prompt != Level::Unknown) {
            seen.push((prompt, fit));
        }
    }
    println!("{} pictures in {folder}; {} with both a prompt and a picture reading", all.rows.len(), seen.len());
    if seen.is_empty() {
        return;
    }

    println!("\nprompt (rows) against picture (columns):");
    print!("{:>7}", "");
    for name in &NAMES[1..] {
        print!("{name:>7}");
    }
    println!();
    for prompt in 1..=5u8 {
        print!("{:>7}", NAMES[prompt as usize]);
        for picture in 1..=5u8 {
            let n = seen.iter().filter(|(p, f)| *p as u8 == prompt && from_fits(f).0 as u8 == picture).count();
            print!("{n:>7}");
        }
        println!();
    }

    println!("\neach description: caught at or above its level / caught below it, by bar (current bar marked *)");
    print!("{:<28}{:>6}", "", "level");
    for bar in BARS {
        print!("{:>11}", format!("{bar:.1}"));
    }
    println!();
    for (i, (phrase, level, _)) in IMAGE_PHRASES.iter().enumerate() {
        let at = seen.iter().filter(|(p, _)| p >= level).count();
        let below = seen.len() - at;
        print!("{phrase:<28}{:>6}", NAMES[*level as usize]);
        for bar in BARS {
            let hit = seen.iter().filter(|(p, f)| p >= level && f[i] >= bar).count();
            let miss = seen.iter().filter(|(p, f)| p < level && f[i] >= bar).count();
            let mark = if (bar - image_bar(*level)).abs() < 0.01 { "*" } else { " " };
            print!("{:>11}", format!("{mark}{hit}/{at} {miss}/{below}"));
        }
        println!();
    }
}
