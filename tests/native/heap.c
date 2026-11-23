#include "../../runtime/native/heap.h"
#ifdef FENRIR_SOLO5_TEST
#include <solo5.h>
#define CHECK(test) do { if (!(test)) return SOLO5_EXIT_FAILURE; } while (0)
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#else
#include <assert.h>
#define CHECK(test) assert(test)
int main(void) {
#endif

    fen_heap heap;
    fen_object storage[4];
    fen_heap_init(&heap, storage, 4);
    fen_object *root = fen_heap_alloc(&heap, 1, 3);
    fen_roots outer = {NULL, &root, 1};
    heap.roots = &outer;
    fen_object *child = fen_heap_alloc(&heap, 2, 1);
    root->fields[0] = root->fields[1] = (uintptr_t)child;
    child->fields[0] = (uintptr_t)root;
    fen_object *pinned = fen_heap_alloc(&heap, 3, 0);
    fen_roots inner = {&outer, &pinned, 1};
    heap.roots = &inner;
    fen_object *garbage = fen_heap_alloc(&heap, 4, 0);
    /* This scalar happens to contain an address. It must not retain garbage. */
    root->fields[2] = (uintptr_t)garbage;
    garbage->fields[7] = 99;
    fen_object *fresh = fen_heap_alloc(&heap, 5, 0);
    CHECK(fresh == garbage && fresh->fields[7] == 0);
    root->fields[1] = (uintptr_t)fresh;
    CHECK(!fen_heap_alloc(&heap, 6, 0));
    CHECK(root->tag == 1 && child->tag == 2 && pinned->tag == 3);
    heap.roots = &outer;
    CHECK(fen_heap_alloc(&heap, 7, 0) == pinned);
    heap.roots = NULL;
    fen_heap_collect(&heap);
    CHECK(heap.free_list == NULL && heap.used == 0);
    for (unsigned i = 0; i < 4; ++i) CHECK(!storage[i].live);
    /* Collect before capacity is reached, with one hole on either side
     * of a pinned object. Reuse both spaces without moving the survivor. */
    fen_heap_alloc(&heap, 1, 0);
    pinned = fen_heap_alloc(&heap, 2, 0);
    fen_heap_alloc(&heap, 3, 0);
    fen_roots only = {NULL, &pinned, 1};
    heap.roots = &only;
    fen_heap_collect(&heap);
    CHECK(heap.used == 2 && pinned == &storage[1] && pinned->tag == 2);
    CHECK(fen_heap_alloc(&heap, 4, 0) == storage);
    CHECK(fen_heap_alloc(&heap, 5, 0) == &storage[2]);
    CHECK(fen_heap_alloc(&heap, 6, 0) == &storage[3]);
    /* A fully initialized eight-field object traces its final field too. */
    fen_heap_init(&heap, storage, 2);
    root = fen_heap_alloc_full(&heap, 9, 128);
    CHECK(root && root->tag == 9 && root->pointer_mask == 128);
    for (unsigned i = 0; i < 8; ++i) root->fields[i] = 0;
    heap.roots = &outer;
    child = fen_heap_alloc(&heap, 10, 0);
    CHECK(child);
    root->fields[7] = (uintptr_t)child;
    CHECK(!fen_heap_alloc_full(&heap, 0, 0));
    CHECK(child->tag == 10);
    fen_heap_init(&heap, NULL, 0);
    CHECK(!fen_heap_alloc(&heap, 0, 0));
    return 0;
}
