//! Image loading, downsampling and luminance extraction.
//!
//! All analysis works on a compact in-memory representation: a grayscale
//! [`LumaImage`] plus an optional gradient magnitude plane. This keeps memory
//! usage low for phone-sized screenshots (typical 1080x2400) while the
//! original images stay on disk and are only decoded lazily during export.

use image::metadata::Orientation;
use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader, RgbImage};

use crate::error::{StitchError, StitchResult};

const MAX_DECODED_IMAGE_BYTES: u64 = 96 * 1024 * 1024;
const RGB_BYTES_PER_PIXEL: u64 = 3;

/// A grayscale image with a fixed max side used for analysis.
///
/// Pixels are stored in `u8`, row-major, top-to-bottom.
#[derive(Debug, Clone)]
pub struct LumaImage {
    pub width: u32,
    pub height: u32,
    pub data: Vec<u8>,
}

impl LumaImage {
    /// Build from raw luminance data. `data.len()` must equal `width * height`.
    pub fn new(width: u32, height: u32, data: Vec<u8>) -> StitchResult<Self> {
        let expected = (width as usize) * (height as usize);
        if data.len() != expected {
            return Err(crate::internal_err!(
                "luma buffer size mismatch: got {}, expected {}",
                data.len(),
                expected
            ));
        }
        Ok(Self {
            width,
            height,
            data,
        })
    }

    /// Look up a pixel with bounds checking.
    #[inline]
    pub fn get(&self, x: u32, y: u32) -> Option<u8> {
        if x < self.width && y < self.height {
            Some(self.data[(y * self.width + x) as usize])
        } else {
            None
        }
    }
}

/// A luminance image plus a Sobel gradient magnitude plane of the same size.
#[derive(Debug, Clone)]
pub struct GradientImage {
    pub luma: LumaImage,
    pub grad: LumaImage,
}

/// Downsample factor applied before overlap search. Kept as a struct so the
/// caller can scale detected offsets back to full resolution.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Scale {
    /// Factor applied to both axes (>= 1).
    pub factor: u32,
}

impl Scale {
    pub const fn identity() -> Self {
        Self { factor: 1 }
    }

    /// Map a coordinate in downsampled space back to original space.
    #[inline]
    pub fn unscale(&self, v: u32) -> u32 {
        v * self.factor
    }
}

/// Image metadata read without decoding pixel data.
#[derive(Debug, Clone, Copy)]
pub struct ImageInfo {
    pub width: u32,
    pub height: u32,
    pub format: ImageFormat,
}

/// Load metadata only (cheap, used by the session model).
pub fn load_info(path: &std::path::Path) -> StitchResult<ImageInfo> {
    let reader = ImageReader::open(path)
        .map_err(|e| StitchError::Decode(e.to_string()))?
        .with_guessed_format()
        .map_err(|e| StitchError::Decode(e.to_string()))?;
    let format = reader
        .format()
        .ok_or_else(|| StitchError::Decode(format!("无法识别格式: {}", path.display())))?;
    let mut decoder = reader
        .into_decoder()
        .map_err(|e| StitchError::Decode(e.to_string()))?;
    let orientation = decoder
        .orientation()
        .map_err(|e| StitchError::Decode(e.to_string()))?;
    ensure_decode_budget(path, decoder.total_bytes())?;
    let dims = oriented_dimensions(decoder.dimensions(), orientation);
    Ok(ImageInfo {
        width: dims.0,
        height: dims.1,
        format,
    })
}

/// Number of bytes required to hold the decoded image in RGBA.
pub fn rgba_size(info: &ImageInfo) -> u64 {
    (info.width as u64) * (info.height as u64) * 4
}

/// Number of bytes required to hold the decoded image in RGB8.
pub fn rgb_size(info: &ImageInfo) -> u64 {
    (info.width as u64)
        .saturating_mul(info.height as u64)
        .saturating_mul(RGB_BYTES_PER_PIXEL)
}

/// Decode an image, orient it upright (EXIF) and convert to grayscale.
pub fn load_luma(path: &std::path::Path) -> StitchResult<LumaImage> {
    let img = decode_oriented(path)?;
    let img = img.into_rgb8();
    Ok(luma_from_rgb(&img))
}

/// Convert an RGB image to luminance using BT.601 weights.
pub fn luma_from_rgb(rgb: &RgbImage) -> LumaImage {
    let (w, h) = rgb.dimensions();
    let mut data = Vec::with_capacity((w * h) as usize);
    for px in rgb.pixels() {
        let (r, g, b) = (px[0] as u32, px[1] as u32, px[2] as u32);
        // BT.601: 0.299 R + 0.587 G + 0.114 B
        let y = (r * 299 + g * 587 + b * 114) / 1000;
        data.push(y as u8);
    }
    LumaImage::new(w, h, data).expect("buffer size matches dimensions")
}

