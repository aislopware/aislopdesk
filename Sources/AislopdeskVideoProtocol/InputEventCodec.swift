import Foundation

/// Modifier-key bitmask carried by input events (matches the CGEventFlags the host
/// will apply, but kept platform-free here).
public struct InputModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
    public static let capsLock = Self(rawValue: 1 << 4)
    public static let function = Self(rawValue: 1 << 5)
}

/// Which mouse button an event concerns.
public enum MouseButton: UInt8, Sendable, Equatable {
    case left = 0
    case right = 1
    case other = 2
}

/// Client→host input events (doc 17 §3.9 / doc 05). Positions are in **normalised
/// window space (0..1)** — the client never sends raw pixels, which removes all
/// pixel-vs-point ambiguity (doc 05 §2); the host maps normalised→host-window-point
/// via ``CoordinateMapping``. Every event carries `tag` = the value the host will
/// stamp on `eventSourceUserData` so it can FILTER its own self-injected events out
/// of `CursorSampler`/`WindowGeometryWatcher` (doc 18 §A — avoids feedback loops).
public enum InputEvent: Equatable, Sendable {
    /// Absolute pointer move to a normalised window position.
    case mouseMove(normalized: VideoPoint, tag: UInt32)
    /// Mouse button down at a normalised window position.
    case mouseDown(
        button: MouseButton,
        normalized: VideoPoint,
        clickCount: UInt8,
        modifiers: InputModifiers,
        tag: UInt32,
    )
    /// Mouse button up at a normalised window position.
    case mouseUp(button: MouseButton, normalized: VideoPoint, clickCount: UInt8, modifiers: InputModifiers, tag: UInt32)
    /// Mouse drag (a button is HELD) to a normalised window position. The CLIENT sends
    /// this explicitly when its view reports a `mouseDragged` (vs a `mouseMoved`), so the
    /// host posts the matching `*MouseDragged` STATELESSLY — it never infers "is a button
    /// held?" from host-side state. This is what makes drag-select ("bôi đen") correct: it
    /// is wire-reorder-safe over UDP (a drag that arrives before its `mouseDown` is simply
    /// ignored by the target app until the down anchors the selection) and it removes the
    /// phantom-drag-after-a-lost-`mouseUp` class of bug (a `.mouseMove` is now ALWAYS a pure
    /// hover). `clickCount` carries the originating click count so the dragged event's
    /// clickState matches the down — selection engines key off it.
    case mouseDrag(
        button: MouseButton,
        normalized: VideoPoint,
        clickCount: UInt8,
        modifiers: InputModifiers,
        tag: UInt32,
    )
    /// Scroll wheel (pixel units). `dy`/`dx` are signed scroll deltas.
    ///
    /// `scrollPhase` / `momentumPhase` carry the trackpad gesture state so the host can replay a
    /// native continuous/inertial scroll instead of a phase-less wheel tick. They use the CoreGraphics
    /// integer encodings verbatim — `scrollPhase` ∈ `CGScrollPhase` (0=none, 1=began, 2=changed,
    /// 4=ended, 8=cancelled, 128=mayBegin); `momentumPhase` ∈ `CGMomentumScrollPhase` (0=none,
    /// 1=begin, 2=continue, 3=end) — and are mutually exclusive (at most one is non-zero per event).
    /// `continuous` mirrors `hasPreciseScrollingDeltas` (true = pixel-precise trackpad gesture).
    case scroll(
        dx: Double,
        dy: Double,
        normalized: VideoPoint,
        scrollPhase: UInt8,
        momentumPhase: UInt8,
        continuous: Bool,
        tag: UInt32,
    )
    /// Key down/up by host virtual keycode (for navigation / shortcuts; doc 05 §3).
    case key(keyCode: UInt16, down: Bool, modifiers: InputModifiers, tag: UInt32)
    /// Unicode text insertion (layout-independent; the robust text path, doc 05 §3).
    case text(String, tag: UInt32)

    public var messageType: UInt8 {
        switch self {
        case .mouseMove: 1
        case .mouseDown: 2
        case .mouseUp: 3
        case .scroll: 4
        case .key: 5
        case .text: 6
        case .mouseDrag: 7
        }
    }

    /// The self-inject filter tag.
    public var tag: UInt32 {
        switch self {
        case let .mouseMove(_, tag),
             let .mouseDown(_, _, _, _, tag),
             let .mouseUp(_, _, _, _, tag),
             let .mouseDrag(_, _, _, _, tag),
             let .scroll(_, _, _, _, _, _, tag),
             let .key(_, _, _, tag),
             let .text(_, tag):
            tag
        }
    }

    /// Encodes via the Rust `aislopdesk-core` input-event codec — the single source of truth shared
    /// with the Android client (the wire format is pinned by golden vectors).
    public func encode() -> Data {
        RustVideoFFI.encode(self)
    }

    /// Decodes via the Rust input-event codec — the single source of truth (the wire format is
    /// pinned by golden vectors). Non-finite coordinates, an unknown button/type, or non-UTF-8
    /// text are rejected as `.malformed`; a short body is `.truncated`.
    public static func decode(_ data: Data) throws -> Self {
        try RustVideoFFI.decodeInputEvent(data)
    }
}
