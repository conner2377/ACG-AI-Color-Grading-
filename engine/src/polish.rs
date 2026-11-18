//! Finishing check for AI (and other automatic) edits.
//!
//! A language model looks at a small JPEG and guesses slider values; it can't see that
//! its edit clips the sky, crushes a black jacket into a flat blob, turns faces orange or
//! pushes colors into a flat patch at the edge of the gamut. Like a retoucher's last look
//! at the histogram, this renders the edit, measures those failures against the original
//! photo, and nudges the values back until they pass. It only changes recipe values.

use serde::Serialize;

use crate::analysis::Stats;
use crate::color::*;
use crate::pipeline::{apply, Image};
use crate::recipe::Recipe;

#[derive(Clone, Debug, Default, Serialize)]
pub struct Measure {
    /// Fraction of pixels with a channel at white.
    pub clipped: f32,
    /// Fraction of pixels at black.
    pub crushed: f32,
    /// Fraction of colorful pixels pushed to full saturation.
    pub oversat: f32,
    /// Mean OKLab (L, chroma, hue°) of skin pixels, if the photo has skin.
    pub skin: Option<[f32; 3]>,
    pub p50: f32,
}

fn skin_mask(src: &Image) -> Vec<bool> {
    src.data
        .iter()
        .map(|p| skin_weight(linear_to_oklab(p.map(|v| v.clamp(0.0, 1.0)))) > 0.5)
        .collect()
}

/// Measure a display-encoded render. `skin` marks skin pixels of the original.
pub fn measure(out: &Image, skin: &[bool]) -> Measure {
    let n = out.data.len().max(1) as f32;
    let (mut clipped, mut crushed, mut oversat) = (0.0f32, 0.0f32, 0.0f32);
    let (mut sl, mut sa, mut sb, mut sn) = (0.0f32, 0.0f32, 0.0f32, 0.0f32);
    let mut lum: Vec<f32> = Vec::with_capacity(out.data.len());
    for (i, p) in out.data.iter().enumerate() {
        let l = luma(*p);
        lum.push(l);
        if p.iter().any(|&v| v >= 0.995) {
            clipped += 1.0;
        }
        if l < 0.012 {
            crushed += 1.0;
        }
        let mx = p[0].max(p[1]).max(p[2]);
        let mn = p[0].min(p[1]).min(p[2]);
        if mx > 0.15 && mx < 0.995 && mn < 0.004 && mx - mn > 0.3 {
            oversat += 1.0;
        }
        if skin.get(i).copied().unwrap_or(false) {
            let lab = linear_to_oklab(p.map(srgb_to_linear));
            sl += lab[0];
            sa += lab[1];
            sb += lab[2];
            sn += 1.0;
        }
    }
    lum.sort_by(|a, b| a.total_cmp(b));
    let skin = if sn / n > 0.01 {
        let (a, b) = (sa / sn, sb / sn);
        Some([sl / sn, (a * a + b * b).sqrt(), b.atan2(a).to_degrees().rem_euclid(360.0)])
    } else {
        None
    };
    Measure { clipped: clipped / n, crushed: crushed / n, oversat: oversat / n, skin, p50: lum[lum.len() / 2] }
}

