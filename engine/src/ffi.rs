//! C ABI used by the Flutter app (dart:ffi). Works the same on Windows and Android.
//!
//! Strings in/out are UTF-8, NUL-terminated. Strings returned by the engine must be
//! released with `acg_string_free`. Errors are reported by a null/negative return and
//! `acg_last_error()`.

#![allow(unsafe_op_in_unsafe_fn)]

use std::cell::RefCell;
use std::ffi::{c_char, CStr, CString};
use std::path::Path;

use crate::pipeline::Image;
use crate::{analysis, apply, io, matching, presets, Recipe};

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

fn set_error(e: impl std::fmt::Display) {
    LAST_ERROR.with(|l| *l.borrow_mut() = CString::new(e.to_string().replace('\0', " ")).ok());
}

fn out_string(s: String) -> *mut c_char {
    CString::new(s.replace('\0', " ")).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

unsafe fn in_str<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() { None } else { CStr::from_ptr(p).to_str().ok() }
}

/// An opened photo: full-resolution linear data plus a preview-sized copy.
pub struct Session {
    full: Image,
    preview: Image,
    /// Last rendered preview as RGBA8 (kept alive for the caller to read).
    rgba: Vec<u8>,
    thumb: Vec<u8>,
}

fn to_rgba(img: &Image, out: &mut Vec<u8>) {
    out.clear();
    out.reserve(img.data.len() * 4);
    for p in &img.data {
        out.extend_from_slice(&[
            (p[0] * 255.0 + 0.5) as u8,
            (p[1] * 255.0 + 0.5) as u8,
            (p[2] * 255.0 + 0.5) as u8,
            255,
        ]);
    }
}

fn parse_recipe(json: *const c_char) -> Result<Recipe, String> {
    match unsafe { in_str(json) } {
        None => Ok(Recipe::default()),
        Some(s) if s.trim().is_empty() => Ok(Recipe::default()),
        Some(s) => Recipe::from_json(s).map_err(|e| format!("recipe: {e}")),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn acg_last_error() -> *mut c_char {
    LAST_ERROR.with(|l| l.borrow().as_ref().map(|c| out_string(c.to_string_lossy().into_owned())))
        .unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// `s` must come from this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// Open a photo. `preview_size` is the long side of the interactive preview.
/// # Safety
/// `path` must be a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_open(path: *const c_char, preview_size: u32) -> *mut Session {
    let Some(path) = in_str(path) else { set_error("invalid path"); return std::ptr::null_mut() };
    match io::load(path) {
        Ok(full) => {
            let preview = full.downscale(preview_size.max(64) as usize);
            Box::into_raw(Box::new(Session { full, preview, rgba: Vec::new(), thumb: Vec::new() }))
        }
        Err(e) => { set_error(format!("{e:#}")); std::ptr::null_mut() }
    }
}

/// # Safety
/// `s` must come from `acg_open` and not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_close(s: *mut Session) {
    if !s.is_null() {
        drop(Box::from_raw(s));
    }
}

/// Full-resolution size.
/// # Safety
/// `s` must be a live session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_size(s: *const Session, w: *mut u32, h: *mut u32) {
    let s = &*s;
    *w = s.full.width as u32;
    *h = s.full.height as u32;
}

/// Render the preview with a recipe. Returns a pointer to RGBA8 pixels valid until the
/// next render call on this session; writes the dimensions.
/// # Safety
/// `s` must be a live session; out pointers must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_render_preview(s: *mut Session, recipe_json: *const c_char, w: *mut u32, h: *mut u32) -> *const u8 {
    let s = &mut *s;
    let r = match parse_recipe(recipe_json) { Ok(r) => r, Err(e) => { set_error(e); return std::ptr::null() } };
    let out = apply(&r, &s.preview);
    to_rgba(&out, &mut s.rgba);
    *w = out.width as u32;
    *h = out.height as u32;
    s.rgba.as_ptr()
}

/// Render a small thumbnail (long side `size`) with a recipe, for template/candidate strips.
/// Pointer valid until the next thumbnail call on this session.
/// # Safety
/// As `acg_render_preview`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_render_thumb(s: *mut Session, recipe_json: *const c_char, size: u32, w: *mut u32, h: *mut u32) -> *const u8 {
    let s = &mut *s;
    let r = match parse_recipe(recipe_json) { Ok(r) => r, Err(e) => { set_error(e); return std::ptr::null() } };
    let small = s.preview.downscale(size.max(16) as usize);
    let out = apply(&r, &small);
    to_rgba(&out, &mut s.thumb);
    *w = out.width as u32;
    *h = out.height as u32;
    s.thumb.as_ptr()
}

