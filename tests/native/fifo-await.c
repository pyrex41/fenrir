#include "../../runtime/native/scheduler.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif

static fen_scheduler scheduler;
static fen_fiber tasks[3];
static _Alignas(16) unsigned char stacks[3][16384];
static unsigned trace;
void fen_write(const char *p, size_t n) { (void)p; (void)n; }

static void waiter(void *arg) {
    unsigned id = *(unsigned *)arg;
    fen_fiber_await(&scheduler, &tasks[2]);
    trace = trace * 10 + id;
    fen_fiber_await(&scheduler, &tasks[2]);
    trace = trace * 10 + id;
}

static void finish(void *arg) {
    (void)arg;
    trace = 3;
}

static void self_wait(void *arg) {
    fen_fiber_await(&scheduler, arg);
    trace = 0;
}

#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    unsigned ids[] = {1, 2, 3};
    for (unsigned i = 0; i < 3; ++i)
        if (!fen_fiber_start(&scheduler, &tasks[i], stacks[i], sizeof stacks[i],
                             NULL, 0, i == 2 ? finish : waiter, &ids[i])) return 1;
    unsigned steps = 0;
    while (fen_dispatch(&scheduler)) if (++steps > 9) return 1;
    if (steps != 9 || trace != 31212 || scheduler.unfinished) return 1;
    if (!fen_fiber_start(&scheduler, &tasks[0], stacks[0], sizeof stacks[0],
                         NULL, 0, self_wait, &tasks[0])) return 1;
    if (!fen_dispatch(&scheduler) || fen_dispatch(&scheduler)) return 1;
    return scheduler.unfinished == 1 && !tasks[0].finished && trace == 31212 ? 0 : 1;
}
