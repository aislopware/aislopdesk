// KeybindingsEditorView — the Settings ▸ Keybindings editor (REBUILD-V2, WS-D / D6).
//
// Renders one row per `WorkspaceBindingRegistry.allBindings` entry (title / category / SF Symbol / the
// effective chord) and lets the user CAPTURE a replacement chord. A captured chord is written into
// `PreferencesStore.keybindings` (`KeybindingPreferences.overrides`, keyed by the registry `bindingID`).
// That is the WHOLE persistence story: the store's `keybindings` `didSet` already republishes the model to
// `WorkspaceBindingRegistry.activeOverrides`, which drives `resolvedChordTable` — so this view adds NO new
// persistence channel (D6 invariant). Conflicts come straight from `store.keybindingConflicts()`.
//
// SCOPE (D6): SINGLE-key chords only — the editor edits whatever the registry's chord model exposes today.
// WS-B later extends the chord model to multi-key sequences; this view re-renders whatever the registry
// surfaces, so it needs no change for that. Chord CAPTURE is a macOS-only `NSEvent` local monitor (the
// client's primary surface); on iOS the rows render read-only (no hardware-key capture UI here).

#if canImport(SwiftUI)
import AislopdeskVideoProtocol
import AislopdeskWorkspaceCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The Keybindings tab body: a scrollable, category-grouped list of every registry binding with its
/// effective chord and a "record a new chord" affordance. Binds the live `PreferencesStore` (D4 hands it
/// in as `@Bindable`); writes overrides through `store.keybindings`.
struct KeybindingsEditorView: View {
    @Bindable var store: PreferencesStore

    /// The binding id currently in capture mode (its row shows "Press a key…"), or `nil`. Only one row
    /// records at a time so the local key monitor has a single unambiguous target.
    @State private var recordingID: String?