/// Export at full resolution. Format from the extension: .jpg (quality), .png / .tif (16-bit).
/// Returns 0 on success.
/// # Safety
/// `s` live; strings valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_export(s: *const Session, recipe_json: *const c_char, path: *const c_char, jpeg_quality: u32) -> i32 {
    let s = &*s;
    let Some(path) = in_str(path) else { set_error("invalid path"); return -1 };
    let r = match parse_recipe(recipe_json) { Ok(r) => r, Err(e) => { set_error(e); return -1 } };
    let p = Path::new(path);
    let fmt = match io::Format::from_path(p) {
        io::Format::Jpeg(_) => io::Format::Jpeg(jpeg_quality.clamp(1, 100) as u8),
        f => f,
    };
    match io::save(&apply(&r, &s.full), p, fmt) {
        Ok(()) => 0,
        Err(e) => { set_error(format!("{e:#}")); -1 }
    }
}

/// JSON: {"stats": {...}, "candidates": [recipe, ...]}
/// # Safety
/// `s` live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_auto_candidates(s: *const Session) -> *mut c_char {
    let s = &*s;
    let (stats, cands) = analysis::candidates(&s.preview);
    out_string(serde_json::json!({ "stats": stats, "candidates": cands }).to_string())
}

/// Fit a look to this photo (see `adapt`). `base_json` is the edit the look is layered
/// on (normally the auto baseline + the user's geometry). Returns
/// `{"recipe": …, "report": {"strength", "change", "notes"}}`.
/// # Safety
/// `s` live; strings valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_adapt_look(s: *const Session, base_json: *const c_char, look_json: *const c_char) -> *mut c_char {
    let s = &*s;
    let base = match parse_recipe(base_json) { Ok(r) => r, Err(e) => { set_error(e); return std::ptr::null_mut() } };
    let look = match parse_recipe(look_json) { Ok(r) => r, Err(e) => { set_error(e); return std::ptr::null_mut() } };
    let stats = analysis::analyze(&s.preview);
    // Geometry changes framing only; measure on the framed preview.
    let framed = if base.has_geometry() { crate::pipeline::geometry(&base, &s.preview) } else { s.preview.clone() };
    let geo_free = Recipe { angle: 0.0, rotate90: 0, flip_h: false, flip_v: false, crop: None, ..base.clone() };
    let (mut r, rep) = crate::adapt::adapt(&look, &geo_free, &stats, &framed);
    r.angle = base.angle;
    r.rotate90 = base.rotate90;
    r.flip_h = base.flip_h;
    r.flip_v = base.flip_v;
    r.crop = base.crop;
    out_string(serde_json::json!({ "recipe": r, "report": rep }).to_string())
}

/// JSON array of built-in templates.
#[unsafe(no_mangle)]
pub extern "C" fn acg_presets() -> *mut c_char {
    out_string(serde_json::to_string(&presets::all()).unwrap_or_default())
}

/// Build a recipe that makes the photo (as edited by `base_json`) look like the
/// reference image. Returns the combined recipe JSON (base + matching LUT).
/// # Safety
/// `s` live; strings valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_match_reference(s: *const Session, base_json: *const c_char, reference_path: *const c_char, strength: f32) -> *mut c_char {
    let s = &*s;
    let Some(rp) = in_str(reference_path) else { set_error("invalid path"); return std::ptr::null_mut() };
    let base = match parse_recipe(base_json) { Ok(r) => r, Err(e) => { set_error(e); return std::ptr::null_mut() } };
    let reference = match io::load(rp) { Ok(i) => i, Err(e) => { set_error(format!("{e:#}")); return std::ptr::null_mut() } };
    let src = apply(&Recipe { lut: None, ..base.clone() }, &s.preview);
    let ref_disp = io::linear_to_display(&reference.downscale(800));
    let m = matching::match_reference(&src, &ref_disp, strength);
    let mut out = base;
    out.name = "참조 스타일".into();
    out.lut = m.lut;
    out.lut_strength = 1.0;
    out_string(out.to_json())
}

/// Encode a small JPEG of the current photo (with recipe) for sending to an AI model.
/// Returns base64 text.
/// # Safety
/// `s` live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_ai_thumbnail_b64(s: *const Session, recipe_json: *const c_char, size: u32) -> *mut c_char {
    let s = &*s;
    let r = match parse_recipe(recipe_json) { Ok(r) => r, Err(e) => { set_error(e); return std::ptr::null_mut() } };
    let out = apply(&r, &s.preview.downscale(size.max(64) as usize));
    let rgb: Vec<u8> = out.data.iter().flat_map(|p| p.map(|v| (v * 255.0 + 0.5) as u8)).collect();
    let mut buf = Vec::new();
    use image::ImageEncoder;
    if let Err(e) = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 85)
        .write_image(&rgb, out.width as u32, out.height as u32, image::ExtendedColorType::Rgb8)
    {
        set_error(e);
        return std::ptr::null_mut();
    }
    out_string(base64(&buf))
}

/// JSON photo statistics (for AI prompts and UI).
/// # Safety
/// `s` live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_analyze(s: *const Session) -> *mut c_char {
    let s = &*s;
    out_string(serde_json::to_string(&analysis::analyze(&s.preview)).unwrap_or_default())
}

