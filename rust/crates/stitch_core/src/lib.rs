//! Stitch engine: automatic screenshot stitching with fixed-element handling.
//!
//! Modules:
//! - [`image`]: loading, downsampling, gradients
//! - [`overlap`]: coarse-to-fine seam search with confidence
//! - [`fixed_elements`]: fixed top and bottom bar detection
//! - [`compose`]: streaming block-wise export
//! - [`encoder`]: row-wise PNG/JPEG sinks

// 图像算法内部函数参数较多（图像对 + 选项 + 采样），统一允许该 lint。
#![allow(clippy::too_many_arguments)]

pub mod compose;
pub mod encoder;
pub mod error;
pub mod fixed_elements;
pub mod image;
pub mod overlap;
pub mod redaction;

pub use compose::{build_plan, compose_to_file, ComposeConfig, ComposePlan, SeamEntry};
pub use encoder::ExportFormat;
pub use error::{StitchError, StitchResult};
pub use fixed_elements::{detect_fixed, FixedElements, FixedOptions, Region};
pub use image::{
    downsample, gradient_of, load_info, load_luma, luma_from_rgb, sobel, GradientImage, ImageInfo,
    LumaImage, Scale,
};
pub use overlap::{
    find_overlap, scale_candidates, Candidate, OverlapOptions, OverlapResult,
    DEFAULT_MAX_DX_TOLERANCE, DEFAULT_MIN_OVERLAP_RATIO,
};
pub use redaction::{redact_to_file, RedactionRect, RedactionStyle};

/// High-level convenience: run the full analysis pipeline for one adjacent
/// pair (seam + fixed elements) and return both results.
pub fn analyze_pair(
    top: &LumaImage,
    bottom: &LumaImage,
    overlap_opts: &OverlapOptions,
    fixed_opts: &FixedOptions,
) -> StitchResult<(OverlapResult, FixedElements)> {
    let seam = find_overlap(top, bottom, overlap_opts)?;
    let fixed = detect_fixed(top, bottom, fixed_opts);
    Ok((seam, fixed))
}