/// Correct the failures of `r` on this photo. Returns the corrected recipe and short
/// Korean notes describing what was fixed (empty when the edit was already clean).
/// `base` is the physical baseline the edit was built on; limits are measured relative
/// to it (or to the untouched photo when there is none).
pub fn polish(r: &Recipe, base: Option<&Recipe>, img: &Image, s: &Stats) -> (Recipe, Vec<String>) {
    let small = img.downscale(420);
    // Skin rules only for photos of people: wood, coffee or lamps share skin colors.
    let people = s.scene == crate::analysis::Scene::Portrait;
    let skin = if people { skin_mask(&small) } else { Vec::new() };
    // Measure without geometry so pixels line up with the skin mask.
    let geo_free = |x: &Recipe| Recipe { angle: 0.0, rotate90: 0, flip_h: false, flip_v: false, crop: None, lut: x.lut.clone(), ..x.clone() };
    let photo = measure(&crate::io::linear_to_display(&small), &skin);
    let orig = match base {
        Some(b) => {
            let mut m = measure(&apply(&geo_free(b), &small), &skin);
            m.clipped = m.clipped.max(photo.clipped);
            m.crushed = m.crushed.max(photo.crushed);
            m.oversat = m.oversat.max(photo.oversat);
            m
        }
        None => photo,
    };
    let mut cur = r.clone();
    let mut notes: Vec<&str> = Vec::new();
    let note = |s: &'static str, notes: &mut Vec<&str>| {
        if !notes.contains(&s) {
            notes.push(s);
        }
    };
    let clip_ok = (orig.clipped.max(s.clipped) * 1.3 + 0.002).max(0.004);
    let crush_ok = (orig.crushed.max(s.crushed) * 1.5 + 0.01).max(0.02);
    let sat_ok = orig.oversat * 1.5 + 0.03;
    for _ in 0..8 {
        let m = measure(&apply(&geo_free(&cur), &small), &skin);
        let mut changed = false;
        if m.clipped > clip_ok {
            // Pull the white point first, then highlights; exposure only as a last resort
            // so the subject keeps the brightness the edit gave it.
            if cur.whites > 0.0 {
                cur.whites = (cur.whites - 0.2).max(0.0);
            } else if cur.highlights > -0.7 {
                cur.highlights = (cur.highlights - 0.15).max(-0.7);
                cur.whites = (cur.whites - 0.06).max(-0.4);
            } else if cur.exposure > -1.0 {
                cur.exposure -= 0.1;
            }
            note("밝은 곳이 하얗게 날아가지 않게 했어요", &mut notes);
            changed = true;
        }
        if m.crushed > crush_ok && !cur.monochrome {
            cur.blacks = (cur.blacks + 0.08).min(0.5);
            cur.shadows = (cur.shadows + 0.06).min(1.0);
            note("어두운 곳이 까맣게 뭉개지지 않게 했어요", &mut notes);
            changed = true;
        }
        if m.oversat > sat_ok && !cur.monochrome {
            cur.saturation -= 0.07;
            cur.vibrance -= 0.04;
            note("색이 떡지지 않게 채도를 정리했어요", &mut notes);
            changed = true;
        }
        if let (Some([l, c, hue]), false) = (m.skin, cur.monochrome) {
            let orig_skin = orig.skin.unwrap_or([l, c, hue]);
            // Natural skin: hue between red-orange and yellow, moderate chroma.
            let hue_bad = !(30.0..=80.0).contains(&hue) && (hue - orig_skin[2]).abs() > 6.0;
            let chroma_bad = c > (orig_skin[1] * 1.35).max(0.13);
            if (hue_bad || chroma_bad) && cur.skin_protect < 0.95 {
                cur.skin_protect = (cur.skin_protect + 0.2).min(0.95);
                note("피부색이 자연스럽게 남도록 했어요", &mut notes);
                changed = true;
            } else if chroma_bad && cur.vibrance > -0.3 {
                cur.vibrance -= 0.08;
                changed = true;
            }
            // A face that went much darker than the photo had it.
            if l < (orig_skin[0] - 0.12).min(0.5) && cur.shadows < 0.8 {
                cur.shadows += 0.1;
                cur.exposure += 0.05;
                note("얼굴이 어두워지지 않게 했어요", &mut notes);
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    (cur, notes.into_iter().map(String::from).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pulls_back_clipping() {
        let mut img = Image::new(64, 64);
        for (i, p) in img.data.iter_mut().enumerate() {
            let v = (i % 64) as f32 / 64.0 * 0.8;
            *p = [v, v * 0.9, v * 0.8];
        }
        let s = crate::analysis::analyze(&img);
        let r = Recipe { exposure: 1.5, whites: 0.4, ..Default::default() };
        let before = measure(&apply(&r, &img), &[]).clipped;
        let (fixed, notes) = polish(&r, None, &img, &s);
        let after = measure(&apply(&fixed, &img), &[]).clipped;
        assert!(after < before, "{before} -> {after}");
        assert!(!notes.is_empty());
    }

    #[test]
    fn clean_edit_is_untouched() {
        let mut img = Image::new(64, 64);
        for (i, p) in img.data.iter_mut().enumerate() {
            let v = 0.05 + (i % 64) as f32 / 64.0 * 0.5;
            *p = [v, v, v * 0.95];
        }
        let s = crate::analysis::analyze(&img);
        let r = Recipe { exposure: 0.2, ..Default::default() };
        let (fixed, notes) = polish(&r, None, &img, &s);
        assert!(notes.is_empty(), "{notes:?}");
        assert_eq!(fixed, r);
    }
}
