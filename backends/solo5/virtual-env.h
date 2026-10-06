/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability. */
#ifndef FENRIR_VIRTUAL_ENV_H
#define FENRIR_VIRTUAL_ENV_H
#include <stdint.h>
/* Cooperative development profile only. No reset or ambient input interface.
 * solo5_ prefix deliberately survives upstream bindings symbol localization. */
int solo5_fenrir_env_init(uint64_t wall_origin);
int solo5_fenrir_env_advance(uint64_t absolute_time);
int solo5_fenrir_env_read(uint64_t *monotonic, uint64_t *wall);
int solo5_fenrir_env_ready(uint64_t deadline);
#endif
