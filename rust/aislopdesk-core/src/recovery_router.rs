//! Pure routing decision for the DEDICATED recovery channel (client→host loss recovery, doc 17 §3.6).
//!
//! The canonical `RecoveryDatagramRouter` logic; the native Swift shell keeps a copy
//! (`Sources/AislopdeskVideoHost/VideoSessionLogic.swift`) that tracks this (golden parity).
//!
//! Decode the [`RecoveryMessage`] and decide the host action. Kept separate from the
//! input router because recovery and input share neither a channel nor a wire grammar —
//! `RecoveryMessage`'s leading type bytes (1/2/3) overlap `InputEvent`'s, which is
//! exactly why they must NOT share the input channel. Testable without an
//! encoder/capturer.
//!
//! ## The sentinel contract
//!
//! The decode-frontier carried by `requestIDR` / `requestLTRRefresh` is a `u32` whose
//! wire sentinel ([`RecoveryMessage::NO_FRAME_DECODED_SENTINEL`]) means "the client has
//! not decoded any frame yet". The router maps that sentinel to `None` so the actor's
//! delivery-keyed policy gets a clean [`Option`]; any other value passes through as
//! `Some`.

use crate::recovery::{NetworkStatsReport, RecoveryMessage};

/// The decision for one received recovery datagram.
///
/// The Swift shell's `RecoveryDatagramRouter.Decision` enum mirrors this 1:1.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// Force an IDR keyframe on the next captured frame. This is the GUARANTEED-recovery
    /// escalation (`requestIDR`): a true keyframe unconditionally re-anchors a desynced
    /// client. Kept distinct from [`Decision::RefreshLtr`] so the escalation can never
    /// degrade to an LTR refresh. Carries the client's decode frontier (`None` ⇔ the wire
    /// sentinel "nothing decoded yet") for the actor's delivery-keyed `RecoveryIDRPolicy`.
    ForceKeyframe {
        /// The client's highest successfully-decoded frame id, or `None` for the sentinel.
        last_decoded_frame_id: Option<u32>,
    },
    /// WF-8: the client requested an LTR refresh (`requestLTRRefresh`). The ACTOR decides
    /// at runtime — via `LTRController::recovery_decision` — whether to issue a cheap
    /// `ForceLTRRefresh` (only when the LTR gate is on AND a token has been acknowledged:
    /// the ACKED-ONLY invariant) or fall back to a real IDR. When LTR is off this folds to
    /// today's `requestLTRRefresh`→IDR behaviour. Carries the client's decode frontier like
    /// [`Decision::ForceKeyframe`] — consumed ONLY by the `.idr` fallback path (an LTR
    /// refresh is never policy-gated).
    RefreshLtr {
        /// The client's highest successfully-decoded frame id, or `None` for the sentinel.
        last_decoded_frame_id: Option<u32>,
    },
    /// A durable-receipt ack: the host may advance its retransmit/LTR-pin window. No live
    /// effect yet (no retransmit buffer); recorded for the docs/escalation.
    Ack {
        /// The acknowledged value (historically a `stream_seq`).
        stream_seq: u32,
    },
    /// Re-ship the cursor SHAPE bitmap for `shape_id` (FIX B self-heal): the client is
    /// missing it (its one-shot shape datagram was lost / over-MTU). The actor asks the
    /// cursor sampler to re-emit that shape on the cursor socket; the client cache
    /// re-insert is idempotent.
    ReshipCursorShape {
        /// The shape id the client is missing.
        shape_id: u16,
    },
    /// A periodic client network-feedback report (loss/FEC counters + host-send-ts echo +
    /// client hold + jitter). The actor folds it into its network estimate and logs —
    /// MAINTAIN+LOG only, no stream-behaviour change this phase.
    NetworkStats(NetworkStatsReport),
    /// NACK / selective ARQ: the client is missing specific DATA fragments of `frame_id` and asks
    /// the host to retransmit them. The actor looks each up by `(frame_id, frag_index)` in its
    /// send-history ring and re-enqueues the original datagrams on the send lane — cheaper than a
    /// full recovery-IDR, and it arrives inside the client's playout buffer (no stutter). A lookup
    /// miss (frame aged out of the ring) is a no-op; the client's Dropped→LTR-refresh path remains
    /// the fallback when the retransmit-grace expires.
    RetransmitFragments {
        /// The frame whose fragments are missing.
        frame_id: u32,
        /// The 0-based DATA-fragment indices to retransmit.
        frag_indices: Vec<u16>,
    },
    /// Drop a malformed/undecodable datagram (a corrupt single packet must never crash the
    /// receiver — same contract as the reassembler).
    Drop {
        /// Human-readable reason (diagnostics only; not part of any wire format).
        reason: String,
    },
    /// Ignore because the session is not streaming.
    IgnoreNotStreaming,
}

