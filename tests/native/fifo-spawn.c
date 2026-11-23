#include "../../runtime/native/scheduler.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif
static fen_scheduler sched;
static fen_fiber parent, child, sibling;
static fen_scope scope;
static _Alignas(16) unsigned char stacks[3][16384];
static unsigned trace;
void fen_write(const char *p, size_t n) { (void)p; (void)n; }

static void child_body(void *arg) {
    (void)arg;
    trace = trace * 10 + 3;
}
static void parent_body(void *arg) {
    (void)arg;
    trace = 1;
    if (!fen_fiber_spawn(&sched, &scope, &child, stacks[1], sizeof stacks[1], NULL, 0, child_body, NULL)) return;
    trace = trace * 10 + 2;
    if (!fen_fiber_spawn(&sched, &scope, &sibling, stacks[2], sizeof stacks[2], NULL, 0, child_body, NULL)) return;
    fen_scope_join(&sched, &scope);
    trace = trace * 10 + 4;
}
#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    if (!fen_fiber_start(&sched, &parent, stacks[0], sizeof stacks[0], NULL, 0, parent_body, NULL)) return 1;
    if (!fen_dispatch(&sched) || trace != 1 || sched.first != &child) return 1;
    if (!fen_dispatch(&sched) || trace != 1 || sched.first != &parent) return 1;
    if (!fen_dispatch_selected(&sched, parent.id) || scope.unfinished != 2) return 1;
    if (!fen_dispatch_selected(&sched, parent.id) || scope.joiner.first != &parent) return 1;
    if (!fen_dispatch_selected(&sched, child.id) || scope.joiner.first != &parent) return 1;
    if (fen_dispatch_selected(&sched, parent.id)) return 1;
    while (fen_dispatch(&sched)) {}
    return !sched.unfinished && !scope.unfinished && trace == 12334 ? 0 : 1;
}
