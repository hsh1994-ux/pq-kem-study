/*
 * bench_kem -- E1 microbenchmark for one liboqs KEM (RQ1).
 *
 *   bench_kem ALG N_KEYGEN N_OPS
 *
 * Times every keygen / encaps / decaps call individually with cpucycles()
 * and prints one CSV row per operation (no header) to stdout:
 *
 *   tier,alg,op,n,unit,ns_per_tick,min,p25,median,p75,mean,
 *   median_ns,p25_ns,p75_ns,stack_bytes,pk_bytes,sk_bytes,ct_bytes,ss_bytes
 *
 * Stack use is measured by running each operation once on a thread whose
 * stack we allocate and pre-fill with a pattern, then finding the deepest
 * byte that was overwritten (minus the same measurement for an empty call).
 */
#include <oqs/oqs.h>
#include <pthread.h>
#include <stdint.h>

#include "../common/cpucycles.h"
#include "../common/util.h"

#ifndef BUILD_TIER
#define BUILD_TIER "unknown"
#endif

#define STACK_SIZE (16u << 20) /* 16 MiB: Classic McEliece keygen is stack-hungry */
#define PATTERN 0xA5

enum op { OP_NONE, OP_KEYGEN, OP_ENCAPS, OP_DECAPS };
static const char *op_name[] = {"none", "keygen", "encaps", "decaps"};

struct ctx {
    OQS_KEM *k;
    uint8_t *pk, *sk, *ct, *ss;
    enum op op;
};

static void run_op(struct ctx *c) {
    int r = OQS_SUCCESS;
    switch (c->op) {
    case OP_KEYGEN: r = OQS_KEM_keypair(c->k, c->pk, c->sk); break;
    case OP_ENCAPS: r = OQS_KEM_encaps(c->k, c->ct, c->ss, c->pk); break;
    case OP_DECAPS: r = OQS_KEM_decaps(c->k, c->ss, c->ct, c->sk); break;
    default: break;
    }
    if (r != OQS_SUCCESS) die("%s %s failed", c->k->method_name, op_name[c->op]);
}

static void *thread_main(void *arg) {
    run_op((struct ctx *)arg);
    return NULL;
}

static size_t stack_used(struct ctx *c) {
    uint8_t *stack = xmalloc(STACK_SIZE);
    memset(stack, PATTERN, STACK_SIZE);
    pthread_attr_t attr;
    pthread_t th;
    pthread_attr_init(&attr);
    if (pthread_attr_setstack(&attr, stack, STACK_SIZE)) die("pthread_attr_setstack");
    if (pthread_create(&th, &attr, thread_main, c)) die("pthread_create");
    pthread_join(th, NULL);
    pthread_attr_destroy(&attr);
    size_t untouched = 0; /* stacks grow down: scan up from the low end */
    while (untouched < STACK_SIZE && stack[untouched] == PATTERN) untouched++;
    free(stack);
    return STACK_SIZE - untouched;
}

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}

static uint64_t pct(const uint64_t *s, int n, double p) {
    int i = (int)(p * (n - 1) + 0.5);
    return s[i];
}

static void bench(struct ctx *c, enum op op, int n, double ns_per_tick, size_t base_stack) {
    uint64_t *t = xmalloc(sizeof(uint64_t) * (size_t)n);
    c->op = op;
    for (int i = 0; i < (n < 10 ? 1 : n / 10); i++) run_op(c); /* warm-up */
    for (int i = 0; i < n; i++) {
        uint64_t t0 = cpucycles();
        run_op(c);
        t[i] = cpucycles() - t0;
    }
    qsort(t, (size_t)n, sizeof(uint64_t), cmp_u64);
    double mean = 0;
    for (int i = 0; i < n; i++) mean += (double)t[i];
    mean /= n;
    size_t st = stack_used(c);
    st = st > base_stack ? st - base_stack : 0;
    OQS_KEM *k = c->k;
    printf("%s,%s,%s,%d,%s,%.6f,%llu,%llu,%llu,%llu,%.1f,%.1f,%.1f,%.1f,%zu,%zu,%zu,%zu,%zu\n",
           BUILD_TIER, k->method_name, op_name[op], n, cpucycles_unit(), ns_per_tick,
           (unsigned long long)t[0], (unsigned long long)pct(t, n, .25),
           (unsigned long long)pct(t, n, .5), (unsigned long long)pct(t, n, .75), mean,
           pct(t, n, .5) * ns_per_tick, pct(t, n, .25) * ns_per_tick, pct(t, n, .75) * ns_per_tick,
           st, k->length_public_key, k->length_secret_key, k->length_ciphertext,
           k->length_shared_secret);
    fflush(stdout);
    free(t);
}

int main(int argc, char **argv) {
    if (argc != 4) die("usage: bench_kem ALG N_KEYGEN N_OPS");
    OQS_init();
    const char *alg = argv[1];
    int nk = atoi(argv[2]), no = atoi(argv[3]);
    if (!OQS_KEM_alg_is_enabled(alg)) die("%s not enabled", alg);
    struct ctx c = {0};
    c.k = OQS_KEM_new(alg);
    c.pk = xmalloc(c.k->length_public_key);
    c.sk = xmalloc(c.k->length_secret_key);
    c.ct = xmalloc(c.k->length_ciphertext);
    c.ss = xmalloc(c.k->length_shared_secret);

    double ns_per_tick = cpucycles_ns_per_tick();
    c.op = OP_NONE;
    size_t base = stack_used(&c);

    bench(&c, OP_KEYGEN, nk, ns_per_tick, base); /* leaves a valid key pair */
    c.op = OP_ENCAPS;
    run_op(&c); /* valid ciphertext for decaps */
    bench(&c, OP_ENCAPS, no, ns_per_tick, base);
    bench(&c, OP_DECAPS, no, ns_per_tick, base);

    OQS_KEM_free(c.k);
    return 0;
}
