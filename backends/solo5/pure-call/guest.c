/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Free-running pure-call guest for a STOCK Solo5 spt tender. data.h holds a
 * batch of validated programs as data. Command line: "<mode> <first> <end>"
 * with mode normal | reverse-operands | wrap-overflow. Every program in
 * [first,end) is stepped to its terminal state or the fuel bound and every
 * sample is written to the console. The host observes; it does not select
 * steps. Development evidence only. Exit 2 is a guest infrastructure failure. */
#include <solo5.h>
#include "machine.h"
#include "data.h"
#ifndef PC_FUEL
#define PC_FUEL 200
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
static unsigned length(const char *s) {unsigned n=0;while(s[n])n++;return n;}
static void text(const char *s) {solo5_console_write(s,length(s));}
static void decimal(char *out,uint64_t n) {
    char digits[21];unsigned at=20,i=0;digits[20]=0;
    do{digits[--at]=(char)('0'+n%10);n/=10;}while(n);
    while(digits[at])out[i++]=digits[at++];
    out[i]=0;
}
static void frame(const char *payload) {
    char digits[21];decimal(digits,length(payload));
    text("FGRUN/1 ");text(digits);text("\n");text(payload);text("\n");
}
static const char *word(const char *s,const char *expected) {
    while(*expected){if(*s!=*expected)return 0;s++;expected++;}
    return *s==' '?s+1:0;
}
static const char *number(const char *s,unsigned *out) {
    unsigned n=0;if(*s<'0' || *s>'9' || (*s=='0' && s[1]>='0' && s[1]<='9'))return 0;
    while(*s>='0' && *s<='9'){if(n>100000000u)return 0;n=n*10+(unsigned)(*s-'0');s++;}
    *out=n;return s;
}
static struct pc_machine machine;
static char body[65536],line[128];
int solo5_app_main(const struct solo5_start_info *info) {
    const char *rest;int reverse=0,wrap=0;unsigned first,end;
    if((rest=word(info->cmdline,"normal"))){}
    else if((rest=word(info->cmdline,"reverse-operands")))reverse=1;
    else if((rest=word(info->cmdline,"wrap-overflow")))wrap=1;
    else return 1;
    if(!(rest=number(rest,&first)) || *rest!=' ' || !(rest=number(rest+1,&end)) || *rest)return 1;
    if(first>end || end>pc_program_count)return 1;
    frame("{\"batch_sha256\":\"" PC_BATCH_SHA256 "\",\"kind\":\"Hello\"}");
    for(unsigned i=first;i<end;i++){
        char digits[21];unsigned at=0;const char *head="{\"index\":\"",*tail="\",\"kind\":\"Program\"}";
        decimal(digits,i);
        while(*head)line[at++]=*head++;
        for(unsigned k=0;digits[k];k++)line[at++]=digits[k];
        while(*tail)line[at++]=*tail++;
        line[at]=0;frame(line);
        struct pc_sample s;
        if(pc_init(&machine,&pc_programs[i],reverse,wrap)!=1)return 2;
        while(machine.control!=PC_TERMINAL && machine.epoch<PC_FUEL){
            if(pc_step(&machine,&s)!=1 || !pc_format_sample(&s,body,sizeof body))return 2;
            frame(body);
        }
        frame(machine.control==PC_TERMINAL?"{\"execution\":\"Completed\",\"kind\":\"End\"}"
                                          :"{\"execution\":\"BudgetExhausted\",\"kind\":\"End\"}");
    }
    frame("{\"kind\":\"Terminal\"}");
    return SOLO5_EXIT_SUCCESS;
}
