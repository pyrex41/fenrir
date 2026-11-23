#include "task-state.h"

/* One heap shared by cooperatively scheduled stacks. */
#ifndef FEN_HEAP_SLOTS
#define FEN_HEAP_SLOTS 1024
#endif
static fen_object storage[FEN_HEAP_SLOTS];
static fen_heap heap = {.storage = storage, .capacity = FEN_HEAP_SLOTS};

void fen_collect(void) { fen_heap_collect(&heap); }

void fen_enter(fen_roots *frame, fen_object **slots, size_t count) {
    *frame = (fen_roots){heap.roots, slots, count};
    heap.roots = frame;
}

void fen_leave(void) { heap.roots = heap.roots->previous; }

/* ARM64 passes and returns these two words in x0/x1. Generated epilogues
 * can unlink a frame while carrying either a result or tail-call arguments. */
typedef struct { uintptr_t value, status; } fen_return_words;
fen_return_words fen_leave_result(uintptr_t value, uintptr_t status) {
    fen_leave();
    return (fen_return_words){value, status};
}

/* The scheduler parks the current stack once before switching. Starting a
 * fresh stack leaves heap.roots empty. Resuming selects any parked stack. */
void fen_pin_roots(fen_parked_roots *task, fen_roots *frames) {
    *task = (fen_parked_roots){frames, heap.parked};
    heap.parked = task;
}

void fen_park_roots(fen_parked_roots *task) {
    fen_pin_roots(task, heap.roots);
    heap.roots = NULL;
}

void fen_unpin_roots(fen_parked_roots *task) {
    fen_parked_roots **link = &heap.parked;
    while (*link && *link != task) link = &(*link)->next;
    if (!*link) __builtin_trap();
    *link = task->next;
    *task = (fen_parked_roots){0};
}

void fen_resume_roots(fen_parked_roots *task) {
    if (heap.roots) __builtin_trap();
    heap.roots = task->frames;
    fen_unpin_roots(task);
}

fen_object *fen_allocate(unsigned mask, unsigned tag) {
    return fen_heap_alloc(&heap, tag, (uint8_t)mask);
}

fen_object *fen_allocate_full(unsigned mask, unsigned tag) {
    return fen_heap_alloc_full(&heap, tag, (uint8_t)mask);
}

unsigned fen_tag(const fen_object *object) { return object->tag; }

/* Image leaves store bytes after the header. Small concatenations use the
 * remaining payload words inline. Larger joins trace their two children.
 * Field zero holds length in all forms. Reserved tags distinguish Bytes
 * from declared constructors even inside a polymorphic equality traversal. */
#define BYTE_LEAF UINT32_MAX
#define BYTE_JOIN (UINT32_MAX - 1)
#define BYTE_INLINE (UINT32_MAX - 2)

static const unsigned char *leaf_data(const fen_object *leaf) {
    return leaf->tag == BYTE_INLINE ? (const unsigned char *)leaf->fields + sizeof leaf->fields[0]
                                    : (const unsigned char *)(leaf + 1);
}

/* Return used=0 to execute the original checked loop whenever the span
 * or signed accumulation cannot be proved safe using the byte upper bound. */
typedef struct { int64_t value; uintptr_t used; } fen_byte_sum_result;
fen_byte_sum_result fen_try_byte_sum(const fen_object *bytes, uintptr_t start,
                                     uintptr_t end, int64_t initial) {
    if ((bytes->tag != BYTE_LEAF && bytes->tag != BYTE_INLINE) || start > end || end > bytes->fields[0])
        return (fen_byte_sum_result){0, 0};
    uintptr_t length = end - start;
    if (length > INT64_MAX / 255 || initial > INT64_MAX - (int64_t)(length * 255))
        return (fen_byte_sum_result){0, 0};
    const unsigned char *src = leaf_data(bytes) + start;
    uint64_t sum = 0;
    for (uintptr_t i = 0; i < length; ++i) sum += src[i];
    return (fen_byte_sum_result){initial + (int64_t)sum, 1};
}

