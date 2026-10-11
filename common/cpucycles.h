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
 * different machines can be put on one axis. pq_core_ghz() estimates the
 * core clock, so nanoseconds can be turned into (approximate) core cycles
 * for comparison with published cycle counts. pq_spin_ms() is the warm-up.
 */
#ifndef PQ_CPUCYCLES_H
#define PQ_CPUCYCLES_H

#include <stdint.h>
#include <stdlib.h>
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

/* Busy-wait for `ms` milliseconds. Used as a warm-up: a core that has been
 * idle (e.g. during COOLDOWN) needs tens of ms of load before DVFS raises its
 * clock, Apple M-series P-cores in particular. */
static inline void pq_spin_ms(unsigned ms) {
    uint64_t t0 = pq_now_ns();
    while (pq_now_ns() - t0 < (uint64_t)ms * 1000000ull) { }
}

static int pq_cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

#if defined(__x86_64__) || defined(__i386__)
/* One calibration window: TSC ticks against the monotonic clock. */
static inline double pq_tsc_window(unsigned ms) {
    uint64_t t0 = pq_now_ns(), c0 = cpucycles();
    while (pq_now_ns() - t0 < (uint64_t)ms * 1000000ull) { }
    uint64_t t1 = pq_now_ns(), c1 = cpucycles();
    return (double)(t1 - t0) / (double)(c1 - c0);
}
#endif

/* Nanoseconds per tick of cpucycles().
 *
 * ARM64: exact, from CNTFRQ_EL0. x86-64: measured, median of 5 x 200 ms
 * windows (a single short window was off by up to +-4% under WSL2). The
 * benchmark driver calibrates once per run and passes the value to every
 * process in PQ_NS_PER_TICK, so all rows of a run share one conversion. */
static inline double cpucycles_ns_per_tick(void) {
    const char *env = getenv("PQ_NS_PER_TICK");
    if (env && atof(env) > 0) return atof(env);
#if defined(__aarch64__)
    uint64_t f;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
    return f ? 1e9 / (double)f : 1.0;
#elif defined(__x86_64__) || defined(__i386__)
    double w[5];
    for (int i = 0; i < 5; i++) w[i] = pq_tsc_window(200);
    qsort(w, 5, sizeof w[0], pq_cmp_double);
    return w[2];
#else
    return 1.0;
#endif
}

/* Estimated current core clock in GHz.
 *
 * Neither WSL2 nor Docker Desktop lets user space read the real core-cycle
 * counter, so we time a chain of dependent register-register additions:
 * each needs the previous result and integer add has 1-cycle latency on all
 * CPUs we use, so additions per nanosecond = core GHz. (A register operand is
 * used rather than an immediate because some newer Intel cores can fold
 * small-immediate adds at rename.) Loop overhead runs in parallel on these
 * out-of-order cores. Median of 5 x ~2 ms windows. It is an estimate of the
 * clock at that moment: heavy AVX2 code may run slightly slower. */
static inline double pq_core_ghz(void) {
#if defined(__x86_64__) || defined(__aarch64__)
    volatile uint64_t one_v = 1;
    uint64_t one = one_v, x = 0;
    const uint64_t iters = 250000; /* x 16 adds = 4M cycles, ~1 ms at 4 GHz */
    double w[5];
    for (int k = 0; k < 5; k++) {
        uint64_t t0 = pq_now_ns();
        for (uint64_t i = 0; i < iters; i++) {
#if defined(__x86_64__)
#define PQ_ADD4 "add %1, %0\n\tadd %1, %0\n\tadd %1, %0\n\tadd %1, %0\n\t"
#else
#define PQ_ADD4 "add %0, %0, %1\n\tadd %0, %0, %1\n\tadd %0, %0, %1\n\tadd %0, %0, %1\n\t"
#endif
            __asm__ volatile(PQ_ADD4 PQ_ADD4 PQ_ADD4 PQ_ADD4 : "+r"(x) : "r"(one));
#undef PQ_ADD4
        }
        uint64_t t1 = pq_now_ns();
        w[k] = (double)(iters * 16) / (double)(t1 - t0);
    }
    one_v = x; /* keep x alive */
    qsort(w, 5, sizeof w[0], pq_cmp_double);
    return w[2];
#else
    return 0.0;
#endif
}

#endif
