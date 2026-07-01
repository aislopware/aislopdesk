import Foundation

/// A theme-SLOT reference (E15) — points at either a built-in ``SlateTheme`` (by its stable id) or a scanned
/// custom ``ThemeDocument`` (by slug). Stored on ``AppearancePreferences`` for the light / dark slots.
///
/// WIRE-FORM: a SINGLE string, `"builtin:<id>"` or `"custom:<slug>"`, so it nests cleanly inside the
/// `UserDefaults`-persisted appearance blob and reads as one human-legible token. An UNKNOWN form (a stale
/// schema, a typo, a slot pointing at a since-deleted custom theme that was renamed) DECODE-FAILS — which, by
/// the validate-then-default rule, bubbles up to fail the whole ``AppearancePreferences`` decode back to its
/// all-`nil` default (no migration; the slot then resolves to the compile-time default theme).
public enum ThemeRef: Codable, Sendable, Equatable {
    /// A shipped theme, keyed by its ``SlateTheme`` `id` (e.g. `"monokai-classic"`, `"dark"`).
    case builtin(String)
    /// A user theme scanned from the themes folder, keyed by its ``ThemeDocument`` slug.
    case custom(slug: String)

    /// The single-string wire form: `"builtin:<id>"` / `"custom:<slug>"`.
    public var encoded: String {
        switch self {
        case let .builtin(id): "builtin:\(id)"
        case let .custom(slug): "custom:\(slug)"
        }
    }

    /// Parse the single-string wire form, or `nil` for any unknown / empty-payload form (the caller then
    /// decode-fails to the appearance default). A bare prefix with no payload (`"builtin:"`) is rejected.
    public init?(encoded raw: String) {
        if raw.hasPrefix(Self.builtinPrefix) {
            let id = String(raw.dropFirst(Self.builtinPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .builtin(id)
        } else if raw.hasPrefix(Self.customPrefix) {
            let slug = String(raw.dropFirst(Self.customPrefix.count))
            guard !slug.isEmpty else { return nil }
            self = .custom(slug: slug)
        } else {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let ref = Self(encoded: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unknown ThemeRef form: \(raw)",
            )
        }
        self = ref
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encoded)
    }

    private static let builtinPrefix = "builtin:"
    private static let customPrefix = "custom:"
}
