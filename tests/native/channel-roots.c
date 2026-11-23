#include "../../runtime/native/scheduler.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif
extern fen_object *fen_allocate(unsigned, unsigned);
void fen_write(const char *p, size_t n) { (void)p; (void)n; }
static fen_scheduler sched;
static fen_channel channel;
static fen_object *slot;
static fen_fiber fibers[2];
static _Alignas(16) unsigned char stacks[2][16384];
static int valid;

static void send_one(void *arg) {
    (void)arg;
    fen_object *value = fen_allocate(0, 42);
    if (value) fen_channel_send(&sched, &channel, (uintptr_t)value);
}
static void recv_one(void *arg) {
    (void)arg;
    uintptr_t value;
    valid = fen_channel_receive(&sched, &channel, &value) && ((fen_object *)value)->tag == 42;
}
static void fill_buffer(void *arg) {
    (void)arg;
    fen_channel_send(&sched, &channel, 0);
}

static int cancel_blocked_sender(void) {
    fen_channel_init_objects(&channel, &slot, 1);
    if (!fen_fiber_start(&sched, &fibers[0], stacks[0], sizeof stacks[0], NULL, 0,
                         fill_buffer, NULL)) return 0;
    while (fen_dispatch(&sched)) {}
    if (!fen_fiber_start(&sched, &fibers[1], stacks[1], sizeof stacks[1], NULL, 0,
                         send_one, NULL) || !fen_dispatch(&sched)) return 0;
    if (channel.senders.first != &fibers[1] || fen_allocate(0, 99)) return 0;
    if (!fen_fiber_request_cancel(&fibers[1])) return 0;
    while (fen_dispatch(&sched)) {}
    if (!fibers[1].cancelled || channel.senders.first || sched.unfinished) return 0;
    fen_channel_release_objects(&channel);
    return fen_allocate(0, 99) != NULL;
}
#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    for (unsigned pending = 0; pending < 2; ++pending) {
        valid = 0;
        fen_channel_init_objects(&channel, &slot, 1);
        for (unsigned i = 0; i < 2; ++i) {
            if (!fen_fiber_start(&sched, &fibers[i], stacks[i], sizeof stacks[i], NULL, 0,
                                 i == pending ? send_one : recv_one, NULL)) return 1;
            if (!fen_dispatch(&sched)) return 1;
            if (!pending && !i) {
                if (!fen_dispatch(&sched)) return 1; /* sender finished */
                if (fen_allocate(0, 99)) return 1; /* only the buffer holds the value */
            }
        }
        /* One-slot heap. The buffered or delivered value must survive. */
        if (fen_allocate(0, 99)) return 1;
        while (fen_dispatch(&sched)) {}
        if (!valid || sched.unfinished) return 1;
        fen_channel_release_objects(&channel);
        if (!fen_allocate(0, 99)) return 1;
    }
    return cancel_blocked_sender() ? 0 : 1;
}
