//! See how content search rates a real library, to judge where its bars
//! (`clip::CLEAR` and `clip::NEARLY`) belong:
//!
//!     cargo run --release --example content_probe -- <data dir> <folder> [description ...]
//!
//! `<data dir>` is the app's own (`~/.local/share/com.jrufer.generativeview`):
//! the model, the index and the vectors of pictures the app has already
//! looked at are read from there. Nothing is embedded here, and the only
//! thing written is the everyday descriptions' vectors, which the app would
//! write itself. Close the app first.
//!
//! With descriptions, each gets a line of how many pictures reach each
//! level (1 is a match) and the names of the best few. Without, the
//! folder's most used prompt words are tried as descriptions and compared
//! with the prompts: a picture prompted with "fox" probably shows one. Per
//! word and level that gives
//!
//!     found   how many pictures reach the level
//!     kept    of the pictures prompted with the word, the share found
//!     right   of the pictures found, the share prompted with the word
//!
//! Prompts are a rough guide (a picture can show a fox nobody asked for, and
//! "detailed" shows nothing at all), so read the columns against each other
//! rather than as marks out of a hundred. A last table gives the same two
//! shares, over all the words, for other settings of `clip::CLEAR` and
//! `clip::NEARLY`.

use gvcore::clip::{ContentSearch, Fit, CLEAR, NEARLY};
use gvcore::db::{Db, Query};
use gvcore::thumbs::Thumbs;
use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

/// Levels to count at: 1 is where the app draws the line.
const LEVELS: [f32; 7] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
/// Other places the two bars could be put.
const CLEARS: [f32; 6] = [2.0, 2.5, 3.0, 3.5, 4.0, 5.0];
const NEARLIES: [f32; 7] = [0.4, 0.5, 0.6, 0.7, 0.75, 0.8, 0.9];
const WORDS: usize = 40;

fn main() {
    let mut args = std::env::args().skip(1);
    let (Some(data), Some(folder)) = (args.next(), args.next()) else {
        eprintln!("usage: content_probe <data dir> <folder> [description ...]");
        std::process::exit(2);
    };
    let descriptions: Vec<String> = args.collect();
    let folder = folder.trim_end_matches('/').to_string();
    let db = Arc::new(Db::open(Path::new(&data)).expect("open the index"));
    let scratch = std::env::temp_dir().join(format!("gv-probe-{}", std::process::id()));
    let thumbs = Thumbs::start(&scratch);
    let content = ContentSearch::start(Path::new(&data), db.clone(), thumbs.clone(), Arc::new(|_| {})).expect("open the vectors");

    let t = Instant::now();
    let first = descriptions.first().map_or("fox", String::as_str);
    let (all, fits) = content.rate(&folder, true, first, "newest").unwrap_or_else(|e| {
        eprintln!("{e}");
        std::process::exit(1);
    });
    let looked_at = fits.iter().flatten().count();
    println!("{} pictures, {looked_at} of them looked at; first search {:.2?}", all.rows.len(), t.elapsed());
    let t = Instant::now();
    content.rate(&folder, true, "something else entirely", "newest").expect("search");
    println!("a search after that: {:.2?}", t.elapsed());
    println!("a match is level 1: {CLEAR} spreads clear of chance, and {NEARLY} of the way to the picture's best descriptions\n");
    if looked_at == 0 {
        eprintln!("No picture in this folder has been looked at yet: open it in the app with content search on.");
        std::process::exit(1);
    }

    let header = LEVELS.iter().map(|level| format!("{level:>6.2}")).collect::<String>();
    if !descriptions.is_empty() {
        println!("{:<28}{header}   best (spreads clear, share of the way)", "pictures at level");
        for description in &descriptions {
            let (all, fits) = content.rate(&folder, true, description, "newest").expect("search");
            let mut rated: Vec<(Fit, &str)> = fits.iter().zip(&all.rows).filter_map(|(fit, row)| fit.map(|fit| (fit, row.2.as_str()))).collect();
            rated.sort_by(|a, b| b.0.level().total_cmp(&a.0.level()));
            let counts = LEVELS.iter().map(|level| format!("{:>6}", rated.iter().filter(|r| r.0.level() >= *level).count())).collect::<String>();
            let best = rated.iter().take(4).map(|(fit, name)| format!("{name} ({:.1}, {:.2})", fit.above, fit.share)).collect::<Vec<_>>().join(", ");
            println!("{:<28}{counts}   {best}", clip(description, 27));
        }
        return;
    }

    let usage = db.usage(&folder, true).expect("count prompt words");
    let Some(words) = usage.groups.iter().find(|group| group.kind == "word") else { return };
    println!("{:<16}{:>7}  {:<6}{header}", "prompt word", "prompts", "level");
    // Every picture's fit to every word tried, with whether it was prompted
    // with the word: enough to redo the sums for other bars afterwards.
    let mut every: Vec<(Fit, bool)> = Vec::new();
    for item in words.items.iter().take(WORDS) {
        let word = item.value.to_lowercase();
        let prompted: HashSet<i64> = db
            .query(&Query { dir: folder.clone(), recursive: true, text: format!("prompt:=\"{word}\""), ..Default::default() })
            .expect("query")
            .rows
            .iter()
            .map(|row| row.0)
            .collect();
        let (all, fits) = content.rate(&folder, true, &word, "newest").expect("search");
        // Only pictures that have been looked at can be found or missed.
        let rated: Vec<(Fit, bool)> = fits.iter().zip(&all.rows).filter_map(|(fit, row)| fit.map(|fit| (fit, prompted.contains(&row.0)))).collect();
        let asked = rated.iter().filter(|r| r.1).count();
        let mut lines = [String::new(), String::new(), String::new()];
        for level in LEVELS {
            let (found, both) = tally(&rated, |fit| fit.level() >= level);
            lines[0] += &format!("{found:>6}");
            lines[1] += &percent(both, asked);
            lines[2] += &percent(both, found);
        }
        println!("{:<16}{asked:>7}  {:<6}{}", clip(&word, 15), "found", lines[0]);
        println!("{:<16}{:>7}  {:<6}{}", "", "", "kept", lines[1]);
        println!("{:<16}{:>7}  {:<6}{}", "", "", "right", lines[2]);
        every.extend(rated);
    }

    let asked = every.iter().filter(|r| r.1).count();
    println!("\nAll {} words together, with the two bars put elsewhere (kept / right):", words.items.len().min(WORDS));
    println!("{:>24}{}", "share of the way:", NEARLIES.iter().map(|n| format!("{n:>12.2}")).collect::<String>());
    for clear in CLEARS {
        let cells: String = NEARLIES
            .iter()
            .map(|nearly| {
                let (found, both) = tally(&every, |fit| fit.above >= clear && fit.share >= *nearly);
                format!("  {} /{}", percent(both, asked), percent(both, found))
            })
            .collect();
        println!("{:>18}{clear:>5.1} {cells}", "spreads clear:");
    }
}

/// How many pictures pass, and how many of those were prompted with the word.
fn tally(rated: &[(Fit, bool)], pass: impl Fn(&Fit) -> bool) -> (usize, usize) {
    let found = rated.iter().filter(|r| pass(&r.0)).count();
    let both = rated.iter().filter(|r| pass(&r.0) && r.1).count();
    (found, both)
}

fn percent(part: usize, whole: usize) -> String {
    if whole == 0 {
        return format!("{:>6}", "-");
    }
    format!("{:>5.0}%", part as f64 * 100.0 / whole as f64)
}

fn clip(text: &str, chars: usize) -> String {
    text.chars().take(chars).collect()
}