/// Apply a uniform box downsample by `factor` (averaging). The result is
/// rounded up so that the analysis image never loses the bottom rows.
pub fn downsample(src: &LumaImage, factor: u32) -> LumaImage {
    if factor <= 1 {
        return src.clone();
    }
    let w = src.width.div_ceil(factor);
    let h = src.height.div_ceil(factor);
    let mut data = vec![0u8; (w * h) as usize];
    for y in 0..h {
        for x in 0..w {
            let mut sum = 0u32;
            let mut n = 0u32;
            for dy in 0..factor {
                for dx in 0..factor {
                    let sx = x * factor + dx;
                    let sy = y * factor + dy;
                    if let Some(v) = src.get(sx, sy) {
                        sum += v as u32;
                        n += 1;
                    }
                }
            }
            data[(y * w + x) as usize] = (sum / n.max(1)) as u8;
        }
    }
    LumaImage::new(w, h, data).expect("buffer size matches dimensions")
}

/// Compute a Sobel gradient magnitude plane for `luma`.
pub fn sobel(luma: &LumaImage) -> LumaImage {
    let (w, h) = (luma.width, luma.height);
    let mut data = vec![0u8; (w * h) as usize];
    for y in 1..h.saturating_sub(1) {
        for x in 1..w.saturating_sub(1) {
            let gx = luma.get(x + 1, y - 1).unwrap_or(0) as i32
                + 2 * luma.get(x + 1, y).unwrap_or(0) as i32
                + luma.get(x + 1, y + 1).unwrap_or(0) as i32
                - luma.get(x - 1, y - 1).unwrap_or(0) as i32
                - 2 * luma.get(x - 1, y).unwrap_or(0) as i32
                - luma.get(x - 1, y + 1).unwrap_or(0) as i32;
            let gy = luma.get(x - 1, y + 1).unwrap_or(0) as i32
                + 2 * luma.get(x, y + 1).unwrap_or(0) as i32
                + luma.get(x + 1, y + 1).unwrap_or(0) as i32
                - luma.get(x - 1, y - 1).unwrap_or(0) as i32
                - 2 * luma.get(x, y - 1).unwrap_or(0) as i32
                - luma.get(x + 1, y - 1).unwrap_or(0) as i32;
            let mag = ((gx * gx + gy * gy) as f32).sqrt().min(255.0) as u8;
            data[(y * w + x) as usize] = mag;
        }
    }
    LumaImage::new(w, h, data).expect("buffer size matches dimensions")
}

/// Compute the gradient magnitude of a colour image directly (used when the
/// caller already has the decoded RGB image at hand).
pub fn gradient_of(rgb: &RgbImage) -> GradientImage {
    let luma = luma_from_rgb(rgb);
    let grad = sobel(&luma);
    GradientImage { luma, grad }
}

/// Decode a full RGB image (used by fixed-element analysis and export).
pub fn load_rgb(path: &std::path::Path) -> StitchResult<RgbImage> {
    let img = decode_oriented(path)?;
    match img {
        DynamicImage::ImageRgb8(rgb) => Ok(rgb),
        other => Ok(other.into_rgb8()),
    }
}

fn decode_oriented(path: &std::path::Path) -> StitchResult<DynamicImage> {
    let reader = ImageReader::open(path)
        .map_err(|e| StitchError::Decode(e.to_string()))?
        .with_guessed_format()
        .map_err(|e| StitchError::Decode(e.to_string()))?;
    let mut decoder = reader
        .into_decoder()
        .map_err(|e| StitchError::Decode(e.to_string()))?;
    let orientation = decoder
        .orientation()
        .map_err(|e| StitchError::Decode(e.to_string()))?;
    ensure_decode_budget(path, decoder.total_bytes())?;
    let mut image =
        DynamicImage::from_decoder(decoder).map_err(|e| StitchError::Decode(e.to_string()))?;
    image.apply_orientation(orientation);
    Ok(image)
}

fn oriented_dimensions(dimensions: (u32, u32), orientation: Orientation) -> (u32, u32) {
    if matches!(
        orientation,
        Orientation::Rotate90
            | Orientation::Rotate270
            | Orientation::Rotate90FlipH
            | Orientation::Rotate270FlipH
    ) {
        (dimensions.1, dimensions.0)
    } else {
        dimensions
    }
}

