/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Closed cooperative environment demonstration, not a TC0 implementation.
 * Independently spelled wire expectations; no host checker code linked here. */
#include <solo5.h>
#include "virtual-env.h"
#include "protocol.h"
#define PROFILE "fenrir.solo5.cooperative-environment/1"
#define COMMON "\"profile\":\"" PROFILE "\",\"run_id\":\"environment-0\","
#define D0 "8f2d92f440c831a56c464d6a7aed6b0d5600b88ae8a2dd4e8b30889b0deb5704"
#define D1 "ab6ffe22b6865b3d71a2cc1da8deb7e74f1de10edcf340f8d3962e79fb6c5c2a"
#define D2 "b53798296776dbb6415b610cb0c1faa5782903e7eff0f5191e3aad8fe78e16ad"
#define D3 "58532fd1fbe7be41923ee244135ec36aa86157b1d480bf62db255d8b425abe67"
#define D4 "3912399f2b61e32aa7aaf887e9c7ac664ed071b53e774dc88743b78af1b5b113"
#define D5 "10d9649b107ed3541b7770b62a03e613285f1aedbdd49abfc2a6091f873aec19"
static unsigned append(char *out, unsigned at, const char *text) {
    while (*text) out[at++]=*text++;
    out[at]=0;
    return at;
}
static unsigned decimal(char *out, unsigned at, uint64_t n) {
    char digits[20]; unsigned end=20;
    do { digits[--end]=(char)('0'+n%10); n/=10; } while(n);
    while(end<20) out[at++]=digits[end++];
    out[at]=0;
    return at;
}
static void reading(const char *epoch,const char *seq,const char *site) {
    char record[512]; unsigned at=0;
    uint64_t m=solo5_clock_monotonic(), w=solo5_clock_wall();
    at=append(record,at,"{\"epoch\":\""); at=append(record,at,epoch);
    at=append(record,at,"\",\"kind\":\"Clock\",\"monotonic\":\"");
    at=decimal(record,at,m); at=append(record,at,"\"," COMMON "\"sequence\":\"");
    at=append(record,at,seq); at=append(record,at,"\",\"site\":\"");
    at=append(record,at,site); at=append(record,at,"\",\"wall\":\"");
    at=decimal(record,at,w); (void)append(record,at,"\"}");
    fg_frame(record);
}
int solo5_app_main(const struct solo5_start_info *info) {
    const char *mode=info->cmdline;
    if(fg_equal(mode,"crash")) { __asm__ volatile("brk 0"); return 42; }
    if(fg_equal(mode,"loop")) { for(;;) __asm__ volatile("" ::: "memory"); }
    if(!fg_equal(mode,"environment") && !fg_equal(mode,"future-yield") &&
       !fg_equal(mode,"read-before-init")) return 1;
    if(fg_equal(mode,"read-before-init")) { (void)solo5_clock_monotonic(); return 42; }
    fg_frame("{\"domain_hash\":\"" D0 "\",\"epoch\":\"0\",\"kind\":\"Hello\"," COMMON "\"sequence\":\"0\",\"site\":\"Init\"}");
    if(!fg_expect("{\"domain_hash\":\"" D0 "\",\"epoch\":\"0\",\"kind\":\"Init\"," COMMON "\"sequence\":\"0\",\"site\":\"Init\",\"time\":\"0\",\"wall_origin\":\"1000\"}")) return 1;
    if(!solo5_fenrir_env_init(1000)) return 1;
    if(fg_equal(mode,"future-yield")) { solo5_yield(1,0); return 42; }
    solo5_handle_set_t ready=~(solo5_handle_set_t)0;
    solo5_yield(0,&ready); if(ready) return 1;
    reading("1","1","Read0");
    if(!fg_expect("{\"domain_hash\":\"" D1 "\",\"epoch\":\"1\",\"kind\":\"Hold\"," COMMON "\"sequence\":\"1\",\"site\":\"Read0\"}")) return 1;
    reading("2","2","Read1");
    if(!fg_expect("{\"domain_hash\":\"" D2 "\",\"epoch\":\"2\",\"kind\":\"Advance\"," COMMON "\"sequence\":\"2\",\"site\":\"Advance10\",\"time\":\"10\"}")) return 1;
    if(!solo5_fenrir_env_advance(10)) return 1;
    solo5_yield(10,&ready); if(ready) return 1;
    reading("3","3","Read2");
    if(!fg_expect("{\"domain_hash\":\"" D3 "\",\"epoch\":\"3\",\"kind\":\"Hold\"," COMMON "\"sequence\":\"3\",\"site\":\"Read2\"}")) return 1;
    reading("4","4","Read3");
    if(!fg_expect("{\"domain_hash\":\"" D4 "\",\"epoch\":\"4\",\"kind\":\"Hold\"," COMMON "\"sequence\":\"4\",\"site\":\"Read3\"}")) return 1;
    fg_frame("{\"accepted\":\"5\",\"domain_hash\":\"" D5 "\",\"epoch\":\"5\",\"kind\":\"Terminal\"," COMMON "\"sequence\":\"5\",\"site\":\"Terminal\"}");
    if(!fg_expect("{\"domain_hash\":\"" D5 "\",\"epoch\":\"5\",\"kind\":\"Ack\"," COMMON "\"sequence\":\"5\",\"site\":\"Terminal\"}")) return 1;
    char end;
    return fg_syscall(63,0,(long)&end,1)==0 ? 0 : 1;
}
