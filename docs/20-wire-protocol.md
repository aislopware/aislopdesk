# 20 — Rwork wire protocol (PATH 1, terminal)

> **STATUS: CURRENT.** Documents the wire format implemented in `Sources/RworkProtocol`
> (WF-1). This is the architectural contract for the PATH 1 byte pipeline. Binding
> decisions it realizes: dual data/control channel + plain TCP + `TCP_NODELAY` + ET-style
> replay-buffer reconnect ([DECISIONS.md](DECISIONS.md), [17](17-native-feel-synthesis.md) §2,
> [18](18-risk-resolutions.md) H). The protocol module is **pure Swift, zero platform
> dependency** (no `Network`, no `Darwin`) so it builds for macOS + iOS and is unit-testable
> in isolation.

## 1. Channels (dual TCP)

A session uses **two** TCP connections, not one:

| `Channel` | Carries | Why separate |
|-----------|---------|--------------|
| `.data`   | `output`, `exit` (host→client); `input` (client→host) | The PTY byte hot path. |
| `.control`| `hello`/`resize`/`ack`/`bye` (client→host); `helloAck`/`title`/`bell` (host→client) | Lifecycle + sizing. |

**Rationale (Zellij lesson, [DECISIONS.md]):** a burst of PTY `output` on the data channel
must not delay a `resize`-ack or a disconnect intent. Putting control messages on their own
TCP connection keeps them head-of-line-independent from output bursts.

`TCP_NODELAY` is set on **both** sockets immediately after connect — this happens in
`RworkTransport`, not in the protocol layer. (Nagle can add up to ~200 ms to single-keystroke
writes.) The framing and decoder are identical on both channels; `WireMessage.channel` is
advisory metadata stating where each message is expected to travel.

## 2. Framing

Every message on either channel is a single length-prefixed frame:

```
[ UInt32 big-endian: payloadLength ][ payload bytes ]
```

- `payloadLength` **excludes** the 4 prefix bytes — it counts only the payload.
- `payload = [ UInt8 messageType ][ message body... ]`.
- A `payloadLength` greater than **16 MiB** (`16 * 1024 * 1024`, `Rwork.maxFramePayloadLength`)
  is rejected with `RworkError.frameTooLarge(_:)` — we never allocate or wait for an
  implausibly large frame.

The body uses **manual binary encoding**. The keystroke/output hot path must **not** use
JSON or `Codable`.

### Streaming decode (`FrameDecoder`)

TCP is a byte stream with no message boundaries: one read may deliver half a frame, three
frames, or a frame split across many reads. `FrameDecoder`:

1. Buffers raw bytes via `append(_:)`.
2. On `nextMessage()`, reads the 4-byte prefix (waiting if fewer than 4 bytes are buffered).
3. Validates the prefix against the 16 MiB cap (throws `frameTooLarge` otherwise).
4. Waits — returning `nil`, **not** an error — until the full payload has arrived.
5. Slices out and decodes exactly one frame, leaving any trailing bytes buffered for the
   next call.

A partial frame is never an error; only a body that is too short for its declared message
type (`truncated`), an unknown type byte (`unknownMessageType`), or invalid contents
(`malformedBody`) are.

## 3. Endianness

**All** multi-byte integers are big-endian ("network byte order") on the wire:
`UInt32` length prefix, `Int64` seq, `Int32` exit code, `UInt16` cols/rows/pixels, `UInt16`
protocol version. The protocol provides its own tiny big-endian read/write helpers
(`BigEndian.swift`); no third-party dependency.

UUIDs (`sessionID`) are sent as their **16 raw bytes** in canonical order (not a string).

## 4. Message table

`messageType` is the first payload byte. Bodies are listed after the type byte.

| Type | Name | Direction | Channel | Body |
|------|------|-----------|---------|------|
| 1  | `output`   | host → client | data    | `Int64 seq` (BE) + remaining bytes = PTY output payload |
| 2  | `exit`     | host → client | data    | `Int32 code` (BE) |
| 3  | `input`    | client → host | data    | remaining bytes = bytes to write to PTY stdin |
| 10 | `hello`    | client → host | control | `UInt16 protocolVersion` + 16-byte `sessionID` (all-zero = NEW) + `Int64 lastReceivedSeq` |
| 11 | `resize`   | client → host | control | `UInt16 cols` + `UInt16 rows` + `UInt16 pxWidth` + `UInt16 pxHeight` |
| 12 | `ack`      | client → host | control | `Int64 seq` (highest contiguous output seq durably received) |
| 13 | `bye`      | client → host | control | (empty) |
| 20 | `helloAck` | host → client | control | 16-byte `sessionID` + `Int64 resumeFromSeq` + `UInt8 returningClient` (0/1) |
| 21 | `title`    | host → client | control | remaining bytes = UTF-8 window/title string |
| 22 | `bell`     | host → client | control | (empty) |

