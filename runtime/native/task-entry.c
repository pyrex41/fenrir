#include "task-entry.h"
extern fen_result fenrir_task_entry(int64_t input);
extern int fenrir_task_result_is_object(void);
extern const char *fenrir_task_root_location(void);

/* The CLI executes one root task per process or guest. */
#ifndef FEN_CHILD_SLOTS
#define FEN_CHILD_SLOTS 16
#endif
#ifndef FEN_HANDLER_SLOTS
#define FEN_HANDLER_SLOTS 32
#endif
#ifndef FEN_TASK_STACK_BYTES
#define FEN_TASK_STACK_BYTES (256 * 1024)
#endif
extern const char *fen_trap_location;
static fen_scheduler scheduler;
static fen_fiber root;
static uint64_t next_scope, next_channel;
static _Alignas(16) unsigned char stack[FEN_TASK_STACK_BYTES];
typedef struct { int64_t input; fen_result result; const char *location; } invocation;

static void run_root(void *arg) {
    invocation *call = arg;
    fen_scope scope = {.id = next_scope++};
    root.active_scope = &scope;
    call->result = fenrir_task_entry(call->input);
    /* Entry has unlinked its compiler frame. Other tasks can collect while
     * the implicit scope waits, including when no explicit scope was used. */
    fen_roots roots;
    fen_object *retained = !call->result.status && fenrir_task_result_is_object()
                             ? (fen_object *)call->result.value : NULL;
    fen_enter(&roots, &retained, 1);
    if (call->result.status) fen_scope_abort(&scheduler, &scope);
    else {
        fen_scope_join(&scheduler, &scope);
        if (scope.failed) {
            call->result = (fen_result){0, 5};
            fen_trap_location = fenrir_task_root_location();
        }
    }
    root.active_scope = NULL;
    fen_leave();
    call->location = fen_trap_location;
}

extern void fen_write(const char *, size_t);

static void print_id(uint64_t id) {
    char digits[20];
    size_t pos = sizeof digits;
    do {
        digits[--pos] = (char)('0' + id % 10);
        id /= 10;
    } while (id);
    fen_write(digits + pos, sizeof digits - pos);
}

void fen_print_task_id(void) { print_id(scheduler.running->id); }

int fen_spawn_current(fen_fiber *child, void *child_stack, size_t size,
                      fen_inherited_handler *handlers, size_t capacity,
                      void (*run)(void *), void *arg) {
    return fen_fiber_spawn(&scheduler, scheduler.running->active_scope, child,
                           child_stack, size, handlers, capacity, run, arg);
}

/* Completed handles remain ordinary heap objects. Only concurrently live
 * children occupy stacks and keep a scheduler-owned root. */
enum { child_slots = FEN_CHILD_SLOTS, handler_slots = FEN_HANDLER_SLOTS };
typedef struct {
    fen_fiber fiber;
    uint64_t implicit_scope;
    fen_inherited_handler handlers[handler_slots];
    _Alignas(16) unsigned char stack[FEN_TASK_STACK_BYTES];
    fen_object *handle;
    fen_roots roots;
    fen_parked_roots pin;
} child_slot;
static child_slot children[child_slots];
extern fen_object *fen_allocate(unsigned, unsigned);
extern fen_handler *fen_current_handler(void);
extern fen_result fen_finish_handler(uintptr_t, fen_handler *);
extern void fen_restore_handler(fen_handler *);

static void release_child(fen_fiber *fiber) {
    for (size_t i = 0; i < child_slots; ++i) {
        child_slot *slot = &children[i];
        if (&slot->fiber != fiber || !slot->handle) continue;
        slot->handle->fields[0] = 0;
        slot->handle->fields[1] = 0;
        slot->handle->fields[3] = fiber->cancelled ? 8 : fiber->trap_code;
        fen_unpin_roots(&slot->pin);
        slot->handle = NULL;
        return;
    }
}

