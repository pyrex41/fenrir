/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Independent TC0-A pure-call candidate (schemas /1 and /2) for a Solo5 guest:
 * calls, closures, tuples, datatypes, match, bytes, eq, checked I64, emit; and TC1
 * user effects: handle, perform, and explicit one-shot resume/discontinue
 * (spec/tc1/EFFECTS.md); and TC1-D1 durable effects: a perform of a durable effect with
 * no active handler stops the machine in HostWait until the host replies
 * (spec/tc1/DURABLE.md). TC1-D1 fields are appended; legacy lowerings set them to zero
 * and legacy control, rule and event numbers are unchanged.
 * No oracle imports, no expected traces. */
#ifndef FENRIR_PC_MACHINE_H
#define FENRIR_PC_MACHINE_H
#include <stdint.h>
#include <stddef.h>
#define PC_MAX_OPERANDS 16
#define PC_MAX_FRAMES 1024
enum pc_tag { PC_UNIT,PC_BOOL,PC_INT,PC_BYTES,PC_VAR,PC_LET,PC_IF,PC_LAMBDA,PC_APPLY,PC_CALL,
              PC_PRIM,PC_EMIT,PC_TUPLE,PC_PROJECT,PC_CONSTRUCT,PC_MATCH,
              PC_HANDLE,PC_PERFORM,PC_RESUME,PC_DISCONTINUE };
enum pc_op { PC_NONE,PC_ADD,PC_SUB,PC_MUL,PC_DIV,PC_NEG,PC_LT,PC_LE,PC_GT,PC_GE,PC_NOT,PC_EQ,
             PC_BYTES_LENGTH,PC_BYTES_INDEX,PC_BYTES_CONCAT };
struct pc_arm { const char *constructor; unsigned binder_count; const uint64_t *binders; int body; };
/* Validated artifact data. text: bytes hex, emit label, datatype or effect; text2:
 * constructor or operation; binding: var/let binder, lambda parameter or the
 * resumption named by resume/discontinue; index: projection or callee function.
 * A handle's clauses are its arms: constructor is the operation name and binders are
 * the argument binder, then the resumption binder when the clause names one. */
struct pc_node {
    int tag; uint64_t id; int op; uint64_t binding; int64_t integer; const char *text,*text2;
    unsigned index,child_count; const int *children;
    unsigned arm_count; const struct pc_arm *arms;
    unsigned free_count; const uint64_t *free;
    /* TC1-D1: for a perform of a durable effect (integer 1), its result type as a
     * descriptor (below); 0 otherwise. */
    const char *type;
};
/* TC1-D1 type descriptors: U Unit, B Bool, I I64, Y Bytes, K TrapCode, T<n> then n
 * descriptors (a tuple, n 1..8), D<index>; a declared datatype of the program. */
struct pc_constructor { const char *name; unsigned field_count; const char *const *fields; };
struct pc_datatype { const char *name; unsigned constructor_count; const struct pc_constructor *constructors; };
struct pc_function { uint64_t parameter; int body; };
struct pc_program {
    const struct pc_node *nodes; unsigned node_count;
    const struct pc_function *functions; unsigned function_count,entry;
    int input_tag; int64_t input_integer; /* PV_UNIT, PV_BOOL or PV_INT, or PC_INPUT_VALUE */
    /* TC1-D1: with input_tag PC_INPUT_VALUE the input is input_value, a canonical JSON value
     * of type input_type, parsed and checked at pc_init. */
    const char *input_value,*input_type;
    const struct pc_datatype *datatypes; unsigned datatype_count;
};
#define PC_INPUT_VALUE 100
enum pc_vtag { PV_UNIT,PV_BOOL,PV_INT,PV_BYTES,PV_TUPLE,PV_DATA,PV_CLOSURE,PV_RESUMPTION };
struct pc_env;
struct pc_segment;
/* Immutable once built. bytes: text is hex, count its length. data: text type, constructor.
 * resumption: segment is the suspended continuation, captures the perform site's bindings. */
