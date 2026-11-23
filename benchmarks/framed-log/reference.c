#include "stream-io.h"

struct totals { uint64_t records, bytes, sum; };

static size_t number(char *dst, uint64_t n) {
    size_t count = 0;
    do {
        dst[count++] = (char)('0' + n % 10);
        n /= 10;
    } while (n);
    for (size_t i = 0; i < count / 2; ++i) {
        char tmp = dst[i];
        dst[i] = dst[count - i - 1];
        dst[count - i - 1] = tmp;
    }
    return count;
}

static int reject(uint64_t offset) {
    char message[32] = "reject ";
    size_t end = 7 + number(message + 7, offset);
    message[end++] = '\n';
    return stream_write(1, message, end) ? 2 : 1;
}

int stream_process(size_t capacity) {
    static unsigned char chunk[65536];
    static struct totals keys[64];
    enum { HIGH, LOW, KEY, PAYLOAD } phase = HIGH;
    unsigned left = 0, key = 0;
    uint64_t offset = 0;
    int size;
    while ((size = stream_read(chunk, capacity)) > 0) {
        unsigned i = 0;
        while (i < (unsigned)size) {
            switch (phase) {
            case HIGH:
                left = chunk[i++] * 256;
                phase = LOW;
                break;
            case LOW:
                left += chunk[i++];
                if (!left) return reject(offset + i - 2);
                phase = KEY;
                break;
            case KEY:
                key = chunk[i++];
                if (key >= 64) return reject(offset + i - 1);
                keys[key].records++;
                keys[key].bytes += --left;
                phase = left ? PAYLOAD : HIGH;
                break;
            case PAYLOAD: {
                unsigned available = (unsigned)size - i;
                unsigned n = available < left ? available : left;
                uint64_t sum = 0;
                for (unsigned j = 0; j < n; ++j) sum += chunk[i+j];
                keys[key].sum += sum;
                i += n;
                left -= n;
                if (!left) phase = HIGH;
                break;
            }
            }
        }
        offset += (unsigned)size;
    }
    if (size < 0) return 2;
    if (phase != HIGH) return reject(offset);
    for (unsigned k = 0; k < 64; ++k) {
        if (!keys[k].records) continue;
        char row[96];
        size_t n = number(row, k);
        row[n++] = ' ';
        n += number(row+n, keys[k].records);
        row[n++] = ' ';
        n += number(row+n, keys[k].bytes);
        row[n++] = ' ';
        n += number(row+n, keys[k].sum);
        row[n++] = '\n';
        if (stream_write(0, row, n)) return 2;
    }
    return 0;
}
