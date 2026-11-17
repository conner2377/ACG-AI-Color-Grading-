//! Photo analysis and automatic grading.

use serde::Serialize;

use crate::color::*;
use crate::pipeline::Image;
use crate::presets;
use crate::recipe::Recipe;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub enum Scene {
    Portrait,
    Landscape,
    Night,
    Sunset,
    General,
}

#[derive(Clone, Debug, Serialize)]
pub struct Stats {
    /// Display-space luminance percentiles.
    pub p01: f32,
    pub p05: f32,
    pub p50: f32,
    pub p95: f32,
    pub p99: f32,
    pub mean_luma: f32,
    pub mean_sat: f32,
    /// Fraction of pixels with any channel clipped.
    pub clipped: f32,
    /// Fraction of pixels crushed to black.
    pub crushed: f32,
    /// Estimated illuminant in linear RGB (white-balance estimate, luminance-normalized).
    pub neutral_rgb: Rgb,
    /// How trustworthy the white-balance estimate is (0..1).
    pub wb_confidence: f32,
    /// Average color cast in OKLab (a: +red/-green, b: +yellow/-blue).
    pub cast_a: f32,
    pub cast_b: f32,
    /// 10-bin luminance histogram (fractions), dark to bright.
    pub histogram: [f32; 10],
    pub skin_fraction: f32,
    pub green_fraction: f32,
    pub blue_fraction: f32,
    pub warm_fraction: f32,
    pub scene: Scene,
}

pub fn analyze(img: &Image) -> Stats {
    let small = img.downscale(512);
    let n = small.data.len().max(1) as f32;
    let mut lum: Vec<f32> = Vec::with_capacity(small.data.len());
    let (mut sat_sum, mut clipped, mut crushed, mut luma_sum) = (0.0f32, 0.0f32, 0.0f32, 0.0f32);
    // Three illuminant estimators: near-neutral pixels (OKLab), shades-of-gray (p=6), bright pixels.
    let (mut neutral, mut neutral_n) = ([0.0f32; 3], 0.0f32);
    let mut sog = [0.0f64; 3];
    let (mut cast_a, mut cast_b) = (0.0f32, 0.0f32);
    let mut histogram = [0.0f32; 10];
    let (mut skin, mut green, mut blue, mut warm) = (0.0f32, 0.0f32, 0.0f32, 0.0f32);
    let mut bright: Vec<(f32, Rgb)> = Vec::new();
    for &p in &small.data {
        let lin = p.map(|v| v.clamp(0.0, 1.0));
        let d = lin.map(linear_to_srgb);
        let l = luma(d);
        lum.push(l);
        luma_sum += l;
        histogram[((l * 10.0) as usize).min(9)] += 1.0 / n;
        let is_clipped = d.iter().any(|&v| v > 0.995);
        if is_clipped { clipped += 1.0; }
        if l < 0.02 { crushed += 1.0; }
        let lab = linear_to_oklab(lin);
        let chroma = (lab[1] * lab[1] + lab[2] * lab[2]).sqrt();
        cast_a += lab[1];
        cast_b += lab[2];
        let hsl = rgb_to_hsl(d);
        sat_sum += hsl[1];
        if !is_clipped && l > 0.04 {
            for k in 0..3 { sog[k] += (lin[k] as f64).powi(6); }
            bright.push((l, lin));
        }
        // Near-neutral surfaces: low chroma, not too dark, not clipped.
        if !is_clipped && chroma < 0.035 && lab[0] > 0.35 && lab[0] < 0.97 {
            let wgt = 1.0 - chroma / 0.035;
            for k in 0..3 { neutral[k] += lin[k] * wgt; }
            neutral_n += wgt;
        }
        if hsl[1] > 0.15 && l > 0.1 {
            let hue = hsl[0];
            if skin_weight(lab) > 0.5 && hsl[1] < 0.75 && l > 0.25 { skin += 1.0; }
            if (70.0..=165.0).contains(&hue) { green += 1.0; }
            if (185.0..=250.0).contains(&hue) { blue += 1.0; }
            if (hue < 50.0 || hue > 340.0) && hsl[1] > 0.35 { warm += 1.0; }
        }
    }
    lum.sort_by(|a, b| a.total_cmp(b));
    let pct = |q: f32| if lum.is_empty() { 0.5 } else { lum[((lum.len() - 1) as f32 * q) as usize] };

    let norm = |c: Rgb| -> Rgb {
        let y = luma(c).max(1e-6);
        [c[0] / y, c[1] / y, c[2] / y]
    };
    // Bright-pixel estimator: mean of the top 3% unclipped pixels.
    bright.sort_by(|a, b| b.0.total_cmp(&a.0));
    let top = (bright.len() / 33).max(1).min(bright.len());
    let mut bmean = [0.0f32; 3];
    for (_, c) in bright.iter().take(top) { for k in 0..3 { bmean[k] += c[k]; } }
    let est_sog = norm(sog.map(|v| (v / n as f64).powf(1.0 / 6.0) as f32));
    let est_bright = if top > 0 { norm(bmean) } else { [1.0; 3] };
    let neutral_frac = neutral_n / n;
    let (neutral_rgb, wb_confidence) = if neutral_frac > 0.03 {
        let est_n = norm(neutral);
        // Neutral pixels are the most reliable; the others refine it.
        let mut e = [0.0; 3];
        for k in 0..3 { e[k] = est_n[k] * 0.6 + est_sog[k] * 0.25 + est_bright[k] * 0.15; }
        (e, (neutral_frac * 6.0).clamp(0.4, 1.0))
    } else {
        let mut e = [0.0; 3];
        for k in 0..3 { e[k] = est_sog[k] * 0.6 + est_bright[k] * 0.4; }
        (e, 0.3)
    };

    let mut s = Stats {
        p01: pct(0.01),
        p05: pct(0.05),
        p50: pct(0.5),
        p95: pct(0.95),
        p99: pct(0.99),
        mean_luma: luma_sum / n,
        mean_sat: sat_sum / n,
        clipped: clipped / n,
        crushed: crushed / n,
        neutral_rgb,
        wb_confidence,
        cast_a: cast_a / n,
        cast_b: cast_b / n,
        histogram,
        skin_fraction: skin / n,
        green_fraction: green / n,
        blue_fraction: blue / n,
        warm_fraction: warm / n,
        scene: Scene::General,
    };
    s.scene = if s.p50 < 0.18 && s.p95 < 0.7 {
        Scene::Night
    } else if s.skin_fraction > 0.08 {
        Scene::Portrait
    } else if s.warm_fraction > 0.25 && s.p50 < 0.55 {
        Scene::Sunset
    } else if s.green_fraction + s.blue_fraction > 0.35 {
        Scene::Landscape
    } else {
        Scene::General
    };
    s
}

