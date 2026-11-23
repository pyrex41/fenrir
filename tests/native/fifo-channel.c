#include "../../runtime/native/scheduler.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif
static fen_scheduler scheduler;
static uintptr_t slot;
static fen_channel channel = {.slots=&slot, .capacity=1};
static fen_fiber fibers[2];
static _Alignas(16) unsigned char stacks[2][16384];
static int good = 1;
void fen_write(const char *p, size_t n) { (void)p; (void)n; }

static void producer(void *unused) {
    (void)unused;
    for (unsigned i = 1; i <= 3; ++i)
        if (!fen_channel_send(&scheduler, &channel, i)) good = 0;
    if (fen_channel_send(&scheduler, &channel, 4)) good = 0;
}
static void consumer(void *unused) {
    (void)unused;
    uintptr_t v = 0;
    fen_fiber_yield(&scheduler);
    for (unsigned i = 1; i <= 2; ++i)
        if (!fen_channel_receive(&scheduler, &channel, &v) || v != i) good = 0;
    fen_fiber_yield(&scheduler);
    fen_channel_close(&scheduler, &channel);
    if (!fen_channel_receive(&scheduler, &channel, &v) || v != 3) good = 0;
    if (fen_channel_receive(&scheduler, &channel, &v)) good = 0;
}
#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    for (unsigned i = 0; i < 2; ++i)
        if (!fen_fiber_start(&scheduler, &fibers[i], stacks[i], sizeof stacks[i],
                             NULL, 0, i ? consumer : producer, NULL)) return 1;
    unsigned steps = 0;
    while (fen_dispatch(&scheduler)) if (++steps > 32) return 1;
    return good && !scheduler.unfinished && !channel.count ? 0 : 1;
}
