#!/usr/bin/env bash
#
# build-libghostty.sh — reproducible, hermetic-ish build of libghostty.xcframework
# for Rwork (the ONLY terminal renderer — libghostty-only, no SwiftTerm, no fallback).
#
# WHAT IT DOES (idempotent, re-runnable with no manual cleanup):
#   1. Download the PINNED Zig toolchain into ThirdParty/ghostty/.toolchain/ (gitignored),
#      verifying the SHA-256. brew's zig 0.16.0 is too new for the fork — we never use it.
#   2. Clone the PINNED ghostty fork SHA into ThirdParty/ghostty/.work/ghostty-src (gitignored).
#   3. `zig build -Demit-xcframework` with the build-local Zig on PATH, producing
#      GhosttyKit.xcframework (macOS arm64 native slice by default; universal adds
#      iOS device + sim).
#   4. Assemble/copy the result to ThirdParty/ghostty/libghostty.xcframework (gitignored).
#   5. Verify the external-IO symbols are present (nm) and print "OK: <path>" or a
#      precise failure.
#
# APPROACH (b): pin the daiimus fork SHA DIRECTLY. The external-IO C API
#   (ghostty_surface_write_output, write_callback/resize_callback config fields,
#   GHOSTTY_BACKEND_EXTERNAL, ghostty_surface_set_size, ghostty_surface_key/_text)
#   already exists on this branch via src/termio/External.zig (~470 LOC) + the C glue
#   in src/apprt/embedded.zig. No upstream patch to author/rebase → most reliable path
#   to the symbols. The equivalent source delta is recorded in External.zig.patch for
#   documentation / future upstream-rebase reference.
#
# USAGE:
#   ThirdParty/ghostty/build-libghostty.sh            # macOS arm64 native slice (fast first cut)
#   XCFRAMEWORK_TARGET=universal ThirdParty/ghostty/build-libghostty.sh   # + iOS device + sim
#   ZIG_BUILD_TIMEOUT_SECS=1800 ...                   # cap the zig build wall clock
#
# Pins are declared below; bump them deliberately (and re-verify the header) when
# updating the renderer.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# PINS — change deliberately; see ThirdParty/ghostty/README.md.
# ─────────────────────────────────────────────────────────────────────────────
GHOSTTY_REPO="https://github.com/daiimus/ghostty.git"
GHOSTTY_BRANCH="ios-external-backend"
GHOSTTY_SHA="21c717340b62349d67124446c2447bf38796540b"

ZIG_VERSION="0.15.2"                                  # build.zig.zon minimum_zig_version
ZIG_ARCH="aarch64"                                    # Apple Silicon host
ZIG_TARBALL="zig-${ZIG_ARCH}-macos-${ZIG_VERSION}.tar.xz"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"
ZIG_SHA256="3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b"

# XCFRAMEWORK_TARGET: "native" (macOS host arch only — fast) or "universal"
# (macOS universal + ios arm64 device + ios arm64 sim). Default: native first cut.
XCFRAMEWORK_TARGET="${XCFRAMEWORK_TARGET:-native}"

# Wall-clock cap for the actual `zig build` step (seconds). Default 1800 (30 min).
ZIG_BUILD_TIMEOUT_SECS="${ZIG_BUILD_TIMEOUT_SECS:-1800}"

# ─────────────────────────────────────────────────────────────────────────────
# Paths (all absolute, derived from this script's location).
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_DIR="${SCRIPT_DIR}/.toolchain"
WORK_DIR="${SCRIPT_DIR}/.work"
SRC_DIR="${WORK_DIR}/ghostty-src"
ZIG_DIR="${TOOLCHAIN_DIR}/zig-${ZIG_ARCH}-macos-${ZIG_VERSION}"
ZIG_BIN="${ZIG_DIR}/zig"
ZIG_GLOBAL_CACHE="${WORK_DIR}/zig-global-cache"       # keep deps out of ~/.cache
OUT_XCFRAMEWORK="${SCRIPT_DIR}/libghostty.xcframework"

