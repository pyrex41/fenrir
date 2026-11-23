#include "scheduler.h"

static void enqueue(fen_scheduler *scheduler, fen_fiber *fiber) {
    fiber->next = NULL;
    if (scheduler->last) scheduler->last->next = fiber;
    else scheduler->first = fiber;
    scheduler->last = fiber;
}

static void wait_on(fen_fiber *fiber, fen_wait_queue *queue, const char *reason, uint64_t target) {
    fiber->wait_reason = reason;
    fiber->wait_target = target;
    fiber->waiting_on = queue;
    fiber->next = NULL;
    if (queue->last) queue->last->next = fiber;
    else queue->first = fiber;
    queue->last = fiber;
}

static void wake_first(fen_wait_queue *queue) {
    fen_fiber *fiber = queue->first;
    queue->first = fiber->next;
    if (!queue->first) queue->last = NULL;
    fiber->waiting_on = NULL;
    enqueue(fiber->scheduler, fiber);
}

static void cancel_children(fen_scope *scope) {
    for (fen_fiber *child = scope->first_child; child; child = child->younger_sibling)
        fen_fiber_request_cancel(child);
}

static _Noreturn void finish(fen_fiber *fiber) {
    fen_scheduler *scheduler = fiber->scheduler;
    fiber->cancelled = fiber->cancel_requested;
    fiber->finished = 1;
    --scheduler->unfinished;
    fen_scope *scope = fiber->owner_scope;
    if (scope && fiber->trap_code) {
        scope->failed = 1;
        cancel_children(scope);
    }
    while (fiber->waiters.first) wake_first(&fiber->waiters);
    if (scope) {
        if (fiber->older_sibling) fiber->older_sibling->younger_sibling = fiber->younger_sibling;
        else scope->first_child = fiber->younger_sibling;
        if (fiber->younger_sibling) fiber->younger_sibling->older_sibling = fiber->older_sibling;
        else scope->last_child = fiber->older_sibling;
        if (--scope->unfinished == 0 && scope->joiner.first) wake_first(&scope->joiner);
    }
    fiber->owner_scope = NULL;
    if (scheduler->on_finish) scheduler->on_finish(fiber);
    fen_task_exit();
    fen_task_resume(&scheduler->state);
    fen_context_switch(&fiber->context, &scheduler->context);
    __builtin_trap();
}

_Noreturn void fen_fiber_fail(fen_scheduler *scheduler, unsigned code) {
    if (!code) __builtin_trap();
    scheduler->running->trap_code = code;
    finish(scheduler->running);
}

static void check_cancel(fen_fiber *fiber) {
    if (!fiber->cancel_requested || fiber->cancelling_scopes) return;
    fiber->cancelling_scopes = 1;
    while (fiber->active_scope) {
        fen_scope *scope = fiber->active_scope;
        fen_scope_abort(fiber->scheduler, scope);
        fiber->active_scope = scope->outer;
    }
    finish(fiber);
}

void fen_check_cancellation(fen_scheduler *scheduler) {
    check_cancel(scheduler->running);
}

static void enter(void *arg) {
    fen_fiber *fiber = arg;
    check_cancel(fiber);
    if (fiber->spawned) fen_fiber_yield(fiber->scheduler); /* TaskStart */
    fiber->run(fiber->argument);
    finish(fiber);
}

int fen_fiber_start(fen_scheduler *scheduler, fen_fiber *fiber, void *stack, size_t stack_size,
                    fen_inherited_handler *handlers, size_t capacity, void (*run)(void *), void *argument) {
    if (scheduler->next_task == UINT64_MAX) return 0;
    if (!fen_task_inherit(&fiber->state, handlers, capacity)) return 0;
    fiber->id = scheduler->next_task++;
    fiber->scheduler = scheduler;
    fiber->owner_scope = fiber->active_scope = NULL;
    fiber->cancelling_scopes = 0;
    fiber->trap_code = 0;
    fiber->spawned = 0;
    fiber->run = run;
    fiber->argument = argument;
    fiber->cancel_requested = fiber->cancelled = fiber->finished = 0;
    fiber->waiting_on = NULL;
    fiber->waiters = (fen_wait_queue){0};
    ++scheduler->unfinished;
    fen_context_init(&fiber->context, stack, stack_size, enter, fiber);
    enqueue(scheduler, fiber);
    return 1;
}

