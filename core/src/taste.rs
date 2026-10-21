//! A model of the user's taste, learned from their own stars and flags.
//!
//! Every picture content search has looked at has a vector saying what it
//! shows (see [`crate::clip`]). The pictures the user has rated or flagged
//! say what they like; a ridge regression from vector to how well liked
//! learns which way in that space "liked" lies, and then scores every
//! other picture by it. It is small (one weight per dimension), quick to
//! fit (a few hundred milliseconds for thousands of ratings), runs on the
//! device, and needs nothing but what is already there.
//!
//! It also says how far to trust it: fitted again with each fifth of the
//! ratings held out, how often it puts a held-out keeper above a held-out
//! reject. Below [`USEFUL`] it makes no suggestions, only an order.

use rayon::prelude::*;

/// How liked a picture is, 0 to 1, from what the user said about it: its
/// stars, raised for a keep flag and lowered to nothing for a reject.
/// None for a picture they have said nothing about.
pub fn target(rating: u8, flag: u8) -> Option<f32> {
    match (rating.min(5), flag) {
        (_, 2) => Some(0.0),
        (0, 1) => Some(KEPT),
        (0, _) => None,
        (r, f) => {
            let stars = (r as f32 - 1.0) / 4.0;
            Some(if f == 1 { stars.max(KEPT) } else { stars })
        }
    }
}

/// What a keep flag alone says: between four and five stars.
const KEPT: f32 = 0.85;

/// Liked (four stars or more, or kept) and disliked (two or fewer, or
/// rejected), for counting and for measuring the model.
pub fn is_liked(target: f32) -> bool {
    target >= 0.74
}
pub fn is_disliked(target: f32) -> bool {
    target <= 0.26
}

/// The fewest liked and disliked pictures each it will learn from.
pub const AT_LEAST: usize = 5;

/// How often (of keeper-reject pairs held out) it must order them rightly
/// to make suggestions.
pub const USEFUL: f32 = 0.65;

/// It learns from at most this many, evenly spread, to stay quick.
const MOST: usize = 4000;

/// Strengths of the pull towards zero to try; the one that does best on
/// held-out ratings is kept. The vectors are of length one, so these are on
/// the scale of how many pictures agree.
const LAMBDAS: [f64; 6] = [0.03, 0.1, 0.3, 1.0, 3.0, 10.0];

/// A picture to learn from.
pub struct Sample {
    pub vector: Vec<f32>,
    pub target: f32,
}

/// The learned model.
#[derive(Debug, Clone)]
pub struct Model {
    weights: Vec<f32>,
    bias: f32,
    /// How many pictures it learned from, and how many of them were liked
    /// and disliked.
    pub learned_from: usize,
    pub liked: usize,
    pub disliked: usize,
    /// Of pairs of a held-out liked and a held-out disliked picture, the
    /// share it scored the right way round.
    pub agreement: f32,
    /// Scores at or above this suggest a keeper; at or below `reject_at`,
    /// a reject. Set from what held-out keepers and rejects scored.
    keep_at: f32,
    reject_at: f32,
}

/// What the model makes of one picture.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Verdict {
    Keep,
    Reject,
    Unsure,
}

impl Model {
    /// How liked a picture of `vector` would be, 0 to 1 (or a little
    /// beyond, for one more extreme than any it learned from).
    pub fn score(&self, vector: &[f32]) -> f32 {
        if vector.len() != self.weights.len() {
            return f32::NAN;
        }
        self.bias + vector.iter().zip(&self.weights).map(|(x, w)| x * w).sum::<f32>()
    }

    /// The score as stars, 1 to 5.
    pub fn stars(&self, score: f32) -> f32 {
        (1.0 + 4.0 * score).clamp(1.0, 5.0)
    }

    pub fn useful(&self) -> bool {
        self.agreement >= USEFUL
    }

    pub fn verdict(&self, score: f32) -> Verdict {
        if !self.useful() || score.is_nan() {
            Verdict::Unsure
        } else if score >= self.keep_at {
            Verdict::Keep
        } else if score <= self.reject_at {
            Verdict::Reject
        } else {
            Verdict::Unsure
        }
    }

    pub fn dim(&self) -> usize {
        self.weights.len()
    }
}

/// Why there is no model yet, as what is still needed.
#[derive(Debug, Clone, PartialEq)]
pub struct NotYet {
    pub liked: usize,
    pub disliked: usize,
}

