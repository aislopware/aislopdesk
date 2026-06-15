use super::*;
use crate::geometry::{VideoRect, VideoSize};

// ----- shared test fixtures -----

const fn bounds() -> VideoRect {
    VideoRect::xywh(10.0, 20.0, 800.0, 600.0)
}

/// `acceptAll` resolver (named after its Swift shell test counterpart): every window resolves to 800×600.
// The `Option` is required: this is passed as the `Fn(u32, VideoSize) -> Option<(u16, u16)>`
// resolver to `handle_control`, so it must match that callback signature (a None-returning
// resolver is the reject path other tests exercise).
#[allow(clippy::unnecessary_wraps)]
const fn accept_all(_window_id: u32, _viewport: VideoSize) -> Option<(u16, u16)> {
    Some((800, 600))
}

/// A valid `hello` for `window_id` at the protocol version.
const fn hello(window_id: u32) -> VideoControlMessage {
    VideoControlMessage::Hello {
        protocol_version: crate::VIDEO_PROTOCOL_VERSION,
        requested_window_id: window_id,
        viewport: VideoSize::new(800.0, 600.0),
    }
}

/// The resize resolver from `ResizeStateMachineTests`: clamp to [320..3840]×[240..2160]
/// for the streaming window id 42, reject any other window.
fn resolve_resize(window_id: u32, desired: VideoSize) -> Option<(u16, u16)> {
    if window_id != 42 {
        return None;
    }
    Some(SizeNegotiation::clamp(
        desired,
        VideoSize::new(320.0, 240.0),
        VideoSize::new(3840.0, 2160.0),
    ))
}

/// Brings a fresh SM up to `.streaming` for window id 42 at 800×600.
fn streaming_machine(next_stream_id: u32) -> VideoSessionStateMachine {
    let mut sm = VideoSessionStateMachine::new(next_stream_id, false);
    sm.start();
    sm.handle_control(&hello(42), bounds(), accept_all, resolve_resize);
    assert_eq!(sm.state(), VideoSessionState::Streaming);
    sm
}

/// Extracts the `helloAck` fields from the first effect, or panics.
fn ack_fields(effects: &[Effect]) -> (bool, u32, u16, u16, bool) {
    match effects.first() {
        Some(Effect::SendControl(VideoControlMessage::HelloAck {
            accepted,
            stream_id,
            capture_width,
            capture_height,
            full_range,
            ..
        })) => (
            *accepted,
            *stream_id,
            *capture_width,
            *capture_height,
            *full_range,
        ),
        other => panic!("expected helloAck effect, got {other:?}"),
    }
}

// ===== VideoSessionStateMachine cases (the Swift `VideoSessionStateMachineTests` suite cross-checks the same) =====

#[test]
fn start_goes_idle_to_listening() {
    let mut sm = VideoSessionStateMachine::default();
    assert_eq!(sm.state(), VideoSessionState::Idle);
    let effects = sm.start();
    assert_eq!(sm.state(), VideoSessionState::Listening);
    assert!(effects.is_empty());
    assert!(!sm.media_flowing());
}

#[test]
fn valid_hello_accepts_and_starts_capture() {
    let mut sm = VideoSessionStateMachine::new(7, false);
    sm.start();
    let effects = sm.handle_control_no_resize(&hello(42), bounds(), accept_all);

    assert_eq!(sm.state(), VideoSessionState::Streaming);
    assert!(sm.media_flowing());
    assert_eq!(sm.window_id(), 42);
    assert_eq!(sm.capture_width(), 800);
    assert_eq!(sm.capture_height(), 600);

    // Ack first, then start capture — in that order.
    assert_eq!(
        effects,
        vec![
            Effect::SendControl(VideoControlMessage::HelloAck {
                accepted: true,
                stream_id: 7,
                capture_width: 800,
                capture_height: 600,
                window_bounds_cg: bounds(),
                full_range: false,
            }),
            Effect::StartCapture {
                window_id: 42,
                width: 800,
                height: 600,
            },
        ]
    );
}

