//! Pure value-type bookkeeping for the set of logical channels on one mux connection —
//! the canonical `ChannelTable` logic. The Swift `AislopdeskProtocol` shell tracks it (golden parity).
//!
//! Allocates **odd** channel ids (1, 3, 5, …) — even ids and 0 are reserved for the peer
//! — using a monotonic counter that NEVER reuses a live id (an id is "live" until it
//! reaches [`ChannelState::Closed`]). Tracks each channel's [`ChannelState`] with SSH
//! `CHANNEL_CLOSE` symmetry: each side sends close, and the channel is fully closed only
//! after both. No IO, no clock, no sockets.

use std::collections::{HashMap, HashSet};

/// Lifecycle state of one logical mux channel.
///
/// SSH-style `CHANNEL_CLOSE` symmetry: a channel is only fully [`Closed`](ChannelState::Closed)
/// after BOTH sides have sent their close. While exactly one side has closed, the channel
/// is [`HalfClosed`](ChannelState::HalfClosed).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelState {
    /// Allocated id with no `open` recorded yet (never carried data).
    Idle,
    /// Both sides live; the channel routes data.
    Open,
    /// Exactly one side has sent `CHANNEL_CLOSE`; awaiting the peer's close.
    HalfClosed,
    /// Both sides have closed; the channel is dead and will not be reused.
    Closed,
}

/// Allocator + per-channel state machine for one mux connection.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ChannelTable {
    /// Per-channel state. Closed channels are retained so their ids are never reused.
    states: HashMap<u32, ChannelState>,
    /// The last odd id handed out by [`allocate`](ChannelTable::allocate); 0 means none.
    last_allocated: u32,
    /// Insertion-ordered ring of ids that reached a terminal-ish state (half-closed or
    /// closed). Bounds the retained terminal entries so sustained open→close CHURN with a
    /// fresh peer-chosen id each cycle cannot grow `states` without bound (R12 #1).
    terminal_ring: Vec<u32>,
    terminal_ring_head: usize,
}

impl ChannelTable {
    /// Sized ≥ `MAX_CHANNELS_PER_CONNECTION` so legitimate churn is never evicted while
    /// still routable; once full, recording a new terminal id evicts the oldest.
    const TERMINAL_RING_CAP: usize = 1024;

    /// A fresh, empty channel table.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Records `id` as newly terminal and, once the ring is full, evicts the oldest
    /// terminal id from `states` (O(1) — overwrites a ring slot). Call EXACTLY once per
    /// id, on its first transition into a terminal state.
    fn note_terminal(&mut self, id: u32) {
        if self.terminal_ring.len() < Self::TERMINAL_RING_CAP {
            self.terminal_ring.push(id);
        } else {
            let evicted = self.terminal_ring[self.terminal_ring_head];
            if evicted != id {
                self.states.remove(&evicted);
            }
            self.terminal_ring[self.terminal_ring_head] = id;
            self.terminal_ring_head += 1;
            if self.terminal_ring_head == Self::TERMINAL_RING_CAP {
                self.terminal_ring_head = 0;
            }
        }
    }

    /// Allocates the next unused **odd** channel id and records it as
    /// [`ChannelState::Idle`]. Monotonic: an id is never handed out twice, even across
    /// closes.
    pub fn allocate(&mut self) -> u32 {
        // First id is 1; thereafter advance by 2 to stay odd.
        let id = if self.last_allocated == 0 {
            1
        } else {
            self.last_allocated + 2
        };
        self.last_allocated = id;
        self.states.insert(id, ChannelState::Idle);
        id
    }

    /// Marks `id` as [`ChannelState::Open`]. Idempotent for an already-open channel; a
    /// no-op for an already-closing/closed id.
    pub fn open(&mut self, id: u32) {
        match self.states.get(&id) {
            // `None` lets a responder register a peer-initiated id it did not allocate.
            Some(ChannelState::Idle | ChannelState::Open) | None => {
                self.states.insert(id, ChannelState::Open);
            }
            Some(ChannelState::HalfClosed | ChannelState::Closed) => {} // do not re-open
        }
    }

