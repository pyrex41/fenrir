/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Remote-perform caller image for a STOCK Solo5 tender (spec/tc1/EFFECTS.md §12).
 * UNQUALIFIED development code.
 *
 * Runs one TC1 program (data.h, lowered by tools/solo5/remote-build.mjs from a
 * source file) on the pure-call machine of ../pure-call, unchanged. A remote
 * operation is an operation of an effect the program declares remote: when
 * the machine is Ready at a perform of such an operation, this file sends the
 * request to the supervisor, waits for the one outcome, and gives it to the
 * machine as the value of that perform. The frames stay where they are:
 * nothing of the continuation leaves the image. The operations, the peer each
 * is bound to and the declaration the supervisor reads from the image file are
 * tables in data.h, derived by the build from the program's remote-effect
 * declarations. No handler frame can handle a remote effect in a validated
 * program; the search below is kept as the machine's own rule.
 *
 * The request names its operation, "Effect.operation" (wire format 4).
 *   keyed:      perform(E, op, tuple(key, a))   key : I64, a : I64 in this version
 *               result reply((I64, I64)) | not_delivered | timed_out
 *   read-only:  perform(E, op, unit)            no key; unit in this version
 *               result reply(I64) | not_delivered | timed_out
 * The values are data of the name RemoteResult. The field of a keyed reply is
 * the operation's own result, (status, value): status 0 is ok with the peer's
 * value, status 1 is conflict (the key was applied with another argument) with
 * value 0. A read-only operation has no key and so no conflict: its reply is
 * the value.
 *
 * Command line: "life=<milliseconds>". Console frames, in order:
 *   Hello; then Step (one machine sample), Remote (a request about to be sent)
 *   and Outcome (the outcome received) as they happen; End; Terminal. Or a
 *   Fault frame. */
#include "support.h"
#include "machine.h"
#include "data.h"
#ifndef PC_FUEL
#define PC_FUEL 2000
#endif
#define MAX_OUTCOMES 64u
const char fenrir_remote_decl[]="\n" REMOTE_DECL "\n";

static struct pc_machine machine;
static struct mailbox box;
/* Outcome values live here, not in the machine's arena: the program may keep them. */
static struct pc_value results[MAX_OUTCOMES],tuples[MAX_OUTCOMES],integers[MAX_OUTCOMES][2];
static const struct pc_value *fields[MAX_OUTCOMES][1],*parts[MAX_OUTCOMES][2];
static unsigned outcomes;

static int same(const char *a,const char *b) {while(*a && *a==*b){a++;b++;}return *a==*b;}
/* The remote operation of the perform the machine is Ready at, when no handler
 * frame handles its effect; otherwise 0. The search is the machine's own:
 * innermost frame first, by effect name. */
