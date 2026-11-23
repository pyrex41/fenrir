#include <solo5.h>

struct outcome { int64_t value; uint64_t status; };
extern struct outcome fenrir_entry(int64_t argument);

extern const char *fen_trap_location;
extern const char *fen_schedule_request;
extern void fen_print_result(uintptr_t value);
void fen_write(const char *s, size_t n) { solo5_console_write(s, n); }
void fen_write_i64(int64_t value) {
    char digits[22];
    unsigned start = sizeof digits;
    uint64_t magnitude = (uint64_t)value;
    if (value < 0) magnitude = 0 - magnitude;
    do {
        digits[--start] = '0' + magnitude % 10;
        magnitude /= 10;
    } while (magnitude);
    if (value < 0) digits[--start] = '-';
    solo5_console_write(digits + start, sizeof digits - start);
}

extern uint64_t (*fen_host_clock)(void);
extern void (*fen_host_wait)(uint64_t);
static void wait_ns(uint64_t ns) {
    uint64_t now = solo5_clock_monotonic();
    solo5_yield(ns > UINT64_MAX - now ? UINT64_MAX : now + ns, 0);
}

int solo5_app_main(const struct solo5_start_info *info) {
    const char *p = info->cmdline;
    int negative = *p == '-';
    if (negative) ++p;
    uint64_t limit = (uint64_t)INT64_MAX + negative, magnitude = 0;
    if (*p < '0' || *p > '9') return SOLO5_EXIT_FAILURE;
    while (*p >= '0' && *p <= '9') {
        unsigned digit = (unsigned)(*p++ - '0');
        if (digit > 9 || magnitude > (limit - digit) / 10)
            return SOLO5_EXIT_FAILURE;
        magnitude = magnitude * 10 + digit;
    }
    if (*p == '@') fen_schedule_request = p + 1;
    else if (*p == '!') {
        const char *suffix = "!live";
        while (*suffix && *p == *suffix) { ++p; ++suffix; }
        if (*suffix || *p) return SOLO5_EXIT_FAILURE;
        fen_host_clock = solo5_clock_monotonic;
        fen_host_wait = wait_ns;
    } else if (*p) return SOLO5_EXIT_FAILURE;
    int64_t input = negative && magnitude ? -(int64_t)(magnitude - 1) - 1 : (int64_t)magnitude;
    struct outcome result = fenrir_entry(input);
    if (result.status == 11) return SOLO5_EXIT_FAILURE; /* schedule rejected */
    if (result.status == 10) return SOLO5_EXIT_FAILURE; /* scheduler printed the wait graph */
    if (result.status) {
        if (result.status == 1) solo5_console_write("trap: Overflow\n", 15);
        if (result.status == 2) solo5_console_write("trap: DivZero\n", 14);
        if (result.status == 4) solo5_console_write("trap: Bounds\n", 13);
        if (result.status == 9) solo5_console_write("trap: InvalidDuration\n", sizeof("trap: InvalidDuration\n") - 1);
        if (result.status == 7) solo5_console_write("trap: TaskLimit\n", 16);
        if (result.status == 5) solo5_console_write("trap: ChildFailed\n", 18);
        if (result.status == 3) solo5_console_write("trap: HeapExhausted\n", 20);
        if (fen_trap_location) {
            size_t n = 0;
            while (fen_trap_location[n]) ++n;
            solo5_console_write(fen_trap_location, n);
        }
        return SOLO5_EXIT_FAILURE;
    }
    fen_print_result((uintptr_t)result.value);
    solo5_console_write("\n", 1);
    return SOLO5_EXIT_SUCCESS;
}
