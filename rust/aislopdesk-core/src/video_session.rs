//! Pure, platform-free host video-session orchestration — the canonical session-logic core.
//!
//! The native Swift shell keeps a copy (`Sources/AislopdeskVideoHost/VideoSessionLogic.swift`)
//! that tracks this (golden parity).
//!
//! This module covers exactly three types — [`VideoSessionState`],
//! [`VideoSessionStateMachine`], and [`SizeNegotiation`] — the pure decision core the host
//! actor (`AislopdeskVideoHostSession`) delegates to. There is NO `ScreenCaptureKit` /
//! `VideoToolbox` / Network here: the state machine validates the client `hello`, decides the
//! `helloAck`, gates whether media may flow, and folds in-session `resizeRequest`s, returning
//! [`Effect`]s the actor performs. The same discipline as
//! [`crate::video_control`], so the transitions + the size clamp are unit-testable in isolation.
//!
//! The companion pure types (`InputDatagramRouter`, `InputInjectorRaisePolicy`,
//! `InputButtonBalance`, `InputMotionCoalescer`, `RecoveryDatagramRouter`, `NetworkEstimate`,
//! `StaticIDRDecider`, `VideoSendScheduler`) live in their own modules — see
//! [`crate::network_estimate`] and the input/recovery controllers — and are intentionally
//! kept out of scope here.

use crate::geometry::{VideoRect, VideoSize};
use crate::video_control::VideoControlMessage;

/// Lifecycle state of a host video session. The Swift shell's `VideoSessionState` mirrors this.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoSessionState {
    /// Sockets not yet bound; nothing flowing.
    Idle,
    /// Sockets bound, awaiting the client `hello`.
    Listening,
    /// `hello` accepted; capture/encode running, media flowing.
    Streaming,
    /// `stop()` (or `bye`) ran; terminal.
    Stopped,
}

/// Side effects the actor must perform after a transition. The Swift shell's
/// `VideoSessionStateMachine.Effect` mirrors this.
///
/// `Effect` is `PartialEq` but not `Eq`: it wraps a [`VideoControlMessage`], whose `f64`
/// fields make total equality impossible — exactly the crate-wide rule for float-carrying
/// wire types.
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// Send this control message back to the client.
    SendControl(VideoControlMessage),
    /// Bring up capture + encode for `window_id` at the negotiated dimensions.
    StartCapture {
        /// The host `CGWindowID` to capture.
        window_id: u32,
        /// Negotiated capture width.
        width: u16,
        /// Negotiated capture height.
        height: u16,
    },
    /// Tear down capture + encode.
    StopCapture,
    /// Re-size the LIVE capture/encode of the streaming window to the clamped dimensions for
    /// the request carrying `epoch`. The actor performs the AX resize +
    /// `SCStream.updateConfiguration` + encoder reconfigure and replies with `resizeAck`.
    /// Does NOT mint a new stream id — the session is the same, only the capture geometry
    /// changes.
    ResizeCapture {
        /// The adopted capture width.
        width: u16,
        /// The adopted capture height.
        height: u16,
        /// The request epoch this resize applies.
        epoch: u32,
    },
}

/// The pure state machine driving a host video session.
///
/// It validates the client `hello`,
/// decides the `helloAck`, and gates whether media may flow — with NO live component. The
/// actor advances it and acts on the returned [`Effect`]s. The Swift shell's
/// `VideoSessionStateMachine` mirrors this.
#[derive(Debug, Clone)]
pub struct VideoSessionStateMachine {
    state: VideoSessionState,
    capture_width: u16,
    capture_height: u16,
    window_id: u32,
    /// The monotonically increasing stream id handed to the client on accept (lets a
    /// reconnecting client distinguish a fresh session).
    next_stream_id: u32,
    /// WF-6 (#8): whether this host is encoding FULL-RANGE luma. Stamped into every accepted
    /// `helloAck` (and the duplicate re-ack — which MUST echo the same value). A reject always
    /// sends `full_range: false`. Default false ⇒ today's video-range, byte-identical.
    full_range: bool,
    /// The highest resize epoch already APPLIED for the current streaming session, so a
    /// stale/duplicate `resizeRequest` (UDP may reorder/duplicate) is dropped. Re-armed to 0
    /// per accepted session; 0 ⇒ none applied yet (the first request, epoch ≥ 1, always wins).
    last_resize_epoch: u32,
    /// The stream id minted for the CURRENT accepted session (echoed on the duplicate re-ack).
    last_stream_id: u32,
}

