//! Automatic overlap (seam) detection between consecutive screenshots.
//!
//! Strategy: coarse-to-fine displacement search on downsampled luminance and
//! gradient planes, using a truncated MAD cost that is robust to JPEG
//! artefacts, followed by a uniqueness-based confidence estimate.

use crate::error::{StitchError, StitchResult};
use crate::image::{sobel, LumaImage, Scale};

/// Minimum overlap ratio of the shorter image that we are willing to accept.
pub const DEFAULT_MIN_OVERLAP_RATIO: f32 = 0.05;
/// Tolerance for horizontal drift between screenshots (in full-res pixels).
pub const DEFAULT_MAX_DX_TOLERANCE: u32 = 24;
/// Truncation threshold for luminance differences (JPEG artefacts).
pub const JPEG_LUMA_THRESHOLD: u8 = 12;
/// Minimum row edge energy (sum of sampled Sobel values) for a row to
/// participate in matching. Blank rows carry no alignment information.
const ROW_ENERGY_MIN: u32 = 120;
/// Number of column segments per row signature.
const SIG_SEGMENTS: usize = 8;
/// Rows of B used in the signature coarse search (full-res pixels).
const SIG_STRIP: usize = 300;
/// Number of top candidates kept between coarse-to-fine levels.
const TOP_K: usize = 5;

/// Tunable parameters for overlap search.
#[derive(Debug, Clone)]
pub struct OverlapOptions {
    pub min_overlap_ratio: f32,
    pub max_dx_tolerance: u32,
    pub jpeg_luma_threshold: u8,
}

impl Default for OverlapOptions {
    fn default() -> Self {
        Self {
            min_overlap_ratio: DEFAULT_MIN_OVERLAP_RATIO,
            max_dx_tolerance: DEFAULT_MAX_DX_TOLERANCE,
            jpeg_luma_threshold: JPEG_LUMA_THRESHOLD,
        }
    }
}

/// A single alignment candidate, in full-resolution pixel coordinates.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Candidate {
    /// Horizontal offset of `bottom` relative to `top` (positive = right).
    pub dx: i32,
    /// Row in the top image where the bottom image's first row is placed.
    /// Equivalent to `top_height - overlap`.
    pub dy: u32,
    /// Truncated MAD cost (lower is better).
    pub cost: f64,
}

/// Result of an overlap search between two adjacent screenshots.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OverlapResult {
    /// The best candidate.
    pub best: Candidate,
    /// All kept candidates, ordered by ascending cost.
    pub candidates: [Candidate; TOP_K],
    /// Number of valid candidates (<= TOP_K).
    pub n_candidates: usize,
    /// Uniqueness-based confidence in `[0, 1]`.
    pub confidence: f32,
    /// Whether the best cost is low enough to trust at all.
    pub plausible: bool,
}

impl OverlapResult {
    /// The overlap height in full-res pixels.
    pub fn overlap(&self, top_height: u32) -> u32 {
        top_height.saturating_sub(self.best.dy)
    }
}

