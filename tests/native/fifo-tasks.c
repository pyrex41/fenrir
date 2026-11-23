#include "../../runtime/native/scheduler.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif

static fen_scheduler scheduler;
static fen_fiber fibers[2];
static _Alignas(16) unsigned char stacks[2][16384];
static unsigned trace;
void fen_write(const char *p, size_t n) { (void)p; (void)n; }

static void task(void *arg) {
    unsigned id = *(unsigned *)arg;
    trace = trace * 10 + id;
    fen_fiber_yield(&scheduler);
    trace = trace * 10 + id;
}
#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    unsigned ids[] = {1, 2};
    for (unsigned i = 0; i < 2; ++i)
        if (!fen_fiber_start(&scheduler, &fibers[i], stacks[i], sizeof stacks[i],
                             NULL, 0, task, &ids[i])) return 1;
    if (trace) return 1;
    unsigned steps = 0;
    while (fen_dispatch(&scheduler)) if (++steps > 4) return 1;
    return steps == 4 && trace == 1212 && fibers[0].finished && fibers[1].finished ? 0 : 1;
}