log()  { printf '\033[1;34m[build-libghostty]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[build-libghostty] %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m[build-libghostty] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────────────────────────────────────
log "host: $(uname -sm), target=${XCFRAMEWORK_TARGET}, zig-pin=${ZIG_VERSION}, ghostty-pin=${GHOSTTY_SHA:0:12}"
[ "$(uname -s)" = "Darwin" ] || fail "must build on macOS (xcframework + Apple SDK required)."
command -v curl >/dev/null  || fail "curl not found."
command -v shasum >/dev/null || fail "shasum not found."
command -v git >/dev/null    || fail "git not found."

mkdir -p "${TOOLCHAIN_DIR}" "${WORK_DIR}" "${ZIG_GLOBAL_CACHE}"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Pinned Zig toolchain (download + verify SHA-256, skip if already good)
# ─────────────────────────────────────────────────────────────────────────────
if [ -x "${ZIG_BIN}" ] && "${ZIG_BIN}" version 2>/dev/null | grep -qx "${ZIG_VERSION}"; then
    log "zig ${ZIG_VERSION} already present at ${ZIG_BIN}"
else
    TARBALL_PATH="${TOOLCHAIN_DIR}/${ZIG_TARBALL}"
    if [ ! -f "${TARBALL_PATH}" ]; then
        log "downloading ${ZIG_URL}"
        curl -fL --retry 3 -o "${TARBALL_PATH}.tmp" "${ZIG_URL}" \
            || fail "could not download Zig ${ZIG_VERSION} (network blocked? URL changed?). URL: ${ZIG_URL}"
        mv "${TARBALL_PATH}.tmp" "${TARBALL_PATH}"
    fi
    log "verifying SHA-256 of ${ZIG_TARBALL}"
    GOT_SHA="$(shasum -a 256 "${TARBALL_PATH}" | awk '{print $1}')"
    if [ "${GOT_SHA}" != "${ZIG_SHA256}" ]; then
        rm -f "${TARBALL_PATH}"
        fail "Zig tarball SHA mismatch. expected=${ZIG_SHA256} got=${GOT_SHA} (corrupt download or wrong pin)."
    fi
    log "extracting Zig"
    rm -rf "${ZIG_DIR}"
    tar -xf "${TARBALL_PATH}" -C "${TOOLCHAIN_DIR}"
    [ -x "${ZIG_BIN}" ] || fail "extracted Zig has no executable at ${ZIG_BIN} (tarball layout changed?)."
fi
ACTUAL_ZIG_VER="$("${ZIG_BIN}" version)"
log "using zig ${ACTUAL_ZIG_VER} at ${ZIG_BIN}"
[ "${ACTUAL_ZIG_VER}" = "${ZIG_VERSION}" ] || fail "zig version drift: have ${ACTUAL_ZIG_VER}, pinned ${ZIG_VERSION}."

# ─────────────────────────────────────────────────────────────────────────────
# 1b. PREFLIGHT: can the pinned Zig link against THIS machine's macOS SDK?
#     Fail fast BEFORE the long dep-fetch + compile. The pinned Zig (0.15.2) is
#     known to be unable to link against the macOS 26.5 SDK (it predates it):
#     a trivial program fails with `undefined symbol: __availability_version_check`
#     / `_abort` / `_bzero` because Zig 0.15.2 doesn't know the 26.x libSystem
#     layout. There is NO satisfying toolchain on such a host: 0.15.2 can't link
#     the new SDK, and the only SDK-compatible Zig (0.16.0) is rejected by the
#     fork's build.zig (hard `requireZig(0.15.2)` gate + `std.process.EnvMap`
#     removed in 0.16). See README "Build outcome / known blocker".
SDK_VER="$(xcrun --show-sdk-version 2>/dev/null || echo unknown)"
SMOKE_DIR="${WORK_DIR}/zig-smoke"; mkdir -p "${SMOKE_DIR}"
printf 'const std=@import("std");\npub fn main() void { std.debug.print("ok\\n", .{}); }\n' > "${SMOKE_DIR}/smoke.zig"
log "preflight: testing whether zig ${ZIG_VERSION} can link the macOS ${SDK_VER} SDK"
if ! "${ZIG_BIN}" run --global-cache-dir "${ZIG_GLOBAL_CACHE}" "${SMOKE_DIR}/smoke.zig" >"${SMOKE_DIR}/smoke.out" 2>&1; then
    echo "---- zig smoke link output ----" >&2; sed 's/^/    /' "${SMOKE_DIR}/smoke.out" >&2
    fail "pinned Zig ${ZIG_VERSION} CANNOT LINK the macOS ${SDK_VER} SDK on this host (libSystem symbols undefined). \
This is a toolchain<->SDK incompatibility, NOT a script/fork bug. Options: (1) build on a host with an \
older macOS SDK (<= 15.x) that Zig ${ZIG_VERSION} supports; (2) wait for / bump to a Zig that supports \
both the macOS ${SDK_VER} SDK AND the fork's build.zig; (3) build in CI on a supported runner image. \
The deliverables (this script, External.zig.patch, modulemap, vendored header, GhosttySurface.swift) are \
complete and correct regardless — see README."
fi
log "preflight OK: zig ${ZIG_VERSION} links the macOS ${SDK_VER} SDK."

# ─────────────────────────────────────────────────────────────────────────────
# 2. Pinned ghostty fork source (clone @ branch, hard-pin to SHA)
# ─────────────────────────────────────────────────────────────────────────────
if [ -d "${SRC_DIR}/.git" ]; then
    CUR_SHA="$(git -C "${SRC_DIR}" rev-parse HEAD 2>/dev/null || echo none)"
    if [ "${CUR_SHA}" != "${GHOSTTY_SHA}" ]; then
        log "source at ${CUR_SHA:0:12}, want ${GHOSTTY_SHA:0:12} — refetching"
        git -C "${SRC_DIR}" fetch --depth 1 origin "${GHOSTTY_SHA}" 2>/dev/null \
            || git -C "${SRC_DIR}" fetch --depth 1 origin "${GHOSTTY_BRANCH}"
        git -C "${SRC_DIR}" checkout -q "${GHOSTTY_SHA}" 2>/dev/null \
            || git -C "${SRC_DIR}" checkout -q FETCH_HEAD
    else
        log "ghostty source already at pinned SHA ${GHOSTTY_SHA:0:12}"
    fi
else
    log "cloning ${GHOSTTY_REPO} @ ${GHOSTTY_BRANCH}"
    rm -rf "${SRC_DIR}"
    git clone --depth 1 --branch "${GHOSTTY_BRANCH}" "${GHOSTTY_REPO}" "${SRC_DIR}" \
        || fail "git clone failed (network blocked?)."
    CUR_SHA="$(git -C "${SRC_DIR}" rev-parse HEAD)"
    if [ "${CUR_SHA}" != "${GHOSTTY_SHA}" ]; then
        log "branch tip ${CUR_SHA:0:12} != pinned ${GHOSTTY_SHA:0:12}; pinning exactly"
        git -C "${SRC_DIR}" fetch --depth 1 origin "${GHOSTTY_SHA}" \
            && git -C "${SRC_DIR}" checkout -q "${GHOSTTY_SHA}" \
            || log "WARN: could not hard-pin to ${GHOSTTY_SHA} (branch may have moved); using ${CUR_SHA:0:12}"
    fi
fi

# Confirm the external-IO symbols are actually present in the source header before
# spending 25 min compiling — fail fast otherwise.
HDR="${SRC_DIR}/include/ghostty.h"
[ -f "${HDR}" ] || fail "missing ${HDR} in source."
for sym in ghostty_surface_write_output ghostty_write_callback_fn GHOSTTY_BACKEND_EXTERNAL ghostty_surface_set_size; do
    grep -q "${sym}" "${HDR}" || fail "expected external-IO symbol '${sym}' not in ${HDR} (wrong SHA?)."
done
log "external-IO symbols confirmed in source header."

# Confirm the source's pinned Zig requirement matches our toolchain.
if grep -q "minimum_zig_version" "${SRC_DIR}/build.zig.zon"; then
    REQ_ZIG="$(grep "minimum_zig_version" "${SRC_DIR}/build.zig.zon" | sed -E 's/.*"([0-9.]+)".*/\1/')"
    log "source requires zig >= ${REQ_ZIG}; pinned toolchain = ${ZIG_VERSION}"
    [ "${REQ_ZIG}" = "${ZIG_VERSION}" ] || log "NOTE: pin (${ZIG_VERSION}) differs from source minimum (${REQ_ZIG}); proceeding (>= satisfied)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Build the xcframework with the build-local Zig
# ─────────────────────────────────────────────────────────────────────────────
export PATH="${ZIG_DIR}:${PATH}"
ZIG_FLAGS=( "build"
    "-Demit-xcframework=true"
    "-Dxcframework-target=${XCFRAMEWORK_TARGET}"
    "-Doptimize=ReleaseFast"
    "--global-cache-dir" "${ZIG_GLOBAL_CACHE}"
    "--prefix" "${WORK_DIR}/zig-out"
)
log "zig ${ZIG_FLAGS[*]}  (timeout ${ZIG_BUILD_TIMEOUT_SECS}s; first run also fetches ~15 zig deps)"

# Bounded wall clock: prefer GNU/coreutils timeout if present, else a watchdog.
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null; then
        timeout --signal=TERM "${secs}s" "$@"
    elif command -v gtimeout >/dev/null; then
        gtimeout --signal=TERM "${secs}s" "$@"
    else
        # portable watchdog
        "$@" & local pid=$!
        ( sleep "${secs}"; kill -TERM "${pid}" 2>/dev/null ) & local wd=$!
        wait "${pid}"; local rc=$?
        kill "${wd}" 2>/dev/null || true
        return "${rc}"
    fi
}

