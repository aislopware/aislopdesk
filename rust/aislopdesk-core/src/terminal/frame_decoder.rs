//! Incremental, streaming decoder that turns arbitrary chunks of TCP bytes into whole
//! [`WireMessage`] values.
//!
//! The canonical `FrameDecoder` logic; the Swift `AislopdeskProtocol` shell tracks it (golden parity).
//!
//! TCP is a byte stream with no message boundaries: one read may deliver half a frame,
//! three frames, or a frame split across many reads. [`FrameDecoder`] buffers raw bytes
//! via [`append`](FrameDecoder::append) and yields complete messages via
//! [`next_message`](FrameDecoder::next_message), returning `Ok(None)` whenever no complete
//! frame is buffered yet (it waits for more bytes — a partial frame is **not** an error).
//!
//! Completed frames are NOT removed per-parse (front-removal memmoves the whole tail
//! forward — O(n) per frame, O(n²) for a chunk of many small frames). Instead a read
//! cursor advances past consumed frames and the head is compacted LAZILY (on a drain that
//! returns `None`, or when the cursor crosses [`COMPACTION_THRESHOLD`]), amortizing total
//! work to O(bytes). One decoder per channel per connection.

use super::MAX_FRAME_PAYLOAD_LENGTH;
use super::error::{Result, TerminalProtocolError};
use super::wire_message::WireMessage;

/// Length of the big-endian `u32` frame-length prefix.
const PREFIX_LENGTH: usize = 4;

/// Reclaim the consumed prefix once the read cursor has advanced past this many bytes, so
/// the buffer's wasted head stays bounded during a long burst. 64 KiB == the max single
/// read chunk, so in the common case compaction happens at most once per received chunk.
const COMPACTION_THRESHOLD: usize = 64 * 1024;

/// Streaming length-prefixed frame decoder. Value type; intentionally NOT shared across
/// tasks — it carries mutable buffer state for a single receive loop.
#[derive(Debug, Clone, Default)]
pub struct FrameDecoder {
    /// Received bytes. All indexing is relative to `read_offset`.
    buffer: Vec<u8>,
    /// Leading bytes already consumed by completed frames but not yet physically removed.
    read_offset: usize,
}

impl FrameDecoder {
    /// A fresh decoder with an empty buffer.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Appends a freshly received chunk of bytes to the internal buffer. Safe to call
    /// with empty data, a single byte, or many frames' worth.
    pub fn append(&mut self, data: &[u8]) {
        self.buffer.extend_from_slice(data);
    }

    /// Returns the next complete message, or `Ok(None)` if a full frame is not yet
    /// buffered (the caller should `append` more bytes and retry).
    ///
    /// # Errors
    /// Returns [`TerminalProtocolError::FrameTooLarge`] if a length prefix exceeds
    /// [`MAX_FRAME_PAYLOAD_LENGTH`]; or any error from [`WireMessage::decode`] (unknown
    /// type, malformed/truncated body).
    pub fn next_message(&mut self) -> Result<Option<WireMessage>> {
        // Bytes not yet consumed by a completed frame.
        let available = self.buffer.len() - self.read_offset;
        // Need at least the length prefix to know how big the frame is.
        if available < PREFIX_LENGTH {
            self.compact_consumed();
            return Ok(None);
        }

        let payload_length = self.read_prefix() as usize;

        // Reject implausibly large frames before allocating / waiting for them.
        if payload_length > MAX_FRAME_PAYLOAD_LENGTH {
            return Err(TerminalProtocolError::FrameTooLarge(payload_length));
        }

        // Wait until the whole payload has arrived (partial read — not an error).
        let frame_length = PREFIX_LENGTH + payload_length;
        if available < frame_length {
            self.compact_consumed();
            return Ok(None);
        }

        // Slice out the payload (after the prefix) and ADVANCE the cursor past the frame.
        let base = self.read_offset;
        let payload_start = base + PREFIX_LENGTH;
        let payload = self.buffer[payload_start..base + frame_length].to_vec();
        self.read_offset += frame_length;
        // Bound the wasted head mid-burst; a drain that returns None reclaims the rest.
        if self.read_offset >= COMPACTION_THRESHOLD {
            self.compact_consumed();
        }

        WireMessage::decode(&payload).map(Some)
    }

