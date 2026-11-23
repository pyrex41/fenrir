#include "heap.h"
#include "port.h"

enum { FIELD_INT, FIELD_BOOL, FIELD_BYTES, FIELD_DATA };
struct description { const char *type, *name; unsigned size; unsigned fields[8]; };
#include "types.h"

typedef struct { fen_object *value; uintptr_t status; } outcome;
extern outcome fenrir_entry(fen_object *);
extern int64_t fen_bytes_index(const fen_object *, uintptr_t);

/* The bounded port domain has one active command. Values supplied by the
 * host live through its return and only point to other host-owned objects. */
static fen_object command, cap, receipt, reply;
static struct { fen_object leaf; uint8_t data[1]; } payload;
static uint8_t packet[64], request[11], output[2048];
static size_t packet_size, request_size, used;
static int queued, failed, commits;

static int read_packet(void) {
    uint8_t header[2];
    int rc = read_exact(header, 2);
    if (rc != 1) return rc;
    packet_size = 256u * header[0] + header[1];
    if (!packet_size || packet_size > sizeof packet) return -1;
    return read_exact(packet, packet_size) == 1 ? 1 : -1;
}
static void put(uint8_t c) {
    if (used == sizeof output) failed = 1;
    else output[used++] = c;
}
static void text(const char *s) { while (*s) put((uint8_t)*s++); }
static void integer(uintptr_t n) {
    uint8_t digits[20];
    unsigned count = 0;
    if ((int64_t)n < 0) { put('-'); n = 0 - n; }
    do { digits[count++] = '0' + n % 10; n /= 10; } while (n);
    while (count) put(digits[--count]);
}
static void encode(const fen_object *obj, unsigned depth) {
    if (!obj || depth > 32 || obj->tag >= sizeof descriptions / sizeof descriptions[0]) { failed = 1; return; }
    const struct description *d = &descriptions[obj->tag];
    if (!d->name) { failed = 1; return; }
    text("[\"data\",\""); text(d->type); text("\",\""); text(d->name); put('"');
    for (unsigned i = 0; i < d->size && !failed; ++i) {
        uintptr_t field = obj->fields[i];
        put(',');
        switch (d->fields[i]) {
        case FIELD_INT: text("[\"int\",\""); integer(field); text("\"]"); break;
        case FIELD_BOOL: text(field ? "[\"bool\",true]" : "[\"bool\",false]"); break;
        case FIELD_BYTES: {
            const char *hex = "0123456789abcdef";
            const fen_object *b = (const fen_object *)field;
            text("[\"bytes\",\"");
            for (size_t j = 0; j < b->fields[0] && !failed; ++j) {
                unsigned byte = (unsigned)fen_bytes_index(b, j);
                put(hex[byte >> 4]); put(hex[byte & 15]);
            }
            text("\"]");
            break;
        }
        default: encode((const fen_object *)field, depth+1);
        }
    }
    put(']');
}
static int send_value(const fen_object *obj) {
    used = 2;
    encode(obj, 0);
    output[0] = (used - 2) >> 8;
    output[1] = (uint8_t)(used - 2);
    return !failed && write_exact(output, used) == 1;
}
static int new_command(void) {
    /* Extended submit/complete carry a nonnegative signed I64 key/job
     * in network order. The original four-byte domain stays available. */
    if (packet_size == 11)
        return (packet[0] == 3 || packet[0] == 4) && packet[1] < 2 &&
               packet[2] < 128 && packet[10] < 2;
    return packet_size == 4 && packet[0] < 2 && packet[1] < 2 && packet[2] < 2 && packet[3] < 2;
}

outcome service_commit(fen_object *transaction) {
    const outcome abort = {0, 7};
    if (++commits != 1 || !send_value(transaction) || read_packet() != 1) return abort;
    /* SQLite may abort without a Reply. A new command abandons this native
     * activation. It must unwind fully before the next request runs. */
    if (new_command()) { queued = 1; return abort; }
    size_t body = 1 + request_size;
    if (packet_size <= body || packet[0] != 2) return abort;
    for (unsigned i = 0; i < request_size; ++i) if (packet[i+1] != request[i]) return abort;
    unsigned kind = packet[body];
    if ((request[0] == 0 || request[0] == 3) && kind < 2 && packet_size == body + 42) {
        for (unsigned i = 0; i < 5; ++i) {
            uintptr_t value = 0;
            for (unsigned j = 0; j < 8; ++j) value = (value << 8) | packet[body+2+8*i+j];
            receipt.fields[i] = value;
        }
        reply.tag = kind ? TAG_Reply_Recorded : TAG_Reply_Committed;
        reply.fields[0] = kind ? packet[body+1] : (uintptr_t)&receipt;
        reply.fields[1] = (uintptr_t)&receipt;
    } else if ((kind == 2 || kind == 3) && packet_size == body + 1) {
        reply.tag = kind == 2 ? TAG_Reply_Applied : TAG_Reply_Skipped;
    } else return abort;
    return (outcome){&reply, 0};
}

int service_run(void) {
    command.live = cap.live = receipt.live = reply.live = payload.leaf.live = FEN_IMAGE_OBJECT;
    cap.tag = TAG_Cap_Tenant;
    receipt.tag = TAG_Receipt_Receipt;
    payload.leaf.tag = UINT32_MAX;
    payload.leaf.fields[0] = 1;
    for (;;) {
        if (!queued) {
            int rc = read_packet();
            if (rc != 1) return rc == 0 ? 0 : 2;
        }
        queued = 0;
        if (!new_command()) return 2;
        request_size = packet_size;
        for (unsigned i = 0; i < request_size; ++i) request[i] = packet[i];
        commits = 0;
        command.tag = (request[0] == 1 || request[0] == 4) ? TAG_Command_Complete : TAG_Command_Submit;
        cap.fields[0] = request[1];
        command.fields[0] = (uintptr_t)&cap;
        uintptr_t key = 0;
        for (size_t i = 2; i < request_size - 1; ++i) key = (key << 8) | request[i];
        command.fields[1] = key;
        command.fields[2] = payload.data[0] = request[request_size - 1];
        command.fields[3] = (uintptr_t)&payload.leaf;
        outcome result = fenrir_entry(&command);
        if (queued && result.status == 7) continue;
        if (result.status || commits != 1 || !send_value(result.value)) return 2;
    }
}
