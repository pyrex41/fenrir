/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Host-controlled pure-call guest for a STOCK Solo5 spt tender: protocol
 * fenrir.solo5.pure-call-control/1 (spec/solo5/pure-call-control-v1.md).
 *
 * Transport: two Solo5 net devices the stock tender attaches to pre-opened file
 * descriptors (--net:ctlin=@0 --net:ctlout=@2): host requests arrive on ctlin, guest
 * responses leave on ctlout. The console carries only the tender's banner; nothing on
 * it is semantic. The guest advances the machine only when a Run request asks it to,
 * and blocks in solo5_yield otherwise.
 *
 * Fail-closed: any malformed, truncated, duplicated, out-of-order, over-limit or
 * out-of-state host input gets one Error frame and exit 3; the guest never guesses.
 * Exit 0 after Bye; exit 2 is a guest infrastructure failure (arena, record limit,
 * transport write failure); exit 1 a bad command line.
 *
 * Determinism: frames depend only on the image (programs as data), the host's
 * requests and the machine. The monotonic clock is read in one place only, to pace
 * write retries under back-pressure; its value never enters a frame or the state.
 * Development evidence only.
 *
 * Built with -DFGC_V2 the same source is the guest of protocol
 * fenrir.solo5.pure-call-control/2 (spec/solo5/pure-call-control-v2.md): TC1-D1 durable
 * effects. A Run stops at a host request (execution HostWait); the host answers it with a
 * Reply frame (type A), which the guest checks against the operation's result type before
 * the program sees it (BadReply otherwise) and answers with the HostReply step. Without
 * the flag nothing of v2 is compiled in and the guest is the v1 guest.
 *
 * Built with -DFGC_V3 (and linked with tasks.c in place of machine.c and format.c) the same
 * source is the guest of fenrir.solo5.pure-call-control/3 (spec/solo5/pure-call-control-v3.md):
 * TC1-C1 tasks. Init names a scheduler: `reference`, where every Run names the task that
 * steps, or `fifo`, where the guest's FIFO production policy chooses and each record names
 * the task it chose. Without the flag nothing of v3 is compiled in. */
#include <solo5.h>
#include "machine.h"
#ifdef FGC_V3
#include "tasks.h"
#endif
#include "data.h"
#include "control-data.h"

#define FGC_HEADER 26u
#define FGC_HOST_MAX 512u
#define FGC_GUEST_MAX 61440u
#define FGC_RECORD_MAX 16384u
#define FGC_RUN_MAX 64u
#define FGC_FUEL_MAX 100000u
#if defined(FGC_V2) && defined(FGC_V3)
#error "FGC_V2 and FGC_V3 are separate guests"
#endif
#ifdef FGC_V2
#define FGC_PROTOCOL "fenrir.solo5.pure-call-control/2"
#define FGC_PROFILE "fenrir.solo5.pure-call-machine/2"
#elif defined(FGC_V3)
#define FGC_PROTOCOL "fenrir.solo5.pure-call-control/3"
#define FGC_PROFILE "fenrir.solo5.pure-call-machine/3"
#else
#define FGC_PROTOCOL "fenrir.solo5.pure-call-control/1"
#define FGC_PROFILE "fenrir.solo5.pure-call-machine/1"
#endif

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
#ifndef FGC_V3
static unsigned length(const char *s) {unsigned n=0;while(s[n])n++;return n;}
#endif
static int same(const char *a,const char *b) {while(*a && *a==*b){a++;b++;}return *a==*b;}

/* ---------- output: one frame at a time ---------- */

static solo5_handle_t ctlin,ctlout;
static char out[FGC_HEADER+FGC_GUEST_MAX+1];
struct text { char *at; size_t used,cap; int bad; };
static void put(struct text *t,const char *s) {
    while(*s){if(t->used>=t->cap){t->bad=1;return;}t->at[t->used++]=*s++;}
}
static void put_span(struct text *t,const char *s,size_t n) {
    for(size_t i=0;i<n;i++){if(t->used>=t->cap){t->bad=1;return;}t->at[t->used++]=s[i];}
}
static void put_decimal(struct text *t,uint64_t n) {
    char d[21];unsigned at=20;d[20]=0;
    do{d[--at]=(char)('0'+n%10);n/=10;}while(n);
    put(t,d+at);
}
static void put_fixed(char *p,uint64_t n) {for(int i=7;i>=0;i--){p[i]=(char)('0'+n%10);n/=10;}}

