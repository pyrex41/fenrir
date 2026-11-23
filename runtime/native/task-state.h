#ifndef FENRIR_NATIVE_TASK_STATE_H
#define FENRIR_NATIVE_TASK_STATE_H

#include "heap.h"

typedef struct fen_handler {
    struct fen_handler *outer;
    fen_object *clauses;
    uintptr_t effect;
    fen_object **pending;
} fen_handler;

typedef struct {
    fen_parked_roots roots;
    fen_handler *active;
    fen_handler *selected;
    unsigned *use;
    const char *location;
} fen_task_state;

/* Storage belongs to the child and stays at a fixed address for its lifetime. */
typedef struct {
    fen_handler handler;
    fen_object *slots[2]; /* inherited clauses and child-local pending work */
    fen_roots frame;
} fen_inherited_handler;

/* Prepare a fresh, parked child. Return 0 if capacity is insufficient,
 * leaving both the child and collector unchanged. */
int fen_task_inherit(fen_task_state *child, fen_inherited_handler *storage, size_t capacity);

/* Park clears the running state for a fresh stack. Resume restores a parked
 * stack. Handler frames and the one-shot use cell stay on their owning stack. */
/* Drop the finishing stack after its caller has secured its outcome. */
void fen_task_exit(void);
void fen_task_park(fen_task_state *state);
void fen_task_resume(fen_task_state *state);
#endif
