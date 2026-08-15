//! Row-wise image encoders used by the streaming composer.
//!
//! The PNG encoder is fully streaming: scanlines are deflated incrementally
//! and flushed into multiple IDAT chunks, so peak memory stays bounded by the
//! block buffer. The JPEG encoder buffers rows and encodes once at the end
//! (JPEG has no scanline API in the pure-Rust encoder); use PNG for very
//! long outputs.

use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use flate2::write::ZlibEncoder;
use flate2::Compression;
use image::RgbImage;

use crate::error::{StitchError, StitchResult};

const JPEG_MAX_DIMENSION: u32 = u16::MAX as u32;
pub(crate) const MAX_PIPELINE_BYTES: u64 = 192 * 1024 * 1024;
const MAX_BUFFERED_OUTPUT_BYTES: u64 = 96 * 1024 * 1024;
const RGB_BYTES_PER_PIXEL: u64 = 3;
const TEMP_FILE_PREFIX: &str = ".pixelforge-export";
static TEMP_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Export image format.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportFormat {
    Png,
    Jpeg { quality: u8 },
    Webp,
}

/// A sink that consumes one RGB row at a time.
pub trait RowSink {
    /// Write a single RGB row (`width * 3` bytes). Called in top-to-bottom
    /// order, exactly `height` times.
    fn write_row(&mut self, rgb: &[u8]) -> StitchResult<()>;
    /// Finish the stream (flush, finalize) and report the output path.
    fn finish(self: Box<Self>) -> StitchResult<()>;
}

/// Create the right sink for `format` writing to `path` with `width`/`height`.
pub fn open_sink(
    format: ExportFormat,
    path: &Path,
    width: u32,
    height: u32,
) -> StitchResult<Box<dyn RowSink>> {
    validate_output_format(format, width, height)?;
    let file = File::create(path)
        .map_err(|e| StitchError::Export(format!("无法创建文件 {}: {e}", path.display())))?;
    let writer = BufWriter::new(file);
    match format {
        ExportFormat::Png => Ok(Box::new(PngSink::new(writer, width, height)?)),
        ExportFormat::Jpeg { quality } => {
            Ok(Box::new(JpegSink::new(writer, width, height, quality)?))
        }
        ExportFormat::Webp => Ok(Box::new(WebpSink::new(writer, width, height)?)),
    }
}

pub(crate) fn buffered_output_bytes(
    format: ExportFormat,
    width: u32,
    height: u32,
) -> StitchResult<u64> {
    validate_output_format(format, width, height)?;
    match format {
        ExportFormat::Png => Ok(0),
        ExportFormat::Jpeg { .. } | ExportFormat::Webp => {
            let bytes = rgb_bytes(width, height)?;
            if bytes > MAX_BUFFERED_OUTPUT_BYTES {
                return Err(StitchError::Export(format!(
                    "{} 输出需要缓存整图，内存需求 {} bytes，超过上限 {} bytes",
                    format_name(format),
                    bytes,
                    MAX_BUFFERED_OUTPUT_BYTES
                )));
            }
            Ok(bytes)
        }
    }
}

pub(crate) fn ensure_pipeline_budget(bytes: u64, operation: &str) -> StitchResult<()> {
    if bytes > MAX_PIPELINE_BYTES {
        return Err(StitchError::Export(format!(
            "{operation} 内存需求过大: {} bytes，超过上限 {} bytes",
            bytes, MAX_PIPELINE_BYTES
        )));
    }
    Ok(())
}

pub(crate) fn paths_alias(first: &Path, second: &Path) -> StitchResult<bool> {
    let first = comparable_path(first)?;
    let second = comparable_path(second)?;
    #[cfg(windows)]
    return Ok(first
        .to_string_lossy()
        .eq_ignore_ascii_case(&second.to_string_lossy()));
    #[cfg(not(windows))]
    Ok(first == second)
}

pub(crate) fn write_atomic<T>(
    output: &Path,
    write: impl FnOnce(&Path) -> StitchResult<T>,
) -> StitchResult<T> {
    let temporary = temporary_output_path(output);
    match write(&temporary) {
        Ok(value) => match finalize_output(&temporary, output) {
            Ok(()) => Ok(value),
            Err(error) => match remove_temporary(&temporary) {
                Ok(()) => Err(error),
                Err(cleanup) => Err(combine_export_errors(error, cleanup)),
            },
        },
        Err(error) => match remove_temporary(&temporary) {
            Ok(()) => Err(error),
            Err(cleanup) => Err(combine_export_errors(error, cleanup)),
        },
    }
}

