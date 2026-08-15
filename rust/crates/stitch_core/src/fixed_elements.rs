//! Detection of fixed top and bottom UI bars.

use crate::image::{sobel, LumaImage};

const WHITESPACE_EDGE_THRESHOLD: u8 = 24;
const WHITESPACE_MAX_ACTIVE_RATIO: f32 = 0.02;

/// A rectangular region in full-resolution pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Region {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

impl Region {
    pub fn contains(&self, x: u32, y: u32) -> bool {
        x >= self.x && x < self.x + self.w && y >= self.y && y < self.y + self.h
    }

    pub fn area(&self) -> u64 {
        self.w as u64 * self.h as u64
    }

    pub fn iou(&self, other: &Region) -> f64 {
        let ix0 = self.x.max(other.x);
        let iy0 = self.y.max(other.y);
        let ix1 = (self.x + self.w).min(other.x + other.w);
        let iy1 = (self.y + self.h).min(other.y + other.h);
        let inter = if ix1 > ix0 && iy1 > iy0 {
            ((ix1 - ix0) * (iy1 - iy0)) as u64
        } else {
            0
        };
        let union = self.area() + other.area() - inter;
        if union == 0 {
            0.0
        } else {
            inter as f64 / union as f64
        }
    }
}

/// Fixed bars detected between two adjacent screenshots.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FixedElements {
    /// Fixed bar at the top of the bottom image.
    pub top_bar: Option<Region>,
    /// Fixed bar at the bottom of the top image.
    pub bottom_bar: Option<Region>,
    /// Blank content immediately above the bottom bar of the bottom image.
    pub bottom_whitespace: Option<Region>,
}

impl FixedElements {
    pub fn is_empty(&self) -> bool {
        self.top_bar.is_none() && self.bottom_bar.is_none() && self.bottom_whitespace.is_none()
    }
}

/// Tunable parameters for fixed-bar detection.
#[derive(Debug, Clone)]
pub struct FixedOptions {
    pub row_same_threshold: u8,
    pub min_bar_height: u32,
    pub min_bar_rows: u32,
    pub max_bar_fraction: f32,
    pub min_whitespace_rows: u32,
}

impl Default for FixedOptions {
    fn default() -> Self {
        Self {
            row_same_threshold: 10,
            min_bar_height: 24,
            min_bar_rows: 4,
            max_bar_fraction: 0.4,
            min_whitespace_rows: 8,
        }
    }
}

fn row_mad(a: &LumaImage, b: &LumaImage, ay: u32, by: u32) -> f64 {
    let width = a.width.min(b.width);
    let mut sum = 0u64;
    for x in 0..width {
        let va = a.get(x, ay).unwrap_or(0) as i64;
        let vb = b.get(x, by).unwrap_or(0) as i64;
        sum += (va - vb).unsigned_abs();
    }
    if width == 0 {
        f64::INFINITY
    } else {
        sum as f64 / width as f64
    }
}

fn valid_bar_height(count: usize, image_height: u32, opts: &FixedOptions) -> bool {
    let min_rows = opts.min_bar_rows.max(opts.min_bar_height) as usize;
    let max_rows = (image_height as f32 * opts.max_bar_fraction) as usize;
    count >= min_rows && count <= max_rows
}

fn detect_top_bar(top: &LumaImage, bottom: &LumaImage, opts: &FixedOptions) -> Option<Region> {
    let rows = top.height.min(bottom.height);
    let mut count = 0usize;
    for row in 0..rows {
        if row_mad(top, bottom, row, row) >= opts.row_same_threshold as f64 {
            break;
        }
        count += 1;
    }
    valid_bar_height(count, rows, opts).then_some(Region {
        x: 0,
        y: 0,
        w: bottom.width,
        h: count as u32,
    })
}

fn detect_bottom_bar(top: &LumaImage, bottom: &LumaImage, opts: &FixedOptions) -> Option<Region> {
    let rows = top.height.min(bottom.height);
    let mut count = 0usize;
    for row in (0..rows).rev() {
        if row_mad(top, bottom, row, row) >= opts.row_same_threshold as f64 {
            break;
        }
        count += 1;
    }
    valid_bar_height(count, rows, opts).then_some(Region {
        x: 0,
        y: top.height - count as u32,
        w: top.width,
        h: count as u32,
    })
}

fn row_edge_ratio(gradient: &LumaImage, y: u32) -> f32 {
    let mut active = 0u32;
    for x in 0..gradient.width {
        if gradient.get(x, y).unwrap_or(0) >= WHITESPACE_EDGE_THRESHOLD {
            active += 1;
        }
    }
    active as f32 / gradient.width.max(1) as f32
}

