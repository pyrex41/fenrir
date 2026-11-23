#include "../../runtime/native/scheduler.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif

/* An injected monotonic clock makes early host wakeups and time spent in a
 * runnable sibling reproducible on both targets. */
static fen_scheduler scheduler;
static fen_fiber tasks[2];
static _Alignas(16) unsigned char stacks[2][16384];
static uint64_t ticks = 100, waits;
static int failed, resumed;
void fen_write(const char *p, size_t n) { (void)p; (void)n; }
static uint64_t read_clock(void) { return ticks; }

static void wait_clock(uint64_t remaining) {
    if (++waits > 2 || remaining != (waits == 1 ? 10u : 7u)) failed = 1;
    ticks += waits == 1 ? 3 : remaining;
}

static void sleeper(void *arg) {
    (void)arg;
    if (fen_fiber_sleep(&scheduler, 5) != FEN_SLEEP_OK || fen_scheduler_now(&scheduler) != 5)
        failed = 1;
    resumed = 1;
    if (fen_fiber_sleep(&scheduler, 10) != FEN_SLEEP_OK || fen_scheduler_now(&scheduler) != 15)
        failed = 1;
}

static void busy(void *arg) {
    (void)arg;
    ticks += 5;
    /* The ready queue still has work when the first timer becomes due. */
    for (unsigned i = 0; i < 3 && !resumed; ++i) fen_fiber_yield(&scheduler);
    if (!resumed || waits) failed = 1;
}

#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    scheduler.clock_origin = ticks;
    scheduler.read_clock = read_clock;
    scheduler.wait_ns = wait_clock;
    for (unsigned i = 0; i < 2; ++i)
        if (!fen_fiber_start(&scheduler, &tasks[i], stacks[i], sizeof stacks[i],
                             NULL, 0, i ? busy : sleeper, NULL)) return 1;
    while (fen_dispatch(&scheduler)) {}
    return failed || waits != 2 || scheduler.unfinished;
}
