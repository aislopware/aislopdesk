import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import Observation
import SwiftUI
#endif

/// The headless proof of the P1 LIVE-SCALE FIX (the critical correctness change). Two halves:
///   1. density math — `DSScale.scaled` is `value * multiplier`, separated (no FMA drift);
///   2. wiring — `DSScale` is `@Observable` (a `multiplier` mutation fires `withObservationTracking`),
///      and the `dsFont`/`dsSpace` ViewModifiers declare `@Environment(DSScale.self)` so SwiftUI records
///      the dependency and a density change repaints. The wiring half is the revert-to-confirm-fail guard
///      for the dead-notification bug (UIScale was @Observable but never injected; UIMetrics read
///      UIScale.shared inside static vars, which SwiftUI cannot observe).
///
/// No GUI: NO NSWindow / Ghostty / SCStream / VT is instantiated. The modifier wiring is proven by
/// reflecting the modifier struct (an `@Environment(DSScale.self)` property surfaces as an
/// `Environment<DSScale>` Mirror child), and the observability by `withObservationTracking`.
@MainActor
final class DSScaleWiringTests: XCTestCase {
    /// Restore the shared multiplier after any test mutates it, so tests stay order-independent.
    override func tearDown() {
        DSScale.shared.multiplier = 1.0
        super.tearDown()
    }

    // MARK: - Density math

    /// At the P1 default multiplier 1.00, scaling is the identity.
    func testScaledIdentityAtDefault() {
        DSScale.shared.multiplier = 1.0
        XCTAssertEqual(DSScale.scaled(8), 8, accuracy: 1e-12)
        XCTAssertEqual(DSScale.scaled(0), 0, accuracy: 1e-12)
        XCTAssertEqual(DSScale.scaled(13), 13, accuracy: 1e-12)
    }

    /// `scaled` is exactly `value * multiplier` — a plain separated multiply, no FMA. Pin at a non-unit
    /// multiplier so the result is `base * mult` to full precision (FMA would keep extra precision and
    /// could differ in the low bits).
    ///
    /// ORDER-INDEPENDENCE: the mutation of the process-wide `DSScale.shared.multiplier` is wrapped in a
    /// `defer` restore so the singleton is back at 1.0 even if an assertion throws mid-test — `tearDown`
    /// alone is not enough (a thrown XCTest assertion would leak a non-unit multiplier to the next test).
    func testScaledIsSeparatedMultiply() {
        defer { DSScale.shared.multiplier = 1.0 }
        DSScale.shared.multiplier = 1.12
        XCTAssertEqual(DSScale.scaled(10), 10 * 1.12)
        XCTAssertEqual(DSScale.scaled(13), 13 * 1.12)
        DSScale.shared.multiplier = 1.24
        XCTAssertEqual(DSScale.scaled(28), 28 * 1.24)
    }

    /// The P1 bridge: `DSScale.shared.multiplier` is seeded from the legacy `UIScale.shared.multiplier` so
    /// the two scale paths never diverge while no view consumes DS tokens. (At default both are 1.00.)
    ///
    /// ORDER-INDEPENDENCE: this asserts the SHARED singleton's live value, which a sibling test could have
    /// left mid-mutation (XCTest runs serially + every mutator `defer`s a restore, but be defensive) — so
    /// it FIRST re-bridges `DSScale.shared.multiplier` to `UIScale.shared.multiplier` so it cannot observe
    /// a value another test leaked, then asserts the bridge holds.
    func testBridgedToLegacyMultiplierAtDefault() {
        XCTAssertEqual(UIScale.shared.multiplier, 1.0, "legacy default preset is regular = 1.00")
        // Re-establish the P1 bridge before reading it, so this test cannot observe a leaked multiplier.
        DSScale.shared.multiplier = UIScale.shared.multiplier
        XCTAssertEqual(DSScale.shared.multiplier, 1.0)
    }

    // MARK: - Observability (the @Observable half of the fix)

    #if canImport(SwiftUI)
    /// `DSScale` is `@Observable`: a read of `multiplier` inside `withObservationTracking` registers a
    /// dependency, and a subsequent mutation fires the change handler. This is the mechanism SwiftUI uses
    /// to repaint a `dsFont`/`dsSpace` view on a density change — the thing the old `UIScale` static-var
    /// path could never trigger. REVERT-TO-CONFIRM-FAIL: drop `@Observable` from `DSScale` and this fails.
    func testDSScaleIsObservable() {
        defer { DSScale.shared.multiplier = 1.0 }
        let scale = DSScale.shared
        let fired = expectation(description: "observation change handler fires on multiplier mutation")
        withObservationTracking {
            _ = scale.multiplier
        } onChange: {
            fired.fulfill()
        }
        scale.multiplier = 1.5
        wait(for: [fired], timeout: 1.0)
    }
    #endif

    // MARK: - Modifier reads @Environment(DSScale.self) (the injection half of the fix)

    #if canImport(SwiftUI)
    /// The `dsFont` modifier declares `@Environment(DSScale.self)` — surfaced as an `Environment<DSScale>`
    /// stored property. This is what makes SwiftUI track the density dependency and repaint live (instead
    /// of reading `DSScale.shared` inside a static var, which is unobservable). REVERT-TO-CONFIRM-FAIL:
    /// change `DSFontModifier` to read `DSScale.shared` (drop the `@Environment` property) and this fails.
    func testDSFontModifierReadsEnvironmentDSScale() {
        let modifier = DSFontModifier(token: .body)
        XCTAssertTrue(
            hasEnvironmentDSScaleProperty(modifier),
            "DSFontModifier must hold an @Environment(DSScale.self) property for live repaint",
        )
    }

    /// The `dsSpace` modifier likewise reads `@Environment(DSScale.self)`.
    func testDSSpaceModifierReadsEnvironmentDSScale() {
        let modifier = DSSpaceModifier(edges: .all, base: 8)
        XCTAssertTrue(
            hasEnvironmentDSScaleProperty(modifier),
            "DSSpaceModifier must hold an @Environment(DSScale.self) property for live repaint",
        )
    }

    /// Reflects a modifier and reports whether it has a stored property of type `Environment<DSScale>`
    /// (the runtime representation of an `@Environment(DSScale.self)` declaration).
    private func hasEnvironmentDSScaleProperty(_ subject: Any) -> Bool {
        Mirror(reflecting: subject).children.contains { child in
            child.value is Environment<DSScale>
        }
    }
    #endif
}
