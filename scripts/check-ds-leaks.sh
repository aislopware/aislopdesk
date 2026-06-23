#!/usr/bin/env bash
# Design-system leak RATCHET (P4) — a pure text-grep gate, no compile.
#
# WHAT IT GUARDS
# The design-system overhaul (docs spec: .work/night-verify/design-system-spec.md) routes every dimension
# through one token system (DSFont / DSSpace / DSRadius / DSColor / DSElevation). This gate fails the build
# if a VIEW file reintroduces:
#   (1) a raw `.font(.system(size: <number>))` or a raw integer `cornerRadius:`  — WHOLE-TREE scan; or
#   (2) a raw `.black.opacity(…)` scrim / `Color.white` literal in one of the SIX named L4 overlay files —
#       a TIGHT inverse-allowlist scan (the P4 scrim/shadow-colour unification headline; only those six
#       files are scanned for it, since the rest of the tree legitimately uses black/white tints).
# It is a RATCHET, not a burn-down: the six P4-migrated overlay files must stay clean (any new leak there
# trips immediately), while the ~10 out-of-scope files that still carry pre-P4 font/radius debt are
# allowlisted with a TODO so they cannot REGRESS but are not force-migrated here.
#
# SCOPE LIMIT (read before trusting this as a full token gate): it is TEXT-ONLY. It catches raw numeric
# literals via a leading-digit heuristic — `.font(.system(size: 14))` and `cornerRadius: 8` are caught;
# `.font(.system(size: UIMetrics.x))` / `cornerRadius: DSRadius.x` (token refs) pass, which is correct. But
# a future `size: someLocalVar` would also pass — this is a raw-literal regression guard, NOT a proof that
# every size is token-backed. `cornerRadius: 1.5` (a float) is intentionally NOT matched (the `[,)]` after
# the integer run excludes the decimal point), so TerminalScreenView's 1.5 corner is naturally skipped.
#
# PER-LINE ESCAPE HATCH: a single grandfathered line may carry an end-of-line `// ds-leak-allow` marker to
# exempt it (used for the PaneDeadScrim content-dim glyph, which is a deliberate white-on-dim affordance,
# not an L4 overlay). Use sparingly.
#
# REVERT-TO-CONFIRM-FAIL (the ratchet's own proof): add a synthetic leak to a NON-allowlisted, clean view
# file, e.g. append to PaneStatusBar.swift:
#     Text("x").font(.system(size: 99))
# then run `bash scripts/check-ds-leaks.sh` — it MUST exit 1 and report the file:line. Revert the line and
# it MUST exit 0. (This is exactly what the P4 hand-off ran to prove the gate bites.)
#
# Wired into `make lint` (and therefore `make check`) and the CI `swift-lint` job (text-only, no Xcode).
set -euo pipefail
cd "$(dirname "${0}")/.."

# ---------------------------------------------------------------------------- #
# L0 (Warp-clone UI rewrite): the old AislopdeskClientUI view target + its DesignSystem/ tokens were
# DELETED and the proven logic extracted into the headless AislopdeskWorkspaceCore. Until the rebuilt
# AislopdeskClientUI + AislopdeskDesignSystem land (L1/L2), there is no VIEW tree to ratchet — exit 0
# gracefully so `make lint` / `make check` stays green. (T2 will repoint this scan at the new
# DesignSystem/ClientUI dirs once they exist.)
if [[ ! -d "Sources/AislopdeskClientUI" && ! -d "Sources/AislopdeskDesignSystem" ]]; then
  echo "check-ds-leaks: no view target present (Sources/AislopdeskClientUI + Sources/AislopdeskDesignSystem absent) — SKIP (L0)."
  echo "PASS — nothing to scan yet."
  exit 0
fi

