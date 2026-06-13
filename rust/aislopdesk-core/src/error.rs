//! Error type for the video-path wire codecs.
//!
//! Mirrors Swift `AislopdeskVideoProtocol.VideoProtocolError`. The variant is the
//! contract that callers branch on (truncated vs malformed); the `Malformed` payload
//! is a human-readable field hint that is *not* part of the wire format, so parity
//! tests assert on the variant, not the string.

use core::fmt;

/// Errors raised while decoding video-path wire messages.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VideoProtocolError {
    /// Not enough bytes remained to satisfy a fixed-size field.
    Truncated,
    /// A field held a value outside its permitted range (e.g. an unknown tag, a
    /// non-finite float, an out-of-range enum discriminant).
    Malformed(String),
}

impl VideoProtocolError {
    /// Builds a [`VideoProtocolError::Malformed`] from any displayable hint.
    pub fn malformed(hint: impl Into<String>) -> Self {
        Self::Malformed(hint.into())
    }
}

impl fmt::Display for VideoProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Truncated => f.write_str("truncated"),
            Self::Malformed(hint) => write!(f, "malformed: {hint}"),
        }
    }
}

impl std::error::Error for VideoProtocolError {}

/// Result alias for the video-path codecs.
pub type Result<T> = core::result::Result<T, VideoProtocolError>;
