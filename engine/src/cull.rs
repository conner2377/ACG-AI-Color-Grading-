//! Photo organizer ("culling"): measure each photo (capture time, a small perceptual
//! hash, subject/background sharpness, motion direction, clipping), group bursts of the
//! same scene, and inside each burst recommend the best-taken frame.
//!
//! Intentional differences are kept: a frame whose subject is sharp while the background
//! streaks (panning), or where the subject moved / the composition changed, is marked as a
//! variation to keep, not as a worse duplicate. Nothing is ever deleted here.

use std::path::Path;
use std::time::UNIX_EPOCH;

use anyhow::{Context, Result};
use image::{imageops::FilterType, DynamicImage, GrayImage, ImageDecoder, ImageReader};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Metrics {
    pub path: String,
    /// Seconds (EXIF capture time when available, otherwise file modified time).
    pub time: f64,
    pub has_exif_time: bool,
    pub width: u32,
    pub height: u32,
    /// 64-bit difference hash of the composition (as hex).
    pub hash: String,
    /// Mean sRGB color (0..1), for telling scenes apart.
    pub color: [f32; 3],
    /// Sharpness of the sharpest regions (the subject, usually).
    pub subject_sharp: f32,
    /// Median sharpness over the frame (background, usually).
    pub global_sharp: f32,
    /// 0..1: how much all gradients point one way (motion blur / camera shake / panning).
    pub motion: f32,
    pub clip_high: f32,
    pub clip_low: f32,
    /// JPEG preview written for formats the UI can't decode itself (TIFF), else empty.
    pub preview: String,
}