/* Writes in chunks of at most 4096 bytes (PIPE_BUF): on a pipe each chunk is written
 * whole or not at all, so a failed write is retried, never half-sent. */
static int send(const char *p,size_t n) {
    while(n){
        size_t k=n>4096?4096:n;unsigned tries=0;
        while(solo5_net_write(ctlout,(const uint8_t *)p,k)!=SOLO5_R_OK){
            if(++tries>5000)return 0;
            solo5_yield(solo5_clock_monotonic()+1000000ULL,0);
        }
        p+=k;n-=k;
    }
    return 1;
}
/* Frame: "FGC1 G" type " " seq(8) " " length(8) "\n" payload "\n". */
static void frame(char type,uint64_t seq,const char *payload,size_t n) {
    if(n>FGC_GUEST_MAX || seq>99999999u)solo5_exit(2);
    char *h=out;
    h[0]='F';h[1]='G';h[2]='C';h[3]='1';h[4]=' ';h[5]='G';h[6]=type;h[7]=' ';
    put_fixed(h+8,seq);h[16]=' ';put_fixed(h+17,n);h[25]='\n';
    for(size_t i=0;i<n;i++)h[FGC_HEADER+i]=payload[i];
    h[FGC_HEADER+n]='\n';
    if(!send(out,FGC_HEADER+n+1))solo5_exit(2);
}
static char payload[FGC_GUEST_MAX];
static void fail(uint64_t seq,const char *code) {
    struct text t={payload,0,sizeof payload,0};
    put(&t,"{\"code\":\"");put(&t,code);put(&t,"\",\"kind\":\"Error\"}");
    frame('E',seq,payload,t.used);
    solo5_exit(same(code,"GuestLimit")?2:3);
}

/* ---------- input: exactly one frame at a time ---------- */

static uint8_t in[4096];
static size_t in_used;
/* 1: at least n bytes buffered; 0: the host closed ctlin first. */
static int fill(size_t n) {
    while(in_used<n){
        size_t got=0;
        solo5_result_t r=solo5_net_read(ctlin,in+in_used,sizeof in-in_used,&got);
        if(r==SOLO5_R_OK){if(!got)return 0;in_used+=got;continue;}
        if(r!=SOLO5_R_AGAIN)return 0;
        /* No deadline: wait for the host. Only ctlin can make this return early, or an
         * error condition on ctlout (the host went away), which ends the session. */
        solo5_handle_set_t ready=0;
        solo5_yield(~(solo5_time_t)0,&ready);
        if(ready&(1ULL<<ctlout))solo5_exit(4);
    }
    return 1;
}
static void drop(size_t n) {
    for(size_t i=n;i<in_used;i++)in[i-n]=in[i];
    in_used-=n;
}
static int digit(uint8_t c) {return c>='0' && c<='9';}
static uint64_t fixed(const uint8_t *p) {uint64_t n=0;for(int i=0;i<8;i++)n=n*10+(uint64_t)(p[i]-'0');return n;}

struct request { char type; char body[FGC_HOST_MAX+1]; size_t n; };
/* Reads the frame with sequence number seq or fails closed. */
static void receive(uint64_t seq,struct request *r) {
    if(!fill(FGC_HEADER))fail(seq,in_used?"Truncated":"Hangup");
    const uint8_t *h=in;
    if(h[0]!='F' || h[1]!='G' || h[2]!='C' || h[3]!='1' || h[4]!=' ')fail(seq,"BadMagic");
    if(h[5]!='H')fail(seq,"BadDirection");
#ifdef FGC_V2
    if(h[6]!='I' && h[6]!='R' && h[6]!='D' && h[6]!='X' && h[6]!='A')fail(seq,"UnknownType");
#else
    if(h[6]!='I' && h[6]!='R' && h[6]!='D' && h[6]!='X')fail(seq,"UnknownType");
#endif
    if(h[7]!=' ' || h[16]!=' ' || h[25]!='\n')fail(seq,"BadHeader");
    for(int i=0;i<8;i++)if(!digit(h[8+i]) || !digit(h[17+i]))fail(seq,"BadHeader");
    if(fixed(h+8)!=seq)fail(seq,"BadSequence");
    uint64_t n=fixed(h+17);
    if(n>FGC_HOST_MAX)fail(seq,"Oversize");
    if(!fill(FGC_HEADER+n+1))fail(seq,"Truncated");
    if(in[FGC_HEADER+n]!='\n')fail(seq,"BadTrailer");
    for(uint64_t i=0;i<n;i++){
        uint8_t c=in[FGC_HEADER+i];
        if(c<0x20 || c>0x7e)fail(seq,"BadPayload");
        r->body[i]=(char)c;
    }
    r->body[n]=0;r->n=(size_t)n;r->type=(char)h[6];
    drop(FGC_HEADER+n+1);
}

