#include "heap.h"
#include "stream-io.h"

typedef struct { uintptr_t value, status; } outcome;
extern outcome fenrir_entry(uintptr_t), stream_feed(uintptr_t), stream_finish(uintptr_t),
    stream_invalid_offset(uintptr_t), stream_final_offset(uintptr_t), stream_summary_keys(uintptr_t),
    stream_next_line(uintptr_t), stream_line_bytes(uintptr_t), stream_remaining_keys(uintptr_t),
    stream_rejection_line(uintptr_t);
extern void fen_enter(fen_roots *, fen_object **, size_t);
extern void fen_leave(void);
extern int64_t fen_bytes_index(const fen_object *, uintptr_t);
static uintptr_t checked(outcome result) {
    if (result.status) stream_trap(result.status);
    return result.value;
}

static int write_bytes(int diagnostic, const fen_object *bytes) {
    char buffer[128];
    uintptr_t i = 0;
    while (i < bytes->fields[0]) {
        size_t n = 0;
        while (i < bytes->fields[0] && n < sizeof buffer)
            buffer[n++] = (char)fen_bytes_index(bytes, i++);
        if (stream_write(diagnostic, buffer, n)) return -1;
    }
    return 0;
}

int stream_process(size_t capacity) {
    // The compiled decoder retains only scalars and aggregate nodes across feeds.
    static struct { fen_object header; unsigned char bytes[65536]; } input = {
        .header = {.tag = UINT32_MAX, .live = FEN_IMAGE_OBJECT}
    };
    fen_object *state = NULL;
    fen_roots frame;
    fen_enter(&frame, &state, 1);
    state = (fen_object *)checked(fenrir_entry(0));
    int64_t offset = -1;
    int n;
    while ((n = stream_read(input.bytes, capacity)) > 0) {
        input.header.fields[0] = n;
        fen_object args = {.fields = {(uintptr_t)state, (uintptr_t)&input.header},
                           .live = FEN_IMAGE_OBJECT};
        state = (fen_object *)checked(stream_feed((uintptr_t)&args));
        offset = (int64_t)checked(stream_invalid_offset((uintptr_t)state));
        if (offset >= 0) break;
    }
    int rc = 0;
    if (n < 0) { rc = 2; goto done; }
    if (offset < 0) {
        state = (fen_object *)checked(stream_finish((uintptr_t)state));
        offset = (int64_t)checked(stream_final_offset((uintptr_t)state));
    }
    if (offset >= 0) {
        fen_object *line = (fen_object *)checked(stream_rejection_line((uintptr_t)offset));
        rc = write_bytes(1, line) ? 2 : 1;
        goto done;
    }
    state = (fen_object *)checked(stream_summary_keys((uintptr_t)state));
    for (;;) {
        state = (fen_object *)checked(stream_next_line((uintptr_t)state));
        fen_object *bytes = (fen_object *)checked(stream_line_bytes((uintptr_t)state));
        if (!bytes->fields[0]) break;
        if (write_bytes(0, bytes)) { rc = 2; break; }
        state = (fen_object *)checked(stream_remaining_keys((uintptr_t)state));
    }
done:
    fen_leave();
    return rc;
}
