//! The `VideoMuxRouter` behaviour: admit / retire / drain / route / bootstrap, plus the
//! retired-set bound constants. The data carriers (`VideoChannel`, `Decision`,
//! `BootstrapAction`, `VideoMuxRouter`) live in the module root.

use super::{BootstrapAction, Decision, VideoChannel, VideoMuxRouter};
use crate::seq::distance_wrapped;

impl VideoMuxRouter {
    /// FIX #4: cap the `retired` set at 512 entries. The Swift shell's `retiredCap` mirrors this.
    pub const RETIRED_CAP: usize = 512;
    /// FIX #4: prune the `retired` set to within 256 of the wrap-aware high-water mark
    /// (the Swift shell's `retiredPruneWindow` mirrors this). An [`i32`] to compare directly
    /// against the signed [`distance_wrapped`] result.
    pub const RETIRED_PRUNE_WINDOW: i32 = 256;
    /// The default for the `payload_is_list_request` argument of [`bootstrap_action`]; matches
    /// the Swift shell's `payloadIsListRequest: Bool = false` default argument.
    ///
    /// [`bootstrap_action`]: VideoMuxRouter::bootstrap_action
    pub const BOOTSTRAP_PAYLOAD_IS_LIST_REQUEST_DEFAULT: bool = false;

    /// Builds an empty router. The Swift shell's `VideoMuxRouter()` mirrors this.
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
        if self.retired.len() > Self::RETIRED_CAP
            && let Some(high) = self.highest_retired
        {
            self.retired
                .retain(|&id| distance_wrapped(high, id) <= Self::RETIRED_PRUNE_WINDOW);
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

    /// [`bootstrap_action`](Self::bootstrap_action) with the Swift shell default
    /// `payload_is_list_request: false`, matching the 3-argument Swift shell call sites.
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
