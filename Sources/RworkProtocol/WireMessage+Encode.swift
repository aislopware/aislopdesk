import Foundation

extension WireMessage {
    /// Number of bytes occupied by a UUID on the wire (its 16 raw bytes).
    static let sessionIDByteCount = 16

    /// All-zero UUID used in `hello` to request a brand-new session.
    public static let newSessionID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Encodes this message into a complete frame, ready to write to a socket:
    /// `[UInt32 BE payloadLength][UInt8 messageType][body...]`.
    ///
    /// `payloadLength` counts `messageType` + `body` and excludes the 4 prefix
    /// bytes — exactly what ``FrameDecoder`` expects.
    public func encode() -> Data {
        var body = Data()
        body.append(messageType)

        switch self {
        case let .output(seq, bytes):
            body.appendBE(seq)
            body.append(bytes)

        case let .exit(code):
            body.appendBE(code)

        case let .input(bytes):
            body.append(bytes)

        case let .hello(protocolVersion, sessionID, lastReceivedSeq):
            body.appendBE(protocolVersion)
            body.append(sessionID.dataBytes)
            body.appendBE(lastReceivedSeq)

        case let .resize(cols, rows, pxWidth, pxHeight):
            body.appendBE(cols)
            body.appendBE(rows)
            body.appendBE(pxWidth)
            body.appendBE(pxHeight)

        case let .ack(seq):
            body.appendBE(seq)

        case .bye:
            break // empty body

        case let .helloAck(sessionID, resumeFromSeq, returningClient):
            body.append(sessionID.dataBytes)
            body.appendBE(resumeFromSeq)
            body.append(returningClient ? 1 : 0)

        case let .title(string):
            body.append(Data(string.utf8))

        case .bell:
            break // empty body

        case let .commandStatus(status):
            // Tag byte discriminates the two cases; `.idle`'s body is FIXED-SIZE (no
            // length-prefix needed) — a presence flag + a manual BE Int32 exit + a BE
            // UInt32 duration, matching the manual-binary style (never JSON/Codable).
            switch status {
            case .running:
                body.append(0)
            case let .idle(exitCode, durationMS):
                body.append(1)
                body.append(exitCode != nil ? 1 : 0)   // hasExit
                body.appendBE(exitCode ?? 0)            // Int32 BE (0 when absent)
                body.appendBE(durationMS)               // UInt32 BE
            }
        }

        // Frame = 4-byte BE length prefix (covers type + body) + the payload.
        var frame = Data(capacity: 4 + body.count)
        frame.appendBE(UInt32(body.count))
        frame.append(body)
        return frame
    }
}

extension UUID {
    /// The UUID's 16 raw bytes as `Data`, in canonical order.
    var dataBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }

    /// Builds a UUID from exactly 16 raw bytes. Returns `nil` otherwise.
    init?(dataBytes data: Data) {
        guard data.count == 16 else { return nil }
        var raw = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { dest in
            _ = data.copyBytes(to: dest)
        }
        self.init(uuid: raw)
    }
}
