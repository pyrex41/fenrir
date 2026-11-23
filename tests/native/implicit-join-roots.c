#include "../../runtime/native/task-entry.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif

extern fen_object *fen_allocate(unsigned, unsigned);
static fen_fiber child;
static _Alignas(16) unsigned char stack[16384];
static int retained;
static const char root_location[] = "test root";
static const char body_location[] = "test body";
extern const char *fen_trap_location;
void fen_write(const char *p, size_t n) { (void)p; (void)n; }
const char *fenrir_task_root_location(void) { return root_location; }
int fenrir_task_result_is_object(void) { return 1; }

static void collect(void *arg) {
    if (arg) fen_fiber_fail(child.scheduler, 2);
    /* With one heap slot a collection can only succeed by reclaiming the
     * parent's result. The child's TaskStart yields before this allocation. */
    retained = fen_allocate(0, 88) == NULL;
}

fen_result fenrir_task_entry(int64_t input) {
    if (!fen_spawn_current(&child, stack, sizeof stack, NULL, 0, collect, input ? &child : NULL))
        return (fen_result){0, 3};
    if (input == 2) {
        fen_trap_location = body_location;
        return (fen_result){0, 1};
    }
    return (fen_result){(uintptr_t)fen_allocate(0, 47), 0};
}

#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    fen_result result = fenrir_entry(0);
    if (result.status || !result.value || !retained || !child.finished ||
        ((fen_object *)result.value)->tag != 47) return 1;
    result = fenrir_entry(1);
    if (result.status != 5 || fen_trap_location != root_location) return 1;
    result = fenrir_entry(2);
    return result.status != 1 || fen_trap_location != body_location || !child.finished;
}
