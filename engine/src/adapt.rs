//! Look adaptation: fit a look (template / LUT-like style) to a specific photo so it
//! blends with the image instead of sitting on top of it like a filter.
//!
//! Ideas taken from the photo-enhancement literature, implemented without a neural net:
//! - Normalize first, then stylize (Neural Preset, CVPR 2023): the look is layered on the
//!   photo's physical baseline (exposure / white balance / range), not on the raw file.
//! - Image-adaptive strength (image-adaptive 3D LUTs, Zeng et al. 2020; SepLUT 2022):
//!   the same look is weighted differently per image, from image statistics.
//! - Interpretable, bounded edits that can be inspected and undone (RetouchLLM 2025,
//!   MonetGPT 2025, JarvisArt 2025): every adaptation is a recipe value plus a reason.
//!
//! Two stages:
//! 1. Per-parameter adaptation from statistics: don't add contrast to a contrasty photo,
//!    don't warm an already warm photo, don't lift blacks that are already lifted, etc.
//! 2. Global strength search on a small preview: the largest strength (≥ 45%) that keeps
//!    new clipping, crushed shadows and skin-hue drift within limits.

use serde::Serialize;

use crate::analysis::{Scene, Stats};
use crate::color::*;
use crate::pipeline::{apply, Image};
use crate::recipe::Recipe;

#[derive(Clone, Debug, Serialize)]
pub struct Report {
    /// Overall strength chosen for the look (0..1).
    pub strength: f32,
    /// Mean OKLab color difference the look makes on this photo (×100).
    pub change: f32,
    /// Human-readable reasons (Korean), shown in the UI.
    pub notes: Vec<String>,
}

/// Scale a style toward "no change": scalars, HSL, wheels, curves, LUT and mixer.
pub fn scale_style(style: &Recipe, s: f32) -> Recipe {
    let mut r = style.clone();
    macro_rules! mul { ($($f:ident),*) => { $( r.$f = style.$f * s; )* } }
    mul!(exposure, contrast, highlights, shadows, whites, blacks, temperature, tint,
         vibrance, saturation, clarity, dehaze, sharpen, vignette, grain, fade,
         texture, noise_reduction, color_noise_reduction, grade_balance, halation, bloom,
         cal_red_hue, cal_red_sat, cal_green_hue, cal_green_sat, cal_blue_hue, cal_blue_sat);
    for b in r.hsl.iter_mut() {
        b.hue *= s;
        b.sat *= s;
        b.lum *= s;
    }
    r.grade_shadows.sat *= s;
    r.grade_midtones.sat *= s;
    r.grade_highlights.sat *= s;
    for c in [&mut r.curve, &mut r.curve_r, &mut r.curve_g, &mut r.curve_b] {
        for p in c.iter_mut() {
            p.1 = p.0 + (p.1 - p.0) * s;
        }
    }
    if r.lut.is_some() {
        r.lut_strength = style.lut_strength * s;
    }
    if let (Some(m), false) = (style.channel_mixer, style.monochrome) {
        let mut o = m;
        for i in 0..3 {
            for j in 0..3 {
                let id = if i == j { 1.0 } else { 0.0 };
                o[i][j] = id + (m[i][j] - id) * s;
            }
        }
        r.channel_mixer = Some(o);
    }
    r
}

/// Direction of a grading wheel in OKLab a/b (unit vector).
fn wheel_dir(hue: f32) -> (f32, f32) {
    let a = hsl_hue_to_oklab_hue(hue).to_radians();
    (a.cos(), a.sin())
}

