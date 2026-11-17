//! Edge-aware local filters used by the tone, clarity and dehaze tools.
//!
//! Plain Gaussian blurs make halos around edges (bright rims along a skyline, dark
//! outlines around faces) as soon as shadows, clarity or dehaze are pushed. Pro editors
//! avoid this with edge-aware base layers; we use the (fast) guided filter of He et al.,
//! which smooths inside regions but stops at strong edges.

use rayon::prelude::*;

/// Mean over a (2r+1)² box, edges clamped.
pub fn box_mean(src: &[f32], w: usize, h: usize, r: usize) -> Vec<f32> {
    if r == 0 {
        return src.to_vec();
    }
    let ri = r as isize;
    let norm = 1.0 / (2 * r + 1) as f32;
    // Horizontal pass.
    let mut tmp = vec![0.0f32; src.len()];
    tmp.par_chunks_mut(w).zip(src.par_chunks(w)).for_each(|(out, row)| {
        let get = |i: isize| row[i.clamp(0, w as isize - 1) as usize];
        let mut acc = 0.0f32;
        for i in -ri..=ri {
            acc += get(i);
        }
        for x in 0..w {
            out[x] = acc * norm;
            acc += get(x as isize + ri + 1) - get(x as isize - ri);
        }
    });
    // Vertical pass, a block of columns per task for cache friendliness.
    let mut out = vec![0.0f32; src.len()];
    const B: usize = 32;
    let blocks: Vec<(usize, Vec<f32>)> = (0..w.div_ceil(B))
        .into_par_iter()
        .map(|bi| {
            let x0 = bi * B;
            let bw = B.min(w - x0);
            let mut col = vec![0.0f32; bw * h];
            let get = |y: isize, k: usize| tmp[y.clamp(0, h as isize - 1) as usize * w + x0 + k];
            for k in 0..bw {
                let mut acc = 0.0f32;
                for i in -ri..=ri {
                    acc += get(i, k);
                }
                for y in 0..h {
                    col[y * bw + k] = acc * norm;
                    acc += get(y as isize + ri + 1, k) - get(y as isize - ri, k);
                }
            }
            (x0, col)
        })
        .collect();
    for (x0, col) in blocks {
        let bw = col.len() / h.max(1);
        for y in 0..h {
            out[y * w + x0..y * w + x0 + bw].copy_from_slice(&col[y * bw..(y + 1) * bw]);
        }
    }
    out
}

fn downsample(src: &[f32], w: usize, h: usize, s: usize) -> (Vec<f32>, usize, usize) {
    let (lw, lh) = (w.div_ceil(s), h.div_ceil(s));
    let mut out = vec![0.0f32; lw * lh];
    out.par_chunks_mut(lw).enumerate().for_each(|(y, row)| {
        let (y0, y1) = (y * s, ((y + 1) * s).min(h));
        for (x, v) in row.iter_mut().enumerate() {
            let (x0, x1) = (x * s, ((x + 1) * s).min(w));
            let mut acc = 0.0;
            for yy in y0..y1 {
                for xx in x0..x1 {
                    acc += src[yy * w + xx];
                }
            }
            *v = acc / ((y1 - y0) * (x1 - x0)) as f32;
        }
    });
    (out, lw, lh)
}

#[inline]
fn sample(src: &[f32], lw: usize, lh: usize, x: f32, y: f32) -> f32 {
    let x = x.clamp(0.0, (lw - 1) as f32);
    let y = y.clamp(0.0, (lh - 1) as f32);
    let (x0, y0) = (x as usize, y as usize);
    let (x1, y1) = ((x0 + 1).min(lw - 1), (y0 + 1).min(lh - 1));
    let (fx, fy) = (x - x0 as f32, y - y0 as f32);
    let top = src[y0 * lw + x0] + (src[y0 * lw + x1] - src[y0 * lw + x0]) * fx;
    let bot = src[y1 * lw + x0] + (src[y1 * lw + x1] - src[y1 * lw + x0]) * fx;
    top + (bot - top) * fy
}

/// Self-guided fast guided filter: an edge-preserving smooth of `p`.
/// `radius` is in full-resolution pixels; `eps` is the edge threshold as a variance
/// (structures with a local std-dev well above sqrt(eps) are kept sharp).
pub fn guided(p: &[f32], w: usize, h: usize, radius: usize, eps: f32) -> Vec<f32> {
    let radius = radius.max(1);
    // Work at reduced resolution (the fast guided filter): coefficients are smooth anyway.
    let s = (radius / 4).max(1);
    let (lp, lw, lh) = if s > 1 { downsample(p, w, h, s) } else { (p.to_vec(), w, h) };
    let r = (radius / s).max(1);
    let mean_p = box_mean(&lp, lw, lh, r);
    let sq: Vec<f32> = lp.par_iter().map(|v| v * v).collect();
    let mean_pp = box_mean(&sq, lw, lh, r);
    let (a, b): (Vec<f32>, Vec<f32>) = mean_p
        .par_iter()
        .zip(mean_pp.par_iter())
        .map(|(&m, &mm)| {
            let var = (mm - m * m).max(0.0);
            let a = var / (var + eps);
            (a, m - a * m)
        })
        .unzip();
    let ma = box_mean(&a, lw, lh, r);
    let mb = box_mean(&b, lw, lh, r);
    let mut out = vec![0.0f32; w * h];
    out.par_chunks_mut(w).enumerate().for_each(|(y, row)| {
        let sy = (y as f32 + 0.5) / s as f32 - 0.5;
        for (x, q) in row.iter_mut().enumerate() {
            let sx = (x as f32 + 0.5) / s as f32 - 0.5;
            let (av, bv) = if s > 1 { (sample(&ma, lw, lh, sx, sy), sample(&mb, lw, lh, sx, sy)) } else { (ma[y * w + x], mb[y * w + x]) };
            *q = av * p[y * w + x] + bv;
        }
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guided_keeps_step_edges() {
        let (w, h) = (64, 32);
        let p: Vec<f32> = (0..w * h).map(|i| if i % w < w / 2 { 0.1 } else { 0.9 }).collect();
        let q = guided(&p, w, h, 8, 0.01);
        // Next to the edge the filtered value stays on its own side (no halo).
        assert!((q[10 * w + w / 2 - 2] - 0.1).abs() < 0.05, "{}", q[10 * w + w / 2 - 2]);
        assert!((q[10 * w + w / 2 + 1] - 0.9).abs() < 0.05);
    }

    #[test]
    fn box_mean_flat() {
        let p = vec![0.5f32; 50 * 40];
        assert!(box_mean(&p, 50, 40, 5).iter().all(|v| (v - 0.5).abs() < 1e-5));
    }
}