int fen_fiber_spawn(fen_scheduler *scheduler, fen_scope *scope, fen_fiber *child, void *stack, size_t stack_size,
                    fen_inherited_handler *handlers, size_t capacity, void (*run)(void *), void *argument) {
    check_cancel(scheduler->running);
    if (scope->failed) return 0;
    if (!fen_fiber_start(scheduler, child, stack, stack_size, handlers, capacity, run, argument)) return 0;
    child->owner_scope = scope;
    child->older_sibling = scope->last_child;
    child->younger_sibling = NULL;
    if (scope->last_child) scope->last_child->younger_sibling = child;
    else scope->first_child = child;
    scope->last_child = child;
    ++scope->unfinished;
    child->spawned = 1;
    fen_fiber_yield(scheduler);
    return 1;
}

static void suspend(fen_scheduler *scheduler) {
    fen_fiber *fiber = scheduler->running;
    fen_task_park(&fiber->state);
    fen_task_resume(&scheduler->state);
    fen_context_switch(&fiber->context, &scheduler->context);
}

void fen_scope_abort(fen_scheduler *scheduler, fen_scope *scope) {
    cancel_children(scope);
    fen_fiber_yield(scheduler);
    fen_scope_join(scheduler, scope);
}

void fen_scope_join(fen_scheduler *scheduler, fen_scope *scope) {
    fen_fiber *owner = scheduler->running;
    check_cancel(owner);
    while (scope->unfinished) {
        wait_on(owner, &scope->joiner, " joins scope ", scope->id);
        suspend(scheduler);
        check_cancel(owner);
    }
    fen_fiber_yield(scheduler);
}

int fen_fiber_request_cancel(fen_fiber *target) {
    if (target->finished || target->cancel_requested) return 0;
    target->cancel_requested = 1;
    fen_wait_queue *owner = target->waiting_on;
    if (owner) {
        fen_fiber *prev = NULL;
        for (fen_fiber *w = owner->first; w != target; w = w->next) prev = w;
        if (prev) prev->next = target->next;
        else owner->first = target->next;
        if (owner->last == target) owner->last = prev;
        target->waiting_on = NULL;
        enqueue(target->scheduler, target);
    }
    return 1;
}

void fen_fiber_cancel(fen_scheduler *scheduler, fen_fiber *target) {
    check_cancel(scheduler->running);
    fen_fiber_request_cancel(target);
    enqueue(scheduler, scheduler->running);
    suspend(scheduler);
}

void fen_fiber_yield(fen_scheduler *scheduler) {
    check_cancel(scheduler->running);
    enqueue(scheduler, scheduler->running);
    suspend(scheduler);
}

int64_t fen_scheduler_now(fen_scheduler *s) {
    if (s->read_clock) {
        uint64_t elapsed = s->read_clock() - s->clock_origin;
        s->now_ns = elapsed > INT64_MAX ? INT64_MAX : (int64_t)elapsed;
    }
    return s->now_ns;
}

fen_sleep_status fen_fiber_sleep(fen_scheduler *s, int64_t duration_ns) {
    fen_fiber *fiber = s->running;
    check_cancel(fiber);
    if (duration_ns < 0) return FEN_SLEEP_INVALID_DURATION;
    if (duration_ns > INT64_MAX - fen_scheduler_now(s)) return FEN_SLEEP_OVERFLOW;
    if (!duration_ns) {
        fen_fiber_yield(s);
    } else {
        uint64_t deadline = (uint64_t)(s->now_ns + duration_ns);
        fen_fiber **link = &s->timers.first;
        while (*link && ((*link)->wait_target < deadline ||
                ((*link)->wait_target == deadline && (*link)->id < fiber->id)))
            link = &(*link)->next;
        fiber->next = *link;
        if (!fiber->next) s->timers.last = fiber;
        *link = fiber;
        fiber->waiting_on = &s->timers;
        fiber->wait_reason = " sleeps until ";
        fiber->wait_target = deadline;
        suspend(s);
    }
    check_cancel(fiber);
    return FEN_SLEEP_OK;
}