#[test]
fn full_range_flag_stamped_into_accept_and_re_ack_but_never_into_reject() {
    let mut sm = VideoSessionStateMachine::new(1, true);
    sm.start();
    let accept = sm.handle_control_no_resize(&hello(42), bounds(), accept_all);
    let (accepted, _, _, _, fr_accept) = ack_fields(&accept);
    assert!(accepted);
    assert!(fr_accept, "accept ack carries the host's full-range flag");

    // Duplicate hello while streaming → re-ack must echo the SAME range.
    let again = sm.handle_control_no_resize(&hello(42), bounds(), accept_all);
    let (_, _, _, _, fr_re_ack) = ack_fields(&again);
    assert!(fr_re_ack, "re-ack echoes the same full-range value");

    // A reject (wrong-window resolver → None) always sends full_range: false.
    let mut rej = VideoSessionStateMachine::new(1, true);
    rej.start();
    let reject = rej.handle_control_no_resize(&hello(42), bounds(), |_, _| None);
    let (rej_accepted, _, _, _, fr_reject) = ack_fields(&reject);
    assert!(!rej_accepted);
    assert!(!fr_reject, "a reject never advertises full-range");
}

#[test]
fn default_state_machine_is_video_range() {
    let mut sm = VideoSessionStateMachine::default();
    sm.start();
    let accept = sm.handle_control_no_resize(&hello(42), bounds(), accept_all);
    let (_, _, _, _, fr) = ack_fields(&accept);
    assert!(!fr, "default host is video-range (OFF)");
}

#[test]
fn focus_window_is_a_state_machine_no_op() {
    let mut sm = VideoSessionStateMachine::new(7, false);
    sm.start();
    assert!(
        sm.handle_control_no_resize(&VideoControlMessage::FocusWindow, bounds(), accept_all)
            .is_empty(),
        "focusWindow yields no effects while listening",
    );
    assert_eq!(sm.state(), VideoSessionState::Listening);

    sm.handle_control_no_resize(&hello(42), bounds(), accept_all);
    assert_eq!(sm.state(), VideoSessionState::Streaming);
    assert!(
        sm.handle_control_no_resize(&VideoControlMessage::FocusWindow, bounds(), accept_all)
            .is_empty(),
        "focusWindow yields no effects while streaming",
    );
    assert_eq!(
        sm.state(),
        VideoSessionState::Streaming,
        "focusWindow must not perturb the streaming state"
    );
    assert!(sm.media_flowing());
}

#[test]
fn wrong_protocol_version_rejected() {
    let mut sm = VideoSessionStateMachine::default();
    sm.start();
    let bad_version = crate::VIDEO_PROTOCOL_VERSION.wrapping_add(1);
    let bad = VideoControlMessage::Hello {
        protocol_version: bad_version,
        requested_window_id: 1,
        viewport: VideoSize::new(100.0, 100.0),
    };
    let effects = sm.handle_control_no_resize(&bad, bounds(), accept_all);

    assert_eq!(sm.state(), VideoSessionState::Listening); // stayed listening — no accept
    assert!(!sm.media_flowing());
    assert_eq!(effects.len(), 1);
    let (accepted, _, _, _, _) = ack_fields(&effects);
    assert!(!accepted);
}

#[test]
fn resolve_capture_size_nil_rejects() {
    let mut sm = VideoSessionStateMachine::default();
    sm.start();
    let effects = sm.handle_control_no_resize(&hello(99), bounds(), |_, _| None);

    assert_eq!(sm.state(), VideoSessionState::Listening);
    assert_eq!(effects.len(), 1);
    let (accepted, _, _, _, _) = ack_fields(&effects);
    assert!(!accepted);
}

#[test]
fn duplicate_hello_while_streaming_re_acks_without_restarting_capture() {
    let mut sm = VideoSessionStateMachine::new(3, false);
    sm.start();
    sm.handle_control_no_resize(&hello(42), bounds(), accept_all);

    let again = sm.handle_control_no_resize(&hello(42), bounds(), accept_all);
    assert_eq!(sm.state(), VideoSessionState::Streaming);
    // Re-ack only — NO second startCapture.
    assert_eq!(again.len(), 1);
    let (accepted, stream_id, _, _, _) = ack_fields(&again);
    assert!(accepted);
    assert_eq!(
        stream_id, 3,
        "re-ack keeps the same stream id, does not mint a new one"
    );
}

