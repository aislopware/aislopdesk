use super::super::error::TerminalProtocolError;
use super::super::frame_decoder::FrameDecoder;
use super::super::session::SessionId;
use super::*;

/// Deterministic stand-in for Swift's random `UUID()` — any 16 bytes round-trip.
fn sid(seed: u8) -> SessionId {
    let mut b = [0u8; 16];
    for (i, slot) in b.iter_mut().enumerate() {
        *slot = seed.wrapping_add(i as u8).wrapping_mul(7).wrapping_add(1);
    }
    SessionId(b)
}

/// Encodes a message, feeds the frame bytes through a fresh `FrameDecoder`, and
/// returns the decoded message — the canonical round-trip helper.
fn round_trip(message: &WireMessage) -> Option<WireMessage> {
    let mut decoder = FrameDecoder::new();
    decoder.append(&message.encode());
    decoder.next_message().expect("decode should not error")
}

fn assert_round_trips(cases: &[WireMessage]) {
    for message in cases {
        assert_eq!(round_trip(message).as_ref(), Some(message));
    }
}

#[test]
fn output_round_trip_representative_and_boundary() {
    assert_round_trips(&[
        WireMessage::Output {
            seq: 1,
            bytes: b"hello".to_vec(),
        },
        WireMessage::Output {
            seq: i64::MAX,
            bytes: Vec::new(),
        },
        WireMessage::Output {
            seq: 42,
            bytes: vec![0x1b, 0x5b, 0x32, 0x4a],
        },
    ]);
}

#[test]
fn exit_round_trip() {
    for code in [0, 1, -1, i32::MAX, i32::MIN] {
        let m = WireMessage::Exit { code };
        assert_eq!(round_trip(&m).as_ref(), Some(&m));
    }
}

#[test]
fn input_round_trip() {
    assert_round_trips(&[
        WireMessage::Input(Vec::new()),
        WireMessage::Input(b"ls -la\n".to_vec()),
        WireMessage::Input(vec![0x00, 0xff, 0x80, 0x7f]),
    ]);
}

#[test]
fn hello_round_trip_new_and_resume_sessions() {
    assert_round_trips(&[
        WireMessage::Hello {
            protocol_version: super::super::PROTOCOL_VERSION,
            session_id: SessionId::NEW_SESSION,
            last_received_seq: 0,
        },
        WireMessage::Hello {
            protocol_version: 1,
            session_id: sid(1),
            last_received_seq: i64::MAX,
        },
        WireMessage::Hello {
            protocol_version: u16::MAX,
            session_id: sid(2),
            last_received_seq: -1,
        },
    ]);
}

#[test]
fn resize_round_trip_boundaries() {
    assert_round_trips(&[
        WireMessage::Resize {
            cols: 0,
            rows: 0,
            px_width: 0,
            px_height: 0,
        },
        WireMessage::Resize {
            cols: 65535,
            rows: 65535,
            px_width: 65535,
            px_height: 65535,
        },
        WireMessage::Resize {
            cols: 80,
            rows: 24,
            px_width: 640,
            px_height: 384,
        },
    ]);
}

#[test]
fn ack_round_trip() {
    for seq in [0, 1, i64::MAX, -1] {
        let m = WireMessage::Ack { seq };
        assert_eq!(round_trip(&m).as_ref(), Some(&m));
    }
}

#[test]
fn bye_round_trip() {
    assert_eq!(round_trip(&WireMessage::Bye), Some(WireMessage::Bye));
}

#[test]
fn ping_pong_round_trip() {
    for ts in [0u64, 1, 1_749_700_000_123, u64::MAX] {
        assert_eq!(
            round_trip(&WireMessage::Ping { timestamp_ms: ts }),
            Some(WireMessage::Ping { timestamp_ms: ts })
        );
        assert_eq!(
            round_trip(&WireMessage::Pong { timestamp_ms: ts }),
            Some(WireMessage::Pong { timestamp_ms: ts })
        );
    }
}

