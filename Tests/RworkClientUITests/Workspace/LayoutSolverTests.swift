import XCTest
import CoreGraphics
@testable import RworkClientUI

/// Pinned-geometry tests for ``LayoutSolver`` — the **single geometry source of truth**
/// (docs/22 §1.3, §2.1). Every assertion checks an *exact* rect (or a tightly-epsilon'd float)
/// against a hand-computed expectation, so the proportional-allocation math, the
/// divider-thickness reservation, the min-leaf floor, and the divider placement are all locked.
///
/// Geometry recap the tests rely on (read from `LayoutSolver.solve` / `segmentLengths`):
/// - Origin `.zero` is top-left, y grows down (standard `CGRect`, matches FocusResolver's
///   `up == smaller-y`).
/// - `dividerThickness` (8) is reserved from the axis length BEFORE distributing fractions:
///   N children share `length − (N−1)·8`.
/// - Children **abut** (the divider does not push them apart); the divider rect is *centered*
///   on the seam (±4 around the boundary).
/// - Each segment is then FLOORED to `minLeaf` (a clamp, not a re-solve — can overflow when the
///   container is too small).
final class LayoutSolverTests: XCTestCase {

    // MARK: - Fixtures

    /// A `minLeaf` small enough never to clamp the rects under test (so we isolate the
    /// proportional math). Floors only matter in the dedicated clamp tests below.
    private let tinyMin = CGSize(width: 1, height: 1)

    /// Floating-point tolerance for geometry compares. The solver does plain `Double`/`CGFloat`
    /// arithmetic, so divisions like `792 * 0.3` accumulate tiny error — 1e-6 is generous yet
    /// far below any meaningful pixel difference.
    private let eps: CGFloat = 1e-6

    private func leaf(_ id: PaneID, _ kind: PaneKind = .terminal, _ title: String = "p") -> PaneNode {
        .leaf(id, PaneSpec(kind: kind, title: title))
    }

