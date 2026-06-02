#!/usr/bin/env bash
#
# build-libghostty.sh — reproducible, hermetic-ish build of libghostty.xcframework
# for Rwork (the ONLY terminal renderer — libghostty-only, no SwiftTerm, no fallback).
#
# WHAT IT DOES (idempotent, re-runnable with no manual cleanup):
#   1. Download the PINNED Zig toolchain into ThirdParty/ghostty/.toolchain/ (gitignored),
#      verifying the SHA-256. brew's zig 0.16.0 is too new for the fork — we never use it.
#   2. Clone the PINNED ghostty fork SHA into ThirdParty/ghostty/.work/ghostty-src (gitignored).
#   3. Generate an `xcrun` PATH-shim and run `zig build -Demit-xcframework` with the
#      build-local Zig on PATH. The shim forces Zig's native macOS SDK detection onto an
#      old SDK (see caveat #1); the zig build runs the libtool steps that produce the
#      per-archive object files even though the overall build then fails at the macOS
#      app-bundle copy step (see caveat #3).
#   4. ASSEMBLE the static library OURSELVES from the libtool object files via
#      ar/ranlib (the libtool-symbol-drop bypass, caveat #3), then wrap it with
#      `xcodebuild -create-xcframework` into ThirdParty/ghostty/libghostty.xcframework.
#   5. Verify the external-IO symbols are present in the FINAL assembled library (nm)
#      and print "OK: <path>" or a precise failure.
#
# APPROACH (b): pin the daiimus fork SHA DIRECTLY. The external-IO C API
#   (ghostty_surface_write_output, write_callback/resize_callback config fields,
#   GHOSTTY_BACKEND_EXTERNAL, ghostty_surface_set_size, ghostty_surface_key/_text)
#   already exists on this branch via src/termio/External.zig (~470 LOC) + the C glue
#   in src/apprt/embedded.zig. No upstream patch to author/rebase → most reliable path
#   to the symbols. The equivalent source delta is recorded in External.zig.patch for
#   documentation / future upstream-rebase reference.
#
# ─────────────────────────────────────────────────────────────────────────────
# macOS-26.5-HOST CAVEATS (this recipe was proven on macOS 26.5 / Xcode 26.5 / arm64)
# ─────────────────────────────────────────────────────────────────────────────
#   (1) xcrun SDK SHIM — THE LEVER.
#       Zig 0.15.2 cannot link the host's default 26.5 macOS SDK (undefined
#       __availability_version_check / _abort / _bzero — it predates the 26.x
#       libSystem layout). The build.zig runner compiles natively against whatever
#       `xcrun --sdk macosx --show-sdk-path` returns. SDKROOT / --sysroot alone do
#       NOT fix this. The fix is a PATH-shim that intercepts ONLY the macosx
#       `--show-sdk-path` / `--show-sdk-version` queries and answers with an
#       OLD SDK (<= 15.x). iOS / sim / tvOS / watchOS queries pass through to the
#       real xcrun untouched. Parameterized below as MACOS_SDK_SHIM_PATH
#       (default /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk).
#   (2) METAL TOOLCHAIN required.
#       The fork compiles Metal shaders (Ghostty.metallib). Without the Metal
#       Toolchain the libtool step never runs:
#         "cannot execute tool 'metal' due to missing Metal Toolchain"
#       Install once with:  xcodebuild -downloadComponent MetalToolchain
#       Preflight below checks for it and prints this instruction if absent.
#   (3) Xcode-26.5 libtool DROPS the Zig root object (libtool BYPASS).
#       `zig build -Demit-xcframework` emits a GhosttyKit.xcframework, but Xcode
#       26.5's `libtool -static` silently drops the Zig compilation unit
#       (libghostty_zcu.o — it carries ALL ~123 ghostty_* C-API symbols; libtool
#       warns "member 'libghostty_zcu.o' not 8-byte aligned"). The fork's own
#       emitted GhosttyKit.xcframework is therefore DEFECTIVE (0 ghostty_* symbols).
#       Worse, the overall `zig build` then FAILS (RC != 0) at the macOS app-bundle
#       CpResource step — so we CANNOT trust its exit code. Instead we harvest the
#       two GOOD intermediate libtool archives the build leaves behind:
#         A) macos/build/ReleaseLocal/libghostty-fat.a  — the C/C++ dependency objects
#         B) .zig-cache/o/<hash>/libghostty.a           — the 8 Zig objects incl.
#                                                          libghostty_zcu.o
#       We extract both, re-archive with ar/ranlib (chmod first — Zig stores members
#       mode 0000; the B-set is prefixed `zig_` to avoid base64.o/compiler_rt.o
#       name collisions with the A-set), then `xcodebuild -create-xcframework`.
#   (4) iOS slice needs an iOS <= 18 SDK.
#       XCFRAMEWORK_TARGET=universal adds ios-arm64 device + sim. The same toolchain<->SDK
#       constraint applies: Zig 0.15.2 needs an iOS SDK <= 18.x (and the shim must be
#       extended to answer iphoneos/iphonesimulator --show-sdk-path). On a host with only
#       the 26.x iOS SDK the universal target will NOT link. Build the iOS slice on a host
#       (or CI image) carrying an iOS <= 18 SDK. Default target is `native` (macOS arm64).
#
# USAGE:
#   ThirdParty/ghostty/build-libghostty.sh            # macOS arm64 native slice (fast first cut)
#   XCFRAMEWORK_TARGET=universal ThirdParty/ghostty/build-libghostty.sh   # + iOS device + sim (needs iOS<=18 SDK)
#   MACOS_SDK_SHIM_PATH=/path/to/MacOSX15.4.sdk ...   # override the old-SDK the shim points at
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