fn detect_bottom_whitespace(
    image: &LumaImage,
    bottom_bar: Option<Region>,
    opts: &FixedOptions,
) -> Option<Region> {
    let bar = bottom_bar?;
    let gradient = sobel(image);
    let mut count = 0usize;
    // The row directly above the fixed bar contains the bar boundary edge;
    // skip it so the boundary does not hide the blank run behind it.
    for y in (0..bar.y.saturating_sub(1)).rev() {
        if row_edge_ratio(&gradient, y) > WHITESPACE_MAX_ACTIVE_RATIO {
            break;
        }
        count += 1;
    }
    let min_rows = opts.min_whitespace_rows as usize;
    let max_rows = (image.height as f32 * opts.max_bar_fraction) as usize;
    if count < min_rows || count > max_rows {
        return None;
    }
    Some(Region {
        x: 0,
        y: bar.y - count as u32,
        w: image.width,
        h: count as u32,
    })
}

/// Detect fixed bars using screen-aligned row comparisons.
pub fn detect_fixed(top: &LumaImage, bottom: &LumaImage, opts: &FixedOptions) -> FixedElements {
    let top_bar = detect_top_bar(top, bottom, opts);
    let bottom_bar = detect_bottom_bar(top, bottom, opts);
    FixedElements {
        top_bar,
        bottom_whitespace: detect_bottom_whitespace(bottom, bottom_bar, opts),
        bottom_bar,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::image::luma_from_rgb;
    use crate::overlap::{find_overlap, OverlapOptions};
    use image::RgbImage;

    const NAV_H: u32 = 80;
    const BAR_H: u32 = 60;
    const CONTENT_H: u32 = 640;

    fn luma(img: &RgbImage) -> LumaImage {
        luma_from_rgb(img)
    }

    fn make_content(w: u32, h: u32) -> RgbImage {
        RgbImage::from_fn(w, h, |x, y| {
            let v = ((x * 17 + y * 31) % 251) as u8;
            image::Rgb([v, v.wrapping_add(37), v.wrapping_add(83)])
        })
    }

    fn make_screen(
        content: &RgbImage,
        content_start: u32,
        w: u32,
        h: u32,
        with_nav: bool,
        with_bar: bool,
    ) -> RgbImage {
        let nav_h = if with_nav { NAV_H } else { 0 };
        RgbImage::from_fn(w, h, |x, y| {
            if with_nav && y < NAV_H {
                return image::Rgb([30, 30, 30]);
            }
            if with_bar && y >= h - BAR_H {
                return image::Rgb([210, 210, 210]);
            }
            let source_y = content_start + y.saturating_sub(nav_h);
            let source_y = source_y.min(content.height() - 1);
            *content.get_pixel(x, source_y)
        })
    }

    #[test]
    fn detects_bars_with_real_scroll() {
        let (w, h) = (360, NAV_H + CONTENT_H + BAR_H);
        let content = make_content(w, 4000);
        let top = make_screen(&content, 0, w, h, true, true);
        let bottom = make_screen(&content, 240, w, h, true, true);
        let top_luma = luma(&top);
        let bottom_luma = luma(&bottom);
        let seam = find_overlap(&top_luma, &bottom_luma, &OverlapOptions::default()).unwrap();
        assert!(seam.plausible);
        let fixed = detect_fixed(&top_luma, &bottom_luma, &FixedOptions::default());
        assert_eq!(fixed.top_bar.unwrap().h, NAV_H);
        assert_eq!(fixed.bottom_bar.unwrap().h, BAR_H);
        assert!(fixed.bottom_whitespace.is_none());
    }

    #[test]
    fn detects_bottom_whitespace_above_fixed_bar() {
        let (w, h) = (360, NAV_H + CONTENT_H + BAR_H);
        let content = make_content(w, 4000);
        let top = make_screen(&content, 0, w, h, true, true);
        let mut bottom = make_screen(&content, 240, w, h, true, true);
        let whitespace_start = h - BAR_H - 40;
        for y in whitespace_start..h - BAR_H {
            for x in 0..w {
                *bottom.get_pixel_mut(x, y) = image::Rgb([248, 248, 248]);
            }
        }
        let fixed = detect_fixed(&luma(&top), &luma(&bottom), &FixedOptions::default());
        let whitespace = fixed.bottom_whitespace.unwrap();
        assert!(whitespace.h >= 38);
    }

    #[test]
    fn no_fixed_elements_when_pure_content() {
        let (w, h) = (360, NAV_H + CONTENT_H + BAR_H);
        let content = make_content(w, 4000);
        let top = make_screen(&content, 0, w, h, false, false);
        let bottom = make_screen(&content, 300, w, h, false, false);
        let fixed = detect_fixed(&luma(&top), &luma(&bottom), &FixedOptions::default());
        assert!(fixed.is_empty());
    }

    #[test]
    fn region_iou() {
        let a = Region {
            x: 0,
            y: 0,
            w: 100,
            h: 100,
        };
        let b = Region {
            x: 50,
            y: 0,
            w: 100,
            h: 100,
        };
        assert!((a.iou(&b) - 1.0 / 3.0).abs() < 1e-9);
    }
}
