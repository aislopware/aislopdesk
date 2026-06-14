//! Pure per-datagram mux routing for the HOST side of the GUI video path (PATH 2).
//!
//! A
//! port of Swift `Sources/AislopdeskVideoHost/Mux/VideoMuxRouter.swift` (the
//! [`VideoChannel`] enum is ported from
//! `Sources/AislopdeskVideoHost/VideoDatagramTransport.swift`).
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

use crate::seq::distance_wrapped;
use std::collections::BTreeSet;

/// The logical sub-streams that share one PATH 2 UDP session (doc 17 §3.3/§3.6/§3.8).
///
/// A
/// port of Swift `VideoChannel` (raw `UInt8`, `CaseIterable`). The cursor channel is its own
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
    /// Every channel in declaration order (mirrors Swift `CaseIterable.allCases`).
    pub const ALL: [Self; 6] = [
        Self::Control,
        Self::Video,
        Self::Geometry,
        Self::Cursor,
        Self::Input,
        Self::Recovery,
    ];

    /// The wire tag byte (mirrors Swift `rawValue`).
    #[must_use]
    pub const fn raw_value(self) -> u8 {
        self as u8
    }

    /// Decodes a wire tag byte back to a channel, or `None` for an out-of-range tag (mirrors
    /// Swift `VideoChannel(rawValue:)`).
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

/// The decision for one received muxed datagram — a port of Swift `VideoMuxRouter.Decision`.
/// A closed enum the IO layer acts on; a single bad packet is never a fatal condition.
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
    /// human-readable explanation (never a fatal condition). Mirrors Swift `.drop(reason:)`.
    Drop {
        /// Human-readable reason the datagram was dropped.
        reason: String,
    },
}

/// What the transport's bootstrap arm should do with a NOT-yet-admitted datagram — a port of
/// Swift `VideoMuxRouter.BootstrapAction`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BootstrapAction {
    /// Remember the lane's reply flow and deliver the datagram to the registry (it mints/admits).
    BootstrapDeliver,
    /// Drop without touching any flow bookkeeping (stray/retired non-hello, or non-control).
    DropNoStamp,
}

/// PURE per-datagram mux router for the HOST side of the GUI video path (PATH 2).
///
/// A port of
/// Swift `VideoMuxRouter`. Uses [`BTreeSet`] for the lane sets so iteration/pruning is
/// deterministic (the Swift `Set` membership result is order-independent, so the observable
/// behaviour is identical).
#[derive(Debug, Clone, Default)]
pub struct VideoMuxRouter {
    /// Currently-admitted lanes (one per live session). Routable for data.
    admitted: BTreeSet<u32>,
    /// Lanes retired by a reconnect/teardown. Their in-flight datagrams are dropped.
    retired: BTreeSet<u32>,
    /// The highest `channel_id` ever retired (wrap-aware high-water mark), used to prune the
    /// retired set of ids too far below it to ever still have an in-flight datagram.
    highest_retired: Option<u32>,
    /// Lanes mid-teardown by the reaper: `begin_drain`-ed, awaiting `session.stop()`, not yet
    /// retired. While draining, EVERY datagram drops.
    draining: BTreeSet<u32>,
}

impl VideoMuxRouter {
    /// FIX #4: cap the `retired` set at 512 entries (mirrors Swift `retiredCap`).
    pub const RETIRED_CAP: usize = 512;
    /// FIX #4: prune the `retired` set to within 256 of the wrap-aware high-water mark
    /// (mirrors Swift `retiredPruneWindow`). An [`i32`] to compare directly against the signed
    /// [`distance_wrapped`] result.
    pub const RETIRED_PRUNE_WINDOW: i32 = 256;
    /// The default for the `payload_is_list_request` argument of [`bootstrap_action`] — mirrors
    /// the Swift `payloadIsListRequest: Bool = false` default argument.
    ///
    /// [`bootstrap_action`]: VideoMuxRouter::bootstrap_action
    pub const BOOTSTRAP_PAYLOAD_IS_LIST_REQUEST_DEFAULT: bool = false;

    /// Builds an empty router (mirrors Swift's `VideoMuxRouter()`).
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Admits `channel_id` as a live lane. Idempotent. Admitting a previously-retired id clears
    /// its retired mark (a fresh generation may legitimately reuse an id) and clears any draining
    /// mark.
    pub fn admit(&mut self, channel_id: u32) {
        self.admitted.insert(channel_id);
        self.retired.remove(&channel_id);
        self.draining.remove(&channel_id);
    }

    /// Retires `channel_id` (reconnect/teardown): it stops being admitted and any further
    /// in-flight datagram for it is dropped via [`Decision::DropRetired`]. Updates the wrap-aware
    /// high-water mark, then bounds the retired set (FIX #4).
    pub fn retire(&mut self, channel_id: u32) {
        self.admitted.remove(&channel_id);
        self.retired.insert(channel_id);
        // Track the wrap-aware high-water mark (a fresh id with no prior mark, or one strictly
        // ahead of the current mark, advances it), then bound the set (FIX #4).
        if self
            .highest_retired
            .is_none_or(|high| distance_wrapped(channel_id, high) > 0)
        {
            self.highest_retired = Some(channel_id);
        }
        if self.retired.len() > Self::RETIRED_CAP {
            if let Some(high) = self.highest_retired {
                self.retired
                    .retain(|&id| distance_wrapped(high, id) <= Self::RETIRED_PRUNE_WINDOW);
            }
        }
    }