# ---------------------------------------------------------------------------- #
# Allowlist: files that legitimately still carry an out-of-P4-scope leak. A match in one of these is a
# known-debt WARNING, never a failure. The trailing comment is the reason / migration phase. The six P4
# overlay files (CommandPaletteView, FloatingPaneView, FloatingPaneHandle, PeekReplyView,
# KeyboardCheatSheet, ConnectionGateView) are DELIBERATELY ABSENT — they were migrated in P4 and must stay
# clean.
ALLOWLIST=(
  "Sources/AislopdeskClientUI/Terminal/TerminalBlocksView.swift"       # TODO(ds-migrate): terminal block chrome
  "Sources/AislopdeskClientUI/Terminal/TerminalFindBar.swift"          # TODO(ds-migrate): terminal find bar
  "Sources/AislopdeskClientUI/Terminal/TerminalRenderingView.swift"    # TODO(ds-migrate): headless placeholder glyph
  "Sources/AislopdeskClientUI/Video/VideoWindowSeam.swift"             # TODO(ds-migrate): video placeholder glyph
  "Sources/AislopdeskClientUI/Video/RemoteWindowPanel.swift"           # TODO(ds-migrate): remote-window panel radius
  "Sources/AislopdeskClientUI/Workspace/Views/PaneLeafView.swift"      # TODO(ds-migrate): pane empty-state glyph + radius
  "Sources/AislopdeskClientUI/Workspace/Views/CanvasView.swift"        # TODO(ds-migrate): retained (dead) canvas radii
  "Sources/AislopdeskClientUI/Workspace/Views/TabBarView.swift"        # TODO(ds-migrate): P3 residual size:7 badge glyph
  "Sources/AislopdeskClientUI/Workspace/Views/WorkspaceRootView.swift" # TODO(ds-migrate): badge chip radius
  "Sources/AislopdeskClientUI/Input/InputBarView.swift"                # TODO(ds-migrate): input bar chip radii
)

# The DesignSystem token sources + the three legacy shim files legitimately HOLD raw literals (they ARE the
# token source). DesignSystem/ is excluded by path; the shims by basename.
SHIM_BASENAMES='AislopdeskTheme.swift UIMetrics.swift UIScale.swift'

# The two whole-tree leak regexes (raw font size / integer corner radius).
FONT_RE='\.font\(\.system\(size: *[0-9]'
RADIUS_RE='cornerRadius: *[0-9]+ *[,)]|\.cornerRadius\( *[0-9]'

# Scrim / shadow-COLOUR ratchet (the P4 scrim-unification headline): a raw `.black.opacity(…)` backdrop
# or a `Color.white` literal in one of the SIX named L4 overlay files is a regression — those scrims/
# shadow colours were unified onto DSColor.scrim / DSElevation.shadow* in P4 and must not creep back. This
# is a TIGHT inverse-allowlist (only the six overlay files are scanned for it; the rest of the tree may
# legitimately use black/white tints). The per-line `// ds-leak-allow` escape hatch still applies — e.g.
# PaneDeadScrim's CONTENT-level dim (in FloatingPaneHandle.swift) is grandfathered line-by-line.
# `Color\.white\b` is matched with perl (BSD/macOS awk chokes on this ERE) so the prose/escape-hatch
# handling below is reliable across awk variants.
SCRIM_RE='\.black\.opacity\(|Color\.white\b'
SCRIM_FILES=(
  "Sources/AislopdeskClientUI/Workspace/Views/CommandPaletteView.swift"
  "Sources/AislopdeskClientUI/Workspace/Views/FloatingPaneView.swift"
  "Sources/AislopdeskClientUI/Workspace/Views/FloatingPaneHandle.swift"
  "Sources/AislopdeskClientUI/Workspace/Views/PeekReplyView.swift"
  "Sources/AislopdeskClientUI/Workspace/Views/KeyboardCheatSheet.swift"
  "Sources/AislopdeskClientUI/Connection/ConnectionGateView.swift"
)

is_scrim_scanned() {
  local path="${1}"
  local entry
  for entry in "${SCRIM_FILES[@]}"; do
    [[ "${path}" == "${entry}" ]] && return 0
  done
  return 1
}