/// Learn from `samples`, which must all have vectors of one length.
pub fn fit(samples: &[Sample]) -> Result<Model, NotYet> {
    let liked = samples.iter().filter(|s| is_liked(s.target)).count();
    let disliked = samples.iter().filter(|s| is_disliked(s.target)).count();
    if liked < AT_LEAST || disliked < AT_LEAST || samples.is_empty() {
        return Err(NotYet { liked, disliked });
    }
    let dim = samples[0].vector.len();
    // Evenly spread if there are too many.
    let picked: Vec<&Sample> = if samples.len() > MOST {
        let step = samples.len() as f64 / MOST as f64;
        (0..MOST).map(|i| &samples[(i as f64 * step) as usize]).collect()
    } else {
        samples.iter().collect()
    };
    let n = picked.len();
    let rows: Vec<Vec<f64>> = picked.iter().map(|s| s.vector.iter().map(|&x| x as f64).collect()).collect();
    let y: Vec<f64> = picked.iter().map(|s| s.target as f64).collect();

    // Features centred on their mean, so the bias takes the mean liking.
    let mut mean = vec![0f64; dim];
    for r in &rows {
        for (m, x) in mean.iter_mut().zip(r) {
            *m += x;
        }
    }
    mean.iter_mut().for_each(|m| *m /= n as f64);
    let rows: Vec<Vec<f64>> = rows.into_iter().map(|r| r.iter().zip(&mean).map(|(x, m)| x - m).collect()).collect();

    // Five folds, by position (the order is already mixed: newest first
    // across folders), every fifth picture in each.
    let folds = 5.min(n);
    let fold_of = |i: usize| i % folds;
    let gram = |which: &dyn Fn(usize) -> bool| -> Vec<f64> { gram_of(&rows, dim, which) };
    let full = gram(&|_| true);
    let parts: Vec<Vec<f64>> = (0..folds).map(|f| gram(&|i| fold_of(i) == f)).collect();

    // For each strength, the held-out scores of every picture.
    let mut best: Option<(f32, f64, Vec<f64>)> = None;
    for &lambda in &LAMBDAS {
        let mut held = vec![0f64; n];
        for f in 0..folds {
            let train = |i: usize| fold_of(i) != f;
            let mut g: Vec<f64> = full.iter().zip(&parts[f]).map(|(a, b)| a - b).collect();
            let count = (0..n).filter(|&i| train(i)).count().max(1);
            let ybar = (0..n).filter(|&i| train(i)).map(|i| y[i]).sum::<f64>() / count as f64;
            let w = solve_ridge(&mut g, &rows, &y, ybar, dim, lambda, &train);
            for i in (0..n).filter(|&i| !train(i)) {
                held[i] = ybar + dot(&rows[i], &w);
            }
        }
        let agreement = pair_agreement(&held, &y);
        if best.as_ref().is_none_or(|(a, _, _)| agreement > *a) {
            best = Some((agreement, lambda, held));
        }
    }
    let (agreement, lambda, held) = best.expect("at least one strength");

    // The model itself, from all of them.
    let mut g = full;
    let ybar = y.iter().sum::<f64>() / n as f64;
    let w = solve_ridge(&mut g, &rows, &y, ybar, dim, lambda, &|_| true);
    // Centred features: the bias carries the mean back out.
    let bias = ybar - dot(&mean, &w);

    // Where held-out keepers and rejects scored: a picture is suggested as
    // a keeper where most keepers scored and nearly no rejects did, and the
    // other way round.
    let quantile = |mut v: Vec<f64>, q: f64| -> f32 {
        v.sort_by(f64::total_cmp);
        if v.is_empty() {
            return f32::NAN;
        }
        v[((v.len() - 1) as f64 * q).round() as usize] as f32
    };
    let kept: Vec<f64> = (0..n).filter(|&i| is_liked(y[i] as f32)).map(|i| held[i]).collect();
    let rejected: Vec<f64> = (0..n).filter(|&i| is_disliked(y[i] as f32)).map(|i| held[i]).collect();
    let keep_at = quantile(kept.clone(), 0.25).max(quantile(rejected.clone(), 0.9));
    let reject_at = quantile(rejected, 0.75).min(quantile(kept, 0.1));
    Ok(Model {
        weights: w.iter().map(|&x| x as f32).collect(),
        bias: bias as f32,
        learned_from: n,
        liked,
        disliked,
        agreement,
        // Never the wrong way round, however poor the model.
        keep_at: keep_at.max(reject_at),
        reject_at: reject_at.min(keep_at),
    })
}

