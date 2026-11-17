//! The processing pipeline: linear float input -> display-encoded (sRGB) float output.

use rayon::prelude::*;

use crate::color::*;
use crate::recipe::Recipe;

/// An RGB float image. Pixel encoding (linear vs display) depends on context:
/// pipeline input is linear sRGB, pipeline output is display sRGB (gamma-encoded).
#[derive(Clone, Debug)]
pub struct Image {
    pub width: usize,
    pub height: usize,
    pub data: Vec<Rgb>,
}

impl Image {
    pub fn new(width: usize, height: usize) -> Self {
        Self { width, height, data: vec![[0.0; 3]; width * height] }
    }

    /// Area-average downscale so that the longest side is at most `max_side`.
    /// Used for fast previews and analysis; exports always use full resolution.
    pub fn downscale(&self, max_side: usize) -> Image {
        let long = self.width.max(self.height);
        if long <= max_side {
            return self.clone();
        }
        let scale = long as f32 / max_side as f32;
        let w = ((self.width as f32 / scale).round() as usize).max(1);
        let h = ((self.height as f32 / scale).round() as usize).max(1);
        let mut out = Image::new(w, h);
        out.data.par_chunks_mut(w).enumerate().for_each(|(y, row)| {
            let y0 = (y as f32 * scale) as usize;
            let y1 = (((y + 1) as f32 * scale) as usize).clamp(y0 + 1, self.height);
            for (x, px) in row.iter_mut().enumerate() {
                let x0 = (x as f32 * scale) as usize;
                let x1 = (((x + 1) as f32 * scale) as usize).clamp(x0 + 1, self.width);
                let mut acc = [0.0f32; 3];
                for yy in y0..y1 {
                    for xx in x0..x1 {
                        let p = self.data[yy * self.width + xx];
                        acc[0] += p[0];
                        acc[1] += p[1];
                        acc[2] += p[2];
                    }
                }
                let n = ((y1 - y0) * (x1 - x0)) as f32;
                *px = [acc[0] / n, acc[1] / n, acc[2] / n];
            }
        });
        out
    }
}

/// Monotone cubic (Fritsch–Carlson) curve sampled into a lookup table.
pub fn curve_lut(points: &[(f32, f32)], n: usize) -> Option<Vec<f32>> {
    if points.len() < 2 {
        return None;
    }
    let mut p: Vec<(f32, f32)> = points.to_vec();
    p.sort_by(|a, b| a.0.total_cmp(&b.0));
    let k = p.len();
    let mut d = vec![0.0f32; k - 1];
    for i in 0..k - 1 {
        let dx = (p[i + 1].0 - p[i].0).max(1e-6);
        d[i] = (p[i + 1].1 - p[i].1) / dx;
    }
    let mut m = vec![0.0f32; k];
    m[0] = d[0];
    m[k - 1] = d[k - 2];
    for i in 1..k - 1 {
        m[i] = if d[i - 1] * d[i] <= 0.0 { 0.0 } else { (d[i - 1] + d[i]) * 0.5 };
    }
    for i in 0..k - 1 {
        if d[i].abs() < 1e-9 {
            m[i] = 0.0;
            m[i + 1] = 0.0;
            continue;
        }
        let a = m[i] / d[i];
        let b = m[i + 1] / d[i];
        let s = a * a + b * b;
        if s > 9.0 {
            let t = 3.0 / s.sqrt();
            m[i] = t * a * d[i];
            m[i + 1] = t * b * d[i];
        }
    }
    let mut lut = Vec::with_capacity(n);
    for j in 0..n {
        let x = j as f32 / (n - 1) as f32;
        let y = if x <= p[0].0 {
            p[0].1
        } else if x >= p[k - 1].0 {
            p[k - 1].1
        } else {
            let i = p.iter().rposition(|q| q.0 <= x).unwrap().min(k - 2);
            let h = (p[i + 1].0 - p[i].0).max(1e-6);
            let t = (x - p[i].0) / h;
            let (t2, t3) = (t * t, t * t * t);
            (2.0 * t3 - 3.0 * t2 + 1.0) * p[i].1
                + (t3 - 2.0 * t2 + t) * h * m[i]
                + (-2.0 * t3 + 3.0 * t2) * p[i + 1].1
                + (t3 - t2) * h * m[i + 1]
        };
        lut.push(y.clamp(0.0, 1.0));
    }
    Some(lut)
}

