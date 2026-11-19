/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Remote-perform peer image for a STOCK Solo5 tender (spec/tc1/EFFECTS.md §12).
 * UNQUALIFIED development code.
 *
 * The peer is a program of this language (EFFECTS.md §12.12; owner ruling of 16
 * November 2026 on §12.10 question 13): data.h holds it, lowered by
 * tools/solo5/remote-build.mjs from a source file with a (serve ...) form, and a
 * table of the operations it serves, each with the function that implements
 * it. This file is the peer's RUNTIME: transport, the durable store, and the
 * transaction around each request. What an operation does is the program's.
 *
 * One request (EFFECTS.md §12.3):
 *   read-only  the operation's function is run on the store as it is (serve.c).
 *              Nothing is recorded and nothing committed; the reply is its value.
 *   keyed      the request id is (caller, key). If the store has a reply record
 *              for it made with this operation and argument, the recorded value
 *              is sent again and nothing is run. If the record was made with
 *              another operation or argument, the reply is conflict and nothing
 *              is run. Otherwise the function is run on tuple(key, argument).
 *              Its writes are kept aside while it runs and its reads see them.
 *              When it returns (status 0, value), THE COMMIT: its writes and the
 *              reply record (caller, key, operation, argument, value) become
 *              durable in one step, and only then is the reply sent.
 *   a trap     of the function, or a keyed result whose status is not 0 (only the
 *              runtime says conflict): nothing is committed and no reply is
 *              sent; the supervisor is told trapped and the caller will time out.
 *
 * The commit (wire.h, "The peer's durable store"): one CELL record for each cell
 * written, in ascending key order, and the STORED record, written after the
 * last record the store header counts; then one write of the header with the
 * new count. A record the header does not count does not exist. So a kill
 * before the header write leaves the store as it was, and a kill after it
 * leaves all of the request. This rests on one 512-byte block write being
 * atomic and on a completed write surviving the image.
 *
 * The supervisor can place a kill at two points of a request, by the hold of the
 * inbox header (wire.h): inside the commit, when every record is written and the
 * header is not; and after the commit, before the Act frame and the reply. The
 * image stops there without exiting and waits to be killed.
 *
 * Command line: "life=<milliseconds>", optionally followed by one deliberate
 * defect of this runtime, for the harness:
 *   non-idempotent        a request id that has a record is run and committed again
 *   reply-before-commit   the reply is sent first and the commit made after it
 *   replay-different-argument   a key that has a record is answered from it
 *                         whatever the operation and argument: never conflict
 *   read-only-writes      before a read-only request is served, cell 0 is
 *                         incremented and committed: the runtime writes where
 *                         the program, checked, cannot
 *   writes-without-record the commit leaves out the reply record
 *   record-without-writes the commit leaves out the program's writes
 *   torn-commit           the header is written after every record of a commit,
 *                         not once at its end: a kill inside leaves a part
 *   stale-reads           a read does not see what its own request has written
 * Console frames: Hello (with the store as found), one Act per request acted on.
 *
 * The line the supervisor reads from the image file before it starts anything
 * (REMOTE_SERVES, given by the build, which derives it from this peer's own
 * program): whether the image has a durable store, whether its program
 * mentions StoreWrite, the operations it serves with the mode of each, and a
 * digest of the signature of each effect it serves. Built with PEER_NO_STORE
 * the image has no store device: its store is empty and stays so. Such an image
 * may serve read-only operations only (EFFECTS.md §12.3, §12.6). */
#include "support.h"
#include "machine.h"
#include "serve.h"
#include "data.h"
#ifndef PEER_FUEL
#define PEER_FUEL 2000
#endif
const char fenrir_remote_serves[]="\n" REMOTE_SERVES "\n";
#define MAX_RECORDS 60u
#define MAX_CELLS 60u
enum { D_NONE,D_NON_IDEMPOTENT,D_REPLY_FIRST,D_DEAF,D_READ_WRITES,D_NO_RECORD,D_NO_WRITES,D_TORN,D_STALE };
static struct mailbox box;
static struct pc_machine machine;
static solo5_handle_t store;
static uint64_t store_blocks;
static uint32_t logged,stored,records,cell_count;
static struct frw_stored table[MAX_RECORDS];
static struct serve_cell cells[MAX_CELLS];
static uint8_t block[FRW_BLOCK];
static int defect;

