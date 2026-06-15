/*
 * smoke.c — a minimal C consumer of libaislopdesk_ffi, proving real cross-language
 * linkage and ABI agreement (struct layout, ownership, status codes) from actual C — not
 * just from Rust calling its own `extern "C"` functions.
 *
 * Build + run via `tests/run_c_smoke.sh` (which resolves the right link flags). Exit code
 * 0 = all checks passed; any failure prints a message and returns non-zero.
 */
#include "aislopdesk_ffi.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond, msg)                                                                  \
    do {                                                                                  \
        if (!(cond)) {                                                                    \
            fprintf(stderr, "FAIL: %s\n", (msg));                                         \
            failures++;                                                                   \
        }                                                                                 \
    } while (0)

int main(void) {
    /* 1. A trivial stateless call: wrap-aware sequence distance. */
    CHECK(aisd_seq_distance(10, 4) == 6, "seq_distance ahead");
    CHECK(aisd_seq_distance(2, 0xFFFFFFFFu) == 3, "seq_distance across wrap");

    /* 2. Encode an Output(seq=7, "hi\xff") in C, decode it back, compare every field. */
    uint8_t payload[3] = {'h', 'i', 0xFF};
    AisdWireMessage out_msg;
    memset(&out_msg, 0, sizeof(out_msg));
    out_msg.tag = AISD_WIRE_OUTPUT;
    out_msg.seq = 7;
    out_msg.data.ptr = payload;
    out_msg.data.len = sizeof(payload);
    out_msg.data.cap = 0; /* borrowed; encode never frees it */

    AisdBytes frame = {NULL, 0, 0};
    CHECK(aisd_wire_message_encode(&out_msg, &frame) == AISD_OK, "encode output ok");
    CHECK(frame.ptr != NULL && frame.len > 0, "encode produced a frame");

    AisdFrameDecoder *dec = aisd_frame_decoder_new();
    CHECK(dec != NULL, "decoder allocated");
    CHECK(aisd_frame_decoder_append(dec, frame.ptr, frame.len) == AISD_OK, "append frame");

    AisdWireMessage decoded;
    memset(&decoded, 0, sizeof(decoded));
    CHECK(aisd_frame_decoder_next(dec, &decoded) == AISD_OK, "decode output ok");
    CHECK(decoded.tag == AISD_WIRE_OUTPUT, "decoded tag is output");
    CHECK(decoded.seq == 7, "decoded seq");
    CHECK(decoded.data.len == sizeof(payload), "decoded payload length");
    CHECK(decoded.data.ptr != NULL &&
              memcmp(decoded.data.ptr, payload, sizeof(payload)) == 0,
          "decoded payload bytes");

    AisdWireMessage spare;
    memset(&spare, 0, sizeof(spare));
    CHECK(aisd_frame_decoder_next(dec, &spare) == AISD_EMPTY, "stream drained");

    aisd_wire_message_free(&decoded);
    aisd_bytes_free(frame);

    /* 3. A control message with no payload round-trips too. */
    AisdWireMessage bell;
    memset(&bell, 0, sizeof(bell));
    bell.tag = AISD_WIRE_BELL;
    AisdBytes bell_frame = {NULL, 0, 0};
    CHECK(aisd_wire_message_encode(&bell, &bell_frame) == AISD_OK, "encode bell");
    CHECK(aisd_frame_decoder_append(dec, bell_frame.ptr, bell_frame.len) == AISD_OK,
          "append bell");
    AisdWireMessage bell_out;
    memset(&bell_out, 0, sizeof(bell_out));
    CHECK(aisd_frame_decoder_next(dec, &bell_out) == AISD_OK, "decode bell");
    CHECK(bell_out.tag == AISD_WIRE_BELL, "decoded tag is bell");
    aisd_wire_message_free(&bell_out);
    aisd_bytes_free(bell_frame);

    /* 4. Error + null guards behave. */
    AisdWireMessage bad;
    memset(&bad, 0, sizeof(bad));
    bad.tag = 99; /* not a real message type */
    AisdBytes junk = {NULL, 0, 0};
    CHECK(aisd_wire_message_encode(&bad, &junk) == AISD_ERR_INVALID_ARGUMENT,
          "encode rejects unknown tag");
    CHECK(aisd_frame_decoder_next(NULL, &decoded) == AISD_ERR_NULL, "null decoder rejected");

    aisd_frame_decoder_free(dec);
    aisd_frame_decoder_free(NULL); /* no-op */

    /* 5. Pure flat-struct geometry policies (FFI wiring round). Exercises AisdRect, AisdPoint,
     * AisdPlacement, AisdVDGeometry, AisdVDMillimeters, AisdCaptureWindowSnapshot layouts from C. */
    AisdRect display = {0.0, 0.0, 1920.0, 1080.0};

    AisdPlacement plc = aisd_window_placement(2400.0, 800.0, display);
    CHECK(plc.x == 0.0 && plc.width == 1920.0 && plc.height == 800.0 && plc.needs_resize == 1,
          "window_placement clamps oversized width and flags resize");
    CHECK(aisd_window_fits(1920.0, 1080.0, display) == 1, "window_fits exact");
    CHECK(aisd_window_fits(1921.0, 1080.0, display) == 0, "window_fits width over");

    AisdVDGeometry g = aisd_vd_geometry(1920, 1080, 2, 7680);
    CHECK(g.pixel_width == 3840 && g.pixel_height == 2160 && g.exceeds_pixel_limit == 0,
          "vd_geometry 2x pixel dims under limit");
    CHECK(aisd_vd_geometry(3840, 2160, 2, 6144).exceeds_pixel_limit == 1,
          "vd_geometry over base-M chip limit");

    AisdVDMillimeters mm = aisd_vd_size_in_millimeters(3840, 2160, 163.0);
    CHECK(mm.width > 598.0 && mm.width < 599.0, "vd_size_in_millimeters width ~598.5mm");

    AisdRect displays[2] = {{0.0, 0.0, 1920.0, 1080.0}, {1920.0, 0.0, 2560.0, 1440.0}};
    AisdPoint origin = aisd_vd_origin_to_right(displays, 2);
    CHECK(origin.x == 4480.0 && origin.y == 0.0, "vd_origin_to_right rightmost edge");
    AisdPoint origin0 = aisd_vd_origin_to_right(NULL, 0);
    CHECK(origin0.x == 0.0 && origin0.y == 0.0, "vd_origin_to_right empty -> (0,0)");

    CHECK(aisd_vd_chip_pixel_limit("Apple M3 Pro") == 7680, "chip limit pro/max/ultra");
    CHECK(aisd_vd_chip_pixel_limit("Apple M2") == 6144, "chip limit base M");
    CHECK(aisd_vd_chip_pixel_limit(NULL) == 7680, "chip limit NULL -> default");

    double rates[3] = {0.0, 0.0, 0.0};
    size_t nrates = aisd_vd_refresh_rates(120, rates, 3);
    CHECK(nrates == 3 && rates[0] == 120.0 && rates[1] == 60.0 && rates[2] == 30.0,
          "vd_refresh_rates 120 -> [120,60,30]");
    CHECK(aisd_vd_refresh_rates(60, rates, 3) == 2, "vd_refresh_rates 60 -> 2 modes");

    AisdRect target = {100.0, 100.0, 800.0, 600.0};
    AisdCaptureWindowSnapshot front[1] = {{2, 42, 0, {700.0, 100.0, 400.0, 300.0}}};
    AisdRect uni = aisd_capture_union_region(target, 1, 42, front, 1, display, 0.30);
    CHECK(uni.width == 1000.0 && uni.height == 600.0,
          "capture_union_region extends to cover the same-pid panel");
    AisdRect noneuni = aisd_capture_union_region(target, 1, 42, NULL, 0, display, 0.30);
    CHECK(noneuni.width == 800.0, "capture_union_region with no panels = target");

    AisdRect ca = {0.0, 0.0, 100.0, 100.0};
    AisdRect cb = {0.0, 0.0, 120.0, 100.0};
    CHECK(aisd_capture_should_retarget(ca, cb, 8.0) == 1, "capture_should_retarget over delta");
    CHECK(aisd_capture_should_retarget(ca, ca, 8.0) == 0, "capture_should_retarget identical");
    CHECK(aisd_capture_reorigin_on_geometry(1) == 1, "capture_reorigin no active region");
    CHECK(aisd_capture_reorigin_on_geometry(0) == 0, "capture_reorigin active union holds");

    if (failures == 0) {
        printf("aislopdesk-ffi C smoke: OK\n");
        return 0;
    }
    fprintf(stderr, "aislopdesk-ffi C smoke: %d FAILURE(S)\n", failures);
    return 1;
}
