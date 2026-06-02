import XCTest
@testable import RworkClientUI

/// Exercises the **pure tree of intent** — every structural op on ``PaneNode`` is a deterministic
/// function returning a new tree, so these tests need no client, no async, and no view (docs/22
/// §1.2, §8). They pin the load-bearing contract that the layout solver, focus resolver, and store
/// reconcile all depend on:
///
/// - **split** evens fractions, and applies the *flatten rule* (same-axis split of a direct child
///   inserts a sibling N→N+1 rather than nesting; cross-axis nests; a bare leaf wraps in a 2-way).
/// - **closing** collapses singleton splits, renormalizes surviving fractions, and returns `nil`
///   only when the last leaf in the whole tree closes.
/// - **allLeafIDs** is canonical pre-order.
/// - **updatingSpec** mutates *only* the target leaf.
///
/// Identities are pinned with `PaneID(raw:)` so assertions are exact; specs use distinct titles so
/// a leaf can be located by spec after a structural rewrite.
final class PaneNodeTests: XCTestCase {

    // MARK: - Fixtures

    /// A deterministic ε for fraction sums (renormalize / even both produce 1.0 modulo FP).
    private let frac = 1e-9

    /// A pinned leaf id + a terminal spec titled `title` (so `spec(for:)` can find it later).
    private func leaf(_ title: String) -> (PaneID, PaneSpec) {
        (PaneID(), PaneSpec(kind: .terminal, title: title))
    }

    /// A pinned leaf with a caller-supplied id (for cross-tree identity assertions).
    private func leaf(_ id: PaneID, _ title: String) -> (PaneID, PaneSpec) {
        (id, PaneSpec(kind: .terminal, title: title))
    }

