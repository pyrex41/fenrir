#include "stream-io.h"
#include <solo5.h>

static solo5_handle_t disk;
static size_t sector;
static uint64_t remaining, position, read_ns, write_ns, first_write_end;
static int profile_io;
#ifdef FEN_PROFILE_HEAP
uint64_t fen_profile_clock_ns(void) { return solo5_clock_monotonic(); }
#endif

int stream_read(unsigned char *dst, size_t capacity) {
    size_t n = remaining < capacity ? (size_t)remaining : capacity;
    uint64_t start = profile_io ? solo5_clock_monotonic() : 0;
    for (size_t i = 0; i < n; i += sector) {
        if (solo5_block_read(disk, position, dst + i, sector) != SOLO5_R_OK) return -1;
        position += sector;
    }
    if (profile_io) read_ns += solo5_clock_monotonic() - start;
    remaining -= n;
    return (int)n;
}
int stream_write(int diagnostic, const char *src, size_t length) {
    uint64_t start = profile_io ? solo5_clock_monotonic() : 0;
    solo5_console_write(src, length);
    if (profile_io) {
        uint64_t end = solo5_clock_monotonic();
        write_ns += end - start;
        if (!diagnostic && length && !first_write_end) first_write_end = end;
    }
    return 0;
}
void fen_write(const char *s, size_t n) { solo5_console_write(s, n); }
void fen_write_i64(int64_t n) {
    char digits[21];
    size_t i = sizeof digits;
    uint64_t value = n < 0 ? 0 - (uint64_t)n : (uint64_t)n;
    do { digits[--i] = '0' + value % 10; value /= 10; } while (value);
    if (n < 0) digits[--i] = '-';
    fen_write(digits+i, sizeof digits-i);
}
_Noreturn void stream_trap(uintptr_t status) {
    fen_write("Fenrir trap ", 12);
    fen_write_i64((int64_t)status);
    fen_write("\n", 1);
    solo5_exit(2);
}

int solo5_app_main(const struct solo5_start_info *info) {
    struct solo5_block_info block;
    if (solo5_block_acquire("input", &disk, &block) != SOLO5_R_OK) return 2;
    sector = block.block_size;
    if (!sector || 8192 % sector) return 2;
    const char *p = info->cmdline;
    profile_io = *p == 'p';
    int timed = *p == 't' || profile_io;
    if (timed) ++p;
    if (!*p) return 2;
    while (*p) {
        unsigned digit = (unsigned)(*p++ - '0');
        if (digit > 9 || remaining > ((uint64_t)INT64_MAX - digit) / 10) return 2;
        remaining = remaining * 10 + digit;
    }
    if (remaining > block.capacity) return 2;
    uint64_t start = timed ? solo5_clock_monotonic() : 0;
    int status = stream_process(8192);
    if (timed && !status) {
        uint64_t elapsed = solo5_clock_monotonic() - start;
        if (profile_io) {
#ifdef FEN_PROFILE_HEAP
            extern uint64_t fen_profile_allocations, fen_profile_collections, fen_profile_collection_ns;
            fen_write("allocations ", 12);
            fen_write_i64((int64_t)fen_profile_allocations);
            fen_write("\ncollections ", 13);
            fen_write_i64((int64_t)fen_profile_collections);
            fen_write("\ncollection_ns ", 15);
            fen_write_i64((int64_t)fen_profile_collection_ns);
            fen_write("\n", 1);
#endif
            fen_write("read_ns ", 8);
            fen_write_i64((int64_t)read_ns);
            fen_write("\nwrite_ns ", 10);
            fen_write_i64((int64_t)write_ns);
            fen_write("\nfirst_output_ns ", 17);
            fen_write_i64(first_write_end ? (int64_t)(first_write_end - start) : -1);
            fen_write("\n", 1);
        }
        fen_write("elapsed_ns ", 11);
        fen_write_i64((int64_t)elapsed);
        fen_write("\n", 1);
    }
    return status;
}