/* Exact canonical templates: a cursor over the request body. */
static const char *lit(const char *s,const char *expected) {
    if(!s)return 0;
    while(*expected){if(*s!=*expected)return 0;s++;expected++;}
    return s;
}
static const char *hex64(const char *s,char *outhex) {
    if(!s)return 0;
    for(int i=0;i<64;i++){
        if(!((s[i]>='0' && s[i]<='9') || (s[i]>='a' && s[i]<='f')))return 0;
        outhex[i]=s[i];
    }
    outhex[64]=0;return s+64;
}
/* Canonical decimal: no sign, no leading zero, at most 9 digits. */
static const char *decimal(const char *s,uint64_t *value) {
    if(!s || !digit((uint8_t)*s) || (*s=='0' && digit((uint8_t)s[1])))return 0;
    uint64_t n=0;int k=0;
    while(digit((uint8_t)*s)){if(++k>9)return 0;n=n*10+(uint64_t)(*s-'0');s++;}
    *value=n;return s;
}
/* A string of at most 63 characters from [A-Za-z0-9._/-], up to the closing quote. */
static const char *word(const char *s,char *outword) {
    if(!s)return 0;
    int k=0;
    while(*s && *s!='"'){
        char c=*s;
        if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='.'||c=='_'||c=='/'||c=='-') || k>=63)return 0;
        outword[k++]=c;s++;
    }
    outword[k]=0;return s;
}

/* ---------- state digest: FNV-1a 64 over the machine's semantic state ---------- */
#ifdef FGC_V3
/* v3: the digest walks the whole task machine (tasks.c). */
static void state_digest(char *hex) {tk_digest(hex);}
#else

struct digest { uint64_t h; unsigned long budget; };
static const struct pc_node *machine_nodes(void);
static void mix(struct digest *d,uint64_t x) {
    for(int i=0;i<8;i++){d->h^=(uint8_t)(x>>(8*i));d->h*=1099511628211ULL;}
}
static void mix_text(struct digest *d,const char *s,unsigned n) {
    mix(d,n);for(unsigned i=0;i<n;i++){d->h^=(uint8_t)s[i];d->h*=1099511628211ULL;}
}
static void mix_env(struct digest *,const struct pc_env *);
static void mix_frames(struct digest *,const struct pc_frame *,unsigned,int);
static void mix_value(struct digest *d,const struct pc_value *v) {
    if(!d->budget){mix(d,0xbadULL);return;}
    d->budget--;
    if(!v){mix(d,0xffffULL);return;}
    mix(d,(uint64_t)v->tag);mix(d,(uint64_t)v->integer);
    if(v->tag==PV_BYTES)mix_text(d,v->text,v->count);
    if(v->tag==PV_DATA){mix_text(d,v->text,length(v->text));mix_text(d,v->constructor,length(v->constructor));}
    if(v->tag==PV_TUPLE || v->tag==PV_DATA){mix(d,v->count);for(unsigned i=0;i<v->count;i++)mix_value(d,v->fields[i]);}
    if(v->tag==PV_CLOSURE){mix(d,(uint64_t)(int64_t)v->code);mix_env(d,v->captures);}
    if(v->tag==PV_RESUMPTION){mix_env(d,v->captures);mix(d,v->segment?v->segment->count:0);
        if(v->segment)mix_frames(d,v->segment->frames,v->segment->count,0);}
}
static void mix_env(struct digest *d,const struct pc_env *e) {
    for(;e && d->budget;e=e->parent){d->budget--;mix(d,e->id);mix_value(d,e->value);}
    mix(d,0xe0dULL);
}
static void mix_frames(struct digest *d,const struct pc_frame *f,unsigned count,int reverse) {
    const struct pc_node *nodes=machine_nodes();
    for(unsigned i=0;i<count && d->budget;i++){
        d->budget--;
        mix(d,(uint64_t)f[i].kind);mix(d,(uint64_t)f[i].node);mix(d,(uint64_t)f[i].tail);mix(d,f[i].next);
        mix_env(d,f[i].env);
        if(f[i].kind==PF_COLLECT){
            unsigned c=nodes[f[i].node].child_count;
            for(unsigned k=0;k<f[i].next && k<c;k++)mix_value(d,f[i].values[reverse?c-1-k:k]);
        }
        if(f[i].kind==PF_CLAUSE && f[i].segment){mix(d,f[i].segment->count);
            mix_frames(d,f[i].segment->frames,f[i].segment->count,reverse);}
    }
}