fen_object *fen_bytes_concat(fen_object *a, fen_object *b) {
    if (!a->fields[0]) return b;
    if (!b->fields[0]) return a;
    if (a->fields[0] > INT64_MAX - b->fields[0]) return NULL;
    uintptr_t length = a->fields[0] + b->fields[0];
    if (length <= sizeof a->fields - sizeof a->fields[0] && a->tag != BYTE_JOIN && b->tag != BYTE_JOIN) {
        fen_object *leaf = fen_allocate(0, BYTE_INLINE);
        if (!leaf) return NULL;
        leaf->fields[0] = length;
        unsigned char *dst = (unsigned char *)leaf->fields + sizeof leaf->fields[0];
        const unsigned char *left = leaf_data(a), *right = leaf_data(b);
        for (uintptr_t i = 0; i < a->fields[0]; ++i) *dst++ = left[i];
        for (uintptr_t i = 0; i < b->fields[0]; ++i) *dst++ = right[i];
        return leaf;
    }
    fen_object *out = fen_allocate(6, BYTE_JOIN);
    if (out) {
        out->fields[0] = a->fields[0] + b->fields[0];
        out->fields[1] = (uintptr_t)a;
        out->fields[2] = (uintptr_t)b;
    }
    return out;
}

static const fen_object *byte_child(const fen_object *node, uintptr_t *offset) {
    const fen_object *left = (const fen_object *)node->fields[1];
    if (*offset < left->fields[0]) return left;
    *offset -= left->fields[0];
    return (const fen_object *)node->fields[2];
}

int64_t fen_bytes_index(const fen_object *node, uintptr_t i) {
    if (i >= node->fields[0]) return -1;
    while (node->tag == BYTE_JOIN) node = byte_child(node, &i);
    return leaf_data(node)[i];
}

static int equal_bytes(const fen_object *left, const fen_object *right) {
    uintptr_t length = left->fields[0];
    if (length != right->fields[0]) return 0;
    for (uintptr_t offset = 0; offset < length;) {
        uintptr_t i = offset, j = offset;
        const fen_object *a = left, *b = right;
        while ((a != b || i != j) && (a->tag == BYTE_JOIN || b->tag == BYTE_JOIN)) {
            // Descend the longer remaining span first so differently grouped
            // ropes can meet at a shared subtree before reaching its leaves.
            uintptr_t remaining_a = a->fields[0] - i, remaining_b = b->fields[0] - j;
            if (a->tag == BYTE_JOIN && (b->tag != BYTE_JOIN || remaining_a >= remaining_b))
                a = byte_child(a, &i);
            else
                b = byte_child(b, &j);
        }
        uintptr_t n = a->fields[0] - i;
        if (n > b->fields[0] - j) n = b->fields[0] - j;
        if (a != b || i != j) {
            const unsigned char *x = leaf_data(a) + i, *y = leaf_data(b) + j;
            for (uintptr_t k = 0; k < n; ++k) if (x[k] != y[k]) return 0;
        }
        offset += n;
    }
    return 1;
}

extern void fen_write(const char *, size_t);
void fen_print_bytes(const fen_object *b) {
    static const char hex[] = "0123456789abcdef";
    fen_write("#x", 2);
    for (uintptr_t i = 0; i < b->fields[0]; ++i) {
        unsigned n = (unsigned)fen_bytes_index(b, i);
        char pair[] = {hex[n >> 4], hex[n & 15]};
        fen_write(pair, 2);
    }
}

/* Validated equality compares values of the same type. Nullary constructors
 * and unused fields are zero-initialized. Constructed Fenrir data is acyclic. */
uintptr_t fen_equal(const fen_object *left, const fen_object *right) {
    if (left == right) return 1;
    if (left->tag >= BYTE_INLINE && right->tag >= BYTE_INLINE)
        return equal_bytes(left, right);
    if (left->tag != right->tag || left->pointer_mask != right->pointer_mask) return 0;
    for (unsigned i = 0; i < 8; ++i) {
        if (left->pointer_mask & (1u << i)) {
            if (!fen_equal((const fen_object *)left->fields[i],
                           (const fen_object *)right->fields[i])) return 0;
        } else if (left->fields[i] != right->fields[i]) return 0;
    }
    return 1;
}

/* Each CLI invocation executes one program in this synchronous context. */
const char *fen_trap_location;
const char *fen_schedule_request;
uint64_t (*fen_host_clock)(void);
void (*fen_host_wait)(uint64_t);
void fen_set_location(const char *location) { fen_trap_location = location; }

/* The installing native frame roots the clause tuple throughout the body.
 * The descriptor itself lives in that frame, including during a clause call. */
