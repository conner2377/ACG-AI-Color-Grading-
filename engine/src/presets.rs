//! Built-in templates. Each is a style layered on top of a base correction.

use crate::recipe::{HslBand, Recipe, ToneWheel};

fn wheel(hue: f32, sat: f32) -> ToneWheel {
    ToneWheel { hue, sat }
}

/// Indices into the HSL band array.
pub mod band {
    pub const RED: usize = 0;
    pub const ORANGE: usize = 1;
    pub const YELLOW: usize = 2;
    pub const GREEN: usize = 3;
    pub const AQUA: usize = 4;
    pub const BLUE: usize = 5;
}

pub fn all() -> Vec<Recipe> {
    vec![
        natural(), vivid(), film(), cinematic(), warm(), cool_moody(), soft_portrait(),
        landscape(), night_city(), bw_classic(), bw_contrast(), infrared(), flash(), matte_pastel(),
    ]
}

pub fn by_name(name: &str) -> Option<Recipe> {
    all().into_iter().find(|r| r.name == name)
}

pub fn natural() -> Recipe {
    Recipe { vibrance: 0.1, clarity: 0.05, ..Recipe::named("자연스럽게") }
}

pub fn vivid() -> Recipe {
    Recipe { contrast: 0.2, vibrance: 0.35, saturation: 0.05, clarity: 0.15, sharpen: 0.2, ..Recipe::named("선명하게") }
}

pub fn film() -> Recipe {
    Recipe {
        contrast: -0.05,
        highlights: -0.2,
        saturation: -0.12,
        temperature: 0.08,
        fade: 0.35,
        grain: 0.25,
        grade_shadows: wheel(200.0, 0.25),
        grade_highlights: wheel(40.0, 0.3),
        curve: vec![(0.0, 0.04), (0.25, 0.23), (0.75, 0.80), (1.0, 0.96)],
        ..Recipe::named("필름")
    }
}

pub fn cinematic() -> Recipe {
    let mut r = Recipe {
        contrast: 0.2,
        highlights: -0.25,
        shadows: -0.1,
        saturation: -0.08,
        grade_shadows: wheel(190.0, 0.5),
        grade_highlights: wheel(32.0, 0.4),
        vignette: -0.25,
        ..Recipe::named("시네마틱")
    };
    r.hsl[band::ORANGE] = HslBand { hue: -3.0, sat: 0.1, lum: 0.05 };
    r.hsl[band::BLUE] = HslBand { hue: -12.0, sat: -0.05, lum: -0.1 };
    r.hsl[band::GREEN] = HslBand { hue: 20.0, sat: -0.3, lum: -0.1 };
    r
}

pub fn warm() -> Recipe {
    Recipe {
        temperature: 0.25,
        tint: 0.05,
        vibrance: 0.15,
        shadows: 0.1,
        grade_highlights: wheel(45.0, 0.3),
        ..Recipe::named("따뜻한 감성")
    }
}

pub fn cool_moody() -> Recipe {
    let mut r = Recipe {
        exposure: -0.15,
        contrast: 0.15,
        temperature: -0.25,
        saturation: -0.2,
        highlights: -0.2,
        grade_shadows: wheel(215.0, 0.35),
        vignette: -0.3,
        ..Recipe::named("차가운 무드")
    };
    r.hsl[band::GREEN] = HslBand { hue: 15.0, sat: -0.4, lum: -0.2 };
    r
}

pub fn soft_portrait() -> Recipe {
    let mut r = Recipe {
        exposure: 0.1,
        contrast: -0.1,
        highlights: -0.15,
        shadows: 0.2,
        clarity: -0.15,
        temperature: 0.06,
        vibrance: 0.1,
        ..Recipe::named("인물 화사하게")
    };
    r.hsl[band::ORANGE] = HslBand { hue: 0.0, sat: -0.1, lum: 0.15 };
    r.hsl[band::RED] = HslBand { hue: 3.0, sat: -0.05, lum: 0.05 };
    r
}

pub fn landscape() -> Recipe {
    let mut r = Recipe {
        contrast: 0.15,
        highlights: -0.4,
        shadows: 0.3,
        dehaze: 0.2,
        clarity: 0.2,
        vibrance: 0.3,
        sharpen: 0.25,
        ..Recipe::named("풍경 강조")
    };
    r.hsl[band::BLUE] = HslBand { hue: 0.0, sat: 0.15, lum: -0.15 };
    r.hsl[band::GREEN] = HslBand { hue: -5.0, sat: 0.1, lum: 0.0 };
    r
}