static struct pc_machine machine;
static const struct pc_node *machine_nodes(void) {return machine.program->nodes;}
static void state_digest(char *hex) {
    struct digest d={14695981039346656037ULL,1u<<20};
    const struct pc_machine *m=&machine;
    mix(&d,m->epoch);mix(&d,(uint64_t)m->control);mix(&d,(uint64_t)(int64_t)m->node);mix(&d,(uint64_t)m->tail);
    mix(&d,(uint64_t)m->trap);mix(&d,m->depth);
#ifdef FGC_V2
    mix(&d,m->requests);
    if(m->control==PC_HOSTWAIT)mix_value(&d,m->value);
#endif
    if(m->control==PC_VALUE || m->control==PC_JOIN || m->control==PC_TERMINATE || m->control==PC_TERMINAL)mix_value(&d,m->trap?0:m->value);
    if(m->control==PC_READY){unsigned c=m->program->nodes[m->node].child_count;mix(&d,c);for(unsigned i=0;i<c;i++)mix_value(&d,m->ready[i]);}
    mix_env(&d,m->env);
    mix_frames(&d,m->frames,m->depth,m->reverse_operands);
    mix(&d,d.budget?1:0);
    for(int i=15;i>=0;i--){unsigned x=(unsigned)(d.h&15u);hex[i]=(char)(x<10?'0'+x:'a'+x-10);d.h>>=4;}
    hex[16]=0;
}
#endif

/* ---------- the session ---------- */

static uint64_t fuel;
static int initialized;
static const char *execution(void) {
#ifdef FGC_V3
    return tk_execution(fuel);
#else
    if(machine.control==PC_TERMINAL)return "Completed";
#ifdef FGC_V2
    if(machine.control==PC_HOSTWAIT)return "HostWait";
#endif
    if(machine.epoch>=fuel)return "BudgetExhausted";
    return "Running";
#endif
}
#ifdef FGC_V3
static char graph[FGC_RECORD_MAX];
static int fifo_scheduler;
static uint64_t epoch_now(void) {return tk_epoch();}
#else
static uint64_t epoch_now(void) {return machine.epoch;}
#endif
/* {"digest":D,"epoch":E,"execution":X,"kind":K ... the common prefix of state responses. */
static void state_fields(struct text *t,const char *kind) {
    char hex[17];state_digest(hex);
    put(t,"{\"digest\":\"");put(t,hex);put(t,"\",\"epoch\":\"");put_decimal(t,epoch_now());
    put(t,"\",\"execution\":\"");put(t,execution());put(t,"\",\"kind\":\"");put(t,kind);put(t,"\"");
}
static char steps[FGC_GUEST_MAX];
static char record[FGC_RECORD_MAX];