# Old macOS SDK the xcrun shim points Zig at (caveat #1). Zig 0.15.2 cannot link
# the host's 26.5 SDK; <= 15.x works. Default is the stable MacOSX15.sdk symlink
# shipped by the Command Line Tools (resolves to e.g. MacOSX15.4.sdk).
MACOS_SDK_SHIM_PATH="${MACOS_SDK_SHIM_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk}"

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
SHIM_DIR="${WORK_DIR}/bin"                            # holds the generated xcrun shim
ASSEMBLE_DIR="${WORK_DIR}/assemble"                  # scratch for ar extract/re-archive
OUT_DIR="${WORK_DIR}/out"                            # staging for the final fat.a + xcframework
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
command -v ar >/dev/null     || fail "ar not found (Command Line Tools)."
command -v ranlib >/dev/null || fail "ranlib not found (Command Line Tools)."
command -v xcodebuild >/dev/null || fail "xcodebuild not found (full Xcode required for -create-xcframework)."

mkdir -p "${TOOLCHAIN_DIR}" "${WORK_DIR}" "${ZIG_GLOBAL_CACHE}" "${SHIM_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# 0a. PREFLIGHT: old macOS SDK for the xcrun shim (caveat #1).
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -d "${MACOS_SDK_SHIM_PATH}" ]; then
    AVAIL="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX1*.sdk 2>/dev/null | tr '\n' ' ')"
    fail "old macOS SDK not found at MACOS_SDK_SHIM_PATH=${MACOS_SDK_SHIM_PATH}. \
Zig ${ZIG_VERSION} cannot link the host's 26.x SDK (caveat #1) — it needs an SDK <= 15.x. \
Installed CLT SDKs: ${AVAIL:-<none>}. Install the Command Line Tools that ship a 15.x SDK \
(or point MACOS_SDK_SHIM_PATH at one), e.g. MacOSX15.4.sdk."
fi
log "xcrun shim will point Zig's macosx SDK at: ${MACOS_SDK_SHIM_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# 0b. PREFLIGHT: Metal Toolchain (caveat #2). Without it the libtool step never runs.
# ─────────────────────────────────────────────────────────────────────────────
if /usr/bin/xcrun --sdk macosx --find metal >/dev/null 2>&1; then
    log "preflight OK: Metal Toolchain present ($(/usr/bin/xcrun --sdk macosx --find metal))."
else
    fail "Metal Toolchain NOT installed — the fork compiles Metal shaders (Ghostty.metallib) \
and the build fails with \"cannot execute tool 'metal'\" without it (caveat #2). Install it with:

    xcodebuild -downloadComponent MetalToolchain

