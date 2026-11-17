//! Color-space helpers. Pixel values are RGB triples of f32.

pub type Rgb = [f32; 3];

#[inline]
pub fn srgb_to_linear(v: f32) -> f32 {
    if v <= 0.04045 {
        v / 12.92
    } else {
        ((v + 0.055) / 1.055).powf(2.4)
    }
}

#[inline]
pub fn linear_to_srgb(v: f32) -> f32 {
    if v <= 0.003_130_8 {
        v * 12.92
    } else {
        1.055 * v.powf(1.0 / 2.4) - 0.055
    }
}

/// Rec.709 luminance.
#[inline]
pub fn luma(c: Rgb) -> f32 {
    0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
}

#[inline]
pub fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// RGB (0..1) -> HSL with hue in degrees [0, 360).
pub fn rgb_to_hsl(c: Rgb) -> Rgb {
    let (r, g, b) = (c[0], c[1], c[2]);
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let l = (max + min) * 0.5;
    let d = max - min;
    if d < 1e-6 {
        return [0.0, 0.0, l];
    }
    let s = if l > 0.5 { d / (2.0 - max - min) } else { d / (max + min) };
    let h = if max == r {
        ((g - b) / d).rem_euclid(6.0)
    } else if max == g {
        (b - r) / d + 2.0
    } else {
        (r - g) / d + 4.0
    };
    [h * 60.0, s, l]
}

pub fn hsl_to_rgb(hsl: Rgb) -> Rgb {
    let (h, s, l) = (hsl[0].rem_euclid(360.0), hsl[1].clamp(0.0, 1.0), hsl[2]);
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let hp = h / 60.0;
    let x = c * (1.0 - (hp.rem_euclid(2.0) - 1.0).abs());
    let (r, g, b) = match hp as i32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = l - c * 0.5;
    [r + m, g + m, b + m]
}

/// Unit-luma-neutral tint vector for a hue (degrees): adding it shifts hue
/// without changing Rec.709 luminance.
pub fn hue_tint(hue: f32) -> Rgb {
    let c = hsl_to_rgb([hue, 1.0, 0.5]);
    let y = luma(c);
    [c[0] - y, c[1] - y, c[2] - y]
}

// --- CIE Lab (D65), input is linear sRGB ---

fn f_lab(t: f32) -> f32 {
    if t > 0.008_856 { t.cbrt() } else { 7.787 * t + 16.0 / 116.0 }
}
fn f_lab_inv(t: f32) -> f32 {
    let t3 = t * t * t;
    if t3 > 0.008_856 { t3 } else { (t - 16.0 / 116.0) / 7.787 }
}

pub fn linear_to_lab(c: Rgb) -> Rgb {
    let x = (0.4124 * c[0] + 0.3576 * c[1] + 0.1805 * c[2]) / 0.95047;
    let y = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    let z = (0.0193 * c[0] + 0.1192 * c[1] + 0.9505 * c[2]) / 1.08883;
    let (fx, fy, fz) = (f_lab(x), f_lab(y), f_lab(z));
    [116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)]
}

pub fn lab_to_linear(lab: Rgb) -> Rgb {
    let fy = (lab[0] + 16.0) / 116.0;
    let fx = fy + lab[1] / 500.0;
    let fz = fy - lab[2] / 200.0;
    let x = f_lab_inv(fx) * 0.95047;
    let y = f_lab_inv(fy);
    let z = f_lab_inv(fz) * 1.08883;
    [
        3.2406 * x - 1.5372 * y - 0.4986 * z,
        -0.9689 * x + 1.8758 * y + 0.0415 * z,
        0.0557 * x - 0.2040 * y + 1.0570 * z,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn roundtrips() {
        for v in [0.0f32, 0.01, 0.2, 0.5, 0.9, 1.0] {
            assert!((linear_to_srgb(srgb_to_linear(v)) - v).abs() < 1e-5);
        }
        let c = [0.3, 0.6, 0.1];
        let back = hsl_to_rgb(rgb_to_hsl(c));
        for i in 0..3 { assert!((back[i] - c[i]).abs() < 1e-4); }
        let back = lab_to_linear(linear_to_lab(c));
        for i in 0..3 { assert!((back[i] - c[i]).abs() < 1e-3); }
    }
}
