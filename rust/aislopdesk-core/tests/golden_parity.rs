//! Cross-language golden-vector parity.
//!
//! Replays the JSON corpus emitted by the Swift `aislopdesk-corevectors` dumper (the REAL
//! `AislopdeskVideoProtocol` codecs) and asserts the Rust `aislopdesk-core` port produces
//! byte- and bit-identical output. This is the load-bearing proof that the two
//! implementations agree on the wire — not just internally self-consistent.
//!
//! Regenerate the corpus after any wire change:
//! `swift run aislopdesk-corevectors > rust/aislopdesk-core/tests/vectors/golden_vectors.json`

use aislopdesk_core::adaptive_fec;
use aislopdesk_core::coordinate_mapping::{self};
use aislopdesk_core::cursor::{CursorShapeMessage, CursorUpdate};
use aislopdesk_core::fec::{FecScheme, XorParityFec};
use aislopdesk_core::fps_governor::FpsGovernor;
use aislopdesk_core::fragment::{Flags, FrameFragment, FrameFragmentHeader};
use aislopdesk_core::geometry::{VideoPoint, VideoRect, VideoSize};
use aislopdesk_core::input_event::{InputEvent, InputModifiers, MouseButton};
use aislopdesk_core::mux_header::{video_mux_header, MuxFrameFragmentHeader};
use aislopdesk_core::nal_unit;
use aislopdesk_core::network_estimate::NetworkEstimate;
use aislopdesk_core::owd_late_detector::OwdLateDetector;
use aislopdesk_core::pacer_depth_policy::{Config as PacerConfig, PacerDepthPolicy};
use aislopdesk_core::recovery::{NetworkStatsReport, RecoveryMessage};
use aislopdesk_core::terminal::mux::{MuxEnvelopeCodec, MuxFrame};
use aislopdesk_core::terminal::{CommandStatus, SessionId, WireMessage};
use aislopdesk_core::trendline_estimator::TrendlineEstimator;
use aislopdesk_core::video_control::{SystemDialogSummary, VideoControlMessage, WindowSummary};
use aislopdesk_core::window_geometry::WindowGeometryMessage;
use aislopdesk_core::ycbcr::{self, ColorRange};
use serde_json::Value;
use std::fmt::Write as _;

// ----- helpers -----

fn load() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/vectors/golden_vectors.json"
    );
    let text = std::fs::read_to_string(path)
        .expect("golden_vectors.json present (regen: `swift run aislopdesk-corevectors > …`)");
    serde_json::from_str(&text).expect("golden_vectors.json is valid JSON")
}

fn hx(s: &str) -> Vec<u8> {
    assert!(s.len() % 2 == 0, "odd-length hex: {s}");
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn to_hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        write!(s, "{b:02x}").unwrap();
    }
    s
}

fn section<'a>(root: &'a Value, key: &str) -> &'a Vec<Value> {
    root[key]
        .as_array()
        .unwrap_or_else(|| panic!("missing section {key}"))
}

fn u64v(r: &Value, k: &str) -> u64 {
    r[k].as_u64()
        .unwrap_or_else(|| panic!("field {k} not u64: {:?}", r[k]))
}
fn u32v(r: &Value, k: &str) -> u32 {
    u64v(r, k) as u32
}
fn u16v(r: &Value, k: &str) -> u16 {
    u64v(r, k) as u16
}
fn u8v(r: &Value, k: &str) -> u8 {
    u64v(r, k) as u8
}
fn f64v(r: &Value, k: &str) -> f64 {
    r[k].as_f64()
        .unwrap_or_else(|| panic!("field {k} not f64: {:?}", r[k]))
}
fn boolv(r: &Value, k: &str) -> bool {
    r[k].as_bool().unwrap()
}
fn i64v(r: &Value, k: &str) -> i64 {
    r[k].as_i64()
        .unwrap_or_else(|| panic!("field {k} not i64: {:?}", r[k]))
}
fn i32v(r: &Value, k: &str) -> i32 {
    i64v(r, k) as i32
}
fn strv<'a>(r: &'a Value, k: &str) -> &'a str {
    r[k].as_str().unwrap()
}
fn hexv(r: &Value, k: &str) -> Vec<u8> {
    hx(r[k].as_str().unwrap())
}
fn opt_hex(v: &Value) -> Option<Vec<u8>> {
    if v.is_null() {
        None
    } else {
        Some(hx(v.as_str().unwrap()))
    }
}