/// Compute a gradient-weighted truncated MAD between two row bands.
///
/// Screenshots are mostly blank (white) with sparse text; an unweighted
/// average diff would be diluted by matching blank areas at *every* offset,
/// collapsing the cost gap between candidates. Weighting each sample by its
/// edge energy (Sobel magnitude) makes textured regions — text, cards, UI —
/// dominate the cost, which is the approach used by production screenshot
/// stitchers (Tailor, LongShot).
///
/// `a` is the reference band (top image), `b` the candidate band (bottom
/// image). `stride_x`/`stride_y` control sampling density; a y-stride of 2
/// makes even pixel offsets invisible, so the final refinement level must
/// use stride 1 on y.
fn weighted_band_cost(
    a: &LumaImage,
    a_grad: &LumaImage,
    b: &LumaImage,
    b_grad: &LumaImage,
    ay: u32,
    by: u32,
    band: u32,
    dx: i32,
    threshold: u8,
    stride_x: u32,
    stride_y: u32,
    fixed: &[bool],
) -> f64 {
    let mut num = 0.0f64;
    let mut den = 0.0f64;
    let sx = stride_x.max(1);
    let sy = stride_y.max(1);
    let mut y = 0u32;
    while y < band {
        // Skip rows that are fixed UI (identical screen rows in both frames):
        // they match at dy=0 and would create a false candidate.
        if fixed.get((by + y) as usize).copied().unwrap_or(false) {
            y += sy;
            continue;
        }
        // Row-energy gating: blank rows in the *candidate* image carry no
        // alignment information. Only check `b`: at the correct dy, a blank
        // row of B may sit over text of A (that mismatch is real and should
        // be penalised when B has content, not skipped via A's energy).
        if row_energy(b_grad, by + y, sx) < ROW_ENERGY_MIN {
            y += sy;
            continue;
        }
        let mut x = 0u32;
        while x < a.width {
            let bx = x as i64 + dx as i64;
            if bx >= 0 && (bx as u32) < b.width {
                let va = a.get(x, ay + y).unwrap_or(0) as i32;
                let vb = b.get(bx as u32, by + y).unwrap_or(0) as i32;
                let d = (va - vb).abs();
                // Edge-energy weight: 1 (flat) .. 20 (strong edge).
                let e = a_grad
                    .get(x, ay + y)
                    .unwrap_or(0)
                    .max(b_grad.get(bx as u32, by + y).unwrap_or(0));
                let w = 1.0 + (e as f64 / 255.0) * (e as f64 / 255.0) * 19.0;
                // Denominator counts every sample, numerator only mismatches:
                // blank regions never inflate the cost, textured ones dominate.
                den += w;
                if d > threshold as i32 {
                    num += w * (d - threshold as i32) as f64;
                }
            }
            x += sx;
        }
        y += sy;
    }
    if den == 0.0 {
        return f64::INFINITY;
    }
    num / den
}

/// Sum of sampled Sobel magnitudes along one row (edge energy of the row).
fn row_energy(grad: &LumaImage, row: u32, stride_x: u32) -> u32 {
    let sx = stride_x.max(1);
    let mut sum = 0u32;
    let mut x = 0u32;
    while x < grad.width {
        sum += grad.get(x, row).unwrap_or(0) as u32;
        x += sx;
    }
    sum
}

/// Evaluate a single candidate (dx, dy) by combining gradient-weighted
/// luminance and gradient costs. `sx`/`sy` are passed through.
///
/// Only a `strip_h`-tall band near the seam is compared (strip template
/// matching): comparing the whole overlap region lets blank areas dilute the
/// cost, which collapses the gap between candidates on sparse-text pages.
///
/// `skip` rows at the top of `bottom` (fixed UI) are excluded from the strip
/// entirely; `fixed` rows inside the strip are skipped individually.
fn evaluate(
    top: &LumaImage,
    top_grad: &LumaImage,
    bottom: &LumaImage,
    bottom_grad: &LumaImage,
    dx: i32,
    dy: u32,
    opts: &OverlapOptions,
    sx: u32,
    sy: u32,
    strip_h: u32,
    skip: u32,
    fixed: &[bool],
) -> f64 {
    let avail = (top.height - dy).saturating_sub(skip);
    let band = avail.min(strip_h);
    if band == 0 {
        return f64::INFINITY;
    }
    let lum = weighted_band_cost(
        top,
        top_grad,
        bottom,
        bottom_grad,
        dy + skip,
        skip,
        band,
        dx,
        opts.jpeg_luma_threshold,
        sx,
        sy,
        fixed,
    );
    // Gradient mismatch: re-use the same weighting on the gradient planes.
    let grad = weighted_band_cost(
        top_grad,
        top_grad,
        bottom_grad,
        bottom_grad,
        dy + skip,
        skip,
        band,
        dx,
        4,
        sx,
        sy,
        fixed,
    );
    // Gradient cost gets a smaller weight; luminance is the primary signal.
    lum + 0.35 * grad
}

