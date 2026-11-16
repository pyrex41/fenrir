/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Remote-perform peer image for a STOCK Solo5 tender (spec/tc1/EFFECTS.md §12).
 * UNQUALIFIED development code.
 *
 * The abstract peer of models/tc1/remote-system.shen: a counter, with two
 * operations. The read-only one (EFFECTS.md §12.3, owner ruling on §12.10
 * question 7) replies with the counter as this incarnation found it in the
 * store or has since made it, and records nothing: it has no request key, and
 * a duplicate or a retry is simply evaluated again. The keyed one changes
 * state. Acting on a keyed
 * request is idempotent per request id (caller, key): if the durable store has
 * a reply record for it made with the same argument, that value is sent again
 * and nothing changes; if the record was made with another argument, the reply
 * is conflict and nothing changes (EFFECTS.md §12.3: a key stands for one
 * argument); otherwise the counter is incremented, the new value is recorded
 * together with the argument, and it is sent. The record keeps the argument
 * itself: an I64 is its own digest. The store is the block device "store" (wire.h): the record block is
 * written first, then the header that counts it. The header write is the
 * commit; a record beyond the header's count does not exist.
 *
 * Order (EFFECTS.md §12.3): the commit first, then the reply. A kill between
 * the two leaves the record and no reply; the next copy of the request id is
 * answered from the record. The supervisor can place a kill exactly there: when
 * the inbox header's hold names the request, the image stops after the commit
 * and before the Act frame and the reply, and waits to be killed (wire.h).
 *
 * Command line: "life=<milliseconds>", optionally followed by one deliberate
 * defect, for the harness:
 *   non-idempotent        a request id that has a record is applied again
 *   reply-before-commit   the reply is sent first and the commit made after it
 *   replay-different-argument   a key that has a record is answered from it
 *                         whatever the argument: no conflict is ever reported
 *   read-only-writes      the read-only operation adds one to the counter and
 *                         commits it before it replies
 * Console frames: Hello (with the store as found), one Act per request replied to.
 *
 * The line the supervisor reads from the image file before it starts anything
 * (REMOTE_SERVES, given by the build, which derives it from the remote-effect
 * declarations of the caller's program): whether the image has a durable
 * store, and the operations it serves with the mode of each. Built with
 * PEER_NO_STORE the image has no store device. Such an image may serve
 * read-only operations only; the build makes one that also claims the keyed
 * operation, for the harness, so that the supervisor's refusal of it at
 * assembly can be exercised. If it ever ran, it would fault on a keyed request. */
#include "support.h"
const char fenrir_remote_serves[]="\n" REMOTE_SERVES "\n";
#define MAX_RECORDS 62u
static struct mailbox box;
static solo5_handle_t store;
static uint64_t store_blocks;
static uint32_t applications,records;
static struct frw_stored table[MAX_RECORDS];
static uint8_t block[FRW_BLOCK];

#ifdef PEER_NO_STORE
/* No durable store: nothing survives this incarnation, and nothing may change. */
static int store_open(void) {return 0;}
static int commit(uint32_t slot,const struct frw_stored *made) {
    (void)slot;(void)made;(void)store;(void)block;
    return fault("a state-changing operation needs a durable store",EXIT_MACHINE);
}
static int commit_count(void) {return fault("a state-changing operation needs a durable store",EXIT_MACHINE);}
#else
static int store_header(void) {
    struct frw_header h={FRW_STORE_MAGIC,FRW_STORE,0,records,applications,0};
    frw_encode_header(&h,block);
    return solo5_block_write(store,0,block,FRW_BLOCK)==SOLO5_R_OK;
}
static int store_record(uint32_t slot,const struct frw_stored *c) {
    struct frw_record r;
    frw_put_stored(c,&r);r.seq=slot+1;r.incarnation=0;
    if(!frw_encode_record(&r,block))return 0;
    return solo5_block_write(store,(solo5_off_t)(slot+1)*FRW_BLOCK,block,FRW_BLOCK)==SOLO5_R_OK;
}
/* 0 ok, otherwise an exit code. */
static int store_open(void) {
    struct solo5_block_info info;struct frw_header h;
    if(solo5_block_acquire("store",&store,&info)!=SOLO5_R_OK || info.block_size!=FRW_BLOCK)return EXIT_DEVICE;
    store_blocks=info.capacity/FRW_BLOCK;
    if(solo5_block_read(store,0,block,FRW_BLOCK)!=SOLO5_R_OK)return EXIT_DEVICE;
    if(!frw_decode_header(block,&h) || h.magic!=FRW_STORE_MAGIC || h.count>MAX_RECORDS || (uint64_t)h.count>=store_blocks)return EXIT_MALFORMED;
    records=h.count;applications=h.grant;
    for(uint32_t i=0;i<records;i++){
        struct frw_record r;
        if(solo5_block_read(store,(solo5_off_t)(i+1)*FRW_BLOCK,block,FRW_BLOCK)!=SOLO5_R_OK)return EXIT_DEVICE;
        if(!frw_decode_record(block,&r) || r.type!=FRW_STORED || r.seq!=i+1 || r.incarnation || !frw_get_stored(&r,&table[i]))return EXIT_MALFORMED;
        for(uint32_t k=0;k<i;k++)
            if(frw_name_same(table[k].name,table[i].name) && table[k].key==table[i].key)return EXIT_MALFORMED;
    }
    return 0;
}
/* The durable commit of one application: the record, then the header that
 * counts it. 0 ok, otherwise an exit code. */
static int commit(uint32_t slot,const struct frw_stored *made) {
    if(!store_record(slot,made))return fault("store write",EXIT_DEVICE);
    table[slot]=*made;applications++;
    if(slot==records)records++;
    if(!store_header())return fault("store commit",EXIT_DEVICE);
    return 0;
}
/* Defect only: the counter as it is now, committed with no record. */
static int commit_count(void) {
    if(!store_header())return fault("store commit",EXIT_DEVICE);
    return 0;
}
#endif
int solo5_app_main(const struct solo5_start_info *info) {
    uint64_t life;const char *rest;int e,defect=0,early=0,deaf=0,scribbling=0;
    if(!parse_life(info->cmdline,&life,&rest))return EXIT_USAGE;
    if(word_is(rest,"non-idempotent"))defect=1;
    else if(word_is(rest,"reply-before-commit"))early=1;
    else if(word_is(rest,"replay-different-argument"))deaf=1;
    else if(word_is(rest,"read-only-writes"))scribbling=1;
    else if(*rest)return EXIT_USAGE;
    if((e=mailbox_open(&box,life))!=1)return fault("cannot open the mailboxes",-e);
    if((e=store_open()))return fault("cannot open the store",e);
    out_begin();out_text("{\"kind\":\"Hello\",\"role\":\"peer\",\"wire\":\"3\",\"incarnation\":\"");out_natural(box.incarnation);
    out_text("\",\"applications\":\"");out_natural(applications);out_text("\",\"records\":\"");out_natural(records);
    out_text(defect?"\",\"defect\":\"non-idempotent\"}":early?"\",\"defect\":\"reply-before-commit\"}":
             deaf?"\",\"defect\":\"replay-different-argument\"}":
             scribbling?"\",\"defect\":\"read-only-writes\"}":"\",\"defect\":\"none\"}");frame_end();
    if((e=mailbox_announce(&box))!=1)return fault("cannot announce",-e);
    for(;;){
        struct frw_record r;struct frw_call call;struct frw_stored made;struct frw_result result;uint32_t slot=records;int apply;
        memset(&made,0,sizeof made);
        if((e=mailbox_receive(&box,&r))!=1){
            if(e==-EXIT_LIFETIME){frame_text("{\"kind\":\"Lifetime\"}");return EXIT_LIFETIME;}
            return fault("malformed inbox",-e);
        }
        if(r.type!=FRW_DELIVER || !frw_get_call(&r,&call))return fault("malformed request",EXIT_MALFORMED);
        for(uint32_t i=0;i<records && call.mode==FRW_KEYED;i++)
            if(frw_name_same(table[i].name,call.name) && table[i].key==call.key)slot=i;
        apply=!(slot<records && !defect);
        result.status=0;
        if(call.mode==FRW_READ_ONLY){
            /* Read-only: the counter, as it is. No key, no record, nothing committed. */
            apply=0;
            if(scribbling){applications++;if((e=commit_count()))return e;}
            result.code=FRW_READ;result.value=(int64_t)applications;
        } else if(!apply && table[slot].argument!=call.value && !deaf){
            /* The key has a record made with another argument: refused. Nothing changes. */
            result.code=FRW_CONFLICT;result.value=0;
        } else if(!apply){
            result.code=FRW_REPLAYED;result.value=table[slot].value;
        } else {
            if(!store_blocks)return fault("a state-changing operation needs a durable store",EXIT_MACHINE);
            if(slot>=MAX_RECORDS || (uint64_t)slot+1>=store_blocks)return fault("store full",EXIT_MACHINE);
            /* Apply: the counter. The record keeps the argument with the value. */
            for(unsigned i=0;i<FRW_NAME;i++)made.name[i]=call.name[i];
            made.key=call.key;made.argument=call.value;made.value=(int64_t)applications+1;
            result.code=FRW_APPLIED;result.value=made.value;
            if(!early && (e=commit(slot,&made)))return e;
        }
        /* Committed, not replied: where the supervisor may ask for the image to stop. */
        if(!early && mailbox_held(&box,r.seq)){
            mailbox_hold(&box);frame_text("{\"kind\":\"Lifetime\"}");return EXIT_LIFETIME;
        }
        out_begin();out_text("{\"kind\":\"Act\",\"seq\":\"");out_natural(r.seq);out_text("\",\"caller\":\"");out_name(call.name);
        /* value: the operation's result as the caller's program will see it: (status, value)
         * for the keyed operation, the value for the read-only one, which has no key. */
        if(result.code==FRW_READ){
            out_text("\",\"how\":\"read\",\"value\":[\"int\",\"");out_integer(result.value);out_text("\"]}");
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
        if(early){
            /* The defect: replied, not committed. */
            if(mailbox_held(&box,r.seq)){mailbox_hold(&box);frame_text("{\"kind\":\"Lifetime\"}");return EXIT_LIFETIME;}
            if(apply && (e=commit(slot,&made)))return e;
        }
    }
}
