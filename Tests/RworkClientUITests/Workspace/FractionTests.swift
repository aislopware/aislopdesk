import XCTest
@testable import RworkClientUI

/// Pins the divider-drag op ``PaneNode/settingFractions(at:to:)`` (docs/22 §2.1, §3).
///
/// ### Important contract note (verbatim, NOT clamping)
/// The original WF2 test plan described `settingFractions` as *"clamps to a minimum fraction,
/// redistributes the complement, normalizes to sum ≈ 1"*. The **shipped source does the opposite
/// on purpose**: `settingFractions` is the *pure, exact* model write — it applies the supplied
/// fractions **verbatim** with no clamping and no normalizing, "so a divider drag is exactly
/// representable" (its doc-comment + source author note #5). Clamping to a min fraction and
/// renormalizing are explicitly the **store's** responsibility, layered on top in a later
/// workstream. So these tests assert the verbatim/idempotent/guarded behaviour the code actually
/// has, and the original plan's "clamp + redistribute" wording is recorded as a plan↔source
/// mismatch in the returned notes rather than tested against the pure op (where it would fail).
///
/// What IS asserted:
/// - verbatim application at the root (empty path) and at a nested path,
/// - idempotent re-application (set X then set X again == set X once),
/// - no-op guards: arity mismatch, path that doesn't address a split, out-of-range index,
/// - the store-style clamp-then-redistribute *math* (computed by the test, applied through the
///   verbatim op) yields a sum-1 distribution — proving the op is a faithful sink for whatever the
///   store decides, within a deliberate ε.
final class FractionTests: XCTestCase {

    /// Deliberate ε for fraction float compares.
    private let eps = 1e-9

    private func leaf(_ title: String) -> PaneNode {
        .leaf(PaneID(), PaneSpec(kind: .terminal, title: title))
    }

    // MARK: - Verbatim application at the root

    func testSetFractionsAtRootAppliesVerbatim() {
        let tree = PaneNode.split(.horizontal, children: [leaf("a"), leaf("b")], fractions: [0.5, 0.5])
        let result = tree.settingFractions(at: [], to: [0.2, 0.8])

        guard case let .split(axis, children, fractions) = result else {
            return XCTFail("expected split")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children.count, 2, "structure untouched")
        XCTAssertEqual(fractions[0], 0.2, accuracy: eps, "applied verbatim — no clamp, no normalize")
        XCTAssertEqual(fractions[1], 0.8, accuracy: eps)
    }

    /// Verbatim really means verbatim: an intentionally *non-normalized* input (sum ≠ 1) is stored
    /// unchanged. (Normalizing is the store's job, not this op's.)
    func testSetFractionsAppliesNonNormalizedVerbatim() {
        let tree = PaneNode.split(.vertical, children: [leaf("a"), leaf("b")], fractions: [0.5, 0.5])
        let result = tree.settingFractions(at: [], to: [0.1, 0.1]) // sums to 0.2, deliberately
        guard case let .split(_, _, fractions) = result else { return XCTFail("expected split") }
        XCTAssertEqual(fractions[0], 0.1, accuracy: eps)
        XCTAssertEqual(fractions[1], 0.1, accuracy: eps)
        XCTAssertEqual(fractions.reduce(0, +), 0.2, accuracy: eps, "the pure op does NOT renormalize")
    }

    // MARK: - Verbatim application at a nested path

    func testSetFractionsAtNestedPath() {
        // horizontal[ a , vertical[ b , c ] ]
        // The inner vertical split is addressed by path [1].
        let inner = PaneNode.split(.vertical, children: [leaf("b"), leaf("c")], fractions: [0.5, 0.5])
        let tree = PaneNode.split(.horizontal, children: [leaf("a"), inner], fractions: [0.5, 0.5])

        let result = tree.settingFractions(at: [1], to: [0.3, 0.7])

        guard case let .split(_, outerChildren, outerFractions) = result else {
            return XCTFail("expected outer split")
        }
        // Outer fractions untouched.
        XCTAssertEqual(outerFractions[0], 0.5, accuracy: eps)
        XCTAssertEqual(outerFractions[1], 0.5, accuracy: eps)
        guard case let .split(innerAxis, _, innerFractions) = outerChildren[1] else {
            return XCTFail("expected inner split at path [1]")
        }
        XCTAssertEqual(innerAxis, .vertical)
        XCTAssertEqual(innerFractions[0], 0.3, accuracy: eps, "nested fractions updated verbatim")
        XCTAssertEqual(innerFractions[1], 0.7, accuracy: eps)
    }

    // MARK: - Idempotency

    func testSetFractionsIsIdempotent() {
        let tree = PaneNode.split(.horizontal, children: [leaf("a"), leaf("b"), leaf("c")],
                                  fractions: [1.0/3, 1.0/3, 1.0/3])
        let target: [Double] = [0.25, 0.25, 0.5]
        let once = tree.settingFractions(at: [], to: target)
        let twice = once.settingFractions(at: [], to: target)
        XCTAssertEqual(once, twice, "applying the same fractions again is a no-op (idempotent)")
    }

