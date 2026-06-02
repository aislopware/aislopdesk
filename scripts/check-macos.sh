#!/usr/bin/env bash
#
# check-macos.sh — macOS RUNTIME self-verify gate (the desktop counterpart to maestro+iOS).
#
# WHY this exists: `swift test` proves the headless logic, `check-ios.sh` type-checks the
# iOS slice, and maestro screenshots the iOS Simulator. The one gap is the *macOS GUI app at
# runtime* — maestro cannot drive a native macOS app (it only targets iOS/Android/web). This
# script closes that gap with the toolchain every Mac already has: build → launch → screenshot.
# An agent (or a human) then READS the PNG to confirm the window actually rendered the expected
# UI (connection bar, terminal seam, input bar) — exactly how the iOS path is verified visually.
#
# WHAT it does:
#   1. (optional, --renderer) wire in the libghostty renderer via enable-macos-renderer.sh, and
#      restore the committed placeholder project.yml on exit so `git status` stays clean.
#   2. Build an unsigned (ad-hoc) Debug Rwork.app into .work/macos-verify/ (gitignored).
#   3. Launch it via LaunchServices (`open`) and poll for the macOS process (NOT the iOS-Simulator
#      "Rwork" process, which shares the name).
#   4. Wait, then assert the process is still alive (a launch-time crash ⇒ it dies in ~3 s).
#   5. Capture a full-screen PNG to .work/macos-verify/macos-shot.png for visual verification.
#
# EXIT: non-zero if the build fails or the app dies within the settle window (a real runtime gate).
#
# STATUS: both modes pass. The PLACEHOLDER build runs fine, and as of 2026-06-02 the --renderer
# build also runs at runtime: the earlier ~3 s launch crash (exit 6, EXC_BREAKPOINT) was an
# off-main `MainActor.assumeIsolated` in libghostty's wakeup/write/resize callbacks — libghostty
# fires them from its `renderer`/`io` threads on macOS, and `assumeIsolated` is a precondition
# that traps off-main. Fixed via the `ghosttyOnMainActor` helper (sync on main, hop otherwise).
# `check-macos.sh --renderer` now launches, survives the settle window, and renders glyphs.
#
# Requires a logged-in GUI session (WindowServer) — it drives a real window, so it is not
# headless. Run from anywhere: paths resolve relative to the repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$REPO_ROOT/Apps/ClientApp-macOS/project.yml"
PROJECT="$REPO_ROOT/Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj"
WORK="$REPO_ROOT/.work/macos-verify"
DD="$WORK/DerivedData"
APP="$DD/Build/Products/Debug/Rwork.app"
SHOT="$WORK/macos-shot.png"
SETTLE=4   # seconds to let the window appear / a launch-time crash to surface

WITH_RENDERER=0
[[ "${1:-}" == "--renderer" ]] && WITH_RENDERER=1

mkdir -p "$WORK"

# The macOS app and the iOS-Simulator app share the binary name "Rwork"; match ONLY the macOS
# build product path so we never touch the Simulator's process.
APP_PROC_PAT="macos-verify/DerivedData.*MacOS/Rwork"

cleanup() {
  pkill -f "$APP_PROC_PAT" 2>/dev/null || true
  if [[ "$WITH_RENDERER" == "1" ]]; then
    echo "==> restoring committed placeholder project.yml"
    git -C "$REPO_ROOT" checkout -- "$SPEC" 2>/dev/null || true
    xcodegen generate --spec "$SPEC" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ── 1. (optional) enable the libghostty renderer ────────────────────────────────────────────
if [[ "$WITH_RENDERER" == "1" ]]; then
  echo "==> enabling libghostty renderer (will restore on exit)"
  bash "$REPO_ROOT/scripts/enable-macos-renderer.sh"
else
  # Make sure the .xcodeproj matches the committed spec.
  xcodegen generate --spec "$SPEC" >/dev/null
fi

# ── 2. Build (unsigned / ad-hoc) ────────────────────────────────────────────────────────────
echo "==> building Rwork.app (Debug, unsigned)"
xcodebuild \
  -project "$PROJECT" \
  -scheme ClientApp-macOS \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build >/dev/null
echo "==> build OK: $APP"

# ── 3. Launch + poll for the macOS process ──────────────────────────────────────────────────
pkill -f "$APP_PROC_PAT" 2>/dev/null || true
open "$APP"
PID=""
for _ in $(seq 1 16); do
  PID="$(pgrep -f "$APP_PROC_PAT" || true)"
  [[ -n "$PID" ]] && break
  sleep 0.5
done
if [[ -z "$PID" ]]; then
  echo "==> FAIL: app never started a process" >&2
  exit 1
fi
echo "==> launched (pid $PID); settling ${SETTLE}s"

# ── 4. Assert it survived the settle window ─────────────────────────────────────────────────
sleep "$SETTLE"
if ! pgrep -f "$APP_PROC_PAT" >/dev/null; then
  echo "==> FAIL: app died within ${SETTLE}s of launch (likely a launch-time crash)" >&2
  exit 1
fi
echo "==> alive after ${SETTLE}s ✅"

# ── 5. Screenshot for visual verification ───────────────────────────────────────────────────
open "$APP"        # bring to front
sleep 1
screencapture -x "$SHOT"
echo "==> screenshot: $SHOT"
echo "==> macOS runtime check OK — open the screenshot to verify the rendered window."