`protocolVersion` is currently **1** (`Rwork.protocolVersion`).

### Field notes

- **`output.seq`** is a **monotonic per-message index starting at 1** — *not* a byte offset.
  See §5.
- **`hello.sessionID`** all-zero (`WireMessage.newSessionID`) requests a brand-new session; a
  non-zero UUID requests resume of that session.
- **`resize`** pixel dimensions are `0` when unknown (cell-only resize); the host maps the
  fields to `TIOCSWINSZ`.
- **`helloAck.returningClient`** is decided **by the host** (see §5), not asserted by the
  client.
- **`title`** payload must be valid UTF-8; a non-UTF-8 body decodes to
  `RworkError.malformedBody`.

## 5. Seq / ack / replay semantics

The host assigns every `output` message a **monotonic `Int64` `seq` starting at 1** — a
per-message index, not a byte count. The replay buffer (implemented in `RworkTransport`,
WF-2) retains un-acked `output` messages so a reconnect is lossless:

- The client sends `ack(seq)` carrying the **highest contiguous** seq it has durably
  received. The host may then release retained entries with `seq <= ack`.
- On reconnect the client sends `hello(lastReceivedSeq:)`. The host replays every retained
  `output` with `seq > lastReceivedSeq`, then resumes live streaming. The result is
  byte-exact resume **without tmux**.
- The host **decides `RETURNING_CLIENT`** (Eternal Terminal `Connection.cpp`): on a `hello`
  with a known non-zero `sessionID` it resumes + replays and answers
  `helloAck(returningClient: true)`; an all-zero or unknown id starts a fresh session
  (`returningClient: false`). `helloAck.resumeFromSeq` tells the client where replay began.

### Replay-buffer caps (WF-2, documented here for the contract)

- **64 MiB** retained-byte ceiling (`ReplayBuffer.maxBackupBytes`; ET `MAX_BACKUP_BYTES`).
- **4 MiB offline gate** (`ReplayBuffer.offlineGateBytes`): while the client is offline, once
  buffered bytes pass 4 MiB the host **pauses the PTY drain** (ET `SKIPPED`) instead of
  growing unbounded; below the gate it keeps buffering (`BUFFERED_ONLY`). A long background
  build must not overflow the buffer and silently lose output.
- Seq is **`Int64`** (ET proto2 used int32, which truncates on very long sessions).
- **No crypto layer.** WireGuard already encrypts; the buffer stores **raw bytes**. ET's
  `CryptoHandler` (libsodium secretbox + nonce reset) is deliberately **not** ported — do not
  reintroduce it ([18](18-risk-resolutions.md) H).

### Equivalence to Eternal Terminal

This design is **functionally equivalent to Eternal Terminal's byte-level `BackedWriter`
sequence number**, lifted from byte offsets to a per-message index. ET tags each chunk of PTY
output with a monotonically increasing sequence and replays the tail after the last
client-acknowledged sequence on reconnect (`recover(lastValidSeq)`); Rwork does the same at
the granularity of one `output` message. The reconnect handshake (`hello.lastReceivedSeq` →
host replays `seq > lastReceivedSeq`) mirrors ET's reconnect path, minus the crypto handler,
over plain TCP inside the WireGuard tunnel.

## 6. Errors (`RworkError`)

| Case | Meaning |
|------|---------|
| `frameTooLarge(Int)` | Length prefix exceeded 16 MiB; associated value is the claimed length. |
| `truncated` | A complete frame's body was shorter than its message type requires (distinct from a partial TCP read, which is not an error). |
| `unknownMessageType(UInt8)` | First payload byte is not a recognized type. |
| `malformedBody(String)` | Right-length body with invalid contents (e.g. bad UTF-8 in `title`); reason string attached. |

## 7. Public API (`RworkProtocol`)

- `enum Channel { case data, control }`
- `enum WireMessage: Equatable, Sendable` — all cases above; `var messageType: UInt8`,
  `var channel: Channel`, `func encode() -> Data` (full frame, prefix + type + body),
  `static let newSessionID: UUID`.
- `struct FrameDecoder` — `init()`, `mutating func append(_ data: Data)`,
  `mutating func nextMessage() throws -> WireMessage?` (handles partial reads + multiple
  frames per append; **not** `Sendable`, lives inside one actor/task).
- `enum RworkError: Error, Equatable, Sendable`.
- `enum Rwork` namespace — `static let protocolVersion: UInt16 = 1`,
  `static let maxFramePayloadLength = 16 * 1024 * 1024`.

`WireMessage`, `Channel`, and `RworkError` are `Sendable`; `FrameDecoder` is a non-`Sendable`
value type by design (it carries the receive buffer for a single connection/channel).
