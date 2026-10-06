/* Stock-policy INPUT CAPABILITY probe, NOT an interactive TC0 guest.
 * ISC license: permission to use/copy/modify/distribute for any purpose with
 * or without fee is granted; provided AS IS without warranties or liability.
 * Linux/AArch64 only. No device/clock APIs, no expanded tender permissions.
 */
#include <solo5.h>
static unsigned length(const char *s) { unsigned n=0; while(s[n]) n++; return n; }
static int equal(const char *a,const char *b) { while(*a && *a==*b) { a++; b++; } return *a==*b; }
static void text(const char *s) { solo5_console_write(s,length(s)); }
static void frame(const char *payload) {
    char digits[16]; unsigned n=length(payload),at=sizeof digits;
    do { digits[--at]=(char)('0'+n%10); n/=10; } while(n);
    text("FGIO0/1 "); solo5_console_write(digits+at,sizeof digits-at);
    text("\n"); text(payload); text("\n");
}
static long read_stdin(char *buf) {
#if defined(__aarch64__)
    register long nr __asm__("x8")=63;
    register long fd __asm__("x0")=0;
    register long p __asm__("x1")=(long)buf;
    register long n __asm__("x2")=1;
    __asm__ volatile("svc 0" : "+r"(fd) : "r"(nr),"r"(p),"r"(n) : "memory","cc");
    return fd;
#else
#error This stock-policy feasibility probe targets Linux/AArch64
#endif
}
int solo5_app_main(const struct solo5_start_info *info) {
    if(!equal(info->cmdline,"control") && !equal(info->cmdline,"read-stdin")) return SOLO5_EXIT_FAILURE;
    frame("{\"kind\":\"ProbeReady\",\"sequence\":\"0\"}");
    if(equal(info->cmdline,"read-stdin")) {
        char byte=0;
        frame("{\"fd\":\"0\",\"kind\":\"InputAttempt\",\"sequence\":\"1\"}");
        (void)read_stdin(&byte); /* Stock no-device whitelist is expected to kill here. */
        frame("{\"kind\":\"UnexpectedReadReturn\",\"sequence\":\"2\"}");
        return 42;
    }
    frame("{\"kind\":\"Terminal\",\"outcome\":\"Ok\",\"sequence\":\"1\"}");
    return SOLO5_EXIT_SUCCESS;
}
