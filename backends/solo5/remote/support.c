/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * See support.h. */
#include "support.h"
void *memset(void *dest,int value,size_t count) {
    volatile unsigned char *p=dest;
    for(size_t i=0;i<count;i++)p[i]=(unsigned char)value;
    return dest;
}
void *memcpy(void *dest,const void *source,size_t count) {
    volatile unsigned char *d=dest;const unsigned char *s=source;
    for(size_t i=0;i<count;i++)d[i]=s[i];
    return dest;
}
static char body[70000];
static size_t at;
static int overflow;
static unsigned length(const char *s) {unsigned n=0;while(s[n])n++;return n;}
void out_begin(void) {at=0;overflow=0;}
void out_text(const char *s) {
    while(*s){if(at+1>=sizeof body){overflow=1;return;}body[at++]=*s++;}
}
void out_natural(uint64_t n) {
    char digits[21];unsigned k=20;digits[20]=0;
    do{digits[--k]=(char)('0'+n%10);n/=10;}while(n);
    out_text(digits+k);
}
void out_integer(int64_t n) {
    if(n<0){out_text("-");out_natural((uint64_t)0-(uint64_t)n);} else out_natural((uint64_t)n);
}
void out_name(const char name[FRW_NAME]) {
    char copy[FRW_NAME+1];
    for(unsigned i=0;i<FRW_NAME;i++)copy[i]=name[i];
    copy[FRW_NAME]=0;out_text(copy);
}
char *out_room(size_t *space) {*space=sizeof body-at;return body+at;}
void out_advance(size_t count) {if(count>=sizeof body-at)overflow=1;else at+=count;}
int frame_end(void) {
    char digits[21];unsigned k=20;uint64_t n=at;digits[20]=0;
    do{digits[--k]=(char)('0'+n%10);n/=10;}while(n);
    solo5_console_write("FGRUN/1 ",8);solo5_console_write(digits+k,20-k);solo5_console_write("\n",1);
    solo5_console_write(body,at);solo5_console_write("\n",1);
    return !overflow;
}
void frame_text(const char *payload) {out_begin();out_text(payload);frame_end();}
int fault(const char *reason,int code) {
    out_begin();out_text("{\"kind\":\"Fault\",\"reason\":\"");out_text(reason);out_text("\"}");frame_end();
    return code;
}
int parse_life(const char *s,uint64_t *life_ns,const char **rest) {
    const char *expected="life=";uint64_t n=0;unsigned digits=0;
    while(*expected){if(*s!=*expected)return 0;s++;expected++;}
    while(*s>='0' && *s<='9'){if(digits>=7)return 0;n=n*10+(uint64_t)(*s-'0');s++;digits++;}
    if(!digits || !n || (*s && *s!=' '))return 0;
    *life_ns=n*1000000u;*rest=*s?s+1:s;
    return 1;
}
int word_is(const char *rest,const char *expected) {
    unsigned n=length(expected);
    for(unsigned i=0;i<n;i++)if(rest[i]!=expected[i])return 0;
    return rest[n]==0;
}

static uint8_t block[FRW_BLOCK];
static int acquire(const char *name,solo5_handle_t *handle,uint64_t *blocks) {
    struct solo5_block_info info;
    if(solo5_block_acquire(name,handle,&info)!=SOLO5_R_OK || info.block_size!=FRW_BLOCK)return 0;
    *blocks=info.capacity/FRW_BLOCK;
    return *blocks>=2;
}
static void pause_until(solo5_time_t t) {solo5_yield(t,0);}
/* The supervisor may be writing the header while it is read here. A header
 * whose CRC fails is read again a few times, a millisecond apart, before it
 * counts as malformed. Records are complete before their header counts them. */
static int inbox_header(struct mailbox *m,struct frw_header *h) {
    for(unsigned attempt=0;attempt<50;attempt++){
        if(solo5_block_read(m->inbox,0,block,FRW_BLOCK)!=SOLO5_R_OK)return -EXIT_DEVICE;
        if(frw_decode_header(block,h))return 1;
        pause_until(solo5_clock_monotonic()+1000000u);
    }
    return -EXIT_MALFORMED;
}
static int outbox_header(struct mailbox *m) {
    struct frw_header h={FRW_MAILBOX_MAGIC,FRW_OUTBOX,m->incarnation,m->sent,m->sent,0,0};
    frw_encode_header(&h,block);
    return solo5_block_write(m->outbox,0,block,FRW_BLOCK)==SOLO5_R_OK?1:-EXIT_DEVICE;
}
int mailbox_open(struct mailbox *m,uint64_t life_ns) {
    struct frw_header h;int r;
    m->deadline=solo5_clock_monotonic()+life_ns;
    if(!acquire("inbox",&m->inbox,&m->inbox_blocks) || !acquire("outbox",&m->outbox,&m->outbox_blocks))return -EXIT_DEVICE;
    if((r=inbox_header(m,&h))!=1)return r;
    if(h.magic!=FRW_MAILBOX_MAGIC || h.kind!=FRW_INBOX)return -EXIT_MALFORMED;
    m->incarnation=h.incarnation;m->count=h.count;m->grant=h.grant;m->hold=h.hold;m->where=h.where;m->consumed=0;m->sent=0;
    return 1;
}
int mailbox_announce(struct mailbox *m) {return outbox_header(m);}
int mailbox_send(struct mailbox *m,struct frw_record *r) {
    if((uint64_t)m->sent+1>=m->outbox_blocks)return -EXIT_MACHINE;
    r->seq=m->sent+1;r->incarnation=m->incarnation;
    if(!frw_encode_record(r,block))return -EXIT_MACHINE;
    if(solo5_block_write(m->outbox,(solo5_off_t)r->seq*FRW_BLOCK,block,FRW_BLOCK)!=SOLO5_R_OK)return -EXIT_DEVICE;
    m->sent++;
    return outbox_header(m);
}
int mailbox_receive(struct mailbox *m,struct frw_record *r) {
    for(;;){
        struct frw_header h;int e;
        if((e=inbox_header(m,&h))!=1)return e;
        /* The header may only move forward within one incarnation. */
        if(h.magic!=FRW_MAILBOX_MAGIC || h.kind!=FRW_INBOX || h.incarnation!=m->incarnation ||
           h.count<m->count || h.grant<m->grant || (uint64_t)h.count>=m->inbox_blocks)return -EXIT_MALFORMED;
        m->count=h.count;m->grant=h.grant;m->hold=h.hold;m->where=h.where;
        if(m->grant>m->consumed){
            uint32_t seq=m->consumed+1;
            if(solo5_block_read(m->inbox,(solo5_off_t)seq*FRW_BLOCK,block,FRW_BLOCK)!=SOLO5_R_OK)return -EXIT_DEVICE;
            if(!frw_decode_record(block,r) || r->seq!=seq || r->incarnation!=m->incarnation)return -EXIT_MALFORMED;
            m->consumed=seq;
            return 1;
        }
        solo5_time_t now=solo5_clock_monotonic();
        if(now>=m->deadline)return -EXIT_LIFETIME;
        pause_until(now+1000000u);
    }
}
int mailbox_held(const struct mailbox *m,uint32_t seq,uint32_t where) {return m->hold && m->hold==seq && m->where==where;}
int mailbox_hold(struct mailbox *m) {
    for(;;){
        solo5_time_t now=solo5_clock_monotonic();
        if(now>=m->deadline)return -EXIT_LIFETIME;
        pause_until(now+1000000u);
    }
}
