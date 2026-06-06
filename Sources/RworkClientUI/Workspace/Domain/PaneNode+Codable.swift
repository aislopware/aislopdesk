import Foundation

// MARK: - Hand-written, discriminated Codable for the recursive tree

/// ``PaneNode`` is the persistence format (docs/22 §6), and a recursive enum is a *silent-
/// corruption surface*: a synthesized `Codable` for an `indirect enum` produces an opaque,
/// position-keyed JSON shape that is fragile to reorder and impossible to review or version. So
/// the conformance is **hand-written with an explicit `type` discriminator** — `"leaf"` /
/// `"split"` — and `encode`/`decode` are exact inverses, preserving deep nesting and every
/// fraction byte-for-byte.
///
/// ### Wire shape (stable, reviewable)
/// ```json
/// // leaf
/// { "type": "leaf", "id": { "raw": "<uuid>" }, "spec": { … } }
/// // split
/// { "type": "split", "axis": "horizontal",
///   "children": [ <node>, <node>, … ],
///   "fractions": [ 0.5, 0.5 ] }
/// ```
/// `PaneID` / `TabID` / `PaneSpec` keep their synthesized `Codable` (flat structs, safe to
/// synthesize); only the recursive enum is hand-rolled here.
///
/// The `Codable` conformance itself is declared on this extension (rather than on the `enum` in
/// `PaneNode.swift`) so the hand-written `encode`/`init(from:)` live next to the discriminator
/// definition — there is no synthesized conformance to suppress.
extension PaneNode: Codable {
    /// The discriminator values. String-raw so the JSON is human-readable and an unknown value
    /// throws a clean `dataCorrupted` (decode-fail gracefully, never silently mis-decode).
    private enum NodeType: String, Codable {
        case leaf
        case split
    }

    private enum CodingKeys: String, CodingKey {
        case type
        // leaf
        case id
        case spec
        // split
        case axis
        case children
        case fractions
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .leaf(id, spec):
            try container.encode(NodeType.leaf, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(spec, forKey: .spec)
        case let .split(axis, children, fractions):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(axis, forKey: .axis)
            try container.encode(children, forKey: .children)
            try container.encode(fractions, forKey: .fractions)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)
        switch type {
        case .leaf:
            let id = try container.decode(PaneID.self, forKey: .id)
            let spec = try container.decode(PaneSpec.self, forKey: .spec)
            self = .leaf(id, spec)
        case .split:
            let axis = try container.decode(SplitAxis.self, forKey: .axis)
            let children = try container.decode([PaneNode].self, forKey: .children)
            let fractions = try container.decode([Double].self, forKey: .fractions)
            // Structural sanity: a decoded split must keep the parallel-array invariant. A
            // mismatch is corruption — fail loudly here so the store's decode-failure fallback
            // (default workspace) fires, rather than letting an inconsistent tree reach the
            // layout solver.
            guard children.count == fractions.count else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "PaneNode.split: children.count (\(children.count)) != fractions.count (\(fractions.count))"
                    )
                )
            }
            // Structural sanity #2 (R8 #6): a split must have ≥ 2 children. Every in-operation tree op
            // maintains this (collapse() folds a 1-child split into its child), so a 0/1-child split can
            // only come from a corrupt/old persisted tree — and it would later trip `collapsing()`'s
            // `precondition(!children.isEmpty)` and CRASH the app. Reject it here so the store's
            // decode-failure fallback (default workspace) fires instead.
            guard children.count >= 2 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "PaneNode.split: a split must have >= 2 children, got \(children.count)"
                    )
                )
            }
            self = .split(axis, children: children, fractions: fractions)
        }
    }
}