/// Detect rows that are identical at the same screen position in both images
/// (fixed UI such as status bars, nav bars, input bars). These rows must be
/// excluded from seam matching: they match at dy=0 regardless of the true
/// scroll amount, creating false candidates.
///
/// Returns one bool per row of `bottom` (length = min heights). Rows are
/// considered fixed when their screen-aligned MAD is below the row threshold.
fn fixed_row_mask(top: &LumaImage, bottom: &LumaImage) -> Vec<bool> {
    let len = top.height.min(bottom.height) as usize;
    let mut mask = vec![false; len];
    for (n, entry) in mask.iter_mut().enumerate() {
        let mut sum = 0u64;
        let mut cnt = 0u64;
        let mut x = 0u32;
        while x < top.width {
            let va = top.get(x, n as u32).unwrap_or(0) as i64;
            let vb = bottom.get(x, n as u32).unwrap_or(0) as i64;
            sum += (va - vb).unsigned_abs();
            cnt += 1;
            x += 2;
        }
        if cnt > 0 && (sum as f64 / cnt as f64) < 6.0 {
            *entry = true;
        }
    }
    // If nearly every row is "fixed" the two images are identical (scroll=0
    // or fully repeated content): there is no fixed UI to exclude, and
    // excluding everything would leave no candidates at all.
    let fixed_count = mask.iter().filter(|b| **b).count();
    if fixed_count * 10 > len * 6 {
        return vec![false; len];
    }
    mask
}

/// 诊断辅助：暴露固定行掩码（example 使用）。
#[doc(hidden)]
pub fn fixed_row_mask_debug(top: &LumaImage, bottom: &LumaImage) -> Vec<bool> {
    fixed_row_mask(top, bottom)
}

/// Height of the fixed region at the top of the images (rows after which the
/// scrolling content starts). The status bar may not register as fixed (its
/// network-speed text changes between frames), so we locate the *first long
/// run of fixed rows* (>= 80 rows, i.e. a nav bar or pinned header) and skip
/// everything above its end.
fn top_fixed_height(mask: &[bool]) -> u32 {
    let mut i = 0usize;
    while i < mask.len() {
        if mask[i] {
            let start = i;
            while i < mask.len() && mask[i] {
                i += 1;
            }
            if i - start >= 80 {
                return i as u32;
            }
        } else {
            i += 1;
        }
    }
    0
}

/// Per-row signature: gradient energy per column segment. Segment energy is
/// stable under 1-2px offsets (unlike pixels), so full-range correlation of
/// signatures lands within a few rows of the true alignment.
fn row_signatures(grad: &LumaImage, luma: &LumaImage, segments: usize) -> Vec<Vec<f64>> {
    let w = luma.width;
    let seg_w = (w as usize).div_ceil(segments).max(1);
    let mut out = Vec::with_capacity(luma.height as usize);
    for row in 0..luma.height {
        let mut sig = vec![0.0f64; segments];
        for (seg, v) in sig.iter_mut().enumerate() {
            let x0 = seg * seg_w;
            let x1 = ((seg + 1) * seg_w).min(w as usize);
            let mut sum = 0u64;
            let mut n = 0u64;
            for x in x0..x1 {
                sum += grad.get(x as u32, row).unwrap_or(0) as u64;
                n += 1;
            }
            *v = if n > 0 { sum as f64 / n as f64 } else { 0.0 };
        }
        out.push(sig);
    }
    out
}

