//! See how content search rates a real library, to judge where its bar
//! (`clip::CLEAR`) belongs and whether it is measuring the right thing:
//!
//!     cargo run --release --example content_probe -- <data dir> <folder> [description ...]
//!
//! `<data dir>` is the app's own (`~/.local/share/com.jrufer.generativeview`):
//! the model, the index and the vectors of pictures the app has already
//! looked at are read from there. Nothing is embedded here, and the only
//! thing written is the everyday descriptions' vectors, which the app would
//! write itself. Close the app first, and put a folder with spaces in its
//! name in quotes.
//!
//! With descriptions, each gets a line: how many pictures land so many
//! spreads above their ordinary run of scores, and the best few.
//!
//! Without, the answer key is the prompts. The everyday words content
//! search measures against (`src/clip/everyday.txt`) are plain things a
//! picture can show, and every picture's score against each is already
//! worked out. A picture prompted with "beach" probably shows one; a word
//! no prompt in the folder mentions is probably in none of them. So:
//!
//!   * for words that some prompts mention, a good measure puts the
//!     prompted pictures above the rest;
//!   * for words no prompt mentions, a good bar lets almost nothing through.
//!
//! The report compares a few ways of turning scores into a measure on both
//! counts, then goes through the words one by one for the measure in use.
//! Prompts are a rough key (a picture can show a beach nobody asked for),
//! so read the figures against each other rather than as marks out of a
//! hundred.

use gvcore::clip::{ContentSearch, Everyday, Fit, CLEAR};
use gvcore::db::{Db, Query};
use gvcore::thumbs::Thumbs;
use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

/// Places the bar could be put, in spreads.
const BARS: [f32; 9] = [1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 3.0, 4.0];
/// How much of the library a word that is in none of it may turn up in.
const LEAKS: [f64; 6] = [0.10, 0.05, 0.02, 0.01, 0.005, 0.002];
/// A word needs this many prompted pictures to say anything about it.
const ENOUGH: usize = 20;

fn main() {
    let mut args = std::env::args().skip(1);
    let (Some(data), Some(folder)) = (args.next(), args.next()) else {
        eprintln!("usage: content_probe <data dir> <folder> [description ...]");
        std::process::exit(2);
    };
    let descriptions: Vec<String> = args.collect();
    let folder = if folder.len() > 1 { folder.trim_end_matches('/').to_string() } else { folder };
    let db = Arc::new(Db::open(Path::new(&data)).expect("open the index"));
    let scratch = std::env::temp_dir().join(format!("gv-probe-{}", std::process::id()));
    let thumbs = Thumbs::start(&scratch);
    let content = ContentSearch::start(Path::new(&data), db.clone(), thumbs.clone(), Arc::new(|_| {})).expect("open the vectors");

    let t = Instant::now();
    let everyday = content.everyday(&folder, true).unwrap_or_else(|e| {
        eprintln!("{e}");
        std::process::exit(1);
    });
    let looked_at = everyday.scores.iter().flatten().count();
    println!("{} pictures under {folder:?}, {looked_at} of them looked at ({:.0?})", everyday.all.rows.len(), t.elapsed());
    if everyday.all.rows.is_empty() {
        eprintln!("The index has no pictures under that folder. Give it as the app shows it, in quotes if it has spaces.");
        std::process::exit(1);
    }
    if looked_at == 0 {
        eprintln!("No picture in this folder has been looked at yet: open it in the app with content search on.");
        std::process::exit(1);
    }
    println!("a match is {CLEAR} spreads or more above a picture's ordinary run of scores\n");

    if descriptions.is_empty() {
        report(&db, &folder, &everyday);
    } else {
        describe(&content, &folder, &descriptions);
    }
}

// ------------------------------------------------------------ descriptions

fn describe(content: &ContentSearch, folder: &str, descriptions: &[String]) {
    let header: String = BARS.iter().map(|bar| format!("{bar:>6.2}")).collect();
    println!("{:<28}{header}   best", "pictures at or above");
    for description in descriptions {
        let t = Instant::now();
        let (all, fits) = content.rate(folder, true, description, "newest").unwrap_or_else(|e| {
            eprintln!("{e}");
            std::process::exit(1);
        });
        let took = t.elapsed();
        let mut rated: Vec<(Fit, &str)> = fits.iter().zip(&all.rows).filter_map(|(fit, row)| fit.map(|fit| (fit, row.2.as_str()))).collect();
        rated.sort_by(|a, b| b.0.above.total_cmp(&a.0.above));
        let counts: String = BARS.iter().map(|bar| format!("{:>6}", rated.iter().filter(|r| r.0.above >= *bar).count())).collect();
        let best = rated.iter().take(4).map(|(fit, name)| format!("{name} {:.2}", fit.above)).collect::<Vec<_>>().join(", ");
        println!("{:<28}{counts}   {best}   ({took:.0?})", clip(description, 27));
    }
}