/// Stage 1: adapt individual parameters of the style to the photo.
fn adapt_params(look: &Recipe, base: &Recipe, st: &Stats, notes: &mut Vec<String>) -> Recipe {
    let mut r = look.clone();
    let range = st.p95 - st.p05;

    // Contrast: an already punchy photo needs less, a flat one can take the full look.
    if r.contrast > 0.0 && range > 0.7 {
        let k = if range > 0.82 { 0.45 } else { 0.7 };
        r.contrast *= k;
        notes.push(format!("원래 대비가 강해서 대비를 {}%만 더했어요", (k * 100.0) as i32));
    } else if r.contrast < 0.0 && range < 0.45 {
        r.contrast *= 0.5;
        notes.push("원래 밋밋한 사진이라 대비를 덜 낮췄어요".into());
    }

    // Exposure: don't darken a dark photo or brighten a bright one much further.
    if r.exposure < 0.0 && st.p50 < 0.3 {
        r.exposure *= 0.35;
        notes.push("어두운 사진이라 어둡게 하는 정도를 줄였어요".into());
    } else if r.exposure > 0.0 && st.p50 > 0.62 {
        r.exposure *= 0.35;
        notes.push("밝은 사진이라 밝게 하는 정도를 줄였어요".into());
    }

    // Saturation: avoid neon on colorful photos and grey mush on muted ones.
    let boost = r.saturation + r.vibrance * 0.6;
    if boost > 0.0 && st.mean_sat > 0.35 {
        let k = if st.mean_sat > 0.5 { 0.4 } else { 0.65 };
        r.saturation = if r.saturation > 0.0 { r.saturation * k } else { r.saturation };
        r.vibrance = if r.vibrance > 0.0 { r.vibrance * k } else { r.vibrance };
        notes.push("이미 색이 진해서 채도를 덜 올렸어요".into());
    } else if r.saturation < 0.0 && !r.monochrome && st.mean_sat < 0.18 {
        r.saturation *= 0.55;
        notes.push("원래 색이 옅어서 채도를 덜 뺐어요".into());
    }

    // White balance: a look's warmth/coolness is reduced when the light that is left after
    // the baseline still leans that way (estimated from neutral surfaces, not object colors).
    let cast = (st.cast_a, st.cast_b);
    let [nr, _, nb] = st.neutral_rgb;
    let warm_left = if nr > 0.0 && nb > 0.0 && st.wb_confidence >= 0.4 {
        (nr / nb).log2() / 0.9 + base.temperature
    } else {
        0.0
    };
    if r.temperature > 0.0 && warm_left > 0.08 {
        let k = (1.0 - (warm_left - 0.08) / 0.3).clamp(0.3, 1.0);
        r.temperature *= k;
        notes.push("빛이 이미 따뜻해서 웜톤을 줄였어요".into());
    } else if r.temperature < 0.0 && warm_left < -0.08 {
        let k = (1.0 - (-warm_left - 0.08) / 0.3).clamp(0.3, 1.0);
        r.temperature *= k;
        notes.push("빛이 이미 푸르러서 쿨톤을 줄였어요".into());
    }

    // Grading wheels: tint less in the direction the photo is already cast.
    let cm = (cast.0 * cast.0 + cast.1 * cast.1).sqrt();
    if cm > 0.01 {
        let (cx, cy) = (cast.0 / cm, cast.1 / cm);
        let mut reduced = false;
        for w in [&mut r.grade_shadows, &mut r.grade_midtones, &mut r.grade_highlights] {
            if w.sat > 0.0 {
                let (dx, dy) = wheel_dir(w.hue);
                let same = dx * cx + dy * cy;
                if same > 0.5 {
                    let k = (1.0 - same * (cm / 0.05).min(1.0) * 0.5).clamp(0.5, 1.0);
                    if k < 0.95 {
                        w.sat *= k;
                        reduced = true;
                    }
                }
            }
        }
        if reduced {
            notes.push("사진에 이미 있는 색감과 겹치는 색 입히기를 줄였어요".into());
        }
    }

    // Blacks: skip most of the matte fade if shadows are already lifted.
    if r.fade > 0.0 && st.p01 > 0.08 {
        r.fade *= 0.45;
        notes.push("어두운 곳이 이미 들떠 있어서 빛바램을 줄였어요".into());
    }
    if r.shadows > 0.0 && st.p05 > 0.18 {
        r.shadows *= 0.5;
    }
    if r.highlights < 0.0 && st.p99 < 0.8 {
        r.highlights *= 0.5;
    }

    // Grain on a busy night shot reads as noise.
    if st.scene == Scene::Night && r.grain > 0.2 {
        r.grain *= 0.6;
    }

    // People: protect skin more.
    if st.skin_fraction > 0.04 && !r.monochrome {
        r.skin_protect = r.skin_protect.max(0.7);
    }
    r
}

#[derive(Default)]
struct Metrics {
    change: f32,
    clip: f32,
    crush: f32,
    skin_shift: f32,
}

