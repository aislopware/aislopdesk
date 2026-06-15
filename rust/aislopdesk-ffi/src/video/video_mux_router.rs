//! `video_mux_router`: opaque handle (host per-datagram mux routing for the GUI video path).
//! Driven on the transport's mux queue (one `route()` per received datagram, NSLock-serialized).
//! `admit/retire/begin_drain/end_drain` fold the lane bookkeeping; `route()` decides per datagram.
//! The Decision / `BootstrapAction` enums cross as u8 discriminants — the live path and tests read
//! only the discriminant (the Route `channel_id` echoes the caller's input; the Drop reason is
//! descriptive-only and never asserted), so no associated value crosses the boundary. One owner
//! (`NWVideoMuxDatagramTransport`). Same "Rust owns the state" boundary as the deduper.

use aislopdesk_core::video_mux_router::{
    BootstrapAction as MuxBootstrapAction, Decision as MuxDecision,
    VideoChannel as MuxVideoChannel, VideoMuxRouter,
};

/// [`MuxDecision::Route`] discriminant — route to the lane (channel id echoes the caller's input).
pub const AISD_MUX_DECISION_ROUTE: u8 = 0;
/// [`MuxDecision::RejectUnadmitted`] discriminant — unknown/stray lane.
pub const AISD_MUX_DECISION_REJECT_UNADMITTED: u8 = 1;
/// [`MuxDecision::DropRetired`] discriminant — retired lane (reconnect-generation drop).
pub const AISD_MUX_DECISION_DROP_RETIRED: u8 = 2;
/// [`MuxDecision::DropDraining`] discriminant — lane mid-teardown.
pub const AISD_MUX_DECISION_DROP_DRAINING: u8 = 3;
/// [`MuxDecision::Drop`] discriminant — benign drop (e.g. empty datagram).
pub const AISD_MUX_DECISION_DROP: u8 = 4;

/// [`MuxBootstrapAction::BootstrapDeliver`] discriminant — deliver + stamp the reply flow.
pub const AISD_MUX_BOOTSTRAP_DELIVER: u8 = 0;
/// [`MuxBootstrapAction::DropNoStamp`] discriminant — drop without touching flow bookkeeping.
pub const AISD_MUX_BOOTSTRAP_DROP_NO_STAMP: u8 = 1;

const fn mux_decision_to_c(d: &MuxDecision) -> u8 {
    match d {
        MuxDecision::Route { .. } => AISD_MUX_DECISION_ROUTE,
        MuxDecision::RejectUnadmitted => AISD_MUX_DECISION_REJECT_UNADMITTED,
        MuxDecision::DropRetired => AISD_MUX_DECISION_DROP_RETIRED,
        MuxDecision::DropDraining => AISD_MUX_DECISION_DROP_DRAINING,
        MuxDecision::Drop { .. } => AISD_MUX_DECISION_DROP,
    }
}

/// Rebuilds a [`MuxDecision`] from its discriminant for [`VideoMuxRouter::bootstrap_action`], which
/// only matches the variant — so the associated values are dummies (the live caller likewise reads
/// only the discriminant). An unknown discriminant maps to `RejectUnadmitted` (the safe "unknown
/// lane").
const fn mux_decision_from_c(kind: u8) -> MuxDecision {
    match kind {
        AISD_MUX_DECISION_ROUTE => MuxDecision::Route { channel_id: 0 },
        AISD_MUX_DECISION_DROP_RETIRED => MuxDecision::DropRetired,
        AISD_MUX_DECISION_DROP_DRAINING => MuxDecision::DropDraining,
        AISD_MUX_DECISION_DROP => MuxDecision::Drop {
            reason: String::new(),
        },
        _ => MuxDecision::RejectUnadmitted,
    }
}

/// A C channel byte → core [`MuxVideoChannel`]. An unknown byte maps to `Video` (a non-control
/// channel), so an out-of-range channel can never accidentally satisfy a control-only bootstrap.
fn mux_channel_from_c(channel: u8) -> MuxVideoChannel {
    MuxVideoChannel::from_raw(channel).unwrap_or(MuxVideoChannel::Video)
}

