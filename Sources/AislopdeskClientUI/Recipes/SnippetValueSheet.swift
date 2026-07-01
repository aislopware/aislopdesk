// SnippetValueSheet — the placeholder value-entry modal a PARAMETERIZED snippet needs before it runs (E16
// WI-7 / M5). The ⌘⇧P palette routes a snippet selection through `WorkspaceStore.beginRunSnippet(id)`: a
// snippet whose body carries a NON-reserved `{{placeholder}}` (`ssh {{host}}`) returns `.needsValues` and
// arms `store.pendingSnippetRun`, expecting a UI to collect a value per slot. Before this sheet existed
// NOTHING consumed that flag, so selecting such a snippet from the palette silently did nothing.
//
// This sheet is mounted off `store.pendingSnippetRun` in `RecipeSheetsHost` (the same place the other recipe
// modals ride their `pending*` flags), prompts ONLY the user-prompt slots — `ReservedSnippetVars`'s four
// reserved names ({{date}}/{{time}}/{{clipboard}}/{{cursor}}) are resolved automatically and must never
// surface here — collects a value per slot, and on Run calls `store.runSnippet(id, values:)` +
// `clearSnippetRunRequest()`. Cancel just clears the flag. A reserved-only / placeholder-free body never
// reaches this sheet (it runs immediately via `beginRunSnippet`).
//
// Plain SwiftUI — no NSWindow / WKWebView. Slate.* tokens only (raw font/radius literals fail
// `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import Foundation
import SwiftUI

/// The pure, headless backing for ``SnippetValueSheet`` — the ordered USER-prompt slots to ask for and the
/// value collected per slot. Factored out of the view so the value-collection → `runSnippet` contract is
/// unit-testable without instantiating SwiftUI: `slots` is exactly ``ReservedSnippetVars/userPlaceholders(in:)``
/// (reserved names excluded), and ``collectedValues`` is what the sheet hands to ``WorkspaceStore/runSnippet(_:values:)``.
struct SnippetValueForm {
    /// The snippet whose values are being collected.
    let snippetID: UUID
    /// The user-prompt placeholder names, first-appearance order, deduped, reserved names removed.
    let slots: [String]
    /// The value typed per slot (seeded empty so an untouched slot resolves to "" rather than a literal `{{}}`).
    var values: [String: String]

    init(snippetID: UUID, body: String) {
        self.snippetID = snippetID
        let slots = ReservedSnippetVars.userPlaceholders(in: body)
        self.slots = slots
        values = Dictionary(uniqueKeysWithValues: slots.map { ($0, "") })
    }

    /// The dictionary handed to ``WorkspaceStore/runSnippet(_:values:)`` — every slot present (blank ones
    /// included) so no unresolved `{{slot}}` can leak as literal braces.
    var collectedValues: [String: String] { values }
}

/// The placeholder value-entry sheet for a parameterized snippet. Built from the snippet's body so it asks
/// only for the user-prompt slots; Run resolves + injects through the store, Cancel disarms.
struct SnippetValueSheet: View {
    let store: WorkspaceStore
    @State private var form: SnippetValueForm

    @Environment(\.dismiss) private var dismiss

    init(store: WorkspaceStore, snippetID: UUID, body: String) {
        self.store = store
        _form = State(initialValue: SnippetValueForm(snippetID: snippetID, body: body))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space4) {
            header
            slotFields
            footer
        }
        .padding(Slate.Metric.space4)
        #if os(macOS)
            .frame(width: 420)
        #else
            .frame(maxWidth: 420)
        #endif
            .background(Slate.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: Slate.Metric.radiusCard))
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Snippet Values")
                .font(.system(size: Slate.Typeface.body, weight: .semibold))
                .foregroundStyle(Slate.Text.primary)
            Spacer(minLength: 0)
            Button { cancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Slate.Text.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: Slots

    private var slotFields: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space3) {
            ForEach(form.slots, id: \.self) { slot in
                VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                    Text(slot)
                        .font(.system(size: Slate.Typeface.base, weight: .medium).monospaced())
                        .foregroundStyle(Slate.Text.primary)
                    TextField(slot, text: binding(for: slot))
                        .textFieldStyle(.plain)
                        .font(.system(size: Slate.Typeface.body).monospaced())
                        .foregroundStyle(Slate.Text.primary)
                        .tint(Slate.State.accent)
                        .padding(Slate.Metric.space2)
                        .background(plate)
                }
            }
        }
    }

    private func binding(for slot: String) -> Binding<String> {
        Binding(
            get: { form.values[slot] ?? "" },
            set: { form.values[slot] = $0 },
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Slate.Metric.space2) {
            Spacer(minLength: 0)
            Button("Cancel") { cancel() }
                .buttonStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.secondary)
                .padding(.horizontal, Slate.Metric.space3)
                .padding(.vertical, Slate.Metric.space1)
            Button(action: run) {
                Text("Run")
                    .font(.system(size: Slate.Typeface.body, weight: .semibold))
                    .foregroundStyle(Slate.Surface.card)
                    .padding(.horizontal, Slate.Metric.space3)
                    .padding(.vertical, Slate.Metric.space1)
                    .background(
                        RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                            .fill(Slate.State.accent),
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var plate: some View {
        RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
            .fill(Slate.Surface.element)
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                    .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
            )
    }

    // MARK: Actions

    private func run() {
        store.runSnippet(form.snippetID, values: form.collectedValues)
        store.clearSnippetRunRequest()
        dismiss()
    }

    private func cancel() {
        store.clearSnippetRunRequest()
        dismiss()
    }
}
#endif