fn dot(a: &[f64], b: &[f64]) -> f64 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

/// XᵀX over the rows `which` picks (the upper triangle filled, then copied).
fn gram_of(rows: &[Vec<f64>], dim: usize, which: &dyn Fn(usize) -> bool) -> Vec<f64> {
    let picked: Vec<&Vec<f64>> = rows.iter().enumerate().filter(|(i, _)| which(*i)).map(|(_, r)| r).collect();
    let mut g = vec![0f64; dim * dim];
    g.par_chunks_mut(dim).enumerate().for_each(|(a, row)| {
        for r in &picked {
            let ra = r[a];
            if ra == 0.0 {
                continue;
            }
            for b in a..dim {
                row[b] += ra * r[b];
            }
        }
    });
    for a in 0..dim {
        for b in 0..a {
            g[a * dim + b] = g[b * dim + a];
        }
    }
    g
}

/// The weights of a ridge regression: (G + λI) w = Xᵀ(y − ȳ) over the rows
/// `train` picks, G their Gram matrix (overwritten).
fn solve_ridge(g: &mut [f64], rows: &[Vec<f64>], y: &[f64], ybar: f64, dim: usize, lambda: f64, train: &dyn Fn(usize) -> bool) -> Vec<f64> {
    let mut rhs = vec![0f64; dim];
    for (i, r) in rows.iter().enumerate() {
        if !train(i) {
            continue;
        }
        let t = y[i] - ybar;
        for (b, x) in rhs.iter_mut().zip(r) {
            *b += t * x;
        }
    }
    for a in 0..dim {
        g[a * dim + a] += lambda;
    }
    cholesky_solve(g, &mut rhs, dim);
    rhs
}

/// Solve A x = b in place for symmetric positive definite A (n × n, row
/// major, overwritten by its Cholesky factor); b becomes x.
fn cholesky_solve(a: &mut [f64], b: &mut [f64], n: usize) {
    for j in 0..n {
        let mut d = a[j * n + j];
        for k in 0..j {
            d -= a[j * n + k] * a[j * n + k];
        }
        let d = d.max(1e-12).sqrt();
        a[j * n + j] = d;
        // Each row below is independent of the others.
        let (top, below) = a.split_at_mut((j + 1) * n);
        let row_j = &top[j * n..j * n + j];
        below.par_chunks_mut(n).for_each(|row_i| {
            let mut s = row_i[j];
            for k in 0..j {
                s -= row_i[k] * row_j[k];
            }
            row_i[j] = s / d;
        });
    }
    // L y = b, then Lᵀ x = y.
    for i in 0..n {
        let mut s = b[i];
        for k in 0..i {
            s -= a[i * n + k] * b[k];
        }
        b[i] = s / a[i * n + i];
    }
    for i in (0..n).rev() {
        let mut s = b[i];
        for k in i + 1..n {
            s -= a[k * n + i] * b[k];
        }
        b[i] = s / a[i * n + i];
    }
}