/// Assert a Rust encoding equals the Swift golden bytes, with a labelled diff on mismatch.
fn assert_hex(label: &str, got: &[u8], expected_hex: &str) {
    assert_eq!(
        to_hex(got),
        expected_hex,
        "{label}: Rust bytes differ from Swift golden"
    );
}

// ----- sections -----

#[test]
fn fragment_encode_parity() {
    let root = load();
    for r in section(&root, "fragmentEncode") {
        let payload = hexv(r, "payloadHex");
        let frag = FrameFragment {
            header: FrameFragmentHeader {
                stream_seq: u32v(r, "streamSeq"),
                frame_id: u32v(r, "frameID"),
                frag_index: u16v(r, "fragIndex"),
                frag_count: u16v(r, "fragCount"),
                flags: Flags(u8v(r, "flags")),
                host_send_ts_millis: u32v(r, "hostTs"),
                payload_length: payload.len() as u16,
            },
            payload,
        };
        assert_hex("fragmentEncode", &frag.encode(), strv(r, "hex"));
        // decode the Swift bytes and confirm a clean round-trip.
        let decoded = FrameFragment::decode(&hx(strv(r, "hex"))).unwrap();
        assert_eq!(to_hex(&decoded.encode()), strv(r, "hex"));
    }
}

#[test]
fn fec_parity_parity() {
    let root = load();
    for r in section(&root, "fecParity") {
        let data: Vec<Vec<u8>> = r["dataHex"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| hx(v.as_str().unwrap()))
            .collect();
        let slices: Vec<&[u8]> = data.iter().map(Vec::as_slice).collect();
        let group_size = u64v(r, "groupSize") as usize;
        let parity = XorParityFec::new(5).parity(&slices, group_size);
        let expected: Vec<String> = r["parityHex"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_owned())
            .collect();
        assert_eq!(parity.len(), expected.len(), "fecParity count");
        for (i, p) in parity.iter().enumerate() {
            assert_hex(&format!("fecParity[{i}]"), p, &expected[i]);
        }
    }
}

#[test]
fn fec_recover_parity() {
    let root = load();
    for r in section(&root, "fecRecover") {
        let mut data: Vec<Option<Vec<u8>>> = r["dataHex"]
            .as_array()
            .unwrap()
            .iter()
            .map(opt_hex)
            .collect();
        let parity: Vec<Option<Vec<u8>>> = r["parityHex"]
            .as_array()
            .unwrap()
            .iter()
            .map(opt_hex)
            .collect();
        let group_size = u64v(r, "groupSize") as usize;
        XorParityFec::new(5).recover(&mut data, &parity, group_size);
        let expected: Vec<Option<Vec<u8>>> = r["recoveredHex"]
            .as_array()
            .unwrap()
            .iter()
            .map(opt_hex)
            .collect();
        assert_eq!(data, expected, "fecRecover");
    }
}

#[test]
fn nalu_join_split_parity() {
    let root = load();
    for r in section(&root, "naluJoin") {
        let units: Vec<Vec<u8>> = r["unitsHex"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| hx(v.as_str().unwrap()))
            .collect();
        let joined = nal_unit::join(units.iter().map(Vec::as_slice));
        assert_hex("naluJoin", &joined, strv(r, "hex"));
    }
    for r in section(&root, "naluSplit") {
        let avcc = hexv(r, "avccHex");
        let units = nal_unit::split(&avcc);
        let expected: Vec<String> = r["unitsHex"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_owned())
            .collect();
        assert_eq!(units.len(), expected.len(), "naluSplit count");
        for (i, u) in units.iter().enumerate() {
            assert_hex(&format!("naluSplit[{i}]"), u, &expected[i]);
        }
    }
}

#[test]
fn cursor_parity() {
    let root = load();
    for r in section(&root, "cursorUpdate") {
        let u = CursorUpdate {
            position: VideoPoint::new(f64v(r, "x"), f64v(r, "y")),
            shape_id: u16v(r, "shapeID"),
            hotspot: VideoPoint::new(f64v(r, "hx"), f64v(r, "hy")),
            visible: boolv(r, "visible"),
        };
        assert_hex("cursorUpdate", &u.encode(), strv(r, "hex"));
        assert_eq!(CursorUpdate::decode(&hx(strv(r, "hex"))).unwrap(), u);
    }
    for r in section(&root, "cursorShape") {
        let s = CursorShapeMessage {
            shape_id: u16v(r, "shapeID"),
            size: VideoSize::new(f64v(r, "w"), f64v(r, "h")),
            hotspot: VideoPoint::new(f64v(r, "hx"), f64v(r, "hy")),
            bitmap: hexv(r, "bitmapHex"),
        };
        assert_hex("cursorShape", &s.encode(), strv(r, "hex"));
    }
}

