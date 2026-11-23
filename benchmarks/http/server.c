#include "heap.h"
#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

enum { LIMIT = 8192, CONNECTIONS = 64 };
typedef struct { fen_object leaf; unsigned char data[LIMIT]; } request;
typedef struct { fen_object *result; uintptr_t status; } outcome;
extern outcome http_response(fen_object *);
static pthread_mutex_t runtime_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_uint active;
#ifdef FENRIR_HTTP_PROFILE_LOCK
#include <time.h>
static _Thread_local uint64_t calls, wait_ns, held_ns;
#endif
void fen_write(const char *p, size_t n) { fwrite(p, 1, n, stderr); }
void fen_write_i64(int64_t n) { fprintf(stderr, "%lld", (long long)n); }

static int write_all(int fd, const char *p, size_t n) {
    while (n) {
        ssize_t used = send(fd, p, n, 0);
        if (used < 0 && errno == EINTR) continue;
        if (used <= 0) return -1;
        p += used;
        n -= (size_t)used;
    }
    return 0;
}

static int respond(int fd, request *head, int complete) {
    fen_object args = {.fields = {(uintptr_t)&head->leaf, (uintptr_t)complete}, .live = FEN_IMAGE_OBJECT};
    uintptr_t fields[4];
    // The native runtime owns one heap. Copy the scalar decision before another invocation.
#ifdef FENRIR_HTTP_PROFILE_LOCK
    uint64_t before_lock = clock_gettime_nsec_np(CLOCK_MONOTONIC);
#endif
    pthread_mutex_lock(&runtime_lock);
#ifdef FENRIR_HTTP_PROFILE_LOCK
    uint64_t acquired = clock_gettime_nsec_np(CLOCK_MONOTONIC);
#endif
    outcome result = http_response(&args);
    if (!result.status) memcpy(fields, result.result->fields, sizeof fields);
#ifdef FENRIR_HTTP_PROFILE_LOCK
    uint64_t releasing = clock_gettime_nsec_np(CLOCK_MONOTONIC);
#endif
    pthread_mutex_unlock(&runtime_lock);
#ifdef FENRIR_HTTP_PROFILE_LOCK
    ++calls;
    wait_ns += acquired - before_lock;
    held_ns += releasing - acquired;
#endif
    if (result.status) return -1;

    const char *status, *kind = "text/plain", *body = "";
    size_t size = 0;
    switch (fields[0]) {
    case 200:
        status = "200 OK";
        if (fields[2] == UINTPTR_MAX) {
            kind = "application/json";
            body = "{\"ok\":true}\n";
            size = strlen(body);
        } else if (fields[2] == 0) {
            body = "fenrir\n";
            size = strlen(body);
        } else {
            if (fields[2] > head->leaf.fields[0] || fields[3] > head->leaf.fields[0] - fields[2]) return -1;
            body = (const char *)head->data + fields[2];
            size = fields[3];
        }
        break;
    case 400: status = "400 Bad Request"; break;
    case 404: status = "404 Not Found"; break;
    case 431: status = "431 Request Header Fields Too Large"; break;
    default: return -1;
    }
    char header[256];
    int n = snprintf(header, sizeof header,
        "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nConnection: %s\r\n\r\n",
        status, kind, size, fields[1] ? "close" : "keep-alive");
    if (n < 0 || (size_t)n >= sizeof header) return -1;
    size_t header_size = (size_t)n;
    if (size <= sizeof header - header_size) {
        memcpy(header + header_size, body, size);
        if (write_all(fd, header, header_size + size)) return -1;
    } else if (write_all(fd, header, header_size) || write_all(fd, body, size)) {
        return -1;
    }
    return fields[1] ? 1 : 0;
}

static void *serve(void *arg) {
    int fd = (int)(intptr_t)arg;
    struct timeval timeout = {.tv_sec = 5};
    request head = {.leaf = {.tag = UINT32_MAX, .live = FEN_IMAGE_OBJECT}};
    char buf[8192];
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout) ||
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout)) goto done;
    for (;;) {
        ssize_t n = recv(fd, buf, sizeof buf, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        for (ssize_t i = 0; i < n; ++i) {
            size_t used = head.leaf.fields[0];
            head.data[used++] = (unsigned char)buf[i];
            head.leaf.fields[0] = used;
            int complete = used >= 4 && !memcmp(head.data + used - 4, "\r\n\r\n", 4);
            if (complete || used == LIMIT) {
                if (respond(fd, &head, complete)) goto done;
                head.leaf.fields[0] = 0;
            }
        }
    }
done:
#ifdef FENRIR_HTTP_PROFILE_LOCK
    fprintf(stderr, "{\"calls\":%llu,\"wait_ns\":%llu,\"held_ns\":%llu}\n",
            (unsigned long long)calls, (unsigned long long)wait_ns, (unsigned long long)held_ns);
#endif
    shutdown(fd, SHUT_WR);
    close(fd);
    atomic_fetch_sub(&active, 1);
    return NULL;
}

int main(int argc, char **argv) {
    char *end;
    if (argc != 2) return 2;
    long port = strtol(argv[1], &end, 10);
    if (end == argv[1] || *end || port < 0 || port > 65535) return 2;
    signal(SIGPIPE, SIG_IGN);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
                               .sin_port = htons((uint16_t)port)};
    socklen_t len = sizeof addr;
    if (fd < 0 || bind(fd, (struct sockaddr *)&addr, len) || listen(fd, CONNECTIONS) ||
        getsockname(fd, (struct sockaddr *)&addr, &len)) { perror("listen"); return 2; }
    fprintf(stderr, "127.0.0.1:%u\n", ntohs(addr.sin_port));
    for (;;) {
        int client = accept(fd, NULL, NULL);
        if (client < 0 && errno == EINTR) continue;
        if (client < 0) { perror("accept"); return 2; }
        pthread_t thread;
        if (atomic_fetch_add(&active, 1) >= CONNECTIONS ||
            pthread_create(&thread, NULL, serve, (void *)(intptr_t)client)) {
            close(client);
            atomic_fetch_sub(&active, 1);
        } else pthread_detach(thread);
    }
}
