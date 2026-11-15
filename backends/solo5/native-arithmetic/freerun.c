/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Free-running native arithmetic guest for a STOCK Solo5 spt tender.
 * It steps the same candidate machine as guest.c to its terminal state and
 * writes every sample to the console. There is no host control channel, so
 * the host observes the run but does not select its steps. Development
 * evidence only; no oracle code or expected traces are linked. */
#include <solo5.h>
#include "machine.h"
#include "format.h"
#include "data.h"
#ifndef NA_FUEL
#define NA_FUEL 200
#endif
/* Compiler-generated aggregate clears need a freestanding helper. */
void *memset(void *dest,int value,size_t count) {
    volatile unsigned char *p=dest;
    for(size_t i=0;i<count;i++)p[i]=(unsigned char)value;
    return dest;
}
static unsigned length(const char *s) {unsigned n=0;while(s[n])n++;return n;}
static int equal(const char *a,const char *b) {while(*a && *a==*b){a++;b++;}return *a==*b;}
static void text(const char *s) {solo5_console_write(s,length(s));}
static void frame(const char *payload) {
    char digits[16];unsigned n=length(payload),at=sizeof digits;
    do{digits[--at]=(char)('0'+n%10);n/=10;}while(n);
    text("FGRUN/1 ");solo5_console_write(digits+at,sizeof digits-at);text("\n");
    text(payload);text("\n");
}
int solo5_app_main(const struct solo5_start_info *info) {
    int mutant=equal(info->cmdline,"mutant");
    if(!mutant && !equal(info->cmdline,"normal"))return 1;
    static struct na_machine machine;struct na_sample s;static char body[4096];
    if(na_init(&machine,na_nodes,na_node_count,na_root,na_parameter,na_input,mutant)!=1)return 2;
    frame("{\"artifact_sha256\":\"" NA_ARTIFACT_SHA256 "\",\"input_sha256\":\"" NA_INPUT_SHA256 "\",\"kind\":\"Hello\"}");
    while(machine.control!=NA_TERMINAL && machine.epoch<NA_FUEL) {
        if(na_step(&machine,&s)!=1 || !na_format_sample(&s,body,sizeof body))return 2;
        frame(body);
    }
    frame(machine.control==NA_TERMINAL?"{\"execution\":\"Completed\",\"kind\":\"Terminal\"}"
                                      :"{\"execution\":\"BudgetExhausted\",\"kind\":\"Terminal\"}");
    return SOLO5_EXIT_SUCCESS;
}
