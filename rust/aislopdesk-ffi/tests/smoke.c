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

    if (failures == 0) {
        printf("aislopdesk-ffi C smoke: OK\n");
        return 0;
    }
    fprintf(stderr, "aislopdesk-ffi C smoke: %d FAILURE(S)\n", failures);
    return 1;
}
