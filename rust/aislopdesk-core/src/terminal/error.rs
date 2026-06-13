//! Error type for the terminal-path (PTY) wire codecs — a port of Swift
//! `AislopdeskProtocol.AislopdeskError`.
//!
//! These are decode-time faults: a frame too large to be legitimate, a truncated body
//! that can never complete, an unknown message type, or a body whose contents do not
//! match the type's declared layout. A *partial* frame that might still complete is
//! **not** an error — the decoder simply waits (see [`FrameDecoder`](super::FrameDecoder)).
//!
//! This is a SEPARATE type from [`VideoProtocolError`](crate::VideoProtocolError): the
//! Swift `AislopdeskProtocol` and `AislopdeskVideoProtocol` targets are independent
//! modules with independent error types, and this port preserves that boundary. The
//! variant is the contract callers branch on; the `MalformedBody` / `FrameTooLarge`
//! payloads are diagnostic and *not* part of the wire format.

use core::fmt;

/// Errors raised while decoding terminal-path wire frames.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalProtocolError {
    /// A frame's length prefix exceeded [`MAX_FRAME_PAYLOAD_LENGTH`](super::MAX_FRAME_PAYLOAD_LENGTH).
    /// The payload carries the offending claimed payload length.
    FrameTooLarge(usize),

    /// A complete frame's body was shorter than the message type requires (e.g. an
    /// `exit` frame whose payload is fewer than 4 bytes). Distinct from a partial TCP
    /// read, which is not an error.
    Truncated,

    /// The frame's first byte was not a recognized message type. The payload carries the
    /// unknown type byte.
    UnknownMessageType(u8),

    /// A body had the right length but malformed contents (e.g. invalid UTF-8 in a
    /// `title`). The payload is a short human-readable reason.
    MalformedBody(String),
}

impl TerminalProtocolError {
    /// Builds a [`TerminalProtocolError::MalformedBody`] from any displayable hint.
    pub fn malformed(hint: impl Into<String>) -> Self {
        Self::MalformedBody(hint.into())
    }
}

impl fmt::Display for TerminalProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::FrameTooLarge(len) => write!(f, "frame too large: {len}"),
            Self::Truncated => f.write_str("truncated"),
            Self::UnknownMessageType(byte) => write!(f, "unknown message type: {byte}"),
            Self::MalformedBody(hint) => write!(f, "malformed body: {hint}"),
        }
    }
}

impl std::error::Error for TerminalProtocolError {}

/// Result alias for the terminal-path codecs.
pub type Result<T> = core::result::Result<T, TerminalProtocolError>;
