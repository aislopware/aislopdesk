//! Pure per-datagram mux routing for the HOST side of the GUI video path (PATH 2).
//!
//! The canonical `VideoMuxRouter` logic. The native Swift shell keeps copies in
//! `Sources/AislopdeskVideoHost/Mux/VideoMuxRouter.swift` (with [`VideoChannel`] in
//! `Sources/AislopdeskVideoHost/VideoDatagramTransport.swift`) that track this (golden parity).
//!
//! When several remote-window sessions share one host UDP socket, each datagram is fronted
//! by a `u32` `channel_id` (see [`crate::mux_header`]). This router decides which session a
//! freshly-arrived datagram belongs to — purely from the `channel_id` it is told plus the
//! admitted/retired/draining bookkeeping it holds. It owns NO sockets and NO session
//! objects: it returns a [`Decision`] and lets the IO layer act. This is the headlessly
//! unit-testable discipline of `InputDatagramRouter` / `VideoSessionStateMachine`.
//!
//! ## Reconnect-generation safety
//!
//! A reconnecting client is admitted under a NEW `channel_id` (the prior one is
//! [`retire`](VideoMuxRouter::retire)d). In-flight datagrams that were already on the wire
//! for the OLD `channel_id` must be DROPPED, not misrouted to the new session — otherwise a
//! stale frame/input from the previous generation would leak into the fresh one. The router
//! therefore keeps a *retired* set distinct from a *never-seen* `channel_id`: a retired id is
//! dropped with [`Decision::DropRetired`] (a known, benign drop), while a genuinely unknown
//! id is [`Decision::RejectUnadmitted`].
//!
//! ## The retired-set bound (FIX #4)
//!
//! The client allocator is monotonic, so a retired id is otherwise never re-admitted ⇒ one
//! entry per pane/reconnect would leak for the daemon lifetime. The set is bounded exactly
//! like `FrameReassembler` bounds its retired frame ids — capped at
//! [`RETIRED_CAP`](VideoMuxRouter::RETIRED_CAP), pruned to within
//! [`RETIRED_PRUNE_WINDOW`](VideoMuxRouter::RETIRED_PRUNE_WINDOW) of the wrap-aware
//! high-water mark (via [`crate::seq::distance_wrapped`]). An id far BELOW the high-water mark
//! can have no in-flight datagram left, so dropping it from the set is safe — it falls back to
//! [`Decision::RejectUnadmitted`] and, with FIX #2, a fresh hello still re-admits it cleanly.
//!
//! ## The draining state (FIX #4b)
//!
//! A lane being torn down by the reaper is [`begin_drain`](VideoMuxRouter::begin_drain)-ed:
//! it stops routing and EVERY datagram (incl. a hello) drops via [`Decision::DropDraining`]
//! until [`end_drain`](VideoMuxRouter::end_drain) transitions it draining → retired. This
//! keeps a reconnect that races the async `session.stop()` from being delivered to the dying
//! session's still-registered sink (a false accept) or prematurely re-minted.

use std::collections::BTreeSet;

mod router;
#[cfg(test)]
mod tests;

/// The logical sub-streams that share one PATH 2 UDP session (doc 17 §3.3/§3.6/§3.8).
///
/// Canonical `VideoChannel` (raw `UInt8`, `CaseIterable`); the Swift shell mirrors it. The cursor channel is its own
/// UDP socket so video backpressure never delays the cursor; the router treats every channel
/// as an independent lane. The admit/retire decision is per-`channel_id`, NOT per-channel —
/// the channel is carried through purely for the IO layer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum VideoChannel {
    /// Session bring-up control (`VideoControlMessage`): hello / helloAck / bye.
    Control = 0,
    /// Encoded video fragments (`FrameFragment`).
    Video = 1,
    /// Window move/resize/title (`WindowGeometryMessage`).
    Geometry = 2,
    /// Cursor position + shape (`CursorChannelMessage`) — its own socket.
    Cursor = 3,
    /// Client → host input (`InputEvent`) — received, not sent, by the host.
    Input = 4,
    /// Client → host loss recovery (`RecoveryMessage`) — a dedicated channel (its leading
    /// type bytes overlap `InputEvent`'s, so it must not be multiplexed onto `.input`).
    Recovery = 5,
}

