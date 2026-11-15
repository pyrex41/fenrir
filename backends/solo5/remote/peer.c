/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Remote-perform peer image for a STOCK Solo5 tender (spec/tc1/EFFECTS.md §12).
 * UNQUALIFIED development code.
 *
 * The abstract peer of models/tc1/remote-system.shen: a counter. Acting on a
 * request is idempotent per request id (caller, key): if the durable store has
 * a reply record for it, that value is sent again and nothing changes;
 * otherwise the counter is incremented, the new value is recorded, and it is
 * sent. The store is the block device "store" (wire.h): the record block is
 * written first, then the header that counts it. The header write is the
 * commit; a record beyond the header's count does not exist.
 *
 * Command line: "life=<milliseconds>" or "life=<milliseconds> non-idempotent".
 * The second form is a deliberate defect, for the harness: a request id that
 * has a record is applied again.
 * Console frames: Hello (with the store as found), one Act per request. */
#include "support.h"
#define MAX_RECORDS 62u
static struct mailbox box;
static solo5_handle_t store;
static uint64_t store_blocks;
static uint32_t applications,records;
static struct frw_call table[MAX_RECORDS];
static uint8_t block[FRW_BLOCK];

static int store_header(void) {
    struct frw_header h={FRW_STORE_MAGIC,FRW_STORE,0,records,applications};
    frw_encode_header(&h,block);
    return solo5_block_write(store,0,block,FRW_BLOCK)==SOLO5_R_OK;
}
static int store_record(uint32_t slot,const struct frw_call *c) {
    struct frw_record r;
    frw_put_call(c,&r,FRW_STORED);r.seq=slot+1;r.incarnation=0;
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
        if(!frw_decode_record(block,&r) || r.type!=FRW_STORED || r.seq!=i+1 || r.incarnation || !frw_get_call(&r,&table[i]))return EXIT_MALFORMED;
        for(uint32_t k=0;k<i;k++)
            if(frw_name_same(table[k].name,table[i].name) && table[k].key==table[i].key)return EXIT_MALFORMED;
    }
    return 0;
}
int solo5_app_main(const struct solo5_start_info *info) {
    uint64_t life;const char *rest;int e,defect=0;
    if(!parse_life(info->cmdline,&life,&rest))return EXIT_USAGE;
    if(word_is(rest,"non-idempotent"))defect=1;
    else if(*rest)return EXIT_USAGE;
    if((e=mailbox_open(&box,life))!=1)return fault("cannot open the mailboxes",-e);
    if((e=store_open()))return fault("cannot open the store",e);
    out_begin();out_text("{\"kind\":\"Hello\",\"role\":\"peer\",\"wire\":\"1\",\"incarnation\":\"");out_natural(box.incarnation);
    out_text("\",\"applications\":\"");out_natural(applications);out_text("\",\"records\":\"");out_natural(records);
    out_text(defect?"\",\"defect\":\"non-idempotent\"}":"\",\"defect\":\"none\"}");frame_end();
    if((e=mailbox_announce(&box))!=1)return fault("cannot announce",-e);
    for(;;){
        struct frw_record r;struct frw_call call;struct frw_result result;uint32_t slot=records;
        if((e=mailbox_receive(&box,&r))!=1){
            if(e==-EXIT_LIFETIME){frame_text("{\"kind\":\"Lifetime\"}");return EXIT_LIFETIME;}
            return fault("malformed inbox",-e);
        }
        if(r.type!=FRW_DELIVER || !frw_get_call(&r,&call))return fault("malformed request",EXIT_MALFORMED);
        for(uint32_t i=0;i<records;i++)
            if(frw_name_same(table[i].name,call.name) && table[i].key==call.key)slot=i;
        if(slot<records && !defect){
            result.code=FRW_REPLAYED;result.value=table[slot].value;
        } else {
            if(slot>=MAX_RECORDS || (uint64_t)slot+1>=store_blocks)return fault("store full",EXIT_MACHINE);
            /* Apply: the counter. Record, then commit by the header. */
            call.value=(int64_t)applications+1;
            if(!store_record(slot,&call))return fault("store write",EXIT_DEVICE);
            table[slot]=call;applications++;
            if(slot==records)records++;
            if(!store_header())return fault("store commit",EXIT_DEVICE);
            result.code=FRW_APPLIED;result.value=call.value;
        }
        out_begin();out_text("{\"kind\":\"Act\",\"seq\":\"");out_natural(r.seq);out_text("\",\"caller\":\"");out_name(call.name);
        out_text("\",\"key\":\"");out_integer(call.key);
        out_text(result.code==FRW_APPLIED?"\",\"how\":\"applied\",\"value\":[\"int\",\"":"\",\"how\":\"replayed\",\"value\":[\"int\",\"");
        out_integer(result.value);out_text("\"]}");frame_end();
        struct frw_record reply;
        frw_put_result(&result,&reply,FRW_REPLY);reply.ref=r.seq;
        if((e=mailbox_send(&box,&reply))!=1)return fault("cannot send the reply",-e);
    }
}
