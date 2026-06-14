//! # aislopdesk-core
//!
//! The portable, side-effect-free core of Aislopdesk: the wire codecs, forward-error
//! correction, packetizer/reassembler, and realtime-media controllers, reimplemented
//! in 100% safe Rust as a byte- and behaviour-identical port of the Swift
//! `AislopdeskVideoProtocol` and `AislopdeskProtocol` (terminal/PTY path, see
//! [`terminal`]) targets.
//!
//! ## Why this crate exists
//!
//! The macOS/iOS app keeps running its native Swift implementations untouched — this
//! crate is a *parallel* source of truth, not a replacement — so the existing hot
//! path takes **zero performance risk**. The crate exists so a future Android client
//! can link the exact same algorithms over a C ABI / JNI boundary (the ALVR pattern:
//! Rust owns reassembly/FEC/jitter/ABR/recovery; the platform shell owns capture,
//! the socket, and the hardware codec).
//!
//! Equivalence with the Swift source is *proven*, not assumed: the `golden_parity`
//! integration test replays JSON vectors emitted by the Swift `aislopdesk-corevectors`
//! dumper and asserts byte-identical output, and every Swift unit test is mirrored
//! here.
//!
//! ## Invariants
//!
//! * **No `unsafe`.** Enforced crate-wide by [`forbid(unsafe_code)`]. The FFI lives in the
//!   separate `aislopdesk-ffi` crate at the boundary — the one place `unsafe` is allowed.
//! * **No dependencies.** The shipped library pulls in nothing; auditability and a
//!   minimal Android footprint are the point.
//! * **Never panics on untrusted input.** Every decoder of network bytes returns
//!   [`error::Result`]; a corrupt datagram is dropped, never a crash.

#![forbid(unsafe_code)]

pub mod adaptive_fec;
pub mod bytes;
pub mod coordinate_mapping;
pub mod cursor;
pub mod decode_frontier;
pub mod decode_gate;
pub mod decode_sequencer;
pub mod error;
pub mod fec;
pub mod fps_governor;
pub mod fragment;
pub mod geometry;
pub mod idle_reap_decider;
pub mod input_event;
pub mod interleaver;
pub mod keepalive;
pub mod live_bitrate_policy;
pub mod live_congestion_controller;
pub mod ltr_controller;
pub mod mux_header;
pub mod nal_unit;
pub mod network_estimate;
pub mod owd_late_detector;
pub mod pacer_depth_policy;
pub mod reassembler;
pub mod recovery;
pub mod recovery_idr_policy;
pub mod recovery_policy;
pub mod recovery_request_deduper;
pub mod seq;
pub mod terminal;
pub mod trendline_estimator;
pub mod video_control;
pub mod window_geometry;
pub mod ycbcr;

pub use error::{Result, VideoProtocolError};

/// Wire protocol version for the video path (bumped on any breaking change). Mirrors
/// Swift `AislopdeskVideoProtocol.version`.
pub const VIDEO_PROTOCOL_VERSION: u16 = 1;