    /// Records that the responder REFUSED our channel-open. A refused channel never
    /// opened, so an `idle` id goes straight to [`ChannelState::Closed`] (retained, never
    /// reused). A no-op for any other state or an unknown id. Returns the resulting state.
    pub fn reject(&mut self, id: u32) -> ChannelState {
        if self.states.get(&id) == Some(&ChannelState::Idle) {
            self.states.insert(id, ChannelState::Closed);
            self.note_terminal(id);
        }
        self.states
            .get(&id)
            .copied()
            .unwrap_or(ChannelState::Closed)
    }

    /// Records that THIS side sent `CHANNEL_CLOSE` on `id` and returns the resulting state.
    pub fn local_close(&mut self, id: u32) -> ChannelState {
        self.advance_close(id)
    }

    /// Records that the PEER sent `CHANNEL_CLOSE` on `id` and returns the resulting state.
    pub fn remote_close(&mut self, id: u32) -> ChannelState {
        self.advance_close(id)
    }

    /// Shared close transition — `CHANNEL_CLOSE` symmetry means a close from either
    /// direction advances the same one-step state machine.
    fn advance_close(&mut self, id: u32) -> ChannelState {
        match self.states.get(&id) {
            Some(ChannelState::Idle | ChannelState::Open) => {
                self.states.insert(id, ChannelState::HalfClosed); // first close
                self.note_terminal(id); // newly terminal — bound the retained entries
                ChannelState::HalfClosed
            }
            Some(ChannelState::HalfClosed) => {
                self.states.insert(id, ChannelState::Closed); // second close — both done
                ChannelState::Closed
            }
            Some(ChannelState::Closed) => ChannelState::Closed, // already dead
            None => {
                // A close for an id we NEVER registered must create NO entry, else a
                // hostile peer grows `states` without bound by spamming closes for
                // arbitrary peer-chosen ids (a router memory-DoS). The monotonic-no-reuse
                // guarantee only needs to cover LOCALLY-allocated ids.
                ChannelState::Closed
            }
        }
    }

    /// The current [`ChannelState`] of `id`, or `None` if it was never allocated.
    #[must_use]
    pub fn state(&self, id: u32) -> Option<ChannelState> {
        self.states.get(&id).copied()
    }

    /// Whether `id` is currently routable ([`ChannelState::Open`]). A half-closed channel
    /// is NOT considered open here.
    #[must_use]
    pub fn is_open(&self, id: u32) -> bool {
        self.states.get(&id) == Some(&ChannelState::Open)
    }

    /// Ids that are not fully [`ChannelState::Closed`] (idle, open, or half-closed).
    #[must_use]
    pub fn live_channel_ids(&self) -> HashSet<u32> {
        self.states
            .iter()
            .filter(|&(_, &state)| state != ChannelState::Closed)
            .map(|(&id, _)| id)
            .collect()
    }

