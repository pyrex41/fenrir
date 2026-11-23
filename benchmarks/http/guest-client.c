// One in-flight call under the server's router lock. Both ARM64 endpoints are little-endian.
#include "heap.h"
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>

typedef struct { fen_object *result; uintptr_t status; } outcome;
static void transfer(int writing, void *buffer, size_t n) {
    char *p = buffer;
    while (n) {
        ssize_t count = writing ? write(STDOUT_FILENO, p, n) : read(STDIN_FILENO, p, n);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) _Exit(2);
        p += count;
        n -= (size_t)count;
    }
}
outcome http_response(fen_object *args) {
    static fen_object reply;
    fen_object *head = (fen_object *)args->fields[0];
    uint32_t frame[] = {(uint32_t)head->fields[0], (uint32_t)args->fields[1]};
    transfer(1, frame, sizeof frame);
    transfer(1, head + 1, frame[0]);
    transfer(0, reply.fields, 4*sizeof(uint64_t));
    return (outcome){&reply, 0};
}