/// Cost of aligning B's content strip (starting at `skip`, `strip` rows tall)
/// with A at offset `dy`, based on row signatures. Fixed rows are excluded.
fn signature_cost(
    sig_a: &[Vec<f64>],
    sig_b: &[Vec<f64>],
    fixed: &[bool],
    skip: u32,
    strip: usize,
    dy: u32,
) -> f64 {
    let mut num = 0.0f64;
    let mut den = 0.0f64;
    let segments = sig_b.first().map(|s| s.len()).unwrap_or(0);
    for i in 0..strip {
        let by = skip as usize + i;
        if fixed.get(by).copied().unwrap_or(false) {
            continue;
        }
        let ay = dy as usize + by;
        let Some(sa) = sig_a.get(ay) else { break };
        let Some(sb) = sig_b.get(by) else { break };
        let mut d = 0.0f64;
        for k in 0..segments {
            d += (sa[k] - sb[k]).abs();
        }
        num += d;
        den += 1.0;
    }
    if den == 0.0 {
        f64::INFINITY
    } else {
        num / den
    }
}

/// Search overlap at the resolution supplied by the caller. Production code
/// may downsample inputs before calling this function and use
/// [`scale_candidates`] to restore full-resolution coordinates.
pub fn search_scaled(
    top: &LumaImage,
    bottom: &LumaImage,
    opts: &OverlapOptions,
) -> StitchResult<OverlapResult> {
    let min_overlap = ((top.height as f32) * opts.min_overlap_ratio).round() as u32;
    let max_dy = top.height.saturating_sub(min_overlap);
    if max_dy == 0 {
        return Err(StitchError::Search(format!(
            "图像过小，无法检测重叠 (height={})",
            top.height
        )));
    }
    // Fixed-UI row mask and the top fixed region (strip starts after it).
    let fixed = fixed_row_mask(top, bottom);
    let skip = top_fixed_height(&fixed);
    // Skip must leave room for content: cap at 35% of the image height.
    let skip = skip.min((top.height as usize * 35 / 100) as u32);

    // --- Full-range coarse search on row signatures. ---
    // Row signatures are insensitive to 1-2px offsets (unlike pixels, where
    // downsampled text is destroyed by any misalignment), so a cheap
    // full-range correlation reliably lands within a few rows of the truth.
    let tg = sobel(top);
    let bg = sobel(bottom);
    let sig_a = row_signatures(&tg, top, SIG_SEGMENTS);
    let sig_b = row_signatures(&bg, bottom, SIG_SEGMENTS);
    let sig_strip = SIG_STRIP.min((top.height - skip) as usize);
    let mut cands: Vec<Candidate> = Vec::with_capacity(TOP_K);
    let mut best_overall = f64::INFINITY;
    let mut dy = 0u32;
    while dy <= max_dy {
        let cost = signature_cost(&sig_a, &sig_b, &fixed, skip, sig_strip, dy);
        if cost < best_overall {
            best_overall = cost;
        }
        push_candidate(&mut cands, Candidate { dx: 0, dy, cost });
        dy += 1;
    }
    #[cfg(debug_assertions)]
    if std::env::var("STITCH_DBG").is_ok() {
        let mut v: Vec<(u32, f64)> = cands.iter().map(|c| (c.dy, c.cost)).collect();
        v.sort_by(|a, b| a.1.total_cmp(&b.1));
        eprintln!("coarse top-10 (dy, cost):");
        for (d, c) in v.iter().take(10) {
            eprintln!("  dy={:>4} cost={:.2}", d, c);
        }
    }

    // --- Pixel verification of the signature candidates. ---
    // Signatures locate structure but can be ambiguous on uniform content;
    // re-rank the top candidates with the full-resolution pixel cost in a
    // small (dy ±2, dx ±4) window. This yields pixel-exact alignment, so no
    // further multi-resolution refinement is needed.
    let dx_tol = opts.max_dx_tolerance.max(1) as i64;
    let mut verified: Vec<Candidate> = Vec::with_capacity(TOP_K);
    let sig_top: Vec<Candidate> = cands.iter().cloned().take(5).collect();
    for c in &sig_top {
        for ddy in -2i64..=2 {
            for ddx in -dx_tol..=dx_tol {
                let dy = c.dy as i64 + ddy;
                if dy < 0 || dy as u32 >= top.height {
                    continue;
                }
                let cost = evaluate(
                    top, &tg, bottom, &bg, ddx as i32, dy as u32, opts, 2, 1, 400, skip, &fixed,
                );
                push_candidate(
                    &mut verified,
                    Candidate {
                        dx: ddx as i32,
                        dy: dy as u32,
                        cost,
                    },
                );
            }
        }
    }
    let cands = verified;
    #[cfg(debug_assertions)]
    if std::env::var("STITCH_DBG").is_ok() {
        eprintln!("after pixel verify: {:?}", cands);
    }

    let cands = finalize(cands, best_overall);
    if cands.is_empty() {
        return Err(StitchError::Search("候选为空".into()));
    }
    let best = cands[0];
    let second = cands.get(1).map(|c| c.cost).unwrap_or(best.cost * 1.5);
    let confidence = uniqueness_confidence(best.cost, second);
    // Plausible: the best cost is absolutely low (real matches are near 0
    // thanks to the truncation threshold; fixed-bar misalignment adds a
    // bounded constant) and clearly below the runner-up.
    let plausible = best.cost < 50.0 && best.cost < second * 0.85;
    let mut arr = [Candidate {
        dx: 0,
        dy: 0,
        cost: 0.0,
    }; TOP_K];
    for (i, c) in cands.iter().take(TOP_K).enumerate() {
        arr[i] = *c;
    }
    Ok(OverlapResult {
        best,
        candidates: arr,
        n_candidates: cands.len(),
        confidence,
        plausible,
    })
}

