/* Transport/lifecycle fault peer ONLY; not a language implementation.
 * ISC: freely use/copy/modify/distribute; AS IS without warranty or liability. */
#include <solo5.h>
#include "protocol.h"
#include "peer-data.h"
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
#if PEER_KIND == 1
    for (;;) __asm__ volatile("" ::: "memory");
#elif PEER_KIND == 2
    return 0; /* EOF before Hello, not completion. */
#else
    fg_frame(PEER_HELLO);
    if (!fg_expect(PEER_INIT)) return 1;
#if PEER_KIND == 3
    return 0; /* Valid prefix, no Boundary/Terminal. */
#elif PEER_KIND == 4
    __builtin_trap(); /* Native crash, never a modeled trap. */
#elif PEER_KIND == 5
    const char partial[] = "FGCTL/1 100\n{";
    if (fg_syscall(64, 1, (long)partial, sizeof(partial)-1) != (long)(sizeof(partial)-1)) return 1;
    for (;;) __asm__ volatile("" ::: "memory");
#else
    const char bad[] = "NOT_FGCTL\n";
    long n = fg_syscall(64, 1, (long)bad, sizeof(bad)-1);
    return n == (long)(sizeof(bad)-1) ? 0 : 1;
#endif
#endif
}
