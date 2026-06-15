//! `input_event`: client→host pointer/key/scroll/text events (per user action; one owned text
//! buffer, marshaled like `AisdWireMessage`).

use super::{slice_in, status_for_video_error};
use crate::{
    AISD_ERR_INVALID_ARGUMENT, AISD_ERR_NULL, AISD_OK, AisdBytes, AisdStatus, bytes_from_vec,
    copy_in, drop_bytes,
};
use aislopdesk_core::geometry::VideoPoint;
use aislopdesk_core::input_event::{InputEvent, InputModifiers, MouseButton};

/// [`InputEvent::MouseMove`] discriminator (`kind`).
pub const AISD_INPUT_MOUSE_MOVE: u8 = 1;
/// [`InputEvent::MouseDown`] discriminator.
pub const AISD_INPUT_MOUSE_DOWN: u8 = 2;
/// [`InputEvent::MouseUp`] discriminator.
pub const AISD_INPUT_MOUSE_UP: u8 = 3;
/// [`InputEvent::Scroll`] discriminator.
pub const AISD_INPUT_SCROLL: u8 = 4;
/// [`InputEvent::Key`] discriminator.
pub const AISD_INPUT_KEY: u8 = 5;
/// [`InputEvent::Text`] discriminator.
pub const AISD_INPUT_TEXT: u8 = 6;
/// [`InputEvent::MouseDrag`] discriminator.
pub const AISD_INPUT_MOUSE_DRAG: u8 = 7;

/// A client→host input event, flattened for the C ABI.
///
/// `kind` (`AISD_INPUT_*`) selects which fields are meaningful; `tag` (the self-inject filter)
/// is valid for EVERY kind. Field usage: `MOUSE_MOVE` → `x`/`y`; `MOUSE_DOWN`/`MOUSE_UP`/
/// `MOUSE_DRAG` → `button`/`click_count`/`modifiers`/`x`/`y`; `SCROLL` → `dx`/`dy`/`x`/`y`/
/// `scroll_phase`/`momentum_phase`/`continuous`; `KEY` → `key_code`/`down`/`modifiers`; `TEXT`
/// → `text` (UTF-8, owned out via [`aisd_input_event_free`] / borrowed in).
#[repr(C)]
pub struct AisdInputEvent {
    /// Message discriminator (`AISD_INPUT_*`).
    pub kind: u8,
    /// Self-inject filter tag (valid for every kind).
    pub tag: u32,
    /// Normalised (0..1) x (`MOVE`/`DOWN`/`UP`/`DRAG`/`SCROLL`).
    pub x: f64,
    /// Normalised (0..1) y.
    pub y: f64,
    /// `SCROLL` horizontal delta (pixels).
    pub dx: f64,
    /// `SCROLL` vertical delta (pixels).
    pub dy: f64,
    /// Mouse button raw (`0`=left, `1`=right, `2`=other) for `DOWN`/`UP`/`DRAG`.
    pub button: u8,
    /// Originating click count for `DOWN`/`UP`/`DRAG`.
    pub click_count: u8,
    /// Modifier bitmask for `DOWN`/`UP`/`DRAG`/`KEY`.
    pub modifiers: u8,
    /// `SCROLL` `CGScrollPhase` code (carried opaquely).
    pub scroll_phase: u8,
    /// `SCROLL` `CGMomentumScrollPhase` code (carried opaquely).
    pub momentum_phase: u8,
    /// `SCROLL` pixel-precise flag (`0`/nonzero, read `!= 0`).
    pub continuous: u8,
    /// `KEY` host virtual keycode.
    pub key_code: u16,
    /// `KEY` down flag (`0`/nonzero, read `!= 0`).
    pub down: u8,
    /// `TEXT` UTF-8 bytes (owned out / borrowed in; [`AisdBytes::EMPTY`] otherwise).
    pub text: AisdBytes,
}

