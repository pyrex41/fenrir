#ifndef FENRIR_NATIVE_HEAP_H
#define FENRIR_NATIVE_HEAP_H

#include <stddef.h>
#include <stdint.h>

/* Small fixed-layout objects. Only fields selected by pointer_mask are
 * references into this heap. A zero reference denotes no object. */
typedef struct fen_object {
    uintptr_t fields[8];
    struct fen_object *next;
    uint32_t tag;
    uint8_t pointer_mask;
    uint8_t live;
    uint8_t marked;
} fen_object;

enum { FEN_IMAGE_OBJECT = 2 };
_Static_assert(sizeof(fen_object) == 80 && offsetof(fen_object, tag) == 72 &&
               offsetof(fen_object, live) == 77, "ARM64 literal object layout");

/* Caller-owned root frames. Link frames before allocating; keep each frame
 * and its slots valid until unlinked. The scheduler must include suspended
 * tasks' roots and the host must pin retained objects across callbacks. */
typedef struct fen_roots {
    struct fen_roots *previous;
    fen_object **slots;
    size_t count;
} fen_roots;

/* A suspended task owns this node until its stack is active again. */
typedef struct fen_parked_roots {
    fen_roots *frames;
    struct fen_parked_roots *next;
} fen_parked_roots;

void fen_enter(fen_roots *frame, fen_object **slots, size_t count);
void fen_leave(void);
void fen_pin_roots(fen_parked_roots *node, fen_roots *frames);
void fen_unpin_roots(fen_parked_roots *node);
void fen_park_roots(fen_parked_roots *task);
void fen_resume_roots(fen_parked_roots *task);

typedef struct {
    fen_object *storage;
    size_t capacity;
    size_t used; /* Slots below used are initialized and may contain holes. */
    fen_object *free_list;
    fen_roots *roots;
    fen_parked_roots *parked;
} fen_heap;

void fen_heap_init(fen_heap *heap, fen_object *storage, size_t capacity);
void fen_heap_collect(fen_heap *heap);
/* Payload is uninitialized. Before allocation or publication, initialize every
 * field that tracing or any consumer (including equality) can inspect. */
fen_object *fen_heap_alloc_full(fen_heap *heap, uint32_t tag, uint8_t pointer_mask);
/* Returns NULL on exhaustion after collection. All fields are zero on return. */
fen_object *fen_heap_alloc(fen_heap *heap, uint32_t tag, uint8_t pointer_mask);

#endif
