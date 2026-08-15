//! Streaming composition: layout planning and block-wise export.
//!
//! The output image is assembled row by row in blocks. Only the few source
//! images touching the current block are decoded at a time, so peak memory
//! stays bounded regardless of the total output height.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use image::RgbImage;

use crate::encoder::{
    buffered_output_bytes, ensure_pipeline_budget, open_sink, paths_alias, write_atomic,
    ExportFormat,
};
use crate::error::{StitchError, StitchResult};

/// Number of output rows processed per block.
const BLOCK_ROWS: u32 = 128;
/// Hard safety cap on output pixels.
const MAX_OUTPUT_PIXELS: u64 = 400_000_000;
const MIN_SCALE_PERCENT: u32 = 1;
const MAX_SCALE_PERCENT: u32 = 100;

/// Seam between two consecutive screenshots (full-resolution).
#[derive(Debug, Clone, Copy)]
pub struct SeamEntry {
    /// Horizontal offset of the later image relative to the earlier one.
    pub dx: i32,
    /// Row of the earlier image where the later image starts.
    pub dy: u32,
}

/// Full export configuration for a session.
#[derive(Debug, Clone)]
pub struct ComposeConfig {
    pub format: ExportFormat,
    /// Output scale relative to the source screenshots, in percent.
    pub scale_percent: u32,
    /// One seam per adjacent pair; length must be `n - 1`.
    pub seams: Vec<SeamEntry>,
    /// Top crop heights per image. The first item is the status-bar height;
    /// later items are the repeated app-header heights.
    pub top_bars: Vec<u32>,
    /// Bottom fixed-bar heights per image. The final bar is emitted as a
    /// preserved tail so the chat box and system navigation remain visible.
    pub bottom_bars: Vec<u32>,
    /// Blank content rows immediately above the final bottom bar.
    pub last_bottom_whitespace: u32,
    /// Drop the first image's status bar from the output.
    pub remove_first_status_bar: bool,
    /// Drop the last image's bottom whitespace from the output.
    pub trim_last_bottom_whitespace: bool,
    /// Keep a small edge from the last image's bottom whitespace.
    pub retained_bottom_edge: u32,
}

/// Precomputed output layout.
#[derive(Debug, Clone)]
pub struct ComposePlan {
    pub width: u32,
    pub height: u32,
    pub source_width: u32,
    pub source_height: u32,
    pub scale_percent: u32,
    /// Horizontal placement of each image in the output canvas.
    /// Positive analyzer dx moves the later image left to align it.
    pub x_offsets: Vec<i64>,
    /// Output y-offset of each image's first emitted row.
    pub offsets: Vec<u32>,
    /// Number of rows each image contributes to the output.
    pub out_rows: Vec<u32>,
    /// Rows skipped at the top of each image (crop).
    pub crop_top: Vec<u32>,
    /// Rows skipped at the bottom of each image (crop).
    pub crop_bottom: Vec<u32>,
    /// Main rows emitted from the final image before its preserved tail.
    pub last_main_rows: u32,
    /// Start row of the preserved final bottom bar in source coordinates.
    pub last_tail_start: u32,
    /// Number of rows in the preserved final bottom bar.
    pub last_tail_rows: u32,
}

fn scaled_dimension(value: u32, scale_percent: u32) -> u32 {
    ((value as u64 * scale_percent as u64 + 50) / 100).max(1) as u32
}

