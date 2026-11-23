#include "port.h"
#include <errno.h>
#include <unistd.h>

int read_exact(uint8_t *p, size_t n) {
    size_t done = 0;
    while (done < n) {
        ssize_t got = read(0, p+done, n-done);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return got == 0 && done == 0 ? 0 : -1;
        done += (size_t)got;
    }
    return 1;
}
int write_exact(const uint8_t *p, size_t n) {
    while (n) {
        ssize_t sent = write(1, p, n);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return -1;
        p += sent; n -= (size_t)sent;
    }
    return 1;
}
void fen_write(const char *p, size_t n) { (void)p; (void)n; _exit(2); }
void fen_write_i64(int64_t value) { (void)value; _exit(2); }
int main(void) { return service_run(); }
