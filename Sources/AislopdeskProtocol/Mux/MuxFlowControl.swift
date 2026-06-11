import Foundation

/// Shared constants for TCP-mux per-channel credit flow control (always on).
///
/// The numbers here are deliberately in ONE place so both ends agree without negotiation: a
/// sender's initial ``FlowCreditPolicy`` window, a receiver's ``ReceiveWindowAccountant`` window,
/// and the host's ``BoundedQueuePolicy`` capacity are all sized from ``MuxFlowControl``.
public enum MuxFlowControl {
    /// Initial per-channel send/receive window, in bytes. 64 KiB, sized for LATENCY now that
    /// credit is granted at CONSUMPTION (the client's render drain), not at demux: every
    /// in-flight byte is committed ahead of fresh output, so the window bounds both client
    /// RAM per flooding pane AND the echo head-of-line delay (~44 ms at the measured
    /// ~12 Mbps inter-ISP path; the old 256 KiB ≈ 175 ms). Still far above what an
    /// interactive pane ever has outstanding, so flow control stays invisible on the
    /// common path. Throughput ceiling = window per grant round-trip (~17 Mbps at 30 ms
    /// WAN RTT, ~hundreds of Mbps on LAN) — ample for terminal bytes.
    ///
    /// PROGRESS INVARIANT (credit-at-consumption): every DATA inner frame must satisfy
    /// `frame wire bytes ≤ window/2` — the receiver can only consume (and thus re-grant)
    /// COMPLETE decoded frames, so a frame near the whole window could park its sender
    /// against a receiver whose pending credit never crosses the grant threshold. Enforced
    /// by construction: host output frames ≤ ``hostMergeCapBytes``/`PTYReadLoop.readChunkSize`
    /// (32 KiB), client input frames split at ``maxDataMessagePayloadBytes`` (16 KiB).
    ///
    /// `AISLOPDESK_MUX_WINDOW` tunes it — ⚠️ MUST be set identically in BOTH processes
    /// (host + client): the sender's window and the receiver's grant threshold derive from
    /// this constant in their own process; a host-only decrease below the client's
    /// half-window threshold permanently stalls the channel on the first flood.
    public static let initialWindowBytes =
        envInt("AISLOPDESK_MUX_WINDOW", 64 * 1024, min: 16 * 1024, max: 16 * 1024 * 1024)

    /// Split cap for client→host `.input` frames (paste). One paste used to travel as ONE
    /// inner frame (up to 16 MiB): the host writes nothing to the PTY until the WHOLE frame
    /// reassembles, and under credit-at-consumption a frame ≥ the window would deadlock
    /// (see the progress invariant above). 16 KiB ≪ window/2 streams a paste progressively
    /// and keeps interleave granularity fine. Splitting a byte stream is transparent to the
    /// PTY (frames carry no semantics; order is preserved by the per-channel send gate).
    public static let maxDataMessagePayloadBytes = 16 * 1024

    /// Bound on the host's per-channel PTY-read queue, in bytes. Sized for LATENCY, not
    /// throughput: every byte enqueued-not-yet-sent here is committed AHEAD of fresh output
    /// (a keystroke echo, the post-flood prompt), so on a slow link the queue bound IS the
    /// in-host head-of-line delay. 64 KiB ≈ 44 ms at the measured ~12 Mbps inter-ISP path
    /// (vs ~175 ms at the old 256 KiB) while still amortizing the pause/resume gate to one
    /// NSCondition signal per ~64 KiB drained. The PTY pause → kernel-buffer → shell
    /// backpressure chain (never-drop) is unchanged — only the trigger point moves.
    /// Host-local only (no protocol interaction) → unilaterally safe to tune via
    /// `AISLOPDESK_MUX_HOST_QUEUE`.
    public static let hostQueueCapacityBytes =
        envInt("AISLOPDESK_MUX_HOST_QUEUE", 64 * 1024, min: 8 * 1024, max: 8 * 1024 * 1024)

    /// Cap on a MERGED host output frame (drain-side coalescing), in bytes. The host drain
    /// concatenates immediately-available FIFO chunks into one `.output` frame up to this
    /// cap, amortizing per-frame costs (seq, two encode copies, actor hops, one send) across
    /// a flood's small kernel-sized chunks. MUST stay ≤ ``initialWindowBytes``/2 so a merged
    /// frame can always make window progress (the credit grant threshold is window/2 — a
    /// frame bigger than that can park the sender against a receiver that never re-grants).
    /// Tunable via `AISLOPDESK_MUX_MERGE_CAP`.
    public static let hostMergeCapBytes =
        envInt("AISLOPDESK_MUX_MERGE_CAP", 32 * 1024, min: 4 * 1024, max: 128 * 1024)

    /// Max number of LIVE logical channels (panes) one physical connection may hold open at once
    /// (R6 #6). A hostile/buggy peer can otherwise spam distinct `channelOpen` ids and make the host
    /// `openpty()`+`fork()` a shell per id without bound — a fork-bomb that exhausts fds/processes/RAM.
    /// The host refuses a NEW channel past this cap. 256 is far above any real multi-pane session (a
    /// few dozen panes), so legitimate use never approaches it.
    public static let maxChannelsPerConnection = 256

    /// Env-seamed Int with bounds (the video-path `envInt` discipline): out-of-range or
    /// unparseable values fall back to the shipped default, so a typo can never produce a
    /// degenerate window/queue.
    private static func envInt(_ key: String, _ fallback: Int, min lo: Int, max hi: Int) -> Int {
        guard let s = ProcessInfo.processInfo.environment[key], let v = Int(s), v >= lo, v <= hi
        else { return fallback }
        return v
    }
}