#[test]
fn hello_ack_round_trip() {
    assert_round_trips(&[
        WireMessage::HelloAck {
            session_id: sid(3),
            resume_from_seq: 1,
            returning_client: true,
        },
        WireMessage::HelloAck {
            session_id: SessionId::NEW_SESSION,
            resume_from_seq: 0,
            returning_client: false,
        },
        WireMessage::HelloAck {
            session_id: sid(4),
            resume_from_seq: i64::MAX,
            returning_client: true,
        },
    ]);
}

#[test]
fn title_round_trip_including_cjk_and_emoji() {
    assert_round_trips(&[
        WireMessage::Title(String::new()),
        WireMessage::Title("zsh — ~/project".to_string()),
        WireMessage::Title("日本語タイトル".to_string()),
        WireMessage::Title("build ✅ done 🚀 — café".to_string()),
    ]);
}

#[test]
fn bell_round_trip() {
    assert_eq!(round_trip(&WireMessage::Bell), Some(WireMessage::Bell));
}

#[test]
fn notification_round_trip_including_empty_title_and_unicode() {
    assert_round_trips(&[
        WireMessage::Notification {
            title: String::new(),
            body: "build done".to_string(),
        },
        WireMessage::Notification {
            title: "CI".to_string(),
            body: "all green ✅".to_string(),
        },
        WireMessage::Notification {
            title: "日本語".to_string(),
            body: "完了 🚀".to_string(),
        },
        WireMessage::Notification {
            title: "only title".to_string(),
            body: String::new(),
        },
        WireMessage::Notification {
            title: "semis;in;title".to_string(),
            body: "and;in;body;too".to_string(),
        },
    ]);
}

#[test]
fn notification_overlong_title_clamps_without_corrupting_body() {
    let body = "the body must survive intact — ✅";
    let decoded = round_trip(&WireMessage::Notification {
        title: "T".repeat(70_000),
        body: body.to_string(),
    });
    let Some(WireMessage::Notification {
        title: d_title,
        body: d_body,
    }) = decoded
    else {
        panic!("not a notification");
    };
    assert_eq!(d_body, body, "body is never corrupted by an overlong title");
    assert!(
        u16::try_from(d_title.len()).is_ok(),
        "title clamped to the u16 length limit"
    );
    assert!(
        d_title.bytes().all(|c| c == b'T'),
        "the clamped title is a valid prefix of the original"
    );
}

#[test]
fn command_status_round_trip() {
    assert_round_trips(&[
        WireMessage::CommandStatus(CommandStatus::Running),
        WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code: Some(0),
            duration_ms: 12_000,
        }),
        WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code: Some(1),
            duration_ms: 300,
        }),
        WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code: Some(130),
            duration_ms: 0,
        }),
        WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code: Some(-1),
            duration_ms: 1,
        }),
        WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code: Some(i32::MIN),
            duration_ms: u32::MAX,
        }),
        WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code: None,
            duration_ms: 5_000,
        }),
    ]);
}

#[test]
fn command_status_invalid_tag_throws_malformed_body() {
    // type 23 + bogus tag 9 (only 0=running / 1=idle valid).
    let body = [23u8, 0x09];
    let mut frame = (body.len() as u32).to_be_bytes().to_vec();
    frame.extend_from_slice(&body);
    let mut decoder = FrameDecoder::new();
    decoder.append(&frame);
    assert!(matches!(
        decoder.next_message(),
        Err(TerminalProtocolError::MalformedBody(_))
    ));
}

