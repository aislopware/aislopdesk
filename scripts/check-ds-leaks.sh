#!/usr/bin/env bash
# Design-token leak RATCHET — RETIRED in the native-SwiftUI rewrite (REBUILD-V2).
#
# The old gate scanned the Warp-clone view tree for raw `.font(.system(size:))` / integer `cornerRadius:` /
# raw scrim colours, forcing every dimension through the custom `AislopdeskDesignSystem` token system. That
# token target was DELETED in L0 — the rebuilt UI uses STOCK SwiftUI with SYSTEM semantic colours and
# system fonts/sizes (`.font(.system(...))`, `Color(.windowBackgroundColor)`, `.regularMaterial`, …), so the
# font/radius/scrim ban is obsolete (those literals are now the intended, correct style).
#
# Kept as a harmless no-op because the Makefile (`make lint`/`make check`) and the CI `swift-lint` job still
# reference it. Always exits 0.
set -euo pipefail

echo "check-ds-leaks: design-token ratchet retired in native-SwiftUI rewrite — native uses system fonts/sizes."
exit 0
