import Foundation
@testable import RworkClientUI

// MARK: - FakePaneSession (the store test double)

/// The test double the ``WorkspaceStore`` reconcile/fan-out/video-cap tests inject via the
/// `makeSession` seam (docs/22 §0, §8). It conforms to ``PaneSessionHandle`` EXACTLY and records the
/// lifecycle calls + their ordering so a test can assert reconcile correctness, teardown ordering,
/// and the scenePhase fan-out — **without ever constructing a `RworkClient` or a `HostServer`**.
///
/// Built from a ``PaneSpec`` (mirroring `LivePaneSession.make`'s spec→session shape) so the store's
/// production and test factories are interchangeable. It also conforms to the store-internal
/// ``PaneSessionIDAdopting`` so `reconcile()` re-points its `id` at the leaf id, exactly as it does for
/// the live session — which is what lets the registry-key invariant be asserted.
@MainActor
@Observable
final class FakePaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
    // MARK: Identity

    /// Placeholder until the store adopts the leaf id (see ``adopt(id:)``).
    private(set) var id: PaneID
    let kind: PaneKind

    /// The spec it was built from (so a test can assert kind/endpoint wiring).
    let spec: PaneSpec

    // MARK: Recorded lifecycle

    /// How many times ``pause()`` was called.
    private(set) var pauseCount = 0
    /// How many times ``resume()`` was called.
    private(set) var resumeCount = 0
    /// How many times ``teardown()`` was called.
    private(set) var teardownCount = 0

    /// A monotonically-appended log of every lifecycle event, in call order, for ordering assertions.
    enum Event: Equatable, Sendable { case pause, resume, teardown, adopt(PaneID), videoActive(Bool) }
    private(set) var events: [Event] = []

    // MARK: Video activation

    /// The video-activation flag the cap tests assert against (only meaningful for `.remoteGUI`).
    private(set) var isVideoActive: Bool = false

    /// Mirrors ``LivePaneSession``: a `.remoteGUI` pane that was video-active before `pause()` is
    /// remembered so `resume()` re-activates it. Guarded to `.remoteGUI` so the unconditional-flip cap
    /// tests (which never call pause/resume) are unaffected.
    private var wasVideoActiveBeforePause = false

    // MARK: Init

    /// Builds a fake session from `spec` (the store-injected shape). Mints a placeholder id; the store
    /// adopts the leaf id during reconcile.
    init(_ spec: PaneSpec) {
        self.id = PaneID()
        self.kind = spec.kind
        self.spec = spec
    }

    // MARK: PaneSessionIDAdopting

    func adopt(id: PaneID) {
        self.id = id
        events.append(.adopt(id))
    }

    // MARK: PaneSessionHandle: video

    func setVideoActive(_ active: Bool) {
        // Match LivePaneSession: a no-op for non-video kinds.
        guard kind == .remoteGUI else { return }
        isVideoActive = active
        events.append(.videoActive(active))
    }

    // MARK: PaneSessionHandle: lifecycle

    func pause() async {
        pauseCount += 1
        events.append(.pause)
        // Mirror LivePaneSession: suspend live video and remember it for resume (.remoteGUI only).
        if isVideoActive {
            wasVideoActiveBeforePause = true
            isVideoActive = false
            events.append(.videoActive(false))
        }
    }

    func resume() async {
        resumeCount += 1
        events.append(.resume)
        // Mirror LivePaneSession: re-activate video that was active before pause (.remoteGUI only).
        if kind == .remoteGUI, wasVideoActiveBeforePause {
            wasVideoActiveBeforePause = false
            isVideoActive = true
            events.append(.videoActive(true))
        }
    }

    func teardown() async {
        teardownCount += 1
        events.append(.teardown)
    }
}
