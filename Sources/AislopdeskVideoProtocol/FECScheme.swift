import CAislopdeskFFI
import Foundation

/// Forward-error-correction over a frame's data fragments.
///
/// doc 17 §3.6 calls for ~20% parity per frame (Sunshine default). The live engine is the
/// NEON-backed Reed-Solomon erasure codec in the Rust core (`aislopdesk-core::fec`), driven over
/// the `aisd_fec_*` C ABI: ``RustReedSolomonFEC`` is the production ``FECScheme``. With `m == 1`
/// (one parity per group) it is **byte-identical** to the legacy XOR/length-prefix wire format, so
/// a mixed fleet still interoperates and the golden vectors are unchanged. Multi-loss (`m >= 2`)
/// activation is gated behind a later workflow; v1 ships `m == 1`.
///
/// Contract: ``parity(forDataFragments:)`` produces parity fragments from the frame's data
/// fragments; ``recover(dataFragments:parityFragments:)`` fills any `nil` (lost) data fragment it
/// can, returning the repaired array (still possibly holding `nil` for unrecoverable losses, which
/// the caller escalates to request-recovery).
public protocol FECScheme: Sendable {
    /// The DEFAULT group size: how many data fragments share one parity fragment when no explicit
    /// per-frame group size is supplied. With `groupSize = 5` the overhead is 1/5 = 20% parity,
    /// matching the doc-17 target. WF-4 adaptive FEC drives a per-frame group size through the
    /// `groupSize:`-parameterized methods; this value is the tier-0 / convenience default.
    var groupSize: Int { get }

    /// Computes parity fragments for `dataFragments`, in group order, grouping by `groupSize`.
    func parity(forDataFragments dataFragments: [Data], groupSize: Int) -> [Data]

    /// Attempts to recover lost (`nil`) data fragments using the parity fragments, grouping by
    /// `groupSize`. Entries that cannot be recovered remain `nil`.
    func recover(dataFragments: [Data?], parityFragments: [Data?], groupSize: Int) -> [Data?]
}

public extension FECScheme {
    /// Convenience: parity using the scheme's configured default ``groupSize``. Keeps pre-WF-4
    /// callers (no explicit group size) compiling and behaving identically.
    func parity(forDataFragments dataFragments: [Data]) -> [Data] {
        parity(forDataFragments: dataFragments, groupSize: groupSize)
    }

    /// Convenience: recover using the scheme's configured default ``groupSize``.
    func recover(dataFragments: [Data?], parityFragments: [Data?]) -> [Data?] {
        recover(dataFragments: dataFragments, parityFragments: parityFragments, groupSize: groupSize)
    }
}

/// The production FEC scheme: the Rust core's NEON-backed Reed-Solomon erasure codec, reached over
/// the `aisd_fec_*` C ABI. Each group of `groupSize` data fragments produces `m` parity fragments
/// and recovers up to `m` losses per group.
///
/// **v1 ships `m == 1`**, which the core special-cases to plain XOR parity — the parity bytes and
/// the recovered bytes are bit-for-bit the legacy ``XORParityFEC`` length-prefixed XOR (the
/// `aislopdesk-core` golden vectors anchor this), so the on-wire datagrams are byte-identical to
/// the pre-port stream and a mixed fleet interoperates. The XOR path still routes through the GF
/// backend, so on Apple Silicon the accumulate is NEON-vectorised.
///
/// **Dynamic group size.** The codec is constructed ONCE (`aisd_fec_codec_new(k, m)`), but the
/// host/client drive it with a PER-FRAME group size (``AdaptiveFECPolicy/groupSize(forTier:default:)``,
/// which varies by tier — e.g. 2, 3, 5, 10). For `m == 1` there is no matrix, so the core honours
/// the per-call group size EXACTLY (no clamp to `k`), exactly matching the old Swift XOR for any
/// group size. The codec is therefore built with `k == groupSize` for clarity, but a per-call size
/// larger than `k` (a heavier adaptive tier) is still grouped at the requested width.
///
/// Owns a Rust codec handle, so this is a `final class` with a `deinit` that frees it. The handle
/// is immutable after construction and the codec is pure (no shared mutation), so it is safe to use
/// concurrently — marked `@unchecked Sendable` because the `OpaquePointer` is not auto-`Sendable`.
public final class RustReedSolomonFEC: FECScheme, @unchecked Sendable {
    public let groupSize: Int
    /// The parity-shard count per group (`m`). v1 is always 1 (XOR-equivalent, wire-identical).
    public let parityCount: Int
    /// The owned Rust codec handle (`AisdFecCodec *`). Freed in `deinit`.
    private let codec: OpaquePointer