impl AisdInputEvent {
    /// An all-zero struct with an empty text buffer — the base every decode fills in.
    const fn zeroed() -> Self {
        Self {
            kind: 0,
            tag: 0,
            x: 0.0,
            y: 0.0,
            dx: 0.0,
            dy: 0.0,
            button: 0,
            click_count: 0,
            modifiers: 0,
            scroll_phase: 0,
            momentum_phase: 0,
            continuous: 0,
            key_code: 0,
            down: 0,
            text: AisdBytes::EMPTY,
        }
    }
}

/// Rebuilds a core [`InputEvent`] from the caller's C struct, validating the `kind`, the mouse
/// button, and any UTF-8 text.
///
/// # Safety
/// A non-empty `text` in `m` must point to that many readable bytes.
unsafe fn c_to_input_event(m: &AisdInputEvent) -> Result<InputEvent, AisdStatus> {
    unsafe {
        let normalized = VideoPoint::new(m.x, m.y);
        let modifiers = InputModifiers(m.modifiers);
        let event = match m.kind {
            AISD_INPUT_MOUSE_MOVE => InputEvent::MouseMove {
                normalized,
                tag: m.tag,
            },
            AISD_INPUT_MOUSE_DOWN | AISD_INPUT_MOUSE_UP | AISD_INPUT_MOUSE_DRAG => {
                let button = MouseButton::from_u8(m.button).ok_or(AISD_ERR_INVALID_ARGUMENT)?;
                let click_count = m.click_count;
                match m.kind {
                    AISD_INPUT_MOUSE_DOWN => InputEvent::MouseDown {
                        button,
                        normalized,
                        click_count,
                        modifiers,
                        tag: m.tag,
                    },
                    AISD_INPUT_MOUSE_UP => InputEvent::MouseUp {
                        button,
                        normalized,
                        click_count,
                        modifiers,
                        tag: m.tag,
                    },
                    _ => InputEvent::MouseDrag {
                        button,
                        normalized,
                        click_count,
                        modifiers,
                        tag: m.tag,
                    },
                }
            }
            AISD_INPUT_SCROLL => InputEvent::Scroll {
                dx: m.dx,
                dy: m.dy,
                normalized,
                scroll_phase: m.scroll_phase,
                momentum_phase: m.momentum_phase,
                continuous: m.continuous != 0,
                tag: m.tag,
            },
            AISD_INPUT_KEY => InputEvent::Key {
                key_code: m.key_code,
                down: m.down != 0,
                modifiers,
                tag: m.tag,
            },
            AISD_INPUT_TEXT => {
                let text =
                    String::from_utf8(copy_in(m.text)).map_err(|_| AISD_ERR_INVALID_ARGUMENT)?;
                InputEvent::Text { text, tag: m.tag }
            }
            _ => return Err(AISD_ERR_INVALID_ARGUMENT),
        };
        Ok(event)
    }
}

/// Flattens a core [`InputEvent`] into the C struct, allocating an owned buffer for text.
fn input_event_to_c(e: &InputEvent) -> AisdInputEvent {
    let mut out = AisdInputEvent::zeroed();
    out.kind = e.message_type();
    out.tag = e.tag();
    match e {
        InputEvent::MouseMove { normalized, .. } => {
            out.x = normalized.x;
            out.y = normalized.y;
        }
        InputEvent::MouseDown {
            button,
            normalized,
            click_count,
            modifiers,
            ..
        }
        | InputEvent::MouseUp {
            button,
            normalized,
            click_count,
            modifiers,
            ..
        }
        | InputEvent::MouseDrag {
            button,
            normalized,
            click_count,
            modifiers,
            ..
        } => {
            out.button = button.raw();
            out.click_count = *click_count;
            out.modifiers = modifiers.raw();
            out.x = normalized.x;
            out.y = normalized.y;
        }
        InputEvent::Scroll {
            dx,
            dy,
            normalized,
            scroll_phase,
            momentum_phase,
            continuous,
            ..
        } => {
            out.dx = *dx;
            out.dy = *dy;
            out.x = normalized.x;
            out.y = normalized.y;
            out.scroll_phase = *scroll_phase;
            out.momentum_phase = *momentum_phase;
            out.continuous = u8::from(*continuous);
        }
        InputEvent::Key {
            key_code,
            down,
            modifiers,
            ..
        } => {
            out.key_code = *key_code;
            out.down = u8::from(*down);
            out.modifiers = modifiers.raw();
        }
        InputEvent::Text { text, .. } => out.text = bytes_from_vec(text.clone().into_bytes()),
    }
    out
}