#[test]
fn window_geometry_parity() {
    let root = load();
    for r in section(&root, "windowGeometry") {
        let msg = match strv(r, "variant") {
            "move" => WindowGeometryMessage::Move(VideoPoint::new(f64v(r, "x"), f64v(r, "y"))),
            "resize" => WindowGeometryMessage::Resize(VideoSize::new(f64v(r, "w"), f64v(r, "h"))),
            "bounds" => WindowGeometryMessage::Bounds(VideoRect::xywh(
                f64v(r, "x"),
                f64v(r, "y"),
                f64v(r, "w"),
                f64v(r, "h"),
            )),
            "title" => WindowGeometryMessage::Title(strv(r, "title").to_owned()),
            other => panic!("unknown windowGeometry variant {other}"),
        };
        assert_hex(
            &format!("windowGeometry/{}", strv(r, "variant")),
            &msg.encode(),
            strv(r, "hex"),
        );
        assert_eq!(
            WindowGeometryMessage::decode(&hx(strv(r, "hex"))).unwrap(),
            msg
        );
    }
}

#[test]
fn input_event_parity() {
    let root = load();
    for r in section(&root, "inputEvent") {
        let n = || VideoPoint::new(f64v(r, "nx"), f64v(r, "ny"));
        let mods = |k: &str| InputModifiers(u8v(r, k));
        let btn = || MouseButton::from_u8(u8v(r, "button")).unwrap();
        let msg = match strv(r, "variant") {
            "mouseMove" => InputEvent::MouseMove {
                normalized: n(),
                tag: u32v(r, "tag"),
            },
            "mouseDown" => InputEvent::MouseDown {
                button: btn(),
                normalized: n(),
                click_count: u8v(r, "clickCount"),
                modifiers: mods("mods"),
                tag: u32v(r, "tag"),
            },
            "mouseUp" => InputEvent::MouseUp {
                button: btn(),
                normalized: n(),
                click_count: u8v(r, "clickCount"),
                modifiers: mods("mods"),
                tag: u32v(r, "tag"),
            },
            "mouseDrag" => InputEvent::MouseDrag {
                button: btn(),
                normalized: n(),
                click_count: u8v(r, "clickCount"),
                modifiers: mods("mods"),
                tag: u32v(r, "tag"),
            },
            "scroll" => InputEvent::Scroll {
                dx: f64v(r, "dx"),
                dy: f64v(r, "dy"),
                normalized: n(),
                tag: u32v(r, "tag"),
            },
            "key" => InputEvent::Key {
                key_code: u16v(r, "keyCode"),
                down: boolv(r, "down"),
                modifiers: mods("mods"),
                tag: u32v(r, "tag"),
            },
            "text" => InputEvent::Text {
                text: strv(r, "text").to_owned(),
                tag: u32v(r, "tag"),
            },
            other => panic!("unknown inputEvent variant {other}"),
        };
        assert_hex(
            &format!("inputEvent/{}", strv(r, "variant")),
            &msg.encode(),
            strv(r, "hex"),
        );
        assert_eq!(InputEvent::decode(&hx(strv(r, "hex"))).unwrap(), msg);
    }
}

