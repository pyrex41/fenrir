#include "port.h"
#include <solo5.h>

static solo5_handle_t input, output;
int read_exact(uint8_t *p, size_t n) {
    size_t done = 0;
    while (done < n) {
        size_t got = 0;
        solo5_result_t rc = solo5_net_read(input, p+done, n-done, &got);
        if (rc == SOLO5_R_AGAIN) {
            solo5_handle_set_t ready;
            solo5_yield(~(solo5_time_t)0, &ready);
            if (ready & (1ULL << output)) return done ? -1 : 0;
            continue;
        }
        if (rc != SOLO5_R_OK) return -1;
        if (!got) return done ? -1 : 0;
        done += got;
    }
    return 1;
}
int write_exact(const uint8_t *p, size_t n) {
    return solo5_net_write(output, p, n) == SOLO5_R_OK ? 1 : -1;
}
void fen_write(const char *p, size_t n) { (void)p; (void)n; solo5_exit(2); }
void fen_write_i64(int64_t value) { (void)value; solo5_exit(2); }
int solo5_app_main(const struct solo5_start_info *info) {
    (void)info;
    struct solo5_net_info net;
    if (solo5_net_acquire("ctlin", &input, &net) != SOLO5_R_OK ||
        solo5_net_acquire("ctlout", &output, &net) != SOLO5_R_OK) return 2;
    return service_run();
}
