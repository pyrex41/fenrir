/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * TC1-C1 task layer for the pure-call guest (spec/tc1/CONCURRENCY.md): structured
 * tasks and bounded channels over the handler machine of machine.c, one local machine
 * per task. The schedule is an input: tk_step runs one step of the task it is given, or,
 * in FIFO mode, of the task the FIFO production policy chooses. Written from the
 * contract, not from the Shen model or the JavaScript implementation. UNQUALIFIED. */
#ifndef FENRIR_TK_TASKS_H
#define FENRIR_TK_TASKS_H
#include "machine.h"
/* Injected defects (spec/solo5/pure-call-control-v3.md section 4); TK_NORMAL by default. */
enum tk_defect { TK_NORMAL,TK_FIFO_REVERSED,TK_CANCEL_OFF_POINT,TK_LOST_WAKEUP,TK_CAPACITY_OFF_BY_ONE };
/* 1 ok; -1 invalid program or guest limits. fifo: the guest chooses every step. */
int tk_init(const struct pc_program *,int defect,int fifo);
/* One step of task `task` (reference; ignored in FIFO mode). Writes the step record's
 * canonical JSON to out[0..*n). 1 ok; 0 the task is not Runnable (no step); -1 guest
 * limits or an internal inconsistency. */
int tk_step(uint64_t task,char *out,size_t cap,size_t *n);
/* "Completed", "Deadlock", "BudgetExhausted" or "Running". */
const char *tk_execution(uint64_t fuel);
uint64_t tk_epoch(void);
int tk_runnable(uint64_t task);
/* The wait graph as a JSON array; bytes written, 0 on overflow. */
size_t tk_wait_graph(char *out,size_t cap);
/* FNV-1a 64 over the whole task machine, as 16 lowercase hex digits and a NUL. */
void tk_digest(char *hex);
#endif