#[test]
fn video_control_parity() {
    let root = load();
    for r in section(&root, "videoControl") {
        let msg = match strv(r, "variant") {
            "hello" => VideoControlMessage::Hello {
                protocol_version: u16v(r, "version"),
                requested_window_id: u32v(r, "windowID"),
                viewport: VideoSize::new(f64v(r, "vw"), f64v(r, "vh")),
            },
            "helloAck" => VideoControlMessage::HelloAck {
                accepted: boolv(r, "accepted"),
                stream_id: u32v(r, "streamID"),
                capture_width: u16v(r, "cw"),
                capture_height: u16v(r, "ch"),
                window_bounds_cg: VideoRect::xywh(
                    f64v(r, "bx"),
                    f64v(r, "by"),
                    f64v(r, "bw"),
                    f64v(r, "bh"),
                ),
                full_range: boolv(r, "fullRange"),
            },
            "bye" => VideoControlMessage::Bye,
            "resizeRequest" => VideoControlMessage::ResizeRequest {
                desired: VideoSize::new(f64v(r, "w"), f64v(r, "h")),
                epoch: u32v(r, "epoch"),
            },
            "resizeAck" => VideoControlMessage::ResizeAck {
                capture_width: u16v(r, "cw"),
                capture_height: u16v(r, "ch"),
                epoch: u32v(r, "epoch"),
            },
            "keepalive" => VideoControlMessage::Keepalive,
            "listWindows" => VideoControlMessage::ListWindows,
            "windowList" => VideoControlMessage::WindowList(
                r["windows"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|w| WindowSummary {
                        window_id: u32v(w, "windowID"),
                        app_name: strv(w, "appName").to_owned(),
                        title: strv(w, "title").to_owned(),
                        width: u16v(w, "width"),
                        height: u16v(w, "height"),
                    })
                    .collect(),
            ),
            "focusWindow" => VideoControlMessage::FocusWindow,
            "streamCadence" => VideoControlMessage::StreamCadence {
                fps: u16v(r, "fps"),
            },
            "listSystemDialogs" => VideoControlMessage::ListSystemDialogs,
            "systemDialogList" => VideoControlMessage::SystemDialogList(
                r["dialogs"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|d| SystemDialogSummary {
                        window_id: u32v(d, "windowID"),
                        owner: strv(d, "owner").to_owned(),
                        title: strv(d, "title").to_owned(),
                        width: u16v(d, "width"),
                        height: u16v(d, "height"),
                        is_secure: boolv(d, "isSecure"),
                    })
                    .collect(),
            ),
            other => panic!("unknown videoControl variant {other}"),
        };
        assert_hex(
            &format!("videoControl/{}", strv(r, "variant")),
            &msg.encode(),
            strv(r, "hex"),
        );
        assert_eq!(
            VideoControlMessage::decode(&hx(strv(r, "hex"))).unwrap(),
            msg
        );
    }
}

#[test]
fn recovery_parity() {
    let root = load();
    for r in section(&root, "recovery") {
        let msg = match strv(r, "variant") {
            "ack" => RecoveryMessage::Ack {
                stream_seq: u32v(r, "streamSeq"),
            },
            "requestLTRRefresh" => RecoveryMessage::RequestLtrRefresh {
                from_frame_id: u32v(r, "from"),
                to_frame_id: u32v(r, "to"),
                last_decoded_frame_id: u32v(r, "lastDecoded"),
            },
            "requestIDR" => RecoveryMessage::RequestIdr {
                last_decoded_frame_id: u32v(r, "lastDecoded"),
            },
            "requestCursorShape" => RecoveryMessage::RequestCursorShape {
                shape_id: u16v(r, "shapeID"),
            },
            "networkStats" => RecoveryMessage::NetworkStats(NetworkStatsReport {
                frames_received: u32v(r, "framesReceived"),
                fec_recovered: u32v(r, "fecRecovered"),
                unrecovered: u32v(r, "unrecovered"),
                latest_host_send_ts: u32v(r, "latestHostSendTs"),
                client_hold_ms: u32v(r, "clientHoldMs"),
                owd_jitter_micros: u32v(r, "owdJitterMicros"),
                owd_trend_milli: u32v(r, "owdTrendMilli"),
                owd_trend_flags: u32v(r, "owdTrendFlags"),
                pacer_late_frames: u32v(r, "pacerLateFrames"),
                pacer_present_gaps: u32v(r, "pacerPresentGaps"),
                pacer_depth: u32v(r, "pacerDepth"),
            }),
            other => panic!("unknown recovery variant {other}"),
        };
        assert_hex(
            &format!("recovery/{}", strv(r, "variant")),
            &msg.encode(),
            strv(r, "hex"),
        );
        assert_eq!(RecoveryMessage::decode(&hx(strv(r, "hex"))).unwrap(), msg);
    }
}

