//! Streaming opaque redaction for one source image.

use std::path::Path;

use image::{imageops, RgbImage};

use crate::encoder::{
    buffered_output_bytes, ensure_pipeline_budget, open_sink, paths_alias, write_atomic,
    ExportFormat,
};
use crate::error::{StitchError, StitchResult};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RedactionRect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    pub color: [u8; 3],
    pub style: RedactionStyle,
    pub adaptive: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RedactionStyle {
    Solid,
    Blur,
}

const BLUR_SIGMA: f32 = 8.0;

/// Re-encode an image with opaque or blurred rectangular masks.
pub fn redact_to_file(
    source: &Path,
    masks: &[RedactionRect],
    format: ExportFormat,
    output: &Path,
) -> StitchResult<(u32, u32)> {
    if paths_alias(source, output)? {
        return Err(StitchError::Export("输入文件和输出文件不能相同".into()));
    }
    write_atomic(output, |temporary| {
        redact_to_path(source, masks, format, temporary)
    })
}

fn redact_to_path(
    source: &Path,
    masks: &[RedactionRect],
    format: ExportFormat,
    output: &Path,
) -> StitchResult<(u32, u32)> {
    let info = crate::image::load_info(source)?;
    let source_bytes = crate::image::rgb_size(&info);
    let buffered_bytes = buffered_output_bytes(format, info.width, info.height)?;
    let blur_bytes = if masks.iter().any(|mask| mask.style == RedactionStyle::Blur) {
        source_bytes
    } else {
        0
    };
    ensure_pipeline_budget(
        source_bytes
            .saturating_add(blur_bytes)
            .saturating_add(buffered_bytes),
        "打码导出",
    )?;
    let image = crate::image::load_rgb(source)?;
    let (width, height) = image.dimensions();
    validate_masks(masks, width, height)?;
    let blurred = build_blurred_image(&image, masks);
    let colors = resolve_mask_colors(&image, masks);
    let mut sink = open_sink(format, output, width, height)?;
    for y in 0..height {
        let row_start = y as usize * width as usize * 3;
        let row_end = row_start + width as usize * 3;
        let mut row = image.as_raw()[row_start..row_end].to_vec();
        for (index, mask) in masks.iter().enumerate() {
            apply_mask_to_row(&mut row, y, mask, colors[index], blurred.as_ref());
        }
        sink.write_row(&row)?;
    }
    sink.finish()?;
    Ok((width, height))
}

fn build_blurred_image(image: &RgbImage, masks: &[RedactionRect]) -> Option<RgbImage> {
    masks
        .iter()
        .any(|mask| mask.style == RedactionStyle::Blur)
        .then(|| imageops::blur(image, BLUR_SIGMA))
}

fn resolve_mask_colors(image: &RgbImage, masks: &[RedactionRect]) -> Vec<[u8; 3]> {
    masks
        .iter()
        .map(|mask| {
            if mask.adaptive && mask.style == RedactionStyle::Solid {
                average_color(image, mask)
            } else {
                mask.color
            }
        })
        .collect()
}

fn average_color(image: &RgbImage, mask: &RedactionRect) -> [u8; 3] {
    let mut sum = [0u64; 3];
    for y in mask.y..mask.y + mask.h {
        for x in mask.x..mask.x + mask.w {
            let pixel = image.get_pixel(x, y).0;
            for channel in 0..3 {
                sum[channel] += u64::from(pixel[channel]);
            }
        }
    }
    let count = u64::from(mask.w) * u64::from(mask.h);
    [
        (sum[0] / count) as u8,
        (sum[1] / count) as u8,
        (sum[2] / count) as u8,
    ]
}

fn apply_mask_to_row(
    row: &mut [u8],
    y: u32,
    mask: &RedactionRect,
    color: [u8; 3],
    blurred: Option<&RgbImage>,
) {
    if y < mask.y || y >= mask.y + mask.h {
        return;
    }
    let start = mask.x as usize * 3;
    let end = (mask.x + mask.w) as usize * 3;
    for (offset, pixel) in row[start..end].chunks_exact_mut(3).enumerate() {
        let replacement = match mask.style {
            RedactionStyle::Solid => color,
            RedactionStyle::Blur => {
                blurred
                    .expect("blurred image must exist for blur masks")
                    .get_pixel(mask.x + offset as u32, y)
                    .0
            }
        };
        pixel.copy_from_slice(&replacement);
    }
}