static void poll_timers(fen_scheduler *s) {
    if (s->running || !s->timers.first) return;
    uint64_t deadline = s->timers.first->wait_target;
    if (s->read_clock) {
        while ((uint64_t)fen_scheduler_now(s) < deadline) {
            if (s->first) return;
            s->wait_ns(deadline - (uint64_t)s->now_ns);
        }
    } else {
        if (s->first) return;
        s->now_ns = (int64_t)deadline;
    }
    do {
        wake_first(&s->timers);
    } while (s->timers.first && s->timers.first->wait_target <= (uint64_t)s->now_ns);
}

void fen_fiber_await(fen_scheduler *scheduler, fen_fiber *target) {
    fen_fiber *waiter = scheduler->running;
    check_cancel(waiter);
    int blocked = !target->finished;
    if (!blocked) {
        enqueue(scheduler, waiter);
    } else {
        wait_on(waiter, &target->waiters, " awaits task ", target->id);
    }
    suspend(scheduler);
    /* A blocked await resumes at Wake, a separate scheduling point. */
    if (blocked) fen_fiber_yield(scheduler);
}

void fen_channel_init_objects(fen_channel *ch, fen_object **slots, size_t capacity) {
    if (!capacity) __builtin_trap();
    for (size_t i = 0; i < capacity; ++i) slots[i] = NULL;
    *ch = (fen_channel){.capacity=capacity, .objects={NULL, slots, capacity}};
    fen_pin_roots(&ch->pin, &ch->objects);
}

void fen_channel_release_objects(fen_channel *ch) {
    if (ch->senders.first || ch->receivers.first) __builtin_trap();
    fen_unpin_roots(&ch->pin);
    *ch = (fen_channel){0};
}

static void push(fen_channel *ch, uintptr_t value) {
    size_t index = (ch->head + ch->count) % ch->capacity;
    if (ch->objects.slots) ch->objects.slots[index] = (fen_object *)value;
    else ch->slots[index] = value;
    ++ch->count;
}

static uintptr_t pop(fen_channel *ch) {
    uintptr_t value;
    if (ch->objects.slots) {
        value = (uintptr_t)ch->objects.slots[ch->head];
        ch->objects.slots[ch->head] = NULL;
    } else {
        value = ch->slots[ch->head];
        ch->slots[ch->head] = 0;
    }
    ch->head = (ch->head + 1) % ch->capacity;
    --ch->count;
    return value;
}

static void stabilize(fen_channel *ch) {
    while (ch->receivers.first && ch->count) {
        ch->receivers.first->channel_value = pop(ch);
        if (ch->objects.slots || ch->managed_buffer) ch->receivers.first->channel_object = (fen_object *)ch->receivers.first->channel_value;
        ch->receivers.first->channel_ok = 1;
        wake_first(&ch->receivers);
    }
    while (!ch->closed && ch->senders.first && ch->count < ch->capacity) {
        push(ch, ch->senders.first->channel_value);
        ch->senders.first->channel_ok = 1;
        wake_first(&ch->senders);
    }
}