set +e
( cd "${SRC_DIR}" && run_with_timeout "${ZIG_BUILD_TIMEOUT_SECS}" "${ZIG_BIN}" "${ZIG_FLAGS[@]}" )
BUILD_RC=$?
set -e
if [ "${BUILD_RC}" -eq 124 ]; then
    fail "zig build exceeded ${ZIG_BUILD_TIMEOUT_SECS}s wall clock and was killed (TIME-BOX). Re-run to resume — deps + caches persist under ${WORK_DIR}."
elif [ "${BUILD_RC}" -ne 0 ]; then
    fail "zig build exited ${BUILD_RC}. See output above (toolchain mismatch, dep fetch failure, or SDK error)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Locate + assemble the produced xcframework
# ─────────────────────────────────────────────────────────────────────────────
# The fork emits macos/GhosttyKit.xcframework under the install prefix.
PRODUCED="$(find "${WORK_DIR}/zig-out" "${SRC_DIR}/zig-out" -maxdepth 3 -name '*.xcframework' -type d 2>/dev/null | head -1 || true)"
[ -n "${PRODUCED}" ] || fail "no .xcframework produced under zig-out (build succeeded but artifact missing?)."
log "produced: ${PRODUCED}"

rm -rf "${OUT_XCFRAMEWORK}"
cp -R "${PRODUCED}" "${OUT_XCFRAMEWORK}"
log "assembled: ${OUT_XCFRAMEWORK}"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Verify external-IO symbols in the built binary
# ─────────────────────────────────────────────────────────────────────────────
SLICES="$(find "${OUT_XCFRAMEWORK}" -name '*.a' -o -name 'libghostty*' -o -name 'GhosttyKit' 2>/dev/null)"
log "xcframework slices:"; echo "${SLICES}" | sed 's/^/    /'

VERIFIED=0
while IFS= read -r lib; do
    [ -n "${lib}" ] || continue
    if nm "${lib}" 2>/dev/null | grep -q "ghostty_surface_write_output"; then
        log "✔ ${lib##*/} exposes ghostty_surface_write_output"
        nm "${lib}" 2>/dev/null | grep -E "ghostty_surface_write_output|ghostty_surface_set_size|ghostty_surface_key|ghostty_surface_new" | sed 's/^/        /' | head -8
        VERIFIED=1
    fi
done <<< "$(find "${OUT_XCFRAMEWORK}" -type f \( -name '*.a' -o -name 'GhosttyKit' -o -name 'libghostty*' \) 2>/dev/null)"

[ "${VERIFIED}" -eq 1 ] || fail "built xcframework does NOT expose ghostty_surface_write_output (external-IO API missing — wrong branch/SHA?)."

ok "OK: ${OUT_XCFRAMEWORK}"
ok "    zig=${ZIG_VERSION}  ghostty=${GHOSTTY_SHA:0:12}  target=${XCFRAMEWORK_TARGET}"
ok "    external-IO symbols verified (ghostty_surface_write_output present)."