/// Routes a datagram received on the dedicated recovery channel. Stateless pure decision
/// logic — a zero-sized value type, exactly like the Swift shell's `struct`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RecoveryDatagramRouter;

impl RecoveryDatagramRouter {
    /// Builds a router. Stateless — the Swift shell's `init()` is API-equivalent.
    #[must_use]
    pub const fn new() -> Self {
        Self
    }

    /// Decides what to do with one raw recovery datagram.
    ///
    /// A non-streaming session ignores the datagram before any decode (the Swift shell's
    /// `guard mediaFlowing` matches this); an undecodable datagram drops; otherwise the decoded
    /// [`RecoveryMessage`] maps to its [`Decision`].
    #[must_use]
    // `route` is an instance method to match the Swift shell's `RecoveryDatagramRouter.route` (the actor
    // holds a `let router = RecoveryDatagramRouter()`); the type is a stateless namespace handle,
    // so `self` is intentionally unused.
    #[allow(clippy::unused_self)]
    pub fn route(self, datagram: &[u8], media_flowing: bool) -> Decision {
        if !media_flowing {
            return Decision::IgnoreNotStreaming;
        }
        let Ok(message) = RecoveryMessage::decode(datagram) else {
            return Decision::Drop {
                reason: "undecodable recovery datagram".to_string(),
            };
        };
        match message {
            // The guaranteed-recovery escalation: ALWAYS a real IDR (a keyframe
            // unconditionally re-anchors a client that lost frames). Never an LTR refresh.
            // The wire sentinel ("nothing decoded yet") maps to None so the actor's policy
            // gets a clean Optional.
            RecoveryMessage::RequestIdr {
                last_decoded_frame_id,
            } => Decision::ForceKeyframe {
                last_decoded_frame_id: decode_frontier(last_decoded_frame_id),
            },
            // WF-8: defer the LTR-refresh-vs-IDR choice to the actor (it owns the runtime
            // acked-token state + the LTR gate). With LTR off the actor folds this to a real
            // IDR — today's behaviour exactly. Same sentinel→None mapping as RequestIdr.
            RecoveryMessage::RequestLtrRefresh {
                last_decoded_frame_id,
                ..
            } => Decision::RefreshLtr {
                last_decoded_frame_id: decode_frontier(last_decoded_frame_id),
            },
            RecoveryMessage::Ack { stream_seq } => Decision::Ack { stream_seq },
            RecoveryMessage::RequestCursorShape { shape_id } => {
                Decision::ReshipCursorShape { shape_id }
            }
            RecoveryMessage::NetworkStats(report) => Decision::NetworkStats(report),
            RecoveryMessage::RequestFragments {
                frame_id,
                frag_indices,
            } => Decision::RetransmitFragments {
                frame_id,
                frag_indices,
            },
        }
    }
}