fn validate_output_format(format: ExportFormat, width: u32, height: u32) -> StitchResult<()> {
    if width == 0 || height == 0 {
        return Err(StitchError::Export("输出尺寸不能为 0".into()));
    }
    if let ExportFormat::Jpeg { quality } = format {
        if !(1..=100).contains(&quality) {
            return Err(StitchError::Export(format!(
                "JPEG 质量必须在 1 到 100 之间: {quality}"
            )));
        }
        if width > JPEG_MAX_DIMENSION || height > JPEG_MAX_DIMENSION {
            return Err(StitchError::Export(format!(
                "JPEG 尺寸不能超过 {JPEG_MAX_DIMENSION} 像素: {width}x{height}"
            )));
        }
    }
    Ok(())
}

fn rgb_bytes(width: u32, height: u32) -> StitchResult<u64> {
    u64::from(width)
        .checked_mul(u64::from(height))
        .and_then(|pixels| pixels.checked_mul(RGB_BYTES_PER_PIXEL))
        .ok_or_else(|| StitchError::Export("输出尺寸计算溢出".into()))
}

fn format_name(format: ExportFormat) -> &'static str {
    match format {
        ExportFormat::Png => "PNG",
        ExportFormat::Jpeg { .. } => "JPEG",
        ExportFormat::Webp => "WebP",
    }
}

fn comparable_path(path: &Path) -> StitchResult<PathBuf> {
    if path.exists() {
        return fs::canonicalize(path)
            .map_err(|e| StitchError::Export(format!("无法解析路径 {}: {e}", path.display())));
    }
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let file_name = path
        .file_name()
        .ok_or_else(|| StitchError::Export(format!("输出路径无效: {}", path.display())))?;
    let parent = fs::canonicalize(parent)
        .map_err(|e| StitchError::Export(format!("无法解析输出目录 {}: {e}", parent.display())))?;
    Ok(parent.join(file_name))
}

fn temporary_output_path(output: &Path) -> PathBuf {
    let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let file_name = output
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("output");
    let temporary_name = format!(
        "{TEMP_FILE_PREFIX}-{file_name}-{}-{sequence}.tmp",
        std::process::id()
    );
    output.with_file_name(temporary_name)
}

fn finalize_output(temporary: &Path, output: &Path) -> StitchResult<()> {
    if output.exists() {
        fs::remove_file(output).map_err(|e| {
            StitchError::Export(format!("无法替换旧输出文件 {}: {e}", output.display()))
        })?;
    }
    fs::rename(temporary, output)
        .map_err(|e| StitchError::Export(format!("无法完成输出文件写入 {}: {e}", output.display())))
}

fn remove_temporary(path: &Path) -> StitchResult<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(StitchError::Export(format!(
            "无法清理临时输出文件 {}: {error}",
            path.display()
        ))),
    }
}

fn combine_export_errors(error: StitchError, cleanup: StitchError) -> StitchError {
    StitchError::Export(format!("{error}; {cleanup}"))
}

/// Target size of each IDAT chunk written to the PNG stream.
const IDAT_CHUNK_LIMIT: usize = 64 * 1024;

/// Wraps a `png::Writer` and splits a byte stream into IDAT chunks.
struct IdatWriter<W: Write> {
    png: png::Writer<W>,
    buf: Vec<u8>,
}

impl<W: Write> IdatWriter<W> {
    fn flush_chunk(&mut self) -> Result<(), StitchError> {
        if self.buf.is_empty() {
            return Ok(());
        }
        let data = std::mem::take(&mut self.buf);
        self.png
            .write_chunk(png::chunk::IDAT, &data)
            .map_err(|e| StitchError::Export(format!("PNG IDAT 写入失败: {e}")))
    }
}

impl<W: Write> Write for IdatWriter<W> {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.buf.extend_from_slice(data);
        if self.buf.len() >= IDAT_CHUNK_LIMIT {
            self.flush_chunk().map_err(std::io::Error::other)?;
        }
        Ok(data.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        // Buffered; flushed by `finish`.
        Ok(())
    }
}

/// Streaming PNG encoder (RGB8, filter 0, incremental deflate).
struct PngSink<W: Write> {
    zlib: ZlibEncoder<IdatWriter<W>>,
    rows_written: u32,
    height: u32,
}

impl<W: Write> PngSink<W> {
    fn new(writer: W, width: u32, height: u32) -> StitchResult<Self> {
        let mut encoder = png::Encoder::new(writer, width, height);
        encoder.set_color(png::ColorType::Rgb);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_filter(png::FilterType::NoFilter);
        let png = encoder
            .write_header()
            .map_err(|e| StitchError::Export(format!("PNG 头部写入失败: {e}")))?;
        let idat = IdatWriter {
            png,
            buf: Vec::new(),
        };
        let zlib = ZlibEncoder::new(idat, Compression::default());
        Ok(Self {
            zlib,
            rows_written: 0,
            height,
        })
    }
}