/* The committed value of a cell is kept in ascending key order. 1 ok, 0 full. */
static int cell_set(int64_t key,int64_t value) {
    unsigned at=0;
    while(at<cell_count && cells[at].key<key)at++;
    if(at<cell_count && cells[at].key==key){cells[at].value=value;return 1;}
    if(cell_count>=MAX_CELLS)return 0;
    for(unsigned i=cell_count;i>at;i--)cells[i]=cells[i-1];
    cells[at].key=key;cells[at].value=value;cell_count++;
    return 1;
}
static uint32_t record_slot(const char name[FRW_NAME],int64_t key) {
    for(uint32_t i=0;i<records;i++)
        if(frw_name_same(table[i].name,name) && table[i].key==key)return i;
    return records;
}
static int record_set(const struct frw_stored *made) {
    uint32_t slot=record_slot(made->name,made->key);
    if(slot>=MAX_RECORDS)return 0;
    table[slot]=*made;
    if(slot==records)records++;
    return 1;
}
#ifdef PEER_NO_STORE
/* No durable store: nothing survives this incarnation, and nothing may change. */
static int store_open(void) {(void)store;(void)block;(void)logged;(void)cell_set;(void)record_set;return 0;}
static int commit(uint32_t seq,const struct serve_cell *writes,unsigned count,const struct frw_stored *made) {
    (void)seq;(void)writes;(void)count;(void)made;(void)stored;
    return fault("a state-changing operation needs a durable store",EXIT_MACHINE);
}
#else
static int store_header(void) {
    struct frw_header h={FRW_STORE_MAGIC,FRW_STORE,0,logged,stored,0,0};
    frw_encode_header(&h,block);
    return solo5_block_write(store,0,block,FRW_BLOCK)==SOLO5_R_OK;
}
static int store_write(struct frw_record *r,uint32_t seq) {
    r->seq=seq;r->incarnation=0;
    if(!frw_encode_record(r,block))return 0;
    return solo5_block_write(store,(solo5_off_t)seq*FRW_BLOCK,block,FRW_BLOCK)==SOLO5_R_OK;
}
/* 0 ok, otherwise an exit code. Only the records the header counts are read. */
static int store_open(void) {
    struct solo5_block_info info;struct frw_header h;
    if(solo5_block_acquire("store",&store,&info)!=SOLO5_R_OK || info.block_size!=FRW_BLOCK)return EXIT_DEVICE;
    store_blocks=info.capacity/FRW_BLOCK;
    if(solo5_block_read(store,0,block,FRW_BLOCK)!=SOLO5_R_OK)return EXIT_DEVICE;
    if(!frw_decode_header(block,&h) || h.magic!=FRW_STORE_MAGIC || (uint64_t)h.count>=store_blocks)return EXIT_MALFORMED;
    for(uint32_t i=1;i<=h.count;i++){
        struct frw_record r;struct frw_cell c;struct frw_stored s;
        if(solo5_block_read(store,(solo5_off_t)i*FRW_BLOCK,block,FRW_BLOCK)!=SOLO5_R_OK)return EXIT_DEVICE;
        if(!frw_decode_record(block,&r) || r.seq!=i || r.incarnation)return EXIT_MALFORMED;
        if(frw_get_cell(&r,&c)){if(!cell_set(c.key,c.value))return EXIT_MACHINE;}
        else if(frw_get_stored(&r,&s)){if(!record_set(&s))return EXIT_MACHINE;stored++;}
        else return EXIT_MALFORMED;
    }
    if(stored!=h.grant)return EXIT_MALFORMED;
    logged=h.count;
    return 0;
}
/* The durable commit of one request: its writes and its reply record, then the
 * header that counts them. made 0: no record (a defect). 0 ok, otherwise an
 * exit code. seq is the inbox record acted on, for a hold inside the commit.
 * stored counts the STORED records of the log, for the header. */