    /// Total number of retained id entries (live + closed) — diagnostics / tests.
    #[must_use]
    pub fn state_count(&self) -> usize {
        self.states.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allocates_odd_monotonic_ids() {
        let mut table = ChannelTable::new();
        let ids: Vec<u32> = (0..5).map(|_| table.allocate()).collect();
        assert_eq!(
            ids,
            [1, 3, 5, 7, 9],
            "client-initiated ids are odd and monotonic"
        );
        for id in ids {
            assert_eq!(table.state(id), Some(ChannelState::Idle));
        }
    }

    #[test]
    fn never_reuses_a_live_id() {
        let mut table = ChannelTable::new();
        let first = table.allocate();
        table.open(first);
        let second = table.allocate();
        assert_ne!(first, second);
        assert_eq!([first, second], [1, 3]);
    }

    #[test]
    fn never_reuses_a_closed_id_either() {
        let mut table = ChannelTable::new();
        let a = table.allocate();
        table.open(a);
        assert_eq!(table.local_close(a), ChannelState::HalfClosed);
        assert_eq!(table.remote_close(a), ChannelState::Closed);
        let b = table.allocate();
        assert_eq!(b, 3);
        assert_eq!(table.state(a), Some(ChannelState::Closed));
    }

    #[test]
    fn lifecycle_idle_to_open() {
        let mut table = ChannelTable::new();
        let id = table.allocate();
        assert_eq!(table.state(id), Some(ChannelState::Idle));
        assert!(!table.is_open(id));
        table.open(id);
        assert_eq!(table.state(id), Some(ChannelState::Open));
        assert!(table.is_open(id));
    }

    #[test]
    fn lifecycle_both_sides_close_symmetry_local_then_remote() {
        let mut table = ChannelTable::new();
        let id = table.allocate();
        table.open(id);
        assert_eq!(table.local_close(id), ChannelState::HalfClosed);
        assert!(!table.is_open(id));
        assert_eq!(table.remote_close(id), ChannelState::Closed);
    }

    #[test]
    fn lifecycle_both_sides_close_symmetry_remote_then_local() {
        let mut table = ChannelTable::new();
        let id = table.allocate();
        table.open(id);
        assert_eq!(table.remote_close(id), ChannelState::HalfClosed);
        assert_eq!(table.local_close(id), ChannelState::Closed);
    }

    #[test]
    fn closing_an_idle_channel_half_then_full_closes() {
        let mut table = ChannelTable::new();
        let id = table.allocate();
        assert_eq!(table.state(id), Some(ChannelState::Idle));
        assert_eq!(table.local_close(id), ChannelState::HalfClosed);
        assert_eq!(table.remote_close(id), ChannelState::Closed);
    }

    #[test]
    fn reopening_a_closing_channel_is_ignored() {
        let mut table = ChannelTable::new();
        let id = table.allocate();
        table.open(id);
        assert_eq!(table.local_close(id), ChannelState::HalfClosed);
        table.open(id); // no-op
        assert_eq!(table.state(id), Some(ChannelState::HalfClosed));
        assert_eq!(table.remote_close(id), ChannelState::Closed);
        table.open(id); // still a no-op
        assert_eq!(table.state(id), Some(ChannelState::Closed));
    }

    #[test]
    fn live_channel_ids_excludes_only_fully_closed() {
        let mut table = ChannelTable::new();
        let a = table.allocate(); // 1 idle
        let b = table.allocate(); // 3 open
        let c = table.allocate(); // 5 half-closed
        let d = table.allocate(); // 7 fully closed
        table.open(b);
        table.local_close(c);
        table.local_close(d);
        table.remote_close(d);

        let live = table.live_channel_ids();
        assert_eq!(live, HashSet::from([a, b, c]));
        assert!(!live.contains(&d));
    }

    #[test]
    fn state_of_unknown_id_is_none() {
        let table = ChannelTable::new();
        assert_eq!(table.state(42), None);
        assert!(!table.is_open(42));
    }

    #[test]
    fn remote_close_for_unknown_id_creates_no_entry() {
        let mut table = ChannelTable::new();
        let mut id = 1000u32;
        while id < 1000 + 5000 {
            assert_eq!(table.remote_close(id), ChannelState::Closed);
            id += 2;
        }
        assert!(table.live_channel_ids().is_empty());
        assert_eq!(
            table.state(1000),
            None,
            "a stray close leaves NO retained entry"
        );
        // A locally-allocated id still flows the normal half-close → closed machine.
        let mine = table.allocate();
        table.open(mine);
        assert_eq!(table.local_close(mine), ChannelState::HalfClosed);
        assert_eq!(table.remote_close(mine), ChannelState::Closed);
        assert_eq!(table.state(mine), Some(ChannelState::Closed));
    }

    #[test]
    fn terminal_ring_bounds_retained_entries_under_churn() {
        // Sustained peer-driven open→close churn with a fresh even id each cycle must not
        // grow `states` without bound — the ring evicts the oldest terminal entry once full.
        let mut table = ChannelTable::new();
        for id in (2u32..)
            .step_by(2)
            .take(ChannelTable::TERMINAL_RING_CAP * 4)
        {
            table.open(id); // peer-initiated registration
            table.remote_close(id);
            table.local_close(id);
        }
        assert!(
            table.state_count() <= ChannelTable::TERMINAL_RING_CAP,
            "retained entries stay bounded by the terminal ring cap"
        );
    }
}
