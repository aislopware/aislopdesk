//! `system_dialog_detector`: pure classifier (the ~1 Hz `listSystemDialogs` poll, ≤16 windows;
//! cold path, FFI cost irrelevant). One window in (three borrowed UTF-8 strings), one dialog out
//! (two owned strings), marshaled like the `AisdWindowGeometry` title path. The secure/system
//! allowlists and the on-screen + min-size rules live ONLY in the core.

use super::{AisdRect, slice_in};
use crate::{
    AISD_EMPTY, AISD_ERR_NULL, AISD_OK, AisdBytes, AisdStatus, bytes_from_vec, drop_bytes,
};
use aislopdesk_core::system_dialog_detector;

/// A classified system dialog, flattened for the C ABI — the `Some(Dialog)` result of
/// [`system_dialog_detector::classify`].
///
/// On an [`AISD_OK`] classify the `owner` / `title` own Rust allocations — release with
/// [`aisd_system_dialog_free`]. Field order MUST match the C header's `AisdSystemDialog`.
#[repr(C)]
pub struct AisdSystemDialog {
    /// The CoreGraphics window id to surface.
    pub window_id: u32,
    /// Rounded, standardized (non-negative) width in points.
    pub width: i64,
    /// Rounded, standardized (non-negative) height in points.
    pub height: i64,
    /// `1` ⇒ a secure-credential (`SecurityAgent`/`coreauthd`) prompt class; NOT a typing restriction.
    pub is_secure: u8,
    /// Display label — owner name, or the bundle id when the owner is empty (owned out).
    pub owner: AisdBytes,
    /// Window title, passed through unchanged (owned out).
    pub title: AisdBytes,
}

/// Borrows a `(ptr, len)` C buffer as an owned `String`, lossily (invalid UTF-8 → replacement
/// chars, never an error).
///
/// The classifier only does ASCII allowlist membership on the owner/bundle and passes the title
/// through, so a lossy read is total and behaviour-preserving for any real `SCWindow` string
/// (always valid UTF-8 from a Swift `String`).
///
/// # Safety
/// If `len != 0`, `ptr` must point to at least `len` readable bytes.
unsafe fn string_in(ptr: *const u8, len: usize) -> String {
    // SAFETY: `slice_in` borrows `len` readable bytes at `ptr` per this function's contract.
    let bytes = unsafe { slice_in(ptr, len) };
    String::from_utf8_lossy(bytes).into_owned()
}

/// The minimum on-screen width/height (points) for a window to be a surfaced system dialog. Wraps
/// [`system_dialog_detector::MIN_SIZE`].
#[must_use]
#[unsafe(no_mangle)]
pub const extern "C" fn aisd_system_dialog_min_size() -> i64 {
    system_dialog_detector::MIN_SIZE
}

/// Classifies ONE on-screen window into a surfaced system dialog.
///
/// Wraps [`system_dialog_detector::classify`]: the secure/system allowlists and the on-screen +
/// min-size rules live ONLY in the core. The three strings are borrowed for the call (each may be
/// null only when its length is `0`). Returns [`AISD_OK`] (a dialog was written to `*out` — release
/// its `owner` / `title` with [`aisd_system_dialog_free`]), [`AISD_EMPTY`] (not a system dialog;
/// nothing written), or [`AISD_ERR_NULL`] (a null `out`, or a null string with a nonzero length).
///
/// # Safety
/// `out` must be a writable [`AisdSystemDialog`]; each non-empty string must point to that many
/// readable bytes. On a non-[`AISD_OK`] return `*out` is untouched; on [`AISD_OK`] it is
/// overwritten as raw output WITHOUT freeing prior contents.
#[must_use]
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn aisd_system_dialog_classify(
    window_id: u32,
    owner_name: *const u8,
    owner_name_len: usize,
    bundle_id: *const u8,
    bundle_id_len: usize,
    is_on_screen: u8,
    title: *const u8,
    title_len: usize,
    frame: AisdRect,
    min_size: i64,
    out: *mut AisdSystemDialog,
) -> AisdStatus {
    if out.is_null()
        || (owner_name.is_null() && owner_name_len != 0)
        || (bundle_id.is_null() && bundle_id_len != 0)
        || (title.is_null() && title_len != 0)
    {
        return AISD_ERR_NULL;
    }
    // SAFETY: each string is non-null per the checks above (or has length 0) and covers that
    // many readable bytes per the contract.
    let snapshot = system_dialog_detector::WindowSnapshot::new(
        window_id,
        unsafe { string_in(owner_name, owner_name_len) },
        unsafe { string_in(bundle_id, bundle_id_len) },
        is_on_screen != 0,
        unsafe { string_in(title, title_len) },
        frame.to_core(),
    );
    match system_dialog_detector::classify(&snapshot, min_size) {
        Some(d) => {
            let dialog = AisdSystemDialog {
                window_id: d.window_id,
                width: d.width,
                height: d.height,
                is_secure: u8::from(d.is_secure),
                owner: bytes_from_vec(d.owner.into_bytes()),
                title: bytes_from_vec(d.title.into_bytes()),
            };
            // SAFETY: `out` is non-null per the check above and writable per the contract; the
            // prior contents are overwritten without freeing, as documented.
            unsafe { out.write(dialog) };
            AISD_OK
        }
        None => AISD_EMPTY,
    }
}