int solo5_app_main(const struct solo5_start_info *info) {
    struct solo5_net_info ni;
    if(info->cmdline[0])return 1; /* no startup input besides the image */
    if(solo5_net_acquire("ctlin",&ctlin,&ni)!=SOLO5_R_OK || solo5_net_acquire("ctlout",&ctlout,&ni)!=SOLO5_R_OK)return 2;
    struct text t={payload,0,sizeof payload,0};
    put(&t,"{\"batch_sha256\":\"" PC_BATCH_SHA256 "\",\"kind\":\"Hello\",\"limits\":{\"fuel\":\"");
    put_decimal(&t,FGC_FUEL_MAX);put(&t,"\",\"guest_payload\":\"");put_decimal(&t,FGC_GUEST_MAX);
    put(&t,"\",\"host_payload\":\"");put_decimal(&t,FGC_HOST_MAX);put(&t,"\",\"run_steps\":\"");put_decimal(&t,FGC_RUN_MAX);
    put(&t,"\"},\"machine_profile\":\"" FGC_PROFILE "\",\"programs\":\"");put_decimal(&t,pc_program_count);
    put(&t,"\",\"protocol\":\"" FGC_PROTOCOL "\"}");
    frame('H',0,payload,t.used);
    static struct request r;
    for(uint64_t seq=1;;seq++){
        receive(seq,&r);
        t=(struct text){payload,0,sizeof payload,0};
        if(r.type=='I'){
            char artifact[65],batch[65],mode[64],protocol[64],schema[64];uint64_t program=0,f=0;
            const char *s=lit(r.body,"{\"artifact_sha256\":\"");
            s=lit(hex64(s,artifact),"\",\"batch_sha256\":\"");
            s=lit(hex64(s,batch),"\",\"fuel\":\"");
            s=lit(decimal(s,&f),"\",\"kind\":\"Init\",\"mode\":\"");
            s=lit(word(s,mode),"\",\"program\":\"");
            s=lit(decimal(s,&program),"\",\"protocol\":\"");
#ifdef FGC_V3
            char scheduler[64];
            s=lit(word(s,protocol),"\",\"scheduler\":\"");
            s=lit(word(s,scheduler),"\",\"schema\":\"");
#else
            s=lit(word(s,protocol),"\",\"schema\":\"");
#endif
            s=lit(word(s,schema),"\"}");
            if(!s || *s)fail(seq,"BadPayload");
            if(initialized)fail(seq,"BadState");
            if(!same(protocol,FGC_PROTOCOL) || !same(batch,PC_BATCH_SHA256) || program>=pc_program_count ||
               !same(artifact,pc_program_sha256[program]) ||
               !same(schema,pc_program_schema[program]))fail(seq,"Identity");
#ifdef FGC_V3
            int defect=TK_NORMAL;
            if(same(mode,"fifo-reversed"))defect=TK_FIFO_REVERSED;
            else if(same(mode,"cancel-off-point"))defect=TK_CANCEL_OFF_POINT;
            else if(same(mode,"lost-wakeup"))defect=TK_LOST_WAKEUP;
            else if(same(mode,"capacity-off-by-one"))defect=TK_CAPACITY_OFF_BY_ONE;
            else if(!same(mode,"normal"))fail(seq,"Identity");
            if(same(scheduler,"fifo"))fifo_scheduler=1;
            else if(!same(scheduler,"reference"))fail(seq,"Identity");
            if(f<1 || f>FGC_FUEL_MAX)fail(seq,"BadBudget");
            if(tk_init(&pc_programs[program],defect,fifo_scheduler)!=1)fail(seq,"GuestLimit");
#else
            int reverse=0,wrap=0;
            if(same(mode,"reverse-operands"))reverse=1;
            else if(same(mode,"wrap-overflow"))wrap=1;
            else if(!same(mode,"normal"))fail(seq,"Identity");
            if(f<1 || f>FGC_FUEL_MAX)fail(seq,"BadBudget");
            if(pc_init(&machine,&pc_programs[program],reverse,wrap)!=1)fail(seq,"GuestLimit");
#endif
            fuel=f;initialized=1;
            char hex[17];state_digest(hex);
            put(&t,"{\"artifact_sha256\":\"");put(&t,artifact);put(&t,"\",\"digest\":\"");put(&t,hex);
            put(&t,"\",\"epoch\":\"0\",\"execution\":\"");put(&t,execution());put(&t,"\",\"fuel\":\"");put_decimal(&t,fuel);
            put(&t,"\",\"kind\":\"Ready\",\"mode\":\"");put(&t,mode);put(&t,"\",\"program\":\"");put_decimal(&t,program);
#ifdef FGC_V3
            put(&t,"\",\"scheduler\":\"");put(&t,fifo_scheduler?"fifo":"reference");
#endif
            put(&t,"\",\"schema\":\"");put(&t,schema);put(&t,"\"}");
            frame('Y',seq,payload,t.used);
        } else if(r.type=='R'){
#ifdef FGC_V3
            /* {"kind":"Run","steps":N,"task":T} (reference) or {"kind":"Run","steps":N} (fifo). */
            uint64_t n=0,task=0;int named=0;
            const char *s=lit(r.body,"{\"kind\":\"Run\",\"steps\":\"");
            s=s?decimal(s,&n):0;
            const char *tail=lit(s,"\"}");
            if(!tail){s=lit(s,"\",\"task\":\"");s=lit(s?decimal(s,&task):0,"\"}");named=1;} else s=tail;
            if(!s || *s)fail(seq,"BadPayload");
            if(!initialized || named==fifo_scheduler)fail(seq,"BadState");
            if(n<1 || n>FGC_RUN_MAX)fail(seq,"BadBudget");
            if(!same(execution(),"Running"))fail(seq,"NotRunning");
            if(named && !tk_runnable(task))fail(seq,"NotRunnable");
            struct text st={steps,0,sizeof steps-256,0};
            unsigned done=0;
            while(done<n && same(execution(),"Running") && (!named || tk_runnable(task)) && st.cap-st.used>FGC_RECORD_MAX+1){
                size_t k=0;
                if(tk_step(task,record,sizeof record,&k)!=1)fail(seq,"GuestLimit");
                if(done)put(&st,",");
                put_span(&st,record,k);done++;
            }
            if(st.bad)fail(seq,"GuestLimit");
            state_fields(&t,"Steps");put(&t,",\"steps\":[");put_span(&t,steps,st.used);put(&t,"]");
            if(same(execution(),"Deadlock")){
                size_t g=tk_wait_graph(graph,sizeof graph);
                if(!g)fail(seq,"GuestLimit");
                put(&t,",\"wait_graph\":");put_span(&t,graph,g);
            }
            put(&t,"}");
            if(t.bad)fail(seq,"GuestLimit");
            frame('S',seq,payload,t.used);
#else
            uint64_t n;
            const char *s=lit(r.body,"{\"kind\":\"Run\",\"steps\":\"");
            s=lit(s?decimal(s,&n):0,"\"}");
            if(!s || *s)fail(seq,"BadPayload");
            if(!initialized)fail(seq,"BadState");
            if(n<1 || n>FGC_RUN_MAX)fail(seq,"BadBudget");
            if(!same(execution(),"Running"))fail(seq,"NotRunning");
            struct text st={steps,0,sizeof steps-256,0};
            unsigned done=0;
            while(done<n && same(execution(),"Running") && st.cap-st.used>FGC_RECORD_MAX+1){
                struct pc_sample sample;
                if(pc_step(&machine,&sample)!=1)fail(seq,"GuestLimit");
                size_t k=pc_format_sample(&sample,record,sizeof record);
                if(!k)fail(seq,"GuestLimit");
                if(done)put(&st,",");
                put_span(&st,record,k);done++;
            }
            if(st.bad)fail(seq,"GuestLimit");
            state_fields(&t,"Steps");put(&t,",\"steps\":[");put_span(&t,steps,st.used);put(&t,"]}");
            if(t.bad)fail(seq,"GuestLimit");
            frame('S',seq,payload,t.used);
#endif
#ifdef FGC_V2
        } else if(r.type=='A'){
            /* {"kind":"Reply","request":R,"value":V}: V a canonical value, checked by the
             * machine against the pending operation's result type. */
            uint64_t request;
            const char *s=lit(r.body,"{\"kind\":\"Reply\",\"request\":\"");
            s=lit(s?decimal(s,&request):0,"\",\"value\":");
            if(!s || r.n<1 || r.body[r.n-1]!='}' || s>r.body+r.n-1)fail(seq,"BadPayload");
            if(!initialized || !pc_host_wait(&machine))fail(seq,"BadState");
            if(request+1!=machine.requests)fail(seq,"BadReply");
            struct pc_sample sample;
            int got=pc_reply(&machine,s,(size_t)(r.body+r.n-1-s),&sample);
            if(got==0)fail(seq,"BadReply");
            if(got!=1)fail(seq,"GuestLimit");
            size_t k=pc_format_sample(&sample,record,sizeof record);
            if(!k)fail(seq,"GuestLimit");
            state_fields(&t,"Steps");put(&t,",\"steps\":[");put_span(&t,record,k);put(&t,"]}");
            if(t.bad)fail(seq,"GuestLimit");
            frame('S',seq,payload,t.used);
#endif
        } else if(r.type=='D'){
            if(!same(r.body,"{\"kind\":\"Digest\"}"))fail(seq,"BadPayload");
            if(!initialized)fail(seq,"BadState");
            state_fields(&t,"Digest");put(&t,"}");
            frame('D',seq,payload,t.used);
        } else {
            if(!same(r.body,"{\"kind\":\"Terminate\"}"))fail(seq,"BadPayload");
            if(!initialized)fail(seq,"BadState");
            /* Nothing may follow Terminate: input already sent after it is refused. */
            size_t got=0;
            if(!in_used && in_used<sizeof in && solo5_net_read(ctlin,in,sizeof in,&got)==SOLO5_R_OK)in_used=got;
            if(in_used)fail(seq,"TrailingInput");
            state_fields(&t,"Bye");put(&t,"}");
            frame('B',seq,payload,t.used);
            return SOLO5_EXIT_SUCCESS;
        }
    }
}
