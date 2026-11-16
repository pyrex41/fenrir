/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Requests served by peer programs on the C machine, for comparison only
 * (spec/tc1/EFFECTS.md §12.12). Free-running guest for a STOCK Solo5 tender; no
 * devices. UNQUALIFIED development code.
 *
 * data.h holds a batch of peer programs as data and a table of cases: a
 * program, one of its functions, the request's input and the store it is
 * served on. Each case is run by serve.c, as the peer image runs a request,
 * and everything is written to the console: every machine sample, every store
 * perform with its value, and at the end how the run ended and what it would
 * write. The host observes; it does not select steps. Nothing is committed and
 * no supervisor is involved: transport, records and the commit are peer.c's.
 *
 * Command line: "<mode> <first> <end>", mode normal | stale-reads (the
 * deliberate defect of serve.c). Frames: Hello; for each case Case, then its
 * samples and {"key","store","value"} frames in order, then End; Terminal. */
#include "support.h"
#include "machine.h"
#include "serve.h"
#include "data.h"
#ifndef PEER_FUEL
#define PEER_FUEL 2000
#endif
static struct pc_machine machine;
static int failed;
static const char *word(const char *s,const char *expected) {
    while(*expected){if(*s!=*expected)return 0;s++;expected++;}
    return *s==' '?s+1:0;
}
static const char *number(const char *s,unsigned *out) {
    unsigned n=0;if(*s<'0' || *s>'9' || (*s=='0' && s[1]>='0' && s[1]<='9'))return 0;
    while(*s>='0' && *s<='9'){if(n>100000000u)return 0;n=n*10+(unsigned)(*s-'0');s++;}
    *out=n;return s;
}
static void observe(void *context,const struct pc_sample *sample,const struct serve_event *event) {
    (void)context;
    out_begin();
    if(sample){
        size_t space,n;char *room=out_room(&space);
        if(!(n=pc_format_sample(sample,room,space))){failed=1;return;}
        out_advance(n);
    } else {
        out_text("{\"key\":\"");out_integer(event->key);out_text(event->put?"\",\"store\":\"put\",\"value\":\"":"\",\"store\":\"get\",\"value\":\"");
        out_integer(event->value);out_text("\"}");
    }
    if(!frame_end())failed=1;
}
int solo5_app_main(const struct solo5_start_info *info) {
    const char *rest;int stale=0;unsigned first,end;
    if((rest=word(info->cmdline,"normal"))){}
    else if((rest=word(info->cmdline,"stale-reads")))stale=1;
    else return EXIT_USAGE;
    if(!(rest=number(rest,&first)) || *rest!=' ' || !(rest=number(rest+1,&end)) || *rest)return EXIT_USAGE;
    if(first>end || end>serve_case_count)return EXIT_USAGE;
    frame_text("{\"batch_sha256\":\"" PC_BATCH_SHA256 "\",\"kind\":\"Hello\"}");
    for(unsigned i=first;i<end;i++){
        const struct serve_case *c=&serve_cases[i];struct serve_result run;
        struct pc_value input,key,argument;const struct pc_value *parts[2];
        memset(&input,0,sizeof input);memset(&key,0,sizeof key);memset(&argument,0,sizeof argument);
        key.tag=PV_INT;key.integer=c->key;key.code=-1;
        argument.tag=PV_INT;argument.integer=c->argument;argument.code=-1;
        if(c->keyed){parts[0]=&key;parts[1]=&argument;input.tag=PV_TUPLE;input.fields=parts;input.count=2;}
        else input.tag=PV_UNIT;
        input.code=-1;
        out_begin();out_text("{\"index\":\"");out_natural(i);out_text("\",\"kind\":\"Case\"}");frame_end();
        if(c->program>=pc_program_count)return EXIT_MACHINE;
        if(serve_request(&machine,&pc_programs[c->program],c->function,&input,c->cells,c->cell_count,stale,PEER_FUEL,observe,0,&run)!=1 || failed)
            return fault("machine",EXIT_MACHINE);
        out_begin();out_text(run.completed?"{\"execution\":\"Completed\",\"kind\":\"End\",\"writes\":[":"{\"execution\":\"BudgetExhausted\",\"kind\":\"End\",\"writes\":[");
        for(unsigned k=0;k<run.write_count;k++){
            out_text(k?",[\"":"[\"");out_integer(run.writes[k].key);out_text("\",\"");out_integer(run.writes[k].value);out_text("\"]");
        }
        out_text("]}");frame_end();
    }
    frame_text("{\"kind\":\"Terminal\"}");
    return SOLO5_EXIT_SUCCESS;
}