    /// Physically drops the consumed prefix (`read_offset` bytes) from the front of the
    /// buffer ONCE, resetting the cursor — the single O(remaining) move that replaces the
    /// per-frame one.
    fn compact_consumed(&mut self) {
        if self.read_offset > 0 {
            self.buffer.drain(..self.read_offset);
            self.read_offset = 0;
        }
    }

    /// Reads the 4-byte big-endian length prefix at the cursor without consuming it.
    fn read_prefix(&self) -> u32 {
        let base = self.read_offset;
        u32::from_be_bytes([
            self.buffer[base],
            self.buffer[base + 1],
            self.buffer[base + 2],
            self.buffer[base + 3],
        ])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::session::SessionId;

    fn sid(seed: u8) -> SessionId {
        let mut b = [0u8; 16];
        for (i, slot) in b.iter_mut().enumerate() {
            *slot = seed.wrapping_add(i as u8);
        }
        SessionId(b)
    }

    fn sample_messages() -> Vec<WireMessage> {
        vec![
            WireMessage::Output {
                seq: 7,
                bytes: "partial-read test ✅".as_bytes().to_vec(),
            },
            WireMessage::Resize {
                cols: 120,
                rows: 40,
                px_width: 0,
                px_height: 0,
            },
            WireMessage::HelloAck {
                session_id: sid(5),
                resume_from_seq: 9,
                returning_client: true,
            },
        ]
    }

    fn concatenated(messages: &[WireMessage]) -> Vec<u8> {
        let mut out = Vec::new();
        for m in messages {
            out.extend_from_slice(&m.encode());
        }
        out
    }

    fn drain_all(decoder: &mut FrameDecoder) -> Vec<WireMessage> {
        let mut out = Vec::new();
        while let Some(m) = decoder.next_message().expect("no decode error") {
            out.push(m);
        }
        out
    }

    #[test]
    fn partial_reads_one_byte_at_a_time() {
        let messages = sample_messages();
        let combined = concatenated(&messages);
        let mut decoder = FrameDecoder::new();
        let mut decoded = Vec::new();
        for &byte in &combined {
            decoder.append(&[byte]);
            decoded.append(&mut drain_all(&mut decoder));
        }
        assert_eq!(decoded, messages);
        assert_eq!(decoder.next_message().unwrap(), None);
    }

    #[test]
    fn multiple_frames_in_one_append() {
        let messages = sample_messages();
        let mut decoder = FrameDecoder::new();
        decoder.append(&concatenated(&messages));
        assert_eq!(drain_all(&mut decoder), messages);
        assert_eq!(decoder.next_message().unwrap(), None);
    }

    #[test]
    fn oversized_frame_throws_frame_too_large() {
        let oversized = MAX_FRAME_PAYLOAD_LENGTH + 1;
        let mut decoder = FrameDecoder::new();
        decoder.append(&(oversized as u32).to_be_bytes());
        assert_eq!(
            decoder.next_message(),
            Err(TerminalProtocolError::FrameTooLarge(oversized))
        );
    }

    #[test]
    fn max_size_frame_prefix_is_accepted_not_rejected() {
        // Guard is `<=`, so a prefix EXACTLY at the cap must wait (no body), never throw.
        let mut decoder = FrameDecoder::new();
        decoder.append(&(MAX_FRAME_PAYLOAD_LENGTH as u32).to_be_bytes());
        assert_eq!(decoder.next_message().unwrap(), None);
    }

    #[test]
    fn large_multi_kb_payload_round_trips() {
        let big: Vec<u8> = (0..(256 * 1024)).map(|i| (i & 0xFF) as u8).collect();
        let message = WireMessage::Output {
            seq: 99,
            bytes: big,
        };
        let mut decoder = FrameDecoder::new();
        decoder.append(&message.encode());
        assert_eq!(decoder.next_message().unwrap(), Some(message));
        assert_eq!(decoder.next_message().unwrap(), None);
    }

    #[test]
    fn unknown_message_type_throws() {
        let mut frame = 1u32.to_be_bytes().to_vec();
        frame.push(0xFF);
        let mut decoder = FrameDecoder::new();
        decoder.append(&frame);
        assert_eq!(
            decoder.next_message(),
            Err(TerminalProtocolError::UnknownMessageType(0xFF))
        );
    }

    #[test]
    fn truncated_body_waits_rather_than_misparsing() {
        let full = (WireMessage::Exit { code: 256 }).encode();
        let mut decoder = FrameDecoder::new();
        decoder.append(&full[..full.len() - 1]);
        assert_eq!(decoder.next_message().unwrap(), None);
        assert_eq!(decoder.next_message().unwrap(), None);
        decoder.append(&[full[full.len() - 1]]);
        assert_eq!(
            decoder.next_message().unwrap(),
            Some(WireMessage::Exit { code: 256 })
        );
    }

    #[test]
    fn empty_and_zero_length_inputs() {
        let mut decoder = FrameDecoder::new();
        assert_eq!(decoder.next_message().unwrap(), None);
        decoder.append(&[]);
        assert_eq!(decoder.next_message().unwrap(), None);
        decoder.append(&[0x00, 0x00]);
        assert_eq!(decoder.next_message().unwrap(), None);
    }

    #[test]
    fn remaining_frames_survive_a_partial_trailing_frame() {
        let first = WireMessage::Bell.encode();
        let second = WireMessage::Title("incomplete".to_string()).encode();
        let mut decoder = FrameDecoder::new();
        decoder.append(&first);
        decoder.append(&second[..second.len() - 3]);
        assert_eq!(decoder.next_message().unwrap(), Some(WireMessage::Bell));
        assert_eq!(decoder.next_message().unwrap(), None);
        decoder.append(&second[second.len() - 3..]);
        assert_eq!(
            decoder.next_message().unwrap(),
            Some(WireMessage::Title("incomplete".to_string()))
        );
    }

    // --- cursor + lazy-compaction (FrameDecoderCursorTests) ---

    fn small_wire_frames(n: usize) -> (Vec<WireMessage>, Vec<u8>) {
        let mut frames = Vec::with_capacity(n);
        let mut bytes = Vec::new();
        for i in 0..n {
            let m = WireMessage::Output {
                seq: (i + 1) as i64,
                bytes: vec![(i & 0xFF) as u8, ((i >> 8) & 0xFF) as u8],
            };
            bytes.extend_from_slice(&m.encode());
            frames.push(m);
        }
        (frames, bytes)
    }

    #[test]
    fn decodes_many_small_frames_identically_in_one_chunk() {
        // > 64 KiB of tiny frames → compaction fires mid-drain.
        let (expected, bytes) = small_wire_frames(12_000);
        let mut decoder = FrameDecoder::new();
        decoder.append(&bytes);
        assert_eq!(drain_all(&mut decoder), expected);
        assert_eq!(decoder.next_message().unwrap(), None);
    }

    #[test]
    fn decodes_identically_across_arbitrary_splits() {
        let (expected, bytes) = small_wire_frames(3_000);
        let mut decoder = FrameDecoder::new();
        let mut decoded = Vec::new();
        // 7-byte slices so frames straddle append boundaries repeatedly.
        for chunk in bytes.chunks(7) {
            decoder.append(chunk);
            decoded.append(&mut drain_all(&mut decoder));
        }
        assert_eq!(decoded, expected);
        assert_eq!(decoder.next_message().unwrap(), None);
    }

    #[test]
    fn scales_linearly_not_quadratically() {
        let small = drain_time(8_000);
        let large = drain_time(32_000); // 4× the frames
        // Linear ≈ 4×; the old O(n²) front-removal ≈ 16×. Generous 8× bound absorbs noise.
        assert!(
            large / small.max(1e-9) < 8.0,
            "decode time must scale ~linearly (got {}× for 4× frames)",
            large / small
        );
    }

    fn drain_time(n: usize) -> f64 {
        let (_, bytes) = small_wire_frames(n);
        for _ in 0..2 {
            let mut d = FrameDecoder::new();
            d.append(&bytes);
            while d.next_message().unwrap().is_some() {}
        }
        let start = std::time::Instant::now();
        let mut d = FrameDecoder::new();
        d.append(&bytes);
        while d.next_message().unwrap().is_some() {}
        start.elapsed().as_secs_f64()
    }
}