then re-run this script (it is idempotent)."
fi

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
# 1b. Generate the xcrun PATH-shim (caveat #1) and PREFLIGHT that the pinned Zig
#     can link the macOS SDK *through the shim*. The shim intercepts ONLY the
#     macosx `--show-sdk-path` / `--show-sdk-version` queries and answers with the
#     old SDK; iOS / sim / tvOS / watchOS queries pass through to the real xcrun.
#     Without the shim Zig 0.15.2 fails to link the host's 26.x SDK (undefined
#     __availability_version_check / _abort / _bzero) — SDKROOT alone does not help.
# ─────────────────────────────────────────────────────────────────────────────
SHIM_XCRUN="${SHIM_DIR}/xcrun"
SDK_SHIM_VER="$(basename "$(readlink "${MACOS_SDK_SHIM_PATH}" 2>/dev/null || echo "${MACOS_SDK_SHIM_PATH}")" | sed -E 's/^MacOSX([0-9.]+)\.sdk$/\1/')"
[ -n "${SDK_SHIM_VER}" ] || SDK_SHIM_VER="15.4"
log "generating xcrun shim at ${SHIM_XCRUN} (macosx SDK -> ${MACOS_SDK_SHIM_PATH}, version ${SDK_SHIM_VER})"
cat > "${SHIM_XCRUN}" <<SHIM
#!/bin/bash
# GENERATED by build-libghostty.sh — DO NOT EDIT (regenerated every run).
# Forces Zig's native macOS SDK detection onto an old SDK that Zig ${ZIG_VERSION}
# can link (caveat #1). Everything that is not a macosx SDK-path/version query
# passes through to the real /usr/bin/xcrun untouched.
SDK_PATH="${MACOS_SDK_SHIM_PATH}"
SDK_VERSION="${SDK_SHIM_VER}"
args="\$*"
case "\$args" in
  *"--show-sdk-path"*)
    case "\$args" in
      *iphoneos*|*iphonesimulator*|*appletvos*|*appletvsimulator*|*watchos*|*watchsimulator*|*xros*|*xrsimulator*)
        exec /usr/bin/xcrun "\$@" ;;   # leave non-macOS SDKs to the real xcrun
      *)
        echo "\$SDK_PATH"; exit 0 ;;
    esac ;;
  *"--show-sdk-version"*)
    case "\$args" in
      *iphoneos*|*iphonesimulator*|*appletvos*|*appletvsimulator*|*watchos*|*watchsimulator*|*xros*|*xrsimulator*)
        exec /usr/bin/xcrun "\$@" ;;
      *)
        echo "\$SDK_VERSION"; exit 0 ;;
    esac ;;
  *)
    exec /usr/bin/xcrun "\$@" ;;
esac
SHIM
chmod +x "${SHIM_XCRUN}"

# Self-test the shim before trusting it.
GOT_SDK_PATH="$(PATH="${SHIM_DIR}:${PATH}" xcrun --sdk macosx --show-sdk-path)"
[ "${GOT_SDK_PATH}" = "${MACOS_SDK_SHIM_PATH}" ] || fail "xcrun shim self-test failed: --show-sdk-path returned '${GOT_SDK_PATH}', expected '${MACOS_SDK_SHIM_PATH}'."
log "xcrun shim self-test OK (macosx --show-sdk-path -> ${GOT_SDK_PATH})."

SDK_VER="$(/usr/bin/xcrun --show-sdk-version 2>/dev/null || echo unknown)"
SMOKE_DIR="${WORK_DIR}/zig-smoke"; mkdir -p "${SMOKE_DIR}"
printf 'const std=@import("std");\npub fn main() void { std.debug.print("ok\\n", .{}); }\n' > "${SMOKE_DIR}/smoke.zig"
log "preflight: testing whether zig ${ZIG_VERSION} can link via the shim (host SDK is ${SDK_VER})"
if ! PATH="${SHIM_DIR}:${PATH}" "${ZIG_BIN}" run --global-cache-dir "${ZIG_GLOBAL_CACHE}" "${SMOKE_DIR}/smoke.zig" >"${SMOKE_DIR}/smoke.out" 2>&1; then
    echo "---- zig smoke link output ----" >&2; sed 's/^/    /' "${SMOKE_DIR}/smoke.out" >&2
    fail "pinned Zig ${ZIG_VERSION} CANNOT LINK even through the SDK shim (${MACOS_SDK_SHIM_PATH}). \
The shimmed SDK may be too new/too old, or the Command Line Tools are misconfigured. \
Point MACOS_SDK_SHIM_PATH at a known-good SDK <= 15.x (caveat #1)."
fi
log "preflight OK: zig ${ZIG_VERSION} links via the shim (SDK ${MACOS_SDK_SHIM_PATH})."

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
# 3. Build with the build-local Zig + the xcrun shim on PATH.
#
#    IMPORTANT (caveat #3): `zig build -Demit-xcframework` runs the libtool steps
#    that produce the GOOD intermediate archives we harvest, but then FAILS (RC != 0)
#    at the macOS app-bundle CpResource stage. So we do NOT trust the exit code — we
#    verify the intermediate archives exist afterwards instead. The shim MUST be ahead
#    of the real /usr/bin on PATH so the build.zig runner sees the old macosx SDK.
# ─────────────────────────────────────────────────────────────────────────────
export PATH="${SHIM_DIR}:${ZIG_DIR}:${PATH}"
ZIG_FLAGS=( "build"
    "-Demit-xcframework=true"
    "-Dxcframework-target=${XCFRAMEWORK_TARGET}"
    "-Doptimize=ReleaseFast"
    "--global-cache-dir" "${ZIG_GLOBAL_CACHE}"
    "--prefix" "${WORK_DIR}/zig-out"
)
log "zig ${ZIG_FLAGS[*]}  (timeout ${ZIG_BUILD_TIMEOUT_SECS}s; first run also fetches ~15 zig deps)"
log "NOTE: a non-zero exit at the app-bundle/CpResource stage is EXPECTED (caveat #3); we harvest the libtool archives regardless."

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
fi
[ "${BUILD_RC}" -eq 0 ] && log "zig build exited 0." || log "zig build exited ${BUILD_RC} (expected — app-bundle stage; harvesting libtool archives, caveat #3)."

