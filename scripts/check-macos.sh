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
# MODES:
#   (default)    Build the committed PLACEHOLDER app, launch, assert alive, screenshot.
#   --renderer   Wire in the libghostty renderer (enable-macos-renderer.sh), build, launch,
#                assert alive, screenshot. Verifies the renderer app launches without crashing.
#   --connect    --renderer PLUS a real END-TO-END render check: stand up `rwork-hostd` (a real
#                PTY host daemon), launch the renderer app with RWORK_AUTOCONNECT_HOST/PORT set
#                so it auto-connects on launch (no fragile UI automation — see
#                RworkClientApp.autoConnectIfRequested), then assert the TCP session is
#                ESTABLISHED and the app survived, and screenshot the connected terminal so the
#                glyphs libghostty rendered (shell/Starship prompt, ANSI colours, nerd-font
#                icons) can be visually confirmed.
#
# EXIT: non-zero if the build fails, the app dies within the settle window (a launch/connect
# crash), or (--connect) no client↔host session is established.
#
# STATUS (2026-06-02): all three modes pass. The earlier --renderer ~3 s launch crash (off-main
# `MainActor.assumeIsolated` in libghostty's wakeup/write/resize callbacks, fired from its
# renderer/io threads) is fixed via the `ghosttyOnMainActor` helper. --connect renders a live
# remote shell end to end.
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
APP_BIN="$APP/Contents/MacOS/Rwork"
SHOT="$WORK/macos-shot.png"
HOSTD_LOG="$WORK/hostd.log"
CONNECT_PORT=47420          # uncommon fixed loopback port for the e2e host daemon

WITH_RENDERER=0
CONNECT=0
case "${1:-}" in
  --renderer) WITH_RENDERER=1 ;;
  --connect)  WITH_RENDERER=1; CONNECT=1 ;;
  "")         ;;
  *) echo "usage: check-macos.sh [--renderer | --connect]" >&2; exit 2 ;;
esac

# --connect needs more settle time (build + TCP connect + first render).
SETTLE=4
[[ "$CONNECT" == "1" ]] && SETTLE=7

mkdir -p "$WORK"

# The macOS app and the iOS-Simulator app share the binary name "Rwork"; match ONLY the macOS
# build product path so we never touch the Simulator's process.
APP_PROC_PAT="macos-verify/DerivedData.*MacOS/Rwork"
HOSTD_PID=""

cleanup() {
  pkill -f "$APP_PROC_PAT" 2>/dev/null || true
  [[ -n "$HOSTD_PID" ]] && kill "$HOSTD_PID" 2>/dev/null || true
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

# ── 2b. (--connect) stand up the host daemon ────────────────────────────────────────────────
if [[ "$CONNECT" == "1" ]]; then
  echo "==> building + starting rwork-hostd on 127.0.0.1:$CONNECT_PORT"
  ( cd "$REPO_ROOT" && swift build --product rwork-hostd >/dev/null )
  # Free the port if a prior run left a daemon behind.
  pkill -f "rwork-hostd --port $CONNECT_PORT" 2>/dev/null || true
  sleep 0.5
  "$REPO_ROOT/.build/debug/rwork-hostd" --port "$CONNECT_PORT" >"$HOSTD_LOG" 2>&1 &
  HOSTD_PID=$!
  sleep 1
  if ! kill -0 "$HOSTD_PID" 2>/dev/null; then
    echo "==> FAIL: rwork-hostd did not stay up; log:" >&2; cat "$HOSTD_LOG" >&2; exit 1
  fi
  echo "==> hostd up (pid $HOSTD_PID)"
fi

# ── 3. Launch + poll for the macOS process ──────────────────────────────────────────────────
pkill -f "$APP_PROC_PAT" 2>/dev/null || true
if [[ "$CONNECT" == "1" ]]; then
  # Launch the bundle's binary DIRECTLY (not via `open`) so the auto-connect env vars are
  # inherited — LaunchServices does not forward the shell environment.
  RWORK_AUTOCONNECT_HOST=127.0.0.1 RWORK_AUTOCONNECT_PORT="$CONNECT_PORT" "$APP_BIN" >/dev/null 2>&1 &
else
  open "$APP"
fi
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
  echo "==> FAIL: app died within ${SETTLE}s of launch (likely a launch/connect crash)" >&2
  [[ "$CONNECT" == "1" ]] && { echo "--- hostd log ---" >&2; cat "$HOSTD_LOG" >&2; }
  exit 1
fi
echo "==> alive after ${SETTLE}s ✅"

# ── 4b. (--connect) assert the client↔host TCP session is established ────────────────────────
if [[ "$CONNECT" == "1" ]]; then
  if lsof -nP -iTCP:"$CONNECT_PORT" -sTCP:ESTABLISHED >/dev/null 2>&1; then
    echo "==> client↔host session ESTABLISHED on :$CONNECT_PORT ✅"
  else
    echo "==> FAIL: no ESTABLISHED session on :$CONNECT_PORT (auto-connect did not land)" >&2
    echo "--- hostd log ---" >&2; cat "$HOSTD_LOG" >&2
    exit 1
  fi
fi

# ── 5. Screenshot for visual verification ───────────────────────────────────────────────────
[[ "$CONNECT" != "1" ]] && open "$APP"   # bring to front (direct-launch already foregrounds)
sleep 1
screencapture -x "$SHOT"
echo "==> screenshot: $SHOT"
if [[ "$CONNECT" == "1" ]]; then
  echo "==> macOS END-TO-END check OK — open the screenshot to confirm libghostty rendered the"
  echo "    live remote shell (prompt, ANSI colours, nerd-font glyphs)."
else
  echo "==> macOS runtime check OK — open the screenshot to verify the rendered window."
fi
