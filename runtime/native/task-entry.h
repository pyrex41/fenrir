#ifndef FENRIR_NATIVE_TASK_ENTRY_H
#define FENRIR_NATIVE_TASK_ENTRY_H

#include "scheduler.h"
typedef struct { uintptr_t value, status; } fen_result;
int64_t fen_root_now(void);
fen_result fen_root_sleep(int64_t duration_ns);
fen_result fenrir_entry(int64_t input);
int fen_spawn_current(fen_fiber *child, void *stack, size_t size,
                      fen_inherited_handler *handlers, size_t capacity,
                      void (*run)(void *), void *arg);

#endif