static void run_closure(void *arg) {
    child_slot *slot = arg;
    fen_object *handle = slot->handle;
    fen_object *closure = (fen_object *)handle->fields[1];
    typedef fen_result (*closure_fn)(uintptr_t, fen_object *);
    fen_scope scope = {.id = slot->implicit_scope};
    slot->fiber.active_scope = &scope;
    fen_result result = ((closure_fn)closure->fields[0])(0, closure);
    for (fen_handler *h = fen_current_handler(); h; h = h->outer) {
        if (result.status == (uintptr_t)h) result.status = 0;
        if (result.status) fen_restore_handler(h->outer);
        else result = fen_finish_handler(result.value, h);
    }
    if (!result.status) handle->fields[2] = result.value;
    if (result.status) fen_scope_abort(&scheduler, &scope);
    else fen_scope_join(&scheduler, &scope);
    slot->fiber.active_scope = NULL;
    if (result.status || scope.failed)
        fen_fiber_fail(&scheduler, result.status ? (unsigned)result.status : 5);
}

fen_result fen_spawn_closure(fen_object *closure, unsigned object_result) {
    fen_check_cancellation(&scheduler);
    if (scheduler.running->active_scope->failed) return (fen_result){0, 5};
    for (size_t i = 0; i < child_slots; ++i) {
        child_slot *slot = &children[i];
        if (slot->handle) continue;
        fen_object *handle = fen_allocate(2 | (object_result ? 4 : 0), 0);
        if (!handle) return (fen_result){0, 3};
        handle->fields[0] = (uintptr_t)&slot->fiber;
        handle->fields[1] = (uintptr_t)closure;
        fen_roots parent;
        fen_enter(&parent, &handle, 1);
        slot->implicit_scope = next_scope++;
        slot->handle = handle;
        slot->roots = (fen_roots){NULL, &slot->handle, 1};
        fen_pin_roots(&slot->pin, &slot->roots);
        int started = fen_spawn_current(&slot->fiber, slot->stack, sizeof slot->stack,
                                        slot->handlers, handler_slots, run_closure, slot);
        if (!started) {
            fen_unpin_roots(&slot->pin);
            slot->handle = NULL;
        }
        fen_leave();
        return started ? (fen_result){(uintptr_t)handle, 0} : (fen_result){0, 7};
    }
    return (fen_result){0, 7};
}

fen_result fen_await_handle(fen_object *handle) {
    fen_fiber *child = (fen_fiber *)handle->fields[0];
    if (child) fen_fiber_await(&scheduler, child);
    else fen_fiber_yield(&scheduler);
    return (fen_result){handle->fields[2], handle->fields[3]};
}

void fen_cancel_handle(fen_object *handle) {
    fen_fiber *child = (fen_fiber *)handle->fields[0];
    if (child) fen_fiber_cancel(&scheduler, child);
    else fen_fiber_yield(&scheduler);
}

/* A handle owns its managed ring buffer. The pool keeps weak references so
 * discarded channels and their queued payloads can be collected together. */
enum { channel_slots = 64, channel_tag = 0x40000000 };
typedef struct { fen_object *weak; fen_channel channel; } channel_slot;
static channel_slot channels[channel_slots];
extern void fen_collect(void);

static channel_slot *free_channel(void) {
    for (size_t i = 0; i < channel_slots; ++i) {
        channel_slot *slot = &channels[i];
        fen_object *h = slot->weak;
        if (!h || !h->live || h->tag != channel_tag || h->fields[0] != (uintptr_t)&slot->channel)
            return slot;
    }
    return NULL;
}

fen_object *fen_new_channel(size_t capacity, int managed) {
    fen_check_cancellation(&scheduler);
    if (!capacity || capacity > 8) return NULL;
    channel_slot *slot = free_channel();
    if (!slot) {
        fen_collect();
        slot = free_channel();
        if (!slot) return NULL;
    }
    fen_object *handle = fen_allocate(2, channel_tag);
    if (!handle) return NULL;
    fen_roots frame;
    fen_enter(&frame, &handle, 1);
    fen_object *buffer = fen_allocate(managed ? (1u << capacity) - 1 : 0, 0);
    if (buffer) {
        slot->channel = (fen_channel){.capacity = capacity, .slots = buffer->fields, .id = next_channel++, .managed_buffer = managed};
        slot->weak = handle;
        handle->fields[0] = (uintptr_t)&slot->channel;
        handle->fields[1] = (uintptr_t)buffer;
        fen_fiber_yield(&scheduler);
    }
    fen_leave();
    return buffer ? handle : NULL;
}

int fen_send_handle(fen_object *handle, uintptr_t value) {
    return fen_channel_send(&scheduler, (fen_channel *)handle->fields[0], value);
}

fen_result fen_receive_handle(fen_object *handle) {
    uintptr_t value = 0;
    int ok = fen_channel_receive(&scheduler, (fen_channel *)handle->fields[0], &value);
    return (fen_result){value, ok};
}

