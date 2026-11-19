/* Fenrir A3 host infrastructure: a small SQLite port program for the OTP storage adapter
 * (host/service/src/fenrir_store.erl). It holds ONE SQLite connection and executes the
 * statements it is sent, one at a time, and answers each with its rows or its error code.
 * It makes no storage decision: the transaction logic (BEGIN IMMEDIATE ... COMMIT) is in
 * the Erlang adapter. Named assumption, not covered by Fenrir's proofs.
 *
 * Transport: stdin/stdout of an Erlang port with {packet,4}: every message is a 4-byte
 * big-endian length and that many bytes.
 *
 * Requests:
 *   'O' path                     open (creating) the database at path with the "fenrir"
 *                                VFS below; answer 'K'
 *   'E' u32 n sql u16 k param*   prepare, bind, step to SQLITE_DONE; answer rows or error
 *   'F' u8 kind u32 n            arm a fault (kill -9 of this process, for crash campaigns):
 *                                1 before the n-th file write from now, 2 before the n-th
 *                                fsync from now, 3 after the n-th statement from now has
 *                                completed but before its answer is written (a lost
 *                                acknowledgment), 4 before the n-th statement from now is
 *                                executed, 5 after the n-th successful COMMIT before its
 *                                answer, 0 disarm every fault; answer 'K'.
 *   'W'                          answer 'R' with the write and fsync counters since open
 *   'C'                          close and exit 0
 * Values: 'n' | 'i' i64(BE) | 't' u32 n bytes | 'b' u32 n bytes.
 * Answers: 'K' | 'R' u32 rows u16 cols value* | 'X' i32 primary i32 extended u32 n message.
 * Diagnostic (not a SQL answer): 'L' immediately before a kind-5 SIGKILL.
 *
 * Exit status: 0 after 'C' or EOF on stdin; 2 on a malformed request or I/O failure. */
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sqlite3.h>

/* ---------- framing ---------- */

static int read_full(void *p, size_t n) {
    unsigned char *b = p;
    while (n) {
        ssize_t r = read(0, b, n);
        if (r <= 0) return 0;
        b += r; n -= (size_t)r;
    }
    return 1;
}
static void write_full(const void *p, size_t n) {
    const unsigned char *b = p;
    while (n) {
        ssize_t r = write(1, b, n);
        if (r <= 0) _exit(2);
        b += r; n -= (size_t)r;
    }
}

static unsigned char *out; static size_t out_used, out_cap;
static void out_reset(void) { out_used = 4; }
static void out_bytes(const void *p, size_t n) {
    if (out_used + n > out_cap) {
        size_t cap = out_cap ? out_cap : 4096;
        while (cap < out_used + n) cap *= 2;
        out = realloc(out, cap); if (!out) _exit(2);
        out_cap = cap;
    }
    memcpy(out + out_used, p, n); out_used += n;
}
static void out_u8(unsigned v) { unsigned char c = (unsigned char)v; out_bytes(&c, 1); }
static void out_u16(unsigned v) { unsigned char b[2] = {(unsigned char)(v >> 8), (unsigned char)v}; out_bytes(b, 2); }
static void out_u32(uint32_t v) { unsigned char b[4] = {(unsigned char)(v >> 24), (unsigned char)(v >> 16), (unsigned char)(v >> 8), (unsigned char)v}; out_bytes(b, 4); }
static void out_i64(int64_t s) { uint64_t v = (uint64_t)s; for (int i = 7; i >= 0; i--) out_u8((unsigned)(v >> (8 * i)) & 255u); }
static void out_send(void) {
    uint32_t n = (uint32_t)(out_used - 4);
    out[0] = (unsigned char)(n >> 24); out[1] = (unsigned char)(n >> 16); out[2] = (unsigned char)(n >> 8); out[3] = (unsigned char)n;
    write_full(out, out_used);
}

/* ---------- faults ---------- */

static long fault_write = -1, fault_sync = -1, fault_after_stmt = -1, fault_before_stmt = -1, fault_after_commit = -1;
static unsigned long writes, syncs;
static void die(void) { kill(getpid(), SIGKILL); _exit(9); }

/* ---------- the "fenrir" VFS: the default unix VFS, with counted writes and syncs ---------- */

struct shim_file { sqlite3_file base; sqlite3_file *real; };
static sqlite3_vfs *real_vfs;
static sqlite3_io_methods shim_methods;