#[inline]
fn lookup(lut: &[f32], v: f32) -> f32 {
    let n = lut.len() - 1;
    let p = v.clamp(0.0, 1.0) * n as f32;
    let i = (p as usize).min(n - 1);
    let f = p - i as f32;
    lut[i] + (lut[i + 1] - lut[i]) * f
}

/// Tone response for the Light panel (exposure is applied separately in linear).
fn tone_lut(r: &Recipe, n: usize) -> Vec<f32> {
    let bp = -r.blacks * 0.08;
    let wp = 1.0 - r.whites * 0.15;
    (0..n)
        .map(|j| {
            let g = j as f32 / (n - 1) as f32;
            let mut x = (g - bp) / (wp - bp).max(0.05);
            let xc = x.clamp(0.0, 1.0);
            // Shadows act on the lower third, highlights on the upper third.
            let s_mask = xc * (1.0 - xc) * (1.0 - xc) * 6.75;
            let h_mask = xc * xc * (1.0 - xc) * 6.75;
            x += r.shadows * 0.25 * s_mask + r.highlights * 0.25 * h_mask;
            let xc = x.clamp(0.0, 1.0);
            x += r.contrast * 0.6 * (xc - 0.5) * 4.0 * xc * (1.0 - xc);
            x.clamp(0.0, 1.0)
        })
        .collect()
}

/// Separable box blur (3 passes ≈ Gaussian) of a single-channel buffer.
pub fn blur(src: &[f32], w: usize, h: usize, radius: usize) -> Vec<f32> {
    if radius == 0 {
        return src.to_vec();
    }
    let mut a = src.to_vec();
    let mut b = vec![0.0f32; src.len()];
    for _ in 0..3 {
        box_h(&a, &mut b, w, radius);
        box_v(&b, &mut a, w, h, radius);
    }
    a
}

fn box_h(src: &[f32], dst: &mut [f32], w: usize, r: usize) {
    dst.par_chunks_mut(w).zip(src.par_chunks(w)).for_each(|(out, row)| {
        let mut acc = 0.0f32;
        let ri = r as isize;
        let get = |i: isize| row[i.clamp(0, w as isize - 1) as usize];
        for i in -ri..=ri {
            acc += get(i);
        }
        let norm = 1.0 / (2 * r + 1) as f32;
        for x in 0..w {
            out[x] = acc * norm;
            acc += get(x as isize + ri + 1) - get(x as isize - ri);
        }
    });
}

fn box_v(src: &[f32], dst: &mut [f32], w: usize, h: usize, r: usize) {
    // Process column strips in parallel by transposing access through row chunks.
    let cols: Vec<Vec<f32>> = (0..w)
        .into_par_iter()
        .map(|x| {
            let get = |y: isize| src[y.clamp(0, h as isize - 1) as usize * w + x];
            let ri = r as isize;
            let mut acc = 0.0f32;
            for i in -ri..=ri {
                acc += get(i);
            }
            let norm = 1.0 / (2 * r + 1) as f32;
            let mut col = Vec::with_capacity(h);
            for y in 0..h {
                col.push(acc * norm);
                acc += get(y as isize + ri + 1) - get(y as isize - ri);
            }
            col
        })
        .collect();
    dst.par_chunks_mut(w).enumerate().for_each(|(y, row)| {
        for x in 0..w {
            row[x] = cols[x][y];
        }
    });
}