impl Default for VideoSessionStateMachine {
    fn default() -> Self {
        Self::new(Self::DEFAULT_NEXT_STREAM_ID, Self::DEFAULT_FULL_RANGE)
    }
}

impl VideoSessionStateMachine {
    /// Default `next_stream_id` (the first accepted session mints stream id 1).
    pub const DEFAULT_NEXT_STREAM_ID: u32 = 1;
    /// Default `full_range` (video-range, the wire-byte-identical OFF path).
    pub const DEFAULT_FULL_RANGE: bool = false;

    /// Builds a fresh state machine in [`VideoSessionState::Idle`]. `next_stream_id` is the id
    /// the first accepted session will mint; `full_range` stamps the negotiated luma range into
    /// every accept ack. See [`DEFAULT_NEXT_STREAM_ID`](Self::DEFAULT_NEXT_STREAM_ID) /
    /// [`DEFAULT_FULL_RANGE`](Self::DEFAULT_FULL_RANGE) (or [`Default`]) for the canonical defaults.
    #[must_use]
    pub const fn new(next_stream_id: u32, full_range: bool) -> Self {
        Self {
            state: VideoSessionState::Idle,
            capture_width: 0,
            capture_height: 0,
            window_id: 0,
            next_stream_id,
            full_range,
            last_resize_epoch: 0,
            last_stream_id: 0,
        }
    }

    /// The current lifecycle state.
    #[must_use]
    pub const fn state(&self) -> VideoSessionState {
        self.state
    }

    /// Negotiated capture width (0 until a hello is accepted).
    #[must_use]
    pub const fn capture_width(&self) -> u16 {
        self.capture_width
    }

    /// Negotiated capture height (0 until a hello is accepted).
    #[must_use]
    pub const fn capture_height(&self) -> u16 {
        self.capture_height
    }

    /// The window the accepted session is remoting (0 until a hello is accepted).
    #[must_use]
    pub const fn window_id(&self) -> u32 {
        self.window_id
    }

    /// Whether this host advertises full-range luma in its accept acks.
    #[must_use]
    pub const fn full_range(&self) -> bool {
        self.full_range
    }

    /// The highest resize epoch already applied for the current session (0 = none).
    #[must_use]
    pub const fn last_resize_epoch(&self) -> u32 {
        self.last_resize_epoch
    }

    /// Whether media (video/geometry/cursor) is allowed to flow right now.
    #[must_use]
    pub const fn media_flowing(&self) -> bool {
        matches!(self.state, VideoSessionState::Streaming)
    }

    /// `start()` was called: bind sockets, wait for the client hello. A no-op (empty effects)
    /// unless currently [`VideoSessionState::Idle`].
    pub fn start(&mut self) -> Vec<Effect> {
        if self.state != VideoSessionState::Idle {
            return Vec::new();
        }
        self.state = VideoSessionState::Listening;
        Vec::new()
    }

    /// Convenience for the hello/bye call sites that never carry an in-session resize: matches
    /// the Swift shell's `resolveResizeSize` default argument (`{ _, _ in nil }`). Equivalent to
    /// [`handle_control`](Self::handle_control) with a resolver that always rejects resizes.
    pub fn handle_control_no_resize(
        &mut self,
        message: &VideoControlMessage,
        window_bounds_cg: VideoRect,
        resolve_capture_size: impl Fn(u32, VideoSize) -> Option<(u16, u16)>,
    ) -> Vec<Effect> {
        self.handle_control(
            message,
            window_bounds_cg,
            resolve_capture_size,
            |_window_id: u32, _desired: VideoSize| None,
        )
    }

