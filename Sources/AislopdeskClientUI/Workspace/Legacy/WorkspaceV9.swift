import CoreGraphics
import Foundation

// MARK: - WorkspaceV9 (FROZEN mirror of the v9 persisted workspace shape)

/// A **frozen, self-contained `Codable` mirror** of the v9 persisted ``Workspace`` shape — the single
/// infinite ``Canvas`` of free-floating panes + named ``PaneGroup``s (docs/42 §Migration / §Decisions.8).
///
/// ### Why a frozen shadow (not the live `Workspace`)
/// The v9 → v10 migration (``WorkspaceMigrationV9toV10``) reads the OLD on-disk shape. W4 will replace the
/// live ``Workspace`` type with the tree-rooted ``TreeWorkspace`` — at which point the live `Workspace`
/// Codable no longer exists to decode a v9 file. Freezing the v9 shape **here, now**, decouples the
/// migration from that cutover: this mirror keeps decoding the exact bytes today's `Workspace` Codable
/// produces, so a future live-type edit can never silently break the migration (docs/42 §Migration: "A
/// frozen `WorkspaceV9` mirror immunizes the migration against future live-type edits.").
///
/// ### Faithfulness contract
/// Every field + wire shape mirrors the LIVE `Workspace`/`Canvas`/`CanvasItem`/`CanvasCamera` Codable
/// **exactly**, so the SAME JSON decodes through both. `WorkspaceMigrationV9toV10Tests` pins this by
/// encoding a live `Workspace` value and decoding it through this mirror. ``PaneID`` / ``PaneSpec`` /
/// ``PaneGroup`` / ``Snippet`` / ``LayoutPreset`` / ``ConnectionTarget`` / ``CanvasBookmark`` are reused
/// verbatim (stable public value types whose wire shapes are part of the same persisted format).
///
/// ### Validate-then-repair
/// Decode is **defensive** (CLAUDE.md untrusted-persisted-data contract): missing optionals default,
/// per-field type mismatches in the canvas frame fall back to a safe rect, a missing camera defaults to
/// the origin — a hand-edited / partial file never traps. (The migration itself also never force-unwraps.)
struct WorkspaceV9: Codable, Equatable {
    var schemaVersion: Int
    var canvas: CanvasV9
    var focusedPane: PaneID?
    var maximizedPane: PaneID?
    var groups: [PaneGroup]
    var connection: ConnectionTarget?
    var bookmarks: [Int: CanvasBookmark]
    var layoutPresets: [LayoutPreset]
    var snippets: [Snippet]

    init(
        schemaVersion: Int,
        canvas: CanvasV9,
        focusedPane: PaneID?,
        maximizedPane: PaneID?,
        groups: [PaneGroup],
        connection: ConnectionTarget?,
        bookmarks: [Int: CanvasBookmark],
        layoutPresets: [LayoutPreset],
        snippets: [Snippet],
    ) {
        self.schemaVersion = schemaVersion
        self.canvas = canvas
        self.focusedPane = focusedPane
        self.maximizedPane = maximizedPane
        self.groups = groups
        self.connection = connection
        self.bookmarks = bookmarks
        self.layoutPresets = layoutPresets
        self.snippets = snippets
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case canvas
        case focusedPane
        case maximizedPane
        case groups
        case connection
        case bookmarks
        case layoutPresets
        case snippets
    }

    // Defensive decode: every collection defaults to empty, every optional to nil — a partial / hand-edited
    // v9 file decodes to a repairable value rather than throwing (the migration then normalizes it).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        canvas = try c.decodeIfPresent(CanvasV9.self, forKey: .canvas) ?? CanvasV9(items: [], camera: .zero)
        focusedPane = try c.decodeIfPresent(PaneID.self, forKey: .focusedPane)
        maximizedPane = try c.decodeIfPresent(PaneID.self, forKey: .maximizedPane)
        groups = try c.decodeIfPresent([PaneGroup].self, forKey: .groups) ?? []
        connection = try c.decodeIfPresent(ConnectionTarget.self, forKey: .connection)
        bookmarks = try c.decodeIfPresent([Int: CanvasBookmark].self, forKey: .bookmarks) ?? [:]
        layoutPresets = try c.decodeIfPresent([LayoutPreset].self, forKey: .layoutPresets) ?? []
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
    }
}

// MARK: - CanvasV9 (frozen mirror of the v9 Canvas wire shape)

/// Frozen mirror of the v9 ``Canvas``: a flat list of ``CanvasItemV9`` + the pan ``CameraV9``. Mirrors the
/// LIVE `Canvas` custom Codable wire shape (`{items, camera}`, camera optional → origin). An empty `items`
/// list is a VALID v9 state (the user closed the last pane) — never a decode failure here.
struct CanvasV9: Codable, Equatable {
    var items: [CanvasItemV9]
    var camera: CameraV9

    init(items: [CanvasItemV9], camera: CameraV9) {
        self.items = items
        self.camera = camera
    }

    private enum CodingKeys: String, CodingKey { case items, camera }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([CanvasItemV9].self, forKey: .items) ?? []
        camera = try c.decodeIfPresent(CameraV9.self, forKey: .camera) ?? .zero
    }
}

// MARK: - PaneKindV9 (frozen mirror of the v9 PaneKind, INCLUDING the retired `claudeCode`)

/// A **frozen** copy of the v9 ``PaneKind`` discriminator that — unlike the live `PaneKind` (which now
/// folds the retired `"claudeCode"` raw value into `.terminal`, docs/42 W11) — PRESERVES the legacy
/// `claudeCode` case. The migration reads it to rewrite a legacy Claude pane into a `.terminal` pane +
/// seed a `claude` launch snippet (it would otherwise be invisible — the live decode already collapsed
/// it). An unknown future raw value degrades to `.terminal` (validate-then-repair: never trap on a
/// hand-edited / newer file).
enum PaneKindV9: String, Codable, Equatable {
    case terminal
    case claudeCode
    case remoteGUI
    case systemDialog

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .terminal // unknown → safe default (no trap)
    }
}

