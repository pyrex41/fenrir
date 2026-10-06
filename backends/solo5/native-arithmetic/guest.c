/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Host-selected native transitions; no oracle code or expected traces linked. */
#include <solo5.h>
#include "machine.h"
#include "format.h"
#include "protocol.h"
#include "data.h"
#ifndef NA_FUEL
#define NA_FUEL 200
#endif
#define NA_PROFILE "fenrir.solo5.native-arithmetic-demo/1"
#define NA_DOMAIN "2cfd3c3d4c44e71ac259b85423ce0f53572e74026e3aad3c75d18206e4357558"
/* Stock bindings localize libc helpers. Compiler-generated guest aggregate
 * clears need a project-owned freestanding helper, not a bindings policy patch.
 * Volatile stores prevent optimizer recursion back into memset itself. */
void *memset(void *dest,int value,size_t count) {
    volatile unsigned char *p=dest;
    for(size_t i=0;i<count;i++)p[i]=(unsigned char)value;
    return dest;
}
static char message[8192];
static unsigned at;
static int bad;
static void add(const char *s) {
    while(*s){if(at+1>=sizeof message){bad=1;return;}message[at++]=*s++;}
    message[at]=0;
}
static void number(uint64_t n) {
    char digits[21];unsigned pos=20;digits[20]=0;
    do{digits[--pos]=(char)('0'+n%10);n/=10;}while(n);add(digits+pos);
}
static void common(uint64_t epoch,const char *kind,const char *mode,uint64_t sequence) {
    add("\"epoch\":\"");number(epoch);add("\",\"input_sha256\":\"" NA_INPUT_SHA256 "\",\"kind\":\"");
    add(kind);add("\",\"mode\":\"");add(mode);
    add("\",\"profile\":\"" NA_PROFILE "\",\"run_id\":\"native-0\",\"sequence\":\"");number(sequence);add("\"");
}
static int record(const char *kind,const char *mode,uint64_t seq,uint64_t epoch,const char *site) {
    at=0;bad=0;message[0]=0;
    add("{\"artifact_sha256\":\"" NA_ARTIFACT_SHA256 "\"");
    if(site)add(",\"domain_hash\":\"" NA_DOMAIN "\"");
    add(",");common(epoch,kind,mode,seq);
    if(site){add(",\"site\":");add(site);}
    add("}");return !bad;
}
static int terminal(const char *kind,const char *mode,uint64_t seq,uint64_t epoch,int completed) {
    at=0;bad=0;message[0]=0;
    add("{\"artifact_sha256\":\"" NA_ARTIFACT_SHA256 "\",\"epoch\":\"");number(epoch);
    add("\",\"execution\":\"");add(completed?"Completed":"BudgetExhausted");
    add("\",\"input_sha256\":\"" NA_INPUT_SHA256 "\",\"kind\":\"");add(kind);
    add("\",\"mode\":\"");add(mode);add("\",\"profile\":\"" NA_PROFILE "\",\"run_id\":\"native-0\",\"sequence\":\"");
    number(seq);add("\"}");return !bad;
}
static int sample_record(const char *mode,uint64_t seq,const struct na_sample *s) {
    char body[4096];if(!na_format_sample(s,body,sizeof body))return 0;
    at=0;bad=0;message[0]=0;
    add("{\"artifact_sha256\":\"" NA_ARTIFACT_SHA256 "\",\"epoch\":\"");number(s->epoch);
    add("\",\"input_sha256\":\"" NA_INPUT_SHA256 "\",\"kind\":\"Sample\",\"mode\":\"");add(mode);
    add("\",\"profile\":\"" NA_PROFILE "\",\"run_id\":\"native-0\",\"sample\":");add(body);
    add(",\"sequence\":\"");number(seq);add("\"}");return !bad;
}
int solo5_app_main(const struct solo5_start_info *info) {
    const char *mode=info->cmdline;
    int mutant=fg_equal(mode,"mutant");
    if(!mutant && !fg_equal(mode,"normal"))return 1;
    struct na_machine machine;struct na_sample s;char site[256];
    if(na_init(&machine,na_nodes,na_node_count,na_root,na_parameter,na_input,mutant)!=1)return 2;
    if(!record("Hello",mode,0,0,0))return 2;
    fg_frame(message);
    if(!record("Init",mode,0,0,0) || !fg_expect(message))return 1;
    uint64_t seq=1;
    while(machine.control!=NA_TERMINAL && machine.epoch<NA_FUEL) {
        if(na_site(&machine,&s)!=1 || !na_format_site(&s,site,sizeof site))return 2;
        if(!record("Boundary",mode,seq,machine.epoch,site))return 2;
        fg_frame(message);
        if(!record("Run",mode,seq,machine.epoch,site) || !fg_expect(message))return 1;
        if(na_step(&machine,&s)!=1)return 2;
        if(!sample_record(mode,++seq,&s))return 2;
        fg_frame(message);seq++;
    }
    int completed=machine.control==NA_TERMINAL;
    if(!terminal("Terminal",mode,seq,machine.epoch,completed))return 2;
    fg_frame(message);
    if(!terminal("Ack",mode,seq,machine.epoch,completed) || !fg_expect(message))return 1;
    char end;return fg_syscall(63,0,(long)&end,1)==0?0:1;
}
