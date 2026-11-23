#include "../../runtime/native/scheduler.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif

static fen_scheduler sched;
static fen_scope scope;
static fen_fiber parent, children[2];
static _Alignas(16) unsigned char stacks[3][16384];
static int joined, escaped, fail_child;
void fen_write(const char *p, size_t n) { (void)p; (void)n; }

static void wait_for_parent(void *arg) {
    if (arg && fail_child) fen_fiber_fail(&sched, 2);
    fen_fiber_await(&sched, &parent);
    escaped = 1;
}

static void abort_body(void *arg) {
    (void)arg;
    for (size_t i = 0; i < 2; ++i)
        if (!fen_fiber_spawn(&sched, &scope, &children[i], stacks[i+1], sizeof stacks[i+1],
                             NULL, 0, wait_for_parent, i ? &scope : NULL)) return;
    if (fail_child) {
        if (!scope.failed || fen_fiber_spawn(&sched, &scope, &children[1], stacks[2], sizeof stacks[2],
                                               NULL, 0, wait_for_parent, NULL)) return;
        fen_scope_join(&sched, &scope);
        joined = children[0].cancelled && children[1].trap_code == 2;
        return;
    }
    fen_scope_abort(&sched, &scope);
    joined = children[0].cancelled && children[1].cancelled;
}

#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    if (!fen_fiber_start(&sched, &parent, stacks[0], sizeof stacks[0], NULL, 0, abort_body, NULL)) return 1;
    for (unsigned i = 0; i < 2; ++i) {
        if (!fen_dispatch_selected(&sched, parent.id)) return 1;
        for (unsigned j = 0; j < 2; ++j)
            if (!fen_dispatch_selected(&sched, children[i].id)) return 1;
        if (children[i].waiting_on != &parent.waiters) return 1;
    }
    if (!fen_dispatch_selected(&sched, parent.id) || parent.waiters.first ||
        sched.first != &children[0] || children[0].next != &children[1]) return 1;
    while (fen_dispatch(&sched)) {}
    if (!joined || escaped || sched.unfinished || scope.first_child || scope.last_child || scope.failed) return 1;
    fail_child = 1;
    joined = 0;
    if (!fen_fiber_start(&sched, &parent, stacks[0], sizeof stacks[0], NULL, 0, abort_body, NULL)) return 1;
    for (size_t i = 0; i < 2; ++i) {
        if (!fen_dispatch_selected(&sched, parent.id)) return 1;
        for (size_t j = 0; j < 2; ++j)
            if (!fen_dispatch_selected(&sched, children[i].id)) return 1;
    }
    while (fen_dispatch(&sched)) {}
    return joined && !escaped && !sched.unfinished && !parent.cancelled && sched.next_task == 6 ? 0 : 1;
}
