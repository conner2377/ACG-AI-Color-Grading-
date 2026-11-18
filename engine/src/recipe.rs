//! A recipe is the complete, serializable description of an edit.
//! Templates/presets, auto-grades and AI outputs are all recipes.

use serde::{Deserialize, Serialize};

use crate::lut::Lut3d;

/// Per-band HSL adjustment. Bands: red, orange, yellow, green, aqua, blue, purple, magenta.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct HslBand {
    /// Hue shift in degrees (-30..30 typical).
    pub hue: f32,
    /// Saturation (-1..1).
    pub sat: f32,
    /// Luminance (-1..1).
    pub lum: f32,
}

pub const HSL_BAND_NAMES: [&str; 8] =
    ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"];
pub const HSL_BAND_CENTERS: [f32; 8] = [0.0, 30.0, 60.0, 120.0, 180.0, 225.0, 270.0, 315.0];

/// Split-tone style color wheel for one tonal range.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ToneWheel {
    /// Hue in degrees.
    pub hue: f32,
    /// Strength (0..1).
    pub sat: f32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Recipe {
    pub name: String,
    /// Template category shown in the UI (e.g. "필름", "시네마틱").
    pub category: String,
    /// Short description of the look.
    pub description: String,

    // --- Geometry (applied first, lossless for 90° turns/flips/plain crops) ---
    /// Straighten angle in degrees (-45..45). The image is zoomed to avoid empty corners.
    pub angle: f32,
    /// Quarter turns clockwise (0..3).
    pub rotate90: u8,
    pub flip_h: bool,
    pub flip_v: bool,
    /// Crop rectangle [x, y, w, h] normalized to the rotated frame. None = full frame.
    pub crop: Option<[f32; 4]>,

    // --- Light ---
    /// Exposure in stops (-5..5).
    pub exposure: f32,
    /// All of the following are -1..1, 0 = neutral.
    pub contrast: f32,
    pub highlights: f32,
    pub shadows: f32,
    pub whites: f32,
    pub blacks: f32,

    // --- Color ---
    /// White balance shift: negative = cooler, positive = warmer (-1..1).
    pub temperature: f32,
    /// Negative = green, positive = magenta (-1..1).
    pub tint: f32,
    pub vibrance: f32,
    pub saturation: f32,
    pub hsl: [HslBand; 8],

    // --- Calibration: primary hue/saturation shifts (-1..1), like Lightroom's Calibration panel ---
    pub cal_red_hue: f32,
    pub cal_red_sat: f32,
    pub cal_green_hue: f32,
    pub cal_green_sat: f32,
    pub cal_blue_hue: f32,
    pub cal_blue_sat: f32,

    // --- Effects / detail ---
    /// Fine detail contrast (-1..1).
    pub texture: f32,
    pub clarity: f32,
    pub dehaze: f32,
    /// Sharpen amount (0..1).
    pub sharpen: f32,
    /// Negative darkens corners (-1..1).
    pub vignette: f32,
    /// Film grain (0..1).
    pub grain: f32,
    /// Grain size (0 fine .. 1 coarse).
    pub grain_size: f32,
    /// Luminance noise reduction (0..1).
    pub noise_reduction: f32,
    /// Color noise reduction (0..1).
    pub color_noise_reduction: f32,
    /// Film halation: red-orange glow around bright highlights (0..1).
    pub halation: f32,
    /// Soft dreamy glow from highlights (0..1).
    pub bloom: f32,
    /// How much of the color styling is held back on skin tones (0 = none, 1 = full).
    pub skin_protect: f32,

    // --- Grading ---
    pub grade_shadows: ToneWheel,
    pub grade_midtones: ToneWheel,
    pub grade_highlights: ToneWheel,
    /// Shifts the split between shadow and highlight grading (-1..1).
    pub grade_balance: f32,
    /// Faded/matte blacks (0..1): lifts the black point.
    pub fade: f32,

    /// Master tone curve control points in display space, (x, y) in 0..1, sorted by x.
    /// Empty = identity.
    pub curve: Vec<(f32, f32)>,
    /// Optional per-channel curves (R, G, B). Empty = identity.
    pub curve_r: Vec<(f32, f32)>,
    pub curve_g: Vec<(f32, f32)>,
    pub curve_b: Vec<(f32, f32)>,

    /// Channel mixer as a 3x3 row-major matrix applied in linear RGB (None = identity).
    /// Used for looks like infrared (channel swaps) or B&W mixes.
    pub channel_mixer: Option<[[f32; 3]; 3]>,
    /// Convert to monochrome after mixing.
    pub monochrome: bool,

    /// Optional 3D LUT applied in display space, blended by `lut_strength`.
    pub lut: Option<Lut3d>,
    pub lut_strength: f32,
}