    /// Builds an `[n = k + m, k]` Reed-Solomon codec.
    ///
    /// - Parameters:
    ///   - groupSize: data fragments per group (`k`). Default 5 ⇒ 20% parity at `m == 1`.
    ///   - parityCount: parity fragments per group (`m`). Default 1 (XOR-equivalent, byte-identical
    ///     to the legacy wire). Values `>= 2` enable multi-loss recovery (a later workflow).
    public init(groupSize: Int = 5, parityCount: Int = 1) {
        precondition(groupSize >= 1, "groupSize must be >= 1")
        precondition(parityCount >= 1, "parityCount must be >= 1")
        precondition(groupSize + parityCount <= 255, "groupSize + parityCount must be <= 255 (GF(2^8))")
        self.groupSize = groupSize
        self.parityCount = parityCount
        // `aisd_fec_codec_new` returns null ONLY for an invalid config, which the preconditions
        // above already rule out — so the force-unwrap is unreachable for valid arguments.
        guard let handle = aisd_fec_codec_new(groupSize, parityCount) else {
            preconditionFailure("aisd_fec_codec_new returned null for a validated (k=\(groupSize), m=\(parityCount))")
        }
        codec = handle
    }

    deinit { aisd_fec_codec_free(codec) }

    public func parity(forDataFragments dataFragments: [Data], groupSize: Int) -> [Data] {
        let groupSize = max(1, groupSize) // defensive floor: a non-positive size must never trap.
        return RustFECBridge.parity(codec: codec, dataFragments: dataFragments, groupSize: groupSize)
    }

    public func recover(dataFragments: [Data?], parityFragments: [Data?], groupSize: Int) -> [Data?] {
        let groupSize = max(1, groupSize) // defensive floor (matches `parity`).
        return RustFECBridge.recover(
            codec: codec,
            dataFragments: dataFragments,
            parityFragments: parityFragments,
            groupSize: groupSize,
        )
    }
}

/// Compatibility alias: the legacy name now maps to the Rust-backed Reed-Solomon scheme so the many
/// `XORParityFEC(...)` construction/test sites keep building UNCHANGED while the live FEC engine is
/// the NEON-backed Rust core. `m == 1` keeps the wire byte-identical to the old native Swift XOR.
public typealias XORParityFEC = RustReedSolomonFEC

/// The `aisd_fec_*` C-ABI marshaling for the FEC path. All `import CAislopdeskFFI` for FEC is
/// contained here; ``RustReedSolomonFEC`` calls these to drive the Rust core's codec. The previous
/// native Swift XOR/length-prefix math is DELETED — the Rust core (`aislopdesk-core::fec`) is the
/// single source of truth, with `m == 1` byte-identical to the legacy wire.
enum RustFECBridge {
    /// Computes the parity shards for `dataFragments`, grouping by `groupSize`, by marshaling the
    /// shards as a borrowed `AisdBytes` array into `aisd_fec_parity` and copying the owned result
    /// array out into `[Data]`. Wraps `aisd_fec_parity` / `aisd_bytes_array_free`.
    static func parity(codec: OpaquePointer, dataFragments: [Data], groupSize: Int) -> [Data] {
        guard !dataFragments.isEmpty else { return [] }
        // Borrow each shard's bytes for the duration of the call (no copy). Nested `withUnsafeBytes`
        // closures keep every backing buffer alive while the C ABI reads them.
        return withBorrowedShards(dataFragments) { borrowed in
            var out = AisdBytesArray()
            let status = borrowed.withUnsafeBufferPointer { buf in
                aisd_fec_parity(codec, buf.baseAddress, buf.count, groupSize, &out)
            }
            guard status == AISD_OK else { return [] }
            defer { aisd_bytes_array_free(&out) }
            return collectArray(out)
        }
    }

