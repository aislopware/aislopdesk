//! Canonical encode / decode / `wire_byte_count` for [`WireMessage`] — the manual
//! big-endian framing of the PTY control + data byte stream.

use super::super::error::{Result, TerminalProtocolError};
use super::super::reader::BigEndianReader;
use super::super::session::SessionId;
use super::{Channel, CommandStatus, WireMessage, clamped_notification_title};
use crate::bytes::ByteWriter;

impl WireMessage {
    /// The on-wire message-type byte for this case.
    #[must_use]
    pub const fn message_type(&self) -> u8 {
        match self {
            Self::Output { .. } => 1,
            Self::Exit { .. } => 2,
            Self::Input(_) => 3,
            Self::Hello { .. } => 10,
            Self::Resize { .. } => 11,
            Self::Ack { .. } => 12,
            Self::Bye => 13,
            Self::Ping { .. } => 14,
            Self::HelloAck { .. } => 20,
            Self::Title(_) => 21,
            Self::Bell => 22,
            Self::CommandStatus(_) => 23,
            Self::Pong { .. } => 24,
            Self::Notification { .. } => 25,
        }
    }

    /// The channel this message is expected to travel on (advisory; see [`Channel`]).
    #[must_use]
    pub const fn channel(&self) -> Channel {
        match self {
            Self::Output { .. } | Self::Exit { .. } | Self::Input(_) => Channel::Data,
            Self::Hello { .. }
            | Self::Resize { .. }
            | Self::Ack { .. }
            | Self::Bye
            | Self::Ping { .. }
            | Self::HelloAck { .. }
            | Self::Title(_)
            | Self::Bell
            | Self::CommandStatus(_)
            | Self::Pong { .. }
            | Self::Notification { .. } => Channel::Control,
        }
    }

    /// Encodes this message into a complete frame, ready to write to a socket:
    /// `[u32 BE payloadLength][u8 messageType][body…]`. `payloadLength` counts
    /// `messageType` + `body` and excludes the 4 prefix bytes — exactly what
    /// [`FrameDecoder`](super::FrameDecoder) expects.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        // Build [messageType][body…] first, then prepend the big-endian length prefix.
        // Byte-identical encoding (the Swift shell's single-buffer back-patch matches it).
        let mut w = ByteWriter::new();
        w.put_u8(self.message_type());

        match self {
            Self::Output { seq, bytes } => {
                w.put_i64(*seq);
                w.put_bytes(bytes);
            }
            Self::Exit { code } => w.put_i32(*code),
            Self::Input(bytes) => w.put_bytes(bytes),
            Self::Hello {
                protocol_version,
                session_id,
                last_received_seq,
            } => {
                w.put_u16(*protocol_version);
                w.put_bytes(session_id.bytes());
                w.put_i64(*last_received_seq);
            }
            Self::Resize {
                cols,
                rows,
                px_width,
                px_height,
            } => {
                w.put_u16(*cols);
                w.put_u16(*rows);
                w.put_u16(*px_width);
                w.put_u16(*px_height);
            }
            Self::Ack { seq } => w.put_i64(*seq),
            Self::Bye | Self::Bell => {} // empty body
            Self::Ping { timestamp_ms } | Self::Pong { timestamp_ms } => w.put_u64(*timestamp_ms),
            Self::HelloAck {
                session_id,
                resume_from_seq,
                returning_client,
            } => {
                w.put_bytes(session_id.bytes());
                w.put_i64(*resume_from_seq);
                w.put_u8(u8::from(*returning_client));
            }
            Self::Title(string) => w.put_bytes(string.as_bytes()),
            Self::Notification { title, body } => {
                // [u16 BE titleLen][title UTF-8][body UTF-8]. The title is clamped to the
                // u16 length field's limit so an absurd >64 KiB title can never wrap the
                // length and corrupt the body (see `clamped_notification_title`).
                let title_bytes = clamped_notification_title(title).as_bytes();
                w.put_u16(title_bytes.len() as u16);
                w.put_bytes(title_bytes);
                w.put_bytes(body.as_bytes());
            }
            Self::CommandStatus(status) => match status {
                CommandStatus::Running => w.put_u8(0),
                CommandStatus::Idle {
                    exit_code,
                    duration_ms,
                } => {
                    w.put_u8(1);
                    w.put_u8(u8::from(exit_code.is_some())); // hasExit
                    w.put_i32(exit_code.unwrap_or(0)); // Int32 BE (0 when absent)
                    w.put_u32(*duration_ms); // UInt32 BE
                }
            },
        }