// ------------------------------------------------------------------ report

/// One everyday word: which of the looked-at pictures were prompted with it.
struct Word {
    name: &'static str,
    prompted: Vec<bool>,
    count: usize,
}

/// A way of turning one picture's scores against every word into a measure
/// of how well each word fits it.
struct Measure {
    name: &'static str,
    note: &'static str,
    of: fn(&[f32]) -> Vec<f32>,
}

const MEASURES: [Measure; 5] = [
    Measure { name: "spreads", note: "above the picture's middle score, in spreads of its scores (in use)", of: spreads },
    Measure { name: "lower", note: "the same, with the spread taken from the lower half of the scores only", of: lower_spreads },
    Measure { name: "rank", note: "the share of everyday words that score lower", of: rank },
    Measure { name: "chance", note: "the model's own odds for the word among all the everyday words, as log10", of: chance },
    Measure { name: "score", note: "the model's score as it comes", of: plain },
];

fn sorted(scores: &[f32]) -> Vec<f32> {
    let mut sorted = scores.to_vec();
    sorted.sort_by(f32::total_cmp);
    sorted
}

fn spreads(scores: &[f32]) -> Vec<f32> {
    let ordered = sorted(scores);
    let middle = ordered[ordered.len() / 2];
    let apart = sorted(&scores.iter().map(|s| (s - middle).abs()).collect::<Vec<_>>());
    let spread = (apart[apart.len() / 2] * 1.4826).max(1e-9);
    scores.iter().map(|s| (s - middle) / spread).collect()
}

fn lower_spreads(scores: &[f32]) -> Vec<f32> {
    let ordered = sorted(scores);
    let middle = ordered[ordered.len() / 2];
    let quarter = ordered[ordered.len() / 4];
    let spread = ((middle - quarter) / 0.6745).max(1e-9);
    scores.iter().map(|s| (s - middle) / spread).collect()
}

fn rank(scores: &[f32]) -> Vec<f32> {
    let ordered = sorted(scores);
    scores.iter().map(|s| ordered.partition_point(|o| o < s) as f32 / (ordered.len() - 1).max(1) as f32).collect()
}

fn chance(scores: &[f32]) -> Vec<f32> {
    // CLIP models multiply scores by about 100 before comparing them.
    let top = scores.iter().copied().fold(f32::MIN, f32::max);
    let total: f32 = scores.iter().map(|s| (100.0 * (s - top)).exp()).sum();
    scores.iter().map(|s| (100.0 * (s - top) - total.ln()) / std::f32::consts::LN_10).collect()
}

fn plain(scores: &[f32]) -> Vec<f32> {
    scores.to_vec()
}

