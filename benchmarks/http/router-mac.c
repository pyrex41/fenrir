#include "heap.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
struct outcome { int64_t value; uint64_t status; };
#include "router-loop.h"

int main(int argc, char **argv) {
    if (argc != 2) return 1;
    int rounds = atoi(argv[1]);
    if (rounds <= 0) return 1;
    uint64_t start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    struct outcome result = http_benchmark_entry(rounds);
    uint64_t elapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start;
    if (result.status) return 1;
    printf("%lld %llu\n", result.value, elapsed);
    return 0;
}

void fen_write(const char *p, size_t n) { fwrite(p, 1, n, stderr); }
void fen_write_i64(int64_t n) { fprintf(stderr, "%lld", n); }