fn measure(base: &Image, out: &Image) -> Metrics {
    let n = base.data.len().max(1) as f32;
    let (mut change, mut clip, mut crush) = (0.0f32, 0.0f32, 0.0f32);
    let (mut skin_n, mut skin_shift) = (0.0f32, 0.0f32);
    for (b, o) in base.data.iter().zip(&out.data) {
        let lb = linear_to_oklab(b.map(|v| srgb_to_linear(v.clamp(0.0, 1.0))));
        let lo = linear_to_oklab(o.map(|v| srgb_to_linear(v.clamp(0.0, 1.0))));
        change += ((lb[0] - lo[0]).powi(2) + (lb[1] - lo[1]).powi(2) + (lb[2] - lo[2]).powi(2)).sqrt();
        let bc = b.iter().any(|&v| v > 0.995);
        let oc = o.iter().any(|&v| v > 0.995);
        if oc && !bc { clip += 1.0; }
        let bk = luma(*b) < 0.015;
        let ok = luma(*o) < 0.015;
        if ok && !bk { crush += 1.0; }
        if skin_weight(lb) > 0.6 {
            let hb = lb[2].atan2(lb[1]);
            let ho = lo[2].atan2(lo[1]);
            let mut d = (ho - hb).to_degrees().abs();
            if d > 180.0 { d = 360.0 - d; }
            skin_shift += d;
            skin_n += 1.0;
        }
    }
    Metrics {
        change: change / n * 100.0,
        clip: clip / n,
        crush: crush / n,
        skin_shift: if skin_n > n * 0.02 { skin_shift / skin_n } else { 0.0 },
    }
}

/// Fit `look` to the photo: returns the full recipe (base + adapted look) and a report.
pub fn adapt(look: &Recipe, base: &Recipe, st: &Stats, preview: &Image) -> (Recipe, Report) {
    let mut notes = Vec::new();
    let style = adapt_params(look, base, st, &mut notes);
    let small = preview.downscale(256);
    let base_img = apply(base, &small);
    let special = look.monochrome || look.category == "특수" || look.category == "흑백";

    let mut chosen = 0.45f32;
    let mut m_chosen = Metrics::default();
    let mut limit_reason: Option<&str> = None;
    for s in [1.0f32, 0.9, 0.8, 0.7, 0.6, 0.5, 0.45] {
        let r = base.layered(&scale_style(&style, s));
        let m = measure(&base_img, &apply(&r, &small));
        let reason = if m.clip > 0.015 {
            Some("밝은 곳이 하얗게 날아가지 않게")
        } else if m.crush > if look.category == "깊이감" || look.monochrome { 0.08 } else { 0.03 } {
            Some("어두운 곳이 뭉개지지 않게")
        } else if !special && m.skin_shift > 9.0 {
            Some("피부색이 틀어지지 않게")
        } else {
            None
        };
        chosen = s;
        m_chosen = m;
        if reason.is_none() {
            break;
        }
        limit_reason = reason;
    }
    if chosen < 1.0 {
        if let Some(why) = limit_reason {
            notes.push(format!("{why} 전체 세기를 {}%로 맞췄어요", (chosen * 100.0).round() as i32));
        }
    }

    let mut out = base.layered(&scale_style(&style, chosen));
    out.name = look.name.clone();
    out.category = look.category.clone();
    out.description = look.description.clone();
    (out, Report { strength: chosen, change: m_chosen.change, notes })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::analysis::{analyze, auto_correct};
    use crate::presets;

    fn test_image(warm: bool) -> Image {
        let (w, h) = (96, 64);
        let mut img = Image::new(w, h);
        for y in 0..h {
            for x in 0..w {
                let t = x as f32 / w as f32;
                let v = y as f32 / h as f32;
                let mut c = [0.1 + 0.8 * t, 0.15 + 0.6 * v, 0.2 + 0.5 * (1.0 - t)];
                if warm {
                    c = [c[0] * 1.3, c[1], c[2] * 0.6];
                }
                img.data[y * w + x] = c.map(|v| srgb_to_linear(v.clamp(0.0, 1.0)));
            }
        }
        img
    }

    #[test]
    fn warm_photo_gets_less_warmth() {
        let img = test_image(true);
        let st = analyze(&img);
        let base = auto_correct(&st);
        let look = presets::golden_hour();
        let (r, rep) = adapt(&look, &base, &st, &img);
        assert!(rep.strength >= 0.45 && rep.strength <= 1.0);
        assert!(r.temperature - base.temperature <= look.temperature + 1e-6);
    }

    #[test]
    fn scale_zero_is_identity_style() {
        let s = scale_style(&presets::portra(), 0.0);
        assert_eq!(s.contrast, 0.0);
        assert!(s.curve.iter().all(|p| (p.0 - p.1).abs() < 1e-6));
    }
}