fn report(db: &Db, folder: &str, everyday: &Everyday) {
    // Only pictures that have been looked at can be found or missed.
    let looked: Vec<(i64, &Vec<f32>)> = everyday.all.rows.iter().zip(&everyday.scores).filter_map(|(row, scores)| scores.as_ref().map(|s| (row.0, s))).collect();
    let pictures = looked.len();
    let words: Vec<Word> = everyday
        .words
        .iter()
        .map(|name| {
            let ids: HashSet<i64> = db
                .query(&Query { dir: folder.to_string(), recursive: true, text: format!("prompt:=\"{name}\""), ..Default::default() })
                .map(|found| found.rows.iter().map(|row| row.0).collect())
                .unwrap_or_default();
            let prompted: Vec<bool> = looked.iter().map(|(id, _)| ids.contains(id)).collect();
            Word { name, count: prompted.iter().filter(|p| **p).count(), prompted }
        })
        .collect();
    let told: Vec<usize> = (0..words.len()).filter(|w| words[*w].count >= ENOUGH && words[*w].count < pictures).collect();
    let silent: Vec<usize> = (0..words.len()).filter(|w| words[*w].count == 0).collect();
    println!(
        "{} everyday words: {} are in the prompts of {ENOUGH} or more pictures, {} in none at all.\n",
        words.len(),
        told.len(),
        silent.len()
    );
    if told.is_empty() || silent.is_empty() {
        println!("Not enough to go on: this needs prompts that mention some of the everyday words, and some they leave out.");
        return;
    }

    // measured[m][w][p]: word w's fit to picture p by measure m.
    let measured: Vec<Vec<Vec<f32>>> = MEASURES
        .iter()
        .map(|measure| {
            let by_picture: Vec<Vec<f32>> = looked.iter().map(|(_, scores)| (measure.of)(scores)).collect();
            (0..words.len()).map(|w| by_picture.iter().map(|fits| fits[w]).collect()).collect()
        })
        .collect();

    println!("1. Does the measure put the prompted pictures above the rest?");
    println!("   (0.50 = no better than a coin, 1.00 = always; over the {} words that prompts mention)\n", told.len());
    println!("   {:<10}{:>8}{:>10}   {}", "measure", "middle", "weighted", "");
    for (m, measure) in MEASURES.iter().enumerate() {
        let mut each: Vec<(f64, usize)> = told.iter().map(|w| (separation(&measured[m][*w], &words[*w].prompted), words[*w].count)).collect();
        let weighted = each.iter().map(|(auc, n)| auc * *n as f64).sum::<f64>() / each.iter().map(|(_, n)| *n as f64).sum::<f64>();
        each.sort_by(|a, b| a.0.total_cmp(&b.0));
        println!("   {:<10}{:>8.3}{weighted:>10.3}   {}", measure.name, each[each.len() / 2].0, measure.note);
    }

    println!("\n2. With the bar set so that a word no prompt mentions turns up in a given share of the library");
    println!("   (the middle one of the {} such words), how many of the prompted pictures are still found?\n", silent.len());
    let header: String = LEAKS.iter().map(|leak| format!("{:>9.1}%", leak * 100.0)).collect();
    println!("   {:<10}{:<10}{header}", "measure", "");
    for (m, measure) in MEASURES.iter().enumerate() {
        let quiet: Vec<Vec<f32>> = silent.iter().map(|w| sorted(&measured[m][*w])).collect();
        let (mut bars, mut kept, mut middle, mut worst) = (String::new(), String::new(), String::new(), String::new());
        for leak in LEAKS {
            let bar = bar_for(&quiet, leak);
            let shares: Vec<f64> = told.iter().map(|w| found(&measured[m][*w], &words[*w].prompted, bar).1 as f64 / words[*w].count as f64).collect();
            let all: usize = told.iter().map(|w| found(&measured[m][*w], &words[*w].prompted, bar).1).sum();
            let asked: usize = told.iter().map(|w| words[*w].count).sum();
            let mut leaks: Vec<f64> = quiet.iter().map(|values| share_at(values, bar)).collect();
            leaks.sort_by(f64::total_cmp);
            bars += &format!("{bar:>10.3}");
            kept += &format!("{:>9.1}%", all as f64 * 100.0 / asked as f64);
            middle += &format!("{:>9.1}%", median(shares) * 100.0);
            worst += &format!("{:>9.1}%", leaks[leaks.len() * 9 / 10] * 100.0);
        }
        println!("   {:<10}{:<10}{bars}", measure.name, "bar at");
        println!("   {:<10}{:<10}{kept}", "", "found");
        println!("   {:<10}{:<10}{middle}", "", "per word");
        println!("   {:<10}{:<10}{worst}", "", "1 in 10");
    }
    println!("   found: of all prompted pictures; per word: the middle word's share; 1 in 10: one unmentioned word");
    println!("   in ten turns up in more of the library than this.");

    let header: String = BARS.iter().map(|bar| format!("{bar:>7.2}")).collect();
    println!("\n3. Word by word, for the measure in use (spreads). Pictures found, the share of the prompted");
    println!("   pictures that is, and the share of the found that were prompted:\n");
    println!("   {:<18}{:>8}  {:<6}{header}", "word", "prompts", "");
    let mut by_count = told.clone();
    by_count.sort_by(|a, b| words[*b].count.cmp(&words[*a].count));
    for w in by_count.iter().take(45) {
        let word = &words[*w];
        let (mut counts, mut kept, mut right) = (String::new(), String::new(), String::new());
        for bar in BARS {
            let (all, both) = found(&measured[0][*w], &word.prompted, bar);
            counts += &format!("{all:>7}");
            kept += &percent(both, word.count);
            right += &percent(both, all);
        }
        println!("   {:<18}{:>8}  {:<6}{counts}", clip(word.name, 17), word.count, "found");
        println!("   {:<18}{:>8}  {:<6}{kept}", "", "", "kept");
        println!("   {:<18}{:>8}  {:<6}{right}", "", "", "right");
    }

    println!("\n4. Words no prompt mentions, and how many pictures each turns up in all the same (spreads);");
    println!("   the 40 that turn up most, then the middle one of all {}:\n", silent.len());
    println!("   {:<18}{header}", "word");
    let mut loud: Vec<usize> = silent.clone();
    let at = |w: usize, bar: f32| measured[0][w].iter().filter(|fit| **fit >= bar).count();
    loud.sort_by(|a, b| at(*b, CLEAR).cmp(&at(*a, CLEAR)).then(words[*a].name.cmp(words[*b].name)));
    for w in loud.iter().take(40) {
        let counts: String = BARS.iter().map(|bar| format!("{:>7}", at(*w, *bar))).collect();
        println!("   {:<18}{counts}", clip(words[*w].name, 17));
    }
    let totals: String = BARS.iter().map(|bar| format!("{:>6.1}%", median(silent.iter().map(|w| at(*w, *bar) as f64 * 100.0 / pictures as f64).collect()))).collect();
    println!("   {:<18}{totals}", "the middle word");
}

