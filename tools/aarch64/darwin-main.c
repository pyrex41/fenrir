#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct outcome { int64_t value; uint64_t status; };
extern struct outcome fenrir_entry(int64_t argument);

extern const char *fen_trap_location;
extern const char *fen_schedule_request;
extern void fen_print_result(uintptr_t value);
void fen_write(const char *s, size_t n) { fwrite(s, 1, n, stdout); }
void fen_write_i64(int64_t n) { printf("%" PRId64, n); }

extern uint64_t (*fen_host_clock)(void);
extern void (*fen_host_wait)(uint64_t);
static uint64_t monotonic_ns(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }
static void wait_ns(uint64_t ns) {
    struct timespec delay = {ns / 1000000000, ns % 1000000000};
    nanosleep(&delay, NULL);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fputs("expected one signed I64 argument\n", stderr);
        return 2;
    }
    // The Solo5 entry point and the CLI accept decimal digits with an optional minus.
    const char *digits = argv[1] + (argv[1][0] == '-');
    if (*digits < '0' || *digits > '9') return 2;
    char *end;
    errno = 0;
    int64_t input = strtoimax(argv[1], &end, 10);
    if (errno || end == argv[1]) return 2;
    if (*end == '@') fen_schedule_request = end + 1;
    else if (strcmp(end, "!live") == 0) {
        fen_host_clock = monotonic_ns;
        fen_host_wait = wait_ns;
    } else if (*end) return 2;
    struct outcome result = fenrir_entry(input);
    if (result.status == 11) return 2; /* schedule rejected */
    if (result.status == 10) return 1; /* scheduler printed the wait graph */
    if (result.status) {
        fflush(stdout);
        fprintf(stderr, "trap: %s\n", result.status == 1 ? "Overflow" :
                result.status == 2 ? "DivZero" :
                result.status == 3 ? "HeapExhausted" : result.status == 4 ? "Bounds" :
                result.status == 5 ? "ChildFailed" : result.status == 7 ? "TaskLimit" :
                result.status == 9 ? "InvalidDuration" : "invalid native status");
        if (fen_trap_location) fputs(fen_trap_location, stderr);
        return 1;
    }
    fen_print_result((uintptr_t)result.value);
    putchar('\n');
    return 0;
}
