#include "heap.h"

typedef struct { fen_object *result; uintptr_t status; } outcome;
typedef struct { const unsigned char *p; size_t n; } span;

static int equal(span s, const char *word, int fold) {
    for (size_t i = 0; i < s.n; ++i) {
        unsigned c = s.p[i];
        if (fold && c >= 'A' && c <= 'Z') c += 'a' - 'A';
        if (!word[i] || c != (unsigned char)word[i]) return 0;
    }
    return word[s.n] == 0;
}
static int token(unsigned c) {
    if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) return 1;
    for (const char *p = "!#$%&'*+-.^_`|~"; *p; ++p)
        if (c == (unsigned char)*p) return 1;
    return 0;
}
static int white(unsigned c) { return c == ' ' || c == '\t'; }
static span trim(span s) {
    while (s.n && white(*s.p)) { ++s.p; --s.n; }
    while (s.n && white(s.p[s.n-1])) --s.n;
    return s;
}
static int wants_close(span s) {
    size_t start = 0;
    for (size_t i = 0; i <= s.n; ++i) {
        if (i < s.n && s.p[i] != ',') continue;
        if (equal(trim((span){s.p + start, i - start}), "close", 1)) return 1;
        start = i + 1;
    }
    return 0;
}

static void route(const unsigned char *p, size_t n, uintptr_t *result) {
    if (n < 5 || !equal((span){p, 5}, "GET /", 0)) return;
    size_t i = 4;
    while (i < n && p[i] > 32 && p[i] < 127) ++i;
    span path = {p + 4, i - 4};
    if (n-i < 11 || !equal((span){p+i, 11}, " HTTP/1.1\r\n", 0)) return;
    i += 11;
    int host = 0, close = 0;
    while (i < n && p[i] != '\r') {
        size_t start = i;
        while (i < n && token(p[i])) ++i;
        span field = {p+start, i-start};
        if (!field.n || i == n || p[i++] != ':') return;
        start = i;
        while (i < n && (p[i] == '\t' || (p[i] >= 32 && p[i] < 127))) ++i;
        span value = trim((span){p+start, i-start});
        if (n-i < 2 || p[i] != '\r' || p[i+1] != '\n') return;
        i += 2;
        if (equal(field, "host", 1)) {
            if (host || !value.n) return;
            host = 1;
        } else if (equal(field, "content-length", 1) || equal(field, "transfer-encoding", 1)) return;
        else if (equal(field, "connection", 1)) close |= wants_close(value);
    }
    if (!host || n-i != 2 || p[i] != '\r' || p[i+1] != '\n') return;
    result[0] = 200;
    result[1] = (uintptr_t)close;
    if (equal(path, "/", 0)) return;
    if (equal(path, "/status", 0)) { result[2] = UINTPTR_MAX; return; }
    if (path.n > 7 && equal((span){path.p,7}, "/items/", 0)) {
        size_t j = 7;
        while (j < path.n && path.p[j] >= '0' && path.p[j] <= '9') ++j;
        if (j == path.n) { result[2] = 11; result[3] = j-7; return; }
    }
    result[0] = 404;
}

outcome http_response(fen_object *args) {
    static fen_object reply;
    fen_object *head = (fen_object *)args->fields[0];
    reply.fields[0] = 431;
    reply.fields[1] = 1;
    reply.fields[2] = reply.fields[3] = 0;
    if (args->fields[1] && head->fields[0] <= 8192) {
        reply.fields[0] = 400;
        route((const unsigned char *)(head + 1), head->fields[0], reply.fields);
    }
    return (outcome){&reply, 0};
}
