struct test_case { fen_object *head; uintptr_t expected[4]; };
#include "corpus.h"
struct reply { fen_object *result; uintptr_t status; };
extern struct reply http_response(fen_object *);
struct outcome http_benchmark_entry(int64_t rounds) {
    int64_t completed = 0;
    for (int64_t n = 0; n < rounds; ++n) {
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
            fen_object args = {.fields={(uintptr_t)cases[i].head, 1}, .live=FEN_IMAGE_OBJECT};
            struct reply reply = http_response(&args);
            if (reply.status) return (struct outcome){0, 1};
            for (unsigned j = 0; j < 4; ++j) {
                if (reply.result->fields[j] != cases[i].expected[j]) return (struct outcome){0, 1};
            }
            ++completed;
        }
    }
    return (struct outcome){completed, 0};
}
