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

use crate::video_control::VideoControlMessage;

mod size_negotiation;
mod state_machine;
#[cfg(test)]
mod tests;

pub use size_negotiation::*;
pub use state_machine::*;

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
