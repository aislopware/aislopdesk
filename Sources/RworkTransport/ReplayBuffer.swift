import Foundation
import RworkProtocol

/// Host-side replay buffer for lossless reconnect — an Rwork-native port of
/// Eternal Terminal's `BackedWriter`/`BackedReader` over plain TCP.
///
/// ## Why
/// iOS kills the TCP connection a few seconds after backgrounding. To resume
/// **byte-exact** without tmux, the host retains recently-sent `output` messages
/// keyed by their monotonic `Int64` seq. On reconnect the client's
/// `hello.lastReceivedSeq` tells the host which tail to replay (everything with
/// `seq > lastReceivedSeq`).
///
/// This is functionally equivalent to ET's byte-level `BackedWriter` seq, lifted to
/// **per-message** seq (see `docs/20-wire-protocol.md`).
///
/// ## Caps & gates (from `DECISIONS.md` / [18 H])
/// - **64 MiB cap** (`MAX_BACKUP_BYTES`): retained-byte ceiling. Entries already
///   acked (`ack(seq)`) are released first; beyond that the oldest are evicted.
/// - **4 MiB offline gate**: while the client is offline, once buffered bytes pass
///   4 MiB we **pause the PTY drain** (ET `SKIPPED`) instead of growing unbounded —
///   a long background build must not overflow the buffer and lose output. Below the
///   gate we keep buffering (`BUFFERED_ONLY`).
/// - Seq is **`Int64`** (ET proto2's int32 truncates on very long sessions).
/// - **No `CryptoHandler`**: WireGuard already encrypts; the buffer stores raw bytes.
///   Do not reintroduce ET's libsodium secretbox / nonce-reset layer here.
/// - **The host decides `RETURNING_CLIENT`** during the handshake (ET
///   `Connection.cpp`), then replays the tail.
///
/// - Note: Documented seam for WF-2. Signatures are real; bodies are stubs.
public struct ReplayBuffer {
    /// Retained-byte ceiling: 64 MiB.
    public static let maxBackupBytes = 64 * 1024 * 1024

    /// Offline buffering gate: 4 MiB. Above this while offline, pause PTY drain.
    public static let offlineGateBytes = 4 * 1024 * 1024

    /// Action signalled to the PTY relay as output is enqueued.
    public enum DrainState: Sendable, Equatable {
        /// Keep buffering and draining the PTY normally.
        case bufferedOnly
        /// Offline gate exceeded — pause draining the PTY until the client returns.
        case skipped
    }

    /// Highest seq assigned so far (last produced `output.seq`). Starts at 0; the
    /// first output is seq 1.
    public private(set) var highestSeq: Int64 = 0

    /// Highest contiguous seq the client has acked; entries up to here are releasable.
    public private(set) var ackedSeq: Int64 = 0

    public init() {}

    /// Assigns the next monotonic seq (`highestSeq + 1`), retains the payload for
    /// possible replay, and reports whether the PTY relay should keep draining.
    ///
    /// - Returns: the assigned seq and the resulting ``DrainState``.
    public mutating func enqueueOutput(_ bytes: Data) -> (seq: Int64, drain: DrainState) {
        // TODO(WF-2): append to ring keyed by seq; enforce 64MiB cap (release acked
        //   first, then evict oldest); compute offline-gate DrainState.
        highestSeq += 1
        return (highestSeq, .bufferedOnly)
    }

    /// Records a client ack, releasing retained entries with `seq <= seq`.
    public mutating func acknowledge(upTo seq: Int64) {
        // TODO(WF-2): drop retained entries <= seq; advance ackedSeq.
        ackedSeq = max(ackedSeq, seq)
    }

    /// Returns the retained `output` messages with `seq > lastReceivedSeq`, in
    /// order, for replay after reconnect.
    public func replay(after lastReceivedSeq: Int64) -> [WireMessage] {
        // TODO(WF-2): return retained outputs with seq > lastReceivedSeq.
        []
    }
}