#[inline]
fn hash(x: u32, y: u32) -> f32 {
    let mut h = x.wrapping_mul(0x8da6_b343) ^ y.wrapping_mul(0xd816_3841);
    h ^= h >> 13;
    h = h.wrapping_mul(0x85eb_ca6b);
    h ^= h >> 16;
    (h & 0xffff) as f32 / 65535.0
}

/// Smooth value noise for grain with adjustable size.
#[inline]
fn value_noise(x: f32, y: f32) -> f32 {
    let (xi, yi) = (x.floor(), y.floor());
    let (fx, fy) = (x - xi, y - yi);
    let (sx, sy) = (fx * fx * (3.0 - 2.0 * fx), fy * fy * (3.0 - 2.0 * fy));
    let (xi, yi) = (xi as i32 as u32, yi as i32 as u32);
    let a = hash(xi, yi);
    let b = hash(xi.wrapping_add(1), yi);
    let c = hash(xi, yi.wrapping_add(1));
    let d = hash(xi.wrapping_add(1), yi.wrapping_add(1));
    let top = a + (b - a) * sx;
    let bot = c + (d - c) * sx;
    top + (bot - top) * sy
}

fn shoulder(x: f32) -> f32 {
    // Gentle highlight roll-off for values above 0.9 (recovers RAW/overexposed data).
    const K: f32 = 0.9;
    if x <= K { x } else { K + (1.0 - K) * ((x - K) / (1.0 - K)).tanh() }
}

// ---------------------------------------------------------------- geometry

fn rotate90(img: &Image, turns: u8) -> Image {
    let (w, h) = (img.width, img.height);
    match turns % 4 {
        0 => img.clone(),
        2 => Image { width: w, height: h, data: img.data.iter().rev().copied().collect() },
        t => {
            let mut out = Image::new(h, w);
            out.data.par_chunks_mut(h).enumerate().for_each(|(y, row)| {
                for (x, px) in row.iter_mut().enumerate() {
                    // out is h wide, w tall.
                    let (sx, sy) = if t == 1 { (y, h - 1 - x) } else { (w - 1 - y, x) };
                    *px = img.data[sy * w + sx];
                }
            });
            out
        }
    }
}

fn flip(img: &mut Image, h: bool, v: bool) {
    let w = img.width;
    if h {
        img.data.par_chunks_mut(w).for_each(|row| row.reverse());
    }
    if v {
        let rows: Vec<Vec<Rgb>> = img.data.chunks(w).rev().map(|r| r.to_vec()).collect();
        img.data = rows.concat();
    }
}

/// Zoom factor that keeps a rotated frame free of empty corners.
pub fn straighten_scale(w: f32, h: f32, angle_deg: f32) -> f32 {
    let t = angle_deg.to_radians().abs();
    let (c, s) = (t.cos(), t.sin());
    (w / (w * c + h * s)).min(h / (w * s + h * c))
}

#[inline]
fn bilinear(img: &Image, x: f32, y: f32) -> Rgb {
    let x = x.clamp(0.0, (img.width - 1) as f32);
    let y = y.clamp(0.0, (img.height - 1) as f32);
    let (x0, y0) = (x as usize, y as usize);
    let (x1, y1) = ((x0 + 1).min(img.width - 1), (y0 + 1).min(img.height - 1));
    let (fx, fy) = (x - x0 as f32, y - y0 as f32);
    let p = |xx: usize, yy: usize| img.data[yy * img.width + xx];
    let (a, b, c, d) = (p(x0, y0), p(x1, y0), p(x0, y1), p(x1, y1));
    let mut o = [0.0; 3];
    for k in 0..3 {
        let top = a[k] + (b[k] - a[k]) * fx;
        let bot = c[k] + (d[k] - c[k]) * fx;
        o[k] = top + (bot - top) * fy;
    }
    o
}