#[test]
fn bye_stops_capture() {
    let mut sm = VideoSessionStateMachine::default();
    sm.start();
    sm.handle_control_no_resize(&hello(42), bounds(), accept_all);

    let effects = sm.handle_control_no_resize(&VideoControlMessage::Bye, bounds(), accept_all);
    assert_eq!(sm.state(), VideoSessionState::Listening);
    assert!(!sm.media_flowing());
    assert_eq!(effects, vec![Effect::StopCapture]);
}

#[test]
fn bye_returns_to_listening_not_stopped() {
    let mut sm = VideoSessionStateMachine::default();
    sm.start();
    sm.handle_control_no_resize(&hello(42), bounds(), accept_all);
    assert_eq!(sm.state(), VideoSessionState::Streaming);

    sm.handle_control_no_resize(&VideoControlMessage::Bye, bounds(), accept_all);
    assert_eq!(
        sm.state(),
        VideoSessionState::Listening,
        "bye must re-arm to .listening, not go terminal"
    );
    assert!(!sm.media_flowing());
}

#[test]
fn hello_after_bye_re_arms_capture_with_fresh_stream_id() {
    let mut sm = VideoSessionStateMachine::new(5, false);
    sm.start();
    let first = sm.handle_control_no_resize(&hello(42), bounds(), accept_all);
    let (_, first_stream_id, _, _, _) = ack_fields(&first);
    assert_eq!(first_stream_id, 5);

    sm.handle_control_no_resize(&VideoControlMessage::Bye, bounds(), accept_all);
    assert_eq!(sm.state(), VideoSessionState::Listening);

    let reconnect = sm.handle_control_no_resize(&hello(42), bounds(), accept_all);
    assert_eq!(sm.state(), VideoSessionState::Streaming);
    assert!(sm.media_flowing());
    assert_eq!(sm.window_id(), 42);
    assert_eq!(sm.capture_width(), 800);
    assert_eq!(sm.capture_height(), 600);

    assert_eq!(
        reconnect,
        vec![
            Effect::SendControl(VideoControlMessage::HelloAck {
                accepted: true,
                stream_id: 6,
                capture_width: 800,
                capture_height: 600,
                window_bounds_cg: bounds(),
                full_range: false,
            }),
            Effect::StartCapture {
                window_id: 42,
                width: 800,
                height: 600,
            },
        ]
    );
}

#[test]
fn bye_while_listening_is_idempotent_no_stop_capture() {
    let mut sm = VideoSessionStateMachine::default();
    sm.start();
    assert_eq!(sm.state(), VideoSessionState::Listening);

    let effects = sm.handle_control_no_resize(&VideoControlMessage::Bye, bounds(), accept_all);
    assert_eq!(sm.state(), VideoSessionState::Listening);
    assert!(
        effects.is_empty(),
        "no capture was running, so no stopCapture"
    );
    assert!(!sm.media_flowing());
}

#[test]
fn bye_while_idle_stays_idle_no_effects() {
    let mut sm = VideoSessionStateMachine::default();
    // No start() — sockets not bound; a bye must not transition or emit anything.
    let effects = sm.handle_control_no_resize(&VideoControlMessage::Bye, bounds(), accept_all);
    assert_eq!(sm.state(), VideoSessionState::Idle);
    assert!(effects.is_empty());
    assert!(!sm.media_flowing());
}

#[test]
fn local_stop_remains_terminal_after_fix() {
    let mut sm = VideoSessionStateMachine::default();
    sm.start();
    sm.handle_control_no_resize(&hello(42), bounds(), accept_all);

    assert_eq!(sm.stop(), vec![Effect::StopCapture]);
    assert_eq!(sm.state(), VideoSessionState::Stopped);
    let after_stop = sm.handle_control_no_resize(&hello(42), bounds(), accept_all);
    assert_eq!(
        sm.state(),
        VideoSessionState::Stopped,
        "local stop() is terminal — a hello must not re-arm it"
    );
    assert!(after_stop.is_empty());
    assert!(!sm.media_flowing());
}