    var body: some View {
        let conflicts = store.keybindingConflicts()
        // The set of binding ids that collide with at least one other id on the same chord (for the badge).
        let conflictingIDs = Set(conflicts.values.flatMap(\.self))

        VStack(alignment: .leading, spacing: Otty.Metric.space3) {
            header
            if !conflicts.isEmpty {
                conflictBanner(conflicts)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Otty.Metric.space3, pinnedViews: [.sectionHeaders]) {
                    ForEach(WorkspaceAction.Category.allCases, id: \.self) { category in
                        let rows = bindings(in: category)
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows, id: \.id) { binding in
                                    row(for: binding, isConflicting: conflictingIDs.contains(binding.id))
                                }
                            } header: {
                                OttySectionHeader(category.rawValue)
                                    .background(Otty.Surface.window)
                            }
                        }
                    }
                }
            }
        }
        .padding(Otty.Metric.space4)
        #if os(macOS)
            .background(KeyCaptureMonitor(isActive: recordingID != nil) { event in
                handleCapturedEvent(event)
            })
        #endif
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Otty.Metric.space1) {
            Text("Keyboard Shortcuts")
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
            Text("Click a shortcut to record a replacement. Single-key chords only.")
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.secondary)
        }
    }

    private func conflictBanner(_ conflicts: [String: [String]]) -> some View {
        // Each conflict key is a canonical chord string shared by ≥2 ids; surface them plainly.
        let lines = conflicts.map { chord, ids -> String in
            let titles = ids.compactMap { id in binding(forID: id)?.title }.sorted()
            return "\(chord): \(titles.joined(separator: ", "))"
        }.sorted()
        return VStack(alignment: .leading, spacing: Otty.Metric.space1) {
            Label("Shortcut conflicts", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: Otty.Typeface.footnote, weight: .semibold))
                .foregroundStyle(Otty.Status.warn)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: Otty.Typeface.small))
                    .foregroundStyle(Otty.Text.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Otty.Metric.space2)
        .ottyCard()
    }

    private func row(for binding: WorkspaceBinding, isConflicting: Bool) -> some View {
        let isRecording = recordingID == binding.id
        let isOverridden = store.keybindings.chord(for: binding.id) != nil
        return HStack(spacing: Otty.Metric.space2) {
            Image(systemName: binding.symbol)
                .font(.system(size: Otty.Metric.iconSize))
                .foregroundStyle(Otty.Text.icon)
                .frame(width: 18)
            Text(binding.title)
                .font(.system(size: Otty.Typeface.base))
                .foregroundStyle(Otty.Text.primary)
                .lineLimit(1)
            if isConflicting {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: Otty.Typeface.small))
                    .foregroundStyle(Otty.Status.warn)
                    .help("This shortcut conflicts with another command")
            }
            Spacer(minLength: Otty.Metric.space2)
            chordChip(for: binding, isRecording: isRecording)
            if isOverridden {
                Button {
                    clearOverride(binding.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: Otty.Typeface.small))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Otty.Text.icon)
                .help("Reset to default")
            }
        }
        .padding(.vertical, 4)
    }

    /// The trailing chord chip — the effective shortcut glyph, tappable to start recording. While recording
    /// it reads "Press a key…"; click again (or Escape, handled by the monitor) to cancel.
    private func chordChip(for binding: WorkspaceBinding, isRecording: Bool) -> some View {
        Button {
            toggleRecording(binding.id)
        } label: {
            Text(isRecording ? "Press a key…" : effectiveGlyph(for: binding))
                .font(.system(size: Otty.Typeface.footnote, weight: .medium))
                .foregroundStyle(isRecording ? Otty.State.accent : Otty.Text.secondary)
                .lineLimit(1)
                .padding(.horizontal, Otty.Metric.space2)
                .padding(.vertical, 2)
                .frame(minWidth: 64)
                .background(
                    isRecording ? Otty.State.accentMuted : Otty.Surface.element,
                    in: RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall, style: .continuous),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Otty.Metric.radiusSmall, style: .continuous)
                        .strokeBorder(isRecording ? Otty.State.accent : Otty.Line.subtle, lineWidth: 1),
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Data helpers

    /// The bindings in `category`, excluding the synthetic ⌘1…⌘9 representative (it has no single chord to
    /// rebind and the real per-digit chords are an implementation detail). Reads `allBindings` so the
    /// generated select-tab chords are present but the display-only representative is filtered out.
    private func bindings(in category: WorkspaceAction.Category) -> [WorkspaceBinding] {
        WorkspaceBindingRegistry.allBindings.filter {
            $0.category == category && $0.id != WorkspaceBindingRegistry.selectTabRepresentative.id
        }
    }

    private func binding(forID id: String) -> WorkspaceBinding? {
        WorkspaceBindingRegistry.allBindings.first { $0.id == id }
    }

    /// The glyph for the binding's EFFECTIVE chord: the user override (if it maps) else the registry
    /// default. Mirrors `WorkspaceBindingRegistry.resolvedChord(for:)` so the chip shows what actually fires.
    private func effectiveGlyph(for binding: WorkspaceBinding) -> String {
        if let override = store.keybindings.chord(for: binding.id), let mapped = override.asRegistryChord {
            return WorkspaceBindingRegistry.glyph(mapped)
        }
        if let chord = binding.chord {
            return WorkspaceBindingRegistry.glyph(chord)
        }
        return "—"
    }

    // MARK: Mutation (all routed through `store.keybindings`)

    private func toggleRecording(_ id: String) {
        recordingID = (recordingID == id) ? nil : id
    }

    /// Remove the override for `id` (restores the registry default). Writes a fresh model so the store's
    /// `didSet` fires (it compares to `oldValue`).
    private func clearOverride(_ id: String) {
        guard store.keybindings.chord(for: id) != nil else { return }
        var overrides = store.keybindings.overrides
        overrides.removeValue(forKey: id)
        store.keybindings = KeybindingPreferences(overrides: overrides)
    }

    /// Write `chord` as the override for `id` and stop recording. The single persistence channel: setting
    /// `store.keybindings` republishes to `WorkspaceBindingRegistry.activeOverrides` (D6 invariant).
    private func setOverride(_ chord: KeybindingPreferences.KeyChord, for id: String) {
        var overrides = store.keybindings.overrides
        overrides[id] = chord
        store.keybindings = KeybindingPreferences(overrides: overrides)
        recordingID = nil
    }

    #if os(macOS)
    /// Map a captured `NSEvent` to a `KeybindingPreferences.KeyChord` and store it for the recording row.
    /// Escape cancels (no write); an event with no usable base key is ignored (stays in recording mode).
    private func handleCapturedEvent(_ event: NSEvent) {
        guard let id = recordingID else { return }
        // Escape (keyCode 53) cancels recording without writing an override.
        if event.keyCode == 53 {
            recordingID = nil
            return
        }
        guard let key = Self.baseKey(for: event) else { return }
        let mods = event.modifierFlags
        let chord = KeybindingPreferences.KeyChord(
            key: key,
            command: mods.contains(.command),
            shift: mods.contains(.shift),
            option: mods.contains(.option),
            control: mods.contains(.control),
        )
        setOverride(chord, for: id)
    }

    /// The normalized base-key token for an `NSEvent` (a lowercased single character or a named key the
    /// `KeybindingPreferences.KeyChord` → registry mapping recognises). `nil` for a pure modifier / unmapped
    /// key so the caller keeps recording.
    private static func baseKey(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36,
             76: return "return" // Return / keypad Enter
        case 48: return "tab"
        case 123: return "left"
        case 124: return "right"
        case 126: return "up"
        case 125: return "down"
        case 116: return "pageup"
        case 121: return "pagedown"
        case 115: return "home"
        case 119: return "end"
        default: break
        }
        // `charactersIgnoringModifiers` gives the base key independent of shift/option (so ⇧2 is "2").
        guard let chars = event.charactersIgnoringModifiers, let first = chars.first else { return nil }
        // Reject control characters / whitespace; accept a single printable char (lowercased by KeyChord).
        guard chars.count == 1, !first.isWhitespace, first.isASCII || first.isLetter else { return nil }
        return String(first).lowercased()
    }
    #endif
}

#if os(macOS)
/// A zero-size `NSViewRepresentable` that installs a LOCAL `NSEvent` keyDown monitor while `isActive` so a
/// captured keystroke reaches `onKey` (and is SWALLOWED — the monitor returns `nil` so the keystroke does
/// not also trigger a menu shortcut / type into a field while recording). Removed when inactive.
private struct KeyCaptureMonitor: NSViewRepresentable {
    let isActive: Bool
    let onKey: (NSEvent) -> Void

    func makeNSView(context _: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onKey = onKey
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        var onKey: (NSEvent) -> Void = { _ in }
        private var monitor: Any?
        var isActive: Bool = false {
            didSet {
                if isActive { install() } else { teardown() }
            }
        }

        private func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.onKey(event)
                return nil // swallow the keystroke while recording
            }
        }

        func teardown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
#endif