    /// A control datagram arrived. Returns the effects (helloAck + startCapture on a valid
    /// hello; stopCapture on bye; resizeCapture on an in-session resize). An invalid/duplicate
    /// hello is rejected.
    ///
    /// - `message`: the decoded control message.
    /// - `window_bounds_cg`: the live window bounds to report in the ack (the actor reads these
    ///   from the geometry watcher; the pure SM just forwards them).
    /// - `resolve_capture_size`: maps `(requested_window_id, viewport)` → the capture size the
    ///   host will actually use. `None` rejects the session.
    /// - `resolve_resize_size`: maps an in-session `resizeRequest`'s `(window_id, desired)` →
    ///   the clamped capture size the host will adopt (typically via
    ///   [`SizeNegotiation::clamp`]). `None` rejects the resize (window gone / out of policy),
    ///   so capture stays at its current size and the epoch is NOT advanced.
    #[allow(clippy::too_many_lines)] // one flat match over the wire variants reads clearest inline.
    pub fn handle_control(
        &mut self,
        message: &VideoControlMessage,
        window_bounds_cg: VideoRect,
        resolve_capture_size: impl Fn(u32, VideoSize) -> Option<(u16, u16)>,
        resolve_resize_size: impl Fn(u32, VideoSize) -> Option<(u16, u16)>,
    ) -> Vec<Effect> {
        match message {
            VideoControlMessage::Hello {
                protocol_version,
                requested_window_id,
                viewport,
            } => {
                let requested_window_id = *requested_window_id;
                let viewport = *viewport;
                // Strict version check — no fallback (doc 20 §4 discipline).
                if *protocol_version != crate::VIDEO_PROTOCOL_VERSION {
                    return vec![Effect::SendControl(reject_hello_ack(window_bounds_cg))];
                }
                // Only accept a hello while listening; ignore a duplicate once streaming
                // (idempotent — the client may retransmit the unreliable hello).
                if self.state != VideoSessionState::Listening {
                    if self.state == VideoSessionState::Streaming
                        && requested_window_id == self.window_id
                    {
                        // Re-ack an in-flight duplicate so a lost ack is recovered, but do NOT
                        // restart capture.
                        return vec![Effect::SendControl(VideoControlMessage::HelloAck {
                            accepted: true,
                            stream_id: self.last_stream_id,
                            capture_width: self.capture_width,
                            capture_height: self.capture_height,
                            window_bounds_cg,
                            full_range: self.full_range,
                        })];
                    }
                    return Vec::new();
                }
                let Some((w, h)) = resolve_capture_size(requested_window_id, viewport) else {
                    return vec![Effect::SendControl(reject_hello_ack(window_bounds_cg))];
                };
                let stream_id = self.next_stream_id;
                self.next_stream_id = self.next_stream_id.wrapping_add(1);
                self.last_stream_id = stream_id;
                self.capture_width = w;
                self.capture_height = h;
                self.window_id = requested_window_id;
                // Reset the resize epoch for the FRESH session. A reconnecting client mints its
                // own epochs from 1 again (its `ResizeDebounce` is per-connection), so a stale
                // `last_resize_epoch` carried over from the PRIOR session would make every epoch
                // of the new session look stale and silently drop its first resizes. Re-arm to 0
                // here so the new session's first request (epoch ≥ 1) wins.
                self.last_resize_epoch = 0;
                self.state = VideoSessionState::Streaming;
                vec![
                    Effect::SendControl(VideoControlMessage::HelloAck {
                        accepted: true,
                        stream_id,
                        capture_width: w,
                        capture_height: h,
                        window_bounds_cg,
                        full_range: self.full_range,
                    }),
                    Effect::StartCapture {
                        window_id: requested_window_id,
                        width: w,
                        height: h,
                    },
                ]
            }
            VideoControlMessage::Bye => {
                // A client bye re-arms the session so a fresh hello can reconnect WITHOUT a
                // daemon restart (#8). Return to .listening (re-armable) and stop capture only if
                // it was actually streaming. (Local stop() — which also closes the UDP sockets —
                // stays terminal .stopped, NOT re-armable.)
                let was_streaming = self.state == VideoSessionState::Streaming;
                if self.state != VideoSessionState::Streaming
                    && self.state != VideoSessionState::Listening
                {
                    return Vec::new();
                }
                self.state = VideoSessionState::Listening;
                if was_streaming {
                    vec![Effect::StopCapture]
                } else {
                    Vec::new()
                }
            }
            VideoControlMessage::ResizeRequest { desired, epoch } => {
                let desired = *desired;
                let epoch = *epoch;
                // In-session resize: accept ONLY while streaming. A request that arrives while
                // listening/stopped (no live capture) is ignored — there is nothing to re-size.
                if self.state != VideoSessionState::Streaming {
                    return Vec::new();
                }
                // A stale/dup epoch (≤ the last applied) is dropped so a UDP reorder/retransmit
                // cannot shrink-then-grow the capture out of order.
                if SizeNegotiation::is_stale_epoch(epoch, self.last_resize_epoch) {
                    return Vec::new();
                }
                // The closure clamps `desired` against the LIVE window (min/max) for the
                // session's `window_id`; `None` ⇒ wrong/gone window or out-of-policy → reject
                // (capture stays put, epoch NOT advanced so a later valid request still wins).
                let Some((w, h)) = resolve_resize_size(self.window_id, desired) else {
                    return Vec::new();
                };
                self.last_resize_epoch = epoch;
                self.capture_width = w;
                self.capture_height = h;
                // Same session (same stream id, same window) — only the capture geometry changes.
                vec![Effect::ResizeCapture {
                    width: w,
                    height: h,
                    epoch,
                }]
            }
            // The host never receives a helloAck/resizeAck/streamCadence (all host→client) —
            // defensive no-op.
            VideoControlMessage::HelloAck { .. }
            | VideoControlMessage::ResizeAck { .. }
            | VideoControlMessage::StreamCadence { .. }
            // `keepalive` carries NO state-machine semantics — its only effect is the
            // transport-level `last_inbound` stamp the reaper reads. `focusWindow` is actioned at
            // the ACTOR level (it raises the captured window) and likewise has no SM/capture-state
            // effect. Both are defensive no-ops here.
            | VideoControlMessage::Keepalive
            | VideoControlMessage::FocusWindow
            // Window-list AND system-dialog-list discovery are answered at the DAEMON level
            // (session-less, no capture mint) and never reach a session's state machine.
            // `windowList`/`systemDialogList` are host→client and never arrive at the host at all.
            | VideoControlMessage::ListWindows
            | VideoControlMessage::WindowList(_)
            | VideoControlMessage::ListSystemDialogs
            | VideoControlMessage::SystemDialogList(_) => Vec::new(),
        }
    }

