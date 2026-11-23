/* Host-only driver for one untimed search round over the generated corpus.h. */
#include <stdio.h>
#define REPRESENTATION_DIAGNOSTICS
static unsigned max_switch_width;
#define REPRESENTATION_OBSERVE_SWITCH(rear) do { \
    unsigned width = 0; \
    for (const queue_node *q = (rear); q; q = q->next) ++width; \
    if (width > max_switch_width) max_switch_width = width; \
} while (0)
#include "reference-representation.c"

void representation_observe(unsigned index, unsigned result, unsigned steps,
                            unsigned cells, unsigned copies) {
    static unsigned previous_copies;
    printf("%u %u %u %u %u\n", index, steps, cells, copies - previous_copies, max_switch_width);
    max_switch_width = 0;
    previous_copies = copies;
    (void)result;
}

int main(void) {
    struct outcome_value result = fenrir_entry(1);
    return result.status || result.value != (int64_t)(sizeof prepared / sizeof *prepared);
}