static int commit(uint32_t seq,const struct serve_cell *writes,unsigned count,const struct frw_stored *made) {
    struct frw_record r;uint32_t first=logged;
    if((uint64_t)logged+count+(made?1u:0u)>=store_blocks)return fault("store full",EXIT_MACHINE);
    for(unsigned i=0;i<count;i++){
        struct frw_cell c={writes[i].key,writes[i].value};
        frw_put_cell(&c,&r);
        if(!store_write(&r,first+i+1))return fault("store write",EXIT_DEVICE);
        /* The defect: each record is counted as soon as it is written. */
        if(defect==D_TORN){logged=first+i+1;if(!store_header())return fault("store commit",EXIT_DEVICE);}
    }
    if(made){
        frw_put_stored(made,&r);
        if(!store_write(&r,first+count+1))return fault("store write",EXIT_DEVICE);
    }
    /* Every record is written and none is counted: where the supervisor may ask for the image to stop. */
    if(mailbox_held(&box,seq,FRW_IN_COMMIT)){mailbox_hold(&box);frame_text("{\"kind\":\"Lifetime\"}");return EXIT_LIFETIME;}
    logged=first+count+(made?1u:0u);stored+=made?1u:0u;
    if(!store_header())return fault("store commit",EXIT_DEVICE);
    for(unsigned i=0;i<count;i++)if(!cell_set(writes[i].key,writes[i].value))return fault("too many cells",EXIT_MACHINE);
    if(made && !record_set(made))return fault("too many records",EXIT_MACHINE);
    return 0;
}
#endif
static const struct serve_operation *served(const char operation[FRW_OPERATION]) {
    char name[FRW_OPERATION];
    for(unsigned i=0;i<serve_operation_count;i++)
        if(frw_operation_set(name,serve_operations[i].name) && frw_operation_same(name,operation))return &serve_operations[i];
    return 0;
}
int solo5_app_main(const struct solo5_start_info *info) {
    static const char *names[]={"none","non-idempotent","reply-before-commit","replay-different-argument","read-only-writes",
                                "writes-without-record","record-without-writes","torn-commit","stale-reads"};
    uint64_t life;const char *rest;int e;
    if(!parse_life(info->cmdline,&life,&rest))return EXIT_USAGE;
    defect=D_NONE;
    for(int i=1;i<=D_STALE && *rest;i++)if(word_is(rest,names[i]))defect=i;
    if(*rest && defect==D_NONE)return EXIT_USAGE;
    if((e=mailbox_open(&box,life))!=1)return fault("cannot open the mailboxes",-e);
    if((e=store_open()))return fault("cannot open the store",e);
    out_begin();out_text("{\"kind\":\"Hello\",\"role\":\"peer\",\"wire\":\"4\",\"incarnation\":\"");out_natural(box.incarnation);
    out_text("\",\"cells\":[");
    for(unsigned i=0;i<cell_count;i++){
        out_text(i?",[\"":"[\"");out_integer(cells[i].key);out_text("\",\"");out_integer(cells[i].value);out_text("\"]");
    }
    out_text("],\"records\":\"");out_natural(records);
    out_text("\",\"defect\":\"");out_text(names[defect]);out_text("\"}");frame_end();
    if((e=mailbox_announce(&box))!=1)return fault("cannot announce",-e);
    if(pc_program_count!=1)return fault("program",EXIT_MACHINE);
    for(;;){
        struct frw_record r;struct frw_call call;struct frw_stored made;struct frw_result result;struct serve_result run;
        struct pc_value input,key,argument;const struct pc_value *parts[2];
        const struct serve_operation *op;uint32_t slot;int apply=0;
        memset(&made,0,sizeof made);memset(&input,0,sizeof input);memset(&key,0,sizeof key);memset(&argument,0,sizeof argument);
        if((e=mailbox_receive(&box,&r))!=1){
            if(e==-EXIT_LIFETIME){frame_text("{\"kind\":\"Lifetime\"}");return EXIT_LIFETIME;}
            return fault("malformed inbox",-e);
        }
        if(r.type!=FRW_DELIVER || !frw_get_call(&r,&call))return fault("malformed request",EXIT_MALFORMED);
        if(!(op=served(call.operation)))return fault("a request for an operation this image does not serve",EXIT_MALFORMED);
        if((call.mode==FRW_READ_ONLY)!=(op->read_only!=0))return fault("a request in the wrong mode for its operation",EXIT_MALFORMED);
        result.status=0;result.value=0;
        key.tag=PV_INT;key.integer=call.key;key.code=-1;
        argument.tag=PV_INT;argument.integer=call.value;argument.code=-1;
        if(op->read_only){
            /* Read-only: the function, on the store as it is. No key, no record, nothing committed. */
            if(defect==D_READ_WRITES){
                struct serve_cell bump={0,0};
                for(unsigned i=0;i<cell_count;i++)if(cells[i].key==0)bump.value=cells[i].value;
                bump.value++;
                if((e=commit(r.seq,&bump,1,0)))return e;
            }
            input.tag=PV_UNIT;input.code=-1;
            if(serve_request(&machine,&pc_programs[0],op->function,&input,cells,cell_count,defect==D_STALE,PEER_FUEL,0,0,&run)!=1 || !run.completed)
                return fault("the program did not finish the request",EXIT_MACHINE);
            if(run.write_count)return fault("a read-only operation wrote the store",EXIT_MACHINE);
            if(run.trap)result.code=FRW_TRAPPED;
            else {
                if(!run.value || run.value->tag!=PV_INT)return fault("a read-only result that is not an I64",EXIT_MACHINE);
                result.code=FRW_READ;result.value=run.value->integer;
            }
        } else {
            slot=record_slot(call.name,call.key);
            if(slot<records && defect!=D_NON_IDEMPOTENT){
                if((frw_operation_same(table[slot].operation,call.operation) && table[slot].argument==call.value) || defect==D_DEAF){
                    result.code=FRW_REPLAYED;result.value=table[slot].value;
                } else {
                    /* The key has a record made with another operation or argument: refused. Nothing changes. */
                    result.code=FRW_CONFLICT;
                }
            } else {
                if(!store_blocks)return fault("a state-changing operation needs a durable store",EXIT_MACHINE);
                parts[0]=&key;parts[1]=&argument;
                input.tag=PV_TUPLE;input.fields=parts;input.count=2;input.code=-1;
                if(serve_request(&machine,&pc_programs[0],op->function,&input,cells,cell_count,defect==D_STALE,PEER_FUEL,0,0,&run)!=1 || !run.completed)
                    return fault("the program did not finish the request",EXIT_MACHINE);
                if(!run.trap && (!run.value || run.value->tag!=PV_TUPLE || run.value->count!=2 ||
                                 run.value->fields[0]->tag!=PV_INT || run.value->fields[1]->tag!=PV_INT))
                    return fault("a keyed result that is not (I64, I64)",EXIT_MACHINE);
                if(run.trap || run.value->fields[0]->integer!=0)result.code=FRW_TRAPPED;
                else {
                    /* Apply: the record keeps the operation and the argument with the value. */
                    for(unsigned i=0;i<FRW_NAME;i++)made.name[i]=call.name[i];
                    for(unsigned i=0;i<FRW_OPERATION;i++)made.operation[i]=call.operation[i];
                    made.key=call.key;made.argument=call.value;made.value=run.value->fields[1]->integer;
                    result.code=FRW_APPLIED;result.value=made.value;apply=1;
                }
            }
        }
        if(apply && defect!=D_REPLY_FIRST){
            if((e=commit(r.seq,run.writes,defect==D_NO_WRITES?0:run.write_count,defect==D_NO_RECORD?0:&made)))return e;
        }
        /* Committed, not replied: where the supervisor may ask for the image to stop. */
        if(defect!=D_REPLY_FIRST && mailbox_held(&box,r.seq,FRW_BEFORE_REPLY)){
            mailbox_hold(&box);frame_text("{\"kind\":\"Lifetime\"}");return EXIT_LIFETIME;
        }
        out_begin();out_text("{\"kind\":\"Act\",\"seq\":\"");out_natural(r.seq);out_text("\",\"caller\":\"");out_name(call.name);
        out_text("\",\"operation\":\"");out_text(op->name);
        /* value: the operation's result as the caller's program will see it: (status, value)
         * for a keyed operation, the value for a read-only one, which has no key. */
        if(result.code==FRW_READ){
            out_text("\",\"how\":\"read\",\"value\":[\"int\",\"");out_integer(result.value);out_text("\"]}");
        } else if(result.code==FRW_TRAPPED){
            if(!op->read_only){out_text("\",\"key\":\"");out_integer(call.key);}
            out_text("\",\"how\":\"trapped\",\"value\":[\"unit\"]}");
        } else {
            out_text("\",\"key\":\"");out_integer(call.key);
            out_text(result.code==FRW_APPLIED?"\",\"how\":\"applied\"":result.code==FRW_REPLAYED?"\",\"how\":\"replayed\"":"\",\"how\":\"conflict\"");
            out_text(result.code==FRW_CONFLICT?",\"value\":[\"tuple\",[\"int\",\"1\"],[\"int\",\"":",\"value\":[\"tuple\",[\"int\",\"0\"],[\"int\",\"");
            out_integer(result.value);out_text("\"]]}");
        }
        frame_end();
        struct frw_record reply;
        frw_put_result(&result,&reply,FRW_REPLY);reply.ref=r.seq;
        if((e=mailbox_send(&box,&reply))!=1)return fault("cannot send the reply",-e);
        if(defect==D_REPLY_FIRST){
            /* The defect: replied, not committed. */
            if(mailbox_held(&box,r.seq,FRW_BEFORE_REPLY)){mailbox_hold(&box);frame_text("{\"kind\":\"Lifetime\"}");return EXIT_LIFETIME;}
            if(apply && (e=commit(r.seq,run.writes,run.write_count,&made)))return e;
        }
    }
}
