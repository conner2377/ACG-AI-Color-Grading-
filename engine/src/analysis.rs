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
    pub mean_sat: f32,
    pub clipped: f32,
    /// Average linear RGB of near-neutral pixels (white-balance estimate).
    pub neutral_rgb: Rgb,
    pub skin_fraction: f32,
    pub green_fraction: f32,
    pub blue_fraction: f32,
    pub warm_fraction: f32,
    pub scene: Scene,
}

pub fn analyze(img: &Image) -> Stats {
    let small = img.downscale(512);
    let n = small.data.len() as f32;
    let mut lum: Vec<f32> = Vec::with_capacity(small.data.len());
    let (mut sat_sum, mut clipped) = (0.0f32, 0.0f32);
    let (mut neutral, mut neutral_n) = ([0.0f32; 3], 0.0f32);
    let (mut skin, mut green, mut blue, mut warm) = (0.0f32, 0.0f32, 0.0f32, 0.0f32);
    for &p in &small.data {
        let d = [linear_to_srgb(p[0].clamp(0.0, 1.0)), linear_to_srgb(p[1].clamp(0.0, 1.0)), linear_to_srgb(p[2].clamp(0.0, 1.0))];
        let l = luma(d);
        lum.push(l);
        if d.iter().any(|&v| v > 0.995) {
            clipped += 1.0;
        }
        let hsl = rgb_to_hsl(d);
        sat_sum += hsl[1];
        if hsl[1] < 0.25 && l > 0.15 && l < 0.92 {
            for k in 0..3 { neutral[k] += p[k]; }
            neutral_n += 1.0;
        }
        if hsl[1] > 0.15 && l > 0.1 {
            let hue = hsl[0];
            if (8.0..=40.0).contains(&hue) && hsl[1] < 0.7 && l > 0.25 { skin += 1.0; }
            if (70.0..=165.0).contains(&hue) { green += 1.0; }
            if (185.0..=250.0).contains(&hue) { blue += 1.0; }
            if (hue < 50.0 || hue > 340.0) && hsl[1] > 0.35 { warm += 1.0; }
        }
    }
    lum.sort_by(|a, b| a.total_cmp(b));
    let pct = |q: f32| lum[((lum.len() - 1) as f32 * q) as usize];
    let neutral_rgb = if neutral_n > n * 0.02 {
        [neutral[0] / neutral_n, neutral[1] / neutral_n, neutral[2] / neutral_n]
    } else {
        [1.0, 1.0, 1.0]
    };
    let mut s = Stats {
        p01: pct(0.01),
        p05: pct(0.05),
        p50: pct(0.5),
        p95: pct(0.95),
        p99: pct(0.99),
        mean_sat: sat_sum / n,
        clipped: clipped / n,
        neutral_rgb,
        skin_fraction: skin / n,
        green_fraction: green / n,
        blue_fraction: blue / n,
        warm_fraction: warm / n,
        scene: Scene::General,
    };
    s.scene = if s.p50 < 0.18 && s.p95 < 0.7 {
        Scene::Night
    } else if s.skin_fraction > 0.12 {
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

/// A precise, neutral base correction: exposure, white balance and tonal range.
pub fn auto_correct(s: &Stats) -> Recipe {
    let mut r = Recipe::named("자동 보정");

    // Exposure: bring the median toward a pleasant mid-grey (keep night shots dark).
    let target = if s.scene == Scene::Night { 0.28 } else { 0.46 };
    let ev = (srgb_to_linear(target) / srgb_to_linear(s.p50.max(0.02))).log2();
    r.exposure = (ev * 0.7).clamp(-1.5, 1.5);

    // White balance from near-neutral pixels, partially corrected to keep mood.
    let [nr, ng, nb] = s.neutral_rgb;
    if nr > 0.0 && nb > 0.0 && ng > 0.0 {
        let keep = if s.scene == Scene::Sunset { 0.3 } else { 0.6 };
        r.temperature = (-(nr / nb).log2() / 0.7 * keep).clamp(-0.6, 0.6);
        r.tint = (((nr * nb).sqrt() / ng).log2() / 0.5 * keep).clamp(-0.4, 0.4);
    }

    // Tonal range.
    if s.clipped > 0.01 || s.p99 > 0.98 {
        r.highlights = -(0.3 + (s.clipped * 10.0).min(0.4));
    }
    if s.p05 < 0.06 && s.scene != Scene::Night {
        r.shadows = 0.25;
    }
    r.whites = ((0.97 - s.p99) * 1.5).clamp(-0.3, 0.4);
    r.blacks = ((0.02 - s.p01) * 2.0).clamp(-0.3, 0.2);
    let range = s.p95 - s.p05;
    if range < 0.6 {
        r.contrast = ((0.6 - range) * 0.6).min(0.3);
    }
    if s.mean_sat < 0.25 {
        r.vibrance = 0.15;
    }
    r
}

/// Several graded candidates suited to the scene, each built on the base correction.
pub fn candidates(img: &Image) -> (Stats, Vec<Recipe>) {
    let s = analyze(img);
    let base = auto_correct(&s);
    let styles: Vec<Recipe> = match s.scene {
        Scene::Portrait => vec![presets::natural(), presets::soft_portrait(), presets::film(), presets::warm(), presets::matte_pastel(), presets::bw_classic()],
        Scene::Landscape => vec![presets::natural(), presets::landscape(), presets::vivid(), presets::cinematic(), presets::cool_moody(), presets::infrared()],
        Scene::Night => vec![presets::natural(), presets::night_city(), presets::cinematic(), presets::cool_moody(), presets::bw_contrast()],
        Scene::Sunset => vec![presets::natural(), presets::warm(), presets::vivid(), presets::cinematic(), presets::film()],
        Scene::General => vec![presets::natural(), presets::vivid(), presets::film(), presets::cinematic(), presets::cool_moody(), presets::bw_classic()],
    };
    let mut out = vec![base.clone()];
    out.extend(styles.iter().map(|st| base.layered(st)));
    (s, out)
}
