#include "../../runtime/native/scheduler.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif

static fen_scheduler runs[3];
static fen_scheduler *sched = &runs[0];
static fen_fiber tasks[3];
static _Alignas(16) unsigned char stacks[3][16384];
static unsigned trace;
void fen_write(const char *p, size_t n) { (void)p; (void)n; }

static void record(void *arg) {
    unsigned id = *(unsigned *)arg;
    trace = trace * 10 + id;
    if (id == 2) fen_fiber_await(sched, &tasks[0]);
    trace = trace * 10 + id;
}

#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    unsigned ids[] = {1, 2, 3};
    for (unsigned i = 0; i < 3; ++i)
        if (!fen_fiber_start(sched, &tasks[i], stacks[i], sizeof stacks[i],
                             NULL, 0, record, &ids[i])) return 1;
    if (!fen_dispatch_selected(sched, 1)) return 1;
    if (fen_dispatch_selected(sched, 1)) return 1; /* blocked */
    if (!fen_dispatch_selected(sched, 2)) return 1;
    if (fen_dispatch_selected(sched, 2)) return 1; /* terminal */
    while (fen_dispatch(sched)) {}
    if (trace != 233112 || sched->unfinished || sched->last) return 1;
    /* Reusing the terminal fiber's storage must not revive a recorded ID. */
    if (!fen_fiber_start(sched, &tasks[0], stacks[0], sizeof stacks[0],
                         NULL, 0, record, &ids[0])) return 1;
    if (fen_dispatch_selected(sched, 0) || !fen_dispatch_selected(sched, 3)) return 1;
    if (trace != 23311211 || sched->unfinished) return 1;

    uint64_t choices[16];
    size_t count = 0, used;
    unsigned expected = 0;
    for (unsigned replay = 0; replay <= 1; ++replay) {
        sched = &runs[1 + replay];
        trace = 0;
        for (unsigned i = 0; i < 3; ++i)
            if (!fen_fiber_start(sched, &tasks[i], stacks[i], sizeof stacks[i],
                                 NULL, 0, record, &ids[i])) return 1;
        if (!replay) {
            if (fen_record_schedule(sched, choices, 1, &used) != FEN_SCHEDULE_TRUNCATED || used != 1) return 1;
            if (fen_record_schedule(sched, choices + 1, 15, &used) != FEN_SCHEDULE_COMPLETE) return 1;
            count = 1 + used;
            expected = trace;
        } else {
            if (fen_replay_schedule(sched, choices, count - 1, &used) != FEN_SCHEDULE_TRUNCATED ||
                used != count - 1) return 1;
            if (fen_replay_schedule(sched, choices + used, 1, &used) != FEN_SCHEDULE_COMPLETE ||
                used != 1 || trace != expected) return 1;
            if (fen_replay_schedule(sched, choices, 1, &used) != FEN_SCHEDULE_DIVERGED || used) return 1;
        }
    }
    return 0;
}