#define REAL(f) (((struct shim_file *)(f))->real)
static int s_close(sqlite3_file *f) { int rc = REAL(f)->pMethods ? REAL(f)->pMethods->xClose(REAL(f)) : SQLITE_OK; free(REAL(f)); return rc; }
static int s_read(sqlite3_file *f, void *b, int n, sqlite3_int64 o) { return REAL(f)->pMethods->xRead(REAL(f), b, n, o); }
static int s_write(sqlite3_file *f, const void *b, int n, sqlite3_int64 o) {
    writes++;
    if (fault_write > 0 && --fault_write == 0) die();
    return REAL(f)->pMethods->xWrite(REAL(f), b, n, o);
}
static int s_truncate(sqlite3_file *f, sqlite3_int64 s) { return REAL(f)->pMethods->xTruncate(REAL(f), s); }
static int s_sync(sqlite3_file *f, int fl) {
    syncs++;
    if (fault_sync > 0 && --fault_sync == 0) die();
    return REAL(f)->pMethods->xSync(REAL(f), fl);
}
static int s_size(sqlite3_file *f, sqlite3_int64 *s) { return REAL(f)->pMethods->xFileSize(REAL(f), s); }
static int s_lock(sqlite3_file *f, int l) { return REAL(f)->pMethods->xLock(REAL(f), l); }
static int s_unlock(sqlite3_file *f, int l) { return REAL(f)->pMethods->xUnlock(REAL(f), l); }
static int s_check(sqlite3_file *f, int *r) { return REAL(f)->pMethods->xCheckReservedLock(REAL(f), r); }
static int s_fcntl(sqlite3_file *f, int op, void *a) { return REAL(f)->pMethods->xFileControl(REAL(f), op, a); }
static int s_sector(sqlite3_file *f) { return REAL(f)->pMethods->xSectorSize(REAL(f)); }
static int s_dev(sqlite3_file *f) { return REAL(f)->pMethods->xDeviceCharacteristics(REAL(f)); }
static int s_shmmap(sqlite3_file *f, int r, int sz, int e, void volatile **p) { return REAL(f)->pMethods->xShmMap(REAL(f), r, sz, e, p); }
static int s_shmlock(sqlite3_file *f, int o, int n, int fl) { return REAL(f)->pMethods->xShmLock(REAL(f), o, n, fl); }
static void s_shmbarrier(sqlite3_file *f) { REAL(f)->pMethods->xShmBarrier(REAL(f)); }
static int s_shmunmap(sqlite3_file *f, int d) { return REAL(f)->pMethods->xShmUnmap(REAL(f), d); }
static int s_fetch(sqlite3_file *f, sqlite3_int64 o, int n, void **p) { return REAL(f)->pMethods->xFetch(REAL(f), o, n, p); }
static int s_unfetch(sqlite3_file *f, sqlite3_int64 o, void *p) { return REAL(f)->pMethods->xUnfetch(REAL(f), o, p); }

static int s_open(sqlite3_vfs *v, const char *name, sqlite3_file *f, int flags, int *outflags) {
    (void)v;
    struct shim_file *s = (struct shim_file *)f;
    s->real = calloc(1, (size_t)real_vfs->szOsFile);
    if (!s->real) return SQLITE_NOMEM;
    int rc = real_vfs->xOpen(real_vfs, name, s->real, flags, outflags);
    if (rc != SQLITE_OK || !s->real->pMethods) { free(s->real); s->real = 0; f->pMethods = 0; return rc; }
    /* Forward exactly the method versions the real file has. */
    shim_methods.iVersion = s->real->pMethods->iVersion;
    f->pMethods = &shim_methods;
    return SQLITE_OK;
}
static int v_delete(sqlite3_vfs *v, const char *n, int d) { (void)v; return real_vfs->xDelete(real_vfs, n, d); }
static int v_access(sqlite3_vfs *v, const char *n, int fl, int *r) { (void)v; return real_vfs->xAccess(real_vfs, n, fl, r); }
static int v_full(sqlite3_vfs *v, const char *n, int k, char *o) { (void)v; return real_vfs->xFullPathname(real_vfs, n, k, o); }
static void *v_dlopen(sqlite3_vfs *v, const char *n) { (void)v; return real_vfs->xDlOpen(real_vfs, n); }
static void v_dlerror(sqlite3_vfs *v, int n, char *m) { (void)v; real_vfs->xDlError(real_vfs, n, m); }
static void (*v_dlsym(sqlite3_vfs *v, void *h, const char *s))(void) { (void)v; return real_vfs->xDlSym(real_vfs, h, s); }
static void v_dlclose(sqlite3_vfs *v, void *h) { (void)v; real_vfs->xDlClose(real_vfs, h); }
static int v_random(sqlite3_vfs *v, int n, char *o) { (void)v; return real_vfs->xRandomness(real_vfs, n, o); }
static int v_sleep(sqlite3_vfs *v, int us) { (void)v; return real_vfs->xSleep(real_vfs, us); }
static int v_time(sqlite3_vfs *v, double *t) { (void)v; return real_vfs->xCurrentTime(real_vfs, t); }
static int v_lasterr(sqlite3_vfs *v, int n, char *m) { (void)v; return real_vfs->xGetLastError ? real_vfs->xGetLastError(real_vfs, n, m) : 0; }
static int v_time64(sqlite3_vfs *v, sqlite3_int64 *t) { (void)v; return real_vfs->xCurrentTimeInt64(real_vfs, t); }