#[test]
fn mux_parity() {
    let root = load();
    for r in section(&root, "muxBare") {
        let bytes = video_mux_header::encode(u32v(r, "channelID"), &hexv(r, "payloadHex"));
        assert_hex("muxBare", &bytes, strv(r, "hex"));
    }
    for r in section(&root, "muxFragment") {
        let payload = hexv(r, "payloadHex");
        let header = MuxFrameFragmentHeader {
            channel_id: u32v(r, "channelID"),
            stream_seq: u32v(r, "streamSeq"),
            frame_id: u32v(r, "frameID"),
            frag_index: u16v(r, "fragIndex"),
            frag_count: u16v(r, "fragCount"),
            flags: Flags(u8v(r, "flags")),
            payload_length: payload.len() as u16,
        };
        assert_hex("muxFragment", &header.encode(&payload), strv(r, "hex"));
    }
}

#[test]
fn coordinate_mapping_parity() {
    let root = load();
    for r in section(&root, "coordWindowPoint") {
        let p = coordinate_mapping::window_point(
            VideoPoint::new(f64v(r, "nx"), f64v(r, "ny")),
            VideoRect::xywh(f64v(r, "bx"), f64v(r, "by"), f64v(r, "bw"), f64v(r, "bh")),
        );
        assert_eq!(p.x.to_bits(), u64v(r, "outXBits"), "coord x bits");
        assert_eq!(p.y.to_bits(), u64v(r, "outYBits"), "coord y bits");
    }
}

#[test]
fn ycbcr_parity() {
    let root = load();
    for r in section(&root, "ycbcr") {
        let range = match strv(r, "range") {
            "video" => ColorRange::Video,
            "full" => ColorRange::Full,
            other => panic!("unknown range {other}"),
        };
        let c = ycbcr::coefficients(range);
        assert_eq!(c.luma_scale.to_bits(), u32v(r, "lumaScale"), "lumaScale");
        assert_eq!(c.luma_bias.to_bits(), u32v(r, "lumaBias"), "lumaBias");
        assert_eq!(c.chroma_bias.to_bits(), u32v(r, "chromaBias"), "chromaBias");
        assert_eq!(c.cr_to_r.to_bits(), u32v(r, "crToR"), "crToR");
        assert_eq!(c.cb_to_g.to_bits(), u32v(r, "cbToG"), "cbToG");
        assert_eq!(c.cr_to_g.to_bits(), u32v(r, "crToG"), "crToG");
        assert_eq!(c.cb_to_b.to_bits(), u32v(r, "cbToB"), "cbToB");
    }
}

#[test]
fn adaptive_fec_parity() {
    let root = load();
    for r in section(&root, "adaptiveTier") {
        let loss = f64::from_bits(u64v(r, "lossBits"));
        let tier = adaptive_fec::tier(loss, u8v(r, "prevTier"), boolv(r, "allowOff"));
        assert_eq!(
            u64::from(tier),
            u64v(r, "tier"),
            "adaptiveTier loss={loss} prev={}",
            u8v(r, "prevTier")
        );
    }
    for r in section(&root, "adaptiveGroupSize") {
        let got = adaptive_fec::group_size(u8v(r, "tier"), u64v(r, "def") as usize);
        let expected = if r["groupSize"].is_null() {
            None
        } else {
            Some(u64v(r, "groupSize") as usize)
        };
        assert_eq!(got, expected, "adaptiveGroupSize tier={}", u8v(r, "tier"));
    }
}

// ----- realtime-controller FLOAT-determinism parity -----
//
// Each test replays the SAME deterministic input sequence the Swift dumper drove and asserts the
// resulting f64 state is bit-identical (IEEE bit patterns), proving the port reproduces Swift's
// floating-point arithmetic operation-for-operation.

#[test]
fn network_estimate_fold_parity() {
    let root = load();
    let mut est = NetworkEstimate::new();
    for (i, r) in section(&root, "networkEstimateFold").iter().enumerate() {
        let rtt = if r["rtt"].is_null() {
            None
        } else {
            Some(r["rtt"].as_i64().unwrap())
        };
        est.fold(rtt, u32v(r, "frames"), u32v(r, "unrec"), u32v(r, "jitter"));
        assert_eq!(
            est.smoothed_rtt_millis().to_bits(),
            u64v(r, "smoothedBits"),
            "smoothed @{i}"
        );
        assert_eq!(
            est.min_rtt_millis().to_bits(),
            u64v(r, "minBits"),
            "min @{i}"
        );
        assert_eq!(
            est.loss_rate().to_bits(),
            u64v(r, "lossRateBits"),
            "lossRate @{i}"
        );
        assert_eq!(
            est.last_loss_sample().to_bits(),
            u64v(r, "lastLossBits"),
            "lastLoss @{i}"
        );
    }
}