/// Maps a wire decode-frontier `u32` to the actor's `Option<u32>`: the
/// [`RecoveryMessage::NO_FRAME_DECODED_SENTINEL`] becomes `None`, every other value `Some`.
#[must_use]
const fn decode_frontier(last_decoded: u32) -> Option<u32> {
    if last_decoded == RecoveryMessage::NO_FRAME_DECODED_SENTINEL {
        None
    } else {
        Some(last_decoded)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input_event::InputEvent;

    fn router() -> RecoveryDatagramRouter {
        RecoveryDatagramRouter::new()
    }

    // MARK: Recovery routing cases (the Swift `RecoveryDatagramRouterTests` suite cross-checks the same).

    #[test]
    fn ignores_when_not_streaming() {
        let datagram = RecoveryMessage::RequestIdr {
            last_decoded_frame_id: 5,
        }
        .encode();
        assert_eq!(
            router().route(&datagram, false),
            Decision::IgnoreNotStreaming
        );
    }

    /// Component 2: `ForceKeyframe` carries the request's decode frontier for the actor's
    /// delivery-keyed `RecoveryIDRPolicy`.
    #[test]
    fn request_idr_forces_keyframe_carrying_last_decoded() {
        let datagram = RecoveryMessage::RequestIdr {
            last_decoded_frame_id: 41,
        }
        .encode();
        assert_eq!(
            router().route(&datagram, true),
            Decision::ForceKeyframe {
                last_decoded_frame_id: Some(41),
            }
        );
    }

    /// The wire sentinel ("nothing decoded yet") maps to a clean `None` for the actor's policy.
    #[test]
    fn request_idr_sentinel_maps_to_none() {
        let datagram = RecoveryMessage::RequestIdr {
            last_decoded_frame_id: RecoveryMessage::NO_FRAME_DECODED_SENTINEL,
        }
        .encode();
        assert_eq!(
            router().route(&datagram, true),
            Decision::ForceKeyframe {
                last_decoded_frame_id: None,
            }
        );
    }

    /// WF-8: `requestLTRRefresh` routes to `RefreshLtr` (the actor decides
    /// LTR-refresh-vs-IDR from runtime acked-token state), DISTINCT from `requestIDR`'s
    /// `ForceKeyframe` (the guaranteed IDR). Component 2: it carries the decode frontier too.
    #[test]
    fn request_ltr_refresh_routes_to_refresh_ltr() {
        let datagram = RecoveryMessage::RequestLtrRefresh {
            from_frame_id: 10,
            to_frame_id: 12,
            last_decoded_frame_id: 9,
        }
        .encode();
        assert_eq!(
            router().route(&datagram, true),
            Decision::RefreshLtr {
                last_decoded_frame_id: Some(9),
            }
        );
    }

    #[test]
    fn request_ltr_refresh_sentinel_maps_to_none() {
        let datagram = RecoveryMessage::RequestLtrRefresh {
            from_frame_id: 0,
            to_frame_id: 0,
            last_decoded_frame_id: RecoveryMessage::NO_FRAME_DECODED_SENTINEL,
        }
        .encode();
        assert_eq!(
            router().route(&datagram, true),
            Decision::RefreshLtr {
                last_decoded_frame_id: None,
            }
        );
    }

    /// `requestIDR` MUST stay a real forced keyframe — the guaranteed-recovery escalation
    /// must never degrade to an LTR refresh. (`last_decoded == 0` is NOT the sentinel.)
    #[test]
    fn request_idr_stays_force_keyframe() {
        let datagram = RecoveryMessage::RequestIdr {
            last_decoded_frame_id: 0,
        }
        .encode();
        assert_eq!(
            router().route(&datagram, true),
            Decision::ForceKeyframe {
                last_decoded_frame_id: Some(0),
            }
        );
    }

    #[test]
    fn ack_surfaces_stream_seq() {
        let datagram = RecoveryMessage::Ack {
            stream_seq: 0xCAFE_BABE,
        }
        .encode();
        assert_eq!(
            router().route(&datagram, true),
            Decision::Ack {
                stream_seq: 0xCAFE_BABE,
            }
        );
    }

    /// FIX B: a `requestCursorShape` on the recovery channel routes to a re-ship of that
    /// shape, NOT a forced keyframe — the cursor self-heal must not trigger an expensive IDR.
    #[test]
    fn request_cursor_shape_reships() {
        let datagram = RecoveryMessage::RequestCursorShape { shape_id: 7 }.encode();
        assert_eq!(
            router().route(&datagram, true),
            Decision::ReshipCursorShape { shape_id: 7 }
        );
    }

    #[test]
    fn request_cursor_shape_ignored_when_not_streaming() {
        let datagram = RecoveryMessage::RequestCursorShape { shape_id: 1 }.encode();
        assert_eq!(
            router().route(&datagram, false),
            Decision::IgnoreNotStreaming
        );
    }

    #[test]
    fn drops_undecodable_datagram() {
        // Unknown recovery type 0x7F.
        let garbage = [0x7F_u8, 0x00];
        assert!(matches!(
            router().route(&garbage, true),
            Decision::Drop { .. }
        ));
    }

    /// The network-feedback channel: a `NetworkStats` report routes to `NetworkStats`
    /// carrying the decoded report verbatim — including component 3's trend fields (a
    /// negative modified-trend bit-pattern + packed state/deltas flags survive the wire
    /// round-trip untouched) and component 4's pacer presentation-health fields.
    #[test]
    fn network_stats_routes() {
        let report = NetworkStatsReport {
            frames_received: 600,
            fec_recovered: 12,
            unrecovered: 3,
            latest_host_send_ts: 1_234_567,
            client_hold_ms: 7,
            owd_jitter_micros: 850,
            owd_trend_milli: (-987_i32) as u32,
            owd_trend_flags: (42_u32 << 8) | 1,
            pacer_late_frames: 4,
            pacer_present_gaps: 6,
            pacer_depth: 2,
        };
        let decision = router().route(&RecoveryMessage::NetworkStats(report).encode(), true);
        assert_eq!(decision, Decision::NetworkStats(report));
        let Decision::NetworkStats(rx) = decision else {
            panic!("expected networkStats");
        };
        assert_eq!(rx.owd_trend_state_raw(), 1);
        assert_eq!(rx.owd_trend_deltas(), 42);
        assert_eq!(rx.owd_trend_modified_milli_signed(), -987);
        assert_eq!(rx.pacer_late_frames, 4);
        assert_eq!(rx.pacer_present_gaps, 6);
        assert_eq!(rx.pacer_depth, 2);
    }

    #[test]
    fn request_fragments_routes_to_retransmit() {
        let msg = RecoveryMessage::RequestFragments {
            frame_id: 7,
            frag_indices: vec![1, 4, 9],
        };
        let decision = router().route(&msg.encode(), true);
        assert_eq!(
            decision,
            Decision::RetransmitFragments {
                frame_id: 7,
                frag_indices: vec![1, 4, 9],
            },
        );
        // Not streaming ⇒ ignored before decode (same guard as every other recovery message).
        assert_eq!(
            router().route(&msg.encode(), false),
            Decision::IgnoreNotStreaming,
        );
    }

    #[test]
    fn network_stats_ignored_when_not_streaming() {
        let report = NetworkStatsReport {
            frames_received: 1,
            latest_host_send_ts: 1,
            ..NetworkStatsReport::default()
        };
        assert_eq!(
            router().route(&RecoveryMessage::NetworkStats(report).encode(), false),
            Decision::IgnoreNotStreaming
        );
    }

    /// A truncated `NetworkStats` body (short of the 11×u32 payload) DROPS — never crashes.
    #[test]
    fn truncated_network_stats_drops() {
        let report = NetworkStatsReport {
            frames_received: 1,
            fec_recovered: 2,
            unrecovered: 3,
            latest_host_send_ts: 4,
            client_hold_ms: 5,
            owd_jitter_micros: 6,
            ..NetworkStatsReport::default()
        };
        let full = RecoveryMessage::NetworkStats(report).encode();
        assert!(matches!(
            router().route(&full[..10], true),
            Decision::Drop { .. }
        ));
    }

    // MARK: Never-run wire-collision regression
    //
    // Wire-collision cases: the byte-grammar collision between the recovery and input channels
    // is exercised directly through `InputEvent::decode` — the load-bearing part of the regression.
    // (The Swift `RecoveryDatagramRouterTests` cross-checks these against `InputDatagramRouter`.)

    /// THE original bug: recovery rode the `.input` channel, where the host decodes every
    /// datagram as an `InputEvent`. `RecoveryMessage`'s leading type bytes (1/2/3) overlap
    /// `InputEvent`'s (mouseMove/Down/Up). This proves the channels are disjoint: the same
    /// bytes route to the WF-8 LTR-refresh decision on the recovery router, and the input
    /// grammar would only ever (mis)read them as a `MouseDown` if it decoded at all.
    #[test]
    fn recovery_bytes_are_not_misrouted_as_input() {
        let ltr = RecoveryMessage::RequestLtrRefresh {
            from_frame_id: 7,
            to_frame_id: 7,
            last_decoded_frame_id: 6,
        }
        .encode();

        // The recovery router decodes it correctly → routes to the WF-8 LTR-refresh decision.
        assert_eq!(
            router().route(&ltr, true),
            Decision::RefreshLtr {
                last_decoded_frame_id: Some(6),
            }
        );

        // The SAME bytes, fed to the input grammar (type byte 2 = mouseDown), surface the
        // collision the dedicated channel eliminates: if the input grammar decodes them at
        // all it can only be a mouseDown (the Swift shell's `if case .mouseDown` matches this). The 13-byte
        // LTR body is in fact too short for a 24-byte mouseDown, so it truncates here — but
        // the point is recovery NEVER travels on `.input`.
        if let Ok(event) = InputEvent::decode(&ltr) {
            assert!(matches!(event, InputEvent::MouseDown { .. }));
        }
    }

    /// `requestIDR` (type byte 3) overlaps `InputEvent::MouseUp` (type 3) but is shorter —
    /// even the component-2 5-byte body ([3][lastDecodedFrameID]) truncates against
    /// mouseUp's 24-byte wire size, so on the input grammar it drops (silently swallowing
    /// recovery). On the recovery channel it correctly forces a keyframe.
    #[test]
    fn request_idr_would_have_been_swallowed_by_input_grammar() {
        let idr = RecoveryMessage::RequestIdr {
            last_decoded_frame_id: 99,
        }
        .encode();
        assert_eq!(idr.len(), 5);
        assert_eq!(
            router().route(&idr, true),
            Decision::ForceKeyframe {
                last_decoded_frame_id: Some(99),
            }
        );
        // 5 bytes is still too short for a mouseUp body → the input grammar drops it.
        assert!(InputEvent::decode(&idr).is_err());
    }

    // MARK: added edge cases

    /// The non-streaming guard precedes the decode: even outright garbage on a
    /// non-streaming session is ignored, never dropped.
    #[test]
    fn garbage_ignored_before_decode_when_not_streaming() {
        assert_eq!(
            router().route(&[0xFF, 0xFF, 0xFF], false),
            Decision::IgnoreNotStreaming
        );
    }

    /// An empty datagram cannot even yield a type byte → drop (when streaming).
    #[test]
    fn empty_datagram_drops_when_streaming() {
        assert!(matches!(router().route(&[], true), Decision::Drop { .. }));
    }

    /// A valid message with one trailing byte is malformed (the recovery codec rejects
    /// trailing bytes for byte-keyed host dedup) → drop.
    #[test]
    fn trailing_bytes_drop() {
        let mut bytes = RecoveryMessage::Ack { stream_seq: 1 }.encode();
        bytes.push(0);
        assert!(matches!(
            router().route(&bytes, true),
            Decision::Drop { .. }
        ));
    }

    /// Ack passes the value through untouched at both extremes of `u32`.
    #[test]
    fn ack_passthrough_extremes() {
        for seq in [0_u32, u32::MAX] {
            let datagram = RecoveryMessage::Ack { stream_seq: seq }.encode();
            assert_eq!(
                router().route(&datagram, true),
                Decision::Ack { stream_seq: seq }
            );
        }
    }

    /// Cursor-shape id passes through untouched at both extremes of `u16`.
    #[test]
    fn cursor_shape_passthrough_extremes() {
        for id in [0_u16, u16::MAX] {
            let datagram = RecoveryMessage::RequestCursorShape { shape_id: id }.encode();
            assert_eq!(
                router().route(&datagram, true),
                Decision::ReshipCursorShape { shape_id: id }
            );
        }
    }

    /// The LTR refresh `from`/`to` frame ids are NOT part of the decision — only the decode
    /// frontier survives. Two requests differing only in `from`/`to` route identically.
    #[test]
    fn ltr_refresh_ignores_from_to() {
        let a = RecoveryMessage::RequestLtrRefresh {
            from_frame_id: 1,
            to_frame_id: 2,
            last_decoded_frame_id: 42,
        }
        .encode();
        let b = RecoveryMessage::RequestLtrRefresh {
            from_frame_id: 100,
            to_frame_id: 200,
            last_decoded_frame_id: 42,
        }
        .encode();
        let expected = Decision::RefreshLtr {
            last_decoded_frame_id: Some(42),
        };
        assert_eq!(router().route(&a, true), expected);
        assert_eq!(router().route(&b, true), expected);
    }

    /// A `last_decoded` of `sentinel - 1` (`0xFFFF_FFFE`) is NOT the sentinel and passes
    /// through as `Some` — guards the off-by-one on the sentinel boundary.
    #[test]
    fn sentinel_boundary_is_not_sentinel() {
        let near = RecoveryMessage::NO_FRAME_DECODED_SENTINEL - 1;
        let datagram = RecoveryMessage::RequestIdr {
            last_decoded_frame_id: near,
        }
        .encode();
        assert_eq!(
            router().route(&datagram, true),
            Decision::ForceKeyframe {
                last_decoded_frame_id: Some(near),
            }
        );
    }

    /// An all-zero `NetworkStatsReport` round-trips through the router unchanged.
    #[test]
    fn network_stats_all_zero_round_trips() {
        let report = NetworkStatsReport::default();
        let datagram = RecoveryMessage::NetworkStats(report).encode();
        assert_eq!(
            router().route(&datagram, true),
            Decision::NetworkStats(report)
        );
    }

    /// `new()` and `default()` build the same stateless router.
    #[test]
    fn new_equals_default() {
        assert_eq!(RecoveryDatagramRouter::new(), RecoveryDatagramRouter);
    }
}
