#include "../../runtime/native/context.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#endif

static fen_context parent, child;
static _Alignas(16) unsigned char child_stack[16384];
static unsigned phase;

static uint64_t rounding(void) {
    uint64_t control;
    __asm__ volatile("mrs %0, fpcr" : "=r"(control));
    return control;
}

static void worker(void *argument) {
    uint64_t mode = rounding() ^ (UINT64_C(1) << 22);
    __asm__ volatile("msr fpcr, %0" :: "r"(mode));
    volatile unsigned local = *(unsigned *)argument;
    if ((uintptr_t)&local >= (uintptr_t)child_stack &&
        (uintptr_t)&local < (uintptr_t)(child_stack + sizeof child_stack)) phase = local;
    fen_context_switch(&child, &parent);
    if (rounding() == mode) phase += local;
    fen_context_switch(&child, &parent);
}

#ifdef FENRIR_SOLO5_TEST
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
int main(void) {
#endif
    unsigned seed = 7;
    uint64_t initial = rounding();
    fen_context_init(&child, child_stack, sizeof child_stack, worker, &seed);
    fen_context_switch(&parent, &child);
    if (phase != 7 || rounding() != initial) return 1;
    seed = 99;
    fen_context_switch(&parent, &child);
    return phase == 14 && rounding() == initial ? 0 : 1;
}