fn ensure_decode_budget(path: &std::path::Path, bytes: u64) -> StitchResult<()> {
    if bytes > MAX_DECODED_IMAGE_BYTES {
        return Err(StitchError::InvalidImage(format!(
            "图片解码内存需求过大: {} bytes，上限 {} bytes ({})",
            bytes,
            MAX_DECODED_IMAGE_BYTES,
            path.display()
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_luma() -> LumaImage {
        // 4x4 checker-ish pattern with a strong vertical edge.
        let data = vec![
            10, 10, 200, 200, //
            10, 10, 200, 200, //
            10, 10, 200, 200, //
            10, 10, 200, 200, //
        ];
        LumaImage::new(4, 4, data).unwrap()
    }

    #[test]
    fn luma_get_bounds_check() {
        let l = test_luma();
        assert_eq!(l.get(0, 0), Some(10));
        assert_eq!(l.get(3, 3), Some(200));
        assert_eq!(l.get(4, 0), None);
        assert_eq!(l.get(0, 4), None);
    }

    #[test]
    fn luma_size_mismatch_rejected() {
        assert!(LumaImage::new(4, 4, vec![0u8; 15]).is_err());
    }

    #[test]
    fn downsample_averages() {
        let l = test_luma();
        let d = downsample(&l, 2);
        assert_eq!((d.width, d.height), (2, 2));
        // Each 2x2 block: (10+10+10+10)/4 = 10, (200+200+200+200)/4 = 200.
        assert_eq!(d.get(0, 0), Some(10));
        assert_eq!(d.get(1, 0), Some(200));
        assert_eq!(d.get(0, 1), Some(10));
        assert_eq!(d.get(1, 1), Some(200));
    }

    #[test]
    fn downsample_rounds_up() {
        let l = LumaImage::new(5, 5, vec![0u8; 25]).unwrap();
        let d = downsample(&l, 2);
        assert_eq!((d.width, d.height), (3, 3));
    }

    #[test]
    fn sobel_detects_vertical_edge() {
        // 8x8: left half 10, right half 200 -> vertical edge at x=4.
        let mut data = vec![0u8; 64];
        for y in 0..8 {
            for x in 0..8 {
                data[y * 8 + x] = if x < 4 { 10 } else { 200 };
            }
        }
        let l = LumaImage::new(8, 8, data).unwrap();
        let g = sobel(&l);
        // At the vertical edge (x=4), magnitude should be high.
        let mag = g.get(4, 4).unwrap();
        assert!(mag > 100, "edge magnitude was {mag}");
        // Interior flat region (away from the edge) is ~0.
        let flat = g.get(1, 4).unwrap();
        assert!(flat < 10, "flat magnitude was {flat}");
    }

    #[test]
    fn luma_from_rgb_matches_bt601() {
        let rgb = RgbImage::from_fn(1, 1, |_, _| image::Rgb([255, 0, 0]));
        let l = luma_from_rgb(&rgb);
        assert_eq!(l.get(0, 0), Some(76)); // 0.299 * 255 ≈ 76
    }

    #[test]
    fn exif_rotation_is_applied_to_metadata_and_pixels() {
        let path =
            std::env::temp_dir().join(format!("stitch_exif_{}_rotate.jpg", std::process::id()));
        let image = RgbImage::from_fn(3, 2, |x, y| image::Rgb([x as u8, y as u8, 0]));
        let mut jpeg = Vec::new();
        jpeg_encoder::Encoder::new(&mut jpeg, 100)
            .encode(
                image.as_raw(),
                image.width() as u16,
                image.height() as u16,
                jpeg_encoder::ColorType::Rgb,
            )
            .unwrap();
        let mut bytes = vec![0xFF, 0xD8];
        bytes.extend_from_slice(&exif_orientation_segment(6));
        bytes.extend_from_slice(&jpeg[2..]);
        std::fs::write(&path, bytes).unwrap();

        let info = load_info(&path).unwrap();
        assert_eq!((info.width, info.height), (2, 3));
        assert_eq!(load_rgb(&path).unwrap().dimensions(), (2, 3));
        let luma = load_luma(&path).unwrap();
        assert_eq!((luma.width, luma.height), (2, 3));
        std::fs::remove_file(path).ok();
    }

    fn exif_orientation_segment(orientation: u16) -> Vec<u8> {
        let exif = [
            b'E',
            b'x',
            b'i',
            b'f',
            0,
            0,
            b'I',
            b'I',
            42,
            0,
            8,
            0,
            0,
            0,
            1,
            0,
            0x12,
            0x01,
            3,
            0,
            1,
            0,
            0,
            0,
            orientation as u8,
            (orientation >> 8) as u8,
            0,
            0,
            0,
            0,
            0,
            0,
        ];
        let length = (exif.len() + 2) as u16;
        let mut segment = vec![0xFF, 0xE1, (length >> 8) as u8, length as u8];
        segment.extend_from_slice(&exif);
        segment
    }
}