/// The physical baseline: exposure, white balance, black/white points and clipping
/// avoidance, computed only from measurements (no taste involved). Styles and AI
/// choices are layered on top of this.
pub fn auto_correct(s: &Stats) -> Recipe {
    let mut r = Recipe::named("자동 보정");
    r.category = "기본".into();
    r.description = "히스토그램 기반 노출·화이트밸런스·명암 범위 보정".into();

    // --- Exposure: move the median toward a scene-appropriate mid-grey, but never
    // push the bright end (p99) past white by more than the highlight roll-off can absorb.
    let target = match s.scene {
        Scene::Night => 0.26,
        Scene::Sunset => 0.40,
        Scene::Portrait => 0.50,
        _ => 0.46,
    };
    let mut ev = (srgb_to_linear(target) / srgb_to_linear(s.p50.max(0.02))).log2() * 0.85;
    let headroom = (srgb_to_linear(0.97) / srgb_to_linear(s.p99.max(0.05))).log2() + 0.6;
    if ev > 0.0 {
        ev = ev.min(headroom.max(0.0));
    }
    r.exposure = ev.clamp(-1.5, 2.0);

    // Predicted percentiles after exposure.
    let g = 2f32.powf(r.exposure);
    let after = |v: f32| linear_to_srgb((srgb_to_linear(v) * g).min(4.0));
    let (p01, p05, p95, p99) = (after(s.p01), after(s.p05), after(s.p95), after(s.p99));

    // --- White balance: undo the estimated illuminant, partially (keeps mood), more
    // strongly when the estimate is confident.
    let [nr, ng, nb] = s.neutral_rgb;
    if nr > 0.0 && nb > 0.0 && ng > 0.0 {
        let keep = match s.scene {
            Scene::Sunset => 0.25,
            Scene::Night => 0.4,
            _ => 0.85,
        } * s.wb_confidence;
        // Gains: R/B = 2^(0.9*temp), G = 2^(-0.3*tint) (see pipeline).
        let temp = -(nr / nb).log2() / 0.9;
        let tint = -((nr * nb).sqrt() / ng).log2() / 0.3;
        // Ignore tiny casts (noise), correct larger ones.
        let dz = |v: f32, z: f32| if v.abs() < z { 0.0 } else { v - z * v.signum() };
        r.temperature = (dz(temp, 0.03) * keep).clamp(-0.7, 0.7);
        r.tint = (dz(tint, 0.03) * keep).clamp(-0.5, 0.5);
    }

    // --- Highlights: recover what would clip.
    if p99 > 0.97 || s.clipped > 0.005 {
        r.highlights = -(0.25 + ((p99 - 0.97).max(0.0) * 4.0) + (s.clipped * 8.0)).min(0.75);
    }
    // --- Shadows: open crushed shadows (not at night).
    if p05 < 0.07 && s.scene != Scene::Night {
        r.shadows = ((0.07 - p05) * 4.0 + 0.1).min(0.45);
    }
    // --- Black and white points: stretch to use the full range.
    r.whites = ((0.96 - p99) * 1.4).clamp(-0.3, 0.45);
    r.blacks = ((0.025 - p01) * 2.5).clamp(-0.35, 0.25);
    // --- Contrast from the spread of the histogram.
    let range = p95 - p05;
    r.contrast = if range < 0.65 { ((0.65 - range) * 0.7).min(0.35) } else if range > 0.9 { -0.1 } else { 0.0 };
    // --- Color density.
    r.vibrance = if s.mean_sat < 0.2 { 0.25 } else if s.mean_sat < 0.3 { 0.12 } else if s.mean_sat > 0.55 { -0.1 } else { 0.05 };
    if s.p50 < 0.35 && s.scene != Scene::Night {
        r.dehaze = 0.05;
    }
    r
}

/// Several graded candidates suited to the scene, each built on the base correction.
/// Returns the base first, then 16+ looks ranging from subtle to strong.
pub fn candidates(img: &Image) -> (Stats, Vec<Recipe>) {
    let s = analyze(img);
    let base = auto_correct(&s);
    let mut out = vec![base.clone()];
    for name in presets::suggestions(s.scene) {
        if let Some(st) = presets::by_name(name) {
            out.push(base.layered(&st));
        }
    }
    (s, out)
}