/// How often a prompted picture is rated above one that was not (the area
/// under the ROC curve): ties count half.
fn separation(fits: &[f32], prompted: &[bool]) -> f64 {
    let mut order: Vec<usize> = (0..fits.len()).collect();
    order.sort_by(|a, b| fits[*a].total_cmp(&fits[*b]));
    // Sum of the prompted pictures' ranks, ties sharing their average rank.
    let (mut ranks, mut i) = (0.0f64, 0);
    while i < order.len() {
        let mut j = i;
        while j < order.len() && fits[order[j]] == fits[order[i]] {
            j += 1;
        }
        let shared = (i + j + 1) as f64 / 2.0;
        ranks += shared * order[i..j].iter().filter(|p| prompted[**p]).count() as f64;
        i = j;
    }
    let yes = prompted.iter().filter(|p| **p).count() as f64;
    let no = prompted.len() as f64 - yes;
    (ranks - yes * (yes + 1.0) / 2.0) / (yes * no)
}

/// How many pictures reach `bar`, and how many of those were prompted.
fn found(fits: &[f32], prompted: &[bool], bar: f32) -> (usize, usize) {
    let all = fits.iter().filter(|fit| **fit >= bar).count();
    let both = fits.iter().zip(prompted).filter(|(fit, p)| **fit >= bar && **p).count();
    (all, both)
}

/// The share of (ascending) `values` at or above `bar`.
fn share_at(values: &[f32], bar: f32) -> f64 {
    (values.len() - values.partition_point(|v| *v < bar)) as f64 / values.len().max(1) as f64
}

/// The bar at which the middle one of `quiet` words turns up in `leak` of
/// the pictures.
fn bar_for(quiet: &[Vec<f32>], leak: f64) -> f32 {
    let low = quiet.iter().map(|v| v[0]).fold(f32::MAX, f32::min);
    let high = quiet.iter().map(|v| v[v.len() - 1]).fold(f32::MIN, f32::max);
    let (mut low, mut high) = (low, high);
    for _ in 0..50 {
        let bar = (low + high) / 2.0;
        if median(quiet.iter().map(|values| share_at(values, bar)).collect()) > leak {
            low = bar;
        } else {
            high = bar;
        }
    }
    high
}

fn median(mut values: Vec<f64>) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    values.sort_by(f64::total_cmp);
    values[values.len() / 2]
}

fn percent(part: usize, whole: usize) -> String {
    if whole == 0 {
        return format!("{:>7}", "-");
    }
    format!("{:>6.0}%", part as f64 * 100.0 / whole as f64)
}

fn clip(text: &str, chars: usize) -> String {
    text.chars().take(chars).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sums() {
        // Every prompted picture above every other: 1. The other way: 0.
        assert_eq!(separation(&[0.1, 0.9, 0.2, 0.8], &[false, true, false, true]), 1.0);
        assert_eq!(separation(&[0.1, 0.9, 0.2, 0.8], &[true, false, true, false]), 0.0);
        // One of the four pairs the wrong way round; all tied.
        assert_eq!(separation(&[0.1, 0.9, 0.2, 0.15], &[false, true, false, true]), 0.75);
        assert_eq!(separation(&[0.5, 0.5, 0.5, 0.5], &[false, true, false, true]), 0.5);

        assert_eq!(found(&[1.0, 2.0, 3.0], &[true, false, true], 2.0), (2, 1));
        assert_eq!(share_at(&[1.0, 2.0, 3.0, 4.0], 2.5), 0.5);
        // Three words over ten pictures: the bar that lets the middle word
        // into two of them sits just above its third-best score.
        let quiet: Vec<Vec<f32>> = (0..3).map(|w| (0..10).map(|p| p as f32 + w as f32 * 0.1).collect()).collect();
        let bar = bar_for(&quiet, 0.2);
        assert!(bar > 7.1 && bar <= 8.1, "{bar}");
        assert_eq!(share_at(&quiet[1], bar), 0.2);

        // Each measure keeps the order of one picture's scores.
        let scores = [0.21, 0.18, 0.30, 0.19, 0.17, 0.22, 0.20];
        for measure in &MEASURES {
            let fits = (measure.of)(&scores);
            for (a, b) in [(2, 5), (5, 0), (0, 6), (6, 3), (3, 1), (1, 4)] {
                assert!(fits[a] > fits[b], "{}: {fits:?}", measure.name);
            }
        }
        assert_eq!(rank(&scores)[2], 1.0);
        assert_eq!(rank(&scores)[4], 0.0);
        assert_eq!(spreads(&scores)[6], 0.0);
    }
}
