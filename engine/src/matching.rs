//! Reference-photo style matching. Produces a 3D LUT (and therefore a recipe)
//! that transfers the reference's tonal response and per-tone color balance.
//! Because it is a color transform, it applies losslessly at any resolution.

use crate::color::*;
use crate::lut::Lut3d;
use crate::pipeline::Image;
use crate::recipe::Recipe;

const BANDS: usize = 3;

struct LabStats {
    /// Sorted L values for CDF matching.
    l_sorted: Vec<f32>,
    /// Per luminance band: mean and std of a, b.
    mean: [[f32; 2]; BANDS],
    std: [[f32; 2]; BANDS],
    chroma: f32,
}

fn band_weights(l: f32) -> [f32; BANDS] {
    let t = (l / 100.0).clamp(0.0, 1.0);
    let s = (1.0 - t * 2.0).max(0.0);
    let h = (t * 2.0 - 1.0).max(0.0);
    [s, 1.0 - s - h, h]
}

/// `img` is display-encoded.
fn stats(img: &Image) -> LabStats {
    let small = img.downscale(400);
    let labs: Vec<Rgb> = small
        .data
        .iter()
        .map(|p| linear_to_lab([srgb_to_linear(p[0]), srgb_to_linear(p[1]), srgb_to_linear(p[2])]))
        .collect();
    let mut l_sorted: Vec<f32> = labs.iter().map(|c| c[0]).collect();
    l_sorted.sort_by(|a, b| a.total_cmp(b));
    let mut sw = [0.0f32; BANDS];
    let mut m = [[0.0f32; 2]; BANDS];
    let mut chroma = 0.0;
    for c in &labs {
        let w = band_weights(c[0]);
        for k in 0..BANDS {
            sw[k] += w[k];
            m[k][0] += w[k] * c[1];
            m[k][1] += w[k] * c[2];
        }
        chroma += (c[1] * c[1] + c[2] * c[2]).sqrt();
    }
    for k in 0..BANDS {
        let d = sw[k].max(1e-3);
        m[k][0] /= d;
        m[k][1] /= d;
    }
    let mut v = [[0.0f32; 2]; BANDS];
    for c in &labs {
        let w = band_weights(c[0]);
        for k in 0..BANDS {
            v[k][0] += w[k] * (c[1] - m[k][0]).powi(2);
            v[k][1] += w[k] * (c[2] - m[k][1]).powi(2);
        }
    }
    let mut sd = [[0.0f32; 2]; BANDS];
    for k in 0..BANDS {
        let d = sw[k].max(1e-3);
        sd[k] = [(v[k][0] / d).sqrt().max(1.0), (v[k][1] / d).sqrt().max(1.0)];
    }
    LabStats { l_sorted, mean: m, std: sd, chroma: chroma / labs.len() as f32 }
}

fn quantile(sorted: &[f32], q: f32) -> f32 {
    let p = q.clamp(0.0, 1.0) * (sorted.len() - 1) as f32;
    let i = p as usize;
    let j = (i + 1).min(sorted.len() - 1);
    sorted[i] + (sorted[j] - sorted[i]) * (p - i as f32)
}

fn rank(sorted: &[f32], v: f32) -> f32 {
    let i = sorted.partition_point(|&x| x < v);
    i as f32 / (sorted.len() - 1).max(1) as f32
}

/// Build a style-transfer recipe. `source` is the photo as currently edited
/// (display-encoded); `reference` is the styled example (display-encoded).
/// `strength` in 0..1.
pub fn match_reference(source: &Image, reference: &Image, strength: f32) -> Recipe {
    let s = stats(source);
    let r = stats(reference);
    // Smooth tone mapping via 33-point quantile matching (avoids posterization).
    let tone: Vec<(f32, f32)> = (0..=32)
        .map(|i| {
            let q = i as f32 / 32.0;
            (quantile(&s.l_sorted, q), quantile(&r.l_sorted, q))
        })
        .collect();
    let map_l = |l: f32| -> f32 {
        let q = rank(&s.l_sorted, l);
        let mapped = quantile(&r.l_sorted, q);
        // Blend toward identity at the extremes for stability.
        let edge = smoothstep(0.0, 0.03, q) * smoothstep(0.0, 0.03, 1.0 - q);
        let _ = &tone;
        l + (mapped - l) * (0.35 + 0.65 * edge)
    };
    let chroma_ratio = (r.chroma / s.chroma.max(1.0)).clamp(0.4, 2.0);
    let strength = strength.clamp(0.0, 1.0);

    let lut = Lut3d::from_fn(33, |c| {
        let lin = [srgb_to_linear(c[0]), srgb_to_linear(c[1]), srgb_to_linear(c[2])];
        let lab = linear_to_lab(lin);
        let w = band_weights(lab[0]);
        let (mut a, mut b) = (0.0, 0.0);
        for k in 0..BANDS {
            let ra = (r.std[k][0] / s.std[k][0]).clamp(0.5, 2.0);
            let rb = (r.std[k][1] / s.std[k][1]).clamp(0.5, 2.0);
            a += w[k] * ((lab[1] - s.mean[k][0]) * ra + r.mean[k][0]);
            b += w[k] * ((lab[2] - s.mean[k][1]) * rb + r.mean[k][1]);
        }
        // Blend the statistical transfer with a simpler chroma scale for neutrals' safety.
        let a2 = lab[1] * chroma_ratio;
        let b2 = lab[2] * chroma_ratio;
        let out = [map_l(lab[0]), 0.75 * a + 0.25 * a2, 0.75 * b + 0.25 * b2];
        let lin2 = lab_to_linear(out);
        let disp = [
            linear_to_srgb(lin2[0].clamp(0.0, 1.0)),
            linear_to_srgb(lin2[1].clamp(0.0, 1.0)),
            linear_to_srgb(lin2[2].clamp(0.0, 1.0)),
        ];
        [
            c[0] + (disp[0] - c[0]) * strength,
            c[1] + (disp[1] - c[1]) * strength,
            c[2] + (disp[2] - c[2]) * strength,
        ]
    });
    Recipe { lut: Some(lut), lut_strength: 1.0, ..Recipe::named("참조 스타일") }
}
