//! The terminal (PTY) wire protocol — the canonical terminal/PTY wire protocol; the Swift
//! `AislopdeskProtocol` shell tracks it (golden parity).
//!
//! This is the PATH-1 byte pipeline that carries the remote terminal: the length-prefixed
//! [`WireMessage`] frame (PTY output/input, resize, handshake, title, bell, command status,
//! notifications, RTT ping/pong), its streaming [`FrameDecoder`], and the [`mux`] layer that
//! multiplexes many such channels over one TCP connection with SSH-style framing and
//! per-channel credit flow control.
//!
//! It is a **separate namespace** from the crate's video path
//! ([`crate::video_control`] et al.): the Swift `AislopdeskProtocol` and
//! `AislopdeskVideoProtocol` shells are independent modules with their own error type and
//! big-endian helpers — this core preserves that boundary, hence the terminal-local
//! [`TerminalProtocolError`] and [`reader::BigEndianReader`]. Like the rest of the crate it
//! is 100% safe, dependency-free, and never panics on untrusted input (every decoder of
//! network bytes returns [`Result`]).

pub mod error;
pub mod frame_decoder;
pub mod mux;
pub mod reader;
pub mod session;
pub mod wire_message;

pub use error::{Result, TerminalProtocolError};
pub use frame_decoder::FrameDecoder;
pub use session::SessionId;
pub use wire_message::{Channel, CommandStatus, WireMessage};

/// Current wire-protocol version, sent in the `hello` handshake. The Swift shell's
/// `Aislopdesk.protocolVersion` mirrors this.
pub const PROTOCOL_VERSION: u16 = 1;

/// Maximum accepted frame payload size: 16 MiB.
///
/// A length prefix larger than this is
/// rejected with [`TerminalProtocolError::FrameTooLarge`] rather than buffered — it almost
/// certainly means a corrupt or hostile stream. The Swift shell's
/// `Aislopdesk.maxFramePayloadLength` mirrors this.
pub const MAX_FRAME_PAYLOAD_LENGTH: usize = 16 * 1024 * 1024;