struct pc_value {
    int tag; int64_t integer; const char *text,*constructor; unsigned count;
    const struct pc_value **fields; int code; const struct pc_env *captures;
    const struct pc_segment *segment;
};
struct pc_env { uint64_t id; const struct pc_value *value; const struct pc_env *parent; };
enum pc_control { PC_EVAL,PC_VALUE,PC_READY,PC_UNWIND,PC_JOIN,PC_TERMINATE,PC_TERMINAL,PC_ABANDON,PC_HOSTWAIT };
enum pc_trap { PC_NO_TRAP,PC_OVERFLOW,PC_DIVZERO,PC_BOUNDS };
enum pc_frame_kind { PF_LET,PF_IF,PF_MATCH,PF_RETURN,PF_COLLECT,
                     PF_HANDLE,PF_CLAUSE,PF_CLAUSE_EXIT,PF_RESUME,PF_DISCONTINUE };
enum pc_rule { PR_DISPATCH,PR_READY,PR_LET_RETURN,PR_IF_RETURN,PR_MATCH_RETURN,PR_RETURN_RETURN,
               PR_COLLECT_RETURN,PR_UNWIND_FRAME,PR_VALUE,PR_UNWIND,PR_JOIN,PR_TERMINATE,
               PR_HANDLE_RETURN,PR_CLAUSE_RETURN,PR_CLAUSE_EXIT_RETURN,PR_RESUME_RETURN,
               PR_DISCONTINUE_RETURN,PR_ABANDON_FRAME,PR_HOST_REPLY };
enum pc_machine_site { PS_ROOT_JOIN_ENTRY,PS_JOIN,PS_TERMINATE };
enum pc_event_kind { PE_INVOKE,PE_EMIT,PE_COMMIT,PE_SCOPE_EXIT,PE_TASK_TERMINATION,PE_HOST_REQUEST,PE_HOST_REPLY };
/* label: emit label, or a host request's effect; operation: a host request's operation;
 * seq: a host request's or reply's sequence number. */
struct pc_event { int kind; uint64_t node; const char *label; const struct pc_value *value; int trap; const char *operation; uint64_t seq; };
struct pc_sample {
    uint64_t epoch,node; int machine_site,rule,after; unsigned depth,event_count;
    struct pc_event events[3];
};
/* segment: for a clause frame, the continuation suspended while its clause runs. */
struct pc_frame {
    int kind,node,tail; const struct pc_env *env; unsigned next;
    const struct pc_segment *segment;
    const struct pc_value *values[PC_MAX_OPERANDS];
};
/* Frames from a selected handler (first) out to a perform site (last). */
struct pc_segment { unsigned count; const struct pc_frame *frames; };
struct pc_machine {
    const struct pc_program *program;
    int control,node,tail,trap,reverse_operands,wrap_overflow;
    const struct pc_value *value; const struct pc_env *env;
    const struct pc_value *ready[PC_MAX_OPERANDS];
    unsigned depth; uint64_t epoch;
    struct pc_frame frames[PC_MAX_FRAMES];
    uint64_t requests; /* TC1-D1: host requests made so far */
};
/* 1 ok; -1 invalid program/state or exhausted guest memory (infrastructure, never a trap). */
int pc_init(struct pc_machine *,const struct pc_program *,int reverse_operands,int wrap_overflow);
/* The same start at another function with a given input, for a host that runs one
 * function for each request (backends/solo5/remote/serve.c). The input must outlive the
 * run and is not copied; the program's own entry and input are not used. */
int pc_start(struct pc_machine *,const struct pc_program *,unsigned function,const struct pc_value *input);
/* A unit, bool or int value in the machine's memory, for a host that gives a perform its
 * value. 0 when the memory is exhausted. Valid until the next pc_init or pc_start. */
const struct pc_value *pc_scalar(int tag,int64_t integer);
int pc_step(struct pc_machine *,struct pc_sample *);
/* TC1-D1. In HostWait pc_step returns -1: only the host's reply can move the machine.
 * pc_reply parses the canonical JSON value text[0..n) and checks it against the pending
 * operation's result type: 1 and the HostReply step; 0 when the reply is malformed or
 * ill-typed (the host's contract violation: no step); -1 not waiting, or guest limits. */
int pc_reply(struct pc_machine *,const char *text,size_t n,struct pc_sample *);
int pc_host_wait(const struct pc_machine *);
/* Canonical-shaped sample JSON. Returns bytes written (excluding NUL) or 0 on cap/shape error. */
size_t pc_format_sample(const struct pc_sample *,char *,size_t);
#endif
