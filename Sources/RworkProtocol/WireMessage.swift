import Foundation

/// The two TCP connections that make up an Rwork session.
///
/// Per `DECISIONS.md`, a session uses **two** TCP connections so that a burst of
/// PTY output on the data channel cannot delay a resize / disconnect intent on the
/// control channel (the Zellij lesson). `TCP_NODELAY` is set on both, but in
/// `RworkTransport` — not here; `RworkProtocol` is transport-agnostic.
///
/// This enum is advisory metadata: ``WireMessage/channel`` states which connection
/// a message is expected to travel on. The framing and decoder are identical on
/// both channels.
public enum Channel: Sendable, Equatable {
    /// PTY byte stream: `output`, `exit` (host -> client) and `input` (client -> host).
    case data
    /// Session lifecycle & sizing: `hello`/`resize`/`ack`/`bye` (client -> host) and
    /// `helloAck`/`title`/`bell` (host -> client).
    case control
}

/// One decoded Rwork protocol message.
///
/// Wire layout of a frame is `[UInt32 BE payloadLength][UInt8 messageType][body...]`
/// where `payloadLength` counts `messageType` + `body` (it excludes the 4 prefix
/// bytes). All multi-byte integers are big-endian. The keystroke/output hot path
/// uses this manual binary encoding — **never** JSON/`Codable`.
///
/// `WireMessage` is `Sendable` so decoded messages can cross actor / task boundaries
/// (the TCP receive loop hands them to the `@MainActor` renderer).
public enum WireMessage: Equatable, Sendable {
    // MARK: DATA channel, host -> client

    /// PTY output. `seq` is a **monotonic per-message index starting at 1** (NOT a
    /// byte offset); `bytes` is the raw VT payload. See `docs/20-wire-protocol.md`
    /// for the seq/ack/replay contract.
    case output(seq: Int64, bytes: Data)

    /// Child process exited with the given status `code`.
    case exit(code: Int32)

    // MARK: DATA channel, client -> host

    /// Bytes to write to the PTY's stdin (keystrokes, pasted text, etc.).
    case input(Data)

    // MARK: CONTROL channel, client -> host

    /// Session handshake. `sessionID` all-zero means "open a NEW session";
    /// a non-zero UUID means "resume this session". `lastReceivedSeq` is the
    /// highest contiguous output seq the client already has, so the host can
    /// replay only `seq > lastReceivedSeq`.
    case hello(protocolVersion: UInt16, sessionID: UUID, lastReceivedSeq: Int64)

    /// Terminal resize. Character cells (`cols`/`rows`) plus optional pixel
    /// dimensions (`pxWidth`/`pxHeight`, 0 if unknown) — maps to `TIOCSWINSZ`.
    case resize(cols: UInt16, rows: UInt16, pxWidth: UInt16, pxHeight: UInt16)

    /// Acknowledge receipt of output up to and including `seq` (the highest
    /// contiguous output seq the client has durably received). Lets the host
    /// release replay-buffer entries.
    case ack(seq: Int64)

    /// Client is leaving cleanly (empty body).
    case bye

    // MARK: CONTROL channel, host -> client

    /// Handshake reply. `sessionID` is the authoritative session id (echoes the
    /// client's, or a freshly minted one for a new session). `resumeFromSeq` is the
    /// seq the host will replay from. `returningClient` is **decided by the host**
    /// (true = this is a recognized resuming client; the host replays the tail).
    case helloAck(sessionID: UUID, resumeFromSeq: Int64, returningClient: Bool)

    /// Window/title text (UTF-8). Driven by OSC 0/2 from the child.
    case title(String)

    /// Terminal bell (empty body).
    case bell

    /// The on-wire message-type byte (`UInt8`) for this case.
    public var messageType: UInt8 {
        switch self {
        case .output: return 1
        case .exit: return 2
        case .input: return 3
        case .hello: return 10
        case .resize: return 11
        case .ack: return 12
        case .bye: return 13
        case .helloAck: return 20
        case .title: return 21
        case .bell: return 22
        }
    }

    /// The channel this message is expected to travel on (advisory; see ``Channel``).
    public var channel: Channel {
        switch self {
        case .output, .exit, .input:
            return .data
        case .hello, .resize, .ack, .bye, .helloAck, .title, .bell:
            return .control
        }
    }
}
