#include "../../runtime/native/context.h"
#include "../../runtime/native/task-state.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif

struct fen_outcome { uintptr_t value, status; };
extern struct fen_outcome fen_perform(uintptr_t, uintptr_t, uintptr_t);
extern unsigned fen_use_resumption(unsigned);
extern void fen_install_handler(fen_handler *, fen_object *, uintptr_t, fen_object **);
extern fen_handler *fen_current_handler(void);
extern const char *fen_trap_location;
extern void fen_set_location(const char *);
void fen_write(const char *p, size_t n) { (void)p; (void)n; }

static fen_context parent, child;
static fen_task_state parent_state, child_state;
static _Alignas(16) unsigned char stack[16384];
static const char parent_site[] = "parent", child_site[] = "child";
static int valid;

static struct fen_outcome clause(uintptr_t arg, fen_object *self) {
    (void)self;
    fen_task_park(&parent_state);
    fen_context_switch(&parent, &child);
    if (fen_trap_location != parent_site || !fen_use_resumption(1) || fen_use_resumption(1))
        return (struct fen_outcome){0, 6};
    return (struct fen_outcome){arg + 1, 0};
}

static void worker(void *unused) {
    (void)unused;
    valid = !fen_current_handler() && !fen_trap_location && !fen_use_resumption(1);
    fen_set_location(child_site);
    fen_task_park(&child_state);
    fen_task_resume(&parent_state);
    fen_context_switch(&child, &parent);
    valid = valid && fen_trap_location == child_site && !fen_use_resumption(1);
    fen_task_resume(&parent_state);
    fen_context_switch(&child, &parent);
}

#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    fen_object fn = {.fields={(uintptr_t)clause}, .live=FEN_IMAGE_OBJECT};
    fen_object clauses = {.fields={(uintptr_t)&fn}, .live=FEN_IMAGE_OBJECT};
    fen_handler frame;
    fen_object *pending;
    fen_context_init(&child, stack, sizeof stack, worker, NULL);
    fen_set_location(parent_site);
    fen_install_handler(&frame, &clauses, 1, &pending);
    struct fen_outcome out = fen_perform(41, 1, 0);
    if (out.status || out.value != 42 || fen_current_handler() != &frame) return 1;
    fen_task_park(&parent_state);
    fen_task_resume(&child_state);
    fen_context_switch(&parent, &child);
    return valid && fen_current_handler() == &frame && fen_trap_location == parent_site ? 0 : 1;
}