/// Compute the output layout from image dimensions and the seam list.
pub fn build_plan(
    width: u32,
    heights: &[u32],
    config: &ComposeConfig,
) -> StitchResult<ComposePlan> {
    let n = heights.len();
    if n == 0 {
        return Err(StitchError::Export("没有可导出的图片".into()));
    }
    if !(MIN_SCALE_PERCENT..=MAX_SCALE_PERCENT).contains(&config.scale_percent) {
        return Err(StitchError::Export(format!(
            "导出尺寸比例必须在 {MIN_SCALE_PERCENT}% 到 {MAX_SCALE_PERCENT}% 之间"
        )));
    }
    if config.seams.len() != n - 1 {
        return Err(StitchError::Export(format!(
            "接缝数量不匹配: 有 {} 张图但 {} 个接缝",
            n,
            config.seams.len()
        )));
    }
    if config.top_bars.len() != n || config.bottom_bars.len() != n {
        return Err(StitchError::Export("固定区域数据与图片数量不一致".into()));
    }
    for h in heights {
        if *h == 0 {
            return Err(StitchError::Export("存在高度为 0 的图片".into()));
        }
    }

    let mut crop_top = vec![0u32; n];
    let mut crop_bottom = vec![0u32; n];
    let mut last_main_rows = 0;
    let mut last_tail_start = 0;
    let mut last_tail_rows = 0;
    for i in 0..n {
        if i > 0 || config.remove_first_status_bar {
            crop_top[i] = config.top_bars[i].min(heights[i]);
        }
        if i + 1 < n {
            crop_bottom[i] = config.bottom_bars[i].min(heights[i]);
        }
    }

    let mut offsets = Vec::with_capacity(n);
    let mut out_rows = Vec::with_capacity(n);
    let mut y = 0u32;
    for (i, &h) in heights.iter().enumerate() {
        offsets.push(y);
        let eff = if i + 1 == n && config.bottom_bars[i] > 0 {
            let bar_height = config.bottom_bars[i].min(h);
            let bar_start = h - bar_height;
            let blank = if config.trim_last_bottom_whitespace {
                config.last_bottom_whitespace.min(bar_start)
            } else {
                0
            };
            let retained = config.retained_bottom_edge.min(blank);
            let main_end = bar_start - blank + retained;
            if main_end < crop_top[i] {
                return Err(StitchError::Export("末图留白裁切后无有效内容".into()));
            }
            crop_bottom[i] = h - main_end;
            last_main_rows = main_end - crop_top[i];
            last_tail_start = bar_start;
            last_tail_rows = bar_height;
            last_main_rows + last_tail_rows
        } else {
            let cropped = crop_top[i].saturating_add(crop_bottom[i]);
            if cropped > h {
                return Err(StitchError::Export(format!(
                    "第 {} 张图片的固定区域裁切超出图片高度",
                    i + 1
                )));
            }
            h - cropped
        };
        out_rows.push(eff);
        if i + 1 < n {
            // The next image's first emitted row is aligned to the matched
            // content row, after excluding fixed bars from both images.
            let next = config.seams[i].dy as i64 + crop_top[i + 1] as i64 - crop_top[i] as i64;
            if next < 0 {
                return Err(StitchError::Export(format!(
                    "第 {} 个接缝在裁切固定区域后无效",
                    i + 1
                )));
            }
            y = y.saturating_add(next as u32);
        } else {
            y = y.saturating_add(eff);
        }
    }
    let source_height = y;
    if source_height == 0 {
        return Err(StitchError::Export("输出高度为 0".into()));
    }
    let mut x_offsets = vec![0i64; n];
    for i in 0..n.saturating_sub(1) {
        x_offsets[i + 1] = x_offsets[i] - config.seams[i].dx as i64;
    }
    let output_width = scaled_dimension(width, config.scale_percent);
    let height = scaled_dimension(source_height, config.scale_percent);
    let total_pixels = (output_width as u64) * (height as u64);
    if total_pixels > MAX_OUTPUT_PIXELS {
        return Err(StitchError::Export(format!(
            "输出尺寸过大 ({}x{} = {:.1}MP，上限 {}MP)",
            output_width,
            height,
            total_pixels as f64 / 1e6,
            MAX_OUTPUT_PIXELS / 1_000_000
        )));
    }
    if height == 0 {
        return Err(StitchError::Export("输出高度为 0".into()));
    }
    Ok(ComposePlan {
        width: output_width,
        height,
        source_width: width,
        source_height,
        scale_percent: config.scale_percent,
        x_offsets,
        offsets,
        out_rows,
        crop_top,
        crop_bottom,
        last_main_rows,
        last_tail_start,
        last_tail_rows,
    })
}

fn source_row_for_output(plan: &ComposePlan, output_y: u32) -> u32 {
    let numerator = output_y as u64 * 100 + (plan.scale_percent as u64 / 2);
    (numerator / plan.scale_percent as u64).min(plan.source_height.saturating_sub(1) as u64) as u32
}

