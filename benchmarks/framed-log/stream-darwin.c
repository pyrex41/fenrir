#include "stream-io.h"
#include <stdio.h>
#include <stdlib.h>

#ifdef FEN_PROFILE_HEAP
#include <inttypes.h>
#include <time.h>

extern uint64_t fen_profile_allocations, fen_profile_collections, fen_profile_collection_ns;
static uint64_t input_bytes;
uint64_t fen_profile_clock_ns(void) {
    return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
}
#endif

void fen_write(const char *s, size_t n) { fwrite(s, 1, n, stdout); }
void fen_write_i64(int64_t n) { fprintf(stdout, "%lld", (long long)n); }
_Noreturn void stream_trap(uintptr_t status) {
    fprintf(stderr, "Fenrir trap %lu\n", (unsigned long)status);
    exit(2);
}
int stream_read(unsigned char *dst, size_t capacity) {
    size_t n = fread(dst, 1, capacity, stdin);
#ifdef FEN_PROFILE_HEAP
    input_bytes += n;
#endif
    return ferror(stdin) ? -1 : (int)n;
}
int stream_write(int diagnostic, const char *src, size_t length) {
    FILE *out = diagnostic ? stderr : stdout;
    return fwrite(src, 1, length, out) == length ? 0 : -1;
}

int main(int argc, char **argv) {
    long capacity = 8192;
    if (argc == 2) {
        char *end;
        capacity = strtol(argv[1], &end, 10);
        if (*end || capacity < 1 || capacity > 65536) return 2;
    } else if (argc != 1) return 2;

    int rc = stream_process((size_t)capacity);
    if (fflush(rc ? stderr : stdout)) return 2;
#ifdef FEN_PROFILE_HEAP
    if (!rc) {
        fprintf(stderr, "{\"bytes\":%" PRIu64 ",\"allocations\":%" PRIu64
                ",\"collections\":%" PRIu64 ",\"collection_ns\":%" PRIu64 "}\n",
                input_bytes, fen_profile_allocations, fen_profile_collections, fen_profile_collection_ns);
    }
#endif
    return rc;
}
