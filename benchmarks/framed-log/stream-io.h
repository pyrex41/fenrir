#include <stddef.h>
#include <stdint.h>

int stream_process(size_t capacity);
int stream_read(unsigned char *dst, size_t capacity);
int stream_write(int diagnostic, const char *src, size_t length);
_Noreturn void stream_trap(uintptr_t status);