/// Apply crop / straighten / rotate / flip. Plain crops, flips and quarter turns copy
/// pixels exactly; only straightening resamples (bilinear).
pub fn geometry(r: &Recipe, input: &Image) -> Image {
    let mut img = rotate90(input, r.rotate90);
    flip(&mut img, r.flip_h, r.flip_v);
    let (w, h) = (img.width as f32, img.height as f32);
    let [cx, cy, cw, ch] = r.crop.unwrap_or([0.0, 0.0, 1.0, 1.0]).map(|v| v.clamp(0.0, 1.0));
    let cw = cw.clamp(0.01, 1.0 - cx);
    let ch = ch.clamp(0.01, 1.0 - cy);
    let ow = ((cw * w).round() as usize).max(1);
    let oh = ((ch * h).round() as usize).max(1);
    if r.angle.abs() < 1e-3 {
        let x0 = (cx * w).round() as usize;
        let y0 = (cy * h).round() as usize;
        let ow = ow.min(img.width - x0.min(img.width - 1));
        let oh = oh.min(img.height - y0.min(img.height - 1));
        if x0 == 0 && y0 == 0 && ow == img.width && oh == img.height {
            return img;
        }
        let mut out = Image::new(ow, oh);
        out.data.par_chunks_mut(ow).enumerate().for_each(|(y, row)| {
            let s = (y0 + y) * img.width + x0;
            row.copy_from_slice(&img.data[s..s + ow]);
        });
        return out;
    }
    let s = straighten_scale(w, h, r.angle);
    let (sin, cos) = r.angle.to_radians().sin_cos();
    let mut out = Image::new(ow, oh);
    out.data.par_chunks_mut(ow).enumerate().for_each(|(y, row)| {
        for (x, px) in row.iter_mut().enumerate() {
            let nx = cx + (x as f32 + 0.5) / ow as f32 * cw - 0.5;
            let ny = cy + (y as f32 + 0.5) / oh as f32 * ch - 0.5;
            let (gx, gy) = (nx * w * s, ny * h * s);
            let sx = gx * cos - gy * sin + w * 0.5 - 0.5;
            let sy = gx * sin + gy * cos + h * 0.5 - 0.5;
            *px = bilinear(&img, sx, sy);
        }
    });
    out
}

// ---------------------------------------------------------------- color helpers

/// Calibration: rotate/saturate each RGB primary (like Lightroom's Calibration panel),
/// then renormalize so neutrals stay neutral.
fn calibration_matrix(r: &Recipe) -> Option<[[f32; 3]; 3]> {
    let hs = [
        (r.cal_red_hue, r.cal_red_sat),
        (r.cal_green_hue, r.cal_green_sat),
        (r.cal_blue_hue, r.cal_blue_sat),
    ];
    if hs.iter().all(|&(h, s)| h == 0.0 && s == 0.0) {
        return None;
    }
    let mut cols = [[0.0f32; 3]; 3];
    for (j, &(hue, sat)) in hs.iter().enumerate() {
        let mut e = [0.0f32; 3];
        e[j] = 1.0;
        let lab = linear_to_oklab(e);
        let ang = (hue * 30.0).to_radians();
        let (sn, cs) = ang.sin_cos();
        let k = (1.0 + sat * 0.6).max(0.0);
        let a = (lab[1] * cs - lab[2] * sn) * k;
        let b = (lab[1] * sn + lab[2] * cs) * k;
        cols[j] = oklab_to_linear([lab[0], a, b]);
    }
    let mut m = [[0.0f32; 3]; 3];
    for i in 0..3 {
        let sum: f32 = (0..3).map(|j| cols[j][i]).sum();
        for j in 0..3 {
            m[i][j] = cols[j][i] / sum.max(1e-3);
        }
    }
    Some(m)
}

fn mat_mul(a: [[f32; 3]; 3], b: [[f32; 3]; 3]) -> [[f32; 3]; 3] {
    let mut m = [[0.0; 3]; 3];
    for i in 0..3 {
        for j in 0..3 {
            m[i][j] = (0..3).map(|k| a[i][k] * b[k][j]).sum();
        }
    }
    m
}