/// Opaque host per-datagram mux router.
///
/// Create with [`aisd_video_mux_router_new`], fold lane state with the `_admit` / `_retire` /
/// `_begin_drain` / `_end_drain` calls, decide per datagram with [`aisd_video_mux_router_route`],
/// destroy with [`aisd_video_mux_router_free`]. One per transport; not thread-safe (the caller's
/// lock serializes access).
pub struct AisdVideoMuxRouter {
    inner: VideoMuxRouter,
}

/// Creates a fresh mux router (nothing admitted). Destroy it with [`aisd_video_mux_router_free`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_video_mux_router_new() -> *mut AisdVideoMuxRouter {
    Box::into_raw(Box::new(AisdVideoMuxRouter {
        inner: VideoMuxRouter::new(),
    }))
}

/// Destroys a router created by [`aisd_video_mux_router_new`]. No-op on null.
///
/// # Safety
/// `router` must be a pointer from [`aisd_video_mux_router_new`] that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_mux_router_free(router: *mut AisdVideoMuxRouter) {
    unsafe {
        if !router.is_null() {
            drop(Box::from_raw(router));
        }
    }
}

/// Admits `channel_id` as a live lane (clears any retired/draining mark). No-op on null. Wraps
/// [`VideoMuxRouter::admit`].
///
/// # Safety
/// `router`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_mux_router_admit(
    router: *mut AisdVideoMuxRouter,
    channel_id: u32,
) {
    unsafe {
        if let Some(r) = router.as_mut() {
            r.inner.admit(channel_id);
        }
    }
}

/// Retires `channel_id` (reconnect/teardown). No-op on null. Wraps [`VideoMuxRouter::retire`].
///
/// # Safety
/// `router`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_mux_router_retire(
    router: *mut AisdVideoMuxRouter,
    channel_id: u32,
) {
    unsafe {
        if let Some(r) = router.as_mut() {
            r.inner.retire(channel_id);
        }
    }
}

/// Begins draining `channel_id` on the reaper path. No-op on null. Wraps
/// [`VideoMuxRouter::begin_drain`].
///
/// # Safety
/// `router`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_mux_router_begin_drain(
    router: *mut AisdVideoMuxRouter,
    channel_id: u32,
) {
    unsafe {
        if let Some(r) = router.as_mut() {
            r.inner.begin_drain(channel_id);
        }
    }
}

/// Finishes draining `channel_id` (draining → retired). No-op on null. Wraps
/// [`VideoMuxRouter::end_drain`].
///
/// # Safety
/// `router`, if non-null, must be a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_mux_router_end_drain(
    router: *mut AisdVideoMuxRouter,
    channel_id: u32,
) {
    unsafe {
        if let Some(r) = router.as_mut() {
            r.inner.end_drain(channel_id);
        }
    }
}

/// Whether `channel_id` is an admitted (routable) lane. `0` for a null handle. Wraps
/// [`VideoMuxRouter::is_admitted`].
///
/// # Safety
/// `router`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_mux_router_is_admitted(
    router: *const AisdVideoMuxRouter,
    channel_id: u32,
) -> u8 {
    unsafe {
        router
            .as_ref()
            .map_or(0, |r| u8::from(r.inner.is_admitted(channel_id)))
    }
}

/// Whether `channel_id` is currently draining. `0` for a null handle. Wraps
/// [`VideoMuxRouter::is_draining`].
///
/// # Safety
/// `router`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_mux_router_is_draining(
    router: *const AisdVideoMuxRouter,
    channel_id: u32,
) -> u8 {
    unsafe {
        router
            .as_ref()
            .map_or(0, |r| u8::from(r.inner.is_draining(channel_id)))
    }
}

/// The routing decision for one received datagram, as an `AISD_MUX_DECISION_*` discriminant.
///
/// `channel` is a [`MuxVideoChannel`] raw byte (0=control … 5=recovery). Returns `RejectUnadmitted`
/// (`1`) for a null handle (an unknown lane — the safe drop). Wraps [`VideoMuxRouter::route`].
///
/// # Safety
/// `router`, if non-null, must be a live handle.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_mux_router_route(
    router: *const AisdVideoMuxRouter,
    channel_id: u32,
    channel: u8,
    bytes_count: usize,
) -> u8 {
    unsafe {
        router
            .as_ref()
            .map_or(AISD_MUX_DECISION_REJECT_UNADMITTED, |r| {
                mux_decision_to_c(&r.inner.route(
                    channel_id,
                    mux_channel_from_c(channel),
                    bytes_count,
                ))
            })
    }
}

