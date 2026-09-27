/* Small helpers shared by the C tools: file I/O, hex, fatal errors. */
#ifndef PQ_UTIL_H
#define PQ_UTIL_H

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static inline void die(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

static inline void write_file(const char *path, const uint8_t *buf, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) die("cannot write %s", path);
    if (fwrite(buf, 1, len, f) != len) die("short write to %s", path);
    fclose(f);
}

/* Reads exactly `len` bytes, or dies. */
static inline void read_file(const char *path, uint8_t *buf, size_t len) {
    FILE *f = fopen(path, "rb");
    if (!f) die("cannot read %s", path);
    size_t n = fread(buf, 1, len, f);
    if (n != len) die("%s: expected %zu bytes, got %zu", path, len, n);
    fclose(f);
}

static inline void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) die("out of memory");
    return p;
}

#endif
