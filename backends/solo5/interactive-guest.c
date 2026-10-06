/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Cooperative fixed transport probe and isolated negative/control modes only.
 */
#include <solo5.h>
#include "protocol.h"
static char input[65537];
int solo5_app_main(const struct solo5_start_info *info) {
    const char *mode=info->cmdline;
    if(fg_equal(mode,"read-one")) return fg_syscall(63,0,(long)input,1)==1 ? 0 : 1;
    if(fg_equal(mode,"read-max")) return fg_syscall(63,0,(long)input,65536)==1 ? 0 : 1;
    if(fg_equal(mode,"other-fd")) { (void)fg_syscall(63,2,(long)input,1); return 42; }
    if(fg_equal(mode,"oversize")) { (void)fg_syscall(63,0,(long)input,65537); return 42; }
    if(fg_equal(mode,"open")) { (void)fg_syscall(56,-100,(long)"/authority/sentinel",1); return 42; }
    if(fg_equal(mode,"socket")) { (void)fg_syscall(198,2,1,0); return 42; }
    if(fg_equal(mode,"crash")) { __asm__ volatile("brk 0"); return 42; }
    if(fg_equal(mode,"loop")) { for(;;) __asm__ volatile("" ::: "memory"); }
    if(fg_equal(mode,"flood")) { for(;;) solo5_console_write(input,sizeof input); }
    if(!fg_equal(mode,"protocol") && !fg_equal(mode,"early-terminal") && !fg_equal(mode,"wrong-boundary") && !fg_equal(mode,"suffix") && !fg_equal(mode,"malformed-output")) return 1;
    fg_frame(FG_HELLO);
    if(!fg_expect(FG_INIT)) return 1;
    if(fg_equal(mode,"early-terminal")) { fg_frame(FG_TERMINAL); return 0; }
    fg_frame(fg_equal(mode,"wrong-boundary") ? FG_BOUNDARY1 : FG_BOUNDARY0);
    if(fg_equal(mode,"malformed-output")) { solo5_console_write("noise\n",6); return 1; }
    if(!fg_expect(FG_PROCEED0)) return 1;
    fg_frame(FG_BOUNDARY1);
    if(!fg_expect(FG_PROCEED1)) return 1;
    fg_frame(FG_TERMINAL);
    if(!fg_expect(FG_ACK)) return 1;
    if(fg_syscall(63,0,(long)input,1)!=0) return 1;
    if(fg_equal(mode,"suffix")) fg_frame(FG_TERMINAL);
    return 0;
}