impl VideoChannel {
    /// Every channel in declaration order. The Swift shell's `CaseIterable.allCases` mirrors this.
    pub const ALL: [Self; 6] = [
        Self::Control,
        Self::Video,
        Self::Geometry,
        Self::Cursor,
        Self::Input,
        Self::Recovery,
    ];

    /// The wire tag byte. The Swift shell's `rawValue` mirrors this.
    #[must_use]
    pub const fn raw_value(self) -> u8 {
        self as u8
    }

    /// Decodes a wire tag byte back to a channel, or `None` for an out-of-range tag. The Swift
    /// shell's `VideoChannel(rawValue:)` mirrors this.
    #[must_use]
    pub const fn from_raw(raw: u8) -> Option<Self> {
        match raw {
            0 => Some(Self::Control),
            1 => Some(Self::Video),
            2 => Some(Self::Geometry),
            3 => Some(Self::Cursor),
            4 => Some(Self::Input),
            5 => Some(Self::Recovery),
            _ => None,
        }
    }
}

/// The decision for one received muxed datagram. The Swift shell's `VideoMuxRouter.Decision`
/// mirrors this. A closed enum the IO layer acts on; a single bad packet is never a fatal condition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// Route the datagram to the session bound to `channel_id`.
    Route {
        /// The lane the datagram routes to.
        channel_id: u32,
    },
    /// The `channel_id` was never admitted (an unknown / stray lane) — reject it.
    RejectUnadmitted,
    /// The `channel_id` was retired by a reconnect/teardown — drop the in-flight datagram so a
    /// previous generation's bytes never reach the new session.
    DropRetired,
    /// The `channel_id` is mid-teardown (the reaper is stopping its session) — drop EVERY
    /// datagram (incl. a hello) until [`VideoMuxRouter::end_drain`] transitions it to retired.
    DropDraining,
    /// Drop for another reason (e.g. an empty/zero-byte datagram). `reason` is a short
    /// human-readable explanation (never a fatal condition). The Swift shell's `.drop(reason:)` mirrors this.
    Drop {
        /// Human-readable reason the datagram was dropped.
        reason: String,
    },
}

/// What the transport's bootstrap arm should do with a NOT-yet-admitted datagram. The Swift
/// shell's `VideoMuxRouter.BootstrapAction` mirrors this.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BootstrapAction {
    /// Remember the lane's reply flow and deliver the datagram to the registry (it mints/admits).
    BootstrapDeliver,
    /// Drop without touching any flow bookkeeping (stray/retired non-hello, or non-control).
    DropNoStamp,
}

/// PURE per-datagram mux router for the HOST side of the GUI video path (PATH 2).
///
/// The canonical `VideoMuxRouter`. Uses [`BTreeSet`] for the lane sets so iteration/pruning is
/// deterministic (Swift's `Set` membership result is order-independent, so the observable
/// behaviour is identical). The Swift shell's `VideoMuxRouter` mirrors this.
#[derive(Debug, Clone, Default)]
pub struct VideoMuxRouter {
    /// Currently-admitted lanes (one per live session). Routable for data.
    pub(crate) admitted: BTreeSet<u32>,
    /// Lanes retired by a reconnect/teardown. Their in-flight datagrams are dropped.
    pub(crate) retired: BTreeSet<u32>,
    /// The highest `channel_id` ever retired (wrap-aware high-water mark), used to prune the
    /// retired set of ids too far below it to ever still have an in-flight datagram.
    pub(crate) highest_retired: Option<u32>,
    /// Lanes mid-teardown by the reaper: `begin_drain`-ed, awaiting `session.stop()`, not yet
    /// retired. While draining, EVERY datagram drops.
    pub(crate) draining: BTreeSet<u32>,
}
