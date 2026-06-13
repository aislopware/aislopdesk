/*
 * This translation unit exists only so SwiftPM treats `CAislopdeskFFI` as a buildable
 * C target. The actual symbols are provided by `libaislopdesk_ffi.a` — the Rust staticlib
 * built by `rust/build-apple.sh` — which is linked via this target's `linkerSettings` in
 * Package.swift. Including the header here also type-checks it as valid C on every build,
 * so any drift from the Rust-side header (`rust/aislopdesk-ffi/include/aislopdesk_ffi.h`)
 * surfaces at compile time.
 */
#include "aislopdesk_ffi.h"

/* A single anchor symbol keeps the TU non-empty (no -Wempty-translation-unit). */
int aisd_ffi_shim_anchor(void);
int aisd_ffi_shim_anchor(void) { return 0; }