/// Load a .cube LUT file as a template recipe (JSON).
/// # Safety
/// `path` must be a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_load_cube(path: *const c_char) -> *mut c_char {
    let Some(path) = in_str(path) else { set_error("invalid path"); return std::ptr::null_mut() };
    let text = match std::fs::read_to_string(path) { Ok(t) => t, Err(e) => { set_error(e); return std::ptr::null_mut() } };
    match crate::lut::Lut3d::parse_cube(&text) {
        Ok(lut) => {
            let name = Path::new(path).file_stem().and_then(|s| s.to_str()).unwrap_or("LUT").to_string();
            out_string(Recipe { lut: Some(lut), lut_strength: 1.0, ..Recipe::named(&name) }.to_json())
        }
        Err(e) => { set_error(format!("{e:#}")); std::ptr::null_mut() }
    }
}

fn base64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::with_capacity(data.len().div_ceil(3) * 4);
    for c in data.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        s.push(T[(n >> 18) as usize & 63] as char);
        s.push(T[(n >> 12) as usize & 63] as char);
        s.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        s.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_known() {
        assert_eq!(base64(b"Man"), "TWFu");
        assert_eq!(base64(b"Ma"), "TWE=");
        assert_eq!(base64(b"M"), "TQ==");
    }

    #[test]
    fn session_roundtrip() {
        let dir = std::env::temp_dir().join("acg_ffi_test");
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("in.png");
        let mut img = Image::new(128, 96);
        for (i, p) in img.data.iter_mut().enumerate() {
            let v = (i % 128) as f32 / 128.0;
            *p = [v, 0.3, 1.0 - v];
        }
        io::save(&io::linear_to_display(&img), &src, io::Format::Png16).unwrap();
        let cpath = CString::new(src.to_str().unwrap()).unwrap();
        unsafe {
            let s = acg_open(cpath.as_ptr(), 64);
            assert!(!s.is_null());
            let (mut w, mut h) = (0u32, 0u32);
            let recipe = CString::new(presets::film().to_json()).unwrap();
            let px = acg_render_preview(s, recipe.as_ptr(), &mut w, &mut h);
            assert!(!px.is_null());
            assert_eq!((w, h), (64, 48));
            let c = acg_auto_candidates(s);
            let v: serde_json::Value = serde_json::from_str(CStr::from_ptr(c).to_str().unwrap()).unwrap();
            assert!(v["candidates"].as_array().unwrap().len() >= 5);
            acg_string_free(c);
            let m = acg_match_reference(s, std::ptr::null(), cpath.as_ptr(), 0.8);
            assert!(!m.is_null());
            acg_string_free(m);
            let out = CString::new(dir.join("out.tif").to_str().unwrap()).unwrap();
            assert_eq!(acg_export(s, recipe.as_ptr(), out.as_ptr(), 100), 0);
            acg_close(s);
        }
    }
}

/// Photo organizer: measure photos. `paths_json` is a JSON array of paths; `cache_dir`
/// (may be null) receives JPEG previews for TIFFs. Returns {"metrics":[...],"errors":[...]}.
/// # Safety
/// Strings must be valid C strings or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_cull_measure(paths_json: *const c_char, cache_dir: *const c_char) -> *mut c_char {
    let paths: Vec<String> = match in_str(paths_json).map(serde_json::from_str) {
        Some(Ok(p)) => p,
        _ => { set_error("paths: invalid JSON"); return std::ptr::null_mut() }
    };
    let (metrics, errors) = crate::cull::measure_all(&paths, in_str(cache_dir));
    out_string(serde_json::json!({ "metrics": metrics, "errors": errors }).to_string())
}

/// Photo organizer: group measured photos into bursts and pick the best frames.
/// Returns a JSON array of groups.
/// # Safety
/// `metrics_json` must be a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_cull_group(metrics_json: *const c_char) -> *mut c_char {
    let ms: Vec<crate::cull::Metrics> = match in_str(metrics_json).map(serde_json::from_str) {
        Some(Ok(m)) => m,
        Some(Err(e)) => { set_error(format!("metrics: {e}")); return std::ptr::null_mut() }
        None => { set_error("metrics: null"); return std::ptr::null_mut() }
    };
    out_string(serde_json::to_string(&crate::cull::group(ms)).unwrap_or_default())
}

/// Finishing check for an automatic edit (see `polish`): fixes clipped highlights,
/// crushed shadows, over-saturated colors and unnatural skin. `base_json` is the
/// physical baseline the edit was built on (may be empty).
/// Returns `{"recipe": …, "notes": ["…"]}`.
/// # Safety
/// `s` live; strings valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acg_polish(s: *const Session, recipe_json: *const c_char, base_json: *const c_char) -> *mut c_char {
    let s = &*s;
    let r = match parse_recipe(recipe_json) { Ok(r) => r, Err(e) => { set_error(e); return std::ptr::null_mut() } };
    let base = match in_str(base_json) {
        Some(b) if !b.trim().is_empty() => match Recipe::from_json(b) { Ok(b) => Some(b), Err(e) => { set_error(e); return std::ptr::null_mut() } },
        _ => None,
    };
    let stats = analysis::analyze(&s.preview);
    let (out, notes) = crate::polish::polish(&r, base.as_ref(), &s.preview, &stats);
    out_string(serde_json::json!({ "recipe": out, "notes": notes }).to_string())
}
