//! Structured error types for the stitch engine.

use std::fmt;

/// Errors that can occur anywhere in the stitching pipeline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StitchError {
    /// The image file could not be decoded.
    Decode(String),
    /// The image has an unsupported colour type or bit depth.
    UnsupportedImage(String),
    /// An image failed to pass validation (empty, corrupt metadata, ...).
    InvalidImage(String),
    /// The overlap search failed because the inputs are incompatible.
    Search(String),
    /// Not enough reliable seams were found to compose the image.
    InsufficientSeams { found: usize, required: usize },
    /// Export failed (encode, write, size limits, ...).
    Export(String),
    /// Internal invariant violation; indicates a bug.
    Internal(String),
}

impl fmt::Display for StitchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Decode(msg) => write!(f, "无法解码图片: {msg}"),
            Self::UnsupportedImage(msg) => write!(f, "不支持的图片格式: {msg}"),
            Self::InvalidImage(msg) => write!(f, "图片无效: {msg}"),
            Self::Search(msg) => write!(f, "重叠检测失败: {msg}"),
            Self::InsufficientSeams { found, required } => {
                write!(f, "有效接缝不足 ({found}/{required})，请手动调整重叠区域")
            }
            Self::Export(msg) => write!(f, "导出失败: {msg}"),
            Self::Internal(msg) => write!(f, "内部错误: {msg}"),
        }
    }
}

impl std::error::Error for StitchError {}

/// Convenience result alias.
pub type StitchResult<T> = Result<T, StitchError>;

/// Helper macro to build [`StitchError::Internal`] from format arguments.
#[macro_export]
macro_rules! internal_err {
    ($($arg:tt)*) => {
        $crate::StitchError::Internal(format!($($arg)*))
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_display_is_user_facing() {
        let err = StitchError::Decode("not a png".into());
        assert!(err.to_string().contains("无法解码图片"));
    }

    #[test]
    fn insufficient_seams_message_includes_counts() {
        let err = StitchError::InsufficientSeams {
            found: 1,
            required: 2,
        };
        let msg = err.to_string();
        assert!(msg.contains('1'));
        assert!(msg.contains('2'));
    }
}
