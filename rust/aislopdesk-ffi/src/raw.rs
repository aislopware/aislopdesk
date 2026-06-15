//! The crate's **thin unsafe layer** — every raw-pointer / heap-handle primitive lives here.
//!
//! [`aislopdesk_core`](aislopdesk_core) is `#![forbid(unsafe_code)]`, and the rest of *this*
//! crate is structured so its ~100 `extern "C"` shims stay **safe-bodied**: they validate their
//! arguments in plain safe Rust and delegate the genuinely-`unsafe` work — borrowing a caller
//! buffer, owning/freeing a boxed opaque handle, moving owned bytes back across the boundary — to
//! the small, individually-audited functions below.
//!
//! Concentrating the pointer arithmetic in one file is what keeps the unsafe surface a *thin,
//! reviewable layer* instead of being smeared across every boundary function: an auditor reads
//! this module, not 24 others. The only `unsafe` an `extern "C"` shim then needs is a minimal,
//! `// SAFETY:`-commented call into one of these primitives (plus the occasional bare
//! `ptr.as_ref()` / `out.write()` for an opaque handle deref or out-param write, which the shim
//! keeps to a single expression).

use crate::AisdBytes;

// ---------------------------------------------------------------------------------------
// Borrowed caller buffers (never freed by Rust)
// ---------------------------------------------------------------------------------------

/// Borrows a `(ptr, len)` pair as a shared slice; empty for `len == 0` (even if `data` is null).
///
/// # Safety
/// If `len != 0`, `data` must point to at least `len` readable, initialized bytes that stay
/// valid and unmodified for the chosen lifetime `'a`.
pub(crate) const unsafe fn slice_in<'a>(data: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        &[]
    } else {
        // SAFETY: forwarded from this function's contract — `len` readable bytes at `data`.
        unsafe { core::slice::from_raw_parts(data, len) }
    }
}

/// Borrows a `(ptr, len)` pair as a mutable slice; empty for `len == 0` (even if `data` is null).
///
/// # Safety
/// If `len != 0`, `data` must point to `len` writable bytes that stay valid and unaliased for
/// the chosen lifetime `'a`.
pub(crate) const unsafe fn slice_out<'a>(data: *mut u8, len: usize) -> &'a mut [u8] {
    if len == 0 {
        &mut []
    } else {
        // SAFETY: forwarded from this function's contract — `len` writable bytes at `data`.
        unsafe { core::slice::from_raw_parts_mut(data, len) }
    }
}

// ---------------------------------------------------------------------------------------
// Opaque heap handles (`*_new` / `*_free`)
// ---------------------------------------------------------------------------------------

/// Boxes `value` onto the heap and leaks it as an opaque handle the C side owns. The matching
/// [`free_handle`] (invoked by the type's `_free`) reclaims it.
///
/// Safe: nothing is dereferenced — only a fresh allocation is handed over.
pub(crate) fn into_handle<T>(value: T) -> *mut T {
    Box::into_raw(Box::new(value))
}

/// Reclaims and drops a handle previously produced by [`into_handle`]. No-op on null.
///
/// # Safety
/// `handle` must be a pointer returned by [`into_handle`] (i.e. the matching `_new`) that has
/// not already been freed; it must not be used again afterwards.
pub(crate) unsafe fn free_handle<T>(handle: *mut T) {
    if !handle.is_null() {
        // SAFETY: forwarded from this function's contract — a live, not-yet-freed `into_handle` box.
        drop(unsafe { Box::from_raw(handle) });
    }
}

// ---------------------------------------------------------------------------------------
// Owned byte buffers crossing the boundary (Rust-allocated, Rust-freed)
// ---------------------------------------------------------------------------------------

