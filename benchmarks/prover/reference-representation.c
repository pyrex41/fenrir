/* Representation control for the prover benchmark.
 *
 * Formulae are immutable pointer graphs and pending work is an immutable
 * singly-linked queue.  Appending copies the queue cells, matching the
 * algebraic Queue/More representation used by the Fenrir implementation.
 * This file intentionally keeps the same tableau order and proof protocol as
 * reference.c.  It is an experiment, not the production reference.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

enum { REPRESENTATION_SLOT_BYTES = 80 };
#define CORPUS_LIMITS_ONLY
#include "corpus.h"
#undef CORPUS_LIMITS_ONLY

typedef struct {
    char op[MAX_FORMULA];
    unsigned right[MAX_FORMULA];
} formula;
typedef enum { PROOF, COUNTERMODEL, EXHAUSTED, INVALID } outcome;
typedef struct {
    unsigned fuel, model, cursor;
    char generated[MAX_PROOF];
    const char *supplied;
    size_t length;
} traversal;
typedef struct {
    formula f;
    const char *proof;
    unsigned budget, nodes, model;
    outcome expected;
} test_case;
#include "corpus.h"

typedef struct formula_node formula_node;
struct formula_node {
    char op;
    formula_node *left;
    formula_node *right;
};
typedef struct queue_node queue_node;
struct queue_node {
    bool sign;
    const formula_node *formula;
    const queue_node *next;
};
typedef union {
    formula_node node;
    unsigned char slot[REPRESENTATION_SLOT_BYTES];
} formula_slot;
typedef union {
    queue_node node;
    unsigned char slot[REPRESENTATION_SLOT_BYTES];
} queue_slot;
_Static_assert(sizeof(formula_slot) == 80 && sizeof(queue_slot) == 80, "managed cell stride");
enum { REPRESENTATION_FORMULA_CAP = (sizeof cases / sizeof *cases) * MAX_FORMULA,
       REPRESENTATION_QUEUE_CAP = 65536 };
static formula_slot formula_pool[REPRESENTATION_FORMULA_CAP];
static queue_slot queue_pool[REPRESENTATION_QUEUE_CAP];
static unsigned formula_used, queue_used;
#ifdef REPRESENTATION_DIAGNOSTICS
uint64_t representation_formula_allocations;
uint64_t representation_queue_allocations;
uint64_t representation_queue_cells_copied;
#define COUNT(name, amount) (representation_##name += (amount))
#else
#define COUNT(name, amount) ((void)0)
#endif

static formula_node *make_formula(const formula *f, unsigned index) {
    const char op = f->op[index];
    formula_node *left = NULL, *right = NULL;
    if (op == '!' || op < 'a' || op > 'z') left = make_formula(f, index + 1);
    if (op != '!' && (op < 'a' || op > 'z')) right = make_formula(f, f->right[index]);
    // The Fenrir image interns structurally identical immutable constants.
    for (unsigned i = 0; i < formula_used; ++i) {
        formula_node *old = &formula_pool[i].node;
        if (old->op == op && old->left == left && old->right == right) return old;
    }
    if (formula_used == REPRESENTATION_FORMULA_CAP) __builtin_trap();
    formula_node *node = &formula_pool[formula_used++].node;
    COUNT(formula_allocations, 1);
    node->op = op;
    node->left = left;
    node->right = right;
    return node;
}

static queue_node *new_queue_cell(bool sign, const formula_node *formula,
                                  const queue_node *next) {
    if (queue_used == REPRESENTATION_QUEUE_CAP) __builtin_trap();
    queue_slot *slot = &queue_pool[queue_used++];
    queue_node *node = &slot->node;
    COUNT(queue_allocations, 1);
    node->sign = sign;
    node->formula = formula;
    node->next = next;
    return node;
}

/* formula.fen copies the rear spine two cells at a time; the unconsumed
 * front and the suffix remain shared across branches. */
static const queue_node *append_suffix(const queue_node *rear, const queue_node *suffix) {
    if (!rear) return suffix;
    const queue_node *second = rear->next;
    if (second) {
        suffix = append_suffix(second->next, suffix);
        suffix = new_queue_cell(second->sign, second->formula, suffix);
        COUNT(queue_cells_copied, 1);
    }
    COUNT(queue_cells_copied, 1);
    return new_queue_cell(rear->sign, rear->formula, suffix);
}

static const queue_node *append_one(const queue_node *rear, bool sign,
                                    const formula_node *formula) {
    return append_suffix(rear, new_queue_cell(sign, formula, NULL));
}

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