/// Of every pair of a liked and a disliked picture, the share `scores`
/// puts the right way round (ties count half).
fn pair_agreement(scores: &[f64], y: &[f64]) -> f32 {
    let mut good: Vec<f64> = Vec::new();
    let mut bad: Vec<f64> = Vec::new();
    for (s, t) in scores.iter().zip(y) {
        if is_liked(*t as f32) {
            good.push(*s);
        } else if is_disliked(*t as f32) {
            bad.push(*s);
        }
    }
    if good.is_empty() || bad.is_empty() {
        return 0.5;
    }
    bad.sort_by(f64::total_cmp);
    // For each liked one, how many disliked are below it.
    let mut right = 0f64;
    for g in &good {
        let below = bad.partition_point(|b| b < g);
        let equal = bad[below..].partition_point(|b| b <= g);
        right += below as f64 + equal as f64 / 2.0;
    }
    (right / (good.len() * bad.len()) as f64) as f32
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A unit vector of length `dim` pointing mostly along axis `axis`,
    /// with a little of `noise` mixed in.
    fn vector(dim: usize, axis: usize, noise: u64) -> Vec<f32> {
        let mut v: Vec<f32> = (0..dim)
            .map(|i| {
                // Cheap repeatable noise.
                let h = (noise.wrapping_mul(6364136223846793005).wrapping_add(i as u64 * 1442695040888963407)) >> 40;
                (h % 1000) as f32 / 1000.0 * 0.3
            })
            .collect();
        v[axis] += 1.0;
        let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        v.iter_mut().for_each(|x| *x /= norm);
        v
    }

    #[test]
    fn what_the_user_said_becomes_how_liked() {
        assert_eq!(target(0, 0), None);
        assert_eq!(target(5, 0), Some(1.0));
        assert_eq!(target(1, 0), Some(0.0));
        assert_eq!(target(3, 0), Some(0.5));
        assert_eq!(target(0, 1), Some(KEPT));
        assert_eq!(target(2, 1), Some(KEPT), "kept outranks its stars");
        assert_eq!(target(5, 2), Some(0.0), "rejected outranks its stars");
    }

    #[test]
    fn too_few_ratings_says_how_many_more() {
        let samples: Vec<Sample> = (0..4).map(|i| Sample { vector: vector(8, 0, i), target: 1.0 }).collect();
        let err = fit(&samples).unwrap_err();
        assert_eq!(err, NotYet { liked: 4, disliked: 0 });
    }

    #[test]
    fn it_learns_which_way_liked_lies() {
        // Liked pictures point along axis 0, disliked along axis 1, so a
        // new picture along axis 0 should score high and one along 1 low.
        let dim = 16;
        let mut samples = Vec::new();
        for i in 0..30 {
            samples.push(Sample { vector: vector(dim, 0, i), target: 1.0 });
            samples.push(Sample { vector: vector(dim, 1, i + 100), target: 0.0 });
            samples.push(Sample { vector: vector(dim, 2, i + 200), target: 0.5 });
        }
        let model = fit(&samples).unwrap();
        assert_eq!(model.learned_from, 90);
        assert_eq!((model.liked, model.disliked), (30, 30));
        assert!(model.agreement > 0.95, "agreement {}", model.agreement);
        assert!(model.useful());
        let good = model.score(&vector(dim, 0, 999));
        let bad = model.score(&vector(dim, 1, 998));
        assert!(good > 0.8 && bad < 0.2, "good {good}, bad {bad}");
        // New pictures of each kind: most are called rightly, none wrongly.
        let verdicts = |axis: usize| -> Vec<Verdict> { (0..40).map(|i| model.verdict(model.score(&vector(dim, axis, 5000 + i)))).collect() };
        let likes = verdicts(0);
        let dislikes = verdicts(1);
        assert!(likes.iter().filter(|v| **v == Verdict::Keep).count() >= 20, "{likes:?}");
        assert!(dislikes.iter().filter(|v| **v == Verdict::Reject).count() >= 20, "{dislikes:?}");
        assert!(!likes.contains(&Verdict::Reject) && !dislikes.contains(&Verdict::Keep));
        assert!(model.stars(good) > 4.0);
        assert!(model.score(&[0.0; 3]).is_nan(), "a vector of another length scores nothing");
    }

    #[test]
    fn ratings_with_no_pattern_make_no_suggestions() {
        // Liked and disliked pictures drawn from the same place.
        let dim = 16;
        // Each kind of picture is as often liked as not.
        let samples: Vec<Sample> = (0..80).map(|i| Sample { vector: vector(dim, (i % 4) as usize, i), target: if (i / 4) % 2 == 0 { 1.0 } else { 0.0 } }).collect();
        let model = fit(&samples).unwrap();
        assert!(!model.useful(), "agreement {}", model.agreement);
        assert_eq!(model.verdict(model.score(&vector(dim, 0, 5))), Verdict::Unsure);
    }

    #[test]
    fn pairs_are_counted_with_ties_as_half() {
        assert_eq!(pair_agreement(&[0.9, 0.1], &[1.0, 0.0]), 1.0);
        assert_eq!(pair_agreement(&[0.1, 0.9], &[1.0, 0.0]), 0.0);
        assert_eq!(pair_agreement(&[0.5, 0.5], &[1.0, 0.0]), 0.5);
    }

    #[test]
    fn cholesky_solves_a_small_system() {
        // [[4, 2], [2, 3]] x = [2, 1]  →  x = [0.5, 0]
        let mut a = vec![4.0, 2.0, 2.0, 3.0];
        let mut b = vec![2.0, 1.0];
        cholesky_solve(&mut a, &mut b, 2);
        assert!((b[0] - 0.5).abs() < 1e-12 && b[1].abs() < 1e-12, "{b:?}");
    }
}
