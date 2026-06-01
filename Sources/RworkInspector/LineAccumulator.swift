import Foundation

/// Splits an incrementally-growing byte stream into complete `\n`-terminated lines.
///
/// This is the **pure, deterministic core** of the tailer (the part that must "not
/// miss a line and not double-emit"). The tailer feeds it raw byte deltas as the file
/// grows; it returns only *complete* lines and holds back a partial trailing line
/// until its newline arrives. Pulling this logic out of the I/O lets us test the hard
/// part (partial line, burst, multi-byte boundary) with zero file system.
public struct LineAccumulator {
    /// Bytes received but not yet terminated by a newline (the partial tail).
    private var pending = Data()

    public init() {}

    /// Appends a delta and returns every newly-completed line (newline stripped).
    /// A trailing partial line (no `\n` yet) stays buffered and is NOT returned —
    /// it surfaces only once its terminating newline arrives, so a line written in
    /// two writes ("abc" then "def\n") emits exactly once, as "abcdef".
    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        return drainCompleteLines()
    }

    /// Resets the accumulator (used on file truncation/rotation: the byte offset
    /// restarts, so any half-line we were holding is stale and must be dropped).
    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    private mutating func drainCompleteLines() -> [String] {
        var lines: [String] = []
        let newline = UInt8(ascii: "\n")
        while let nlIndex = pending.firstIndex(of: newline) {
            // `pending` may be a non-zero-based slice after removeSubrange; index math
            // is relative to its own startIndex via firstIndex, which is safe here.
            let lineData = pending[pending.startIndex ..< nlIndex]
            // Strip a trailing CR for CRLF tolerance.
            var bytes = Data(lineData)
            if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
            if let line = String(data: bytes, encoding: .utf8) {
                lines.append(line)
            }
            // Drop the consumed line + its newline.
            pending.removeSubrange(pending.startIndex ... nlIndex)
        }
        return lines
    }

    /// Bytes currently held back as an incomplete line (for tests / introspection).
    public var bufferedByteCount: Int { pending.count }
}