    /// `stop()` was called locally (closes the UDP sockets). Terminal: transitions to
    /// [`VideoSessionState::Stopped`] and tears down capture if it was streaming. A second stop
    /// is a no-op.
    pub fn stop(&mut self) -> Vec<Effect> {
        if self.state == VideoSessionState::Stopped {
            return Vec::new();
        }
        let was_streaming = self.state == VideoSessionState::Streaming;
        self.state = VideoSessionState::Stopped;
        if was_streaming {
            vec![Effect::StopCapture]
        } else {
            Vec::new()
        }
    }
}

/// The rejecting `helloAck` (accepted: false, zeroed dims, never full-range). Both reject sites
/// (wrong protocol version, `resolve_capture_size` → `None`) emit this exact message.
const fn reject_hello_ack(window_bounds_cg: VideoRect) -> VideoControlMessage {
    VideoControlMessage::HelloAck {
        accepted: false,
        stream_id: 0,
        capture_width: 0,
        capture_height: 0,
        window_bounds_cg,
        full_range: false,
    }
}

/// Pure host-side size negotiation for the in-session resize feature — the canonical
/// `SizeNegotiation`. The Swift shell's `SizeNegotiation` mirrors this.
///
/// Turns a client `resizeRequest`'s desired size into the `u16` capture dimensions the host
/// will adopt, clamped to the host's allowed `min`/`max` window size and rounded to a
/// `u16`-safe int that is NEVER zero (a zero-dimension SCStream/encoder config is invalid). No
/// `ScreenCaptureKit` / AX — exactly the discipline of [`VideoSessionStateMachine`], so the
/// clamp + epoch ordering are unit-testable in isolation. Modelled as a unit struct (the
/// caseless-enum namespace pattern: it is never instantiated).
pub struct SizeNegotiation;

impl SizeNegotiation {
    /// Clamps `desired` into `[min, max]` per axis and rounds to a `u16`-safe, non-zero
    /// integer. Identity (within rounding) when `desired` is already inside the bounds.
    ///
    /// Matches the actor's hello clamp (`u16(max(1, min(u16::MAX, v.round())))`) but bounded by
    /// the host's min/max policy rather than a single window size. The min is floored at 1 and
    /// the max ceilinged at `u16::MAX` so a degenerate (zero / out-of-range) policy can never
    /// yield 0 or overflow.
    #[must_use]
    pub fn clamp(desired: VideoSize, min_size: VideoSize, max_size: VideoSize) -> (u16, u16) {
        (
            Self::clamp_axis(desired.width, min_size.width, max_size.width),
            Self::clamp_axis(desired.height, min_size.height, max_size.height),
        )
    }

