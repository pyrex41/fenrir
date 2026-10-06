/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability. */
#include <solo5.h>
#include "protocol.h"
static unsigned length(const char *s) { unsigned n=0; while(s[n]) n++; return n; }
int fg_equal(const char *a,const char *b) { while(*a && *a==*b) { a++; b++; } return *a==*b; }
long fg_syscall(long nr,long a,long b,long c) {
#if defined(__aarch64__)
    register long x8 __asm__("x8")=nr;
    register long x0 __asm__("x0")=a;
    register long x1 __asm__("x1")=b;
    register long x2 __asm__("x2")=c;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8),"r"(x1),"r"(x2) : "memory","cc");
    return x0;
#else
#error Linux/AArch64 transport demo only
#endif
}
static void text(const char *s) { solo5_console_write(s,length(s)); }
void fg_frame(const char *payload) {
    char digits[16]; unsigned n=length(payload),at=sizeof digits;
    do { digits[--at]=(char)('0'+n%10); n/=10; } while(n);
    text("FGCTL/1 "); solo5_console_write(digits+at,sizeof digits-at);
    text("\n"); text(payload); text("\n");
}
static int read_exact(char *p,unsigned n) {
    while(n) { long got=fg_syscall(63,0,(long)p,n); if(got<=0 || (unsigned long)got>n) return 0; p+=got; n-=(unsigned)got; }
    return 1;
}
int fg_expect(const char *expected) {
    static char payload[65501]; char ch;
    const char *prefix="FGCTL/1 ";
    for(unsigned i=0;prefix[i];i++) if(!read_exact(&ch,1) || ch!=prefix[i]) return 0;
    unsigned n=0,digits=0;
    for(;;) {
        if(!read_exact(&ch,1)) return 0;
        if(ch=='\n') break;
        if(ch<'0' || ch>'9' || digits>=5 || (!digits && ch=='0')) return 0;
        n=n*10+(unsigned)(ch-'0'); digits++;
        if(n>65500) return 0;
    }
    if(!digits || n!=length(expected) || !read_exact(payload,n)) return 0;
    payload[n]=0;
    if(!read_exact(&ch,1) || ch!='\n') return 0;
    return fg_equal(payload,expected);
}
