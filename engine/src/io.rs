//! Image loading and lossless/high-quality export.

use std::io::BufWriter;
use std::path::Path;

use anyhow::{Context, Result};
use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::{CompressionType, FilterType, PngEncoder};
use image::codecs::tiff::TiffEncoder;
use image::{DynamicImage, ExtendedColorType, ImageDecoder, ImageEncoder, ImageReader};
use rayon::prelude::*;

use crate::color::{linear_to_srgb, srgb_to_linear};
use crate::pipeline::Image;

/// Load an image as linear-light float RGB, honoring EXIF orientation.
/// 8- and 16-bit sources keep their full precision.
pub fn load(path: impl AsRef<Path>) -> Result<Image> {
    let path = path.as_ref();
    let mut decoder = ImageReader::open(path)
        .with_context(|| format!("open {}", path.display()))?
        .with_guessed_format()?
        .into_decoder()?;
    let orientation = decoder.orientation()?;
    let mut img = DynamicImage::from_decoder(decoder)?;
    img.apply_orientation(orientation);
    Ok(from_dynamic(&img))
}

pub fn from_dynamic(img: &DynamicImage) -> Image {
    let rgb = img.to_rgb32f();
    let (w, h) = (rgb.width() as usize, rgb.height() as usize);
    let data = rgb
        .as_raw()
        .par_chunks(3)
        .map(|p| [srgb_to_linear(p[0]), srgb_to_linear(p[1]), srgb_to_linear(p[2])])
        .collect();
    Image { width: w, height: h, data }
}

/// Convert a linear image to display encoding without other edits.
pub fn linear_to_display(img: &Image) -> Image {
    Image {
        width: img.width,
        height: img.height,
        data: img
            .data
            .par_iter()
            .map(|p| [linear_to_srgb(p[0].clamp(0.0, 1.0)), linear_to_srgb(p[1].clamp(0.0, 1.0)), linear_to_srgb(p[2].clamp(0.0, 1.0))])
            .collect(),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    /// 8-bit JPEG at the given quality (1..=100). Dithered to prevent banding.
    Jpeg(u8),
    /// 16-bit lossless PNG.
    Png16,
    /// 16-bit lossless TIFF.
    Tiff16,
}

impl Format {
    pub fn from_path(path: &Path) -> Format {
        match path.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase()).as_deref() {
            Some("png") => Format::Png16,
            Some("tif") | Some("tiff") => Format::Tiff16,
            _ => Format::Jpeg(100),
        }
    }
}

fn dither(x: usize, y: usize) -> f32 {
    // Triangular-ish dither from two hashes, ±1 LSB.
    let h = |a: u32| {
        let mut v = a.wrapping_mul(0x9e37_79b9);
        v ^= v >> 15;
        v = v.wrapping_mul(0x85eb_ca6b);
        v ^= v >> 13;
        (v & 0xffff) as f32 / 65535.0
    };
    let i = (y * 7919 + x) as u32;
    h(i) + h(i ^ 0x5bd1_e995) - 1.0
}

/// Save a display-encoded image.
pub fn save(img: &Image, path: impl AsRef<Path>, format: Format) -> Result<()> {
    let path = path.as_ref();
    let (w, h) = (img.width as u32, img.height as u32);
    let file = BufWriter::new(std::fs::File::create(path).with_context(|| format!("create {}", path.display()))?);
    match format {
        Format::Jpeg(q) => {
            let buf: Vec<u8> = img
                .data
                .par_iter()
                .enumerate()
                .flat_map_iter(|(i, p)| {
                    let d = dither(i % img.width, i / img.width) * 0.5;
                    p.map(|v| (v * 255.0 + 0.5 + d).clamp(0.0, 255.0) as u8)
                })
                .collect();
            JpegEncoder::new_with_quality(file, q.clamp(1, 100)).write_image(&buf, w, h, ExtendedColorType::Rgb8)?;
        }
        Format::Png16 | Format::Tiff16 => {
            let buf: Vec<u16> = img
                .data
                .par_iter()
                .flat_map_iter(|p| p.map(|v| (v * 65535.0 + 0.5).clamp(0.0, 65535.0) as u16))
                .collect();
            let bytes: &[u8] = bytemuck_cast(&buf);
            if format == Format::Png16 {
                // PNG stores 16-bit big-endian; the encoder expects native-endian input.
                PngEncoder::new_with_quality(file, CompressionType::Default, FilterType::Adaptive)
                    .write_image(bytes, w, h, ExtendedColorType::Rgb16)?;
            } else {
                TiffEncoder::new(file).write_image(bytes, w, h, ExtendedColorType::Rgb16)?;
            }
        }
    }
    Ok(())
}

fn bytemuck_cast(v: &[u16]) -> &[u8] {
    // SAFETY: u16 has no padding and u8 has alignment 1.
    unsafe { std::slice::from_raw_parts(v.as_ptr() as *const u8, v.len() * 2) }
}