static outcome visit(const queue_node *queue, const queue_node *rear, unsigned pos, unsigned neg,
                     traversal *t) {
    for (;;) {
        if (!queue && rear) {
            queue = rear;
            rear = NULL;
        }
        if (!t->supplied) {
            if (!t->fuel) return EXHAUSTED;
            --t->fuel;
        }
        if (!queue) {
            t->model = pos;
            return t->supplied ? INVALID : COUNTERMODEL;
        }
        bool sign = queue->sign;
        const formula_node *f = queue->formula;
        queue = queue->next;
        char op = f->op;
        if (op >= 'a' && op <= 'z') {
            unsigned bit = 1u << (op - 'a');
            if ((sign ? neg : pos) & bit) return rule(t, 'x') ? PROOF : INVALID;
            if (sign) pos |= bit;
            else neg |= bit;
        } else {
            /* The next obligations follow the current rear. When the front
             * is exhausted, both children can share the rear as their front. */
            if (!queue) {
#ifdef REPRESENTATION_OBSERVE_SWITCH
                if (op != '!' && ((op == '&') == sign)) REPRESENTATION_OBSERVE_SWITCH(rear);
#endif
                queue = rear;
                rear = NULL;
            }
            bool left_sign = sign;
            if (op == '>' || op == '!') left_sign = !sign;
            if (op == '!') {
                rear = append_one(rear, left_sign, f->left);
            } else {
                if ((op == '&') != sign) {
                    if (!rule(t, 'b')) return INVALID;
                    const queue_node *branch = append_one(rear, left_sign, f->left);
                    outcome first = visit(queue, branch, pos, neg, t);
                    if (first != PROOF) return first;
                    rear = append_one(rear, sign, f->right);
                    continue;
                }
                queue_node *suffix = new_queue_cell(sign, f->right, NULL);
                suffix = new_queue_cell(left_sign, f->left, suffix);
                rear = append_suffix(rear, suffix);
            }
        }
        if (!rule(t, 's')) return INVALID;
    }
}

typedef struct {
    formula_node *root;
    const char *proof;
    unsigned budget, nodes, model;
    outcome expected;
} representation_case;

static representation_case prepared[sizeof cases / sizeof *cases];
static bool prepared_once;

static void prepare(void) {
    if (prepared_once) return;
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; ++i) {
        prepared[i].root = make_formula(&cases[i].f, 0);
        prepared[i].proof = cases[i].proof;
        prepared[i].budget = cases[i].budget;
        prepared[i].nodes = cases[i].nodes;
        prepared[i].model = cases[i].model;
        prepared[i].expected = cases[i].expected;
    }
    prepared_once = true;
}

void representation_prepare(void) { prepare(); }
void representation_reset_queue(void) { queue_used = 0; }

static outcome evaluate_formula(const formula_node *root, traversal *t) {
    queue_node initial;
    initial.sign = false;
    initial.formula = root;
    initial.next = NULL;
    outcome result = visit(&initial, NULL, 0, 0, t);
    return t->supplied && t->cursor != t->length ? INVALID : result;
}

static int64_t check_mutations(void) {
    int64_t rejected = 0;
    for (unsigned i = 0; i < sizeof prepared / sizeof *prepared; ++i) {
        const representation_case *c = &prepared[i];
        representation_reset_queue();
        char tape[MAX_PROOF];
        size_t size = 0;
        while (c->proof[size]) {
            if (size + 1 >= sizeof tape) return -1;
            tape[size] = c->proof[size];
            ++size;
        }
        if (!size) return -1;
        traversal t;
        t.fuel = 0; t.model = 0; t.cursor = 0;
        t.generated[0] = 0; t.supplied = tape; t.length = size - 1;
        rejected += evaluate_formula(c->root, &t) == INVALID;
        representation_reset_queue();
        tape[size] = 'x'; t.cursor = 0; t.length = size + 1;
        rejected += evaluate_formula(c->root, &t) == INVALID;
        representation_reset_queue();
        tape[size - 1] = '?'; t.cursor = 0; t.length = size;
        rejected += evaluate_formula(c->root, &t) == INVALID;
    }
    return rejected;
}

struct outcome_value { int64_t value; uint64_t status; };
struct outcome_value fenrir_entry(int64_t rounds) {
    prepare();
    if (!rounds && checking) return (struct outcome_value){check_mutations(), 0};
    int64_t passed = 0;
    for (int64_t round = 0; round < rounds; ++round) {
        for (unsigned i = 0; i < sizeof prepared / sizeof *prepared; ++i) {
            const representation_case *c = &prepared[i];
            representation_reset_queue();
            size_t length = 0;
            while (c->proof[length]) ++length;
            traversal t;
            t.fuel = c->budget; t.model = 0; t.cursor = 0;
            t.generated[0] = 0; t.supplied = checking ? c->proof : NULL;
            t.length = length;
            outcome actual = evaluate_formula(c->root, &t);
#ifdef REPRESENTATION_DIAGNOSTICS
            extern void representation_observe(unsigned, unsigned, unsigned, unsigned, unsigned);
            representation_observe(i, actual, checking ? t.cursor : c->budget - t.fuel,
                                   queue_used + 1, (unsigned)representation_queue_cells_copied);
#endif
            if (actual != c->expected) continue;
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