fn validate_masks(masks: &[RedactionRect], width: u32, height: u32) -> StitchResult<()> {
    for mask in masks {
        if mask.w == 0 || mask.h == 0 {
            return Err(StitchError::Export("遮罩区域不能为空".into()));
        }
        let right = mask.x.saturating_add(mask.w);
        let bottom = mask.y.saturating_add(mask.h);
        if mask.x >= width || mask.y >= height || right > width || bottom > height {
            return Err(StitchError::Export(format!(
                "遮罩区域超出图片范围: x={}, y={}, w={}, h={}, image={}x{}",
                mask.x, mask.y, mask.w, mask.h, width, height
            )));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgb, RgbImage};

    fn temp_path(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "pixelforge_redaction_{}_{name}",
            std::process::id()
        ))
    }

    fn write_source(path: &Path) {
        let image = RgbImage::from_fn(4, 3, |x, y| Rgb([x as u8, y as u8, 9]));
        image.save(path).unwrap();
    }

    #[test]
    fn covers_requested_pixels_and_preserves_dimensions() {
        let source = temp_path("source.png");
        let output = temp_path("output.png");
        write_source(&source);
        redact_to_file(
            &source,
            &[RedactionRect {
                x: 1,
                y: 1,
                w: 2,
                h: 1,
                color: [0, 0, 0],
                style: RedactionStyle::Solid,
                adaptive: false,
            }],
            ExportFormat::Png,
            &output,
        )
        .unwrap();
        let image = image::open(&output).unwrap().into_rgb8();
        assert_eq!(image.dimensions(), (4, 3));
        assert_eq!(image.get_pixel(1, 1).0, [0, 0, 0]);
        assert_eq!(image.get_pixel(2, 1).0, [0, 0, 0]);
        assert_ne!(image.get_pixel(0, 1).0, [0, 0, 0]);
        std::fs::remove_file(source).unwrap();
        std::fs::remove_file(output).unwrap();
    }

    #[test]
    fn rejects_zero_or_out_of_bounds_masks() {
        let source = temp_path("invalid_source.png");
        let output = temp_path("invalid_output.png");
        write_source(&source);
        let invalid = [
            RedactionRect {
                x: 0,
                y: 0,
                w: 0,
                h: 1,
                color: [0, 0, 0],
                style: RedactionStyle::Solid,
                adaptive: false,
            },
            RedactionRect {
                x: 3,
                y: 0,
                w: 2,
                h: 1,
                color: [0, 0, 0],
                style: RedactionStyle::Solid,
                adaptive: false,
            },
        ];
        assert!(redact_to_file(&source, &invalid[..1], ExportFormat::Png, &output).is_err());
        assert!(redact_to_file(&source, &invalid[1..], ExportFormat::Png, &output).is_err());
        std::fs::remove_file(source).unwrap();
    }

    #[test]
    fn rejects_output_alias_without_truncating_source() {
        let source = temp_path("alias_source.png");
        write_source(&source);
        let before = std::fs::read(&source).unwrap();
        let mask = RedactionRect {
            x: 0,
            y: 0,
            w: 1,
            h: 1,
            color: [0, 0, 0],
            style: RedactionStyle::Solid,
            adaptive: false,
        };
        assert!(redact_to_file(&source, &[mask], ExportFormat::Png, &source).is_err());
        assert_eq!(std::fs::read(&source).unwrap(), before);
        std::fs::remove_file(source).unwrap();
    }

    #[test]
    fn adaptive_solid_uses_the_source_region_average() {
        let source = temp_path("adaptive_source.png");
        let output = temp_path("adaptive_output.png");
        write_source(&source);
        redact_to_file(
            &source,
            &[RedactionRect {
                x: 0,
                y: 0,
                w: 2,
                h: 1,
                color: [255, 255, 255],
                style: RedactionStyle::Solid,
                adaptive: true,
            }],
            ExportFormat::Png,
            &output,
        )
        .unwrap();
        let image = image::open(&output).unwrap().into_rgb8();
        assert_eq!(image.get_pixel(0, 0).0, [0, 0, 9]);
        assert_eq!(image.get_pixel(1, 0).0, [0, 0, 9]);
        std::fs::remove_file(source).unwrap();
        std::fs::remove_file(output).unwrap();
    }

    #[test]
    fn blur_replaces_pixels_with_blurred_source_values() {
        let source = temp_path("blur_source.png");
        let output = temp_path("blur_output.png");
        let image = RgbImage::from_fn(5, 5, |x, y| {
            if x == 2 && y == 2 {
                image::Rgb([255, 0, 0])
            } else {
                image::Rgb([0, 0, 0])
            }
        });
        image.save(&source).unwrap();
        redact_to_file(
            &source,
            &[RedactionRect {
                x: 1,
                y: 1,
                w: 3,
                h: 3,
                color: [0, 0, 0],
                style: RedactionStyle::Blur,
                adaptive: false,
            }],
            ExportFormat::Png,
            &output,
        )
        .unwrap();
        let result = image::open(&output).unwrap().into_rgb8();
        assert_eq!(result.dimensions(), (5, 5));
        assert!(result.get_pixel(2, 2).0[0] < 255);
        std::fs::remove_file(source).unwrap();
        std::fs::remove_file(output).unwrap();
    }
}