impl<W: Write> RowSink for PngSink<W> {
    fn write_row(&mut self, rgb: &[u8]) -> StitchResult<()> {
        // Scanline filter byte (0 = none) precedes the row data.
        self.zlib
            .write_all(&[0])
            .map_err(|e| StitchError::Export(format!("PNG 写入失败: {e}")))?;
        self.zlib
            .write_all(rgb)
            .map_err(|e| StitchError::Export(format!("PNG 写入失败: {e}")))?;
        self.rows_written += 1;
        Ok(())
    }

    fn finish(self: Box<Self>) -> StitchResult<()> {
        let Self {
            zlib,
            rows_written,
            height,
        } = *self;
        if rows_written != height {
            return Err(StitchError::Export(format!(
                "PNG 行数不匹配: 收到 {rows_written} 行, 期望 {height} 行"
            )));
        }
        let mut idat = zlib
            .finish()
            .map_err(|e| StitchError::Export(format!("PNG 压缩失败: {e}")))?;
        idat.flush_chunk()?;
        idat.png
            .finish()
            .map_err(|e| StitchError::Export(format!("PNG 收尾失败: {e}")))
    }
}

/// JPEG encoder: buffers rows, encodes once at the end.
struct JpegSink<W: Write> {
    image: RgbImage,
    writer: Option<W>,
    quality: u8,
    width: u32,
    height: u32,
    rows_written: u32,
}

impl<W: Write> JpegSink<W> {
    fn new(writer: W, width: u32, height: u32, quality: u8) -> StitchResult<Self> {
        if width > JPEG_MAX_DIMENSION || height > JPEG_MAX_DIMENSION {
            return Err(StitchError::Export(format!(
                "JPEG 尺寸不能超过 {JPEG_MAX_DIMENSION} 像素: {width}x{height}"
            )));
        }
        Ok(Self {
            image: RgbImage::new(width, height),
            writer: Some(writer),
            quality,
            width,
            height,
            rows_written: 0,
        })
    }
}

impl<W: Write> RowSink for JpegSink<W> {
    fn write_row(&mut self, rgb: &[u8]) -> StitchResult<()> {
        let expected = (self.width * 3) as usize;
        if rgb.len() != expected {
            return Err(StitchError::Export(format!(
                "JPEG 行宽不匹配: 收到 {} 字节, 期望 {}",
                rgb.len(),
                expected
            )));
        }
        if self.rows_written >= self.height {
            return Err(StitchError::Export("JPEG 行数超出预期".into()));
        }
        let raw = self.image.as_mut();
        let start = (self.rows_written as usize) * (self.width as usize) * 3;
        let end = start + rgb.len();
        raw[start..end].copy_from_slice(rgb);
        self.rows_written += 1;
        Ok(())
    }

    fn finish(self: Box<Self>) -> StitchResult<()> {
        let Self {
            image,
            writer,
            quality,
            width,
            rows_written,
            height,
            ..
        } = *self;
        if rows_written != height {
            return Err(StitchError::Export(format!(
                "JPEG 行数不匹配: 收到 {rows_written} 行, 期望 {height} 行"
            )));
        }
        let writer = writer.expect("writer present until finish");
        let encoder = jpeg_encoder::Encoder::new(writer, quality);
        encoder
            .encode(
                image.as_raw(),
                width as u16,
                height as u16,
                jpeg_encoder::ColorType::Rgb,
            )
            .map_err(|e| StitchError::Export(format!("JPEG 编码失败: {e}")))
    }
}

/// Lossless WebP encoder: buffers rows, then encodes the complete image.
struct WebpSink<W: Write> {
    image: RgbImage,
    writer: Option<W>,
    width: u32,
    height: u32,
    rows_written: u32,
}

impl<W: Write> WebpSink<W> {
    fn new(writer: W, width: u32, height: u32) -> StitchResult<Self> {
        Ok(Self {
            image: RgbImage::new(width, height),
            writer: Some(writer),
            width,
            height,
            rows_written: 0,
        })
    }
}

impl<W: Write> RowSink for WebpSink<W> {
    fn write_row(&mut self, rgb: &[u8]) -> StitchResult<()> {
        let expected = (self.width * 3) as usize;
        if rgb.len() != expected {
            return Err(StitchError::Export(format!(
                "WebP 行宽不匹配: 收到 {} 字节, 期望 {}",
                rgb.len(),
                expected
            )));
        }
        if self.rows_written >= self.height {
            return Err(StitchError::Export("WebP 行数超出预期".into()));
        }
        let raw = self.image.as_mut();
        let start = (self.rows_written as usize) * (self.width as usize) * 3;
        let end = start + rgb.len();
        raw[start..end].copy_from_slice(rgb);
        self.rows_written += 1;
        Ok(())
    }