#[inline]
fn apply_mat(m: &[[f32; 3]; 3], c: Rgb) -> Rgb {
    [
        m[0][0] * c[0] + m[0][1] * c[1] + m[0][2] * c[2],
        m[1][0] * c[0] + m[1][1] * c[1] + m[1][2] * c[2],
        m[2][0] * c[0] + m[2][1] * c[1] + m[2][2] * c[2],
    ]
}

/// OKLab hue (deg) centers of the 8 HSL bands: red, orange, yellow, green, aqua, blue, purple, magenta.
const OK_BAND_HUES: [f32; 8] = [25.0, 55.0, 100.0, 140.0, 195.0, 255.0, 300.0, 340.0];

/// Weights of the two bands surrounding hue `h` (piecewise linear, sums to 1).
#[inline]
fn band_weights(h: f32) -> [(usize, f32); 2] {
    for i in 0..8 {
        let a = OK_BAND_HUES[i];
        let b = if i == 7 { OK_BAND_HUES[0] + 360.0 } else { OK_BAND_HUES[i + 1] };
        let hh = if h < OK_BAND_HUES[0] { h + 360.0 } else { h };
        if hh >= a && hh < b {
            let t = (hh - a) / (b - a);
            let t = t * t * (3.0 - 2.0 * t);
            return [(i, 1.0 - t), ((i + 1) % 8, t)];
        }
    }
    [(0, 1.0), (1, 0.0)]
}

// ---------------------------------------------------------------- main pipeline