/// Map an output row to `(image_index, local_row)`.
fn map_row(plan: &ComposePlan, out_y: u32) -> (usize, u32) {
    let mut lo = 0usize;
    let mut hi = plan.offsets.len() - 1;
    while lo < hi {
        let mid = (lo + hi).div_ceil(2);
        if plan.offsets[mid] <= out_y {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    let local = out_y - plan.offsets[lo];
    if lo + 1 == plan.offsets.len() && plan.last_tail_rows > 0 && local >= plan.last_main_rows {
        return (lo, plan.last_tail_start + local - plan.last_main_rows);
    }
    (lo, local + plan.crop_top[lo])
}

/// Decode the images needed by one output block.
fn decode_needed(
    paths: &[PathBuf],
    needed: &HashSet<usize>,
) -> StitchResult<std::collections::HashMap<usize, RgbImage>> {
    let mut out = std::collections::HashMap::with_capacity(needed.len());
    for &i in needed {
        let img = crate::image::load_rgb(&paths[i])?;
        out.insert(i, img);
    }
    Ok(out)
}

/// Assemble a single output row from the decoded sources.
fn assemble_row(
    plan: &ComposePlan,
    imgs: &std::collections::HashMap<usize, RgbImage>,
    source_y: u32,
) -> Vec<u8> {
    let (k, local_y) = map_row(plan, source_y);
    let img = &imgs[&k];
    let row = &img.as_raw()[(local_y as usize * img.width() as usize * 3)
        ..((local_y as usize + 1) * img.width() as usize * 3)];
    if plan.width == plan.source_width && plan.x_offsets[k] == 0 {
        return row.to_vec();
    }
    let mut output = vec![0u8; plan.width as usize * 3];
    for x in 0..plan.width {
        let source_canvas_x =
            ((x as u64 * 100 + plan.scale_percent as u64 / 2) / plan.scale_percent as u64) as i64;
        // Keep the established source-width canvas and crop drift at its edge.
        let source_x =
            (source_canvas_x - plan.x_offsets[k]).clamp(0, img.width().saturating_sub(1) as i64);
        let source_start = source_x as usize * 3;
        let output_start = x as usize * 3;
        output[output_start..output_start + 3]
            .copy_from_slice(&row[source_start..source_start + 3]);
    }
    output
}

/// Export the stitched image to `out_path`, calling `progress(done, total)`
/// after each block.
pub fn compose_to_file(
    paths: &[PathBuf],
    config: &ComposeConfig,
    out_path: &Path,
    mut progress: impl FnMut(u64, u64),
) -> StitchResult<()> {
    for path in paths {
        if paths_alias(path, out_path)? {
            return Err(StitchError::Export("输入文件和输出文件不能相同".into()));
        }
    }
    write_atomic(out_path, |temporary| {
        compose_to_path(paths, config, temporary, &mut progress)
    })
}

fn compose_to_path(
    paths: &[PathBuf],
    config: &ComposeConfig,
    out_path: &Path,
    progress: &mut impl FnMut(u64, u64),
) -> StitchResult<()> {
    if paths.is_empty() {
        return Err(StitchError::Export("没有可导出的图片".into()));
    }
    let infos: Vec<crate::image::ImageInfo> = paths
        .iter()
        .map(|p| crate::image::load_info(p))
        .collect::<StitchResult<_>>()?;
    let width = infos[0].width;
    if infos.iter().any(|info| info.width != width) {
        return Err(StitchError::Export("所有图片必须具有相同宽度".into()));
    }
    let heights: Vec<u32> = infos.iter().map(|i| i.height).collect();
    let plan = build_plan(width, &heights, config)?;
    for (i, s) in config.seams.iter().enumerate() {
        if s.dy >= heights[i] {
            return Err(StitchError::Export(format!(
                "第 {} 个接缝无效 (dy={} >= 高度 {})",
                i + 1,
                s.dy,
                heights[i]
            )));
        }
    }
    let source_bytes = infos
        .iter()
        .map(crate::image::rgb_size)
        .fold(0u64, u64::saturating_add);
    let buffered_bytes = buffered_output_bytes(config.format, plan.width, plan.height)?;
    ensure_pipeline_budget(source_bytes.saturating_add(buffered_bytes), "拼接导出")?;

    let mut sink = open_sink(config.format, out_path, plan.width, plan.height)?;
    let total = plan.height as u64;
    let mut done = 0u64;
    let mut out_y = 0u32;
    let mut imgs = std::collections::HashMap::new();
    while out_y < plan.height {
        let block_h = BLOCK_ROWS.min(plan.height - out_y);
        let last_y = out_y + block_h - 1;
        let source_y0 = source_row_for_output(&plan, out_y);
        let source_y1 = source_row_for_output(&plan, last_y);
        let (k0, _) = map_row(&plan, source_y0);
        let (k1, _) = map_row(&plan, source_y1);
        let mut needed = HashSet::new();
        for k in k0..=k1 {
            needed.insert(k);
        }
        imgs.retain(|index, _| needed.contains(index));
        let missing: HashSet<usize> = needed
            .iter()
            .copied()
            .filter(|index| !imgs.contains_key(index))
            .collect();
        imgs.extend(decode_needed(paths, &missing)?);
        for y in out_y..=last_y {
            let source_y = source_row_for_output(&plan, y);
            let row = assemble_row(&plan, &imgs, source_y);
            sink.write_row(&row)?;
            done += 1;
        }
        progress(done, total);
        out_y = last_y + 1;
    }
    sink.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encoder::ExportFormat;
    use image::RgbImage;

    fn temp_path(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("stitch_cmp_{}_{name}", std::process::id()))
    }

    /// Write an RGB test image with a horizontal gradient and a marker column.
    fn write_test_image(path: &Path, w: u32, h: u32, id: u8) {
        let img = RgbImage::from_fn(w, h, |x, y| {
            let v = (y as u8).wrapping_mul(3).wrapping_add(id.wrapping_mul(40));
            let marker = if x == w / 2 { 255u8 } else { v };
            image::Rgb([marker, v, v.wrapping_add(17)])
        });
        img.save(path).unwrap();
    }

    fn two_image_config() -> ComposeConfig {
        ComposeConfig {
            format: ExportFormat::Png,
            scale_percent: 100,
            seams: vec![SeamEntry { dx: 0, dy: 100 }],
            top_bars: vec![0, 0],
            bottom_bars: vec![0, 0],
            last_bottom_whitespace: 0,
            remove_first_status_bar: false,
            trim_last_bottom_whitespace: false,
            retained_bottom_edge: 0,
        }
    }

    #[test]
    fn plan_layout_simple() {
        let cfg = two_image_config();
        let plan = build_plan(1080, &[800, 800], &cfg).unwrap();
        assert_eq!(plan.width, 1080);
        assert_eq!(plan.height, 900);
        assert_eq!(plan.offsets, vec![0, 100]);
        assert_eq!(plan.out_rows, vec![800, 800]);
    }

    #[test]
    fn plan_tracks_alignment_offsets() {
        let mut cfg = two_image_config();
        cfg.seams[0].dx = 12;
        let plan = build_plan(1080, &[800, 800], &cfg).unwrap();
        assert_eq!(plan.x_offsets, vec![0, -12]);
    }

    #[test]
    fn plan_layout_with_scale() {
        let mut cfg = two_image_config();
        cfg.scale_percent = 75;
        let plan = build_plan(1000, &[800, 800], &cfg).unwrap();
        assert_eq!(plan.width, 750);
        assert_eq!(plan.height, 675);
        assert_eq!(plan.source_width, 1000);
        assert_eq!(plan.source_height, 900);
    }

    #[test]
    fn plan_layout_with_crops() {
        let mut cfg = two_image_config();
        cfg.top_bars[0] = 40;
        cfg.bottom_bars[1] = 60;
        cfg.last_bottom_whitespace = 60;
        cfg.remove_first_status_bar = true;
        cfg.trim_last_bottom_whitespace = true;
        cfg.retained_bottom_edge = 10;
        let plan = build_plan(1080, &[800, 800], &cfg).unwrap();
        assert_eq!(plan.height, 810);
        assert_eq!(plan.crop_top, vec![40, 0]);
        assert_eq!(plan.crop_bottom, vec![0, 110]);
        assert_eq!(plan.offsets, vec![0, 60]);
        assert_eq!(plan.last_main_rows, 690);
        assert_eq!(plan.last_tail_start, 740);
        assert_eq!(plan.last_tail_rows, 60);
    }

    #[test]
    fn plan_crops_internal_fixed_bars() {
        let cfg = ComposeConfig {
            format: ExportFormat::Png,
            scale_percent: 100,
            seams: vec![SeamEntry { dx: 0, dy: 500 }, SeamEntry { dx: 0, dy: 500 }],
            top_bars: vec![0, 40, 40],
            bottom_bars: vec![60, 60, 0],
            last_bottom_whitespace: 0,
            remove_first_status_bar: false,
            trim_last_bottom_whitespace: false,
            retained_bottom_edge: 0,
        };
        let plan = build_plan(100, &[800, 800, 800], &cfg).unwrap();
        assert_eq!(plan.crop_top, vec![0, 40, 40]);
        assert_eq!(plan.crop_bottom, vec![60, 60, 0]);
        assert_eq!(plan.offsets, vec![0, 540, 1040]);
        assert_eq!(plan.height, 1800);
    }

    #[test]
    fn compose_two_png() {
        let (w, h) = (64u32, 200u32);
        let p1 = temp_path("a.png");
        let p2 = temp_path("b.png");
        let out = temp_path("out.png");
        write_test_image(&p1, w, h, 0);
        write_test_image(&p2, w, h, 1);
        let cfg = two_image_config();
        let mut last = 0u64;
        compose_to_file(&[p1.clone(), p2.clone()], &cfg, &out, |done, total| {
            last = done;
            assert!(total > 0);
            assert!(done <= total);
        })
        .unwrap();
        assert_eq!(last, 100 + h as u64);
        let img = image::open(&out).unwrap().into_rgb8();
        assert_eq!(img.dimensions(), (w, 100 + h));
        let a = image::open(&p1).unwrap().into_rgb8();
        let b = image::open(&p2).unwrap().into_rgb8();
        // Top part (rows < 100) comes from image 1 unchanged.
        assert_eq!(img.get_pixel(0, 5), a.get_pixel(0, 5));
        // Bottom part (rows >= 100) comes from image 2; bottom row 0 sits at
        // output row 100 (dy=100).
        assert_eq!(img.get_pixel(0, 100), b.get_pixel(0, 0));
        assert_eq!(img.get_pixel(3, 150), b.get_pixel(3, 50));
        for p in [&p1, &p2, &out] {
            std::fs::remove_file(p).ok();
        }
    }

    #[test]
    fn compose_applies_horizontal_alignment() {
        let p1 = temp_path("dx_a.png");
        let p2 = temp_path("dx_b.png");
        let out = temp_path("dx_out.png");
        let top = RgbImage::from_fn(8, 2, |x, y| image::Rgb([x as u8, y as u8, 0]));
        let bottom = RgbImage::from_fn(8, 2, |x, y| image::Rgb([100 + x as u8, y as u8, 0]));
        top.save(&p1).unwrap();
        bottom.save(&p2).unwrap();
        let mut cfg = two_image_config();
        cfg.seams[0] = SeamEntry { dx: 1, dy: 1 };
        compose_to_file(&[p1.clone(), p2.clone()], &cfg, &out, |_, _| {}).unwrap();
        let image = image::open(&out).unwrap().into_rgb8();
        assert_eq!(image.get_pixel(0, 1), &image::Rgb([101, 0, 0]));
        for path in [&p1, &p2, &out] {
            std::fs::remove_file(path).ok();
        }
    }

    #[test]
    fn compose_rejects_output_alias_without_truncating_source() {
        let path = temp_path("alias.png");
        write_test_image(&path, 16, 8, 0);
        let before = std::fs::read(&path).unwrap();
        let config = ComposeConfig {
            format: ExportFormat::Png,
            scale_percent: 100,
            seams: vec![],
            top_bars: vec![0],
            bottom_bars: vec![0],
            last_bottom_whitespace: 0,
            remove_first_status_bar: false,
            trim_last_bottom_whitespace: false,
            retained_bottom_edge: 0,
        };
        assert!(compose_to_file(std::slice::from_ref(&path), &config, &path, |_, _| {}).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), before);
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn build_plan_rejects_bad_seams() {
        let cfg = ComposeConfig {
            format: ExportFormat::Png,
            scale_percent: 100,
            seams: vec![],
            top_bars: vec![0],
            bottom_bars: vec![0],
            last_bottom_whitespace: 0,
            remove_first_status_bar: false,
            trim_last_bottom_whitespace: false,
            retained_bottom_edge: 0,
        };
        // Two images but zero seams -> rejected.
        assert!(build_plan(1080, &[800, 800], &cfg).is_err());
        // Single image with zero seams is valid.
        assert!(build_plan(1080, &[800], &cfg).is_ok());
    }

    #[test]
    fn compose_rejects_oversized_output() {
        let cfg = two_image_config();
        // Two huge heights -> > MAX_OUTPUT_PIXELS.
        let err = build_plan(1080, &[u32::MAX / 2, u32::MAX / 2], &cfg);
        assert!(err.is_err());
    }
}