// MARK: - PaneSpecV9 (frozen mirror of the v9 PaneSpec)

/// Frozen mirror of the v9 ``PaneSpec`` (`{kind, title, video?}`) using ``PaneKindV9`` so the legacy
/// `claudeCode` kind survives the decode (see ``PaneKindV9``). `VideoEndpoint` is reused verbatim (a
/// stable public value type). The migration consults `.kind`; it preserves `.title`/`.video` onto the
/// rewritten live ``PaneSpec``.
struct PaneSpecV9: Codable, Equatable {
    var kind: PaneKindV9
    var title: String
    var video: VideoEndpoint?

    init(kind: PaneKindV9, title: String, video: VideoEndpoint? = nil) {
        self.kind = kind
        self.title = title
        self.video = video
    }

    private enum CodingKeys: String, CodingKey { case kind, title, video }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(PaneKindV9.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        video = try c.decodeIfPresent(VideoEndpoint.self, forKey: .video)
    }
}

// MARK: - CanvasItemV9 (frozen mirror of one placed pane)

/// Frozen mirror of a v9 ``CanvasItem`` — the join key (``PaneID``), the frozen ``PaneSpecV9`` (which
/// keeps the legacy `claudeCode` kind), plus the soon-to-be-dropped `frame`/`z`/`groupID`. The migration
/// keeps `id`+`spec` (mapping the spec into the live tree side table, rewriting a legacy claude pane) and
/// reads `frame`/`groupID` only to deterministically order + bucket panes, then drops them.
///
/// The `frame` mirrors the live `WireRect` shape (`{origin:{x,y}, size:{width,height}}`); a missing /
/// malformed component falls back to a safe default so a hand-edited file never traps (validate-then-repair).
struct CanvasItemV9: Codable, Equatable {
    let id: PaneID
    var spec: PaneSpecV9
    var frame: CGRect
    var z: Int
    var groupID: PaneGroupID?

    init(id: PaneID, spec: PaneSpecV9, frame: CGRect, z: Int, groupID: PaneGroupID?) {
        self.id = id
        self.spec = spec
        self.frame = frame
        self.z = z
        self.groupID = groupID
    }

    private enum CodingKeys: String, CodingKey { case id, spec, frame, z, groupID }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PaneID.self, forKey: .id)
        spec = try c.decode(PaneSpecV9.self, forKey: .spec)
        frame = try (c.decodeIfPresent(WireRectV9.self, forKey: .frame))?.rect ?? .zero
        z = try c.decodeIfPresent(Int.self, forKey: .z) ?? 0
        groupID = try c.decodeIfPresent(PaneGroupID.self, forKey: .groupID)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(spec, forKey: .spec)
        try c.encode(WireRectV9(frame), forKey: .frame)
        try c.encode(z, forKey: .z)
        try c.encodeIfPresent(groupID, forKey: .groupID)
    }
}

// MARK: - CameraV9 (frozen mirror of the pan camera)

/// Frozen mirror of the v9 ``CanvasCamera`` (`{origin:{x,y}}`). The migration drops the camera (the tree
/// has no canvas-pan), but the field must DECODE so the frozen shape stays faithful to today's bytes.
struct CameraV9: Codable, Equatable {
    var origin: CGPoint

    init(origin: CGPoint) { self.origin = origin }

    static let zero = Self(origin: .zero)

    private enum CodingKeys: String, CodingKey { case origin }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        origin = try (c.decodeIfPresent(WirePointV9.self, forKey: .origin))?.point ?? .zero
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(WirePointV9(origin), forKey: .origin)
    }
}

// MARK: - Readable CoreGraphics wire mirrors (match the live Canvas+Codable shapes)

/// Mirrors the live `WirePoint` (`{x, y}`) — the readable object shape the v9 canvas persists CoreGraphics
/// points/origins as (NOT the synthesized opaque `[x, y]` array). A non-finite / missing component folds to
/// 0 so a corrupt file never traps.
private struct WirePointV9: Codable {
    var x: CGFloat
    var y: CGFloat

    init(_ p: CGPoint) {
        x = p.x
        y = p.y
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawX = try c.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0
        let rawY = try c.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0
        x = rawX.isFinite ? rawX : 0
        y = rawY.isFinite ? rawY : 0
    }

    private enum CodingKeys: String, CodingKey { case x, y }

    var point: CGPoint { CGPoint(x: x, y: y) }
}

/// Mirrors the live `WireSize` (`{width, height}`). Non-finite components fold to 0.
private struct WireSizeV9: Codable {
    var width: CGFloat
    var height: CGFloat

    init(_ s: CGSize) {
        width = s.width
        height = s.height
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawW = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? 0
        let rawH = try c.decodeIfPresent(CGFloat.self, forKey: .height) ?? 0
        width = rawW.isFinite ? rawW : 0
        height = rawH.isFinite ? rawH : 0
    }

    private enum CodingKeys: String, CodingKey { case width, height }

    var size: CGSize { CGSize(width: width, height: height) }
}

/// Mirrors the live `WireRect` (`{origin:{x,y}, size:{width,height}}`).
private struct WireRectV9: Codable {
    var origin: WirePointV9
    var size: WireSizeV9

    init(_ r: CGRect) {
        origin = WirePointV9(r.origin)
        size = WireSizeV9(r.size)
    }

    var rect: CGRect { CGRect(origin: origin.point, size: size.size) }
}