/// Encodes a caller-built [`AisdInputEvent`] into its wire form.
///
/// On [`AISD_OK`], `*out` owns the buffer — release with [`crate::aisd_bytes_free`]. Returns
/// [`AISD_ERR_NULL`] for a null argument or [`AISD_ERR_INVALID_ARGUMENT`] for an unknown `kind`
/// / out-of-range `button` / non-UTF-8 `text`.
///
/// # Safety
/// `msg` and `out` must be valid, writable pointers; a non-empty `text` inside `*msg` must
/// point to that many readable bytes.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_input_event_encode(
    msg: *const AisdInputEvent,
    out: *mut AisdBytes,
) -> AisdStatus {
    unsafe {
        if msg.is_null() || out.is_null() {
            return AISD_ERR_NULL;
        }
        match c_to_input_event(&*msg) {
            Ok(event) => {
                out.write(bytes_from_vec(event.encode()));
                AISD_OK
            }
            Err(status) => status,
        }
    }
}

/// Decodes an input event into `*out`.
///
/// On [`AISD_OK`], `*out` may own a `text` buffer — release with [`aisd_input_event_free`].
/// `data` may be null only when `len == 0`. Maps a non-finite coordinate / unknown button /
/// non-UTF-8 text / unknown type to [`crate::AISD_ERR_MALFORMED`] and a short body to
/// [`crate::AISD_ERR_TRUNCATED`].
///
/// # Safety
/// `out` must be writable; if `len != 0`, `data` must point to `len` readable bytes. On a
/// non-[`AISD_OK`] return `*out` is untouched; on [`AISD_OK`] it is overwritten as raw output
/// WITHOUT freeing prior contents.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_input_event_decode(
    data: *const u8,
    len: usize,
    out: *mut AisdInputEvent,
) -> AisdStatus {
    unsafe {
        if out.is_null() || (data.is_null() && len != 0) {
            return AISD_ERR_NULL;
        }
        match InputEvent::decode(slice_in(data, len)) {
            Ok(event) => {
                out.write(input_event_to_c(&event));
                AISD_OK
            }
            Err(e) => status_for_video_error(&e),
        }
    }
}

