/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Independent bounded arithmetic-demo candidate. No oracle imports. */
#ifndef FENRIR_NA_MACHINE_H
#define FENRIR_NA_MACHINE_H
#include <stdint.h>
#define NA_MAX_NODES 100
#define NA_MAX_FRAMES 40
#define NA_MAX_BINDINGS 128
struct na_value { int tag; int64_t integer; }; /* Unit0 Bool1 I642 */
struct na_node {
    int tag; uint64_t id, binding; int op; struct na_value literal;
    const char *label; unsigned count; int child[3];
};
enum na_tag { NA_UNIT,NA_BOOL,NA_INT,NA_VAR,NA_LET,NA_IF,NA_PRIM,NA_EMIT };
enum na_op { NA_ADD,NA_SUB,NA_MUL,NA_DIV,NA_NEG,NA_LT,NA_LE,NA_GT,NA_GE,NA_NOT };
enum na_control { NA_EVAL,NA_VALUE,NA_READY,NA_UNWIND,NA_JOIN,NA_TERMINATE,NA_TERMINAL };
enum na_trap { NA_NO_TRAP,NA_OVERFLOW,NA_DIVZERO };
enum na_frame_kind { NA_COLLECT,NA_BIND,NA_BRANCH };
enum na_rule { NA_DISPATCH,NA_READY_RULE,NA_COLLECT_RETURN,NA_LET_RETURN,NA_IF_RETURN,
               NA_UNWIND_FRAME,NA_VALUE_RULE,NA_UNWIND_RULE,NA_JOIN_RULE,NA_TERMINATE_RULE };
enum na_machine_site { NA_ROOT_ENTRY,NA_JOIN_SITE,NA_TERMINATE_SITE };
enum na_event_kind { NA_INVOKE,NA_EMISSION,NA_COMMIT,NA_SCOPE_EXIT,NA_TASK_TERMINATION };
struct na_event { int kind; uint64_t node; const char *label; struct na_value value; int trap; };
struct na_sample {
    uint64_t epoch, node; int machine_site, rule, after; unsigned depth, event_count;
    struct na_event events[3];
};
struct na_binding { uint64_t id; struct na_value value; int parent; };
struct na_frame { int kind,node,env; unsigned next,count; int children[2]; struct na_value values[2]; };
struct na_machine {
    const struct na_node *nodes; unsigned node_count,depth,binding_count;
    int control,node,env,trap,reverse_operands;
    uint64_t epoch;
    struct na_value value,values[2]; unsigned value_count;
    struct na_frame frames[NA_MAX_FRAMES];
    struct na_binding bindings[NA_MAX_BINDINGS];
};
/* pure:1 result, 0 modeled trap, -1 invalid state/infrastructure */
int na_pure(int op,const struct na_value *values,unsigned count,struct na_value *result,int *trap);
int na_init(struct na_machine *,const struct na_node *,unsigned,unsigned,uint64_t,struct na_value,int);
/* step:1 transition, 0 terminal, -1 invalid state/bound; never fabricate trap */
int na_site(const struct na_machine *,struct na_sample *); /* nonmutating current boundary */
int na_step(struct na_machine *,struct na_sample *);
#endif
