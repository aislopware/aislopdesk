//! The TCP-mux layer — a port of `Sources/AislopdeskProtocol/Mux`.
//!
//! Multiplexes many logical channels over one physical TCP connection (SSH-style channel
//! framing) and runs per-channel credit flow control. Every type here is a pure value type
//! with no IO, clock, or socket — the routing/IO glue lives in the platform shell.
//!
//! * [`MuxEnvelopeCodec`] / [`MuxFrame`] / [`MuxFrameType`] — the outer channel-framing
//!   codec (its `ChannelData` body is an opaque inner [`WireMessage`](crate::terminal::WireMessage)).
//! * [`MuxFrameDecoder`] — the streaming envelope splitter.
//! * [`ChannelTable`] / [`ChannelState`] — the odd-id allocator + SSH close state machine.
//! * [`FlowCreditPolicy`] / [`ReceiveWindowAccountant`] — the sender/receiver halves of the
//!   per-channel credit window.
//! * [`BoundedQueuePolicy`] — the host PTY-read backpressure decider.
//! * [`flow_control`] — the shared window/queue sizing constants + env resolvers.

pub mod bounded_queue_policy;
pub mod channel_table;
pub mod envelope;
pub mod flow_control;
pub mod flow_credit_policy;
pub mod frame_decoder;
pub mod receive_window_accountant;

pub use bounded_queue_policy::BoundedQueuePolicy;
pub use channel_table::{ChannelState, ChannelTable};
pub use envelope::{MuxEnvelopeCodec, MuxFrame, MuxFrameType};
pub use flow_credit_policy::{ConsumeResult, FlowCreditPolicy};
pub use frame_decoder::MuxFrameDecoder;
pub use receive_window_accountant::ReceiveWindowAccountant;