    fn finish(self: Box<Self>) -> StitchResult<()> {
        let Self {
            image,
            writer,
            width,
            height,
            rows_written,
        } = *self;
        if rows_written != height {
            return Err(StitchError::Export(format!(
                "WebP 行数不匹配: 收到 {rows_written} 行, 期望 {height} 行"
            )));
        }
        let writer = writer.expect("writer present until finish");
        image::codecs::webp::WebPEncoder::new_lossless(writer)
            .encode(
                image.as_raw(),
                width,
                height,
                image::ExtendedColorType::Rgb8,
            )
            .map_err(|e| StitchError::Export(format!("WebP 编码失败: {e}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_roundtrip() {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("stitch_test_{}.png", std::process::id()));
        let (w, h) = (16u32, 8u32);
        {
            let mut sink = open_sink(ExportFormat::Png, &path, w, h).unwrap();
            let mut row = vec![0u8; (w * 3) as usize];
            for y in 0..h {
                for x in 0..w {
                    row[(x * 3) as usize] = (x * 16) as u8;
                    row[(x * 3 + 1) as usize] = (y * 32) as u8;
                    row[(x * 3 + 2) as usize] = 128;
                }
                sink.write_row(&row).unwrap();
            }
            sink.finish().unwrap();
        }
        let img = image::open(&path).unwrap().into_rgb8();
        assert_eq!(img.dimensions(), (w, h));
        assert_eq!(img.get_pixel(1, 1), &image::Rgb([16, 32, 128]));
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn png_large_roundtrip_reads_every_idat_chunk() {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("stitch_large_png_{}.png", std::process::id()));
        let (w, h) = (1200u32, 4571u32);
        {
            let mut sink = open_sink(ExportFormat::Png, &path, w, h).unwrap();
            let mut row = vec![0u8; (w * 3) as usize];
            for y in 0..h {
                for x in 0..w {
                    let offset = (x * 3) as usize;
                    row[offset] = (x.wrapping_mul(13) as u8).wrapping_add(y as u8);
                    row[offset + 1] = (y.wrapping_mul(7) as u8).wrapping_add(x as u8);
                    row[offset + 2] = (x ^ y) as u8;
                }
                sink.write_row(&row).unwrap();
            }
            sink.finish().unwrap();
        }
        let img = image::open(&path).unwrap().into_rgb8();
        assert_eq!(img.dimensions(), (w, h));
        assert_eq!(
            img.get_pixel(117, 3200),
            &image::Rgb([
                ((117 * 13 + 3200) & 255) as u8,
                ((3200 * 7 + 117) & 255) as u8,
                (117 ^ 3200) as u8
            ])
        );
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn jpeg_roundtrip() {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("stitch_test_{}.jpg", std::process::id()));
        let (w, h) = (32u32, 8u32);
        {
            let mut sink = open_sink(ExportFormat::Jpeg { quality: 90 }, &path, w, h).unwrap();
            let row = vec![128u8; (w * 3) as usize];
            for _ in 0..h {
                sink.write_row(&row).unwrap();
            }
            sink.finish().unwrap();
        }
        let img = image::open(&path).unwrap().into_rgb8();
        assert_eq!(img.dimensions(), (w, h));
        // Flat gray survives lossy encoding approximately.
        let px = img.get_pixel(4, 4);
        assert!((px[0] as i32 - 128).abs() <= 6, "got {:?}", px);
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn jpeg_rejects_dimensions_above_encoder_limit() {
        let path =
            std::env::temp_dir().join(format!("stitch_jpeg_limit_{}.jpg", std::process::id()));
        assert!(open_sink(ExportFormat::Jpeg { quality: 90 }, &path, 65_536, 1).is_err());
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn jpeg_rejects_invalid_quality_before_creating_file() {
        let path =
            std::env::temp_dir().join(format!("stitch_jpeg_quality_{}.jpg", std::process::id()));
        assert!(open_sink(ExportFormat::Jpeg { quality: 0 }, &path, 16, 8).is_err());
        assert!(!path.exists());
    }

    #[test]
    fn webp_roundtrip() {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("stitch_test_{}.webp", std::process::id()));
        let (w, h) = (16u32, 8u32);
        {
            let mut sink = open_sink(ExportFormat::Webp, &path, w, h).unwrap();
            let row = vec![42u8; (w * 3) as usize];
            for _ in 0..h {
                sink.write_row(&row).unwrap();
            }
            sink.finish().unwrap();
        }
        let img = image::open(&path).unwrap().into_rgb8();
        assert_eq!(img.dimensions(), (w, h));
        assert_eq!(img.get_pixel(1, 1), &image::Rgb([42, 42, 42]));
        std::fs::remove_file(&path).ok();
    }
}