# ─────────────────────────────────────────────────────────────────────────────
# 4. ASSEMBLE the static library OURSELVES (the libtool-symbol-drop bypass, caveat #3).
#
#    Source A (deps): macos/build/ReleaseLocal/libghostty-fat.a — the C/C++ dependency
#      objects (freetype, png, sentry, oniguruma, simdutf, imgui, glslang, …). The Zig
#      root object is NOT here.
#    Source B (zig):  .zig-cache/o/<hash>/libghostty.a — the handful of Zig objects,
#      including libghostty_zcu.o which carries ALL ghostty_* C-API symbols. We must
#      identify it by content (it is the ONLY zig-cache archive whose nm shows
#      ghostty_surface_write_output), then prefix its members `zig_` to avoid
#      base64.o / compiler_rt.o / codepoint_width.o name collisions with Source A.
#
#    Zig stores .a members mode 0000 → we chmod 0644 before re-archiving or ar/ranlib
#    cannot read them. Final archive = A-members + zig_-prefixed B-members, ar qc + ranlib.
# ─────────────────────────────────────────────────────────────────────────────
SRC_A="$(find "${SRC_DIR}/macos/build" -name 'libghostty-fat.a' -type f 2>/dev/null | head -1 || true)"
[ -n "${SRC_A}" ] || fail "dependency archive (macos/build/.../libghostty-fat.a) not found — the libtool step did not run. Most likely the Metal Toolchain is missing (caveat #2) or the SDK shim is not on PATH. Re-check the build output above."
log "source A (deps): ${SRC_A}"

# Locate Source B by CONTENT: the zig-cache libghostty.a that actually exposes the C API.
SRC_B=""
while IFS= read -r cand; do
    [ -n "${cand}" ] || continue
    if nm "${cand}" 2>/dev/null | grep -q "ghostty_surface_write_output"; then
        SRC_B="${cand}"; break
    fi
done <<< "$(find "${SRC_DIR}/.zig-cache" -name 'libghostty.a' -type f 2>/dev/null)"
[ -n "${SRC_B}" ] || fail "Zig root archive (.zig-cache/o/*/libghostty.a exposing ghostty_surface_write_output) not found — the Zig compilation unit did not build (wrong SHA, or build aborted before the Zig step)."
log "source B (zig root, has C API): ${SRC_B}"

# Fresh scratch every run (idempotent).
rm -rf "${ASSEMBLE_DIR}" "${OUT_DIR}"
A_DIR="${ASSEMBLE_DIR}/a"; B_DIR="${ASSEMBLE_DIR}/b"
mkdir -p "${A_DIR}" "${B_DIR}" "${OUT_DIR}"

log "extracting + chmod dependency objects (Source A)"
( cd "${A_DIR}" && ar x "${SRC_A}" && rm -f __.SYMDEF '__.SYMDEF SORTED' )
chmod -R u+rw "${A_DIR}"