#[test]
fn multiple_bye_hello_cycles_each_get_fresh_stream_id() {
    let mut sm = VideoSessionStateMachine::new(1, false);
    sm.start();

    let mut seen_stream_ids: Vec<u32> = Vec::new();
    for _ in 0..4 {
        let accept = sm.handle_control_no_resize(&hello(42), bounds(), accept_all);
        assert_eq!(sm.state(), VideoSessionState::Streaming);
        let (accepted, stream_id, _, _, _) = ack_fields(&accept);
        assert!(accepted);
        seen_stream_ids.push(stream_id);
        assert_eq!(
            accept[1],
            Effect::StartCapture {
                window_id: 42,
                width: 800,
                height: 600,
            }
        );

        sm.handle_control_no_resize(&VideoControlMessage::Bye, bounds(), accept_all);
        assert_eq!(sm.state(), VideoSessionState::Listening);
    }

    assert_eq!(seen_stream_ids, vec![1, 2, 3, 4]);
}

#[test]
fn stop_while_streaming_emits_stop_capture() {
    let mut sm = VideoSessionStateMachine::default();
    sm.start();
    sm.handle_control_no_resize(&hello(42), bounds(), accept_all);
    assert_eq!(sm.stop(), vec![Effect::StopCapture]);
    assert_eq!(sm.state(), VideoSessionState::Stopped);
    // A second stop is a no-op.
    assert!(sm.stop().is_empty());
}

#[test]
fn stop_while_merely_listening_emits_nothing() {
    let mut sm = VideoSessionStateMachine::default();
    sm.start();
    assert!(sm.stop().is_empty());
    assert_eq!(sm.state(), VideoSessionState::Stopped);
}

#[test]
fn hello_ignored_before_start() {
    let mut sm = VideoSessionStateMachine::default();
    // No start() — state is .idle, a hello must not accept.
    let effects = sm.handle_control_no_resize(&hello(1), bounds(), accept_all);
    assert_eq!(sm.state(), VideoSessionState::Idle);
    assert!(effects.is_empty());
}

#[test]
fn each_accepted_session_gets_a_fresh_stream_id() {
    let mut a = VideoSessionStateMachine::new(1, false);
    a.start();
    let e1 = a.handle_control_no_resize(&hello(5), bounds(), accept_all);
    let (_, s1, _, _, _) = ack_fields(&e1);
    assert_eq!(s1, 1);

    let mut b = VideoSessionStateMachine::new(2, false);
    b.start();
    let e2 = b.handle_control_no_resize(&hello(5), bounds(), accept_all);
    let (_, s2, _, _, _) = ack_fields(&e2);
    assert_eq!(s2, 2);
}

// ===== Resize state-machine cases (the Swift `ResizeStateMachineTests` suite cross-checks the same) =====

#[test]
fn resize_while_streaming_emits_resize_capture_clamped_with_epoch() {
    let mut sm = streaming_machine(7);
    let req = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(1280.0, 800.0),
        epoch: 1,
    };
    let effects = sm.handle_control(&req, bounds(), accept_all, resolve_resize);

    assert_eq!(
        sm.state(),
        VideoSessionState::Streaming,
        "resize stays in .streaming (same session)"
    );
    assert!(sm.media_flowing());
    assert_eq!(
        effects,
        vec![Effect::ResizeCapture {
            width: 1280,
            height: 800,
            epoch: 1,
        }]
    );
    assert_eq!(sm.capture_width(), 1280, "SM tracks the new clamped size");
    assert_eq!(sm.capture_height(), 800);
    assert_eq!(sm.last_resize_epoch(), 1);
}

#[test]
fn resize_clamps_below_min_and_above_max() {
    let mut sm = streaming_machine(7);
    let too_small = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(10.0, 10.0),
        epoch: 1,
    };
    assert_eq!(
        sm.handle_control(&too_small, bounds(), accept_all, resolve_resize),
        vec![Effect::ResizeCapture {
            width: 320,
            height: 240,
            epoch: 1,
        }]
    );

    let too_big = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(99999.0, 99999.0),
        epoch: 2,
    };
    assert_eq!(
        sm.handle_control(&too_big, bounds(), accept_all, resolve_resize),
        vec![Effect::ResizeCapture {
            width: 3840,
            height: 2160,
            epoch: 2,
        }]
    );
}