fn exif_time(path: &Path) -> Option<f64> {
    let file = std::fs::File::open(path).ok()?;
    let mut r = std::io::BufReader::new(file);
    let ex = exif::Reader::new().read_from_container(&mut r).ok()?;
    let f = ex
        .get_field(exif::Tag::DateTimeOriginal, exif::In::PRIMARY)
        .or_else(|| ex.get_field(exif::Tag::DateTime, exif::In::PRIMARY))?;
    let s = match &f.value {
        exif::Value::Ascii(v) => String::from_utf8_lossy(v.first()?).into_owned(),
        _ => return None,
    };
    // "YYYY:MM:DD HH:MM:SS"
    let n: Vec<i64> = s.split(|c: char| !c.is_ascii_digit()).filter(|p| !p.is_empty()).filter_map(|p| p.parse().ok()).collect();
    if n.len() < 6 {
        return None;
    }
    let days = days_from_civil(n[0], n[1], n[2]);
    let mut t = (days * 86400 + n[3] * 3600 + n[4] * 60 + n[5]) as f64;
    if let Some(sub) = ex.get_field(exif::Tag::SubSecTimeOriginal, exif::In::PRIMARY) {
        if let exif::Value::Ascii(v) = &sub.value {
            if let Some(d) = v.first() {
                let txt = String::from_utf8_lossy(d);
                let txt = txt.trim();
                if let Ok(x) = txt.parse::<f64>() {
                    t += x / 10f64.powi(txt.len() as i32);
                }
            }
        }
    }
    Some(t)
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

fn dhash(gray: &GrayImage) -> u64 {
    let small = image::imageops::resize(gray, 9, 8, FilterType::Triangle);
    let mut h = 0u64;
    for y in 0..8 {
        for x in 0..8 {
            let a = small.get_pixel(x, y)[0];
            let b = small.get_pixel(x + 1, y)[0];
            h = (h << 1) | (a > b) as u64;
        }
    }
    h
}

/// Laplacian variance per tile + structure-tensor coherence of the gradients.
fn sharpness(gray: &GrayImage) -> (f32, f32, f32) {
    let (w, h) = (gray.width() as usize, gray.height() as usize);
    let px = |x: usize, y: usize| gray.as_raw()[y * w + x] as f32 / 255.0;
    const T: usize = 8;
    let mut sum = vec![0f64; T * T];
    let mut sum2 = vec![0f64; T * T];
    let mut cnt = vec![0f64; T * T];
    let mut jxx = vec![0f64; T * T];
    let mut jyy = vec![0f64; T * T];
    let mut jxy = vec![0f64; T * T];
    for y in 1..h.saturating_sub(1) {
        let ty = (y * T / h).min(T - 1);
        for x in 1..w.saturating_sub(1) {
            let c = px(x, y);
            let lap = px(x - 1, y) + px(x + 1, y) + px(x, y - 1) + px(x, y + 1) - 4.0 * c;
            let tx = (x * T / w).min(T - 1);
            let i = ty * T + tx;
            sum[i] += lap as f64;
            sum2[i] += (lap * lap) as f64;
            cnt[i] += 1.0;
            let gx = (px(x + 1, y) - px(x - 1, y)) as f64;
            let gy = (px(x, y + 1) - px(x, y - 1)) as f64;
            jxx[i] += gx * gx;
            jyy[i] += gy * gy;
            jxy[i] += gx * gy;
        }
    }
    let mut tiles: Vec<f32> = (0..T * T)
        .filter(|&i| cnt[i] > 0.0)
        .map(|i| {
            let m = sum[i] / cnt[i];
            ((sum2[i] / cnt[i] - m * m).max(0.0).sqrt() * 100.0) as f32
        })
        .collect();
    tiles.sort_by(|a, b| b.total_cmp(a));
    let subject = tiles.iter().take(4).sum::<f32>() / tiles.len().min(4).max(1) as f32;
    let global = tiles.get(tiles.len() / 2).copied().unwrap_or(0.0);
    // Median per-tile coherence: high when most of the frame streaks one way
    // (camera shake, or the background of a panning shot).
    let mut coh: Vec<f32> = (0..T * T)
        .filter(|&i| jxx[i] + jyy[i] > 1e-6 * cnt[i].max(1.0))
        .map(|i| {
            let tr = jxx[i] + jyy[i];
            (((jxx[i] - jyy[i]).powi(2) + 4.0 * jxy[i] * jxy[i]).sqrt() / tr) as f32
        })
        .collect();
    coh.sort_by(|a, b| a.total_cmp(b));
    let coherence = coh.get(coh.len() / 2).copied().unwrap_or(0.0);
    (subject, global, coherence)
}

/// Measure one photo. `cache_dir` receives JPEG previews for TIFFs.
pub fn measure(path: &str, cache_dir: Option<&str>) -> Result<Metrics> {
    let p = Path::new(path);
    let mut decoder = ImageReader::open(p).with_context(|| format!("open {path}"))?.with_guessed_format()?.into_decoder()?;
    let orientation = decoder.orientation()?;
    let mut img = DynamicImage::from_decoder(decoder)?;
    img.apply_orientation(orientation);
    let (width, height) = (img.width(), img.height());
    let small = img.resize(1024, 1024, FilterType::Triangle);
    let rgb = small.to_rgb8();
    let gray = small.to_luma8();
    let n = (rgb.width() * rgb.height()).max(1) as f32;
    let mut color = [0f32; 3];
    let (mut hi, mut lo) = (0f32, 0f32);
    for (c, g) in rgb.pixels().zip(gray.pixels()) {
        for k in 0..3 {
            color[k] += c[k] as f32 / 255.0;
        }
        if g[0] >= 250 {
            hi += 1.0;
        }
        if g[0] <= 5 {
            lo += 1.0;
        }
    }
    for c in &mut color {
        *c /= n;
    }
    let (subject_sharp, global_sharp, motion) = sharpness(&gray);
    let exif = exif_time(p);
    let time = exif.unwrap_or_else(|| {
        std::fs::metadata(p)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0)
    });
    let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    let mut preview = String::new();
    if let (Some(dir), true) = (cache_dir, ext == "tif" || ext == "tiff") {
        let name = format!("{:016x}.jpg", fxhash(path));
        let out = Path::new(dir).join(name);
        if !out.exists() {
            img.resize(1600, 1600, FilterType::Triangle).to_rgb8().save(&out)?;
        }
        preview = out.to_string_lossy().into_owned();
    }
    Ok(Metrics {
        path: path.to_string(),
        time,
        has_exif_time: exif.is_some(),
        width,
        height,
        hash: format!("{:016x}", dhash(&gray)),
        color,
        subject_sharp,
        global_sharp,
        motion,
        clip_high: hi / n,
        clip_low: lo / n,
        preview,
    })
}