/// Apply a recipe to a linear image, returning a display-encoded image in 0..1.
///
/// Color science: exposure, white balance, calibration and mixing happen in linear light;
/// tone, saturation, hue and grading happen in OKLab so lightness and color don't bleed
/// into each other; skin tones get only part of the styling (`skin_protect`).
pub fn apply(r: &Recipe, input: &Image) -> Image {
    let geo;
    let input = if r.has_geometry() {
        geo = geometry(r, input);
        &geo
    } else {
        input
    };
    let (w, h) = (input.width, input.height);
    let tone = tone_lut(r, 4096);
    let curve = curve_lut(&r.curve, 1024);
    let curves_rgb = [curve_lut(&r.curve_r, 1024), curve_lut(&r.curve_g, 1024), curve_lut(&r.curve_b, 1024)];

    // White balance as channel gains, normalized to keep luminance.
    let mut wb = [
        2f32.powf(r.temperature * 0.45),
        2f32.powf(-r.tint * 0.3),
        2f32.powf(-r.temperature * 0.45),
    ];
    let wl = luma(wb);
    wb = [wb[0] / wl, wb[1] / wl, wb[2] / wl];
    let gain = 2f32.powf(r.exposure);
    let haze = r.dehaze * 0.06;
    let matrix = match (r.channel_mixer, calibration_matrix(r)) {
        (Some(m), Some(c)) => Some(mat_mul(m, c)),
        (Some(m), None) => Some(m),
        (None, c) => c,
    };

    // Stage 1: linear light.
    let mut lin: Vec<Rgb> = input
        .data
        .par_iter()
        .map(|&p| {
            let mut c = [p[0] * wb[0], p[1] * wb[1], p[2] * wb[2]];
            if let Some(m) = &matrix {
                c = apply_mat(m, c);
            }
            if r.monochrome {
                let y = luma(c);
                c = [y, y, y];
            }
            for v in c.iter_mut() {
                *v *= gain;
                if haze != 0.0 {
                    *v = (*v - haze) / (1.0 - haze);
                }
                *v = v.max(0.0);
            }
            c
        })
        .collect();

    // Film halation / bloom: glow from highlights, computed in linear light.
    if r.halation > 0.0 || r.bloom > 0.0 {
        let hi: Vec<f32> = lin.par_iter().map(|&c| (luma(c) - 0.6).max(0.0)).collect();
        let radius = (w.max(h) / 70).max(2);
        let glow = blur(&hi, w, h, radius);
        let wide = if r.bloom > 0.0 { blur(&hi, w, h, radius * 3) } else { Vec::new() };
        lin.par_iter_mut().enumerate().for_each(|(i, c)| {
            if r.halation > 0.0 {
                let g = glow[i] * r.halation * 2.5;
                c[0] += g;
                c[1] += g * 0.32;
                c[2] += g * 0.12;
            }
            if r.bloom > 0.0 {
                let g = wide[i] * r.bloom * 1.8;
                c[0] += g;
                c[1] += g * 0.95;
                c[2] += g * 0.88;
            }
        });
    }

    // Encode to display space (with highlight roll-off).
    let mut out: Vec<Rgb> = lin
        .par_iter()
        .map(|c| c.map(|v| linear_to_srgb(shoulder(v))))
        .collect();
    drop(lin);

    // Stage 2: local ops on display luminance (noise reduction, texture, clarity).
    if r.noise_reduction > 0.0 || r.color_noise_reduction > 0.0 {
        let lum: Vec<f32> = out.par_iter().map(|&c| luma(c)).collect();
        if r.noise_reduction > 0.0 {
            let base = blur(&lum, w, h, 1 + (r.noise_reduction * 2.0) as usize);
            let thr = 0.02 + 0.06 * r.noise_reduction;
            out.par_iter_mut().zip(lum.par_iter().zip(base.par_iter())).for_each(|(c, (&l, &b))| {
                let d = l - b;
                let wgt = (-(d / thr).powi(2)).exp() * r.noise_reduction;
                for v in c.iter_mut() {
                    *v -= d * wgt;
                }
            });
        }
        if r.color_noise_reduction > 0.0 {
            let rad = (w.max(h) / 300).max(2);
            let ch: Vec<[f32; 2]> = out.par_iter().map(|&c| { let y = luma(c); [c[0] - y, c[2] - y] }).collect();
            let cr = blur(&ch.iter().map(|v| v[0]).collect::<Vec<_>>(), w, h, rad);
            let cb = blur(&ch.iter().map(|v| v[1]).collect::<Vec<_>>(), w, h, rad);
            let k = r.color_noise_reduction;
            out.par_iter_mut().enumerate().for_each(|(i, c)| {
                let y = luma(*c);
                let r0 = c[0] - y + (cr[i] - (c[0] - y)) * k;
                let b0 = c[2] - y + (cb[i] - (c[2] - y)) * k;
                // Solve G from luma so brightness is kept.
                let g0 = -(0.2126 * r0 + 0.0722 * b0) / 0.7152;
                *c = [y + r0, y + g0, y + b0];
            });
        }
    }
    if r.clarity != 0.0 || r.dehaze != 0.0 || r.texture != 0.0 {
        let lum: Vec<f32> = out.par_iter().map(|&c| luma(c)).collect();
        let big = if r.clarity != 0.0 || r.dehaze != 0.0 { blur(&lum, w, h, (w.max(h) / 60).max(2)) } else { Vec::new() };
        let small = if r.texture != 0.0 { blur(&lum, w, h, (w.max(h) / 500).max(1)) } else { Vec::new() };
        let amt = r.clarity * 0.8 + r.dehaze * 0.3;
        out.par_iter_mut().enumerate().for_each(|(i, c)| {
            let l = lum[i];
            let mut d = 0.0;
            if !big.is_empty() {
                let mid = 1.0 - (2.0 * l - 1.0).powi(2);
                d += (l - big[i]) * amt * mid;
            }
            if !small.is_empty() {
                d += (l - small[i]) * r.texture * 1.2;
            }
            for v in c.iter_mut() {
                *v += d;
            }
        });
    }

    // Stage 3: tone & color in OKLab.
    let hsl_active = r.hsl.iter().any(|b| *b != Default::default());
    let grade_dirs: Vec<(f32, f32, f32)> = [r.grade_shadows, r.grade_midtones, r.grade_highlights]
        .iter()
        .map(|w| {
            let a = hsl_hue_to_oklab_hue(w.hue).to_radians();
            (a.cos(), a.sin(), w.sat.clamp(0.0, 1.5))
        })
        .collect();
    let grading = grade_dirs.iter().any(|d| d.2 > 0.0);
    let fade = r.fade * 0.12;
    let diag = ((w * w + h * h) as f32).sqrt() * 0.5;
    let lut_s = r.lut_strength.clamp(0.0, 1.5);
    let sat_boost = if r.dehaze > 0.0 { r.dehaze * 0.15 } else { r.dehaze * 0.3 };
    let skin_k = r.skin_protect.clamp(0.0, 1.0);
    let balance = r.grade_balance.clamp(-1.0, 1.0) * 0.25;

    out.par_chunks_mut(w).enumerate().for_each(|(y, row)| {
        for (x, c) in row.iter_mut().enumerate() {
            let disp = c.map(|v| v.clamp(0.0, 1.0));
            let lab0 = linear_to_oklab(disp.map(srgb_to_linear));
            let skin = if skin_k > 0.0 { skin_weight(lab0) * skin_k } else { 0.0 };

            // Tone on OKLab lightness; chroma follows so saturation stays consistent.
            let l0 = lab0[0].clamp(0.0, 1.0);
            let mut l1 = lookup(&tone, l0);
            if let Some(cv) = &curve {
                l1 = lookup(cv, l1);
            }
            if fade > 0.0 {
                l1 += fade * (1.0 - l1).powi(2);
            }
            let ratio = ((l1 + 0.02) / (l0 + 0.02)).clamp(0.3, 3.0).powf(0.8);
            let (mut a, mut b) = (lab0[1] * ratio, lab0[2] * ratio);

            // Saturation / vibrance (vibrance favors muted colors and spares skin).
            let chroma = (a * a + b * b).sqrt();
            let vib = r.vibrance * (1.0 - (chroma / 0.2).min(1.0)) * (1.0 - skin * 0.8);
            let s_raw = (1.0 + r.saturation + vib + sat_boost).max(0.0);
            // Desaturating looks apply to skin too (so it matches the scene);
            // boosts are held back on skin so faces don't go orange.
            let s = if s_raw > 1.0 { 1.0 + (s_raw - 1.0) * (1.0 - skin * 0.7) } else { s_raw };
            a *= s;
            b *= s;
            let based = [l1, a, b];
            let mut l = l1;

            if hsl_active && chroma > 1e-4 {
                let hue = b.atan2(a).to_degrees().rem_euclid(360.0);
                let (mut dh, mut ds, mut dl) = (0.0, 0.0, 0.0);
                for (i, wgt) in band_weights(hue) {
                    dh += r.hsl[i].hue * wgt;
                    ds += r.hsl[i].sat * wgt;
                    dl += r.hsl[i].lum * wgt;
                }
                let cc = (a * a + b * b).sqrt() * (1.0 + ds).max(0.0);
                let nh = (hue + dh * 0.8).to_radians();
                a = cc * nh.cos();
                b = cc * nh.sin();
                l = (l + dl * 0.12 * (chroma / 0.12).min(1.0)).clamp(0.0, 1.0);
            }

            if grading {
                let t = (l - balance).clamp(0.0, 1.0);
                let masks = [(1.0 - t).powi(2), 4.0 * t * (1.0 - t), t * t];
                for k in 0..3 {
                    let (dx, dy, sat) = grade_dirs[k];
                    if sat > 0.0 {
                        let m = sat * 0.06 * masks[k];
                        a += dx * m;
                        b += dy * m;
                    }
                }
            }

            // Skin protection: blend styled color back toward the tone-only result.
            if skin > 0.0 {
                l += (based[0] - l) * skin;
                a += (based[1] - a) * skin;
                b += (based[2] - b) * skin;
            }

            let mut p = oklab_to_linear_gamut([l, a, b]).map(linear_to_srgb);

            for k in 0..3 {
                if let Some(cl) = &curves_rgb[k] {
                    p[k] = lookup(cl, p[k]);
                }
            }

            if let Some(lut) = &r.lut {
                let q = lut.sample(p);
                let s = lut_s * (1.0 - skin * 0.6);
                for i in 0..3 {
                    p[i] += (q[i] - p[i]) * s;
                }
            }

            if r.vignette != 0.0 {
                let dx = x as f32 - w as f32 * 0.5;
                let dy = y as f32 - h as f32 * 0.5;
                let rr = (dx * dx + dy * dy).sqrt() / diag;
                let m = smoothstep(0.3, 1.1, rr);
                for v in p.iter_mut() {
                    *v = if r.vignette < 0.0 { *v * (1.0 + r.vignette * 0.85 * m) } else { *v + (1.0 - *v) * r.vignette * 0.8 * m };
                }
            }

            *c = p.map(|v| v.clamp(0.0, 1.0));
        }
    });

    // Stage 4: sharpening and grain.
    if r.sharpen > 0.0 {
        let lum: Vec<f32> = out.par_iter().map(|&c| luma(c)).collect();
        let base = blur(&lum, w, h, 1);
        let amt = r.sharpen * 1.5;
        out.par_iter_mut().zip(lum.par_iter().zip(base.par_iter())).for_each(|(c, (&l, &b))| {
            let d = (l - b) * amt;
            for v in c.iter_mut() {
                *v = (*v + d).clamp(0.0, 1.0);
            }
        });
    }
    if r.grain > 0.0 {
        let amt = r.grain * 0.09;
        // Grain size is relative to image size so previews and exports match.
        let cell = (1.0 + r.grain_size.clamp(0.0, 1.0) * 3.0) * (w.max(h) as f32 / 2000.0).max(0.5);
        out.par_chunks_mut(w).enumerate().for_each(|(y, row)| {
            for (x, c) in row.iter_mut().enumerate() {
                let n = (value_noise(x as f32 / cell, y as f32 / cell) - 0.5) * 2.0 * amt;
                let yl = luma(*c);
                let m = 4.0 * yl * (1.0 - yl) * 0.7 + 0.3;
                for v in c.iter_mut() {
                    *v = (*v + n * m).clamp(0.0, 1.0);
                }
            }
        });
    }

    Image { width: w, height: h, data: out }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn neutral_recipe_is_identity() {
        let mut img = Image::new(16, 16);
        for (i, p) in img.data.iter_mut().enumerate() {
            let v = i as f32 / 256.0;
            *p = [srgb_to_linear(v), srgb_to_linear(1.0 - v), srgb_to_linear(0.5 * v)];
        }
        let out = apply(&Recipe::default(), &img);
        for (a, b) in img.data.iter().zip(out.data.iter()) {
            for k in 0..3 {
                let expect = linear_to_srgb(shoulder(a[k]));
                assert!((expect - b[k]).abs() < 2e-3, "{expect} vs {}", b[k]);
            }
        }
    }

    #[test]
    fn exposure_brightens() {
        let mut img = Image::new(4, 4);
        img.data.fill([0.18, 0.18, 0.18]);
        let r = Recipe { exposure: 1.0, ..Default::default() };
        let out = apply(&r, &img);
        assert!(out.data[0][0] > linear_to_srgb(0.18) + 0.1);
    }

    #[test]
    fn curve_is_monotone() {
        let l = curve_lut(&[(0.0, 0.0), (0.25, 0.2), (0.75, 0.8), (1.0, 1.0)], 256).unwrap();
        assert!(l.windows(2).all(|w| w[1] >= w[0]));
    }
}
