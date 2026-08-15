//! C FFI surface for the Stitch app.
//!
//! All functions take/return JSON strings so the boundary stays trivially
//! serializable; pixel buffers never cross the FFI (only file paths, seams
//! and crop settings). Callers must free returned strings with `stitch_free_string`.

// 导出函数按 C ABI 约定解引用裸指针，调用方（Dart FFI）保证有效性。
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use serde::{Deserialize, Serialize};
use stitch_core::{
    downsample, scale_candidates, ComposeConfig, ExportFormat, FixedOptions, OverlapOptions,
    RedactionRect, RedactionStyle, Scale, SeamEntry,
};

const MAX_ANALYSIS_PIXELS: u64 = 2_000_000;

/// Generic response envelope: `{"ok": true, "data": ...}` or
/// `{"ok": false, "error": "..."}`.
#[derive(Serialize)]
struct Response<T: Serialize> {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

impl<T: Serialize> Response<T> {
    fn ok(data: T) -> Self {
        Self {
            ok: true,
            data: Some(data),
            error: None,
        }
    }
    fn err(msg: String) -> Self {
        Self {
            ok: false,
            data: None,
            error: Some(msg),
        }
    }
}

/// Convert a non-null C string into a Rust string.
unsafe fn cstr_arg(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("字符串参数不能为空".into());
    }
    Ok(CStr::from_ptr(ptr).to_string_lossy().into_owned())
}

fn run_ffi<T>(operation: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    catch_unwind(AssertUnwindSafe(operation))
        .unwrap_or_else(|_| Err("原生处理发生未捕获异常".into()))
}