#[test]
fn trendline_drive_parity() {
    let root = load();
    let r = &root["trendlineDrive"];
    let mut est = TrendlineEstimator::new();
    let mut arrival = 1000.0;
    let mut ts: u32 = 5000;
    est.note(arrival, ts);
    for _ in 0..60 {
        arrival += 16.0;
        ts = ts.wrapping_add(16);
        est.note(arrival, ts);
    }
    for _ in 0..40 {
        arrival += 41.0;
        ts = ts.wrapping_add(16);
        est.note(arrival, ts);
    }
    assert_eq!(
        est.modified_trend().to_bits(),
        u64v(r, "modifiedTrendBits"),
        "modifiedTrend"
    );
    assert_eq!(
        est.threshold().to_bits(),
        u64v(r, "thresholdBits"),
        "threshold"
    );
    assert_eq!(u64::from(est.state() as u8), u64v(r, "stateRaw"), "state");
    assert_eq!(est.num_deltas(), u64v(r, "numDeltas") as i64, "numDeltas");
    assert_eq!(
        est.wire_trend_milli(),
        u32v(r, "wireTrendMilli"),
        "wireTrendMilli"
    );
    assert_eq!(
        est.wire_trend_flags(),
        u32v(r, "wireTrendFlags"),
        "wireTrendFlags"
    );
}

#[test]
fn owd_late_drive_parity() {
    let root = load();
    let steps = section(&root, "owdLateDrive");
    let interval = 1000.0 / 60.0;
    let mut d = OwdLateDetector::default();
    let mut arrival = 5000.0;
    let mut send: u32 = 91_000;
    let mut seq: Vec<(f64, u32)> = Vec::new();
    for _ in 0..30 {
        seq.push((16.7, 17));
    }
    seq.push((16.7 + 40.0, 17));
    for _ in 0..5 {
        seq.push((16.7 + 30.0, 17));
    }
    for _ in 0..12 {
        seq.push((1.0, 17));
    }
    assert_eq!(seq.len(), steps.len(), "owdLateDrive step count");
    for (i, (darr, dsend)) in seq.into_iter().enumerate() {
        arrival += darr;
        send = send.wrapping_add(dsend);
        let got = d.note(arrival, send, interval);
        let expected = &steps[i]["devBits"];
        match got {
            Some(dev) => assert_eq!(dev.to_bits(), expected.as_u64().unwrap(), "owd dev @{i}"),
            None => assert!(
                expected.is_null(),
                "owd expected None @{i}, got {expected:?}"
            ),
        }
    }
}

#[test]
fn fps_governor_ewma_parity() {
    let root = load();
    let r = &root["fpsGovernorEwma"];
    let mut gov = FpsGovernor::new(60);
    for s in [
        10_000i64, 20_000, 15_000, 30_000, 12_000, 18_000, 22_000, 9_000, 40_000, 11_000,
    ] {
        gov.note_encoded_frame(s, false);
    }
    gov.note_encoded_frame(500_000, true); // anchor excluded
    assert_eq!(
        gov.bytes_per_frame_ewma().to_bits(),
        u64v(r, "bytesEwmaBits")
    );
}

#[test]
fn pacer_depth_floats_parity() {
    let root = load();
    let r = &root["pacerDepthFloats"];
    let mut dp = PacerDepthPolicy::new(PacerConfig::default(), true);
    let mut t = 0.0;
    let gaps = [
        1.0 / 60.0,
        1.0 / 60.0,
        1.0 / 50.0,
        1.0 / 60.0,
        1.0 / 72.0,
        1.0 / 60.0,
    ];
    for i in 0..30 {
        t += gaps[i % gaps.len()];
        dp.note_arrival(t);
        dp.note_present(t);
    }
    assert_eq!(
        dp.expected_interval_seconds().to_bits(),
        u64v(r, "expectedIntervalBits"),
        "expected"
    );
    assert_eq!(
        dp.late_threshold_seconds().to_bits(),
        u64v(r, "lateThresholdBits"),
        "lateThreshold"
    );

    let rh = &root["pacerDepthHinted"];
    let mut hinted = PacerDepthPolicy::new(PacerConfig::default(), true);
    hinted.set_interval_hint(Some(1.0 / 30.0));
    assert_eq!(
        hinted.expected_interval_seconds().to_bits(),
        u64v(rh, "expectedIntervalBits"),
        "hint expected"
    );
    assert_eq!(
        hinted.late_threshold_seconds().to_bits(),
        u64v(rh, "lateThresholdBits"),
        "hint lateThreshold"
    );
}