log "extracting + chmod + zig_-prefixing Zig objects (Source B)"
( cd "${B_DIR}" && ar x "${SRC_B}" && rm -f __.SYMDEF '__.SYMDEF SORTED' )
chmod -R u+rw "${B_DIR}"
for f in "${B_DIR}"/*.o; do
    base="$(basename "${f}")"
    case "${base}" in zig_*) : ;; *) mv "${f}" "${B_DIR}/zig_${base}" ;; esac
done

FINAL_FAT="${OUT_DIR}/libghostty-fat.a"
log "re-archiving with ar qc + ranlib -> ${FINAL_FAT}"
rm -f "${FINAL_FAT}"
# Pass objects explicitly (not a glob in args) so member order is deterministic-ish.
# ar qc appends; ranlib (re)builds the symbol table libtool would have written.
ar qc "${FINAL_FAT}" "${A_DIR}"/*.o "${B_DIR}"/*.o
ranlib "${FINAL_FAT}"

MEMBER_COUNT="$(ar t "${FINAL_FAT}" 2>/dev/null | grep -vc '__.SYMDEF' || true)"
log "assembled fat archive: ${MEMBER_COUNT} members"

# Stage Headers from the source include/ tree (umbrella ghostty.h + module.modulemap
# + the ghostty/vt/* subtree the modulemap references). This mirrors what the fork's
# own xcframework ships.
HDR_STAGE="${OUT_DIR}/Headers"
rm -rf "${HDR_STAGE}"; mkdir -p "${HDR_STAGE}"
cp -R "${SRC_DIR}/include/." "${HDR_STAGE}/"
[ -f "${HDR_STAGE}/ghostty.h" ] || fail "staged Headers missing ghostty.h (source include/ layout changed?)."
[ -f "${HDR_STAGE}/module.modulemap" ] || fail "staged Headers missing module.modulemap (source include/ layout changed?)."

log "wrapping with xcodebuild -create-xcframework"
rm -rf "${OUT_XCFRAMEWORK}"
xcodebuild -create-xcframework \
    -library "${FINAL_FAT}" -headers "${HDR_STAGE}" \
    -output "${OUT_XCFRAMEWORK}" >/dev/null \
    || fail "xcodebuild -create-xcframework failed (see output)."
log "assembled: ${OUT_XCFRAMEWORK}"

# Also keep a copy of the assembled fat archive next to the staged out for debugging.
cp "${FINAL_FAT}" "${OUT_DIR}/libghostty-fat.a" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# 5. Verify the external-IO symbols in the FINAL ASSEMBLED library (caveat #3 check).
#    This MUST pass now — the whole point of the ar/ranlib bypass is to keep
#    libghostty_zcu.o (and its symbols) in the shipped archive.
# ─────────────────────────────────────────────────────────────────────────────
REQUIRED_SYMS=(
    ghostty_app_new
    ghostty_surface_new
    ghostty_surface_set_size
    ghostty_surface_key
    ghostty_surface_text
    ghostty_surface_write_output
)

SLICE_LIBS="$(find "${OUT_XCFRAMEWORK}" -type f \( -name '*.a' -o -name 'GhosttyKit' -o -name 'libghostty*' \) 2>/dev/null)"
[ -n "${SLICE_LIBS}" ] || fail "no library slice found inside ${OUT_XCFRAMEWORK}."
log "xcframework library slices:"; echo "${SLICE_LIBS}" | sed 's/^/    /'

VERIFIED=0
while IFS= read -r lib; do
    [ -n "${lib}" ] || continue
    log "verifying slice: ${lib}"
    log "  lipo -archs: $(lipo -archs "${lib}" 2>/dev/null || echo '?')"
    MISSING=()
    for sym in "${REQUIRED_SYMS[@]}"; do
        nm -gU "${lib}" 2>/dev/null | grep -q " _${sym}\$" || MISSING+=("${sym}")
    done
    if [ "${#MISSING[@]}" -eq 0 ]; then
        log "  ✔ all ${#REQUIRED_SYMS[@]} required external-IO symbols present"
        nm -gU "${lib}" 2>/dev/null | grep -E " _(ghostty_surface_write_output|ghostty_surface_set_size|ghostty_surface_key|ghostty_surface_text|ghostty_app_new|ghostty_surface_new)\$" | sed 's/^/        /'
        VERIFIED=1
    else
        log "  ✖ MISSING required symbols: ${MISSING[*]}"
    fi
done <<< "${SLICE_LIBS}"

[ "${VERIFIED}" -eq 1 ] || fail "FINAL assembled library is missing required external-IO symbols (the ar/ranlib bypass failed — did libghostty_zcu.o survive? did ranlib run?)."

ok "OK: ${OUT_XCFRAMEWORK}"
ok "    zig=${ZIG_VERSION}  ghostty=${GHOSTTY_SHA:0:12}  target=${XCFRAMEWORK_TARGET}  sdk-shim=${MACOS_SDK_SHIM_PATH}"
ok "    final library assembled via ar/ranlib bypass (${MEMBER_COUNT} members); all required external-IO symbols verified."
