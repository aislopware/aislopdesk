#!/usr/bin/env bash
# Design-system leak RATCHET (P4) — a pure text-grep gate, no compile.
#
# WHAT IT GUARDS
# The design-system overhaul (docs spec: .work/night-verify/design-system-spec.md) routes every dimension
# through one token system (DSFont / DSSpace / DSRadius / DSColor / DSElevation). This gate fails the build
# if a VIEW file reintroduces:
#   (1) a raw `.font(.system(size: <number>))` or a raw integer `cornerRadius:`  — WHOLE-TREE scan; or
#   (2) a raw `.black.opacity(…)` scrim / `Color.white` literal in one of the named L0-rebuild overlay /
#       palette surfaces — a TIGHT inverse-allowlist scan (the scrim/shadow-colour unification headline;
#       only those overlay surfaces are scanned for it, since the rest of the tree legitimately uses
#       black/white tints). The real scrim/shadow now lives in AislopdeskDesignSystem (WarpShadow.scrim /
#       WarpShadow.modalBackdrop / WarpShadow.color), NOT the deleted DSColor.scrim / DSElevation.shadow*.
# It is a RATCHET, not a burn-down: the listed overlay surfaces must stay clean (any new leak there trips
# immediately). The rebuilt tree is font/radius-clean, so the ALLOWLIST is empty.
#
# SCOPE LIMIT (read before trusting this as a full token gate): it is TEXT-ONLY. It catches raw numeric
# literals via a leading-digit heuristic — `.font(.system(size: 14))` and `cornerRadius: 8` are caught;
# `.font(.system(size: UIMetrics.x))` / `cornerRadius: DSRadius.x` (token refs) pass, which is correct. But
# a future `size: someLocalVar` would also pass — this is a raw-literal regression guard, NOT a proof that
# every size is token-backed. `cornerRadius: 1.5` (a float) is intentionally NOT matched (the `[,)]` after
# the integer run excludes the decimal point), so TerminalScreenView's 1.5 corner is naturally skipped.
#
# PER-LINE ESCAPE HATCH: a single grandfathered line may carry an end-of-line `// ds-leak-allow` marker to
# exempt it (used for DismissBackdrop's near-zero-opacity hit-test fill, which is a click-blocker, not a
# scrim). Use sparingly.
#
# REVERT-TO-CONFIRM-FAIL (the ratchet's own proof): temporarily insert a synthetic scrim leak into one of
# the listed SCRIM_FILES, e.g. add to Overlays/ConfirmModal.swift:
#     Color.black.opacity(0.7)
# then run `bash scripts/check-ds-leaks.sh` — it MUST exit 1 and report the file:line. Revert the line and
# it MUST exit 0.
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
# Allowlist: files that legitimately still carry an out-of-scope font/radius leak (known-debt WARNING, not
# a failure). The rebuilt L0 tree is font/radius-clean, so this is EMPTY; add a path + TODO here only if a
# genuine out-of-scope debt lands.
ALLOWLIST=(
)

# The DesignSystem token sources legitimately HOLD raw literals (they ARE the token source). They live
# under Sources/AislopdeskDesignSystem/ and are excluded by the */DesignSystem/* path-skip below. No
# separate shim basenames exist in the rebuilt tree (the old AislopdeskTheme/UIMetrics/UIScale shims were
# deleted in L0), so this list is empty.
SHIM_BASENAMES=''

# The two whole-tree leak regexes (raw font size / integer corner radius).
FONT_RE='\.font\(\.system\(size: *[0-9]'
RADIUS_RE='cornerRadius: *[0-9]+ *[,)]|\.cornerRadius\( *[0-9]'

# Scrim / shadow-COLOUR ratchet (the scrim-unification headline): a raw `.black.opacity(…)` backdrop or a
# `Color.white` literal in one of the named L0-rebuild overlay / palette surfaces is a regression — those
# scrims / shadow colours are unified onto WarpShadow.scrim / WarpShadow.modalBackdrop / WarpShadow.color
# (DesignTokens.shadowColor / .scrim) and must not creep back. This is a TIGHT inverse-allowlist (only
# these overlay surfaces are scanned for it; the rest of the tree may legitimately use black/white tints).
# The per-line `// ds-leak-allow` escape hatch still applies — e.g. DismissBackdrop's near-zero-opacity
# hit-test fill is grandfathered line-by-line. `Color\.white\b` is matched with perl (BSD/macOS awk chokes
# on this ERE) so the prose/escape-hatch handling below is reliable across awk variants.
SCRIM_RE='\.black\.opacity\(|Color\.white\b'
SCRIM_FILES=(
  "Sources/AislopdeskClientUI/Overlays/SettingsOverlay.swift"
  "Sources/AislopdeskClientUI/Overlays/ConfirmModal.swift"
  "Sources/AislopdeskClientUI/Overlays/ToastStackView.swift"
  "Sources/AislopdeskClientUI/Overlays/OverlayLayer.swift"
  "Sources/AislopdeskClientUI/Overlays/DismissBackdrop.swift"
  "Sources/AislopdeskClientUI/Palette/CommandPaletteView.swift"
  "Sources/AislopdeskClientUI/Remote/RemoteWindowPicker.swift"
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

  # (2) Scrim / shadow-colour leaks — ONLY in the named L0-rebuild overlay/palette surfaces (the
  # unification set). A match here is ALWAYS a failure (no allowlist — these files are the unified set and
  # must stay clean). The line's trailing `//` comment is blanked before the match so PROSE that NAMES the
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
        printf 'FAIL  (raw scrim/shadow colour — use WarpShadow.scrim / .modalBackdrop / .color) %s:%s\n' \
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
  echo "shadow colour (.black.opacity / Color.white) in one of the listed overlay/palette surfaces. Migrate"
  echo "it to a WarpType / WarpRadius / WarpShadow token (e.g. WarpShadow.scrim / .modalBackdrop / .color),"
  echo "or (rarely) add an end-of-line // ds-leak-allow marker."
  exit 1
fi
echo "PASS — no new design-system leaks."