#[test]
fn terminal_wire_messages_parity() {
    let root = load();
    for r in section(&root, "terminalWireMessages") {
        let kind = strv(r, "kind");
        let msg = match kind {
            "output" => WireMessage::Output {
                seq: i64v(r, "seq"),
                bytes: hexv(r, "bytesHex"),
            },
            "exit" => WireMessage::Exit {
                code: i32v(r, "code"),
            },
            "input" => WireMessage::Input(hexv(r, "bytesHex")),
            "hello" => WireMessage::Hello {
                protocol_version: u16v(r, "protocolVersion"),
                session_id: SessionId::from_slice(&hexv(r, "sessionIdHex")),
                last_received_seq: i64v(r, "lastReceivedSeq"),
            },
            "resize" => WireMessage::Resize {
                cols: u16v(r, "cols"),
                rows: u16v(r, "rows"),
                px_width: u16v(r, "pxWidth"),
                px_height: u16v(r, "pxHeight"),
            },
            "ack" => WireMessage::Ack {
                seq: i64v(r, "seq"),
            },
            "bye" => WireMessage::Bye,
            "ping" => WireMessage::Ping {
                timestamp_ms: u64v(r, "timestampMs"),
            },
            "pong" => WireMessage::Pong {
                timestamp_ms: u64v(r, "timestampMs"),
            },
            "helloAck" => WireMessage::HelloAck {
                session_id: SessionId::from_slice(&hexv(r, "sessionIdHex")),
                resume_from_seq: i64v(r, "resumeFromSeq"),
                returning_client: boolv(r, "returningClient"),
            },
            "title" => WireMessage::Title(strv(r, "title").to_string()),
            "bell" => WireMessage::Bell,
            "commandStatus" => {
                let status = if strv(r, "cmd") == "running" {
                    CommandStatus::Running
                } else {
                    CommandStatus::Idle {
                        exit_code: if boolv(r, "hasExit") {
                            Some(i32v(r, "exitCode"))
                        } else {
                            None
                        },
                        duration_ms: u32v(r, "durationMs"),
                    }
                };
                WireMessage::CommandStatus(status)
            }
            "notification" => WireMessage::Notification {
                title: strv(r, "title").to_string(),
                body: strv(r, "body").to_string(),
            },
            other => panic!("unknown terminal wire kind {other}"),
        };
        let want = hexv(r, "hex");
        assert_eq!(
            to_hex(&msg.encode()),
            to_hex(&want),
            "encode mismatch for {kind}"
        );
        // And the frame round-trips back through decode (strip the 4-byte length prefix).
        assert_eq!(
            WireMessage::decode(&want[4..]).unwrap(),
            msg,
            "decode mismatch for {kind}"
        );
    }
}

#[test]
fn mux_envelopes_parity() {
    let root = load();
    for r in section(&root, "muxEnvelopes") {
        let kind = strv(r, "kind");
        let cid = u32v(r, "channelId");
        let frame = match kind {
            "channelOpen" => MuxFrame::ChannelOpen {
                channel_id: cid,
                session_id: SessionId::from_slice(&hexv(r, "sessionIdHex")),
                last_received_seq: i64v(r, "lastReceivedSeq"),
                channel_class: u8v(r, "channelClass"),
            },
            "channelOpenAck" => MuxFrame::ChannelOpenAck {
                channel_id: cid,
                accepted: boolv(r, "accepted"),
            },
            "channelData" => MuxFrame::ChannelData {
                channel_id: cid,
                payload: hexv(r, "payloadHex"),
            },
            "channelClose" => MuxFrame::ChannelClose { channel_id: cid },
            "windowAdjust" => MuxFrame::WindowAdjust {
                channel_id: cid,
                bytes_to_add: u32v(r, "bytesToAdd"),
            },
            other => panic!("unknown mux kind {other}"),
        };
        let want = hexv(r, "hex");
        assert_eq!(
            to_hex(&MuxEnvelopeCodec::encode(&frame)),
            to_hex(&want),
            "encode mismatch for {kind}"
        );
        assert_eq!(
            MuxEnvelopeCodec::decode(&want[4..]).unwrap(),
            frame,
            "decode mismatch for {kind}"
        );
    }
}