static fen_handler *active_handler;
fen_handler *fen_current_handler(void) { return active_handler; }
void fen_restore_handler(fen_handler *outer) { active_handler = outer; }
void fen_install_handler(fen_handler *frame, fen_object *clauses, uintptr_t effect, fen_object **pending) {
    *pending = NULL;
    *frame = (fen_handler){active_handler, clauses, effect, pending};
    active_handler = frame;
}

static fen_handler *selected_handler;
static unsigned *current_use;
int fen_task_inherit(fen_task_state *child, fen_inherited_handler *storage, size_t capacity) {
    size_t depth = 0;
    for (fen_handler *frame = active_handler; frame; frame = frame->outer) {
        if (depth == capacity) return 0;
        ++depth;
    }
    fen_roots *roots = NULL;
    fen_handler *frame = active_handler;
    for (size_t i = 0; i < depth; ++i, frame = frame->outer) {
        fen_inherited_handler *copy = &storage[i];
        copy->slots[0] = frame->clauses;
        copy->slots[1] = NULL;
        copy->handler = (fen_handler){i + 1 < depth ? &storage[i + 1].handler : NULL,
                                     frame->clauses, frame->effect, &copy->slots[1]};
        copy->frame = (fen_roots){roots, copy->slots, 2};
        roots = &copy->frame;
    }
    *child = (fen_task_state){.roots = {roots, heap.parked},
                              .active = depth ? &storage[0].handler : NULL};
    heap.parked = &child->roots;
    return 1;
}

void fen_task_park(fen_task_state *state) {
    fen_park_roots(&state->roots);
    state->active = active_handler;
    state->selected = selected_handler;
    state->use = current_use;
    state->location = fen_trap_location;
    fen_task_exit();
}

void fen_task_exit(void) {
    heap.roots = NULL;
    active_handler = NULL;
    selected_handler = NULL;
    current_use = NULL;
    fen_trap_location = NULL;
}

void fen_task_resume(fen_task_state *state) {
    fen_resume_roots(&state->roots);
    active_handler = state->active;
    selected_handler = state->selected;
    current_use = state->use;
    fen_trap_location = state->location;
    *state = (fen_task_state){0};
}

unsigned fen_defer_clause(fen_object *closure) {
    if (!selected_handler || !current_use || *current_use) return 6;
    fen_object *link = fen_allocate(3, 0);
    if (!link) return 3;
    link->fields[0] = (uintptr_t)closure;
    link->fields[1] = (uintptr_t)*selected_handler->pending;
    *selected_handler->pending = link;
    *current_use = 1;
    return 0;
}
unsigned fen_use_resumption(unsigned mode) {
    if (!current_use || *current_use) return 0;
    *current_use = mode;
    return 1;
}

struct fen_outcome { uintptr_t value; uintptr_t status; };
struct fen_outcome fen_perform(uintptr_t arg, uintptr_t effect, uintptr_t operation) {
    fen_handler *saved = active_handler;
    fen_handler *handler = saved;
    while (handler && handler->effect != effect) handler = handler->outer;
    if (!handler) return (struct fen_outcome){0, 9};
    fen_object *closure = (fen_object *)handler->clauses->fields[operation];
    typedef struct fen_outcome (*clause_fn)(uintptr_t, fen_object *);
    unsigned use = 0;
    unsigned *previous_use = current_use;
    fen_handler *previous_selected = selected_handler;
    selected_handler = handler;
    current_use = &use;
    active_handler = handler->outer;
    struct fen_outcome out = ((clause_fn)closure->fields[0])(arg, closure);
    active_handler = saved;
    current_use = previous_use;
    selected_handler = previous_selected;
    if (!out.status && use == 2) out.status = (uintptr_t)handler;
    return out;
}

struct fen_outcome fen_finish_handler(uintptr_t value, fen_handler *frame) {
    active_handler = frame->outer;
    struct fen_outcome out = {value, 0};
    while (*frame->pending && !out.status) {
        fen_object *link = *frame->pending;
        fen_object *closure = (fen_object *)link->fields[0];
        *frame->pending = (fen_object *)link->fields[1];
        typedef struct fen_outcome (*continuation_fn)(uintptr_t, fen_object *);
        out = ((continuation_fn)closure->fields[0])(out.value, closure);
    }
    return out;
}
