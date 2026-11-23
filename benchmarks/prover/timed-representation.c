#include <solo5.h>
#include <stdint.h>
#include <stddef.h>

struct outcome { int64_t value; uint64_t status; };
extern struct outcome fenrir_entry(int64_t argument);
extern void representation_prepare(void);
void fen_write(const char *s, size_t n) { solo5_console_write(s, n); }
void fen_write_i64(int64_t value) {
    char digits[20];
    unsigned start = sizeof digits;
    uint64_t magnitude = value < 0 ? 0 - (uint64_t)value : (uint64_t)value;
    do { digits[--start] = '0' + magnitude % 10; magnitude /= 10; } while (magnitude);
    if (value < 0) digits[--start] = '-';
    fen_write(digits + start, sizeof digits - start);
}
int solo5_app_main(const struct solo5_start_info *info) {
    int64_t rounds = 0;
    for (const char *p = info->cmdline; *p; ++p) {
        if (*p < '0' || *p > '9' || rounds > 100000) return SOLO5_EXIT_FAILURE;
        rounds = rounds * 10 + *p - '0';
    }
    representation_prepare();
    uint64_t start = solo5_clock_monotonic();
    struct outcome result = fenrir_entry(rounds);
    uint64_t elapsed = solo5_clock_monotonic() - start;
    fen_write_i64(result.value); fen_write(" ", 1); fen_write_i64((int64_t)elapsed); fen_write("\n", 1);
    return result.status ? SOLO5_EXIT_FAILURE : SOLO5_EXIT_SUCCESS;
}
