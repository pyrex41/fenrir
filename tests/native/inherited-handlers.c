#include "../../runtime/native/task-state.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif

struct fen_outcome { uintptr_t value, status; };
extern struct fen_outcome fen_perform(uintptr_t, uintptr_t, uintptr_t);
extern fen_object *fen_allocate(unsigned, unsigned);
extern void fen_install_handler(fen_handler *, fen_object *, uintptr_t, fen_object **);
extern void fen_restore_handler(fen_handler *);
extern fen_handler *fen_current_handler(void);
void fen_write(const char *p, size_t n) { (void)p; (void)n; }

static struct fen_outcome add(uintptr_t arg, fen_object *closure) {
    return (struct fen_outcome){arg + closure->fields[1], 0};
}

static struct fen_outcome forward(uintptr_t arg, fen_object *closure) {
    return fen_perform(arg + closure->fields[1], 7, 0);
}

static int spawn_child(fen_task_state *child, fen_inherited_handler *storage) {
    fen_handler frames[2];
    fen_object *pending[2];
    for (unsigned i = 0; i < 2; ++i) {
        fen_object *fn = fen_allocate(0, 1);
        fen_object *ops = fen_allocate(1, 2);
        fn->fields[0] = i ? (uintptr_t)forward : (uintptr_t)add;
        fn->fields[1] = i ? 30 : 10;
        ops->fields[0] = (uintptr_t)fn;
        fen_install_handler(&frames[i], ops, 7, &pending[i]);
    }
    if (fen_task_inherit(child, storage, 1) || !fen_task_inherit(child, storage, 2)) return 0;
    fen_restore_handler(NULL);
    return 1;
}

#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    fen_task_state child;
    fen_inherited_handler storage[2];
    if (!spawn_child(&child, storage)) return 1;
    /* Four-slot heap. Only the parked child now retains either closure. */
    if (fen_allocate(0, 3)) return 1;
    fen_task_resume(&child);
    if (fen_current_handler() != &storage[0].handler || storage[0].slots[1] || storage[1].slots[1])
        return 1;
    struct fen_outcome out = fen_perform(2, 7, 0);
    return out.status || out.value != 42;
}