    /// Recovers recoverable holes in `dataFragments` (a `nil` entry is a hole) using
    /// `parityFragments`, grouping by `groupSize`. Marshals the present/hole masks + borrowed bytes
    /// into `aisd_fec_recover`, then copies each Rust-recovered shard back into the result, freeing
    /// each recovered `AisdBytes`. Wraps `aisd_fec_recover` / `aisd_bytes_free`.
    static func recover(
        codec: OpaquePointer,
        dataFragments: [Data?],
        parityFragments: [Data?],
        groupSize: Int,
    ) -> [Data?] {
        var result = dataFragments
        let dataCount = dataFragments.count
        guard dataCount > 0 else { return result }

        // Present masks: 1 = the shard carries valid bytes, 0 = a hole to repair. A hole is told
        // apart from a legitimately-empty present shard by the mask (never by "empty bytes").
        let dataPresent: [UInt8] = dataFragments.map { $0 == nil ? 0 : 1 }
        let parityPresent: [UInt8] = parityFragments.map { $0 == nil ? 0 : 1 }
        // Present shards carry their bytes; holes carry empty (the mask says they are absent).
        let dataBytes: [Data] = dataFragments.map { $0 ?? Data() }
        let parityBytes: [Data] = parityFragments.map { $0 ?? Data() }
        let parityCount = parityFragments.count

        withBorrowedShards(dataBytes) { dataBorrowed in
            withBorrowedShards(parityBytes) { parityBorrowed in
                // `data` is read AND written by the C ABI (recovered holes become owned buffers),
                // so it is a mutable copy of the borrowed views.
                var data = dataBorrowed
                var recovered = [UInt8](repeating: 0, count: dataCount)
                let status = data.withUnsafeMutableBufferPointer { dataPtr in
                    dataPresent.withUnsafeBufferPointer { dpPtr in
                        parityBorrowed.withUnsafeBufferPointer { parPtr in
                            parityPresent.withUnsafeBufferPointer { ppPtr in
                                recovered.withUnsafeMutableBufferPointer { recPtr in
                                    aisd_fec_recover(
                                        codec,
                                        dataPtr.baseAddress,
                                        dpPtr.baseAddress,
                                        dataCount,
                                        parPtr.baseAddress,
                                        ppPtr.baseAddress,
                                        parityCount,
                                        groupSize,
                                        recPtr.baseAddress,
                                    )
                                }
                            }
                        }
                    }
                }
                guard status == AISD_OK else { return }
                // Copy each recovered hole's bytes out into the result and free the Rust buffer
                // (the C ABI wrote a fresh Rust-owned `AisdBytes` into `data[i]` for each fill).
                for i in 0..<dataCount where recovered[i] != 0 {
                    result[i] = copyOut(data[i])
                    aisd_bytes_free(data[i])
                }
            }
        }
        return result
    }

    // MARK: Marshaling helpers

    /// Runs `body` with `fragments` exposed as a borrowed `[AisdBytes]` (each `{ptr,len,cap:0}`
    /// pointing INTO the corresponding `Data`'s storage). Recurses so EVERY `Data`'s
    /// `withUnsafeBytes` stays open for the whole call — the C ABI never frees these (borrowed in).
    private static func withBorrowedShards<R>(_ fragments: [Data], _ body: ([AisdBytes]) -> R) -> R {
        var borrowed = [AisdBytes]()
        borrowed.reserveCapacity(fragments.count)
        return build(fragments, index: 0, into: &borrowed, body)
    }

    /// Recursive worker for ``withBorrowedShards(_:_:)``: opens each `Data`'s storage in turn,
    /// appending a borrowed `AisdBytes`, then invokes `body` once all are live.
    private static func build<R>(
        _ fragments: [Data],
        index: Int,
        into borrowed: inout [AisdBytes],
        _ body: ([AisdBytes]) -> R,
    ) -> R {
        if index == fragments.count { return body(borrowed) }
        let data = fragments[index]
        if data.isEmpty {
            borrowed.append(AisdBytes(ptr: nil, len: 0, cap: 0))
            return build(fragments, index: index + 1, into: &borrowed, body)
        }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> R in
            // The pointer is borrowed for the call only; cap 0 marks it caller-owned (never freed).
            let ptr = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
            borrowed.append(AisdBytes(ptr: ptr, len: raw.count, cap: 0))
            return build(fragments, index: index + 1, into: &borrowed, body)
        }
    }

    /// Copies an owned/returned `AisdBytesArray` out into `[Data]` (the array itself is freed by the
    /// caller's `aisd_bytes_array_free`).
    private static func collectArray(_ array: AisdBytesArray) -> [Data] {
        // Bind the C `count` to a local Int up front (the `AisdBytesArray` struct has no `isEmpty`).
        let count = array.count
        guard let items = array.items, count > 0 else { return [] }
        var out: [Data] = []
        out.reserveCapacity(count)
        for i in 0..<count { out.append(copyOut(items[i])) }
        return out
    }

    /// Copies an `AisdBytes`' payload into an owned `Data` (empty for the null/zero buffer).
    private static func copyOut(_ bytes: AisdBytes) -> Data {
        guard let ptr = bytes.ptr, bytes.len > 0 else { return Data() }
        return Data(bytes: ptr, count: bytes.len)
    }
}
