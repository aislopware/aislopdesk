// RecipeTrustSheet — the command-replay trust prompt (E16 WI-10, spec `customization__custom-commands.md`
// §Security for Command Replay). When you open an UNFAMILIAR `.aislopdeskrecipe` that carries commands, the store
// (`WorkspaceStore.openRecipe`) parks a `RecipeTrustPrompt` instead of running anything; this sheet SHOWS the
// commands first and offers three choices:
//   • Always Trust → remember the file by its SHA-256 hash, then follow the replay settings;
//   • Run Once     → run this instance only, prompt again next time;
//   • Cancel       → open nothing.
// Editing the file changes its bytes → a new hash → a fresh prompt (the store's trust model owns that). The
// SHA-256 here is a local trust-on-first-use CHECKSUM, not app-layer crypto/auth (see `RecipeTrust.swift`).
//
// Slate.* tokens only (raw font/radius literals fail `scripts/check-ds-leaks.sh`).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

/// The trust prompt for an unfamiliar command-carrying recipe. Built off the store's parked
/// `RecipeTrustPrompt`; each button routes through the store's `confirmTrust` / `cancelTrust` and dismisses.
struct RecipeTrustSheet: View {
    let store: WorkspaceStore
    let prompt: RecipeTrustPrompt

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space4) {
            header
            intro
            commandList
            footer
        }
        .padding(Slate.Metric.space4)
        #if os(macOS)
            .frame(width: 520)
        #else
            .frame(maxWidth: 520)
        #endif
            .background(Slate.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: Slate.Metric.radiusCard))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Slate.Metric.space2) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: Slate.Typeface.body, weight: .semibold))
                .foregroundStyle(Slate.Status.warn)
            Text("Run commands from this recipe?")
                .font(.system(size: Slate.Typeface.body, weight: .semibold))
                .foregroundStyle(Slate.Text.primary)
            Spacer(minLength: 0)
        }
    }

    private var intro: some View {
        Text(introText)
            .font(.system(size: Slate.Typeface.footnote))
            .foregroundStyle(Slate.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var introText: String {
        let trimmed = prompt.recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "This recipe" : "“\(trimmed)”"
        return "\(label) wants to run the following commands. Only run commands you recognize and trust."
    }

    // MARK: Commands

    private var commandList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Slate.Metric.space1) {
                ForEach(Array(prompt.commands.enumerated()), id: \.offset) { _, command in
                    Text(command)
                        .font(.system(size: Slate.Typeface.body).monospaced())
                        .foregroundStyle(Slate.Text.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Slate.Metric.space2)
        }
        .frame(maxHeight: 180)
        .background(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                .fill(Slate.Surface.element),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
        )
    }

    // MARK: Footer (Cancel · Run Once · Always Trust)

    private var footer: some View {
        HStack(spacing: Slate.Metric.space2) {
            Button("Cancel") { cancel() }
                .buttonStyle(.plain)
                .font(.system(size: Slate.Typeface.body))
                .foregroundStyle(Slate.Text.secondary)
                .padding(.horizontal, Slate.Metric.space3)
                .padding(.vertical, Slate.Metric.space1)
            Spacer(minLength: 0)
            secondaryButton("Run Once") { confirm(alwaysTrust: false) }
            primaryButton("Always Trust") { confirm(alwaysTrust: true) }
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Slate.Typeface.body, weight: .medium))
                .foregroundStyle(Slate.Text.primary)
                .padding(.horizontal, Slate.Metric.space3)
                .padding(.vertical, Slate.Metric.space1)
                .background(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                        .fill(Slate.Surface.element),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                        .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
                )
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
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

    // MARK: Actions

    private func confirm(alwaysTrust: Bool) {
        store.confirmTrust(alwaysTrust: alwaysTrust)
        dismiss()
    }

    private func cancel() {
        store.cancelTrust()
        dismiss()
    }
}
#endif