#[test]
fn resize_does_not_mint_new_stream_id() {
    let mut sm = streaming_machine(7);
    // The accept consumed stream id 7 → next would be 8. A resize must NOT mint one.
    let req = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(1280.0, 800.0),
        epoch: 1,
    };
    sm.handle_control(&req, bounds(), accept_all, resolve_resize);

    // Re-arm via bye, then a hello → should take stream id 8 if the resize did not advance.
    sm.handle_control(
        &VideoControlMessage::Bye,
        bounds(),
        accept_all,
        resolve_resize,
    );
    let reconnect = sm.handle_control(&hello(42), bounds(), accept_all, resolve_resize);
    let (_, stream_id, _, _, _) = ack_fields(&reconnect);
    assert_eq!(
        stream_id, 8,
        "the resize between hello and bye did NOT consume a stream id"
    );
}

#[test]
fn stale_epoch_ignored() {
    let mut sm = streaming_machine(7);
    let first = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(1280.0, 800.0),
        epoch: 5,
    };
    assert_eq!(
        sm.handle_control(&first, bounds(), accept_all, resolve_resize),
        vec![Effect::ResizeCapture {
            width: 1280,
            height: 800,
            epoch: 5,
        }]
    );
    assert_eq!(sm.last_resize_epoch(), 5);

    // A reordered/duplicate request with an OLDER (and equal) epoch is dropped.
    let stale = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(640.0, 480.0),
        epoch: 3,
    };
    assert!(
        sm.handle_control(&stale, bounds(), accept_all, resolve_resize)
            .is_empty()
    );
    let dup = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(640.0, 480.0),
        epoch: 5,
    };
    assert!(
        sm.handle_control(&dup, bounds(), accept_all, resolve_resize)
            .is_empty()
    );
    assert_eq!(sm.capture_width(), 1280);
    assert_eq!(sm.capture_height(), 800);
    assert_eq!(sm.last_resize_epoch(), 5);

    // A fresh higher epoch still applies.
    let fresh = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(1920.0, 1080.0),
        epoch: 6,
    };
    assert_eq!(
        sm.handle_control(&fresh, bounds(), accept_all, resolve_resize),
        vec![Effect::ResizeCapture {
            width: 1920,
            height: 1080,
            epoch: 6,
        }]
    );
}

#[test]
fn resize_epoch_resets_on_fresh_hello_accept() {
    let mut sm = streaming_machine(7);
    // Drive the first session's epoch high.
    let high = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(1920.0, 1080.0),
        epoch: 9,
    };
    assert_eq!(
        sm.handle_control(&high, bounds(), accept_all, resolve_resize),
        vec![Effect::ResizeCapture {
            width: 1920,
            height: 1080,
            epoch: 9,
        }]
    );
    assert_eq!(sm.last_resize_epoch(), 9);

    // Client disconnects + reconnects (bye → fresh hello).
    sm.handle_control(
        &VideoControlMessage::Bye,
        bounds(),
        accept_all,
        resolve_resize,
    );
    sm.handle_control(&hello(42), bounds(), accept_all, resolve_resize);
    assert_eq!(sm.state(), VideoSessionState::Streaming);
    assert_eq!(
        sm.last_resize_epoch(),
        0,
        "a fresh hello-accept re-arms last_resize_epoch to 0"
    );

    // The reconnected client's FIRST resize (epoch 1, < the old 9) must now WIN, not drop.
    let first_after_reconnect = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(1280.0, 800.0),
        epoch: 1,
    };
    assert_eq!(
        sm.handle_control(&first_after_reconnect, bounds(), accept_all, resolve_resize),
        vec![Effect::ResizeCapture {
            width: 1280,
            height: 800,
            epoch: 1,
        }],
    );
    assert_eq!(sm.last_resize_epoch(), 1);
}

#[test]
fn resize_ignored_while_listening() {
    let mut sm = VideoSessionStateMachine::default();
    sm.start();
    assert_eq!(sm.state(), VideoSessionState::Listening);
    let req = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(1280.0, 800.0),
        epoch: 1,
    };
    assert!(
        sm.handle_control(&req, bounds(), accept_all, resolve_resize)
            .is_empty()
    );
    assert_eq!(sm.state(), VideoSessionState::Listening);
    assert_eq!(
        sm.last_resize_epoch(),
        0,
        "no resize applied while listening"
    );
}