    /// Begin tearing a lane down on the reaper path: stop routing it and HOLD it (draining) so a
    /// reconnect racing the async `session.stop()` drops cleanly. Pair with [`end_drain`].
    ///
    /// [`end_drain`]: VideoMuxRouter::end_drain
    pub fn begin_drain(&mut self, channel_id: u32) {
        self.admitted.remove(&channel_id);
        self.draining.insert(channel_id);
    }

    /// Finish a reaper teardown: the session is stopped, so move the lane draining → retired
    /// (where a fresh hello may now re-admit it, FIX #2). Idempotent if the lane was not draining.
    pub fn end_drain(&mut self, channel_id: u32) {
        self.draining.remove(&channel_id);
        self.retire(channel_id);
    }

    /// Whether `channel_id` is currently an admitted (routable) lane.
    #[must_use]
    pub fn is_admitted(&self, channel_id: u32) -> bool {
        self.admitted.contains(&channel_id)
    }

    /// Whether `channel_id` is currently draining (reaper teardown in flight).
    #[must_use]
    pub fn is_draining(&self, channel_id: u32) -> bool {
        self.draining.contains(&channel_id)
    }

    /// Decides what to do with one received datagram on `channel` carrying `channel_id`.
    ///
    /// * `channel_id` — the lane the datagram is fronted with (from [`crate::mux_header`]).
    /// * `channel` — the logical sub-stream the datagram arrived on. Carried through for the IO
    ///   layer; the admit/retire decision is per-`channel_id`, not per-channel.
    /// * `bytes_count` — the datagram's byte length (an empty datagram is dropped, and this check
    ///   takes precedence over admitted/draining/retired state).
    #[must_use]
    pub fn route(&self, channel_id: u32, channel: VideoChannel, bytes_count: usize) -> Decision {
        let _ = channel;
        if bytes_count == 0 {
            return Decision::Drop {
                reason: "empty datagram".to_string(),
            };
        }
        if self.admitted.contains(&channel_id) {
            return Decision::Route { channel_id };
        }
        if self.draining.contains(&channel_id) {
            return Decision::DropDraining;
        }
        if self.retired.contains(&channel_id) {
            return Decision::DropRetired;
        }
        Decision::RejectUnadmitted
    }

    /// What the transport's bootstrap arm should do with a NOT-yet-admitted datagram (the lane is
    /// unadmitted OR retired), given the router's `decision`, the channel it arrived on, whether
    /// its payload decoded as a `hello`, and whether it is a window-LIST request. PURE — the
    /// hello/list peek is done once by the caller and passed in.
    ///
    /// * FIX #2: a RETIRED `channel_id` re-admits ONLY when its `.control` datagram is an actual
    ///   hello (cross-process id reuse after a client restart). A non-hello for a retired id
    ///   still drops (reconnect-generation safety).
    /// * FIX #6: an UNADMITTED lane bootstraps (and the transport stamps its reply flow) ONLY when
    ///   its first `.control` datagram is a hello — a stray/adversarial non-hello control datagram
    ///   drops WITHOUT remembering its flow.
    /// * docs/31 picker: a `payload_is_list_request` on `.control` bootstraps exactly like a hello
    ///   (the daemon answers it session-lessly) for an unadmitted OR retired lane.
    #[must_use]
    pub fn bootstrap_action(
        decision: &Decision,
        channel: VideoChannel,
        payload_is_hello: bool,
        payload_is_list_request: bool,
    ) -> BootstrapAction {
        match decision {
            Decision::RejectUnadmitted | Decision::DropRetired => {
                let is_bootstrap_control = channel == VideoChannel::Control
                    && (payload_is_hello || payload_is_list_request);
                if is_bootstrap_control {
                    BootstrapAction::BootstrapDeliver
                } else {
                    BootstrapAction::DropNoStamp
                }
            }
            // A draining lane is mid-teardown — drop EVEN a hello. `.route` is the live path;
            // `.drop` (empty datagram) never bootstraps.
            Decision::DropDraining | Decision::Route { .. } | Decision::Drop { .. } => {
                BootstrapAction::DropNoStamp
            }
        }
    }

