#include "../../runtime/native/scheduler.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif

static fen_scheduler runs[2];
static fen_scheduler *scheduler;
static fen_fiber tasks[4];
static _Alignas(16) unsigned char stacks[4][16384];
static int failed;
static unsigned trace;
static int64_t delays[] = {5, 5, 3, 8};
void fen_write(const char *p, size_t n) { (void)p; (void)n; }

static void sleeper(void *arg) {
    int64_t delay = *(int64_t *)arg;
    if (scheduler->now_ns || fen_fiber_sleep(scheduler, -1) != FEN_SLEEP_INVALID_DURATION) failed = 1;
    if (fen_fiber_sleep(scheduler, delay) != FEN_SLEEP_OK || scheduler->now_ns != delay) failed = 1;
    trace = trace * 10 + (unsigned)scheduler->running->id + 1;
    if (fen_fiber_sleep(scheduler, INT64_MAX) != FEN_SLEEP_OVERFLOW) failed = 1;
    if (fen_fiber_sleep(scheduler, 0) != FEN_SLEEP_OK || scheduler->now_ns != delay) failed = 1;
}

static int exercise(int replay, uint64_t *choices, size_t *count) {
    scheduler = &runs[replay];
    trace = 0;
    for (size_t i = 0; i < 4; i++)
        if (!fen_fiber_start(scheduler, &tasks[i], stacks[i], sizeof stacks[i],
                             NULL, 0, sleeper, &delays[i])) return 1;
    /* Register equal deadlines in reverse ID order. Cancel the last timer. */
    for (int i = 3; i >= 0; --i)
        if (!fen_dispatch_selected(scheduler, (uint64_t)i)) return 1;
    if (scheduler->now_ns || !fen_fiber_request_cancel(&tasks[3])) return 1;
    size_t used;
    fen_schedule_result result = replay
        ? fen_replay_schedule(scheduler, choices, *count, &used)
        : fen_record_schedule(scheduler, choices, 16, &used);
    if (replay && used != *count) return 1;
    *count = used;
    return failed || result != FEN_SCHEDULE_COMPLETE || trace != 312 ||
           scheduler->now_ns != 5 || !tasks[3].cancelled || scheduler->timers.first;
}

#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    uint64_t choices[16];
    size_t count = 0;
    return exercise(0, choices, &count) || exercise(1, choices, &count);
}