#[test]
fn resize_ignored_while_idle() {
    let mut sm = VideoSessionStateMachine::default();
    let req = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(1280.0, 800.0),
        epoch: 1,
    };
    assert!(
        sm.handle_control(&req, bounds(), accept_all, resolve_resize)
            .is_empty()
    );
    assert_eq!(sm.state(), VideoSessionState::Idle);
}

#[test]
fn resize_ignored_after_stop() {
    let mut sm = streaming_machine(7);
    sm.stop();
    assert_eq!(sm.state(), VideoSessionState::Stopped);
    let req = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(1280.0, 800.0),
        epoch: 1,
    };
    assert!(
        sm.handle_control(&req, bounds(), accept_all, resolve_resize)
            .is_empty()
    );
    assert_eq!(sm.state(), VideoSessionState::Stopped);
}

#[test]
fn resize_for_wrong_window_rejected_by_resolver() {
    let mut sm = streaming_machine(7);
    // Resolver only accepts window id 99; session is window 42 → reject.
    let reject_resolver = |wid: u32, _d: VideoSize| -> Option<(u16, u16)> {
        if wid == 99 { Some((640, 480)) } else { None }
    };
    let req = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(1280.0, 800.0),
        epoch: 1,
    };
    assert!(
        sm.handle_control(&req, bounds(), accept_all, reject_resolver)
            .is_empty()
    );
    assert_eq!(sm.state(), VideoSessionState::Streaming);
    assert_eq!(
        sm.last_resize_epoch(),
        0,
        "rejected resize does NOT advance the epoch (a later valid request still wins)"
    );
    assert_eq!(
        sm.capture_width(),
        800,
        "capture stays at the hello-negotiated size"
    );
    assert_eq!(sm.capture_height(), 600);
}

#[test]
fn resize_resolver_receives_session_window_id() {
    let mut sm = streaming_machine(7);
    let seen: std::cell::Cell<Option<u32>> = std::cell::Cell::new(None);
    let spy = |wid: u32, _d: VideoSize| -> Option<(u16, u16)> {
        seen.set(Some(wid));
        Some((1024, 768))
    };
    let req = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(1024.0, 768.0),
        epoch: 1,
    };
    sm.handle_control(&req, bounds(), accept_all, spy);
    assert_eq!(
        seen.get(),
        Some(42),
        "the resolver is handed the streaming session's window id"
    );
}

// ===== Size-negotiation cases (the Swift `SizeNegotiationTests` suite cross-checks the same) =====

const fn min_size() -> VideoSize {
    VideoSize::new(320.0, 240.0)
}
const fn max_size() -> VideoSize {
    VideoSize::new(3840.0, 2160.0)
}

#[test]
fn within_bounds_is_identity() {
    let (w, h) = SizeNegotiation::clamp(VideoSize::new(1280.0, 800.0), min_size(), max_size());
    assert_eq!(w, 1280);
    assert_eq!(h, 800);
}

#[test]
fn below_min_clamps_up_to_min() {
    let (w, h) = SizeNegotiation::clamp(VideoSize::new(100.0, 50.0), min_size(), max_size());
    assert_eq!(w, 320);
    assert_eq!(h, 240);
}

#[test]
fn above_max_clamps_down_to_max() {
    let (w, h) = SizeNegotiation::clamp(VideoSize::new(9999.0, 9999.0), min_size(), max_size());
    assert_eq!(w, 3840);
    assert_eq!(h, 2160);
}

#[test]
fn zero_desired_never_returns_zero() {
    let (w, h) = SizeNegotiation::clamp(VideoSize::new(0.0, 0.0), min_size(), max_size());
    assert_eq!(w, 320, "zero desired clamps up to the min, never 0");
    assert_eq!(h, 240);
}

#[test]
fn zero_min_policy_still_never_returns_zero() {
    let (w, h) = SizeNegotiation::clamp(
        VideoSize::new(0.0, 0.0),
        VideoSize::new(0.0, 0.0),
        max_size(),
    );
    assert!(w >= 1);
    assert!(h >= 1);
}

#[test]
fn rounds_to_nearest_int() {
    let (w, h) = SizeNegotiation::clamp(VideoSize::new(1280.4, 800.6), min_size(), max_size());
    assert_eq!(w, 1280);
    assert_eq!(h, 801);
}