    // MARK: - No-op guards

    /// Arity mismatch (wrong number of fractions for the split) is a no-op.
    func testSetFractionsArityMismatchIsNoOp() {
        let tree = PaneNode.split(.horizontal, children: [leaf("a"), leaf("b")], fractions: [0.5, 0.5])
        let result = tree.settingFractions(at: [], to: [0.3, 0.3, 0.4]) // 3 fractions for 2 children
        XCTAssertEqual(result, tree, "arity mismatch must not mutate the tree")
    }

    /// An empty path on a node that is a LEAF (not a split) is a no-op.
    func testSetFractionsOnLeafIsNoOp() {
        let tree = leaf("solo")
        let result = tree.settingFractions(at: [], to: [0.5, 0.5])
        XCTAssertEqual(result, tree, "a leaf has no fractions to set")
    }

    /// A path that recurses into a leaf (non-split mid-path) is a no-op.
    func testSetFractionsPathThroughLeafIsNoOp() {
        // path [0] addresses child 0, which is a leaf — cannot set fractions there.
        let tree = PaneNode.split(.horizontal, children: [leaf("a"), leaf("b")], fractions: [0.5, 0.5])
        let result = tree.settingFractions(at: [0, 0], to: [0.5, 0.5])
        XCTAssertEqual(result, tree, "descending into a leaf must no-op")
    }

    /// An out-of-range first index is a no-op.
    func testSetFractionsOutOfRangeIndexIsNoOp() {
        let tree = PaneNode.split(.horizontal, children: [leaf("a"), leaf("b")], fractions: [0.5, 0.5])
        let result = tree.settingFractions(at: [5], to: [0.5, 0.5])
        XCTAssertEqual(result, tree, "index outside children.indices must no-op")
    }

    // MARK: - Store-style clamp-then-redistribute, applied THROUGH the verbatim op

    /// The pure op is a faithful sink: whatever distribution the store computes (here: clamp each
    /// child to a min fraction, then redistribute the complement proportionally over the rest) lands
    /// exactly, and the result sums to ~1 within ε. This proves the op + the *caller's* clamp math
    /// compose into the behaviour the original plan described — with the clamp living in the caller,
    /// as the source intends.
    func testStoreClampRedistributeMathLandsExactlyAndSumsToOne() {
        let tree = PaneNode.split(.horizontal, children: [leaf("a"), leaf("b"), leaf("c")],
                                  fractions: [1.0/3, 1.0/3, 1.0/3])

        // A divider drag wants child 0 crushed to ~1%. The store clamps it to a 10% minimum and
        // redistributes the remaining 90% proportionally across the other two (which were equal).
        let minFraction = 0.10
        let desired: [Double] = [0.01, 0.495, 0.495] // pre-clamp intent
        let clamped = clampAndRedistribute(desired, minFraction: minFraction)

        // Sanity on the test's own math first.
        XCTAssertEqual(clamped.reduce(0, +), 1.0, accuracy: eps, "store math normalizes to 1")
        XCTAssertGreaterThanOrEqual(clamped[0], minFraction - eps, "first child floored to the min")

        let result = tree.settingFractions(at: [], to: clamped)
        guard case let .split(_, _, fractions) = result else { return XCTFail("expected split") }
        XCTAssertEqual(fractions.count, 3)
        XCTAssertEqual(fractions[0], clamped[0], accuracy: eps, "op stores the store-computed value verbatim")
        XCTAssertEqual(fractions[1], clamped[1], accuracy: eps)
        XCTAssertEqual(fractions[2], clamped[2], accuracy: eps)
        XCTAssertEqual(fractions.reduce(0, +), 1.0, accuracy: eps, "final distribution sums to ~1")
    }

    // MARK: - Test-local store-style helper (the clamp the PURE op deliberately does not do)

    /// Clamps every fraction below `minFraction` up to `minFraction`, then redistributes the
    /// complement proportionally over the children that are above the floor, returning a
    /// sum-1 distribution. This mirrors the clamp the store layers on top of the verbatim op; it
    /// lives in the test, not the model, on purpose.
    private func clampAndRedistribute(_ fractions: [Double], minFraction: Double) -> [Double] {
        var result = fractions
        var floored = Set<Int>()
        for (i, f) in result.enumerated() where f < minFraction {
            result[i] = minFraction
            floored.insert(i)
        }
        let floorTotal = Double(floored.count) * minFraction
        let remaining = max(1.0 - floorTotal, 0)
        let freeIndices = result.indices.filter { !floored.contains($0) }
        let freeTotal = freeIndices.reduce(0.0) { $0 + fractions[$1] }
        if freeTotal > eps {
            for i in freeIndices {
                result[i] = remaining * (fractions[i] / freeTotal)
            }
        }
        return result
    }
}
