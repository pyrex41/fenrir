/* Fenrir Solo5 startup-transport feasibility probe; not a TC0 runtime.
 * ISC license, same permissions/disclaimer as Solo5. No clocks/devices used.
 * Stock console is output-only: command-line input is STARTUP ONLY.
 */
#include <solo5.h>
static unsigned length(const char *s) {unsigned n=0;while(s[n]) n++;return n;}
static int equal(const char *a,const char *b) {while(*a && *a==*b) {a++;b++;}return *a==*b;}
static void write_text(const char *s) {solo5_console_write(s,length(s));}
static void frame(const char *payload) {
    char digits[16];unsigned n=length(payload),at=sizeof digits;
    do {digits[--at]=(char)('0'+n%10);n/=10;} while(n);
    write_text("FG0/1 ");solo5_console_write(digits+at,sizeof digits-at);write_text("\n");
    write_text(payload);write_text("\n");
}
static long forbidden(long number,long arg0,long arg1,long arg2) {
#if defined(__aarch64__)
    register long nr __asm__("x8")=number;
    register long a0 __asm__("x0")=arg0;
    register long a1 __asm__("x1")=arg1;
    register long a2 __asm__("x2")=arg2;
    __asm__ volatile("svc 0" : "+r"(a0) : "r"(nr),"r"(a1),"r"(a2) : "memory","cc");
    return a0;
#else
#error This measured probe targets Linux/AArch64 only
#endif
}
int solo5_app_main(const struct solo5_start_info *info) {
    if (equal(info->cmdline,"probe-forbidden-open")) {
        (void)forbidden(56,-100,(long)"/authority/sentinel",1);return 42;
    }
    if (equal(info->cmdline,"probe-forbidden-socket")) {
        (void)forbidden(198,2,1,0);return 42;
    }
    if (equal(info->cmdline,"probe-stock-clock")) {
        char digits[32];unsigned at=sizeof digits;
        uint64_t n=solo5_clock_wall();
        do {digits[--at]=(char)('0'+n%10);n/=10;} while(n);
        write_text("FGCLOCK ");solo5_console_write(digits+at,sizeof digits-at);write_text("\n");
        return SOLO5_EXIT_SUCCESS;
    }
    /* Exact bounded startup request; no permissive parsing or seed fallback. */
    if (!equal(info->cmdline,"FG0/1 30\n{\"kind\":\"Ping\",\"sequence\":\"0\"}\n")) return SOLO5_EXIT_FAILURE;
    frame("{\"kind\":\"Pong\",\"sequence\":\"0\",\"value\":\"pong\"}");
    frame("{\"kind\":\"Terminal\",\"outcome\":\"Ok\",\"sequence\":\"1\"}");
    return SOLO5_EXIT_SUCCESS;
}
