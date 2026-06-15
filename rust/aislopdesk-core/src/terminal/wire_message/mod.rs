//! The terminal (PTY) protocol message — the canonical `WireMessage` (encode / decode /
//! wireByteCount). The Swift `AislopdeskProtocol` shell tracks it (golden parity).
//!
//! Wire layout of a frame is `[u32 BE payloadLength][u8 messageType][body…]` where
//! `payloadLength` counts `messageType` + `body` (it excludes the 4 prefix bytes). All
//! multi-byte integers are big-endian. The keystroke/output hot path uses this manual
//! binary encoding — never JSON.

use super::session::SessionId;

mod codec;
mod data_frame_view;
#[cfg(test)]
mod tests;

pub use data_frame_view::*;

/// The two TCP connections that make up an Aislopdesk session.
///
/// A session uses **two** TCP connections so that a burst of PTY output on the data
/// channel cannot delay a resize / disconnect intent on the control channel. This enum
/// is advisory metadata: [`WireMessage::channel`] states which connection a message is
/// expected to travel on; the framing and decoder are identical on both.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Channel {
    /// PTY byte stream: `output`, `exit` (host → client) and `input` (client → host).
    Data,
    /// Session lifecycle & sizing: `hello`/`resize`/`ack`/`bye`/`ping` (client → host)
    /// and `helloAck`/`title`/`bell`/`commandStatus`/`pong`/`notification` (host → client).
    Control,
}

/// The semantic state of the foreground command in a pane's shell (from OSC 133).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommandStatus {
    /// OSC 133;C — a command began executing (preexec). The pane is RUNNING.
    Running,
    /// OSC 133;D — the command finished (precmd of the next prompt). The pane is IDLE
    /// again. `exit_code` is the command's `$?` (`None` if the shell did not report one);
    /// `duration_ms` is the host-measured C→D wall-clock time.
    Idle {
        /// The command's exit status, or `None` if the shell did not report one.
        exit_code: Option<i32>,
        /// Host-measured C→D wall-clock time in milliseconds.
        duration_ms: u32,
    },
}

/// One decoded Aislopdesk terminal-protocol message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WireMessage {
    // DATA channel, host → client
    /// PTY output. `seq` is a monotonic per-message index starting at 1 (NOT a byte
    /// offset); `bytes` is the raw VT payload.
    Output {
        /// Monotonic per-message index, starting at 1.
        seq: i64,
        /// Raw VT payload bytes.
        bytes: Vec<u8>,
    },
    /// Child process exited with the given status `code`.
    Exit {
        /// Child process exit status.
        code: i32,
    },

    // DATA channel, client → host
    /// Bytes to write to the PTY's stdin (keystrokes, pasted text, etc.).
    Input(Vec<u8>),

    // CONTROL channel, client → host
    /// Session handshake. An all-zero `session_id` means "open a NEW session"; a non-zero
    /// id means "resume this session". `last_received_seq` is the highest contiguous
    /// output seq the client already has, so the host can replay only newer output.
    Hello {
        /// Negotiated wire-protocol version.
        protocol_version: u16,
        /// The session to resume, or [`SessionId::NEW_SESSION`] for a new one.
        session_id: SessionId,
        /// Highest contiguous output seq the client already holds.
        last_received_seq: i64,
    },
    /// Terminal resize. Character cells plus optional pixel dimensions (0 if unknown).
    Resize {
        /// Columns (character cells).
        cols: u16,
        /// Rows (character cells).
        rows: u16,
        /// Pixel width (0 if unknown).
        px_width: u16,
        /// Pixel height (0 if unknown).
        px_height: u16,
    },
    /// Acknowledge receipt of output up to and including `seq`.
    Ack {
        /// Highest contiguous output seq durably received.
        seq: i64,
    },
    /// Client is leaving cleanly (empty body).
    Bye,
    /// Application-layer RTT probe (client → host). The host echoes `timestamp_ms` back
    /// verbatim in [`WireMessage::Pong`].
    Ping {
        /// The client's monotonic-clock timestamp (interpreted only by the client).
        timestamp_ms: u64,
    },

    // CONTROL channel, host → client
    /// Handshake reply. `session_id` is authoritative; `resume_from_seq` is the seq the
    /// host will replay from; `returning_client` is decided by the host.
    HelloAck {
        /// Authoritative session id.
        session_id: SessionId,
        /// Seq the host will replay from.
        resume_from_seq: i64,
        /// `true` if the host recognized a resuming client (it replays the tail).
        returning_client: bool,
    },
    /// Window/title text (UTF-8). Driven by OSC 0/2.
    Title(String),
    /// Terminal bell (empty body).
    Bell,
    /// Per-command semantic status, derived host-side from OSC 133 C/D marks.
    CommandStatus(CommandStatus),
    /// RTT probe reply: the client's [`WireMessage::Ping`] timestamp echoed verbatim.
    Pong {
        /// The client timestamp echoed verbatim.
        timestamp_ms: u64,
    },
    /// An explicit desktop notification the child requested via OSC 9 / OSC 777. An OSC 9
    /// with no explicit title carries an empty `title`.
    Notification {
        /// Notification title (empty for an untitled OSC 9).
        title: String,
        /// Notification body.
        body: String,
    },
}

/// A notification title whose UTF-8 fits the wire's `u16` length field (≤ 65535 bytes),
/// clamped at a `char` boundary so it stays valid UTF-8.
///
/// Identity for any sane title (the
/// only producer caps the OSC at 1 KiB); only an absurd >64 KiB title is shortened —
/// preventing the length field from wrapping and corrupting the body.
///
/// Documented divergence (unreachable): the Swift shell clamps at a `Character` (grapheme-cluster)
/// boundary, this clamps at a Rust `char` (Unicode-scalar) boundary. They agree for every
/// title that does not exceed 64 KiB (clamp never fires) and for all-ASCII titles; they
/// could differ only if the 65535-byte cut fell *inside* a multi-scalar grapheme of a
/// >64 KiB title — which no producer emits. Both always yield valid UTF-8.
#[must_use]
pub fn clamped_notification_title(title: &str) -> &str {
    if u16::try_from(title.len()).is_ok() {
        return title; // already fits the u16 length field — the common case
    }
    let limit = u16::MAX as usize;
    let mut count = 0;
    let mut end = 0;
    for (i, ch) in title.char_indices() {
        let n = ch.len_utf8();
        if count + n > limit {
            break;
        }
        count += n;
        end = i + n;
    }
    &title[..end]
}