    /// Asserts two rects are equal within `eps` on every component, with a readable failure.
    private func assertRect(
        _ actual: CGRect?,
        _ expected: CGRect,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("expected a rect (\(expected)) but got nil — \(message)", file: file, line: line)
        }
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: eps, "x — \(message)", file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: eps, "y — \(message)", file: file, line: line)
        XCTAssertEqual(actual.size.width, expected.size.width, accuracy: eps, "w — \(message)", file: file, line: line)
        XCTAssertEqual(actual.size.height, expected.size.height, accuracy: eps, "h — \(message)", file: file, line: line)
    }

    /// Asserts an optional `CGFloat` (e.g. `frames[id]?.width`) equals `expected` within `eps`,
    /// failing readably on `nil`. (`XCTAssertEqual(_:_:accuracy:)` does not take an optional.)
    private func assertCGFloat(
        _ actual: CGFloat?,
        _ expected: CGFloat,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("expected \(expected) but got nil — \(message)", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, accuracy: eps, message, file: file, line: line)
    }

    // MARK: - Degenerate / single leaf

    /// A bare leaf fills the whole container; no dividers.
    func testSingleLeafFillsContainer() {
        let id = PaneID()
        let solved = LayoutSolver.solve(leaf(id), in: CGSize(width: 800, height: 600), minLeaf: tinyMin)

        XCTAssertEqual(solved.frames.count, 1)
        assertRect(solved.frames[id], CGRect(x: 0, y: 0, width: 800, height: 600), "single leaf")
        XCTAssertTrue(solved.dividers.isEmpty, "a lone leaf has no dividers")
    }

    // MARK: - Two-way horizontal split (the canonical case)

    /// 800×600 horizontal split with [0.5, 0.5]:
    /// available = 800 − 8 = 792 → each segment = 396. Children abut at x=396; the divider is
    /// centered on the seam at x = 396 − 4 = 392, width 8, full height.
    func testTwoWayHorizontalEvenSplit() {
        let l = PaneID(), r = PaneID()
        let root = PaneNode.split(.horizontal, children: [leaf(l), leaf(r)], fractions: [0.5, 0.5])
        let solved = LayoutSolver.solve(root, in: CGSize(width: 800, height: 600), minLeaf: tinyMin)

        assertRect(solved.frames[l], CGRect(x: 0, y: 0, width: 396, height: 600), "left child")
        assertRect(solved.frames[r], CGRect(x: 396, y: 0, width: 396, height: 600), "right child")

        XCTAssertEqual(solved.dividers.count, 1)
        let d = solved.dividers[0]
        XCTAssertEqual(d.path, [], "root is the split")
        XCTAssertEqual(d.index, 0, "gap between children[0] and children[1]")
        XCTAssertEqual(d.axis, .horizontal)
        assertRect(d.rect, CGRect(x: 392, y: 0, width: 8, height: 600), "divider centered on the seam")
    }

    /// Children abut exactly (left.maxX == right.minX) so FocusResolver's edge-compare lands
    /// cleanly — the divider overlaps the seam rather than separating the panes.
    func testHorizontalChildrenAbutAtSeam() {
        let l = PaneID(), r = PaneID()
        let root = PaneNode.split(.horizontal, children: [leaf(l), leaf(r)], fractions: [0.5, 0.5])
        let solved = LayoutSolver.solve(root, in: CGSize(width: 800, height: 600), minLeaf: tinyMin)

        let left = solved.frames[l]!, right = solved.frames[r]!
        XCTAssertEqual(left.maxX, right.minX, accuracy: eps, "panes abut, divider overlays the seam")
    }

    /// Uneven fractions distribute the *post-reservation* length proportionally.
    /// available = 792 → [0.25, 0.75] → 198 and 594.
    func testTwoWayHorizontalUnevenSplit() {
        let l = PaneID(), r = PaneID()
        let root = PaneNode.split(.horizontal, children: [leaf(l), leaf(r)], fractions: [0.25, 0.75])
        let solved = LayoutSolver.solve(root, in: CGSize(width: 800, height: 600), minLeaf: tinyMin)

        assertRect(solved.frames[l], CGRect(x: 0, y: 0, width: 198, height: 600), "narrow left")
        assertRect(solved.frames[r], CGRect(x: 198, y: 0, width: 594, height: 600), "wide right")
        assertRect(solved.dividers[0].rect, CGRect(x: 194, y: 0, width: 8, height: 600), "seam at x=198")
    }

    // MARK: - Two-way vertical split

    /// Vertical split stacks children (varies in y). 800×600 [0.5,0.5]:
    /// available = 600 − 8 = 592 → each 296. Children abut at y=296; divider y = 296 − 4 = 292,
    /// full width, height 8.
    func testTwoWayVerticalEvenSplit() {
        let top = PaneID(), bot = PaneID()
        let root = PaneNode.split(.vertical, children: [leaf(top), leaf(bot)], fractions: [0.5, 0.5])
        let solved = LayoutSolver.solve(root, in: CGSize(width: 800, height: 600), minLeaf: tinyMin)

        assertRect(solved.frames[top], CGRect(x: 0, y: 0, width: 800, height: 296), "top child")
        assertRect(solved.frames[bot], CGRect(x: 0, y: 296, width: 800, height: 296), "bottom child")

        XCTAssertEqual(solved.dividers.count, 1)
        let d = solved.dividers[0]
        XCTAssertEqual(d.axis, .vertical)
        assertRect(d.rect, CGRect(x: 0, y: 292, width: 800, height: 8), "horizontal divider bar")
    }

    // MARK: - N-way (3) split: fractions + dividers

    /// A 3-way horizontal split (the `⌘D ⌘D` flatten result). available = 800 − 2·8 = 784;
    /// thirds = 784/3 ≈ 261.333. Two dividers, at the seam after each non-last child.
    func testThreeWayHorizontalSplitFractionsAndDividers() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let third = 1.0 / 3.0
        let root = PaneNode.split(
            .horizontal,
            children: [leaf(a), leaf(b), leaf(c)],
            fractions: [third, third, third]
        )
        let solved = LayoutSolver.solve(root, in: CGSize(width: 800, height: 600), minLeaf: tinyMin)

        let seg = 784.0 / 3.0
        assertRect(solved.frames[a], CGRect(x: 0, y: 0, width: seg, height: 600), "first third")
        assertRect(solved.frames[b], CGRect(x: seg, y: 0, width: seg, height: 600), "second third")
        assertRect(solved.frames[c], CGRect(x: 2 * seg, y: 0, width: seg, height: 600), "third third")

        XCTAssertEqual(solved.dividers.count, 2, "N children → N−1 dividers")
        XCTAssertEqual(solved.dividers.map(\.index), [0, 1], "one divider per interior gap")
        XCTAssertTrue(solved.dividers.allSatisfy { $0.path == [] && $0.axis == .horizontal })
        assertRect(solved.dividers[0].rect, CGRect(x: seg - 4, y: 0, width: 8, height: 600), "first seam")
        assertRect(solved.dividers[1].rect, CGRect(x: 2 * seg - 4, y: 0, width: 8, height: 600), "second seam")
    }

    // MARK: - 3-deep nesting (mixed axes, recursive paths)

    /// A nested tree: root is a horizontal split [left | right], and `right` is itself a vertical
    /// split [top / bottom]. Verifies (a) recursive rects compose correctly, (b) the inner
    /// divider's `path` addresses the nested split (path == [1]), and (c) both axes appear.
    ///
    /// Container 1000×800, even fractions everywhere, tinyMin (no clamp):
    /// - root horizontal: available x = 1000 − 8 = 992 → halves = 496.
    ///   left = (0,0,496,800); right column occupies (496,0,496,800).
    /// - inner vertical inside the right column rect: available y = 800 − 8 = 792 → halves = 396.
    ///   top = (496,0,496,396); bottom = (496,396,496,396).
    func testThreeDeepNestedMixedAxes() {
        let left = PaneID(), top = PaneID(), bottom = PaneID()
        let inner = PaneNode.split(.vertical, children: [leaf(top), leaf(bottom)], fractions: [0.5, 0.5])
        let root = PaneNode.split(.horizontal, children: [leaf(left), inner], fractions: [0.5, 0.5])

        let solved = LayoutSolver.solve(root, in: CGSize(width: 1000, height: 800), minLeaf: tinyMin)

        assertRect(solved.frames[left], CGRect(x: 0, y: 0, width: 496, height: 800), "left column")
        assertRect(solved.frames[top], CGRect(x: 496, y: 0, width: 496, height: 396), "right-top")
        assertRect(solved.frames[bottom], CGRect(x: 496, y: 396, width: 496, height: 396), "right-bottom")

        XCTAssertEqual(solved.frames.count, 3, "exactly the three leaves")
        XCTAssertEqual(solved.dividers.count, 2, "one outer (vertical seam) + one inner (horizontal bar)")

        // Outer divider: root split, gap 0, horizontal, centered on x=496.
        let outer = solved.dividers.first { $0.path == [] }
        XCTAssertNotNil(outer, "an outer divider on the root split")
        XCTAssertEqual(outer?.axis, .horizontal)
        XCTAssertEqual(outer?.index, 0)
        assertRect(outer?.rect, CGRect(x: 492, y: 0, width: 8, height: 800), "outer vertical seam")

        // Inner divider: lives on the split at child path [1], gap 0, vertical, within the
        // right column (x from 496..992), centered on y=396.
        let innerDivider = solved.dividers.first { $0.path == [1] }
        XCTAssertNotNil(innerDivider, "an inner divider addressed by path [1]")
        XCTAssertEqual(innerDivider?.axis, .vertical)
        XCTAssertEqual(innerDivider?.index, 0)
        assertRect(innerDivider?.rect, CGRect(x: 496, y: 392, width: 496, height: 8), "inner horizontal bar")
    }

    /// Path addressing across a deeper chain: root horizontal of [leaf, [leaf, leaf-split]] —
    /// confirm a divider can carry a multi-element path. Build a tree where the inner split is the
    /// SECOND child of an inner split, forcing path [1, 1] for the deepest divider.
    func testDividerPathAddressesDeepSplit() {
        let a = PaneID(), b = PaneID(), c = PaneID(), d = PaneID()
        // deepest: horizontal [c | d]
        let deepest = PaneNode.split(.horizontal, children: [leaf(c), leaf(d)], fractions: [0.5, 0.5])
        // middle: vertical [b / deepest]  → deepest is child index 1 of `middle`
        let middle = PaneNode.split(.vertical, children: [leaf(b), deepest], fractions: [0.5, 0.5])
        // root: horizontal [a | middle]   → middle is child index 1 of root
        let root = PaneNode.split(.horizontal, children: [leaf(a), middle], fractions: [0.5, 0.5])

        let solved = LayoutSolver.solve(root, in: CGSize(width: 1200, height: 900), minLeaf: tinyMin)

        // Three splits → three dividers, with paths [], [1], [1, 1].
        let paths = Set(solved.dividers.map(\.path))
        XCTAssertEqual(paths, [[], [1], [1, 1]], "each split contributes a divider keyed by its child-path")

        let deepDivider = solved.dividers.first { $0.path == [1, 1] }
        XCTAssertNotNil(deepDivider, "the deepest split is addressed by path [1, 1]")
        XCTAssertEqual(deepDivider?.axis, .horizontal)
    }

    // MARK: - Min-leaf clamping (the floor, not a re-solve)

    /// When fractions would crush a child below `minLeaf`, the segment is FLOORED to the min
    /// (a clamp). With a large min the total can overflow the container — the documented
    /// "collapse to compact before crushing" policy means the solver floors rather than crashes.
    ///
    /// 100-wide horizontal split, [0.5,0.5], minLeaf width 200:
    /// available = 100 − 8 = 92 → raw thirds 46 each → floored UP to 200 each.
    func testMinLeafFloorsTinySegments() {
        let l = PaneID(), r = PaneID()
        let root = PaneNode.split(.horizontal, children: [leaf(l), leaf(r)], fractions: [0.5, 0.5])
        let solved = LayoutSolver.solve(
            root,
            in: CGSize(width: 100, height: 600),
            minLeaf: CGSize(width: 200, height: 1)
        )

        // Each segment floored to 200 (overflowing the 100-wide container, by design).
        assertCGFloat(solved.frames[l]?.width, 200, "left floored to minLeaf width")
        assertCGFloat(solved.frames[r]?.width, 200, "right floored to minLeaf width")
        // The second child's origin still advances by the (floored) first segment.
        assertCGFloat(solved.frames[r]?.minX, 200, "cursor advanced by floored segment")
    }

    /// Above the floor, min-leaf does not perturb the proportional result (a floor, never a
    /// ceiling): a comfortably-large container keeps the exact 0.5/0.5 segments.
    func testMinLeafDoesNotShrinkLargeSegments() {
        let l = PaneID(), r = PaneID()
        let root = PaneNode.split(.horizontal, children: [leaf(l), leaf(r)], fractions: [0.5, 0.5])
        let solved = LayoutSolver.solve(
            root,
            in: CGSize(width: 800, height: 600),
            minLeaf: CGSize(width: 50, height: 50)
        )
        assertCGFloat(solved.frames[l]?.width, 396, "min below the natural size is a no-op")
        assertCGFloat(solved.frames[r]?.width, 396)
    }

    // MARK: - Fraction renormalization (defensive)

    /// Fractions that do not sum to 1 are normalized by the solver before allocation, so a tree
    /// whose fractions drifted still solves proportionally. [1, 3] (sum 4) → [0.25, 0.75].
    func testUnnormalizedFractionsAreNormalized() {
        let l = PaneID(), r = PaneID()
        let root = PaneNode.split(.horizontal, children: [leaf(l), leaf(r)], fractions: [1, 3])
        let solved = LayoutSolver.solve(root, in: CGSize(width: 800, height: 600), minLeaf: tinyMin)

        // available 792 → 0.25·792 = 198, 0.75·792 = 594.
        assertCGFloat(solved.frames[l]?.width, 198, "1:3 normalized to 0.25")
        assertCGFloat(solved.frames[r]?.width, 594, "1:3 normalized to 0.75")
    }

    // MARK: - Conservation: leaf widths + reserved dividers == container

    /// The solved leaves plus the reserved divider gaps account for the full axis length (the
    /// reservation accounting closes): for a horizontal split, Σ(segment widths) + (N−1)·8 == W
    /// (when nothing is clamped). Verified for a 3-way split.
    func testWidthsPlusDividersConserveContainer() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let third = 1.0 / 3.0
        let root = PaneNode.split(.horizontal, children: [leaf(a), leaf(b), leaf(c)], fractions: [third, third, third])
        let solved = LayoutSolver.solve(root, in: CGSize(width: 900, height: 500), minLeaf: tinyMin)

        let totalLeafWidth = [a, b, c].compactMap { solved.frames[$0]?.width }.reduce(0, +)
        let reserved = LayoutSolver.dividerThickness * 2
        XCTAssertEqual(totalLeafWidth + reserved, 900, accuracy: 1e-4, "leaves + reserved gaps fill the container")
    }
}
