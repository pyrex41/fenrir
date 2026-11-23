#include "../../runtime/native/scheduler.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif

static fen_scheduler scheduler;
static fen_fiber parent, children[2];
static _Alignas(16) unsigned char stacks[3][16384];
static int escaped;
void fen_write(const char *p, size_t n) { (void)p; (void)n; }

static void child(void *arg) {
    (void)arg;
    fen_fiber_await(&scheduler, &parent);
    escaped = 1;
}

static void run(void *arg) {
    (void)arg;
    fen_scope outer = {0}, inner = {.outer = &outer};
    fen_scope *scopes[] = {&outer, &inner};
    for (size_t i = 0; i < 2; ++i) {
        parent.active_scope = scopes[i];
        if (!fen_fiber_spawn(&scheduler, scopes[i], &children[i], stacks[i+1],
                             sizeof stacks[i+1], NULL, 0, child, NULL)) return;
    }
    fen_scope_join(&scheduler, &inner);
    escaped = 1;
}

#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    if (!fen_fiber_start(&scheduler, &parent, stacks[0], sizeof stacks[0], NULL, 0, run, NULL)) return 1;
    while (fen_dispatch(&scheduler)) {}
    if (!parent.waiting_on || !children[0].waiting_on || !children[1].waiting_on) return 1;
    if (!fen_fiber_request_cancel(&parent)) return 1;
    while (fen_dispatch(&scheduler)) {
        if (parent.finished && (!children[0].finished || !children[1].finished)) return 1;
    }
    return escaped || scheduler.unfinished || !parent.cancelled || !children[0].cancelled || !children[1].cancelled;
}