static const struct remote_operation *remote_operation(const struct pc_machine *m) {
    if(m->control!=PC_READY)return 0;
    const struct pc_node *n=&m->program->nodes[m->node];
    if(n->tag!=PC_PERFORM)return 0;
    for(unsigned i=m->depth;i>0;i--)
        if(m->frames[i-1].kind==PF_HANDLE && same(m->program->nodes[m->frames[i-1].node].text,n->text))return 0;
    for(unsigned i=0;i<remote_operation_count;i++)
        if(same(remote_operations[i].effect,n->text) && same(remote_operations[i].operation,n->text2))return &remote_operations[i];
    return 0;
}
static const struct pc_value *result_value(const struct frw_result *x,int read_only) {
    static const char *names[]={0,"reply","not_delivered","timed_out"};
    if(outcomes>=MAX_OUTCOMES)return 0;
    unsigned k=outcomes++;
    struct pc_value *d=&results[k],*t=&tuples[k],*n=integers[k];
    memset(d,0,sizeof *d);memset(t,0,sizeof *t);memset(n,0,2*sizeof *n);
    d->tag=PV_DATA;d->text="RemoteResult";d->constructor=names[x->code];d->code=-1;
    if(x->code==FRW_REPLIED && read_only){
        /* reply(value): the operation's result is the I64 itself. */
        n[0].tag=PV_INT;n[0].integer=x->value;n[0].code=-1;
        fields[k][0]=&n[0];d->fields=fields[k];d->count=1;
    } else if(x->code==FRW_REPLIED){
        n[0].tag=PV_INT;n[0].integer=(int64_t)x->status;n[0].code=-1;
        n[1].tag=PV_INT;n[1].integer=x->value;n[1].code=-1;
        parts[k][0]=&n[0];parts[k][1]=&n[1];
        t->tag=PV_TUPLE;t->fields=parts[k];t->count=2;t->code=-1;
        fields[k][0]=t;d->fields=fields[k];d->count=1;
    }
    return d;
}
/* One remote perform: request out, outcome in. 0 ok, otherwise an exit code. */
static int remote(const struct remote_operation *op) {
    const struct pc_value *argument=machine.ready[0];
    struct frw_record r;struct frw_call call;struct frw_result result;int e;
    if(!frw_name_set(call.name,op->peer))return fault("peer name",EXIT_MACHINE);
    if(!frw_operation_set(call.operation,op->wire))return fault("operation name",EXIT_MACHINE);
    if(op->read_only){
        if(!argument || argument->tag!=PV_UNIT)return fault("read-only remote argument is not unit",EXIT_MACHINE);
        call.mode=FRW_READ_ONLY;call.key=0;call.value=0;
    } else {
        if(!argument || argument->tag!=PV_TUPLE || argument->count!=2 ||
           argument->fields[0]->tag!=PV_INT || argument->fields[1]->tag!=PV_INT)
            return fault("remote argument is not tuple(I64 key, I64)",EXIT_MACHINE);
        call.mode=FRW_KEYED;call.key=argument->fields[0]->integer;call.value=argument->fields[1]->integer;
    }
    frw_put_call(&call,&r,FRW_REQUEST);
    /* The frame comes before the record: once the supervisor can see the request,
     * this image prints nothing more until it has an outcome. */
    uint32_t seq=box.sent+1;
    out_begin();out_text("{\"kind\":\"Remote\",\"seq\":\"");out_natural(seq);
    out_text("\",\"effect\":\"");out_text(op->effect);out_text("\",\"operation\":\"");out_text(op->operation);
    out_text("\",\"peer\":\"");out_text(op->peer);
    if(op->read_only)out_text("\",\"mode\":\"read-only\",\"argument\":[\"unit\"]}");
    else {
        out_text("\",\"mode\":\"keyed\",\"key\":\"");out_integer(call.key);
        out_text("\",\"argument\":[\"int\",\"");out_integer(call.value);out_text("\"]}");
    }
    frame_end();
    if((e=mailbox_send(&box,&r))!=1)return fault("cannot send the request",-e);
    if((e=mailbox_receive(&box,&r))!=1)
        return fault(e==-EXIT_LIFETIME?"lifetime ran out waiting for an outcome":"malformed inbox",-e);
    /* Exactly the outcome of the request this image is suspended in. */
    if(r.type!=FRW_OUTCOME || r.ref!=seq || !frw_get_result(&r,&result))return fault("malformed or unsolicited outcome",EXIT_MALFORMED);
    /* A read-only operation has no key, so nothing it could conflict with. */
    if(op->read_only && result.status)return fault("a read-only reply with a status",EXIT_MALFORMED);
    out_begin();out_text("{\"kind\":\"Outcome\",\"seq\":\"");out_natural(seq);out_text("\",\"outcome\":");
    if(result.code==FRW_REPLIED && op->read_only){
        out_text("[\"reply\",[\"int\",\"");out_integer(result.value);out_text("\"]]");
    }
    else if(result.code==FRW_REPLIED){
        out_text("[\"reply\",[\"tuple\",[\"int\",\"");out_natural(result.status);out_text("\"],[\"int\",\"");
        out_integer(result.value);out_text("\"]]]");
    }
    else out_text(result.code==FRW_NOT_DELIVERED?"[\"not_delivered\"]":"[\"timed_out\"]");
    out_text("}");frame_end();
    const struct pc_value *v=result_value(&result,op->read_only);
    if(!v)return fault("too many remote performs for this image",EXIT_MACHINE);
    /* The perform returns with the outcome as its value; environment and frames are untouched. */
    machine.control=PC_VALUE;machine.value=v;
    return 0;
}
int solo5_app_main(const struct solo5_start_info *info) {
    uint64_t life;const char *rest;int e;
    if(!parse_life(info->cmdline,&life,&rest) || *rest)return EXIT_USAGE;
    if((e=mailbox_open(&box,life))!=1)return fault("cannot open the mailboxes",-e);
    out_begin();out_text("{\"kind\":\"Hello\",\"role\":\"caller\",\"wire\":\"4\",\"incarnation\":\"");out_natural(box.incarnation);
    out_text("\",\"program_sha256\":\"" PC_BATCH_SHA256 "\",\"connects\":[");
    for(unsigned i=0;i<remote_peer_count;i++){if(i)out_text(",");out_text("\"");out_text(remote_peers[i]);out_text("\"");}
    out_text("]}");frame_end();
    if((e=mailbox_announce(&box))!=1)return fault("cannot announce",-e);
    if(pc_program_count!=1 || pc_init(&machine,&pc_programs[0],0,0)!=1)return fault("program",EXIT_MACHINE);
    while(machine.control!=PC_TERMINAL && machine.epoch<PC_FUEL){
        const struct remote_operation *op=remote_operation(&machine);
        if(op){if((e=remote(op)))return e;continue;}
        struct pc_sample s;size_t space,n;
        if(pc_step(&machine,&s)!=1)return fault("machine step",EXIT_MACHINE);
        out_begin();out_text("{\"kind\":\"Step\",\"sample\":");
        char *room=out_room(&space);
        if(!(n=pc_format_sample(&s,room,space)))return fault("sample format",EXIT_MACHINE);
        out_advance(n);out_text("}");
        if(!frame_end())return fault("sample too large",EXIT_MACHINE);
    }
    frame_text(machine.control==PC_TERMINAL?"{\"execution\":\"Completed\",\"kind\":\"End\"}"
                                           :"{\"execution\":\"BudgetExhausted\",\"kind\":\"End\"}");
    frame_text("{\"kind\":\"Terminal\"}");
    /* Last: the halt record tells the supervisor the program has finished. */
    struct frw_record halt;
    memset(&halt,0,sizeof halt);halt.type=FRW_HALT;
    if((e=mailbox_send(&box,&halt))!=1)return fault("cannot send halt",-e);
    return SOLO5_EXIT_SUCCESS;
}