#[test]
fn u16_safety_clamps_huge_at_max_policy_and_ceiling() {
    let (w, h) = SizeNegotiation::clamp(
        VideoSize::new(1_000_000.0, 1_000_000.0),
        min_size(),
        VideoSize::new(1_000_000.0, 1_000_000.0),
    );
    assert_eq!(w, u16::MAX);
    assert_eq!(h, u16::MAX);
}

#[test]
fn aspect_clamp_per_axis_independently() {
    let (w, h) = SizeNegotiation::clamp(VideoSize::new(100.0, 9999.0), min_size(), max_size());
    assert_eq!(w, 320);
    assert_eq!(h, 2160);
}

#[test]
fn non_finite_desired_collapses_to_lower_bound_not_trap() {
    let (w, h) = SizeNegotiation::clamp(
        VideoSize::new(f64::NAN, f64::INFINITY),
        min_size(),
        max_size(),
    );
    assert_eq!(w, 320, "NaN width collapses to the width min, never traps");
    assert_eq!(
        h, 240,
        "inf height collapses to the height min, never overflows/traps"
    );
}

#[test]
fn swapped_policy_still_clamps_into_valid_range() {
    let (w, h) = SizeNegotiation::clamp(
        VideoSize::new(1280.0, 800.0),
        VideoSize::new(3840.0, 2160.0),
        VideoSize::new(320.0, 240.0),
    );
    assert!(w >= 1);
    assert!(h >= 1);
    assert!(w <= 3840);
    assert!(h <= 2160);
}

#[test]
fn epoch_stale_when_less_than_or_equal_to_last_applied() {
    assert!(
        SizeNegotiation::is_stale_epoch(5, 5),
        "equal epoch is a dup → stale"
    );
    assert!(SizeNegotiation::is_stale_epoch(3, 5), "older epoch → stale");
    assert!(SizeNegotiation::is_stale_epoch(0, 5));
}

#[test]
fn epoch_fresh_when_greater_than_last_applied() {
    assert!(!SizeNegotiation::is_stale_epoch(6, 5));
    assert!(!SizeNegotiation::is_stale_epoch(u32::MAX, 5));
}

#[test]
fn first_epoch_against_zero_is_never_stale() {
    assert!(!SizeNegotiation::is_stale_epoch(1, 0));
    // epoch 0 against 0 is still "stale" (no real request carries epoch 0).
    assert!(SizeNegotiation::is_stale_epoch(0, 0));
}

// ===== Added edge cases =====

#[test]
fn wrong_version_hello_rejects_even_while_streaming() {
    // The strict version guard runs BEFORE the state guard, so a wrong-version hello while
    // streaming still produces a reject ack and does NOT perturb the live session.
    let mut sm = streaming_machine(7);
    let bad = VideoControlMessage::Hello {
        protocol_version: crate::VIDEO_PROTOCOL_VERSION.wrapping_add(1),
        requested_window_id: 42,
        viewport: VideoSize::new(800.0, 600.0),
    };
    let effects = sm.handle_control_no_resize(&bad, bounds(), accept_all);
    let (accepted, stream_id, cw, ch, fr) = ack_fields(&effects);
    assert!(!accepted);
    assert_eq!(stream_id, 0);
    assert_eq!(cw, 0);
    assert_eq!(ch, 0);
    assert!(!fr);
    // Live session untouched.
    assert_eq!(sm.state(), VideoSessionState::Streaming);
    assert_eq!(sm.capture_width(), 800);
    assert_eq!(sm.window_id(), 42);
}

#[test]
fn duplicate_hello_for_different_window_while_streaming_is_noop() {
    // A correct-version hello for a DIFFERENT window while streaming is neither accepted
    // (already streaming) nor re-acked (different window) → no effects, no state change.
    let mut sm = streaming_machine(7);
    let effects = sm.handle_control_no_resize(&hello(99), bounds(), accept_all);
    assert!(effects.is_empty());
    assert_eq!(sm.state(), VideoSessionState::Streaming);
    assert_eq!(sm.window_id(), 42, "the streaming window is unchanged");
}

