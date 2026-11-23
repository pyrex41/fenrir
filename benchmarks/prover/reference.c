/* Bounded tableau reference for the Solo5 prover corpus. Formula nodes use
 * prefix token offsets. One signed queue entry fits in a signed 16-bit word. */
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#define CORPUS_LIMITS_ONLY
#include "corpus.h"
#undef CORPUS_LIMITS_ONLY
typedef struct {
    char op[MAX_FORMULA];
    unsigned right[MAX_FORMULA];
} formula;
typedef struct {
    int16_t terms[MAX_FORMULA];
    unsigned head, end;
} queue;
typedef enum { PROOF, COUNTERMODEL, EXHAUSTED, INVALID } outcome;
typedef struct {
    unsigned fuel, model, cursor;
    char generated[MAX_PROOF];
    const char *supplied;
    size_t length;
} traversal;

static bool rule(traversal *t, char op) {
    if (t->cursor == MAX_PROOF) return false;
    if (t->supplied) {
        if (t->cursor >= t->length || t->supplied[t->cursor] != op) return false;
    } else {
        t->generated[t->cursor] = op;
    }
    ++t->cursor;
    return true;
}

static int16_t term(unsigned index, bool sign) {
    return sign ? (int16_t)(index + 1) : -(int16_t)(index + 1);
}

static outcome visit(const formula *f, queue *q, unsigned pos, unsigned neg, traversal *t) {
    for (;;) {
        if (!t->supplied) {
            if (!t->fuel) return EXHAUSTED;
            --t->fuel;
        }
        if (q->head == q->end) {
            t->model = pos;
            return t->supplied ? INVALID : COUNTERMODEL;
        }
        int entry = q->terms[q->head++];
        bool sign = entry > 0;
        unsigned i = (unsigned)(sign ? entry : -entry) - 1;
        char op = f->op[i];
        if (op >= 'a' && op <= 'z') {
            unsigned bit = 1u << (op - 'a');
            if ((sign ? neg : pos) & bit) return rule(t, 'x') ? PROOF : INVALID;
            if (sign) pos |= bit;
            else neg |= bit;
        } else {
            /* Each node in the input tree is enqueued at most once per path. */
            int16_t left = term(i + 1, op == '>' || op == '!' ? !sign : sign);
            if (op == '!') {
                q->terms[q->end++] = left;
            } else {
                int16_t right = term(f->right[i], sign);
                if ((op == '&') != sign) {
                    if (!rule(t, 'b')) return INVALID;
                    queue branch = *q;
                    branch.terms[branch.end++] = left;
                    outcome first = visit(f, &branch, pos, neg, t);
                    if (first != PROOF) return first;
                    q->terms[q->end++] = right;
                    continue;
                }
                q->terms[q->end++] = left;
                q->terms[q->end++] = right;
            }
        }
        if (!rule(t, 's')) return INVALID;
    }
}

static outcome evaluate_formula(const formula *f, traversal *t) {
    queue pending;
    pending.terms[0] = -1;
    pending.head = 0;
    pending.end = 1;
    outcome result = visit(f, &pending, 0, 0, t);
    return t->supplied && t->cursor != t->length ? INVALID : result;
}

typedef struct {
    formula f;
    const char *proof;
    unsigned budget, nodes, model;
    outcome expected;
} test_case;
#include "corpus.h"

/* Preflight the checker over the same mutations used by check-certificates.py.
 * A zero-round invocation is reserved for this untimed correctness check. */
static int64_t check_mutations(void) {
    int64_t rejected = 0;
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; ++i) {
        const test_case *c = &cases[i];
        char tape[MAX_PROOF];
        size_t size = 0;
        while (c->proof[size]) {
            if (size + 1 >= sizeof tape) return -1;
            tape[size] = c->proof[size];
            ++size;
        }
        if (!size) return -1;
        traversal t;
        t.cursor = 0;
        t.supplied = tape;
        t.length = size - 1;
        rejected += evaluate_formula(&c->f, &t) == INVALID;
        tape[size] = 'x';
        t.cursor = 0;
        t.length = size + 1;
        rejected += evaluate_formula(&c->f, &t) == INVALID;
        tape[size-1] = '?';
        t.cursor = 0;
        t.length = size;
        rejected += evaluate_formula(&c->f, &t) == INVALID;
    }
    return rejected;
}

struct outcome_value { int64_t value; uint64_t status; };
struct outcome_value fenrir_entry(int64_t rounds) {
    if (!rounds && checking) return (struct outcome_value){check_mutations(), 0};
    int64_t passed = 0;
    for (int64_t round = 0; round < rounds; ++round) {
        for (unsigned i = 0; i < sizeof cases / sizeof *cases; ++i) {
            const test_case *c = &cases[i];
            size_t length = 0;
            while (c->proof[length]) ++length;
            traversal t;
            t.fuel = c->budget;
            t.cursor = 0;
            t.length = length;
            t.supplied = checking ? c->proof : NULL;
            if (evaluate_formula(&c->f, &t) != c->expected) continue;
            if (!checking && c->budget - t.fuel != c->nodes) continue;
            if (c->expected == COUNTERMODEL && t.model != c->model) continue;
            if (c->expected == PROOF && !checking) {
                if (length != t.cursor) continue;
                size_t j = 0;
                while (j < length && t.generated[j] == c->proof[j]) ++j;
                if (j < length) continue;
            }
            ++passed;
        }
    }
    return (struct outcome_value){passed, 0};
}
