//! 3D LUTs (Adobe/Resolve .cube compatible).

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

use crate::color::Rgb;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Lut3d {
    pub size: usize,
    /// size^3 entries, red changes fastest (cube file order).
    pub data: Vec<Rgb>,
}

impl Lut3d {
    pub fn identity(size: usize) -> Self {
        Self::from_fn(size, |c| c)
    }

    pub fn from_fn(size: usize, f: impl Fn(Rgb) -> Rgb) -> Self {
        let s = (size - 1) as f32;
        let mut data = Vec::with_capacity(size * size * size);
        for b in 0..size {
            for g in 0..size {
                for r in 0..size {
                    data.push(f([r as f32 / s, g as f32 / s, b as f32 / s]));
                }
            }
        }
        Self { size, data }
    }

    #[inline]
    fn at(&self, r: usize, g: usize, b: usize) -> Rgb {
        self.data[(b * self.size + g) * self.size + r]
    }

    /// Trilinear sample, input in 0..1 (clamped).
    pub fn sample(&self, c: Rgb) -> Rgb {
        let s = (self.size - 1) as f32;
        let p = [c[0].clamp(0.0, 1.0) * s, c[1].clamp(0.0, 1.0) * s, c[2].clamp(0.0, 1.0) * s];
        let i0 = [p[0] as usize, p[1] as usize, p[2] as usize];
        let i1 = [
            (i0[0] + 1).min(self.size - 1),
            (i0[1] + 1).min(self.size - 1),
            (i0[2] + 1).min(self.size - 1),
        ];
        let f = [p[0] - i0[0] as f32, p[1] - i0[1] as f32, p[2] - i0[2] as f32];
        let mut out = [0.0; 3];
        for k in 0..3 {
            let c000 = self.at(i0[0], i0[1], i0[2])[k];
            let c100 = self.at(i1[0], i0[1], i0[2])[k];
            let c010 = self.at(i0[0], i1[1], i0[2])[k];
            let c110 = self.at(i1[0], i1[1], i0[2])[k];
            let c001 = self.at(i0[0], i0[1], i1[2])[k];
            let c101 = self.at(i1[0], i0[1], i1[2])[k];
            let c011 = self.at(i0[0], i1[1], i1[2])[k];
            let c111 = self.at(i1[0], i1[1], i1[2])[k];
            let c00 = c000 + (c100 - c000) * f[0];
            let c10 = c010 + (c110 - c010) * f[0];
            let c01 = c001 + (c101 - c001) * f[0];
            let c11 = c011 + (c111 - c011) * f[0];
            let c0 = c00 + (c10 - c00) * f[1];
            let c1 = c01 + (c11 - c01) * f[1];
            out[k] = c0 + (c1 - c0) * f[2];
        }
        out
    }

    pub fn parse_cube(text: &str) -> Result<Self> {
        let mut size = 0usize;
        let mut data = Vec::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some(rest) = line.strip_prefix("LUT_3D_SIZE") {
                size = rest.trim().parse().context("bad LUT_3D_SIZE")?;
                continue;
            }
            if line.starts_with(|c: char| c.is_ascii_alphabetic()) {
                continue; // TITLE, DOMAIN_MIN/MAX, etc.
            }
            let v: Vec<f32> = line.split_whitespace().filter_map(|t| t.parse().ok()).collect();
            if v.len() == 3 {
                data.push([v[0], v[1], v[2]]);
            }
        }
        if size < 2 || data.len() != size * size * size {
            bail!("invalid .cube: size {size}, {} entries", data.len());
        }
        Ok(Self { size, data })
    }

    pub fn to_cube(&self, title: &str) -> String {
        let mut s = format!("TITLE \"{title}\"\nLUT_3D_SIZE {}\n", self.size);
        for c in &self.data {
            s.push_str(&format!("{:.6} {:.6} {:.6}\n", c[0], c[1], c[2]));
        }
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identity_and_cube_roundtrip() {
        let l = Lut3d::identity(17);
        let c = [0.13, 0.77, 0.42];
        let o = l.sample(c);
        for i in 0..3 { assert!((o[i] - c[i]).abs() < 1e-5); }
        let back = Lut3d::parse_cube(&l.to_cube("id")).unwrap();
        assert_eq!(back.size, 17);
    }
}