/// Releases the owned `owner` / `title` buffers inside an [`AisdSystemDialog`] and resets them to
/// empty. Idempotent; the struct itself is caller-owned.
///
/// # Safety
/// `msg` must point to a writable [`AisdSystemDialog`] previously filled by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_system_dialog_free(msg: *mut AisdSystemDialog) {
    if msg.is_null() {
        return;
    }
    // SAFETY: `msg` is non-null per the guard and points to a writable `AisdSystemDialog`
    // previously filled by this library per the contract.
    let m = unsafe { &mut *msg };
    // SAFETY: `owner` / `title` are live `bytes_from_vec` buffers (or empty); freeing then
    // resetting to empty makes a repeat free a no-op (idempotent).
    unsafe { drop_bytes(m.owner) };
    unsafe { drop_bytes(m.title) };
    m.owner = AisdBytes::EMPTY;
    m.title = AisdBytes::EMPTY;
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;
    use crate::copy_in;

    /// A fresh, all-empty out struct for the classify tests.
    const fn empty_dialog() -> AisdSystemDialog {
        AisdSystemDialog {
            window_id: 0,
            width: 0,
            height: 0,
            is_secure: 0,
            owner: AisdBytes::EMPTY,
            title: AisdBytes::EMPTY,
        }
    }

    #[test]
    fn system_dialog_min_size_matches_core() {
        assert_eq!(
            aisd_system_dialog_min_size(),
            system_dialog_detector::MIN_SIZE
        );
    }

    #[test]
    fn system_dialog_classify_security_agent_is_secure() {
        let owner = b"SecurityAgent";
        let bundle = b"com.apple.SecurityAgent";
        let title = b"Authenticate";
        let frame = AisdRect {
            x: 830.0,
            y: 201.0,
            width: 260.0,
            height: 312.0,
        };
        let mut out = empty_dialog();
        let status = unsafe {
            aisd_system_dialog_classify(
                1966,
                owner.as_ptr(),
                owner.len(),
                bundle.as_ptr(),
                bundle.len(),
                1,
                title.as_ptr(),
                title.len(),
                frame,
                aisd_system_dialog_min_size(),
                &mut out,
            )
        };
        assert_eq!(status, AISD_OK);
        assert_eq!(out.window_id, 1966);
        assert_eq!(out.width, 260);
        assert_eq!(out.height, 312);
        assert_eq!(out.is_secure, 1);
        assert_eq!(unsafe { copy_in(out.owner) }, owner);
        assert_eq!(unsafe { copy_in(out.title) }, title);
        unsafe { aisd_system_dialog_free(&mut out) };
        // Idempotent free + buffers reset to empty.
        assert!(out.owner.ptr.is_null());
        assert!(out.title.ptr.is_null());
        unsafe { aisd_system_dialog_free(&mut out) };
    }

    #[test]
    fn system_dialog_classify_empty_owner_falls_back_to_bundle() {
        let bundle = b"com.apple.coreauthd";
        let frame = AisdRect {
            x: 0.0,
            y: 0.0,
            width: 260.0,
            height: 312.0,
        };
        let mut out = empty_dialog();
        let status = unsafe {
            aisd_system_dialog_classify(
                7,
                core::ptr::null(),
                0,
                bundle.as_ptr(),
                bundle.len(),
                1,
                core::ptr::null(),
                0,
                frame,
                60,
                &mut out,
            )
        };
        assert_eq!(status, AISD_OK);
        assert_eq!(out.is_secure, 1);
        // Empty owner name → label is the bundle id; empty title stays empty (no allocation).
        assert_eq!(unsafe { copy_in(out.owner) }, bundle);
        assert_eq!(out.title.len, 0);
        assert!(out.title.ptr.is_null());
        unsafe { aisd_system_dialog_free(&mut out) };
    }

    #[test]
    fn system_dialog_classify_non_dialog_is_empty() {
        let owner = b"Google Chrome";
        let bundle = b"com.google.Chrome";
        let frame = AisdRect {
            x: 0.0,
            y: 0.0,
            width: 700.0,
            height: 500.0,
        };
        let mut out = empty_dialog();
        let status = unsafe {
            aisd_system_dialog_classify(
                1,
                owner.as_ptr(),
                owner.len(),
                bundle.as_ptr(),
                bundle.len(),
                1,
                core::ptr::null(),
                0,
                frame,
                60,
                &mut out,
            )
        };
        assert_eq!(status, AISD_EMPTY);
        // AISD_EMPTY writes nothing — the out struct is untouched (no buffer to free).
        assert_eq!(out.window_id, 0);
        assert!(out.owner.ptr.is_null());
    }

    #[test]
    fn system_dialog_classify_null_out_is_err() {
        let owner = b"SecurityAgent";
        let frame = AisdRect {
            x: 0.0,
            y: 0.0,
            width: 260.0,
            height: 312.0,
        };
        let status = unsafe {
            aisd_system_dialog_classify(
                1,
                owner.as_ptr(),
                owner.len(),
                core::ptr::null(),
                0,
                1,
                core::ptr::null(),
                0,
                frame,
                60,
                core::ptr::null_mut(),
            )
        };
        assert_eq!(status, AISD_ERR_NULL);
    }
}