    /// One axis of [`clamp`](Self::clamp). Float op order + global-min/max NaN semantics are
    /// canonical (see [`swift_min`]/[`swift_max`]); the Swift shell matches these exactly.
    fn clamp_axis(value: f64, lo: f64, hi: f64) -> u16 {
        // Floor the lower bound at 1 and ceiling the upper at u16::MAX, then order them (a
        // swapped/degenerate policy must still clamp into a valid window).
        let lo_c = swift_max(1.0, swift_min(lo.round(), f64::from(u16::MAX)));
        let hi_c = swift_max(1.0, swift_min(hi.round(), f64::from(u16::MAX)));
        let lower = swift_min(lo_c, hi_c);
        let upper = swift_max(lo_c, hi_c);
        // NaN/non-finite desired collapses to the lower bound (never 0, never a trap).
        let v = if value.is_finite() {
            value.round()
        } else {
            lower
        };
        let clamped = swift_min(swift_max(v, lower), upper);
        // `clamped` is integer-valued and in [1, u16::MAX]; `as u16` truncates toward zero;
        // the Swift shell's `UInt16(Double)` does the same (no saturation triggered, no NaN).
        clamped as u16
    }

    /// Whether `epoch` is stale relative to the last APPLIED epoch — a value `<= last_applied`
    /// (a duplicate or out-of-order/older request) must be ignored so a UDP reorder/retransmit
    /// cannot un-settle the coalesced size. The first request of a session (any `epoch >= 1`
    /// against `last_applied == 0`) is therefore NOT stale.
    #[must_use]
    pub const fn is_stale_epoch(epoch: u32, last_applied: u32) -> bool {
        epoch <= last_applied
    }
}

/// `min(x, y) == { y < x ? y : x }` — propagates a NaN operand (unlike `f64::min`, which
/// returns the non-NaN operand and would diverge on hostile policy bounds). Finite inputs
/// agree with `f64::min`. The Swift shell does the same, so the two stay bit-identical.
#[inline]
const fn swift_min(x: f64, y: f64) -> f64 {
    if y < x {
        y
    } else {
        x
    }
}

/// `max(x, y) == { y >= x ? y : x }` — the NaN-faithful counterpart of `f64::max`
/// (see [`swift_min`]); the Swift shell does the same. Finite inputs agree with `f64::max`.
#[inline]
const fn swift_max(x: f64, y: f64) -> f64 {
    if y >= x {
        y
    } else {
        x
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        assert!(sm
            .handle_control(&stale, bounds(), accept_all, resolve_resize)
            .is_empty());
        let dup = VideoControlMessage::ResizeRequest {
            desired: VideoSize::new(640.0, 480.0),
            epoch: 5,
        };
        assert!(sm
            .handle_control(&dup, bounds(), accept_all, resolve_resize)
            .is_empty());
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
        assert!(sm
            .handle_control(&req, bounds(), accept_all, resolve_resize)
            .is_empty());
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
        assert!(sm
            .handle_control(&req, bounds(), accept_all, resolve_resize)
            .is_empty());
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
        assert!(sm
            .handle_control(&req, bounds(), accept_all, resolve_resize)
            .is_empty());
        assert_eq!(sm.state(), VideoSessionState::Stopped);
    }

    #[test]
    fn resize_for_wrong_window_rejected_by_resolver() {
        let mut sm = streaming_machine(7);
        // Resolver only accepts window id 99; session is window 42 → reject.
        let reject_resolver = |wid: u32, _d: VideoSize| -> Option<(u16, u16)> {
            if wid == 99 {
                Some((640, 480))
            } else {
                None
            }
        };
        let req = VideoControlMessage::ResizeRequest {
            desired: VideoSize::new(1280.0, 800.0),
            epoch: 1,
        };
        assert!(sm
            .handle_control(&req, bounds(), accept_all, reject_resolver)
            .is_empty());
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
        assert!(sm
            .handle_control(&dup, bounds(), accept_all, resolve_resize)
            .is_empty());
        assert_eq!(sm.capture_width(), 1280);
    }
}