/// Push `c` into a size-limited sorted list (ascending cost).
///
/// Candidates with the same (dx, dy) alignment are deduplicated: they are
/// evaluated repeatedly when coarse candidates overlap, and floating-point
/// noise would otherwise fill the top-K with near-identical entries.
fn push_candidate(list: &mut Vec<Candidate>, c: Candidate) {
    if c.cost.is_infinite() {
        return;
    }
    if list.iter().any(|e| e.dx == c.dx && e.dy == c.dy) {
        return;
    }
    let pos = list
        .iter()
        .position(|e| e.cost > c.cost)
        .unwrap_or(list.len());
    if pos >= TOP_K {
        return;
    }
    list.insert(pos, c);
    list.truncate(TOP_K);
}

fn finalize(mut list: Vec<Candidate>, best_overall: f64) -> Vec<Candidate> {
    list.truncate(TOP_K);
    list.sort_by(|a, b| a.cost.total_cmp(&b.cost));
    if best_overall.is_finite() && list.is_empty() {
        // Should not happen; keep the invariant that at least one candidate exists.
        list.push(Candidate {
            dx: 0,
            dy: 0,
            cost: best_overall,
        });
    }
    list
}

/// Confidence from the gap between the best and second-best cost.
///
/// A large gap means the match is unambiguous; a small gap means several
/// similar offsets (e.g. a mostly plain background) could be the true one.
fn uniqueness_confidence(best: f64, second: f64) -> f32 {
    // Guard against exact zero costs (perfect matches): use a tiny epsilon
    // so that a second candidate with the same cost yields confidence 0.
    let denom = best.max(1e-6);
    let ratio = (second / denom).clamp(1.0, 100.0);
    // 1.0 -> 0.0, 1.25 -> ~0.2, 2.0 -> ~0.5, 10+ -> ~0.9
    let conf = 1.0 - 1.0 / ratio;
    conf.clamp(0.0, 1.0) as f32
}

/// Map a downsampled-scale result back to full resolution.
pub fn scale_candidates(result: &OverlapResult, scale: Scale) -> OverlapResult {
    let mut out = *result;
    out.best.dx = result.best.dx * scale.factor as i32;
    out.best.dy = result.best.dy * scale.factor;
    for (dst, src) in out.candidates.iter_mut().zip(result.candidates.iter()) {
        dst.dx = src.dx * scale.factor as i32;
        dst.dy = src.dy * scale.factor;
    }
    out
}

