//! Zero-copy borrowed DATA-channel path — [`DataFrameView`] plus the
//! `encode_data_frame_into` / `data_frame_view` helpers for the bulk PTY byte stream.

use super::super::error::Result;
use super::super::reader::BigEndianReader;
use super::WireMessage;

/// A borrowed view of a DATA-channel frame's payload (`Output`/`Input`), whose bulk bytes are a
/// slice INTO the source buffer — the zero-copy decode path for the PTY byte stream.
///
/// Returned by [`WireMessage::data_frame_view`] so a caller (the FFI shell) can copy the bulk
/// bytes exactly once into its own owned representation instead of paying the owned-`WireMessage`
/// decode's intermediate `to_vec` + buffer-clone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DataFrameView<'a> {
    /// Message type byte: `1` = `Output`, `3` = `Input`.
    pub tag: u8,
    /// `Output.seq` (meaningless / `0` for `Input`).
    pub seq: i64,
    /// The bulk payload bytes, borrowed from the source payload.
    pub bytes: &'a [u8],
}

impl WireMessage {
    /// Writes the complete frame (`[u32 BE len][type][seq?][payload]`) for a DATA-channel message
    /// — `Output` (`tag = 1`, uses `seq`) or `Input` (`tag = 3`, ignores `seq`) — whose bulk
    /// `payload` is borrowed, into `out`, with a SINGLE payload copy. Returns the number of bytes
    /// written, or `0` if `tag` is not a DATA type or `out` is too small.
    ///
    /// This is the zero-extra-copy framing path for the bulk PTY byte stream. It is byte-identical
    /// to [`WireMessage::encode`] for the same message (pinned by `data_frame_into_matches_encode`);
    /// [`encode`](WireMessage::encode) stays the canonical encoder for every other variant.
    #[must_use]
    pub fn encode_data_frame_into(tag: u8, seq: i64, payload: &[u8], out: &mut [u8]) -> usize {
        let body_len = match tag {
            1 => 1 + 8 + payload.len(), // type + seq + payload
            3 => 1 + payload.len(),     // type + payload
            _ => return 0,
        };
        let total = 4 + body_len;
        if out.len() < total {
            return 0;
        }
        out[..4].copy_from_slice(&(body_len as u32).to_be_bytes());
        out[4] = tag;
        if tag == 1 {
            out[5..13].copy_from_slice(&seq.to_be_bytes());
            out[13..total].copy_from_slice(payload);
        } else {
            out[5..total].copy_from_slice(payload);
        }
        total
    }

    /// Parses just the header of a complete payload (`[type][body…]`, no length prefix) to return
    /// a borrowed [`DataFrameView`] for a DATA-channel message (`Output`/`Input`) WITHOUT copying
    /// the bulk bytes.
    ///
    /// Returns `Ok(None)` for any other (control) type — the caller decodes those through
    /// [`WireMessage::decode`].
    ///
    /// # Errors
    /// [`TerminalProtocolError::Truncated`] if the payload is empty (no type byte) or an `Output`
    /// header's `i64` seq is truncated — exactly where [`decode`](WireMessage::decode) would also
    /// reject it.
    pub fn data_frame_view(payload: &[u8]) -> Result<Option<DataFrameView<'_>>> {
        let mut reader = BigEndianReader::new(payload);
        let tag = reader.read_u8()?;
        match tag {
            1 => {
                let seq = reader.read_i64()?;
                Ok(Some(DataFrameView {
                    tag,
                    seq,
                    bytes: reader.remaining(),
                }))
            }
            3 => Ok(Some(DataFrameView {
                tag,
                seq: 0,
                bytes: reader.remaining(),
            })),
            _ => Ok(None),
        }
    }
}
