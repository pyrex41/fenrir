#include "heap.h"

#ifdef FEN_PROFILE_HEAP
uint64_t fen_profile_allocations, fen_profile_collections, fen_profile_collection_ns;
extern uint64_t fen_profile_clock_ns(void);
#endif

void fen_heap_init(fen_heap *heap, fen_object *storage, size_t capacity) {
    *heap = (fen_heap){.storage = storage, .capacity = capacity};
}

static void mark(fen_object **pending, fen_object *obj) {
    if (obj && obj->live != FEN_IMAGE_OBJECT && !obj->marked) {
        obj->marked = 1;
        if (obj->pointer_mask) {
            obj->next = *pending;
            *pending = obj;
        }
    }
}

static void mark_frames(fen_object **pending, fen_roots *frame) {
    for (; frame; frame = frame->previous) {
        for (size_t i = 0; i < frame->count; ++i)
            mark(pending, frame->slots[i]);
    }
}

void fen_heap_collect(fen_heap *heap) {
#ifdef FEN_PROFILE_HEAP
    uint64_t start = fen_profile_clock_ns();
    ++fen_profile_collections;
#endif
    fen_object *pending = NULL;
    mark_frames(&pending, heap->roots);
    for (fen_parked_roots *task = heap->parked; task; task = task->next)
        mark_frames(&pending, task->frames);
    while (pending) {
        fen_object *obj = pending;
        pending = obj->next;
        for (unsigned mask = obj->pointer_mask; mask; mask &= mask - 1) {
            unsigned field = (unsigned)__builtin_ctz(mask);
            mark(&pending, (fen_object *)obj->fields[field]);
        }
    }
    heap->free_list = NULL;
    /* A dead suffix becomes contiguous allocation space. Only holes below
     * the last surviving object need free-list links. */
    while (heap->used && !heap->storage[heap->used - 1].marked) {
        heap->storage[--heap->used].live = 0;
    }
    for (size_t i = heap->used; i > 0; --i) {
        fen_object *slot = &heap->storage[i - 1];
        if (slot->marked) {
            slot->marked = 0;
            slot->next = NULL;
        } else {
            slot->live = 0;
            slot->next = heap->free_list;
            heap->free_list = slot;
        }
    }
#ifdef FEN_PROFILE_HEAP
    fen_profile_collection_ns += fen_profile_clock_ns() - start;
#endif
}

static inline fen_object *take_slot(fen_heap *heap) {
    if (heap->used == heap->capacity && !heap->free_list) fen_heap_collect(heap);
    fen_object *slot;
    if (heap->free_list) {
        slot = heap->free_list;
        heap->free_list = slot->next;
    } else if (heap->used < heap->capacity) {
        slot = &heap->storage[heap->used++];
    } else {
        return NULL;
    }
#ifdef FEN_PROFILE_HEAP
    ++fen_profile_allocations;
#endif
    return slot;
}

fen_object *fen_heap_alloc_full(fen_heap *heap, uint32_t tag, uint8_t pointer_mask) {
    fen_object *slot = take_slot(heap);
    if (!slot) return NULL;
    slot->next = NULL;
    slot->tag = tag;
    slot->pointer_mask = pointer_mask;
    slot->live = 1;
    slot->marked = 0;
    return slot;
}

fen_object *fen_heap_alloc(fen_heap *heap, uint32_t tag, uint8_t pointer_mask) {
    fen_object *slot = take_slot(heap);
    if (!slot) return NULL;
    *slot = (fen_object){.tag = tag, .pointer_mask = pointer_mask, .live = 1};
    return slot;
}