fn fxhash(s: &str) -> u64 {
    s.bytes().fold(0xcbf29ce484222325u64, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3))
}

/// Measure many photos in parallel; failures are skipped (reported in `errors`).
pub fn measure_all(paths: &[String], cache_dir: Option<&str>) -> (Vec<Metrics>, Vec<String>) {
    let res: Vec<_> = paths.par_iter().map(|p| (p, measure(p, cache_dir))).collect();
    let mut ok = vec![];
    let mut errors = vec![];
    for (p, r) in res {
        match r {
            Ok(m) => ok.push(m),
            Err(e) => errors.push(format!("{p}: {e:#}")),
        }
    }
    (ok, errors)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    /// The only photo of its scene.
    Single,
    /// Recommended frame of a burst.
    Best,
    /// Different moment / composition / panning: worth keeping.
    Variation,
    /// Same as the best one and about as good: one is enough.
    Duplicate,
    /// Blurrier or shakier than the best frame.
    Weaker,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pick {
    pub path: String,
    pub verdict: Verdict,
    /// Short Korean reason for the UI.
    pub note: String,
    /// Selected by default.
    pub keep: bool,
    /// 0..1 quality relative to the burst's best frame.
    pub score: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Group {
    pub items: Vec<Pick>,
}

fn hamming(a: &str, b: &str) -> u32 {
    let a = u64::from_str_radix(a, 16).unwrap_or(0);
    let b = u64::from_str_radix(b, 16).unwrap_or(0);
    (a ^ b).count_ones()
}

fn color_diff(a: &Metrics, b: &Metrics) -> f32 {
    (0..3).map(|k| (a.color[k] - b.color[k]).abs()).sum()
}

fn same_scene(a: &Metrics, b: &Metrics) -> bool {
    let dt = (a.time - b.time).abs();
    let both_exif = a.has_exif_time && b.has_exif_time;
    if both_exif && dt > 3.0 {
        return false;
    }
    // Shot within a couple of seconds: allow the subject to move or the framing to drift.
    let limit = if dt <= 2.0 { 26 } else { 16 };
    hamming(&a.hash, &b.hash) <= limit && color_diff(a, b) < 0.15
}

fn exposure_penalty(m: &Metrics) -> f32 {
    (if m.clip_high > 0.04 { 0.15 } else { 0.0 }) + (if m.clip_low > 0.25 { 0.1 } else { 0.0 })
}

/// Group photos into bursts and pick within each burst.
pub fn group(mut ms: Vec<Metrics>) -> Vec<Group> {
    ms.sort_by(|a, b| {
        if a.has_exif_time && b.has_exif_time {
            a.time.total_cmp(&b.time).then(a.path.cmp(&b.path))
        } else {
            a.path.cmp(&b.path)
        }
    });
    let mut bursts: Vec<Vec<Metrics>> = vec![];
    for m in ms {
        match bursts.last_mut() {
            Some(g) if g.iter().rev().take(4).any(|x| same_scene(x, &m)) => g.push(m),
            _ => bursts.push(vec![m]),
        }
    }
    bursts.into_iter().map(pick).collect()
}

fn pick(g: Vec<Metrics>) -> Group {
    if g.len() == 1 {
        let m = &g[0];
        return Group { items: vec![Pick { path: m.path.clone(), verdict: Verdict::Single, note: String::new(), keep: true, score: 1.0 }] };
    }
    let max_sharp = g.iter().map(|m| m.subject_sharp).fold(1e-6f32, f32::max);
    let quality = |m: &Metrics| m.subject_sharp / max_sharp - exposure_penalty(m);
    let best = (0..g.len()).max_by(|&a, &b| quality(&g[a]).total_cmp(&quality(&g[b]))).unwrap();
    let b = &g[best];
    let items = g
        .iter()
        .enumerate()
        .map(|(i, m)| {
            let score = (m.subject_sharp / b.subject_sharp.max(1e-6)).min(1.0);
            let (verdict, note) = if i == best {
                (Verdict::Best, "가장 선명한 컷".to_string())
            } else {
                let moved = hamming(&m.hash, &b.hash) >= 10;
                // Sharp subject over a streaking background: panning or deliberate motion.
                let panning = score >= 0.6 && m.motion > 0.35 && m.global_sharp < 0.6 * b.global_sharp.max(1e-6);
                if panning {
                    (Verdict::Variation, "패닝·움직임 표현 컷".into())
                } else if score >= 0.8 {
                    if moved {
                        (Verdict::Variation, "피사체나 구도가 다른 컷".into())
                    } else {
                        (Verdict::Duplicate, "추천 컷과 거의 같아요".into())
                    }
                } else if moved && score >= 0.5 {
                    (Verdict::Variation, "다른 순간이지만 조금 덜 선명".into())
                } else if m.motion > 0.3 && m.motion > b.motion + 0.1 {
                    (Verdict::Weaker, "흔들림이 있어요".into())
                } else if exposure_penalty(m) > exposure_penalty(b) && score >= 0.8 {
                    (Verdict::Weaker, "노출이 아쉬워요".into())
                } else {
                    (Verdict::Weaker, "흔들림·초점이 아쉬워요".into())
                }
            };
            let keep = matches!(verdict, Verdict::Best | Verdict::Variation);
            Pick { path: m.path.clone(), verdict, note, keep, score }
        })
        .collect();
    Group { items }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(path: &str, t: f64, hash: &str, sharp: f32, motion: f32) -> Metrics {
        Metrics {
            path: path.into(),
            time: t,
            has_exif_time: true,
            width: 100,
            height: 100,
            hash: hash.into(),
            color: [0.5; 3],
            subject_sharp: sharp,
            global_sharp: sharp * 0.5,
            motion,
            clip_high: 0.0,
            clip_low: 0.0,
            preview: String::new(),
        }
    }

    #[test]
    fn burst_picks_sharpest_and_flags_shake() {
        let g = group(vec![
            m("a", 0.0, "ff00ff00ff00ff00", 10.0, 0.1),
            m("b", 0.5, "ff00ff00ff00ff01", 4.0, 0.6),
            m("c", 1.0, "ff00ff00ff00ff00", 9.5, 0.1),
            m("d", 60.0, "00ff00ff00ff00ff", 5.0, 0.1),
        ]);
        assert_eq!(g.len(), 2);
        let v: Vec<_> = g[0].items.iter().map(|p| p.verdict.clone()).collect();
        assert_eq!(v, vec![Verdict::Best, Verdict::Weaker, Verdict::Duplicate]);
        assert_eq!(g[1].items[0].verdict, Verdict::Single);
    }

    #[test]
    fn panning_frame_is_kept() {
        let mut pan = m("p", 0.4, "ff00ff00ff00ff00", 8.0, 0.6);
        pan.global_sharp = 1.0;
        let g = group(vec![m("a", 0.0, "ff00ff00ff00ff00", 10.0, 0.1), pan]);
        assert_eq!(g[0].items[1].verdict, Verdict::Variation);
        assert!(g[0].items[1].keep);
    }

    #[test]
    fn civil_days() {
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(days_from_civil(2000, 3, 1), 11017);
    }
}