void fen_close_handle(fen_object *handle) {
    fen_channel_close(&scheduler, (fen_channel *)handle->fields[0]);
}

int64_t fen_root_now(void) {
    return fen_scheduler_now(&scheduler);
}

fen_result fen_root_sleep(int64_t duration_ns) {
    return (fen_result){0, fen_fiber_sleep(&scheduler, duration_ns)};
}

void fen_root_yield(void) {
    fen_fiber_yield(&scheduler);
}

/* Generated ARM64 frames reserve 64 aligned bytes per lexical scope. */
_Static_assert(sizeof(fen_scope) <= 64, "native scope frame size");

void fen_enter_scope(fen_scope *frame) {
    fen_fiber *task = scheduler.running;
    *frame = (fen_scope){.outer = task->active_scope, .id = next_scope++};
    task->active_scope = frame;
    fen_fiber_yield(&scheduler);
}

int fen_leave_scope(fen_scope *frame, int aborting) {
    if (aborting) fen_scope_abort(&scheduler, frame);
    else fen_scope_join(&scheduler, frame);
    scheduler.running->active_scope = frame->outer;
    return frame->failed;
}

static void print_deadlock(void) {
    fen_fiber *waiters[1 + child_slots] = {&root};
    size_t count = 1;
    for (size_t i = 0; i < child_slots; ++i) {
        if (!children[i].handle) continue;
        fen_fiber *task = &children[i].fiber;
        size_t j = count++;
        while (j && waiters[j-1]->id > task->id) {
            waiters[j] = waiters[j-1];
            --j;
        }
        waiters[j] = task;
    }
    fen_write("deadlock: ", 10);
    for (size_t i = 0; i < count; ++i) {
        fen_fiber *task = waiters[i];
        if (!task->waiting_on) __builtin_trap();
        if (i) fen_write(", ", 2);
        fen_write("task ", 5);
        print_id(task->id);
        size_t length = 0;
        while (task->wait_reason[length]) ++length;
        fen_write(task->wait_reason, length);
        print_id(task->wait_target);
    }
    fen_write("\n", 1);
}

extern const char *fen_schedule_request;
static int dispatch_requested(const char *request) {
    uint64_t choices[240];
    size_t used, count = 0;
    fen_schedule_result result;
    if (request[0] == 'r' && !request[1]) {
        result = fen_record_schedule(&scheduler, choices, 240, &used);
    } else {
        for (;;) {
            if (count == 240 || *request < '0' || *request > '9') return 0;
            uint64_t id = 0;
            do {
                unsigned digit = (unsigned)(*request++ - '0');
                if (id > (UINT64_MAX - digit) / 10) return 0;
                id = id * 10 + digit;
            } while (*request >= '0' && *request <= '9');
            choices[count++] = id;
            if (!*request) break;
            if (*request++ != ',') return 0;
        }
        result = fen_replay_schedule(&scheduler, choices, count, &used);
    }
    if (result != FEN_SCHEDULE_COMPLETE && result != FEN_SCHEDULE_DEADLOCK) return 0;
    fen_write("fenrir schedule ", 16);
    for (size_t i = 0; i < used; ++i) {
        if (i) fen_write(",", 1);
        print_id(choices[i]);
    }
    fen_write("\n", 1);
    return 1;
}

fen_result fenrir_entry(int64_t input) {
    extern uint64_t (*fen_host_clock)(void);
    extern void (*fen_host_wait)(uint64_t);
    scheduler.read_clock = fen_host_clock;
    scheduler.wait_ns = fen_host_wait;
    scheduler.clock_origin = fen_host_clock ? fen_host_clock() : 0;
    scheduler.now_ns = 0;
    scheduler.on_finish = release_child;
    invocation call = {.input = input};
    if (!fen_fiber_start(&scheduler, &root, stack, sizeof stack, NULL, 0, run_root, &call))
        __builtin_trap();
    if (fen_schedule_request) {
        if (!dispatch_requested(fen_schedule_request)) {
            fen_write("native schedule rejected\n", 25);
            return (fen_result){0, 11};
        }
    } else while (fen_dispatch(&scheduler)) {}
    if (!root.finished) {
        print_deadlock();
        return (fen_result){0, 10};
    }
    fen_trap_location = call.location;
    return call.result;
}