static sqlite3_vfs shim_vfs;
static void register_vfs(void) {
    real_vfs = sqlite3_vfs_find(0);
    if (!real_vfs) _exit(2);
    shim_methods = (sqlite3_io_methods){3, s_close, s_read, s_write, s_truncate, s_sync, s_size, s_lock, s_unlock,
        s_check, s_fcntl, s_sector, s_dev, s_shmmap, s_shmlock, s_shmbarrier, s_shmunmap, s_fetch, s_unfetch};
    shim_vfs = (sqlite3_vfs){2, (int)sizeof(struct shim_file), real_vfs->mxPathname, 0, "fenrir", 0,
        s_open, v_delete, v_access, v_full, v_dlopen, v_dlerror, v_dlsym, v_dlclose, v_random, v_sleep, v_time,
        v_lasterr, v_time64, 0, 0, 0};
    if (sqlite3_vfs_register(&shim_vfs, 0) != SQLITE_OK) _exit(2);
}

/* ---------- requests ---------- */

static sqlite3 *db;
static unsigned char *req; static size_t req_n, req_at;
static int take(void *p, size_t n) { if (req_at + n > req_n) return 0; memcpy(p, req + req_at, n); req_at += n; return 1; }
static int take_u32(uint32_t *v) { unsigned char b[4]; if (!take(b, 4)) return 0; *v = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3]; return 1; }
static int take_u16(unsigned *v) { unsigned char b[2]; if (!take(b, 2)) return 0; *v = ((unsigned)b[0] << 8) | b[1]; return 1; }

static void answer_error(int primary, int extended, const char *msg) {
    out_reset(); out_u8('X'); out_u32((uint32_t)primary); out_u32((uint32_t)extended);
    size_t n = msg ? strlen(msg) : 0; out_u32((uint32_t)n); out_bytes(msg ? msg : "", n); out_send();
}
static void answer_ok(void) { out_reset(); out_u8('K'); out_send(); }