#[test]
fn message_type_bytes_match_contract() {
    assert_eq!(
        (WireMessage::Output {
            seq: 1,
            bytes: vec![]
        })
        .message_type(),
        1
    );
    assert_eq!((WireMessage::Exit { code: 0 }).message_type(), 2);
    assert_eq!(WireMessage::Input(vec![]).message_type(), 3);
    assert_eq!(
        (WireMessage::Hello {
            protocol_version: 1,
            session_id: sid(0),
            last_received_seq: 0
        })
        .message_type(),
        10
    );
    assert_eq!(
        (WireMessage::Resize {
            cols: 0,
            rows: 0,
            px_width: 0,
            px_height: 0
        })
        .message_type(),
        11
    );
    assert_eq!((WireMessage::Ack { seq: 0 }).message_type(), 12);
    assert_eq!(WireMessage::Bye.message_type(), 13);
    assert_eq!((WireMessage::Ping { timestamp_ms: 0 }).message_type(), 14);
    assert_eq!(
        (WireMessage::HelloAck {
            session_id: sid(0),
            resume_from_seq: 0,
            returning_client: false
        })
        .message_type(),
        20
    );
    assert_eq!(WireMessage::Title(String::new()).message_type(), 21);
    assert_eq!(WireMessage::Bell.message_type(), 22);
    assert_eq!(
        WireMessage::CommandStatus(CommandStatus::Running).message_type(),
        23
    );
    assert_eq!(
        WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code: Some(0),
            duration_ms: 0
        })
        .message_type(),
        23
    );
    assert_eq!((WireMessage::Pong { timestamp_ms: 0 }).message_type(), 24);
    assert_eq!(
        (WireMessage::Notification {
            title: String::new(),
            body: String::new()
        })
        .message_type(),
        25
    );
}

#[test]
fn channel_assignment() {
    assert_eq!(
        (WireMessage::Output {
            seq: 1,
            bytes: vec![]
        })
        .channel(),
        Channel::Data
    );
    assert_eq!((WireMessage::Exit { code: 0 }).channel(), Channel::Data);
    assert_eq!(WireMessage::Input(vec![]).channel(), Channel::Data);
    assert_eq!(
        (WireMessage::Hello {
            protocol_version: 1,
            session_id: sid(0),
            last_received_seq: 0
        })
        .channel(),
        Channel::Control
    );
    assert_eq!(WireMessage::Bye.channel(), Channel::Control);
    assert_eq!(WireMessage::Bell.channel(), Channel::Control);
    assert_eq!(
        WireMessage::CommandStatus(CommandStatus::Running).channel(),
        Channel::Control
    );
    assert_eq!(
        (WireMessage::Ping { timestamp_ms: 0 }).channel(),
        Channel::Control
    );
    assert_eq!(
        (WireMessage::Pong { timestamp_ms: 0 }).channel(),
        Channel::Control
    );
}

#[test]
fn complete_frame_with_short_body_throws_truncated() {
    // exit (type 2) needs a 4-byte i32 code; supply only the type byte.
    let exit_body = [2u8];
    let mut exit_frame = (exit_body.len() as u32).to_be_bytes().to_vec();
    exit_frame.extend_from_slice(&exit_body);
    let mut exit_decoder = FrameDecoder::new();
    exit_decoder.append(&exit_frame);
    assert_eq!(
        exit_decoder.next_message(),
        Err(TerminalProtocolError::Truncated)
    );

    // resize (type 11) needs 8 body bytes; supply only 3.
    let resize_body = [11u8, 0x00, 0x50, 0x00];
    let mut resize_frame = (resize_body.len() as u32).to_be_bytes().to_vec();
    resize_frame.extend_from_slice(&resize_body);
    let mut resize_decoder = FrameDecoder::new();
    resize_decoder.append(&resize_frame);
    assert_eq!(
        resize_decoder.next_message(),
        Err(TerminalProtocolError::Truncated)
    );
}

#[test]
fn title_with_invalid_utf8_throws_malformed_body() {
    let body = [21u8, 0xFF, 0xFE, 0xFD];
    let mut frame = (body.len() as u32).to_be_bytes().to_vec();
    frame.extend_from_slice(&body);
    let mut decoder = FrameDecoder::new();
    decoder.append(&frame);
    assert!(matches!(
        decoder.next_message(),
        Err(TerminalProtocolError::MalformedBody(_))
    ));
}

#[test]
fn frame_layout_length_prefix_excludes_prefix_bytes() {
    // output(seq:1, "abc") => body = type(1) + seq(8) + 3 = 12.
    let frame = (WireMessage::Output {
        seq: 1,
        bytes: b"abc".to_vec(),
    })
    .encode();
    assert_eq!(frame.len(), 4 + 12);
    let prefix = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]);
    assert_eq!(prefix, 12);
    assert_eq!(frame[4], 1); // first payload byte is the message type
}

