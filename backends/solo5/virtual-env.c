/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability. */
#include "virtual-env.h"
#define FENRIR_TIME_MAX UINT64_C(9223372036854775807)
static uint64_t env_time, env_origin;
static int env_initialized;
int solo5_fenrir_env_init(uint64_t wall_origin) {
    if (env_initialized || wall_origin > FENRIR_TIME_MAX) return 0;
    env_origin = wall_origin;
    env_time = 0;
    env_initialized = 1;
    return 1;
}
int solo5_fenrir_env_advance(uint64_t absolute_time) {
    if (!env_initialized || absolute_time < env_time ||
        absolute_time > FENRIR_TIME_MAX - env_origin) return 0;
    env_time = absolute_time;
    return 1;
}
int solo5_fenrir_env_read(uint64_t *monotonic, uint64_t *wall) {
    if (!env_initialized || !monotonic || !wall || monotonic == wall) return 0;
    *monotonic = env_time;
    *wall = env_origin + env_time;
    return 1;
}
int solo5_fenrir_env_ready(uint64_t deadline) {
    return env_initialized && deadline <= env_time;
}
