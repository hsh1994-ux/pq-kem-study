/*
 * cpucycles.h -- one timer for x86-64 and ARM64 (and a portable fallback).
 *
 *   x86-64 : fenced RDTSC. Counts at a constant "reference" rate, so with
 *            Turbo Boost on it is not the same as core cycles; the benchmark
 *            scripts record whether turbo was disabled.
 *   ARM64  : CNTVCT_EL0, the architectural virtual counter. Fixed frequency
 *            (CNTFRQ_EL0: 24 MHz on Apple M-series, i.e. ~41.7 ns per tick),
 *            readable from user space and inside VMs, unlike PMCCNTR_EL0.
 *   other  : clock_gettime(CLOCK_MONOTONIC), in nanoseconds.
 *
 * cpucycles_ns_per_tick() converts ticks to nanoseconds so results from
 * different machines can be put on one axis.
 */
#ifndef PQ_CPUCYCLES_H
#define PQ_CPUCYCLES_H

#include <stdint.h>
#include <time.h>

static inline uint64_t cpucycles(void) {
#if defined(__x86_64__) || defined(__i386__)
    uint32_t lo, hi;
    __asm__ volatile("lfence\n\trdtsc\n\tlfence" : "=a"(lo), "=d"(hi)::"memory");
    return ((uint64_t)hi << 32) | lo;
#elif defined(__aarch64__)
    uint64_t v;
    __asm__ volatile("isb\n\tmrs %0, cntvct_el0" : "=r"(v)::"memory");
    return v;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

static inline const char *cpucycles_unit(void) {
#if defined(__x86_64__) || defined(__i386__)
    return "tsc_cycles";
#elif defined(__aarch64__)
    return "cntvct_ticks";
#else
    return "ns";
#endif
}

static inline uint64_t pq_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* Nanoseconds per tick of cpucycles(). */
static inline double cpucycles_ns_per_tick(void) {
#if defined(__aarch64__)
    uint64_t f;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
    return f ? 1e9 / (double)f : 1.0;
#elif defined(__x86_64__) || defined(__i386__)
    /* Calibrate the TSC against the monotonic clock over ~50 ms. */
    uint64_t t0 = pq_now_ns(), c0 = cpucycles();
    while (pq_now_ns() - t0 < 50000000ull) { }
    uint64_t t1 = pq_now_ns(), c1 = cpucycles();
    return (double)(t1 - t0) / (double)(c1 - c0);
#else
    return 1.0;
#endif
}

#endif
