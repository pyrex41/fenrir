#include <solo5.h>
#include "heap.h"

typedef struct { fen_object *result; uintptr_t status; } outcome;
extern outcome http_response(fen_object *);
static solo5_handle_t input, output;
static struct { fen_object leaf; uint8_t bytes[8192]; } head;

void fen_write(const char *p, size_t n) { solo5_console_write(p, n); }
void fen_write_i64(int64_t n) { (void)n; solo5_exit(2); }

static int read_exact(uint8_t *dst, size_t n) {
    while (n) {
        size_t got = 0;
        solo5_result_t rc = solo5_net_read(input, dst, n, &got);
        if (rc == SOLO5_R_AGAIN) {
            solo5_handle_set_t ready;
            solo5_yield(~(solo5_time_t)0, &ready);
            if (ready & (1ULL << output)) return 0;
            continue;
        }
        if (rc != SOLO5_R_OK || !got) return 0;
        dst += got;
        n -= got;
    }
    return 1;
}

int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
    struct solo5_net_info net;
    if (solo5_net_acquire("input", &input, &net) != SOLO5_R_OK ||
        solo5_net_acquire("output", &output, &net) != SOLO5_R_OK) return 2;
    head.leaf.tag = UINT32_MAX;
    head.leaf.live = FEN_IMAGE_OBJECT;
    uint32_t frame[2];
    while (read_exact((uint8_t *)frame, sizeof frame)) {
        if (!frame[0] || frame[0] > sizeof head.bytes || frame[1] > 1 ||
            !read_exact(head.bytes, frame[0])) return 2;
        head.leaf.fields[0] = frame[0];
        fen_object args = {.fields = {(uintptr_t)&head.leaf, frame[1]}, .live = FEN_IMAGE_OBJECT};
        outcome result = http_response(&args);
        if (result.status || solo5_net_write(output, (uint8_t *)result.result->fields,
                                             4*sizeof(uint64_t)) != SOLO5_R_OK) return 2;
    }
    return 0;
}
