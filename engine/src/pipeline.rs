//! The processing pipeline: linear float input -> display-encoded (sRGB) float output.

use rayon::prelude::*;

use crate::color::*;
use crate::recipe::{Recipe, HSL_BAND_CENTERS};

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

fn shoulder(x: f32) -> f32 {
    // Gentle highlight roll-off for values above 0.9 (recovers RAW/overexposed data).
    const K: f32 = 0.9;
    if x <= K { x } else { K + (1.0 - K) * ((x - K) / (1.0 - K)).tanh() }
}

/// Apply a recipe to a linear image, returning a display-encoded image in 0..1.
pub fn apply(r: &Recipe, input: &Image) -> Image {
    let (w, h) = (input.width, input.height);
    let tone = tone_lut(r, 4096);
    let curve = curve_lut(&r.curve, 1024);
    let curves_rgb = [curve_lut(&r.curve_r, 1024), curve_lut(&r.curve_g, 1024), curve_lut(&r.curve_b, 1024)];

    // White balance as channel gains, normalized to keep luminance.
    let mut wb = [
        2f32.powf(r.temperature * 0.35),
        2f32.powf(-r.tint * 0.25),
        2f32.powf(-r.temperature * 0.35),
    ];
    let wl = luma(wb);
    wb = [wb[0] / wl, wb[1] / wl, wb[2] / wl];
    let gain = 2f32.powf(r.exposure);
    let haze = r.dehaze * 0.06;

    // Stage 1: linear-light ops and display encoding.
    let mut out: Vec<Rgb> = input
        .data
        .par_iter()
        .map(|&p| {
            let mut c = [p[0] * wb[0], p[1] * wb[1], p[2] * wb[2]];
            if let Some(m) = r.channel_mixer {
                c = [
                    m[0][0] * c[0] + m[0][1] * c[1] + m[0][2] * c[2],
                    m[1][0] * c[0] + m[1][1] * c[1] + m[1][2] * c[2],
                    m[2][0] * c[0] + m[2][1] * c[1] + m[2][2] * c[2],
                ];
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
                *v = linear_to_srgb(shoulder(v.max(0.0)));
            }
            c
        })
        .collect();

    // Stage 2: local contrast (clarity) on display luminance.
    if r.clarity != 0.0 || r.dehaze != 0.0 {
        let lum: Vec<f32> = out.par_iter().map(|&c| luma(c)).collect();
        let radius = (w.max(h) / 60).max(2);
        let base = blur(&lum, w, h, radius);
        let amt = r.clarity * 0.8 + r.dehaze * 0.3;
        out.par_iter_mut().zip(lum.par_iter().zip(base.par_iter())).for_each(|(c, (&l, &b))| {
            let mid = 1.0 - (2.0 * l - 1.0).powi(2);
            let d = (l - b) * amt * mid;
            for v in c.iter_mut() {
                *v += d;
            }
        });
    }

    // Stage 3: tone, color and grading (point ops in display space).
    let hsl_active = r.hsl.iter().any(|b| *b != Default::default());
    let tints = [
        hue_tint(r.grade_shadows.hue),
        hue_tint(r.grade_midtones.hue),
        hue_tint(r.grade_highlights.hue),
    ];
    let fade = r.fade * 0.12;
    let diag = ((w * w + h * h) as f32).sqrt() * 0.5;
    let lut_s = r.lut_strength.clamp(0.0, 1.0);
    let sat_boost = if r.dehaze > 0.0 { r.dehaze * 0.15 } else { r.dehaze * 0.3 };

    out.par_chunks_mut(w).enumerate().for_each(|(y, row)| {
        for (x, c) in row.iter_mut().enumerate() {
            let mut p = *c;
            for v in p.iter_mut() {
                *v = lookup(&tone, *v);
            }
            if let Some(l) = &curve {
                for v in p.iter_mut() {
                    *v = lookup(l, *v);
                }
            }
            for k in 0..3 {
                if let Some(l) = &curves_rgb[k] {
                    p[k] = lookup(l, p[k]);
                }
            }

            // Saturation & vibrance.
            let yl = luma(p);
            let cur_sat = {
                let mx = p[0].max(p[1]).max(p[2]);
                let mn = p[0].min(p[1]).min(p[2]);
                if mx > 1e-5 { (mx - mn) / mx } else { 0.0 }
            };
            let vib = r.vibrance * (1.0 - cur_sat).powi(2);
            let s = (1.0 + r.saturation + vib + sat_boost).max(0.0);
            for v in p.iter_mut() {
                *v = yl + (*v - yl) * s;
            }

            if hsl_active {
                let mut hsl = rgb_to_hsl([p[0].clamp(0.0, 1.0), p[1].clamp(0.0, 1.0), p[2].clamp(0.0, 1.0)]);
                if hsl[1] > 1e-4 {
                    let (mut dh, mut ds, mut dl, mut wsum) = (0.0, 0.0, 0.0, 0.0);
                    for (i, band) in r.hsl.iter().enumerate() {
                        let mut d = (hsl[0] - HSL_BAND_CENTERS[i]).abs();
                        if d > 180.0 { d = 360.0 - d; }
                        let wgt = (1.0 - d / 45.0).max(0.0);
                        if wgt > 0.0 {
                            let wgt = wgt * wgt * (3.0 - 2.0 * wgt);
                            dh += band.hue * wgt;
                            ds += band.sat * wgt;
                            dl += band.lum * wgt;
                            wsum += wgt;
                        }
                    }
                    if wsum > 0.0 {
                        let norm = 1.0 / wsum.max(1.0);
                        hsl[0] += dh * norm;
                        let sw = hsl[1];
                        hsl[1] = (hsl[1] * (1.0 + ds * norm)).clamp(0.0, 1.0);
                        hsl[2] = (hsl[2] * (1.0 + dl * norm * 0.5 * sw)).clamp(0.0, 1.0);
                        p = hsl_to_rgb(hsl);
                    }
                }
            }

            // Color grading wheels.
            let yl = luma(p).clamp(0.0, 1.0);
            let masks = [(1.0 - yl).powi(2), 4.0 * yl * (1.0 - yl), yl * yl];
            let sats = [r.grade_shadows.sat, r.grade_midtones.sat, r.grade_highlights.sat];
            for k in 0..3 {
                if sats[k] > 0.0 {
                    let a = sats[k] * 0.25 * masks[k];
                    for i in 0..3 {
                        p[i] += tints[k][i] * a;
                    }
                }
            }

            if fade > 0.0 {
                for v in p.iter_mut() {
                    let cv = v.clamp(0.0, 1.0);
                    *v = cv + fade * (1.0 - cv).powi(2);
                }
            }

            if let Some(lut) = &r.lut {
                let q = lut.sample(p);
                for i in 0..3 {
                    p[i] += (q[i] - p[i]) * lut_s;
                }
            }

            if r.vignette != 0.0 {
                let dx = x as f32 - w as f32 * 0.5;
                let dy = y as f32 - h as f32 * 0.5;
                let rr = (dx * dx + dy * dy).sqrt() / diag;
                let m = smoothstep(0.35, 1.05, rr);
                let f = 1.0 + r.vignette * 0.8 * m;
                for v in p.iter_mut() {
                    *v = if r.vignette < 0.0 { *v * f } else { *v + (1.0 - *v) * r.vignette * 0.8 * m };
                }
            }

            for v in p.iter_mut() {
                *v = v.clamp(0.0, 1.0);
            }
            *c = p;
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
        let amt = r.grain * 0.08;
        out.par_chunks_mut(w).enumerate().for_each(|(y, row)| {
            for (x, c) in row.iter_mut().enumerate() {
                let n = (hash(x as u32, y as u32) - 0.5) * amt;
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