    /// Asserts a fractions array sums to ~1 and every entry is within ε of the expected even share.
    private func assertEven(_ fractions: [Double], count: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fractions.count, count, "arity", file: file, line: line)
        XCTAssertEqual(fractions.reduce(0, +), 1.0, accuracy: frac, "fractions sum to 1", file: file, line: line)
        for f in fractions {
            XCTAssertEqual(f, 1.0 / Double(count), accuracy: frac, "even share", file: file, line: line)
        }
    }

    // MARK: - allLeafIDs (canonical pre-order)

    func testAllLeafIDsSingleLeaf() {
        let a = leaf("a")
        let tree = PaneNode.leaf(a.0, a.1)
        XCTAssertEqual(tree.allLeafIDs(), [a.0])
        XCTAssertEqual(tree.leafCount, 1)
    }

    /// Pre-order = depth-first, children left-to-right. This ordering is the contract the compact
    /// carousel and focus cycle read, so it must be exact, not just a set.
    func testAllLeafIDsPreOrderDeepNesting() {
        let a = leaf("a"), b = leaf("b"), c = leaf("c"), d = leaf("d")
        // horizontal[ a , vertical[ b , horizontal[ c , d ] ] ]
        let tree = PaneNode.split(.horizontal, children: [
            .leaf(a.0, a.1),
            .split(.vertical, children: [
                .leaf(b.0, b.1),
                .split(.horizontal, children: [.leaf(c.0, c.1), .leaf(d.0, d.1)], fractions: [0.5, 0.5]),
            ], fractions: [0.5, 0.5]),
        ], fractions: [0.5, 0.5])

        XCTAssertEqual(tree.allLeafIDs(), [a.0, b.0, c.0, d.0], "pre-order, left-to-right")
        XCTAssertEqual(tree.leafCount, 4)
    }

    // MARK: - Queries: spec(for:) / contains(_:)

    func testSpecLookupAndContains() {
        let a = leaf("alpha"), b = leaf("beta")
        let tree = PaneNode.split(.horizontal, children: [.leaf(a.0, a.1), .leaf(b.0, b.1)], fractions: [0.5, 0.5])

        XCTAssertEqual(tree.spec(for: a.0)?.title, "alpha")
        XCTAssertEqual(tree.spec(for: b.0)?.title, "beta")
        XCTAssertTrue(tree.contains(a.0))
        XCTAssertTrue(tree.contains(b.0))

        let absent = PaneID()
        XCTAssertNil(tree.spec(for: absent))
        XCTAssertFalse(tree.contains(absent))
    }

    // MARK: - splitting: bare leaf wraps in an even 2-way split

    func testSplitBareLeafHorizontalWrapsInTwoWay() {
        let a = leaf("a")
        let nl = leaf("a2")
        let tree = PaneNode.leaf(a.0, a.1)

        let result = tree.splitting(a.0, axis: .horizontal, newLeaf: nl)

        guard case let .split(axis, children, fractions) = result else {
            return XCTFail("splitting a bare leaf must produce a split, got \(result)")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children.count, 2)
        // Order: original leaf first, new leaf second.
        XCTAssertEqual(children[0], .leaf(a.0, a.1))
        XCTAssertEqual(children[1], .leaf(nl.0, nl.1))
        assertEven(fractions, count: 2)
        XCTAssertEqual(result.allLeafIDs(), [a.0, nl.0])
    }

    func testSplitBareLeafVerticalWrapsInTwoWay() {
        let a = leaf("a")
        let tree = PaneNode.leaf(a.0, a.1)
        let result = tree.splitting(a.0, axis: .vertical, newLeaf: leaf("a2"))

        guard case let .split(axis, children, fractions) = result else {
            return XCTFail("expected split")
        }
        XCTAssertEqual(axis, .vertical)
        assertEven(fractions, count: 2)
        XCTAssertEqual(children.count, 2)
    }

    /// Splitting an id that isn't in the tree is a pure no-op.
    func testSplitUnknownTargetIsNoOp() {
        let a = leaf("a")
        let tree = PaneNode.leaf(a.0, a.1)
        let result = tree.splitting(PaneID(), axis: .horizontal, newLeaf: leaf("x"))
        XCTAssertEqual(result, tree)
    }

    // MARK: - splitting: the flatten rule (same-axis sibling insert)

    /// `⌘D ⌘D` on a horizontal split must produce a single **3-way** horizontal split with even
    /// 1/3 fractions — NOT a right-leaning staircase of nested binary splits.
    func testSplitSameAxisInsertsSiblingFlatThreeWay() {
        let a = leaf("a"), b = leaf("b"), c = leaf("c")
        // Start with a 2-way horizontal split [a, b].
        let two = PaneNode.split(.horizontal, children: [.leaf(a.0, a.1), .leaf(b.0, b.1)], fractions: [0.5, 0.5])

        // Split `b` again, same axis → insert `c` right after `b` in the SAME split.
        let result = two.splitting(b.0, axis: .horizontal, newLeaf: c)

        guard case let .split(axis, children, fractions) = result else {
            return XCTFail("expected a single split, got \(result)")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children.count, 3, "flatten: N→N+1, no nesting")
        XCTAssertEqual(children.map { $0 }, [.leaf(a.0, a.1), .leaf(b.0, b.1), .leaf(c.0, c.1)],
                       "new leaf inserted directly AFTER the split target")
        assertEven(fractions, count: 3)
        XCTAssertEqual(result.allLeafIDs(), [a.0, b.0, c.0])
        // No child is itself a split (proves it stayed flat).
        for child in children {
            if case .split = child { XCTFail("flatten rule must not nest a child split") }
        }
    }

    /// `⌘D ⌘D ⌘D` on a leaf → a single 4-way split, each fraction 1/4.
    func testSplitSameAxisThriceProducesFlatFourWay() {
        let a = leaf("a")
        var tree = PaneNode.leaf(a.0, a.1)
        tree = tree.splitting(a.0, axis: .horizontal, newLeaf: leaf("b"))
        guard case let .split(_, ch2, _) = tree else { return XCTFail("expected split") }
        let bID = ch2[1].allLeafIDs()[0]
        tree = tree.splitting(bID, axis: .horizontal, newLeaf: leaf("c"))
        guard case let .split(_, ch3, _) = tree else { return XCTFail("expected split") }
        let cID = ch3[2].allLeafIDs()[0]
        tree = tree.splitting(cID, axis: .horizontal, newLeaf: leaf("d"))

        guard case let .split(axis, children, fractions) = tree else { return XCTFail("expected split") }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children.count, 4, "three same-axis splits → flat 4-way")
        assertEven(fractions, count: 4)
        XCTAssertEqual(tree.leafCount, 4)
    }

    /// Splitting a direct child across the OTHER axis nests: the target child becomes a nested
    /// 2-way split of the perpendicular axis; the outer split keeps its arity AND its fractions.
    func testSplitCrossAxisNests() {
        let a = leaf("a"), b = leaf("b"), c = leaf("c")
        let two = PaneNode.split(.horizontal, children: [.leaf(a.0, a.1), .leaf(b.0, b.1)], fractions: [0.3, 0.7])

        // Split `b` along the VERTICAL axis (perpendicular) → nest under b's slot.
        let result = two.splitting(b.0, axis: .vertical, newLeaf: c)

        guard case let .split(outerAxis, outerChildren, outerFractions) = result else {
            return XCTFail("expected split")
        }
        XCTAssertEqual(outerAxis, .horizontal)
        XCTAssertEqual(outerChildren.count, 2, "cross-axis split must NOT change outer arity")
        // Outer fractions are preserved verbatim (only a descendant changed).
        XCTAssertEqual(outerFractions.count, 2)
        XCTAssertEqual(outerFractions[0], 0.3, accuracy: frac, "outer fractions preserved on nested split")
        XCTAssertEqual(outerFractions[1], 0.7, accuracy: frac)
        // child[0] is still `a`.
        XCTAssertEqual(outerChildren[0], .leaf(a.0, a.1))
        // child[1] is now a vertical 2-way split [b, c] with even fractions.
        guard case let .split(innerAxis, innerChildren, innerFractions) = outerChildren[1] else {
            return XCTFail("expected b's slot to become a nested split")
        }
        XCTAssertEqual(innerAxis, .vertical)
        XCTAssertEqual(innerChildren, [.leaf(b.0, b.1), .leaf(c.0, c.1)])
        assertEven(innerFractions, count: 2)
        XCTAssertEqual(result.allLeafIDs(), [a.0, b.0, c.0])
    }

    /// Splitting a leaf that lives deep inside the tree rewrites only that subtree; the ancestors
    /// keep their structure and fractions.
    func testSplitDeepLeafRewritesOnlySubtree() {
        let a = leaf("a"), b = leaf("b"), c = leaf("c"), nl = leaf("c2")
        // vertical[ a , horizontal[ b , c ] ] with non-even outer fractions to prove preservation.
        let tree = PaneNode.split(.vertical, children: [
            .leaf(a.0, a.1),
            .split(.horizontal, children: [.leaf(b.0, b.1), .leaf(c.0, c.1)], fractions: [0.5, 0.5]),
        ], fractions: [0.25, 0.75])

        // Split `c` horizontally → it's a direct child of the inner horizontal split → flatten to 3-way.
        let result = tree.splitting(c.0, axis: .horizontal, newLeaf: nl)

        guard case let .split(outerAxis, outerChildren, outerFractions) = result else {
            return XCTFail("expected split")
        }
        XCTAssertEqual(outerAxis, .vertical)
        XCTAssertEqual(outerFractions[0], 0.25, accuracy: frac, "outer fractions untouched")
        XCTAssertEqual(outerFractions[1], 0.75, accuracy: frac)
        XCTAssertEqual(outerChildren[0], .leaf(a.0, a.1))

        guard case let .split(innerAxis, innerChildren, innerFractions) = outerChildren[1] else {
            return XCTFail("expected inner split")
        }
        XCTAssertEqual(innerAxis, .horizontal)
        XCTAssertEqual(innerChildren, [.leaf(b.0, b.1), .leaf(c.0, c.1), .leaf(nl.0, nl.1)],
                       "flatten inserted new leaf after c")
        assertEven(innerFractions, count: 3)
        XCTAssertEqual(result.allLeafIDs(), [a.0, b.0, c.0, nl.0])
    }

    // MARK: - closing: collapse, renormalize, nil-on-last

    /// Closing the only leaf empties the tree → `nil`.
    func testClosingLastLeafReturnsNil() {
        let a = leaf("a")
        let tree = PaneNode.leaf(a.0, a.1)
        XCTAssertNil(tree.closing(a.0))
    }

    /// Closing a leaf that isn't present is a no-op (returns the tree unchanged).
    func testClosingUnknownTargetIsNoOp() {
        let a = leaf("a"), b = leaf("b")
        let tree = PaneNode.split(.horizontal, children: [.leaf(a.0, a.1), .leaf(b.0, b.1)], fractions: [0.5, 0.5])
        XCTAssertEqual(tree.closing(PaneID()), tree)
    }

    /// A 2-way split that loses one child COLLAPSES into the surviving leaf — no singleton split.
    func testClosingCollapsesTwoWayIntoSurvivingLeaf() {
        let a = leaf("a"), b = leaf("b")
        let tree = PaneNode.split(.horizontal, children: [.leaf(a.0, a.1), .leaf(b.0, b.1)], fractions: [0.5, 0.5])

        let result = tree.closing(a.0)
        XCTAssertEqual(result, .leaf(b.0, b.1), "split collapses to the lone survivor, not a singleton split")
    }

    /// A 3-way split that loses one child stays a split (drops to 2 children) and **renormalizes**
    /// the survivors' fractions to sum to 1, redistributing the closed pane's share proportionally.
    func testClosingThreeWayRenormalizesSurvivingFractions() {
        let a = leaf("a"), b = leaf("b"), c = leaf("c")
        // Deliberately uneven so renormalization is observable: closing `a` (0.2) leaves [0.3, 0.5]
        // which renormalizes to [0.375, 0.625].
        let tree = PaneNode.split(.horizontal, children: [
            .leaf(a.0, a.1), .leaf(b.0, b.1), .leaf(c.0, c.1),
        ], fractions: [0.2, 0.3, 0.5])

        let result = tree.closing(a.0)
        guard case let .split(axis, children, fractions) = result else {
            return XCTFail("3-way minus one stays a split, got \(String(describing: result))")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children, [.leaf(b.0, b.1), .leaf(c.0, c.1)])
        XCTAssertEqual(fractions.count, 2)
        XCTAssertEqual(fractions.reduce(0, +), 1.0, accuracy: frac, "renormalized to sum 1")
        XCTAssertEqual(fractions[0], 0.3 / 0.8, accuracy: frac, "b's share renormalized proportionally")
        XCTAssertEqual(fractions[1], 0.5 / 0.8, accuracy: frac, "c's share renormalized proportionally")
    }

    /// Closing a deep leaf collapses the inner split (now a singleton) into its survivor, which
    /// then sits directly in the outer split — and the outer split's fractions are untouched (the
    /// outer arity did not change, only a descendant collapsed).
    func testClosingDeepCollapsesInnerSplitIntoOuter() {
        let a = leaf("a"), b = leaf("b"), c = leaf("c")
        // horizontal[ a , vertical[ b , c ] ] with outer fractions [0.4, 0.6].
        let tree = PaneNode.split(.horizontal, children: [
            .leaf(a.0, a.1),
            .split(.vertical, children: [.leaf(b.0, b.1), .leaf(c.0, c.1)], fractions: [0.5, 0.5]),
        ], fractions: [0.4, 0.6])

        // Close `c` → inner vertical split drops to one child `b` → collapses → b sits in outer[1].
        // `closing` returns an optional; unwrap before pattern-matching so `allLeafIDs()` below is
        // called on the non-optional node.
        guard let result = tree.closing(c.0) else {
            return XCTFail("closing a non-last leaf must not empty the tree")
        }
        guard case let .split(axis, children, fractions) = result else {
            return XCTFail("expected outer split to survive")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0], .leaf(a.0, a.1))
        XCTAssertEqual(children[1], .leaf(b.0, b.1), "inner singleton collapsed into the lone survivor b")
        XCTAssertEqual(fractions[0], 0.4, accuracy: frac, "outer fractions untouched (arity unchanged)")
        XCTAssertEqual(fractions[1], 0.6, accuracy: frac)
        XCTAssertEqual(result.allLeafIDs(), [a.0, b.0])
    }

    // MARK: - updatingSpec mutates ONLY the target

    func testUpdatingSpecMutatesOnlyTarget() {
        let a = leaf("a"), b = leaf("b"), c = leaf("c")
        let tree = PaneNode.split(.horizontal, children: [
            .leaf(a.0, a.1),
            .split(.vertical, children: [.leaf(b.0, b.1), .leaf(c.0, c.1)], fractions: [0.5, 0.5]),
        ], fractions: [0.5, 0.5])

        let result = tree.updatingSpec(b.0) { spec in
            spec.title = "RENAMED"
            spec.endpoint = Endpoint(host: "h", port: 9)
        }

        XCTAssertEqual(result.spec(for: b.0)?.title, "RENAMED")
        XCTAssertEqual(result.spec(for: b.0)?.endpoint, Endpoint(host: "h", port: 9))
        // Siblings untouched.
        XCTAssertEqual(result.spec(for: a.0)?.title, "a")
        XCTAssertNil(result.spec(for: a.0)?.endpoint)
        XCTAssertEqual(result.spec(for: c.0)?.title, "c")
        // Structure preserved (same ids in the same pre-order).
        XCTAssertEqual(result.allLeafIDs(), tree.allLeafIDs())
    }

    func testUpdatingSpecUnknownIdIsNoOp() {
        let a = leaf("a")
        let tree = PaneNode.leaf(a.0, a.1)
        let result = tree.updatingSpec(PaneID()) { $0.title = "x" }
        XCTAssertEqual(result, tree)
    }
}