impl Default for Recipe {
    fn default() -> Self {
        Self {
            name: String::new(),
            category: String::new(),
            description: String::new(),
            angle: 0.0,
            rotate90: 0,
            flip_h: false,
            flip_v: false,
            crop: None,
            cal_red_hue: 0.0,
            cal_red_sat: 0.0,
            cal_green_hue: 0.0,
            cal_green_sat: 0.0,
            cal_blue_hue: 0.0,
            cal_blue_sat: 0.0,
            texture: 0.0,
            grain_size: 0.3,
            noise_reduction: 0.0,
            color_noise_reduction: 0.0,
            grade_balance: 0.0,
            halation: 0.0,
            bloom: 0.0,
            skin_protect: 0.6,
            exposure: 0.0,
            contrast: 0.0,
            highlights: 0.0,
            shadows: 0.0,
            whites: 0.0,
            blacks: 0.0,
            temperature: 0.0,
            tint: 0.0,
            vibrance: 0.0,
            saturation: 0.0,
            hsl: [HslBand::default(); 8],
            clarity: 0.0,
            dehaze: 0.0,
            sharpen: 0.0,
            vignette: 0.0,
            grain: 0.0,
            grade_shadows: ToneWheel::default(),
            grade_midtones: ToneWheel::default(),
            grade_highlights: ToneWheel::default(),
            fade: 0.0,
            curve: Vec::new(),
            curve_r: Vec::new(),
            curve_g: Vec::new(),
            curve_b: Vec::new(),
            channel_mixer: None,
            monochrome: false,
            lut: None,
            lut_strength: 1.0,
        }
    }
}

impl Recipe {
    pub fn named(name: &str) -> Self {
        Self { name: name.to_string(), ..Default::default() }
    }

    /// The geometry part only is non-identity.
    pub fn has_geometry(&self) -> bool {
        self.angle != 0.0 || self.rotate90 % 4 != 0 || self.flip_h || self.flip_v || self.crop.is_some()
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).expect("recipe serializes")
    }

    pub fn from_json(s: &str) -> serde_json::Result<Self> {
        serde_json::from_str(s)
    }

    /// Layer `style` on top of `self` (a base correction): scalar adjustments add,
    /// grading/curves/mixer/LUT come from the style when it sets them.
    pub fn layered(&self, style: &Recipe) -> Recipe {
        let mut r = self.clone();
        r.name = style.name.clone();
        macro_rules! add { ($($f:ident),*) => { $( r.$f = self.$f + style.$f; )* } }
        add!(exposure, contrast, highlights, shadows, whites, blacks, temperature, tint,
             vibrance, saturation, clarity, dehaze, sharpen, vignette, grain, fade,
             texture, noise_reduction, color_noise_reduction, grade_balance, halation, bloom,
             cal_red_hue, cal_red_sat, cal_green_hue, cal_green_sat, cal_blue_hue, cal_blue_sat);
        r.skin_protect = style.skin_protect;
        r.category = style.category.clone();
        r.description = style.description.clone();
        if style.grain > 0.0 { r.grain_size = style.grain_size; }
        for i in 0..8 {
            r.hsl[i].hue += style.hsl[i].hue;
            r.hsl[i].sat += style.hsl[i].sat;
            r.hsl[i].lum += style.hsl[i].lum;
        }
        if style.grade_shadows.sat > 0.0 { r.grade_shadows = style.grade_shadows; }
        if style.grade_midtones.sat > 0.0 { r.grade_midtones = style.grade_midtones; }
        if style.grade_highlights.sat > 0.0 { r.grade_highlights = style.grade_highlights; }
        if !style.curve.is_empty() { r.curve = style.curve.clone(); }
        if !style.curve_r.is_empty() { r.curve_r = style.curve_r.clone(); }
        if !style.curve_g.is_empty() { r.curve_g = style.curve_g.clone(); }
        if !style.curve_b.is_empty() { r.curve_b = style.curve_b.clone(); }
        if style.channel_mixer.is_some() { r.channel_mixer = style.channel_mixer; }
        r.monochrome |= style.monochrome;
        if style.lut.is_some() {
            r.lut = style.lut.clone();
            r.lut_strength = style.lut_strength;
        }
        r
    }
}