is_allowlisted() {
  local path="${1}"
  local entry
  for entry in "${ALLOWLIST[@]}"; do
    [[ "${path}" == "${entry}" ]] && return 0
  done
  return 1
}

failures=0
warnings=0

while IFS= read -r file; do
  # Skip the DesignSystem token sources and the legacy shim files (their literals are the token source).
  case "${file}" in
    *"/DesignSystem/"*) continue ;;
    *) ;;
  esac
  base="$(basename "${file}")"
  case " ${SHIM_BASENAMES} " in
    *" ${base} "*) continue ;;
    *) ;;
  esac

  # (1) Whole-tree font/radius leaks, honouring the per-line `// ds-leak-allow` escape hatch.
  hits="$(grep -nE "${FONT_RE}|${RADIUS_RE}" "${file}" | grep -v 'ds-leak-allow' || true)"
  if [[ -n "${hits}" ]]; then
    if is_allowlisted "${file}"; then
      while IFS= read -r line; do
        printf 'WARN  (allowlisted known debt) %s:%s\n' "${file}" "${line}"
        warnings=$((warnings + 1))
      done <<< "${hits}"
    else
      while IFS= read -r line; do
        printf 'FAIL  (raw DS leak — migrate to a token) %s:%s\n' "${file}" "${line}"
        failures=$((failures + 1))
      done <<< "${hits}"
    fi
  fi

  # (2) Scrim / shadow-colour leaks — ONLY in the six named L4 overlay files (the P4 unification set).
  # A match here is ALWAYS a failure (no allowlist — these six files are the unified set and must stay
  # clean). The line's trailing `//` comment is blanked before the match so PROSE that merely NAMES the
  # banned literal (e.g. a doc-comment "the old Color.white over a solid fill is gone") does not trip the
  # gate — only a literal in LIVE CODE does — while a line carrying `// ds-leak-allow` is skipped wholesale
  # (the per-line escape hatch, used for PaneDeadScrim's content-level dim). Perl gives reliable regex +
  # exact line numbers (BSD/macOS awk rejects the ERE); it prints `<n>:<original line>` for each hit.
  if is_scrim_scanned "${file}"; then
    scrim_hits="$(perl -ne '
      next if /ds-leak-allow/;                  # per-line escape hatch (checked on the FULL line)
      ($code = $_) =~ s{//.*$}{};               # blank the trailing // comment before matching
      print "$.:$_" if $code =~ /'"${SCRIM_RE}"'/;
    ' "${file}" || true)"
    if [[ -n "${scrim_hits}" ]]; then
      while IFS= read -r line; do
        printf 'FAIL  (raw scrim/shadow colour — use DSColor.scrim / DSElevation.shadow*) %s:%s\n' \
          "${file}" "${line}"
        failures=$((failures + 1))
      done <<< "${scrim_hits}"
    fi
  fi
  # Enumerate BOTH the single-level files (Sources/AislopdeskClientUI/*.swift — e.g. the app-entry
  # AislopdeskClientApp.swift) AND the nested files. A git pathspec `**/` requires at least one
  # intervening directory, so the nested glob ALONE silently skips the top-level files (135 → 134) and
  # the ratchet would not cover a leak added to the app-entry view. The two-glob form covers both depths.
done < <(git ls-files 'Sources/AislopdeskClientUI/*.swift' 'Sources/AislopdeskClientUI/**/*.swift')

echo "---"
echo "check-ds-leaks: ${failures} failure(s), ${warnings} allowlisted-debt warning(s)"
if [[ "${failures}" -gt 0 ]]; then
  echo "A view file reintroduced a raw .font(.system(size:)) / integer cornerRadius:, or a raw scrim/"
  echo "shadow colour (.black.opacity / Color.white) in one of the six L4 overlay files. Migrate it to a"
  echo "DSFont / DSRadius / DSColor.scrim / DSElevation.shadow* token, or (rarely) add an end-of-line"
  echo "// ds-leak-allow marker."
  exit 1
fi
echo "PASS — no new design-system leaks."