int fen_channel_send(fen_scheduler *s, fen_channel *ch, uintptr_t value) {
    fen_fiber *fiber = s->running;
    check_cancel(fiber);
    fen_roots frame;
    fen_object *held = (fen_object *)value;
    int managed = ch->objects.slots != NULL || ch->managed_buffer;
    if (managed) fen_enter(&frame, &held, 1);
    int ok = !ch->closed;
    if (ok && ch->count == ch->capacity) {
        fiber->channel_value = value;
        wait_on(fiber, &ch->senders, " sends on channel ", ch->id);
        suspend(s);
        check_cancel(fiber);
        ok = fiber->channel_ok;
    } else if (ok) {
        push(ch, value);
        stabilize(ch);
    }
    held = NULL;
    fen_fiber_yield(s);
    if (managed) fen_leave();
    return ok;
}

int fen_channel_receive(fen_scheduler *s, fen_channel *ch, uintptr_t *value) {
    fen_fiber *fiber = s->running;
    check_cancel(fiber);
    fen_roots frame;
    fiber->channel_object = NULL;
    int managed = ch->objects.slots != NULL || ch->managed_buffer;
    if (managed) fen_enter(&frame, &fiber->channel_object, 1);
    int ok = ch->count != 0;
    if (ok) {
        *value = pop(ch);
        if (managed) fiber->channel_object = (fen_object *)*value;
        stabilize(ch);
    } else if (!ch->closed) {
        wait_on(fiber, &ch->receivers, " receives on channel ", ch->id);
        suspend(s);
        check_cancel(fiber);
        ok = fiber->channel_ok;
        if (ok) *value = fiber->channel_value;
    }
    fen_fiber_yield(s);
    if (managed) fen_leave();
    return ok;
}

void fen_channel_close(fen_scheduler *s, fen_channel *ch) {
    check_cancel(s->running);
    ch->closed = 1;
    while (ch->senders.first) {
        ch->senders.first->channel_ok = 0;
        wake_first(&ch->senders);
    }
    stabilize(ch);
    while (ch->receivers.first) {
        ch->receivers.first->channel_ok = 0;
        wake_first(&ch->receivers);
    }
    fen_fiber_yield(s);
}

int fen_dispatch_selected(fen_scheduler *scheduler, uint64_t task_id) {
    if (scheduler->running) return 0;
    fen_fiber *previous = NULL;
    fen_fiber **link = &scheduler->first;
    while (*link && (*link)->id != task_id) {
        previous = *link;
        link = &previous->next;
    }
    fen_fiber *fiber = *link;
    if (!fiber) return 0;
    *link = fiber->next;
    if (scheduler->last == fiber) scheduler->last = previous;
    fiber->next = NULL;
    scheduler->running = fiber;
    fen_task_park(&scheduler->state);
    fen_task_resume(&fiber->state);
    fen_context_switch(&scheduler->context, &fiber->context);
    scheduler->running = NULL;
    return 1;
}

int fen_dispatch(fen_scheduler *scheduler) {
    poll_timers(scheduler);
    return scheduler->first && fen_dispatch_selected(scheduler, scheduler->first->id);
}

static fen_schedule_result schedule_outcome(const fen_scheduler *s) {
    if (s->first || s->timers.first) return FEN_SCHEDULE_TRUNCATED;
    return s->unfinished ? FEN_SCHEDULE_DEADLOCK : FEN_SCHEDULE_COMPLETE;
}

fen_schedule_result fen_record_schedule(fen_scheduler *s, uint64_t *choices, size_t capacity, size_t *used) {
    *used = 0;
    if (s->running) return FEN_SCHEDULE_DIVERGED;
    while (*used < capacity) {
        poll_timers(s);
        if (!s->first) break;
        choices[*used] = s->first->id;
        fen_dispatch(s);
        ++*used;
    }
    return schedule_outcome(s);
}

fen_schedule_result fen_replay_schedule(fen_scheduler *s, const uint64_t *choices, size_t count, size_t *used) {
    *used = 0;
    if (s->running) return FEN_SCHEDULE_DIVERGED;
    while (*used < count) {
        poll_timers(s);
        if (!fen_dispatch_selected(s, choices[*used])) return FEN_SCHEDULE_DIVERGED;
        ++*used;
    }
    return schedule_outcome(s);
}
