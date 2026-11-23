#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>

static unsigned char stream_buffer[65536];

static int32_t stream_read(int32_t limit) {
    ssize_t n;
    do { n = read(STDIN_FILENO, stream_buffer, (size_t)limit); }
    while (n < 0 && errno == EINTR);
    if (n < 0) exit(2);
    return (int32_t)n;
}