// --- wireByteCount parity (WireMessageWireByteCountTests) ---

#[test]
fn wire_byte_count_matches_encode_for_every_variant() {
    let payloads: [Vec<u8>; 3] = [Vec::new(), b"x".to_vec(), vec![0x41u8; 128 * 1024]];
    let mut messages: Vec<WireMessage> = Vec::new();
    for p in &payloads {
        messages.push(WireMessage::Output {
            seq: 1,
            bytes: p.clone(),
        });
        messages.push(WireMessage::Output {
            seq: i64::MAX,
            bytes: p.clone(),
        });
        messages.push(WireMessage::Input(p.clone()));
    }
    messages.extend([
        WireMessage::Exit { code: 0 },
        WireMessage::Exit { code: -1 },
        WireMessage::Hello {
            protocol_version: 1,
            session_id: sid(9),
            last_received_seq: 42,
        },
        WireMessage::Hello {
            protocol_version: u16::MAX,
            session_id: SessionId::NEW_SESSION,
            last_received_seq: 0,
        },
        WireMessage::Resize {
            cols: 80,
            rows: 24,
            px_width: 0,
            px_height: 0,
        },
        WireMessage::Ack { seq: 7 },
        WireMessage::Bye,
        WireMessage::Ping { timestamp_ms: 0 },
        WireMessage::Ping {
            timestamp_ms: u64::MAX,
        },
        WireMessage::Pong {
            timestamp_ms: 12_345,
        },
        WireMessage::HelloAck {
            session_id: sid(10),
            resume_from_seq: 3,
            returning_client: true,
        },
        WireMessage::HelloAck {
            session_id: sid(11),
            resume_from_seq: 0,
            returning_client: false,
        },
        WireMessage::Title(String::new()),
        WireMessage::Title("hello".to_string()),
        WireMessage::Title("tiếng Việt — đa byte ✓".to_string()),
        WireMessage::Bell,
        WireMessage::CommandStatus(CommandStatus::Running),
        WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code: Some(0),
            duration_ms: 12,
        }),
        WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code: None,
            duration_ms: 0,
        }),
        WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code: Some(-127),
            duration_ms: u32::MAX,
        }),
        WireMessage::Notification {
            title: String::new(),
            body: "done".to_string(),
        },
        WireMessage::Notification {
            title: "CI".to_string(),
            body: "green ✅ — đa byte".to_string(),
        },
        WireMessage::Notification {
            title: "only title".to_string(),
            body: String::new(),
        },
        WireMessage::Notification {
            title: "T".repeat(70_000),
            body: "overlong title is clamped".to_string(),
        },
    ]);
    for message in &messages {
        assert_eq!(
            message.wire_byte_count(),
            message.encode().len(),
            "wire_byte_count must equal encode().len() for {message:?}"
        );
    }
}

// --- back-patched length prefix (FrameDecoderCursorTests) ---

#[test]
fn wire_message_encode_prefix_equals_payload_length() {
    let samples = [
        WireMessage::Output {
            seq: 42,
            bytes: b"hello".to_vec(),
        },
        WireMessage::Output {
            seq: 1,
            bytes: Vec::new(),
        },
        WireMessage::Exit { code: 137 },
        WireMessage::Input(vec![0x1B, 0x5B, 0x41]),
        WireMessage::Resize {
            cols: 200,
            rows: 50,
            px_width: 1,
            px_height: 2,
        },
        WireMessage::Ack { seq: 9_000_000_000 },
        WireMessage::Bye,
        WireMessage::Bell,
        WireMessage::HelloAck {
            session_id: sid(7),
            resume_from_seq: 7,
            returning_client: true,
        },
        WireMessage::Title("a-very-long-title-string-with-emoji-✅-and-more".to_string()),
        WireMessage::CommandStatus(CommandStatus::Running),
        WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code: Some(-1),
            duration_ms: 1234,
        }),
        WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code: None,
            duration_ms: 0,
        }),
    ];
    for m in &samples {
        let f = m.encode();
        assert!(f.len() >= 5, "frame is at least prefix(4) + type(1)");
        let prefix = u32::from_be_bytes([f[0], f[1], f[2], f[3]]);
        assert_eq!(
            prefix as usize,
            f.len() - 4,
            "prefix must equal payload length"
        );
        let mut d = FrameDecoder::new();
        d.append(&f);
        assert_eq!(d.next_message().unwrap().as_ref(), Some(m));
        assert_eq!(d.next_message().unwrap(), None);
    }
}