/// Moves a `Vec<u8>` across the boundary as an owned [`AisdBytes`]. An empty vec becomes
/// [`AisdBytes::EMPTY`] (no allocation leaked; the matching free is a no-op).
///
/// Safe: only the vec's own allocation is handed over, none is read.
pub(crate) fn bytes_from_vec(mut v: Vec<u8>) -> AisdBytes {
    if v.is_empty() {
        return AisdBytes::EMPTY;
    }
    let ptr = v.as_mut_ptr();
    let len = v.len();
    let cap = v.capacity();
    core::mem::forget(v);
    AisdBytes { ptr, len, cap }
}

/// Reconstructs and drops the `Vec<u8>` behind an owned [`AisdBytes`]. No-op on a null pointer
/// (an empty buffer).
///
/// # Safety
/// `b` must be a buffer previously produced by this crate (via [`bytes_from_vec`]) and not yet
/// freed.
pub(crate) unsafe fn drop_bytes(b: AisdBytes) {
    if !b.ptr.is_null() {
        // SAFETY: forwarded from this function's contract — a live `bytes_from_vec` allocation.
        drop(unsafe { Vec::from_raw_parts(b.ptr, b.len, b.cap) });
    }
}

/// Copies the bytes a caller-owned (borrowed) [`AisdBytes`] points at into a fresh `Vec`. Empty
/// (or null) input yields an empty vec.
///
/// # Safety
/// If `b.len != 0` then `b.ptr` must point to at least `b.len` readable bytes.
pub(crate) unsafe fn copy_in(b: AisdBytes) -> Vec<u8> {
    if b.ptr.is_null() || b.len == 0 {
        Vec::new()
    } else {
        // SAFETY: forwarded from this function's contract — `b.len` readable bytes at `b.ptr`.
        unsafe { core::slice::from_raw_parts(b.ptr, b.len) }.to_vec()
    }
}

// ---------------------------------------------------------------------------------------
// Owned arrays of `AisdBytes` (Rust-allocated, Rust-freed) — the reusable shard-list infra
// ---------------------------------------------------------------------------------------

/// Moves a `Vec<AisdBytes>` across the boundary as a raw `(ptr, len)` the caller releases via the
/// matching `*_free`. An empty vec yields `(null, 0)` (no allocation leaked; the matching free is a
/// no-op). Each element should itself be an owned [`bytes_from_vec`] buffer.
///
/// Safe: only the vec's own allocation (and the already-owned element buffers) is handed over;
/// nothing is dereferenced.
pub(crate) fn bytes_vec_into_raw(items: Vec<AisdBytes>) -> (*mut AisdBytes, usize) {
    if items.is_empty() {
        return (core::ptr::null_mut(), 0);
    }
    let len = items.len();
    // `into_boxed_slice` guarantees `cap == len`, so the matching `from_raw_parts_mut` in
    // [`drop_bytes_array`] reconstructs the exact same allocation.
    let mut boxed = items.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    core::mem::forget(boxed);
    (ptr, len)
}

/// Reconstructs the owned `[AisdBytes]` array behind a `(ptr, len)` produced by
/// [`bytes_vec_into_raw`], dropping each element buffer first, then the array allocation. No-op on
/// a null pointer or zero length (so it is safe on a zeroed/EMPTY array value).
///
/// # Safety
/// `(ptr, len)` must be an array previously produced by [`bytes_vec_into_raw`] (each element an
/// unfreed [`bytes_from_vec`] buffer) and not yet freed.
pub(crate) unsafe fn drop_bytes_array(ptr: *mut AisdBytes, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    // SAFETY: forwarded from this function's contract — a live `bytes_vec_into_raw` boxed slice
    // (`into_boxed_slice` makes `cap == len`, so this reconstructs the exact allocation).
    let boxed: Box<[AisdBytes]> =
        unsafe { Box::from_raw(core::ptr::slice_from_raw_parts_mut(ptr, len)) };
    for item in &boxed {
        // SAFETY: each element is a live `bytes_from_vec` allocation owned by this array, freed
        // exactly once here before the slice itself is dropped.
        unsafe { drop_bytes(*item) };
    }
    drop(boxed);
}
