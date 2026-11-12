/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Independent TC0-A pure-call candidate (schemas /1 and /2) for a Solo5 guest:
 * calls, closures, tuples, datatypes, match, bytes, eq, checked I64, emit.
 * No oracle imports, no expected traces. */
#ifndef FENRIR_PC_MACHINE_H
#define FENRIR_PC_MACHINE_H
#include <stdint.h>
#include <stddef.h>
#define PC_MAX_OPERANDS 16
#define PC_MAX_FRAMES 1024
enum pc_tag { PC_UNIT,PC_BOOL,PC_INT,PC_BYTES,PC_VAR,PC_LET,PC_IF,PC_LAMBDA,PC_APPLY,PC_CALL,
              PC_PRIM,PC_EMIT,PC_TUPLE,PC_PROJECT,PC_CONSTRUCT,PC_MATCH };
enum pc_op { PC_NONE,PC_ADD,PC_SUB,PC_MUL,PC_DIV,PC_NEG,PC_LT,PC_LE,PC_GT,PC_GE,PC_NOT,PC_EQ,
             PC_BYTES_LENGTH,PC_BYTES_INDEX,PC_BYTES_CONCAT };
struct pc_arm { const char *constructor; unsigned binder_count; const uint64_t *binders; int body; };
/* Validated artifact data. text: bytes hex, emit label or datatype; text2: constructor;
 * binding: var/let binder or lambda parameter; index: projection or callee function. */
struct pc_node {
    int tag; uint64_t id; int op; uint64_t binding; int64_t integer; const char *text,*text2;
    unsigned index,child_count; const int *children;
    unsigned arm_count; const struct pc_arm *arms;
    unsigned free_count; const uint64_t *free;
};
struct pc_function { uint64_t parameter; int body; };
struct pc_program {
    const struct pc_node *nodes; unsigned node_count;
    const struct pc_function *functions; unsigned function_count,entry;
    int input_tag; int64_t input_integer; /* PV_UNIT, PV_BOOL or PV_INT */
};
enum pc_vtag { PV_UNIT,PV_BOOL,PV_INT,PV_BYTES,PV_TUPLE,PV_DATA,PV_CLOSURE };
struct pc_env;
/* Immutable once built. bytes: text is hex, count its length. data: text type, constructor. */
struct pc_value {
    int tag; int64_t integer; const char *text,*constructor; unsigned count;
    const struct pc_value **fields; int code; const struct pc_env *captures;
};
struct pc_env { uint64_t id; const struct pc_value *value; const struct pc_env *parent; };
enum pc_control { PC_EVAL,PC_VALUE,PC_READY,PC_UNWIND,PC_JOIN,PC_TERMINATE,PC_TERMINAL };
enum pc_trap { PC_NO_TRAP,PC_OVERFLOW,PC_DIVZERO,PC_BOUNDS };
enum pc_frame_kind { PF_LET,PF_IF,PF_MATCH,PF_RETURN,PF_COLLECT };
enum pc_rule { PR_DISPATCH,PR_READY,PR_LET_RETURN,PR_IF_RETURN,PR_MATCH_RETURN,PR_RETURN_RETURN,
               PR_COLLECT_RETURN,PR_UNWIND_FRAME,PR_VALUE,PR_UNWIND,PR_JOIN,PR_TERMINATE };
enum pc_machine_site { PS_ROOT_JOIN_ENTRY,PS_JOIN,PS_TERMINATE };
enum pc_event_kind { PE_INVOKE,PE_EMIT,PE_COMMIT,PE_SCOPE_EXIT,PE_TASK_TERMINATION };
struct pc_event { int kind; uint64_t node; const char *label; const struct pc_value *value; int trap; };
struct pc_sample {
    uint64_t epoch,node; int machine_site,rule,after; unsigned depth,event_count;
    struct pc_event events[3];
};
struct pc_frame {
    int kind,node,tail; const struct pc_env *env; unsigned next;
    const struct pc_value *values[PC_MAX_OPERANDS];
};
struct pc_machine {
    const struct pc_program *program;
    int control,node,tail,trap,reverse_operands,wrap_overflow;
    const struct pc_value *value; const struct pc_env *env;
    const struct pc_value *ready[PC_MAX_OPERANDS];
    unsigned depth; uint64_t epoch;
    struct pc_frame frames[PC_MAX_FRAMES];
};
/* 1 ok; -1 invalid program/state or exhausted guest memory (infrastructure, never a trap). */
int pc_init(struct pc_machine *,const struct pc_program *,int reverse_operands,int wrap_overflow);
int pc_step(struct pc_machine *,struct pc_sample *);
/* Canonical-shaped sample JSON. Returns bytes written (excluding NUL) or 0 on cap/shape error. */
size_t pc_format_sample(const struct pc_sample *,char *,size_t);
#endif
