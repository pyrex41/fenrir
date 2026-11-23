#include "../../runtime/native/context.h"
#include "../../runtime/native/heap.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif

extern void fen_enter(fen_roots *, fen_object **, size_t);
extern void fen_leave(void);
extern fen_object *fen_allocate(unsigned mask, unsigned tag);
void fen_write(const char *p, size_t n) { (void)p; (void)n; }

static fen_context parent, child;
static fen_parked_roots parent_roots, child_roots;
static _Alignas(16) unsigned char stack[16384];
static int valid;

static void worker(void *unused) {
    (void)unused;
    fen_object *pair = fen_allocate(1, 20);
    fen_roots frame;
    fen_enter(&frame, &pair, 1);
    pair->fields[0] = (uintptr_t)fen_allocate(0, 21);
    fen_park_roots(&child_roots);
    fen_resume_roots(&parent_roots);
    fen_context_switch(&child, &parent);
    valid = pair->tag == 20 && ((fen_object *)pair->fields[0])->tag == 21;
    fen_leave();
    fen_resume_roots(&parent_roots);
    fen_context_switch(&child, &parent);
}

#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    fen_object *pinned = fen_allocate(0, 10);
    fen_roots frame;
    fen_enter(&frame, &pinned, 1);
    fen_context_init(&child, stack, sizeof stack, worker, NULL);
    fen_park_roots(&parent_roots);
    fen_context_switch(&parent, &child);
    /* All three heap slots are live across the two stacks. */
    if (fen_allocate(0, 30) || pinned->tag != 10) return 1;
    fen_park_roots(&parent_roots);
    fen_resume_roots(&child_roots);
    fen_context_switch(&parent, &child);
    if (!valid || !fen_allocate(0, 30) || pinned->tag != 10) return 1;
    fen_leave();
    return 0;
}
