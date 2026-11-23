#ifndef FENRIR_NATIVE_CONTEXT_H
#define FENRIR_NATIVE_CONTEXT_H

#include <stddef.h>
#include <stdint.h>

/* One synchronous AArch64 call boundary. A suspended context and its stack
 * must stay at fixed addresses until it resumes or the task is reclaimed. */
typedef struct {
    uintptr_t saved[12]; /* x19..x30 */
    uintptr_t sp;
    uint64_t d[8];       /* low 64 bits of v8..v15 */
    uint64_t fpcr, fpsr;
} fen_context;

_Static_assert(offsetof(fen_context, sp) == 96 && offsetof(fen_context, d) == 104 &&
               offsetof(fen_context, fpcr) == 168 && offsetof(fen_context, fpsr) == 176,
               "context layout must match context.S");

void fen_context_start(void);
void fen_context_switch(fen_context *from, const fen_context *to);

/* Caller supplies a nonempty, adequately sized stack and an entry function
 * that transfers control back to the scheduler when the task finishes. */
static inline void fen_context_init(fen_context *ctx, void *stack, size_t size,
                                    void (*entry)(void *), void *argument) {
    *ctx = (fen_context){0};
    ctx->sp = ((uintptr_t)stack + size) & ~(uintptr_t)15;
    ctx->saved[0] = (uintptr_t)argument;
    ctx->saved[1] = (uintptr_t)entry;
    ctx->saved[11] = (uintptr_t)fen_context_start;
    __asm__ volatile("mrs %0, fpcr" : "=r"(ctx->fpcr));
    __asm__ volatile("mrs %0, fpsr" : "=r"(ctx->fpsr));
}
#endif
