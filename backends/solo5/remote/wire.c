/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Wire format version 4: encoding and strict decoding. See wire.h. No I/O. */
#include "wire.h"
static void put16(uint8_t *p,uint16_t v) {p[0]=(uint8_t)v;p[1]=(uint8_t)(v>>8);}
static void put32(uint8_t *p,uint32_t v) {for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(v>>(8*i));}
static void put64(uint8_t *p,uint64_t v) {for(unsigned i=0;i<8;i++)p[i]=(uint8_t)(v>>(8*i));}
static uint16_t get16(const uint8_t *p) {return (uint16_t)(p[0]|(p[1]<<8));}
static uint32_t get32(const uint8_t *p) {uint32_t v=0;for(unsigned i=0;i<4;i++)v|=(uint32_t)p[i]<<(8*i);return v;}
static uint64_t get64(const uint8_t *p) {uint64_t v=0;for(unsigned i=0;i<8;i++)v|=(uint64_t)p[i]<<(8*i);return v;}
uint32_t frw_crc32(const uint8_t *bytes,size_t count) {
    uint32_t crc=0xffffffffu;
    for(size_t i=0;i<count;i++){
        crc^=bytes[i];
        for(unsigned k=0;k<8;k++)crc=(crc>>1)^(0xedb88320u&(0u-(crc&1u)));
    }
    return ~crc;
}
static void seal(uint8_t block[FRW_BLOCK]) {put32(block+24,0);put32(block+24,frw_crc32(block,FRW_BLOCK));}
/* The stored CRC matches the block with its CRC field taken as zero. */
static int sealed(const uint8_t block[FRW_BLOCK]) {
    uint8_t copy[FRW_BLOCK];
    for(unsigned i=0;i<FRW_BLOCK;i++)copy[i]=block[i];
    put32(copy+24,0);
    return frw_crc32(copy,FRW_BLOCK)==get32(block+24);
}
static int zero(const uint8_t *p,unsigned from,unsigned to) {
    for(unsigned i=from;i<to;i++)if(p[i])return 0;
    return 1;
}
void frw_encode_header(const struct frw_header *h,uint8_t block[FRW_BLOCK]) {
    for(unsigned i=0;i<FRW_BLOCK;i++)block[i]=0;
    put32(block,h->magic);put16(block+4,(uint16_t)FRW_VERSION);put16(block+6,h->kind);
    put32(block+8,h->incarnation);put32(block+12,h->count);put32(block+16,h->grant);put32(block+20,h->hold);put32(block+28,h->where);
    seal(block);
}
int frw_decode_header(const uint8_t block[FRW_BLOCK],struct frw_header *h) {
    if(!sealed(block) || get16(block+4)!=FRW_VERSION || !zero(block,32,FRW_BLOCK))return 0;
    h->magic=get32(block);h->kind=get16(block+6);
    h->incarnation=get32(block+8);h->count=get32(block+12);h->grant=get32(block+16);h->hold=get32(block+20);h->where=get32(block+28);
    if(h->hold && (h->magic!=FRW_MAILBOX_MAGIC || h->kind!=FRW_INBOX || h->hold>h->grant))return 0;
    if(h->where>FRW_IN_COMMIT || (h->where && !h->hold))return 0;
    if(h->magic==FRW_MAILBOX_MAGIC){
        if(h->kind!=FRW_INBOX && h->kind!=FRW_OUTBOX)return 0;
        if(!h->incarnation || h->grant>h->count)return 0;
        if(h->kind==FRW_OUTBOX && h->grant!=h->count)return 0;
    } else if(h->magic==FRW_STORE_MAGIC){
        if(h->kind!=FRW_STORE || h->incarnation || h->grant>h->count)return 0;
    } else return 0;
    return 1;
}
int frw_encode_record(const struct frw_record *r,uint8_t block[FRW_BLOCK]) {
    if(r->length>FRW_PAYLOAD_MAX)return 0;
    for(unsigned i=0;i<FRW_BLOCK;i++)block[i]=0;
    put32(block,FRW_RECORD_MAGIC);put16(block+4,(uint16_t)FRW_VERSION);put16(block+6,r->type);
    put32(block+8,r->seq);put32(block+12,r->incarnation);put32(block+16,r->ref);put32(block+20,r->length);
    for(unsigned i=0;i<r->length;i++)block[32+i]=r->payload[i];
    seal(block);
    return 1;
}
int frw_decode_record(const uint8_t block[FRW_BLOCK],struct frw_record *r) {
    if(!sealed(block) || get32(block)!=FRW_RECORD_MAGIC || get16(block+4)!=FRW_VERSION || get32(block+28))return 0;
    r->type=get16(block+6);r->seq=get32(block+8);r->incarnation=get32(block+12);r->ref=get32(block+16);r->length=get32(block+20);
    if(r->type<FRW_REQUEST || r->type>FRW_CELL || !r->seq || r->length>FRW_PAYLOAD_MAX)return 0;
    if(!zero(block,32+r->length,FRW_BLOCK))return 0;
    for(unsigned i=0;i<FRW_PAYLOAD_MAX;i++)r->payload[i]=i<r->length?block[32+i]:0;
    return 1;
}
int frw_name_ok(const char name[FRW_NAME]) {
    unsigned n=0;
    while(n<FRW_NAME && name[n]){
        char c=name[n];
        if(!((c>='a' && c<='z') || (c>='0' && c<='9') || c=='-'))return 0;
        n++;
    }
    if(!n || n>=FRW_NAME)return 0;
    for(;n<FRW_NAME;n++)if(name[n])return 0;
    return 1;
}
int frw_name_set(char name[FRW_NAME],const char *text) {
    unsigned n=0;
    for(unsigned i=0;i<FRW_NAME;i++)name[i]=0;
    while(text[n]){if(n>=FRW_NAME-1)return 0;name[n]=text[n];n++;}
    return frw_name_ok(name);
}
int frw_name_same(const char a[FRW_NAME],const char b[FRW_NAME]) {
    for(unsigned i=0;i<FRW_NAME;i++)if(a[i]!=b[i])return 0;
    return 1;
}
int frw_operation_ok(const char operation[FRW_OPERATION]) {
    unsigned n=0,dots=0;
    while(n<FRW_OPERATION && operation[n]){
        char c=operation[n];
        if(c=='.'){if(!n)return 0;dots++;}
        else if(!((c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') || c=='_'))return 0;
        n++;
    }
    if(n<3 || n>=FRW_OPERATION || dots!=1 || operation[n-1]=='.')return 0;
    for(;n<FRW_OPERATION;n++)if(operation[n])return 0;
    return 1;
}
int frw_operation_set(char operation[FRW_OPERATION],const char *text) {
    unsigned n=0;
    for(unsigned i=0;i<FRW_OPERATION;i++)operation[i]=0;
    while(text[n]){if(n>=FRW_OPERATION-1)return 0;operation[n]=text[n];n++;}
    return frw_operation_ok(operation);
}
int frw_operation_same(const char a[FRW_OPERATION],const char b[FRW_OPERATION]) {
    for(unsigned i=0;i<FRW_OPERATION;i++)if(a[i]!=b[i])return 0;
    return 1;
}
void frw_put_call(const struct frw_call *c,struct frw_record *r,uint16_t type) {
    for(unsigned i=0;i<FRW_PAYLOAD_MAX;i++)r->payload[i]=0;
    for(unsigned i=0;i<FRW_NAME;i++)r->payload[i]=(uint8_t)c->name[i];
    put32(r->payload+16,c->mode);
    put64(r->payload+24,(uint64_t)c->key);put64(r->payload+32,(uint64_t)c->value);
    for(unsigned i=0;i<FRW_OPERATION;i++)r->payload[40+i]=(uint8_t)c->operation[i];
    r->type=type;r->ref=0;r->length=104;
}
int frw_get_call(const struct frw_record *r,struct frw_call *c) {
    if((r->type!=FRW_REQUEST && r->type!=FRW_DELIVER) || r->ref || r->length!=104)return 0;
    for(unsigned i=0;i<FRW_NAME;i++)c->name[i]=(char)r->payload[i];
    c->mode=get32(r->payload+16);
    c->key=(int64_t)get64(r->payload+24);c->value=(int64_t)get64(r->payload+32);
    for(unsigned i=0;i<FRW_OPERATION;i++)c->operation[i]=(char)r->payload[40+i];
    if(get32(r->payload+20) || (c->mode!=FRW_KEYED && c->mode!=FRW_READ_ONLY))return 0;
    /* A read-only request has no key, and its argument is unit. */
    if(c->mode==FRW_READ_ONLY && (c->key || c->value))return 0;
    return frw_name_ok(c->name) && frw_operation_ok(c->operation);
}
void frw_put_stored(const struct frw_stored *c,struct frw_record *r) {
    for(unsigned i=0;i<FRW_PAYLOAD_MAX;i++)r->payload[i]=0;
    for(unsigned i=0;i<FRW_NAME;i++)r->payload[i]=(uint8_t)c->name[i];
    put64(r->payload+16,(uint64_t)c->key);put64(r->payload+24,(uint64_t)c->argument);put64(r->payload+32,(uint64_t)c->value);
    for(unsigned i=0;i<FRW_OPERATION;i++)r->payload[40+i]=(uint8_t)c->operation[i];
    r->type=FRW_STORED;r->ref=0;r->length=104;
}
int frw_get_stored(const struct frw_record *r,struct frw_stored *c) {
    if(r->type!=FRW_STORED || r->ref || r->length!=104)return 0;
    for(unsigned i=0;i<FRW_NAME;i++)c->name[i]=(char)r->payload[i];
    c->key=(int64_t)get64(r->payload+16);c->argument=(int64_t)get64(r->payload+24);c->value=(int64_t)get64(r->payload+32);
    for(unsigned i=0;i<FRW_OPERATION;i++)c->operation[i]=(char)r->payload[40+i];
    return frw_name_ok(c->name) && frw_operation_ok(c->operation);
}
void frw_put_cell(const struct frw_cell *c,struct frw_record *r) {
    for(unsigned i=0;i<FRW_PAYLOAD_MAX;i++)r->payload[i]=0;
    put64(r->payload,(uint64_t)c->key);put64(r->payload+8,(uint64_t)c->value);
    r->type=FRW_CELL;r->ref=0;r->length=16;
}
int frw_get_cell(const struct frw_record *r,struct frw_cell *c) {
    if(r->type!=FRW_CELL || r->ref || r->length!=16)return 0;
    c->key=(int64_t)get64(r->payload);c->value=(int64_t)get64(r->payload+8);
    return 1;
}
void frw_put_result(const struct frw_result *x,struct frw_record *r,uint16_t type) {
    for(unsigned i=0;i<FRW_PAYLOAD_MAX;i++)r->payload[i]=0;
    put32(r->payload,x->code);put32(r->payload+4,x->status);put64(r->payload+8,(uint64_t)x->value);
    r->type=type;r->length=16;
}
int frw_get_result(const struct frw_record *r,struct frw_result *x) {
    if((r->type!=FRW_OUTCOME && r->type!=FRW_REPLY) || !r->ref || r->length!=16)return 0;
    x->code=get32(r->payload);x->status=get32(r->payload+4);x->value=(int64_t)get64(r->payload+8);
    if(r->type==FRW_OUTCOME){
        if(x->code<FRW_REPLIED || x->code>FRW_TIMED_OUT)return 0;
        if(x->code!=FRW_REPLIED && (x->value || x->status))return 0;
        if(x->status!=FRW_OK && (x->status!=FRW_KEY_CONFLICT || x->value))return 0;
    } else {
        if(x->status || x->code<FRW_APPLIED || x->code>FRW_TRAPPED)return 0;
        if((x->code==FRW_CONFLICT || x->code==FRW_TRAPPED) && x->value)return 0;
    }
    return 1;
}