pub fn night_city() -> Recipe {
    let mut r = Recipe {
        contrast: 0.2,
        highlights: -0.3,
        blacks: -0.1,
        temperature: -0.15,
        tint: 0.1,
        vibrance: 0.25,
        clarity: 0.1,
        grade_shadows: wheel(230.0, 0.35),
        grade_highlights: wheel(320.0, 0.2),
        ..Recipe::named("야경 네온")
    };
    r.hsl[band::AQUA] = HslBand { hue: 10.0, sat: 0.2, lum: 0.0 };
    r.hsl[band::YELLOW] = HslBand { hue: -10.0, sat: 0.0, lum: 0.0 };
    r
}

pub fn bw_classic() -> Recipe {
    Recipe {
        monochrome: true,
        channel_mixer: Some([[0.35, 0.5, 0.15], [0.35, 0.5, 0.15], [0.35, 0.5, 0.15]]),
        contrast: 0.15,
        grain: 0.15,
        ..Recipe::named("흑백 클래식")
    }
}

pub fn bw_contrast() -> Recipe {
    Recipe {
        monochrome: true,
        channel_mixer: Some([[0.6, 0.4, 0.0], [0.6, 0.4, 0.0], [0.6, 0.4, 0.0]]),
        contrast: 0.5,
        blacks: -0.2,
        whites: 0.15,
        clarity: 0.3,
        vignette: -0.3,
        ..Recipe::named("흑백 하이콘트라스트")
    }
}

/// Color-infrared (Aerochrome-like) look: foliage turns red/magenta and glows,
/// skies deepen, other hues (skin, clothing) stay close to the original.
/// Implemented as a hue-selective 3D LUT so it never touches resolution.
pub fn infrared() -> Recipe {
    use crate::color::{hsl_to_rgb, rgb_to_hsl, smoothstep};
    let lut = crate::lut::Lut3d::from_fn(33, |c| {
        let mut hsl = rgb_to_hsl(c);
        let h = hsl[0];
        // Foliage weight: yellow-green through aqua-green.
        let foliage = smoothstep(55.0, 85.0, h) * (1.0 - smoothstep(160.0, 185.0, h));
        let sky = smoothstep(185.0, 205.0, h) * (1.0 - smoothstep(245.0, 265.0, h));
        let s_w = smoothstep(0.05, 0.25, hsl[1]);
        let f = foliage * s_w;
        let k = sky * s_w;
        if f > 0.0 {
            // Rotate toward crimson (≈350°) the short way (through yellow/orange),
            // and brighten like IR reflectance.
            let mut d = 350.0 - h;
            if d < -180.0 { d += 360.0; }
            if d > 180.0 { d -= 360.0; }
            hsl[0] = (h + d * f).rem_euclid(360.0);
            hsl[1] = (hsl[1] * (1.0 + 0.4 * f)).min(1.0);
            hsl[2] = (hsl[2] + 0.12 * f * (1.0 - hsl[2])).min(1.0);
        }
        if k > 0.0 {
            hsl[0] -= 10.0 * k;
            hsl[2] *= 1.0 - 0.25 * k;
            hsl[1] = (hsl[1] * (1.0 + 0.2 * k)).min(1.0);
        }
        // Warm hues lean slightly yellow, as on IR film.
        let warm = smoothstep(0.0, 15.0, h) * (1.0 - smoothstep(40.0, 55.0, h)) * s_w;
        hsl[0] += 6.0 * warm;
        if f == 0.0 && k == 0.0 && warm == 0.0 { return c; }
        hsl_to_rgb(hsl)
    });
    Recipe {
        contrast: 0.15,
        highlights: -0.1,
        vibrance: 0.1,
        lut: Some(lut),
        lut_strength: 1.0,
        ..Recipe::named("적외선")
    }
}

/// Direct on-camera flash look: bright hard-lit subject, dark falloff, crisp cool light.
pub fn flash() -> Recipe {
    Recipe {
        exposure: 0.25,
        contrast: 0.35,
        highlights: 0.2,
        shadows: -0.35,
        blacks: -0.15,
        temperature: -0.08,
        clarity: 0.15,
        sharpen: 0.3,
        vignette: -0.6,
        saturation: 0.05,
        ..Recipe::named("플래시")
    }
}

pub fn matte_pastel() -> Recipe {
    Recipe {
        exposure: 0.15,
        contrast: -0.25,
        saturation: -0.2,
        fade: 0.5,
        grade_highlights: wheel(330.0, 0.15),
        grade_shadows: wheel(180.0, 0.15),
        ..Recipe::named("파스텔 매트")
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn presets_roundtrip_json() {
        for p in super::all() {
            let back = crate::Recipe::from_json(&p.to_json()).unwrap();
            assert_eq!(back, p);
        }
    }
}
