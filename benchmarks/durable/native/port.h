#ifndef FEN_SERVICE_PORT_H
#define FEN_SERVICE_PORT_H
#include <stddef.h>
#include <stdint.h>
/* Return 1 for a complete transfer, 0 for a clean initial EOF, -1 on failure. */
int read_exact(uint8_t *p, size_t n);
int write_exact(const uint8_t *p, size_t n);
int service_run(void);
#endif