// --- zero-copy borrowed DATA path (encode_data_frame_into / data_frame_view) ---

#[test]
fn data_frame_into_matches_encode() {
    let payloads: [Vec<u8>; 4] = [
        Vec::new(),
        b"ls -la\n".to_vec(),
        vec![0x00, 0xff, 0x80, 0x7f],
        vec![0x41u8; 128 * 1024],
    ];
    for p in &payloads {
        for msg in [
            WireMessage::Output {
                seq: 1,
                bytes: p.clone(),
            },
            WireMessage::Output {
                seq: i64::MAX,
                bytes: p.clone(),
            },
            WireMessage::Input(p.clone()),
        ] {
            let (tag, seq) = match &msg {
                WireMessage::Output { seq, .. } => (1u8, *seq),
                WireMessage::Input(_) => (3u8, 0),
                _ => unreachable!(),
            };
            let want = msg.encode();
            let mut got = vec![0u8; want.len()];
            let n = WireMessage::encode_data_frame_into(tag, seq, p, &mut got);
            assert_eq!(n, want.len(), "written len for tag {tag}");
            assert_eq!(got, want, "byte-identical frame for tag {tag}");
        }
    }
    // A too-small buffer writes nothing and reports 0; a non-DATA tag is rejected.
    let mut tiny = [0u8; 3];
    assert_eq!(
        WireMessage::encode_data_frame_into(1, 0, b"x", &mut tiny),
        0
    );
    let mut buf = [0u8; 64];
    assert_eq!(WireMessage::encode_data_frame_into(2, 0, b"x", &mut buf), 0);
}

#[test]
fn data_frame_view_borrows_output_and_input() {
    // Output: the view exposes seq + a slice of the bulk bytes (no copy).
    let out = WireMessage::Output {
        seq: 99,
        bytes: b"hello world".to_vec(),
    }
    .encode();
    let payload = &out[4..]; // strip the length prefix → [type][body]
    let view = WireMessage::data_frame_view(payload).unwrap().unwrap();
    assert_eq!((view.tag, view.seq), (1, 99));
    assert_eq!(view.bytes, b"hello world");

    let inp = WireMessage::Input(vec![0x1b, 0x5b, 0x41]).encode();
    let view = WireMessage::data_frame_view(&inp[4..]).unwrap().unwrap();
    assert_eq!((view.tag, view.seq), (3, 0));
    assert_eq!(view.bytes, &[0x1b, 0x5b, 0x41]);

    // Empty Input → empty borrowed slice (not an error).
    let empty_in = WireMessage::Input(Vec::new()).encode();
    let view = WireMessage::data_frame_view(&empty_in[4..])
        .unwrap()
        .unwrap();
    assert_eq!((view.tag, view.bytes.is_empty()), (3, true));
}

#[test]
fn data_frame_view_returns_none_for_control_and_truncated_for_short() {
    // A control type (e.g. bye = 13) → None: caller routes it to the owned decode.
    let bye = WireMessage::Bye.encode();
    assert_eq!(WireMessage::data_frame_view(&bye[4..]).unwrap(), None);
    // Empty payload → no type byte → Truncated (where decode also rejects).
    assert_eq!(
        WireMessage::data_frame_view(&[]),
        Err(TerminalProtocolError::Truncated)
    );
    // Output type byte with a truncated seq → Truncated.
    assert_eq!(
        WireMessage::data_frame_view(&[1u8, 0, 0]),
        Err(TerminalProtocolError::Truncated)
    );
}
