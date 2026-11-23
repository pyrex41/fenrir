#include "../../runtime/native/scheduler.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif
static fen_scheduler sched;
static fen_fiber tasks[4];
static _Alignas(16) unsigned char stacks[4][16384];
static unsigned trace;
void fen_write(const char *p, size_t n) { (void)p; (void)n; }

static void waiter(void *arg) {
    fen_fiber_await(&sched, &tasks[2]);
    trace = trace * 10 + *(unsigned *)arg;
}
static void cancel_first(void *unused) {
    (void)unused;
    fen_fiber_cancel(&sched, &tasks[0]);
    trace = 3;
}

#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    unsigned ids[] = {1,2,3,4};
    for (unsigned i = 0; i < 4; ++i)
        if (!fen_fiber_start(&sched, &tasks[i], stacks[i], sizeof stacks[i], NULL, 0,
                             i == 2 ? cancel_first : waiter, &ids[i])) return 1;
    if (!fen_fiber_request_cancel(&tasks[3]) || fen_fiber_request_cancel(&tasks[3])) return 1;
    unsigned steps = 0;
    while (fen_dispatch(&sched)) if (++steps > 10) return 1;
    return trace == 32 && sched.unfinished == 0 && tasks[0].cancelled &&
           tasks[3].cancelled && !tasks[1].cancelled && !fen_fiber_request_cancel(&tasks[2]) ? 0 : 1;
}