/// Debug helper used by tests: evaluate a single candidate with the same
/// full-resolution sampling as the final refinement level.
pub fn probe_cost(
    top: &LumaImage,
    top_grad: &LumaImage,
    bottom: &LumaImage,
    bottom_grad: &LumaImage,
    dx: i32,
    dy: u32,
) -> f64 {
    evaluate(
        top,
        top_grad,
        bottom,
        bottom_grad,
        dx,
        dy,
        &OverlapOptions::default(),
        2,
        1,
        400,
        0,
        &[],
    )
}

/// High-level entry point: full-resolution overlap search between two
/// screenshots. `top` is the earlier screenshot, `bottom` the later one.
pub fn find_overlap(
    top: &LumaImage,
    bottom: &LumaImage,
    opts: &OverlapOptions,
) -> StitchResult<OverlapResult> {
    if top.width != bottom.width {
        return Err(StitchError::Search(format!(
            "截图宽度不一致: {} vs {}",
            top.width, bottom.width
        )));
    }
    if top.height < 40 || bottom.height < 40 {
        return Err(StitchError::Search("截图尺寸过小".into()));
    }
    search_scaled(top, bottom, opts)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::image::{luma_from_rgb, LumaImage};
    use image::RgbImage;

    /// Build a synthetic page mimicking real screenshots: white background
    /// with sparse text-like rows (hash-distributed dark runs). The row
    /// structure gives row signatures discriminative power, like real text.
    fn page(width: u32, height: u32, page_id: u8, _bar: bool) -> LumaImage {
        let img = RgbImage::from_fn(width, height, |x, y| {
            let v: u8 = if y < 80 {
                40
            } else if y % 26 < 18 {
                // 行间空白（白底）。
                250
            } else {
                // "文字行"：基于行号与列的哈希决定暗点。
                let h = (y / 26).wrapping_mul(2654435761)
                    ^ x.wrapping_mul(40503)
                    ^ (page_id as u32).wrapping_mul(2654435761);
                if ((h >> 8) % 5) == 0 {
                    10
                } else {
                    250
                }
            };
            image::Rgb([v, v, v])
        });
        luma_from_rgb(&img)
    }

    fn make_pair(scroll: u32) -> (LumaImage, LumaImage) {
        let (w, h) = (400u32, 800u32);
        let full = page(w, 2 * h, 0, false);
        // top = rows 0..800, bottom = rows (h - scroll)..(2h - scroll)
        let top = LumaImage::new(w, h, full.data[0..(w * h) as usize].to_vec()).unwrap();
        let start = (h - scroll) as usize * w as usize;
        let end = start + (w * h) as usize;
        let bottom = LumaImage::new(w, h, full.data[start..end].to_vec()).unwrap();
        (top, bottom)
    }

    #[test]
    fn detects_known_scroll_offset() {
        for scroll in [80u32, 150, 310, 500] {
            let (top, bottom) = make_pair(scroll);
            let res = find_overlap(&top, &bottom, &OverlapOptions::default()).unwrap();
            eprintln!(
                "scroll={scroll}: best={:?} conf={:.3} plaus={}",
                res.best, res.confidence, res.plausible
            );
            assert!(
                res.plausible,
                "scroll {scroll}: not plausible, best cost {:.2}",
                res.best.cost
            );
            assert!(
                res.confidence > 0.3,
                "scroll {scroll}: confidence too low {:.2}",
                res.confidence
            );
            // Expected dy = h - scroll.
            let expected = 800 - scroll;
            let got = res.best.dy;
            assert!(
                (got as i64 - expected as i64).abs() <= 8,
                "scroll {scroll}: dy {got} expected {expected}"
            );
        }
    }

    #[test]
    fn non_overlapping_images_are_implausible() {
        // Completely different content: no shared region.
        let a = page(400, 800, 0, false);
        let b = page(400, 800, 9, false);
        let res = find_overlap(&a, &b, &OverlapOptions::default()).unwrap();
        eprintln!(
            "non_overlap: best={:?} conf={:.3}",
            res.best, res.confidence
        );
        assert!(!res.plausible, "distinct pages should not be plausible");
    }

    #[test]
    fn fixed_bar_is_handled() {
        // Screen model: fixed nav (top 80px) + scrolling content + fixed bar
        // at the bottom (last 80px). Content = text-like rows (realistic:
        // gives row signatures structure).
        let (w, h) = (400u32, 800u32);
        let content_h = 2 * h;
        let full = RgbImage::from_fn(w, content_h, |x, y| {
            let v: u8 = if y % 26 < 18 {
                250
            } else {
                let h = (y / 26).wrapping_mul(2654435761) ^ x.wrapping_mul(40503);
                if ((h >> 8) % 5) == 0 {
                    10
                } else {
                    250
                }
            };
            image::Rgb([v, v, v])
        });
        // Compose a screenshot: nav + content window + bottom bar.
        let screen = |content_start: u32| {
            let mut img = RgbImage::new(w, h);
            // Nav.
            for y in 0..80 {
                for x in 0..w {
                    img.put_pixel(x, y, image::Rgb([30, 30, 30]));
                }
            }
            // Content window: rows 80..720.
            for y in 80..h - 80 {
                for x in 0..w {
                    img.put_pixel(x, y, *full.get_pixel(x, content_start + y - 80));
                }
            }
            // Bottom bar: rows 720..800.
            for y in h - 80..h {
                for x in 0..w {
                    img.put_pixel(x, y, image::Rgb([210, 210, 210]));
                }
            }
            img
        };
        let scroll = 150u32;
        let top_img = screen(0);
        let bottom_img = screen(scroll);
        let top = luma_from_rgb(&top_img);
        let bottom = luma_from_rgb(&bottom_img);
        let res = find_overlap(&top, &bottom, &OverlapOptions::default()).unwrap();
        assert!(res.plausible, "seam not plausible: {:?}", res);
        // dy should equal the scroll amount.
        assert!(
            (res.best.dy as i64 - scroll as i64).abs() <= 8,
            "dy = {}, expected ~{}",
            res.best.dy,
            scroll
        );
    }

    #[test]
    fn dx_drift_is_detected() {
        let (top, mut bottom) = make_pair(200);
        // Shift bottom content right by 10 px (padding the left edge).
        let w = top.width;
        let mut shifted = vec![0u8; bottom.data.len()];
        for y in 0..bottom.height {
            for x in 0..w {
                let src = if x >= 10 {
                    bottom.data[(y * w + x - 10) as usize]
                } else {
                    0
                };
                shifted[(y * w + x) as usize] = src;
            }
        }
        bottom = LumaImage::new(w, bottom.height, shifted).unwrap();
        let res = find_overlap(&top, &bottom, &OverlapOptions::default()).unwrap();
        // shifted[c] = bottom[c-10]: content moved left by 10 -> dx = +10.
        assert!(
            (res.best.dx - 10).abs() <= 8,
            "dx = {}, expected ~10",
            res.best.dx
        );
    }

    #[test]
    fn confidence_drops_with_repeated_content() {
        // A page made of identical bands produces ambiguous matches.
        let w = 400u32;
        let mut a = RgbImage::from_fn(w, 800, |x, y| {
            let v = ((y % 60) + (x / 90)) as u8;
            image::Rgb([v, v, v])
        });
        // Break the exact symmetry at a single known location.
        for x in 0..w {
            a.put_pixel(x, 700, image::Rgb([9, 9, 9]));
        }
        let top = luma_from_rgb(&a);
        let bottom = top.clone(); // identical images -> exact match at dy=0
        let res = find_overlap(&top, &bottom, &OverlapOptions::default()).unwrap();
        assert!(res.best.dy == 0);
        assert!(
            res.confidence < 0.9,
            "repeated content should lower confidence, got {:.2}",
            res.confidence
        );
    }
}
