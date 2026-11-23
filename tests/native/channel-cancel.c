#include "../../runtime/native/scheduler.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif

static fen_scheduler scheduler;
static uintptr_t slot;
static fen_channel channel;
static fen_fiber receiver, sender;
static _Alignas(16) unsigned char receiver_stack[16384], sender_stack[16384];
static int returned_from_receive, sent;
void fen_write(const char *p, size_t n) { (void)p; (void)n; }

static void receive_value(void *unused) {
    (void)unused;
    uintptr_t value;
    fen_channel_receive(&scheduler, &channel, &value);
    returned_from_receive = 1;
}

static void send_value(void *unused) {
    (void)unused;
    sent = fen_channel_send(&scheduler, &channel, 5);
}

static int scenario(int commit_first) {
    channel = (fen_channel){.slots=&slot, .capacity=1};
    sent = returned_from_receive = 0;
    if (!fen_fiber_start(&scheduler, &receiver, receiver_stack, sizeof receiver_stack,
                         NULL, 0, receive_value, NULL) || !fen_dispatch(&scheduler)) return 0;
    if (channel.receivers.first != &receiver || scheduler.first) return 0;
    if (!fen_fiber_start(&scheduler, &sender, sender_stack, sizeof sender_stack,
                         NULL, 0, send_value, NULL)) return 0;
    if (commit_first) {
        if (!fen_dispatch(&scheduler) || channel.receivers.first || channel.count ||
            receiver.channel_value != 5 || receiver.waiting_on) return 0;
    }
    if (!fen_fiber_request_cancel(&receiver) || channel.receivers.first) return 0;
    unsigned steps = 0;
    while (fen_dispatch(&scheduler)) if (++steps > 4) return 0;
    if (!sent || returned_from_receive || !receiver.cancelled || scheduler.unfinished) return 0;
    return commit_first ? channel.count == 0 : channel.count == 1 && slot == 5;
}

#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    return scenario(0) && scenario(1) ? 0 : 1;
}