#[test]
fn stream_id_wraps_around_like_swift_overflow_add() {
    // Swift mints with `nextStreamID &+= 1` (wrapping). Starting at u32::MAX, the first
    // accept yields u32::MAX, then the next session wraps to 0.
    let mut sm = VideoSessionStateMachine::new(u32::MAX, false);
    sm.start();
    let first = sm.handle_control_no_resize(&hello(42), bounds(), accept_all);
    let (_, s1, _, _, _) = ack_fields(&first);
    assert_eq!(s1, u32::MAX);

    sm.handle_control_no_resize(&VideoControlMessage::Bye, bounds(), accept_all);
    let second = sm.handle_control_no_resize(&hello(42), bounds(), accept_all);
    let (_, s2, _, _, _) = ack_fields(&second);
    assert_eq!(s2, 0, "the stream id counter wraps, never traps");
}

#[test]
fn host_only_control_messages_are_inert_no_ops() {
    // Every host→client (or daemon-level) message reaching the SM is a defensive no-op that
    // does not change state, regardless of session phase.
    let mut sm = streaming_machine(7);
    let inert = [
        VideoControlMessage::HelloAck {
            accepted: true,
            stream_id: 1,
            capture_width: 1,
            capture_height: 1,
            window_bounds_cg: bounds(),
            full_range: false,
        },
        VideoControlMessage::ResizeAck {
            capture_width: 1,
            capture_height: 1,
            epoch: 1,
        },
        VideoControlMessage::StreamCadence { fps: 60 },
        VideoControlMessage::Keepalive,
        VideoControlMessage::ListWindows,
        VideoControlMessage::WindowList(Vec::new()),
        VideoControlMessage::ListSystemDialogs,
        VideoControlMessage::SystemDialogList(Vec::new()),
    ];
    for msg in &inert {
        assert!(
            sm.handle_control(msg, bounds(), accept_all, resolve_resize)
                .is_empty(),
            "{msg:?} must yield no effects",
        );
        assert_eq!(sm.state(), VideoSessionState::Streaming);
        assert_eq!(sm.capture_width(), 800);
        assert_eq!(sm.last_resize_epoch(), 0);
    }
}

#[test]
fn clamp_negative_desired_collapses_to_lower_bound() {
    // A finite negative desired rounds, then clamps up to the (≥1) lower bound — never 0.
    let (w, h) = SizeNegotiation::clamp(VideoSize::new(-500.0, -1.0), min_size(), max_size());
    assert_eq!(w, 320);
    assert_eq!(h, 240);
}

#[test]
fn clamp_min_equals_max_pins_axis() {
    // When min == max the axis is pinned to that value regardless of desired.
    let pinned = VideoSize::new(640.0, 480.0);
    assert_eq!(
        SizeNegotiation::clamp(VideoSize::new(10.0, 10.0), pinned, pinned),
        (640, 480)
    );
    assert_eq!(
        SizeNegotiation::clamp(VideoSize::new(9999.0, 9999.0), pinned, pinned),
        (640, 480)
    );
}

#[test]
fn clamp_negative_min_policy_floors_at_one() {
    // A hostile negative min floor is raised to 1 (never 0, never negative → no u16 trap).
    let (w, h) = SizeNegotiation::clamp(
        VideoSize::new(0.0, 0.0),
        VideoSize::new(-100.0, -100.0),
        max_size(),
    );
    assert_eq!(w, 1);
    assert_eq!(h, 1);
}

#[test]
fn resize_at_max_epoch_applies_then_blocks_equal() {
    // An epoch of u32::MAX applies (fresh vs 0), then a duplicate u32::MAX is stale.
    let mut sm = streaming_machine(7);
    let at_max = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(1280.0, 800.0),
        epoch: u32::MAX,
    };
    assert_eq!(
        sm.handle_control(&at_max, bounds(), accept_all, resolve_resize),
        vec![Effect::ResizeCapture {
            width: 1280,
            height: 800,
            epoch: u32::MAX,
        }]
    );
    assert_eq!(sm.last_resize_epoch(), u32::MAX);
    // A second u32::MAX is a duplicate → dropped.
    let dup = VideoControlMessage::ResizeRequest {
        desired: VideoSize::new(640.0, 480.0),
        epoch: u32::MAX,
    };
    assert!(
        sm.handle_control(&dup, bounds(), accept_all, resolve_resize)
            .is_empty()
    );
    assert_eq!(sm.capture_width(), 1280);
}