    /// [`bootstrap_action`](Self::bootstrap_action) with the Swift default
    /// `payload_is_list_request: false` — mirrors the 3-argument Swift call sites.
    #[must_use]
    pub fn bootstrap_action_default(
        decision: &Decision,
        channel: VideoChannel,
        payload_is_hello: bool,
    ) -> BootstrapAction {
        Self::bootstrap_action(
            decision,
            channel,
            payload_is_hello,
            Self::BOOTSTRAP_PAYLOAD_IS_LIST_REQUEST_DEFAULT,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{BTreeMap, BTreeSet};

    // ---------------------------------------------------------------------------------------
    // Mirror of VideoMuxRouterTests.swift (pure admit / retire / route).
    // ---------------------------------------------------------------------------------------

    #[test]
    fn route_admitted_channel_id() {
        let mut router = VideoMuxRouter::new();
        router.admit(11);
        assert_eq!(
            router.route(11, VideoChannel::Video, 1200),
            Decision::Route { channel_id: 11 }
        );
        assert!(router.is_admitted(11));
    }

    #[test]
    fn unadmitted_channel_id_is_rejected() {
        let router = VideoMuxRouter::new();
        assert_eq!(
            router.route(99, VideoChannel::Control, 4),
            Decision::RejectUnadmitted
        );
        assert!(!router.is_admitted(99));
    }

    #[test]
    fn retired_channel_id_is_dropped() {
        // Reconnect-generation case: an admitted-then-retired id must DROP its in-flight
        // datagrams (not reject, not route).
        let mut router = VideoMuxRouter::new();
        router.admit(7);
        router.retire(7);
        assert_eq!(
            router.route(7, VideoChannel::Video, 1200),
            Decision::DropRetired
        );
        assert!(!router.is_admitted(7));
    }

    #[test]
    fn reconnect_admits_new_channel_id_while_old_stays_retired() {
        let mut router = VideoMuxRouter::new();
        router.admit(7);
        router.retire(7);
        router.admit(9); // fresh generation
        assert_eq!(
            router.route(9, VideoChannel::Video, 1200),
            Decision::Route { channel_id: 9 }
        );
        assert_eq!(
            router.route(7, VideoChannel::Video, 1200),
            Decision::DropRetired
        );
    }

    #[test]
    fn two_channel_ids_route_independently() {
        let mut router = VideoMuxRouter::new();
        router.admit(11);
        router.admit(13);
        assert_eq!(
            router.route(11, VideoChannel::Video, 800),
            Decision::Route { channel_id: 11 }
        );
        assert_eq!(
            router.route(13, VideoChannel::Cursor, 36),
            Decision::Route { channel_id: 13 }
        );
        router.retire(11);
        assert_eq!(
            router.route(11, VideoChannel::Video, 800),
            Decision::DropRetired
        );
        assert_eq!(
            router.route(13, VideoChannel::Cursor, 36),
            Decision::Route { channel_id: 13 }
        );
    }

    #[test]
    fn readmitting_retired_channel_id_clears_retired_mark() {
        let mut router = VideoMuxRouter::new();
        router.admit(5);
        router.retire(5);
        assert_eq!(
            router.route(5, VideoChannel::Video, 100),
            Decision::DropRetired
        );
        router.admit(5);
        assert_eq!(
            router.route(5, VideoChannel::Video, 100),
            Decision::Route { channel_id: 5 }
        );
    }

    #[test]
    fn empty_datagram_is_dropped() {
        let mut router = VideoMuxRouter::new();
        router.admit(3);
        assert!(matches!(
            router.route(3, VideoChannel::Video, 0),
            Decision::Drop { .. }
        ));
    }

    // ---------------------------------------------------------------------------------------
    // Mirror of VideoMuxRouterReadmitTests.swift (FIX #2 / #4 / #6 / #4b).
    // ---------------------------------------------------------------------------------------

    #[test]
    fn retired_set_is_bounded_and_prunes_far_below_high_water_mark() {
        let mut router = VideoMuxRouter::new();
        let count: u32 = 700; // > RETIRED_CAP (512)
        for id in 1..=count {
            router.retire(id);
        }

        let high = count;
        let pruned_far: u32 = 1; // 699 below high → far outside the window → pruned
        assert_eq!(
            router.route(pruned_far, VideoChannel::Video, 100),
            Decision::RejectUnadmitted,
            "an id far below the high-water mark is pruned from `retired`"
        );

        let kept_near: u32 = high - 10; // within 256 of high → retained
        assert_eq!(
            router.route(kept_near, VideoChannel::Video, 100),
            Decision::DropRetired,
            "an id within the prune window stays retired"
        );
    }

    #[test]
    fn retired_set_does_not_grow_unbounded() {
        let mut router = VideoMuxRouter::new();
        let high: u32 = 5000;
        for id in 1..=high {
            router.retire(id);
        }

        assert_eq!(
            router.route(high, VideoChannel::Video, 100),
            Decision::DropRetired
        );
        assert_eq!(
            router.route(high - 1, VideoChannel::Video, 100),
            Decision::DropRetired
        );
        assert_eq!(
            router.route(1, VideoChannel::Video, 100),
            Decision::RejectUnadmitted,
            "ancient retired ids are pruned; the set does not grow unbounded"
        );
        assert_eq!(
            router.route(high / 2, VideoChannel::Video, 100),
            Decision::RejectUnadmitted,
            "an id far below the high-water mark is pruned"
        );
    }

    #[test]
    fn retired_lane_readmits_only_on_hello() {
        assert_eq!(
            VideoMuxRouter::bootstrap_action_default(
                &Decision::DropRetired,
                VideoChannel::Control,
                true
            ),
            BootstrapAction::BootstrapDeliver,
            "a retired lane re-admits on an explicit hello"
        );
        assert_eq!(
            VideoMuxRouter::bootstrap_action_default(
                &Decision::DropRetired,
                VideoChannel::Control,
                false
            ),
            BootstrapAction::DropNoStamp,
            "a retired lane drops a non-hello control datagram (stale old-gen)"
        );
        assert_eq!(
            VideoMuxRouter::bootstrap_action_default(
                &Decision::DropRetired,
                VideoChannel::Video,
                false
            ),
            BootstrapAction::DropNoStamp,
            "a retired lane drops in-flight video (reconnect-generation safety)"
        );
    }

    #[test]
    fn unadmitted_lane_bootstraps_only_on_hello() {
        assert_eq!(
            VideoMuxRouter::bootstrap_action_default(
                &Decision::RejectUnadmitted,
                VideoChannel::Control,
                true
            ),
            BootstrapAction::BootstrapDeliver,
            "the first hello bootstraps an unadmitted lane"
        );
        assert_eq!(
            VideoMuxRouter::bootstrap_action_default(
                &Decision::RejectUnadmitted,
                VideoChannel::Control,
                false
            ),
            BootstrapAction::DropNoStamp,
            "a stray non-hello control datagram drops without remembering its flow"
        );
        assert_eq!(
            VideoMuxRouter::bootstrap_action_default(
                &Decision::RejectUnadmitted,
                VideoChannel::Input,
                false
            ),
            BootstrapAction::DropNoStamp,
            "a stray non-control datagram for an unknown lane drops"
        );
    }

    #[test]
    fn list_request_bootstraps_like_hello_on_control_only() {
        assert_eq!(
            VideoMuxRouter::bootstrap_action(
                &Decision::RejectUnadmitted,
                VideoChannel::Control,
                false,
                true
            ),
            BootstrapAction::BootstrapDeliver,
            "a listWindows request bootstraps an unadmitted lane (session-less reply)"
        );
        assert_eq!(
            VideoMuxRouter::bootstrap_action(
                &Decision::DropRetired,
                VideoChannel::Control,
                false,
                true
            ),
            BootstrapAction::BootstrapDeliver,
            "a listWindows request bootstraps a retired lane too (cross-process reuse)"
        );
        assert_eq!(
            VideoMuxRouter::bootstrap_action(
                &Decision::RejectUnadmitted,
                VideoChannel::Video,
                false,
                true
            ),
            BootstrapAction::DropNoStamp,
            "a list request off the control channel drops (only .control bootstraps)"
        );
        assert_eq!(
            VideoMuxRouter::bootstrap_action(
                &Decision::DropDraining,
                VideoChannel::Control,
                false,
                true
            ),
            BootstrapAction::DropNoStamp,
            "a list request racing a teardown drops like a hello does"
        );
    }

    #[test]
    fn routed_and_empty_decisions_never_bootstrap() {
        assert_eq!(
            VideoMuxRouter::bootstrap_action_default(
                &Decision::Route { channel_id: 5 },
                VideoChannel::Control,
                true
            ),
            BootstrapAction::DropNoStamp
        );
        assert_eq!(
            VideoMuxRouter::bootstrap_action_default(
                &Decision::Drop {
                    reason: "empty datagram".to_string()
                },
                VideoChannel::Control,
                true
            ),
            BootstrapAction::DropNoStamp
        );
    }

    #[test]
    fn draining_lane_drops_everything_including_hello() {
        let mut router = VideoMuxRouter::new();
        router.admit(1);
        router.begin_drain(1);
        assert!(router.is_draining(1));
        assert!(!router.is_admitted(1), "begin_drain stops routing the lane");
        assert_eq!(
            router.route(1, VideoChannel::Video, 100),
            Decision::DropDraining
        );
        let hello_while_draining = router.route(1, VideoChannel::Control, 8);
        assert_eq!(hello_while_draining, Decision::DropDraining);
        assert_eq!(
            VideoMuxRouter::bootstrap_action_default(
                &hello_while_draining,
                VideoChannel::Control,
                true
            ),
            BootstrapAction::DropNoStamp,
            "a hello racing the teardown drops — no false accept, no premature re-mint"
        );
    }

    #[test]
    fn end_drain_transitions_to_retired_then_hello_readmits() {
        let mut router = VideoMuxRouter::new();
        router.admit(2);
        router.begin_drain(2);
        router.end_drain(2);
        assert!(!router.is_draining(2));
        assert_eq!(
            router.route(2, VideoChannel::Video, 100),
            Decision::DropRetired,
            "after end_drain the lane is retired (stale old-gen still drops)"
        );
        let hello = router.route(2, VideoChannel::Control, 8);
        assert_eq!(
            VideoMuxRouter::bootstrap_action_default(&hello, VideoChannel::Control, true),
            BootstrapAction::BootstrapDeliver,
            "a fresh hello after end_drain re-admits the lane"
        );
        router.admit(2);
        assert_eq!(
            router.route(2, VideoChannel::Video, 100),
            Decision::Route { channel_id: 2 }
        );
    }

    #[test]
    fn hello_readmit_clears_retired_mark_end_to_end() {
        let mut router = VideoMuxRouter::new();
        router.admit(1);
        router.retire(1);
        assert_eq!(
            router.route(1, VideoChannel::Video, 100),
            Decision::DropRetired
        );

        let hello_decision = router.route(1, VideoChannel::Control, 8);
        assert_eq!(
            hello_decision,
            Decision::DropRetired,
            "the router still reports retired until admit runs"
        );
        assert_eq!(
            VideoMuxRouter::bootstrap_action_default(&hello_decision, VideoChannel::Control, true),
            BootstrapAction::BootstrapDeliver
        );
        router.admit(1); // what the mint path does on session.start
        assert_eq!(
            router.route(1, VideoChannel::Video, 100),
            Decision::Route { channel_id: 1 },
            "after re-admission the reused id routes again — reconnect unblocked"
        );
    }

    // ---------------------------------------------------------------------------------------
    // Mirror of VideoMuxDatagramRoutingTests.swift — the router-decision + per-lane-sink
    // pipeline. The Swift harness frames via VideoMuxHeaderCodec and delivers through a
    // VideoMuxSinkTable; those host-side types are out of this module's scope, so this
    // harness reconstructs only the router decision + a sink registry keyed by channel_id.
    // The OLD bootstrap rule (deliver ANY control on an unadmitted lane) is preserved.
    // ---------------------------------------------------------------------------------------

    struct DatagramHarness {
        router: VideoMuxRouter,
        sinks: BTreeSet<u32>,
        received: BTreeMap<u32, Vec<(VideoChannel, Vec<u8>)>>,
    }

    impl DatagramHarness {
        fn new() -> Self {
            Self {
                router: VideoMuxRouter::new(),
                sinks: BTreeSet::new(),
                received: BTreeMap::new(),
            }
        }

        fn open_lane(&mut self, channel_id: u32) {
            self.router.admit(channel_id);
            self.sinks.insert(channel_id);
        }

        fn register_recording_sink(&mut self, channel_id: u32) {
            self.sinks.insert(channel_id);
        }

        fn retire_lane(&mut self, channel_id: u32) {
            self.router.retire(channel_id);
            self.sinks.remove(&channel_id);
        }

        fn feed_media(
            &mut self,
            channel_id: u32,
            channel: VideoChannel,
            payload: &[u8],
        ) -> Decision {
            // A framed datagram is always non-empty (header + tag + payload), mirror with +2.
            let bytes_count = payload.len() + 2;
            let decision = self.router.route(channel_id, channel, bytes_count);
            let deliver = match decision {
                Decision::Route { .. } => true,
                Decision::RejectUnadmitted => channel == VideoChannel::Control, // bootstrap: first hello
                Decision::DropRetired | Decision::DropDraining | Decision::Drop { .. } => false,
            };
            if deliver && self.sinks.contains(&channel_id) {
                self.received
                    .entry(channel_id)
                    .or_default()
                    .push((channel, payload.to_vec()));
            }
            decision
        }

        fn count(&self, channel_id: u32) -> usize {
            self.received.get(&channel_id).map_or(0, Vec::len)
        }

        fn payloads(&self, channel_id: u32) -> Vec<Vec<u8>> {
            self.received
                .get(&channel_id)
                .map(|v| v.iter().map(|(_, p)| p.clone()).collect())
                .unwrap_or_default()
        }
    }

    #[test]
    fn n_channels_route_to_their_own_sink() {
        let mut h = DatagramHarness::new();
        h.open_lane(10);
        h.open_lane(20);
        h.open_lane(30);

        h.feed_media(10, VideoChannel::Video, &[0x0A]);
        h.feed_media(20, VideoChannel::Video, &[0x14]);
        h.feed_media(30, VideoChannel::Control, &[0x1E]);
        h.feed_media(10, VideoChannel::Input, &[0x0B]);

        assert_eq!(h.payloads(10), vec![vec![0x0A], vec![0x0B]]);
        assert_eq!(h.payloads(20), vec![vec![0x14]]);
        assert_eq!(h.payloads(30), vec![vec![0x1E]]);
    }

    #[test]
    fn unadmitted_channel_id_is_dropped_never_delivered() {
        let mut h = DatagramHarness::new();
        h.open_lane(10);
        let decision = h.feed_media(99, VideoChannel::Video, &[0xFF]);
        assert_eq!(decision, Decision::RejectUnadmitted);
        assert_eq!(h.count(99), 0);
        assert_eq!(
            h.count(10),
            0,
            "an unknown lane never touches a sibling sink"
        );
    }

    #[test]
    fn retiring_one_lane_keeps_siblings_streaming() {
        let mut h = DatagramHarness::new();
        h.open_lane(10);
        h.open_lane(20);
        h.feed_media(10, VideoChannel::Video, &[0x01]);
        h.retire_lane(10);

        assert_eq!(
            h.feed_media(10, VideoChannel::Video, &[0x02]),
            Decision::DropRetired
        );
        assert_eq!(
            h.count(10),
            1,
            "retired lane stops receiving (only the pre-bye datagram landed)"
        );

        h.feed_media(20, VideoChannel::Video, &[0x03]);
        assert_eq!(h.payloads(20), vec![vec![0x03]]);
    }

    #[test]
    fn first_hello_on_unadmitted_lane_bootstraps_through_to_the_registry() {
        let mut h = DatagramHarness::new();
        h.register_recording_sink(5);
        // The DatagramRouting harness delivers ANY control datagram on an unadmitted lane (the
        // pre-FIX-6 rule); the actual hello bytes are immaterial to its decision.
        let control_decision = h.feed_media(5, VideoChannel::Control, &[0x01, 0x02, 0x03]);
        let video_decision = h.feed_media(5, VideoChannel::Video, &[0x01]);
        assert_eq!(
            control_decision,
            Decision::RejectUnadmitted,
            "router still reports unadmitted..."
        );
        assert_eq!(video_decision, Decision::RejectUnadmitted);
        assert_eq!(
            h.count(5),
            1,
            "...but the CONTROL (hello) is delivered for mint; the video is not"
        );
    }

    #[test]
    fn reconnect_admits_fresh_lane_while_old_stale_frames_drop() {
        let mut h = DatagramHarness::new();
        h.open_lane(7);
        h.retire_lane(7); // client went away
        h.open_lane(9); // reconnect under a fresh lane
        assert_eq!(
            h.feed_media(9, VideoChannel::Video, &[0x09]),
            Decision::Route { channel_id: 9 }
        );
        assert_eq!(
            h.feed_media(7, VideoChannel::Video, &[0x07]),
            Decision::DropRetired
        );
        assert_eq!(h.payloads(9), vec![vec![0x09]]);
        assert_eq!(h.count(7), 0);
    }

    // ---------------------------------------------------------------------------------------
    // Mirror of VideoMuxReadmitRoutingTests.swift — the FIX #2/#6 deliver+stamp pipeline.
    // The Swift harness decodes a VideoControlMessage to peek `hello`; that codec is out of
    // this module's scope, so this harness takes the already-decoded `is_hello` boolean (the
    // exact pure input bootstrap_action consumes), and a `conn` id instead of an object identity.
    // ---------------------------------------------------------------------------------------

    struct ReadmitHarness {
        router: VideoMuxRouter,
        channel_media_conn: BTreeMap<u32, u32>,
        delivered: Vec<(u32, VideoChannel, Vec<u8>)>,
    }

    impl ReadmitHarness {
        fn new() -> Self {
            Self {
                router: VideoMuxRouter::new(),
                channel_media_conn: BTreeMap::new(),
                delivered: Vec::new(),
            }
        }

        fn feed(
            &mut self,
            channel_id: u32,
            channel: VideoChannel,
            payload: &[u8],
            conn: u32,
            is_hello: bool,
        ) -> bool {
            let bytes_count = payload.len() + 2; // framed datagram is always non-empty
            let decision = self.router.route(channel_id, channel, bytes_count);
            let deliver = match decision {
                Decision::Route { .. } => {
                    self.channel_media_conn.insert(channel_id, conn);
                    true
                }
                Decision::RejectUnadmitted | Decision::DropRetired => {
                    match VideoMuxRouter::bootstrap_action_default(&decision, channel, is_hello) {
                        BootstrapAction::BootstrapDeliver => {
                            self.channel_media_conn.insert(channel_id, conn);
                            true
                        }
                        BootstrapAction::DropNoStamp => false,
                    }
                }
                Decision::DropDraining | Decision::Drop { .. } => false,
            };
            if deliver {
                self.delivered.push((channel_id, channel, payload.to_vec()));
            }
            deliver
        }

        fn delivered_ids(&self) -> Vec<u32> {
            self.delivered.iter().map(|(id, _, _)| *id).collect()
        }
    }

    #[test]
    fn retired_lane_reconnects_on_hello_after_cross_process_reuse() {
        let mut h = ReadmitHarness::new();
        let (conn1, conn2) = (1_u32, 2_u32);

        assert!(h.feed(1, VideoChannel::Control, &[0xFF], conn1, true));
        h.router.admit(1); // mint path admits on session.start
        h.router.retire(1); // client gone

        assert!(!h.feed(1, VideoChannel::Video, &[0xAA], conn1, false));

        assert!(h.feed(1, VideoChannel::Control, &[0xFF], conn2, true));
        assert_eq!(
            h.channel_media_conn.get(&1),
            Some(&conn2),
            "the re-admit remembers the NEW reply flow"
        );
        h.router.admit(1); // session.start re-admits → clears retired
        assert!(
            h.feed(1, VideoChannel::Video, &[0xBB], conn2, false),
            "after re-admission the reused lane routes again — reconnect is no longer blocked"
        );
    }

    #[test]
    fn stray_non_hello_control_for_unknown_lane_never_stamps_flow() {
        let mut h = ReadmitHarness::new();
        assert!(!h.feed(999, VideoChannel::Control, &[0x01], 7, false));
        assert_eq!(
            h.channel_media_conn.get(&999),
            None,
            "a stray non-hello control datagram leaves no flow entry"
        );
        assert!(h.delivered_ids().is_empty());
    }

    #[test]
    fn stray_non_hello_control_for_retired_lane_never_stamps_flow() {
        let mut h = ReadmitHarness::new();
        h.router.admit(3);
        h.router.retire(3);
        assert!(!h.feed(3, VideoChannel::Control, &[0x01], 7, false));
        assert_eq!(
            h.channel_media_conn.get(&3),
            None,
            "a non-hello control datagram for a retired lane stamps no flow"
        );
    }

    #[test]
    fn first_hello_on_never_seen_lane_still_bootstraps() {
        let mut h = ReadmitHarness::new();
        assert!(h.feed(50, VideoChannel::Control, &[0xFF], 7, true));
        assert_eq!(h.channel_media_conn.get(&50), Some(&7));
        assert_eq!(h.delivered_ids(), vec![50]);
    }

    #[test]
    fn empty_control_payload_is_bounds_safe_and_drops() {
        // A 0-byte control payload (truncated/adversarial) cannot decode as a hello → is_hello
        // false → drop without stamping a flow. (The framed datagram still has a header, so
        // route does not see it as an empty datagram.)
        let mut h = ReadmitHarness::new();
        assert!(!h.feed(60, VideoChannel::Control, &[], 7, false));
        assert_eq!(
            h.channel_media_conn.get(&60),
            None,
            "an empty/truncated control datagram leaves no flow entry"
        );
        assert!(h.delivered_ids().is_empty());
    }

    // ---------------------------------------------------------------------------------------
    // Added edge cases.
    // ---------------------------------------------------------------------------------------

    #[test]
    fn video_channel_raw_values_match_swift() {
        assert_eq!(VideoChannel::Control.raw_value(), 0);
        assert_eq!(VideoChannel::Video.raw_value(), 1);
        assert_eq!(VideoChannel::Geometry.raw_value(), 2);
        assert_eq!(VideoChannel::Cursor.raw_value(), 3);
        assert_eq!(VideoChannel::Input.raw_value(), 4);
        assert_eq!(VideoChannel::Recovery.raw_value(), 5);
        assert_eq!(VideoChannel::ALL.len(), 6);
        for (i, &ch) in VideoChannel::ALL.iter().enumerate() {
            assert_eq!(ch.raw_value() as usize, i, "ALL is in declaration order");
            assert_eq!(VideoChannel::from_raw(ch.raw_value()), Some(ch));
        }
        assert_eq!(VideoChannel::from_raw(6), None);
        assert_eq!(VideoChannel::from_raw(255), None);
    }

    #[test]
    fn empty_datagram_drops_regardless_of_lane_state() {
        // The empty-datagram guard precedes the admitted/draining/retired checks.
        let mut router = VideoMuxRouter::new();
        router.admit(1);
        assert_eq!(
            router.route(1, VideoChannel::Video, 0),
            Decision::Drop {
                reason: "empty datagram".to_string()
            }
        );
        router.begin_drain(2);
        assert_eq!(
            router.route(2, VideoChannel::Video, 0),
            Decision::Drop {
                reason: "empty datagram".to_string()
            }
        );
        let mut r3 = VideoMuxRouter::new();
        r3.admit(3);
        r3.retire(3);
        assert_eq!(
            r3.route(3, VideoChannel::Video, 0),
            Decision::Drop {
                reason: "empty datagram".to_string()
            }
        );
        // A never-seen lane with a non-empty datagram is rejected, not dropped.
        assert_eq!(
            VideoMuxRouter::new().route(4, VideoChannel::Video, 1),
            Decision::RejectUnadmitted
        );
    }

    #[test]
    fn admit_while_draining_clears_draining_and_routes() {
        let mut router = VideoMuxRouter::new();
        router.begin_drain(1);
        assert!(router.is_draining(1));
        router.admit(1);
        assert!(router.is_admitted(1));
        assert!(!router.is_draining(1));
        assert_eq!(
            router.route(1, VideoChannel::Video, 100),
            Decision::Route { channel_id: 1 }
        );
    }

    #[test]
    fn end_drain_on_non_draining_lane_just_retires() {
        let mut router = VideoMuxRouter::new();
        router.end_drain(5); // never admitted nor draining
        assert!(!router.is_draining(5));
        assert_eq!(
            router.route(5, VideoChannel::Video, 100),
            Decision::DropRetired
        );
        // Idempotent.
        router.end_drain(5);
        assert_eq!(
            router.route(5, VideoChannel::Video, 100),
            Decision::DropRetired
        );
    }

    #[test]
    fn begin_drain_removes_admitted_and_drops_with_draining() {
        let mut router = VideoMuxRouter::new();
        router.admit(1);
        router.begin_drain(1);
        assert!(!router.is_admitted(1));
        assert!(router.is_draining(1));
        assert_eq!(
            router.route(1, VideoChannel::Control, 8),
            Decision::DropDraining
        );
    }

    #[test]
    fn prune_window_boundary_is_inclusive() {
        // Retire exactly RETIRED_CAP + 1 (513) ids so the prune fires once at the boundary.
        let mut router = VideoMuxRouter::new();
        for id in 1..=513u32 {
            router.retire(id);
        }
        // high == 513; the prune keeps ids within 256 of it (distance_wrapped(513, id) <= 256),
        // i.e. id >= 257.
        assert_eq!(
            router.route(257, VideoChannel::Video, 100),
            Decision::DropRetired,
            "distance 256 is inclusive — kept"
        );
        assert_eq!(
            router.route(513, VideoChannel::Video, 100),
            Decision::DropRetired
        );
        assert_eq!(
            router.route(256, VideoChannel::Video, 100),
            Decision::RejectUnadmitted,
            "distance 257 is outside the window — pruned"
        );
    }

    #[test]
    fn prune_uses_wrap_aware_high_water_mark() {
        // Retire a contiguous range that wraps past u32::MAX, exceeding the cap so the prune
        // fires. The high-water mark must follow the wrap (the small post-wrap id is "ahead"),
        // so the very first (pre-wrap) id is pruned while a recent id near the wrapped high stays.
        let mut router = VideoMuxRouter::new();
        let start = u32::MAX - 300; // 0xFFFF_FED3
        let first = start;
        for k in 0..=600u32 {
            router.retire(start.wrapping_add(k));
        }
        let high = start.wrapping_add(600); // == 299 after the wrap
        assert_eq!(high, 299);

        // A recent id one below the wrapped high-water mark is retained.
        assert_eq!(
            router.route(high - 1, VideoChannel::Video, 100),
            Decision::DropRetired,
            "an id just below the wrapped high-water mark stays retired"
        );
        // The very first (pre-wrap) id is ~600 behind the high-water mark → pruned.
        assert_eq!(
            router.route(first, VideoChannel::Video, 100),
            Decision::RejectUnadmitted,
            "the ancient pre-wrap id is pruned despite the u32 wrap"
        );
    }

    #[test]
    fn decision_equality_and_drop_reason() {
        assert_eq!(
            Decision::Route { channel_id: 5 },
            Decision::Route { channel_id: 5 }
        );
        assert_ne!(
            Decision::Route { channel_id: 5 },
            Decision::Route { channel_id: 6 }
        );
        assert_ne!(Decision::RejectUnadmitted, Decision::DropRetired);
        assert_ne!(Decision::DropRetired, Decision::DropDraining);
        assert_eq!(
            Decision::Drop {
                reason: "empty datagram".to_string()
            },
            Decision::Drop {
                reason: "empty datagram".to_string()
            }
        );
        assert_ne!(
            Decision::Drop {
                reason: "a".to_string()
            },
            Decision::Drop {
                reason: "b".to_string()
            }
        );
    }

    #[test]
    fn bootstrap_action_full_decision_matrix() {
        // Only RejectUnadmitted / DropRetired on .control with hello-or-list bootstrap.
        for decision in [Decision::RejectUnadmitted, Decision::DropRetired] {
            assert_eq!(
                VideoMuxRouter::bootstrap_action(&decision, VideoChannel::Control, true, false),
                BootstrapAction::BootstrapDeliver
            );
            assert_eq!(
                VideoMuxRouter::bootstrap_action(&decision, VideoChannel::Control, false, true),
                BootstrapAction::BootstrapDeliver
            );
            assert_eq!(
                VideoMuxRouter::bootstrap_action(&decision, VideoChannel::Control, false, false),
                BootstrapAction::DropNoStamp
            );
            // Off the control channel never bootstraps, even with hello + list both true.
            for ch in VideoChannel::ALL {
                if ch == VideoChannel::Control {
                    continue;
                }
                assert_eq!(
                    VideoMuxRouter::bootstrap_action(&decision, ch, true, true),
                    BootstrapAction::DropNoStamp
                );
            }
        }
        // The other three decisions never bootstrap, regardless of channel/flags.
        for decision in [
            Decision::DropDraining,
            Decision::Route { channel_id: 1 },
            Decision::Drop {
                reason: "empty datagram".to_string(),
            },
        ] {
            assert_eq!(
                VideoMuxRouter::bootstrap_action(&decision, VideoChannel::Control, true, true),
                BootstrapAction::DropNoStamp
            );
        }
    }

    #[test]
    fn admit_is_idempotent() {
        let mut router = VideoMuxRouter::new();
        router.admit(1);
        router.admit(1);
        assert!(router.is_admitted(1));
        assert_eq!(
            router.route(1, VideoChannel::Video, 100),
            Decision::Route { channel_id: 1 }
        );
    }
}
