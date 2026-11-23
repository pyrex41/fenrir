#ifndef FENRIR_NATIVE_SCHEDULER_H
#define FENRIR_NATIVE_SCHEDULER_H

#include "context.h"
#include "task-state.h"

typedef struct fen_fiber fen_fiber;
typedef struct { fen_fiber *first, *last; } fen_wait_queue;
/* Scope storage remains live until its final child has terminated. */
typedef struct fen_scope {
    struct fen_scope *outer;
    uint64_t id;
    size_t unfinished;
    fen_fiber *first_child, *last_child;
    fen_wait_queue joiner;
    int failed;
} fen_scope;
typedef struct {
    uintptr_t *slots;
    fen_roots objects;
    fen_parked_roots pin;
    size_t capacity, head, count;
    fen_wait_queue senders, receivers;
    int closed, managed_buffer;
    uint64_t id;
} fen_channel;
typedef struct {
    fen_context context;
    fen_task_state state;
    fen_fiber *first, *last, *running;
    size_t unfinished;
    uint64_t next_task;
    int64_t now_ns;
    uint64_t clock_origin;
    uint64_t (*read_clock)(void);
    void (*wait_ns)(uint64_t);
    fen_wait_queue timers;
    void (*on_finish)(fen_fiber *);
} fen_scheduler;

struct fen_fiber {
    fen_context context;
    fen_task_state state;
    fen_scheduler *scheduler;
    uint64_t id;
    fen_fiber *next;
    fen_wait_queue waiters;
    void (*run)(void *);
    void *argument;
    fen_wait_queue *waiting_on;
    const char *wait_reason;
    uint64_t wait_target;
    uintptr_t channel_value;
    fen_object *channel_object;
    int channel_ok;
    fen_scope *owner_scope, *active_scope;
    fen_fiber *older_sibling, *younger_sibling;
    unsigned trap_code;
    int spawned;
    int cancel_requested, cancelled, finished;
};

/* All storage is caller-owned. Initialize the scheduler to zero. The fiber,
 * its stack and its handler storage must remain valid until it finishes. */
int fen_fiber_start(fen_scheduler *scheduler, fen_fiber *fiber, void *stack, size_t stack_size,
                    fen_inherited_handler *handlers, size_t capacity, void (*run)(void *), void *argument);
/* Spawn from a running task. Spawn and the child's TaskStart are separate scheduling points. */
int fen_fiber_spawn(fen_scheduler *scheduler, fen_scope *scope, fen_fiber *child, void *stack, size_t stack_size,
                    fen_inherited_handler *handlers, size_t capacity, void (*run)(void *), void *argument);
/* Terminate with a nonzero native trap code after owned scopes have joined. */
_Noreturn void fen_fiber_fail(fen_scheduler *scheduler, unsigned code);
void fen_scope_abort(fen_scheduler *scheduler, fen_scope *scope);
void fen_scope_join(fen_scheduler *scheduler, fen_scope *scope);
/* Await is a scheduling point even if the target is already terminal. */
void fen_fiber_await(fen_scheduler *scheduler, fen_fiber *target);
int fen_fiber_request_cancel(fen_fiber *target);
void fen_fiber_cancel(fen_scheduler *scheduler, fen_fiber *target);
void fen_check_cancellation(fen_scheduler *scheduler);
void fen_fiber_yield(fen_scheduler *scheduler);
/* These values are native result status codes. Failed sleeps leave time and
 * the timer queue unchanged. */
typedef enum {
    FEN_SLEEP_OK = 0,
    FEN_SLEEP_OVERFLOW = 1,
    FEN_SLEEP_INVALID_DURATION = 9
} fen_sleep_status;
int64_t fen_scheduler_now(fen_scheduler *scheduler);
fen_sleep_status fen_fiber_sleep(fen_scheduler *scheduler, int64_t duration_ns);
/* Caller provides a zero-initialized channel, positive capacity and storage.
 * For managed payloads initialize with pointer slots and release after use. */
void fen_channel_init_objects(fen_channel *, fen_object **slots, size_t capacity);
void fen_channel_release_objects(fen_channel *);
int fen_channel_send(fen_scheduler *, fen_channel *, uintptr_t value);
int fen_channel_receive(fen_scheduler *, fen_channel *, uintptr_t *value);
void fen_channel_close(fen_scheduler *, fen_channel *);
/* Replay one explicit choice. An unavailable task leaves the queue intact. */
int fen_dispatch_selected(fen_scheduler *scheduler, uint64_t task_id);
typedef enum {
    FEN_SCHEDULE_COMPLETE,
    FEN_SCHEDULE_DEADLOCK,
    FEN_SCHEDULE_TRUNCATED,
    FEN_SCHEDULE_DIVERGED
} fen_schedule_result;
/* Record up to capacity FIFO decisions or consume an exact replay schedule.
 * used counts successful dispatches, identifying the first unavailable choice. */
fen_schedule_result fen_record_schedule(fen_scheduler *, uint64_t *choices, size_t capacity, size_t *used);
fen_schedule_result fen_replay_schedule(fen_scheduler *, const uint64_t *choices, size_t count, size_t *used);
/* Run the oldest ready fiber to its next scheduling point. */
int fen_dispatch(fen_scheduler *scheduler);
#endif