static void exec_request(void) {
    uint32_t n; unsigned k;
    if (!take_u32(&n) || req_at + n > req_n) _exit(2);
    const char *sql = (const char *)req + req_at; req_at += n;
    if (!take_u16(&k)) _exit(2);
    if (fault_before_stmt > 0 && --fault_before_stmt == 0) die();
    sqlite3_stmt *st = 0;
    int rc = sqlite3_prepare_v2(db, sql, (int)n, &st, 0);
    if (rc != SQLITE_OK) { answer_error(rc & 255, sqlite3_extended_errcode(db), sqlite3_errmsg(db)); return; }
    for (unsigned i = 1; i <= k; i++) {
        unsigned char tag; if (!take(&tag, 1)) _exit(2);
        if (tag == 'n') sqlite3_bind_null(st, (int)i);
        else if (tag == 'i') {
            unsigned char b[8]; if (!take(b, 8)) _exit(2);
            uint64_t v = 0; for (int j = 0; j < 8; j++) v = (v << 8) | b[j];
            sqlite3_bind_int64(st, (int)i, (sqlite3_int64)v);
        } else if (tag == 't' || tag == 'b') {
            uint32_t m; if (!take_u32(&m) || req_at + m > req_n) _exit(2);
            if (tag == 't') sqlite3_bind_text(st, (int)i, (const char *)req + req_at, (int)m, SQLITE_TRANSIENT);
            else sqlite3_bind_blob(st, (int)i, req + req_at, (int)m, SQLITE_TRANSIENT);
            req_at += m;
        } else _exit(2);
    }
    /* Rows are collected first: an error after some rows answers only the error. */
    unsigned char *rows = 0; size_t rows_n = 0, rows_cap = 0; uint32_t count = 0;
    int cols = sqlite3_column_count(st);
    for (;;) {
        rc = sqlite3_step(st);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) {
            int ext = sqlite3_extended_errcode(db);
            answer_error(rc & 255, ext, sqlite3_errmsg(db));
            sqlite3_finalize(st); free(rows); return;
        }
        size_t mark = out_used; out_reset();
        for (int c = 0; c < cols; c++) {
            int t = sqlite3_column_type(st, c);
            if (t == SQLITE_NULL) out_u8('n');
            else if (t == SQLITE_INTEGER) { out_u8('i'); out_i64(sqlite3_column_int64(st, c)); }
            else if (t == SQLITE_BLOB) { const void *p = sqlite3_column_blob(st, c); int m = sqlite3_column_bytes(st, c); out_u8('b'); out_u32((uint32_t)m); out_bytes(p, (size_t)m); }
            else { const unsigned char *p = sqlite3_column_text(st, c); int m = sqlite3_column_bytes(st, c); out_u8('t'); out_u32((uint32_t)m); out_bytes(p, (size_t)m); }
        }
        (void)mark;
        size_t m = out_used - 4;
        if (rows_n + m > rows_cap) { rows_cap = (rows_n + m) * 2 + 256; rows = realloc(rows, rows_cap); if (!rows) _exit(2); }
        memcpy(rows + rows_n, out + 4, m); rows_n += m; count++;
    }
    sqlite3_finalize(st);
    /* Emit a diagnostic, NOT a SQL reply. It identifies the exact operation on
       this connection; the driver also needs the port's SIGKILL exit status. */
    if (n == 6 && memcmp(sql, "COMMIT", 6) == 0 &&
        fault_after_commit > 0 && --fault_after_commit == 0) {
        out_reset(); out_u8('L'); out_send();
        die();
    }
    if (fault_after_stmt > 0 && --fault_after_stmt == 0) die();
    out_reset(); out_u8('R'); out_u32(count); out_u16((unsigned)cols); out_bytes(rows ? rows : (unsigned char *)"", rows_n); out_send();
    free(rows);
}

int main(void) {
    register_vfs();
    for (;;) {
        unsigned char h[4];
        if (!read_full(h, 4)) break;
        req_n = ((size_t)h[0] << 24) | ((size_t)h[1] << 16) | ((size_t)h[2] << 8) | h[3];
        if (req_n < 1 || req_n > (64u << 20)) _exit(2);
        free(req); req = malloc(req_n); req_at = 1;
        if (!req || !read_full(req, req_n)) _exit(2);
        switch (req[0]) {
        case 'O': {
            if (db) _exit(2);
            char *path = malloc(req_n); if (!path) _exit(2);
            memcpy(path, req + 1, req_n - 1); path[req_n - 1] = 0;
            int rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, "fenrir");
            free(path);
            if (rc != SQLITE_OK) { answer_error(rc & 255, rc, db ? sqlite3_errmsg(db) : "open"); sqlite3_close(db); db = 0; }
            else { sqlite3_extended_result_codes(db, 1); writes = syncs = 0; answer_ok(); }
            break;
        }
        case 'E': if (!db) _exit(2); exec_request(); break;
        case 'F': {
            unsigned char kind; uint32_t n;
            if (!take(&kind, 1) || !take_u32(&n) || n < 1) _exit(2);
            if (kind == 0) fault_write = fault_sync = fault_after_stmt = fault_before_stmt = fault_after_commit = -1;
            else if (kind == 1) fault_write = n; else if (kind == 2) fault_sync = n;
            else if (kind == 3) fault_after_stmt = n; else if (kind == 4) fault_before_stmt = n;
            else if (kind == 5) fault_after_commit = n; else _exit(2);
            answer_ok();
            break;
        }
        case 'W': out_reset(); out_u8('R'); out_u32(1); out_u16(2); out_u8('i'); out_i64((int64_t)writes); out_u8('i'); out_i64((int64_t)syncs); out_send(); break;
        case 'C': if (db) sqlite3_close(db); return 0;
        default: _exit(2);
        }
    }
    if (db) sqlite3_close(db);
    return 0;
}