/// Serialize and return a response string; caller frees it with stitch_free_string.
unsafe fn write_response<T: Serialize>(
    out_json: *mut *mut c_char,
    result: Result<T, String>,
) -> i32 {
    if out_json.is_null() {
        return 2;
    }
    *out_json = std::ptr::null_mut();
    let (json, ok) = match result {
        Ok(data) => (
            serde_json::to_string(&Response::ok(data))
                .unwrap_or_else(|_| r#"{"ok":false,"error":"响应序列化失败"}"#.into()),
            true,
        ),
        Err(message) => (
            serde_json::to_string(&Response::<serde_json::Value>::err(message))
                .unwrap_or_else(|_| r#"{"ok":false,"error":"错误响应序列化失败"}"#.into()),
            false,
        ),
    };
    let cstr = match CString::new(json) {
        Ok(value) => value,
        Err(_) => return 3,
    };
    *out_json = cstr.into_raw();
    if ok {
        0
    } else {
        1
    }
}

/// Free a string previously returned by this crate.
#[no_mangle]
pub extern "C" fn stitch_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}

/// Analysis options (mirrors Flutter-side defaults).
#[derive(Deserialize)]
struct PairOptions {
    #[serde(default = "default_min_overlap")]
    min_overlap_ratio: f32,
    #[serde(default = "default_max_dx")]
    max_dx_tolerance: u32,
}

fn default_min_overlap() -> f32 {
    stitch_core::DEFAULT_MIN_OVERLAP_RATIO
}

fn default_max_dx() -> u32 {
    stitch_core::DEFAULT_MAX_DX_TOLERANCE
}

fn analysis_scale_factor(width: u32, height: u32) -> u32 {
    let pixels = width as u64 * height as u64;
    if pixels <= MAX_ANALYSIS_PIXELS {
        return 1;
    }
    ((pixels as f64 / MAX_ANALYSIS_PIXELS as f64).sqrt().ceil() as u32).max(1)
}

/// Seam + fixed-element analysis for one adjacent pair.
#[derive(Serialize)]
struct PairAnalysis {
    plausible: bool,
    confidence: f32,
    dx: i32,
    dy: u32,
    candidates: Vec<CandidateJson>,
    top_bar: Option<RegionJson>,
    bottom_bar: Option<RegionJson>,
    bottom_whitespace: Option<RegionJson>,
}

#[derive(Serialize)]
struct CandidateJson {
    dx: i32,
    dy: u32,
    cost: f64,
}

#[derive(Serialize, Deserialize, Clone, Copy)]
struct RegionJson {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
}

/// Analyze one adjacent pair of screenshots.
///
/// Returns JSON: `{"ok":true,"data":{...PairAnalysis}}`.
#[no_mangle]
pub extern "C" fn stitch_analyze_pair(
    top_path: *const c_char,
    bottom_path: *const c_char,
    opts_json: *const c_char,
    out_json: *mut *mut c_char,
) -> i32 {
    if out_json.is_null() {
        return 2;
    }
    let result = run_ffi(|| -> Result<PairAnalysis, String> {
        let top_path = unsafe { cstr_arg(top_path) }?;
        let bottom_path = unsafe { cstr_arg(bottom_path) }?;
        let opts_json = unsafe { cstr_arg(opts_json) }?;
        let opts: PairOptions =
            serde_json::from_str(&opts_json).map_err(|e| format!("选项解析失败: {e}"))?;
        let top =
            stitch_core::load_luma(std::path::Path::new(&top_path)).map_err(|e| e.to_string())?;
        let bottom = stitch_core::load_luma(std::path::Path::new(&bottom_path))
            .map_err(|e| e.to_string())?;
        let factor =
            analysis_scale_factor(top.width.max(bottom.width), top.height.max(bottom.height));
        let top_analysis = downsample(&top, factor);
        let bottom_analysis = downsample(&bottom, factor);
        let scaled_max_dx = opts
            .max_dx_tolerance
            .saturating_add(factor.saturating_sub(1))
            / factor;
        let overlap_opts = OverlapOptions {
            min_overlap_ratio: opts.min_overlap_ratio,
            max_dx_tolerance: scaled_max_dx.max(1),
            ..OverlapOptions::default()
        };
        let (scaled_seam, _) = stitch_core::analyze_pair(
            &top_analysis,
            &bottom_analysis,
            &overlap_opts,
            &FixedOptions::default(),
        )
        .map_err(|e| e.to_string())?;
        let seam = scale_candidates(&scaled_seam, Scale { factor });
        let fixed = stitch_core::detect_fixed(&top, &bottom, &FixedOptions::default());
        let cands = seam
            .candidates
            .iter()
            .take(seam.n_candidates)
            .map(|c| CandidateJson {
                dx: c.dx,
                dy: c.dy,
                cost: c.cost,
            })
            .collect();
        Ok(PairAnalysis {
            plausible: seam.plausible,
            confidence: seam.confidence,
            dx: seam.best.dx,
            dy: seam.best.dy,
            candidates: cands,
            top_bar: fixed.top_bar.map(|r| RegionJson {
                x: r.x,
                y: r.y,
                w: r.w,
                h: r.h,
            }),
            bottom_bar: fixed.bottom_bar.map(|r| RegionJson {
                x: r.x,
                y: r.y,
                w: r.w,
                h: r.h,
            }),
            bottom_whitespace: fixed.bottom_whitespace.map(|r| RegionJson {
                x: r.x,
                y: r.y,
                w: r.w,
                h: r.h,
            }),
        })
    });
    unsafe { write_response(out_json, result) }
}

/// Compose request.
#[derive(Deserialize)]
struct ComposeRequest {
    paths: Vec<String>,
    seams: Vec<SeamEntryJson>,
    top_bars: Vec<u32>,
    bottom_bars: Vec<u32>,
    #[serde(default)]
    last_bottom_whitespace: u32,
    remove_first_status_bar: bool,
    trim_last_bottom_whitespace: bool,
    #[serde(default)]
    retained_bottom_edge: u32,
    format: String, // "png" | "jpeg"
    quality: u8,
    #[serde(default = "default_scale_percent")]
    scale_percent: u32,
    out_path: String,
}

fn default_scale_percent() -> u32 {
    100
}

#[derive(Deserialize)]
struct SeamEntryJson {
    dx: i32,
    dy: u32,
}

#[derive(Serialize)]
struct ComposeResultJson {
    width: u32,
    height: u32,
}

/// Export the stitched image. Returns
/// `{"ok":true,"data":{"width":W,"height":H}}`.
#[no_mangle]
pub extern "C" fn stitch_compose(request_json: *const c_char, out_json: *mut *mut c_char) -> i32 {
    if out_json.is_null() {
        return 2;
    }
    let result = run_ffi(|| -> Result<ComposeResultJson, String> {
        let request_json = unsafe { cstr_arg(request_json) }?;
        let req: ComposeRequest =
            serde_json::from_str(&request_json).map_err(|e| format!("请求解析失败: {e}"))?;
        let format = match req.format.as_str() {
            "png" => ExportFormat::Png,
            "jpeg" => ExportFormat::Jpeg {
                quality: req.quality,
            },
            "webp" => ExportFormat::Webp,
            other => return Err(format!("未知格式: {other}")),
        };
        let config = ComposeConfig {
            format,
            scale_percent: req.scale_percent,
            seams: req
                .seams
                .iter()
                .map(|s| SeamEntry { dx: s.dx, dy: s.dy })
                .collect(),
            top_bars: req.top_bars.clone(),
            bottom_bars: req.bottom_bars.clone(),
            last_bottom_whitespace: req.last_bottom_whitespace,
            remove_first_status_bar: req.remove_first_status_bar,
            trim_last_bottom_whitespace: req.trim_last_bottom_whitespace,
            retained_bottom_edge: req.retained_bottom_edge,
        };
        let paths: Vec<std::path::PathBuf> =
            req.paths.iter().map(std::path::PathBuf::from).collect();
        let out = std::path::PathBuf::from(&req.out_path);
        stitch_core::compose_to_file(&paths, &config, &out, |_, _| {})
            .map_err(|e| e.to_string())?;
        // Re-read the plan for output dimensions.
        let infos: Vec<stitch_core::ImageInfo> = paths
            .iter()
            .map(|p| stitch_core::load_info(p))
            .collect::<Result<_, _>>()
            .map_err(|e| e.to_string())?;
        let heights: Vec<u32> = infos.iter().map(|i| i.height).collect();
        let width = infos[0].width;
        let plan = stitch_core::build_plan(width, &heights, &config).map_err(|e| e.to_string())?;
        Ok(ComposeResultJson {
            width: plan.width,
            height: plan.height,
        })
    });
    unsafe { write_response(out_json, result) }
}

/// Redaction request.
#[derive(Deserialize)]
struct RedactionRequest {
    source_path: String,
    masks: Vec<RedactionMaskJson>,
    format: String,
    quality: u8,
    out_path: String,
}

#[derive(Deserialize)]
struct RedactionMaskJson {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    #[serde(default = "default_mask_color")]
    color: u32,
    #[serde(default)]
    style: String,
    #[serde(default)]
    adaptive: bool,
}

fn default_mask_color() -> u32 {
    0xFF000000
}

#[derive(Serialize)]
struct RedactionResultJson {
    width: u32,
    height: u32,
}

/// Apply opaque masks to one image and re-encode it without source metadata.
#[no_mangle]
pub extern "C" fn stitch_redact(request_json: *const c_char, out_json: *mut *mut c_char) -> i32 {
    if out_json.is_null() {
        return 2;
    }
    let result = run_ffi(|| -> Result<RedactionResultJson, String> {
        let request_json = unsafe { cstr_arg(request_json) }?;
        let req: RedactionRequest =
            serde_json::from_str(&request_json).map_err(|e| format!("请求解析失败: {e}"))?;
        let format = match req.format.as_str() {
            "png" => ExportFormat::Png,
            "jpeg" => ExportFormat::Jpeg {
                quality: req.quality,
            },
            "webp" => ExportFormat::Webp,
            other => return Err(format!("未知格式: {other}")),
        };
        let mut masks = Vec::with_capacity(req.masks.len());
        for mask in &req.masks {
            let style = match mask.style.as_str() {
                "" | "solid" => RedactionStyle::Solid,
                "blur" => RedactionStyle::Blur,
                other => return Err(format!("未知遮挡样式: {other}")),
            };
            masks.push(RedactionRect {
                x: mask.x,
                y: mask.y,
                w: mask.w,
                h: mask.h,
                color: [
                    ((mask.color >> 16) & 0xFF) as u8,
                    ((mask.color >> 8) & 0xFF) as u8,
                    (mask.color & 0xFF) as u8,
                ],
                style,
                adaptive: mask.adaptive,
            });
        }
        let (width, height) = stitch_core::redact_to_file(
            std::path::Path::new(&req.source_path),
            &masks,
            format,
            std::path::Path::new(&req.out_path),
        )
        .map_err(|e| e.to_string())?;
        Ok(RedactionResultJson { width, height })
    });
    unsafe { write_response(out_json, result) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::GenericImageView;

    #[test]
    fn analyze_pair_ffi_roundtrip() {
        // Build two synthetic screenshots on disk and run the FFI function.
        let dir = std::env::temp_dir();
        let p1 = dir.join(format!("stitch_ffi_{}_a.png", std::process::id()));
        let p2 = dir.join(format!("stitch_ffi_{}_b.png", std::process::id()));
        let (w, h) = (120u32, 300u32);
        // A tall page with non-repeating pixel noise, then two windows
        // separated by a known scroll.
        let page = image::RgbImage::from_fn(w, 2 * h, |x, y| {
            let v = (y.wrapping_mul(2654435761) ^ x.wrapping_mul(40503)) as u8;
            image::Rgb([v, v, v])
        });
        let scroll = 90u32;
        let a: image::RgbImage = page.view(0, 0, w, h).to_image();
        let b: image::RgbImage = page.view(0, h - scroll, w, h).to_image();
        a.save(&p1).unwrap();
        b.save(&p2).unwrap();

        let top_c = CString::new(p1.to_str().unwrap()).unwrap();
        let bottom_c = CString::new(p2.to_str().unwrap()).unwrap();
        let opts = CString::new("{}").unwrap();
        let mut out: *mut c_char = std::ptr::null_mut();
        let code = stitch_analyze_pair(top_c.as_ptr(), bottom_c.as_ptr(), opts.as_ptr(), &mut out);
        assert_eq!(code, 0, "analyze failed");
        let json = unsafe { CStr::from_ptr(out) }
            .to_string_lossy()
            .into_owned();
        stitch_free_string(out);
        let resp: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert!(resp["ok"].as_bool().unwrap());
        let dy = resp["data"]["dy"].as_u64().unwrap();
        // dy = row of the top image where the bottom image starts.
        let expected = (h - scroll) as u64;
        assert!(
            (dy as i64 - expected as i64).abs() <= 8,
            "dy = {dy}, expected {expected}"
        );
        std::fs::remove_file(&p1).ok();
        std::fs::remove_file(&p2).ok();
    }

    #[test]
    fn compose_ffi_roundtrip() {
        let dir = std::env::temp_dir();
        let p1 = dir.join(format!("stitch_ffi_c_{}_a.png", std::process::id()));
        let p2 = dir.join(format!("stitch_ffi_c_{}_b.png", std::process::id()));
        let out = dir.join(format!("stitch_ffi_c_{}_out.png", std::process::id()));
        let (w, h) = (120u32, 200u32);
        let mk = |id: u8| {
            image::RgbImage::from_fn(w, h, |_, y| {
                let v = (y as u8).wrapping_mul(3).wrapping_add(id.wrapping_mul(37));
                image::Rgb([v, v, v])
            })
        };
        mk(0).save(&p1).unwrap();
        mk(1).save(&p2).unwrap();
        let req = serde_json::json!({
            "paths": [p1.to_str(), p2.to_str()],
            "seams": [{"dx": 0, "dy": 60}],
            "top_bars": [0, 0],
            "bottom_bars": [0, 0],
            "remove_first_status_bar": false,
            "trim_last_bottom_whitespace": false,
            "format": "png",
            "quality": 90,
            "out_path": out.to_str(),
        });
        let req_c = CString::new(req.to_string()).unwrap();
        let mut out_ptr: *mut c_char = std::ptr::null_mut();
        let code = stitch_compose(req_c.as_ptr(), &mut out_ptr);
        assert_eq!(code, 0, "compose failed");
        let json = unsafe { CStr::from_ptr(out_ptr) }
            .to_string_lossy()
            .into_owned();
        stitch_free_string(out_ptr);
        let resp: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert!(resp["ok"].as_bool().unwrap());
        let img = image::open(&out).unwrap().into_rgb8();
        assert_eq!(img.dimensions(), (w, 60 + h));
        for p in [&p1, &p2, &out] {
            std::fs::remove_file(p).ok();
        }
    }

    #[test]
    fn redact_ffi_roundtrip() {
        let dir = std::env::temp_dir();
        let source = dir.join(format!("stitch_redact_{}_source.png", std::process::id()));
        let output = dir.join(format!("stitch_redact_{}_output.png", std::process::id()));
        image::RgbImage::from_fn(4, 3, |x, y| image::Rgb([x as u8, y as u8, 9]))
            .save(&source)
            .unwrap();
        let request = serde_json::json!({
            "source_path": source.to_str(),
            "masks": [{"x": 1, "y": 1, "w": 2, "h": 1, "color": 4278190080u32}],
            "format": "png",
            "quality": 95,
            "out_path": output.to_str(),
        });
        let request_c = CString::new(request.to_string()).unwrap();
        let mut out: *mut c_char = std::ptr::null_mut();
        let code = stitch_redact(request_c.as_ptr(), &mut out);
        assert_eq!(code, 0, "redaction failed");
        let json = unsafe { CStr::from_ptr(out) }
            .to_string_lossy()
            .into_owned();
        stitch_free_string(out);
        let response: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert!(response["ok"].as_bool().unwrap());
        let image = image::open(&output).unwrap().into_rgb8();
        assert_eq!(image.dimensions(), (4, 3));
        assert_eq!(image.get_pixel(1, 1).0, [0, 0, 0]);
        std::fs::remove_file(source).ok();
        std::fs::remove_file(output).ok();
    }
}