/// Releases the owned `text` buffer inside an [`AisdInputEvent`] and resets it to empty.
/// Idempotent; the struct itself is caller-owned.
///
/// # Safety
/// `msg` must point to a writable [`AisdInputEvent`] previously filled by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_input_event_free(msg: *mut AisdInputEvent) {
    unsafe {
        if msg.is_null() {
            return;
        }
        let m = &mut *msg;
        drop_bytes(m.text);
        m.text = AisdBytes::EMPTY;
    }
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;
    use crate::{AISD_ERR_MALFORMED, AISD_ERR_TRUNCATED};
    use aislopdesk_core::geometry::VideoPoint;

    /// Reads an owned/returned `AisdBytes` as a `Vec` (the caller still frees it).
    unsafe fn view(b: AisdBytes) -> Vec<u8> {
        unsafe {
            if b.ptr.is_null() || b.len == 0 {
                Vec::new()
            } else {
                core::slice::from_raw_parts(b.ptr, b.len).to_vec()
            }
        }
    }

    /// Borrows a slice as an input `AisdBytes` (encode copies it, never frees).
    fn borrow(bytes: &[u8]) -> AisdBytes {
        if bytes.is_empty() {
            AisdBytes::EMPTY
        } else {
            AisdBytes {
                ptr: bytes.as_ptr().cast_mut(),
                len: bytes.len(),
                cap: 0,
            }
        }
    }

    #[test]
    fn input_event_round_trips_every_variant() {
        unsafe {
            let mods = InputModifiers::SHIFT.union(InputModifiers::COMMAND);
            let cases = [
                InputEvent::MouseMove {
                    normalized: VideoPoint::new(0.25, 0.75),
                    tag: 42,
                },
                InputEvent::MouseDown {
                    button: MouseButton::Right,
                    normalized: VideoPoint::new(0.1, 0.2),
                    click_count: 2,
                    modifiers: mods,
                    tag: 7,
                },
                InputEvent::MouseUp {
                    button: MouseButton::Left,
                    normalized: VideoPoint::new(0.3, 0.4),
                    click_count: 1,
                    modifiers: InputModifiers::default(),
                    tag: 8,
                },
                InputEvent::MouseDrag {
                    button: MouseButton::Other,
                    normalized: VideoPoint::new(0.5, 0.6),
                    click_count: 1,
                    modifiers: InputModifiers::CONTROL,
                    tag: 9,
                },
                InputEvent::Scroll {
                    dx: -3.5,
                    dy: 12.0,
                    normalized: VideoPoint::new(0.0, 1.0),
                    scroll_phase: 2,
                    momentum_phase: 0,
                    continuous: true,
                    tag: 10,
                },
                InputEvent::Scroll {
                    dx: 0.0,
                    dy: 4.25,
                    normalized: VideoPoint::new(0.0, 1.0),
                    scroll_phase: 0,
                    momentum_phase: 2,
                    continuous: false,
                    tag: 11,
                },
                InputEvent::Key {
                    key_code: 0x35,
                    down: true,
                    modifiers: InputModifiers::OPTION,
                    tag: 12,
                },
                InputEvent::Text {
                    text: "gõ được 文字".to_owned(),
                    tag: 13,
                },
            ];
            for core_event in cases {
                // `input_event_to_c` is the decode-side marshaling, but it produces a valid C
                // struct from a core event — exactly the encode INPUT we want (and a free check
                // for its text allocation). encode borrows `text` (copies, never frees), so the
                // owned buffer is released afterwards via `aisd_input_event_free(&mut c_in)`.
                let mut c_in = input_event_to_c(&core_event);
                let mut frame = AisdBytes::EMPTY;
                assert_eq!(aisd_input_event_encode(&c_in, &mut frame), AISD_OK);
                assert_eq!(
                    view(frame),
                    core_event.encode(),
                    "encode parity {}",
                    c_in.kind
                );

                let mut out = AisdInputEvent::zeroed();
                assert_eq!(
                    aisd_input_event_decode(frame.ptr, frame.len, &mut out),
                    AISD_OK
                );
                let round = decode_c_input(&out);
                assert_eq!(round, core_event, "decode parity {}", out.kind);
                assert_eq!(out.tag, core_event.tag(), "tag preserved {}", out.kind);
                aisd_input_event_free(&mut out);
                aisd_input_event_free(&mut out); // idempotent
                aisd_input_event_free(&mut c_in); // free the text buffer input_event_to_c made
                crate::aisd_bytes_free(frame);
            }
        }
    }

    /// Rebuilds a core `InputEvent` from a decoded C struct (test-side mirror of the Swift side).
    unsafe fn decode_c_input(out: &AisdInputEvent) -> InputEvent {
        unsafe {
            let normalized = VideoPoint::new(out.x, out.y);
            let modifiers = InputModifiers(out.modifiers);
            match out.kind {
                AISD_INPUT_MOUSE_MOVE => InputEvent::MouseMove {
                    normalized,
                    tag: out.tag,
                },
                AISD_INPUT_MOUSE_DOWN => InputEvent::MouseDown {
                    button: MouseButton::from_u8(out.button).unwrap(),
                    normalized,
                    click_count: out.click_count,
                    modifiers,
                    tag: out.tag,
                },
                AISD_INPUT_MOUSE_UP => InputEvent::MouseUp {
                    button: MouseButton::from_u8(out.button).unwrap(),
                    normalized,
                    click_count: out.click_count,
                    modifiers,
                    tag: out.tag,
                },
                AISD_INPUT_MOUSE_DRAG => InputEvent::MouseDrag {
                    button: MouseButton::from_u8(out.button).unwrap(),
                    normalized,
                    click_count: out.click_count,
                    modifiers,
                    tag: out.tag,
                },
                AISD_INPUT_SCROLL => InputEvent::Scroll {
                    dx: out.dx,
                    dy: out.dy,
                    normalized,
                    scroll_phase: out.scroll_phase,
                    momentum_phase: out.momentum_phase,
                    continuous: out.continuous != 0,
                    tag: out.tag,
                },
                AISD_INPUT_KEY => InputEvent::Key {
                    key_code: out.key_code,
                    down: out.down != 0,
                    modifiers,
                    tag: out.tag,
                },
                _ => InputEvent::Text {
                    text: String::from_utf8(view(out.text)).unwrap(),
                    tag: out.tag,
                },
            }
        }
    }

    #[test]
    fn input_event_encode_and_decode_error_paths() {
        unsafe {
            let mut out_bytes = AisdBytes::EMPTY;
            // Unknown kind on encode.
            let bad_kind = AisdInputEvent {
                kind: 99,
                ..AisdInputEvent::zeroed()
            };
            assert_eq!(
                aisd_input_event_encode(&bad_kind, &mut out_bytes),
                AISD_ERR_INVALID_ARGUMENT
            );
            // Out-of-range mouse button on encode.
            let bad_button = AisdInputEvent {
                kind: AISD_INPUT_MOUSE_DOWN,
                button: 9,
                ..AisdInputEvent::zeroed()
            };
            assert_eq!(
                aisd_input_event_encode(&bad_button, &mut out_bytes),
                AISD_ERR_INVALID_ARGUMENT
            );
            // Non-UTF-8 text on encode.
            let invalid = [0xFFu8, 0xFE];
            let bad_text = AisdInputEvent {
                kind: AISD_INPUT_TEXT,
                text: borrow(&invalid),
                ..AisdInputEvent::zeroed()
            };
            assert_eq!(
                aisd_input_event_encode(&bad_text, &mut out_bytes),
                AISD_ERR_INVALID_ARGUMENT
            );
            // Null guards.
            let mut out = AisdInputEvent::zeroed();
            assert_eq!(
                aisd_input_event_encode(core::ptr::null(), &mut out_bytes),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_input_event_decode(core::ptr::null(), 1, &mut out),
                AISD_ERR_NULL
            );
            // Decode: unknown type → malformed; unknown button → malformed; short → truncated.
            assert_eq!(
                aisd_input_event_decode([200u8].as_ptr(), 1, &mut out),
                AISD_ERR_MALFORMED
            );
            let mut down = InputEvent::MouseDown {
                button: MouseButton::Left,
                normalized: VideoPoint::new(0.0, 0.0),
                click_count: 1,
                modifiers: InputModifiers::default(),
                tag: 0,
            }
            .encode();
            down[5] = 9; // button byte (after type + 4-byte tag)
            assert_eq!(
                aisd_input_event_decode(down.as_ptr(), down.len(), &mut out),
                AISD_ERR_MALFORMED
            );
            let short_move = [AISD_INPUT_MOUSE_MOVE, 0, 0];
            assert_eq!(
                aisd_input_event_decode(short_move.as_ptr(), short_move.len(), &mut out),
                AISD_ERR_TRUNCATED
            );
            aisd_input_event_free(core::ptr::null_mut()); // no-op
        }
    }
}