/// The bootstrap action for a not-yet-admitted datagram, as an `AISD_MUX_BOOTSTRAP_*` discriminant.
///
/// `decision` is an `AISD_MUX_DECISION_*` value, `channel` a [`MuxVideoChannel`] raw byte;
/// `payload_is_hello` / `payload_is_list_request` are bytes read `!= 0`. PURE (no handle). Wraps
/// [`VideoMuxRouter::bootstrap_action`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_video_mux_router_bootstrap_action(
    decision: u8,
    channel: u8,
    payload_is_hello: u8,
    payload_is_list_request: u8,
) -> u8 {
    match VideoMuxRouter::bootstrap_action(
        &mux_decision_from_c(decision),
        mux_channel_from_c(channel),
        payload_is_hello != 0,
        payload_is_list_request != 0,
    ) {
        MuxBootstrapAction::BootstrapDeliver => AISD_MUX_BOOTSTRAP_DELIVER,
        MuxBootstrapAction::DropNoStamp => AISD_MUX_BOOTSTRAP_DROP_NO_STAMP,
    }
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    #[test]
    fn video_mux_router_handle_routes_lanes() {
        unsafe {
            let r = aisd_video_mux_router_new();
            assert!(!r.is_null());
            // Unknown lane rejects; admitted lane routes.
            assert_eq!(
                aisd_video_mux_router_route(r, 11, 1, 1200),
                AISD_MUX_DECISION_REJECT_UNADMITTED
            );
            aisd_video_mux_router_admit(r, 11);
            assert_eq!(aisd_video_mux_router_is_admitted(r, 11), 1);
            assert_eq!(
                aisd_video_mux_router_route(r, 11, 1, 1200),
                AISD_MUX_DECISION_ROUTE
            );
            // Empty datagram drops; retired lane drop-retired; draining lane drop-draining.
            assert_eq!(
                aisd_video_mux_router_route(r, 11, 1, 0),
                AISD_MUX_DECISION_DROP
            );
            aisd_video_mux_router_retire(r, 11);
            assert_eq!(
                aisd_video_mux_router_route(r, 11, 1, 1200),
                AISD_MUX_DECISION_DROP_RETIRED
            );
            aisd_video_mux_router_admit(r, 12);
            aisd_video_mux_router_begin_drain(r, 12);
            assert_eq!(aisd_video_mux_router_is_draining(r, 12), 1);
            assert_eq!(
                aisd_video_mux_router_route(r, 12, 1, 1200),
                AISD_MUX_DECISION_DROP_DRAINING
            );
            aisd_video_mux_router_end_drain(r, 12);
            assert_eq!(aisd_video_mux_router_is_draining(r, 12), 0);
            assert_eq!(
                aisd_video_mux_router_route(r, 12, 1, 1200),
                AISD_MUX_DECISION_DROP_RETIRED
            );

            // bootstrap_action (static): a hello on control for a retired lane re-admits.
            assert_eq!(
                aisd_video_mux_router_bootstrap_action(AISD_MUX_DECISION_DROP_RETIRED, 0, 1, 0),
                AISD_MUX_BOOTSTRAP_DELIVER
            );
            assert_eq!(
                aisd_video_mux_router_bootstrap_action(AISD_MUX_DECISION_DROP_RETIRED, 0, 0, 0),
                AISD_MUX_BOOTSTRAP_DROP_NO_STAMP
            );
            // A draining lane drops even a hello.
            assert_eq!(
                aisd_video_mux_router_bootstrap_action(AISD_MUX_DECISION_DROP_DRAINING, 0, 1, 0),
                AISD_MUX_BOOTSTRAP_DROP_NO_STAMP
            );

            aisd_video_mux_router_free(r);
            aisd_video_mux_router_free(core::ptr::null_mut()); // no-op
            // A null handle rejects (unknown lane) and reports not-admitted / not-draining.
            assert_eq!(
                aisd_video_mux_router_route(core::ptr::null(), 1, 1, 100),
                AISD_MUX_DECISION_REJECT_UNADMITTED
            );
            assert_eq!(aisd_video_mux_router_is_admitted(core::ptr::null(), 1), 0);
            assert_eq!(aisd_video_mux_router_is_draining(core::ptr::null(), 1), 0);
        }
    }
}