        let payload = w.into_vec();
        let payload_length = payload.len() as u32;
        let mut frame = Vec::with_capacity(4 + payload.len());
        frame.extend_from_slice(&payload_length.to_be_bytes());
        frame.extend_from_slice(&payload);
        frame
    }

    /// The exact number of bytes [`encode`](WireMessage::encode) produces, computed
    /// WITHOUT building the frame. The receive-side flow-control crediting credits
    /// `wire_byte_count` per consumed message, matching the sender's per-frame debit.
    #[must_use]
    pub fn wire_byte_count(&self) -> usize {
        // Each arm states a DISTINCT field layout; several coincidentally sum to the same
        // byte count (Resize = 4×u16, Ack = i64, Ping/Pong = u64 all = 8). Keeping them
        // separate (the Swift shell's layout matches this) documents each size at its variant.
        #[allow(clippy::match_same_arms)]
        let body: usize = match self {
            Self::Output { bytes, .. } => 8 + bytes.len(), // seq i64 + payload
            Self::Exit { .. } => 4,                        // code i32
            Self::Input(bytes) => bytes.len(),
            Self::Hello { .. } => 2 + SessionId::BYTE_COUNT + 8, // u16 + id + i64
            Self::Resize { .. } => 8,                            // 4 × u16
            Self::Ack { .. } => 8,                               // seq i64
            Self::Bye | Self::Bell => 0,
            Self::Ping { .. } | Self::Pong { .. } => 8, // timestamp u64
            Self::HelloAck { .. } => SessionId::BYTE_COUNT + 8 + 1, // id + i64 + bool
            Self::Title(string) => string.len(),
            Self::Notification { title, body } => {
                2 + clamped_notification_title(title).len() + body.len()
            }
            Self::CommandStatus(status) => match status {
                CommandStatus::Running => 1,                 // tag
                CommandStatus::Idle { .. } => 1 + 1 + 4 + 4, // tag + hasExit + i32 + u32
            },
        };
        // 4-byte length prefix + 1 type byte + body.
        4 + 1 + body
    }

    /// Decodes a message from a **complete payload** (`[u8 messageType][body…]`, without
    /// the length prefix — framing is handled by [`FrameDecoder`](super::FrameDecoder)).
    ///
    /// # Errors
    /// Returns [`TerminalProtocolError::Truncated`] if the body is shorter than the type
    /// requires, [`TerminalProtocolError::UnknownMessageType`] for an unrecognized type
    /// byte, or [`TerminalProtocolError::MalformedBody`] for a right-length-but-invalid
    /// body (e.g. bad UTF-8).
    pub fn decode(payload: &[u8]) -> Result<Self> {
        let mut reader = BigEndianReader::new(payload);
        let type_byte = reader.read_u8()?;

        match type_byte {
            1 => {
                let seq = reader.read_i64()?;
                Ok(Self::Output {
                    seq,
                    bytes: reader.remaining().to_vec(),
                })
            }
            2 => Ok(Self::Exit {
                code: reader.read_i32()?,
            }),
            3 => Ok(Self::Input(reader.remaining().to_vec())),
            10 => {
                let protocol_version = reader.read_u16()?;
                let session_id = SessionId::from_slice(reader.read_bytes(SessionId::BYTE_COUNT)?);
                let last_received_seq = reader.read_i64()?;
                Ok(Self::Hello {
                    protocol_version,
                    session_id,
                    last_received_seq,
                })
            }
            11 => Ok(Self::Resize {
                cols: reader.read_u16()?,
                rows: reader.read_u16()?,
                px_width: reader.read_u16()?,
                px_height: reader.read_u16()?,
            }),
            12 => Ok(Self::Ack {
                seq: reader.read_i64()?,
            }),
            13 => Ok(Self::Bye),
            14 => Ok(Self::Ping {
                timestamp_ms: reader.read_u64()?,
            }),
            20 => {
                let session_id = SessionId::from_slice(reader.read_bytes(SessionId::BYTE_COUNT)?);
                let resume_from_seq = reader.read_i64()?;
                let returning_byte = reader.read_u8()?;
                Ok(Self::HelloAck {
                    session_id,
                    resume_from_seq,
                    returning_client: returning_byte != 0,
                })
            }
            21 => {
                let bytes = reader.remaining();
                let string = String::from_utf8(bytes.to_vec())
                    .map_err(|_| TerminalProtocolError::malformed("title: invalid UTF-8"))?;
                Ok(Self::Title(string))
            }
            22 => Ok(Self::Bell),
            23 => {
                let tag = reader.read_u8()?;
                match tag {
                    0 => Ok(Self::CommandStatus(CommandStatus::Running)),
                    1 => {
                        let has_exit = reader.read_u8()?;
                        let exit_raw = reader.read_i32()?;
                        let duration_ms = reader.read_u32()?;
                        Ok(Self::CommandStatus(CommandStatus::Idle {
                            exit_code: if has_exit != 0 { Some(exit_raw) } else { None },
                            duration_ms,
                        }))
                    }
                    other => Err(TerminalProtocolError::malformed(format!(
                        "commandStatus: invalid tag {other}"
                    ))),
                }
            }
            24 => Ok(Self::Pong {
                timestamp_ms: reader.read_u64()?,
            }),
            25 => {
                let title_len = usize::from(reader.read_u16()?);
                let title_bytes = reader.read_bytes(title_len)?;
                let title = String::from_utf8(title_bytes.to_vec()).map_err(|_| {
                    TerminalProtocolError::malformed("notification: invalid title UTF-8")
                })?;
                let body = String::from_utf8(reader.remaining().to_vec()).map_err(|_| {
                    TerminalProtocolError::malformed("notification: invalid body UTF-8")
                })?;
                Ok(Self::Notification { title, body })
            }
            other => Err(TerminalProtocolError::UnknownMessageType(other)),
        }
    }
}
