/*
 * bench_ossl -- E1 benchmark of OpenSSL 3.5's own KEMs (RQ1 baseline).
 *
 *   bench_ossl ALG N_KEYGEN N_OPS      ALG: X25519 | ML-KEM-512/768/1024 |
 *                                           X25519MLKEM768 | ...
 *
 * Uses the generic EVP KEM API, so X25519 runs as DHKEM (RFC 9180): encaps =
 * ephemeral keygen + ECDH, the fair comparison to a KEM. Output format is
 * identical to bench_kem, with tier "openssl".
 */
#include <openssl/core_names.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <stdint.h>

#include "../common/cpucycles.h"
#include "../common/util.h"

static void ossl_die(const char *what) {
    ERR_print_errors_fp(stderr);
    die("%s failed", what);
}

static EVP_PKEY *keygen(const char *alg) {
    EVP_PKEY_CTX *c = EVP_PKEY_CTX_new_from_name(NULL, alg, NULL);
    EVP_PKEY *k = NULL;
    if (!c || EVP_PKEY_keygen_init(c) <= 0 || EVP_PKEY_keygen(c, &k) <= 0) ossl_die("keygen");
    EVP_PKEY_CTX_free(c);
    return k;
}

static EVP_PKEY_CTX *kem_ctx(EVP_PKEY *k, const char *alg, int encap) {
    EVP_PKEY_CTX *c = EVP_PKEY_CTX_new_from_pkey(NULL, k, NULL);
    OSSL_PARAM p[2] = {OSSL_PARAM_END, OSSL_PARAM_END};
    if (!strcmp(alg, "X25519") || !strcmp(alg, "X448"))
        p[0] = OSSL_PARAM_construct_utf8_string(OSSL_KEM_PARAM_OPERATION, (char *)"DHKEM", 0);
    int r = encap ? EVP_PKEY_encapsulate_init(c, p) : EVP_PKEY_decapsulate_init(c, p);
    if (!c || r <= 0) ossl_die(encap ? "encapsulate_init" : "decapsulate_init");
    return c;
}

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}

static uint64_t pct(const uint64_t *s, int n, double p) { return s[(int)(p * (n - 1) + 0.5)]; }

static void report(const char *alg, const char *op, uint64_t *t, int n, double npt,
                   size_t pk, size_t ct, size_t ss) {
    qsort(t, (size_t)n, sizeof(uint64_t), cmp_u64);
    double mean = 0;
    for (int i = 0; i < n; i++) mean += (double)t[i];
    mean /= n;
    /* stack_bytes / sk_bytes not measured for OpenSSL (-1) */
    printf("openssl,%s,%s,%d,%s,%.6f,%llu,%llu,%llu,%llu,%.1f,%.1f,%.1f,%.1f,-1,%zu,-1,%zu,%zu\n",
           alg, op, n, cpucycles_unit(), npt, (unsigned long long)t[0],
           (unsigned long long)pct(t, n, .25), (unsigned long long)pct(t, n, .5),
           (unsigned long long)pct(t, n, .75), mean, pct(t, n, .5) * npt,
           pct(t, n, .25) * npt, pct(t, n, .75) * npt, pk, ct, ss);
    fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc != 4) die("usage: bench_ossl ALG N_KEYGEN N_OPS");
    const char *alg = argv[1];
    int nk = atoi(argv[2]), no = atoi(argv[3]);
    double npt = cpucycles_ns_per_tick();
    int nmax = nk > no ? nk : no;
    uint64_t *t = xmalloc(sizeof(uint64_t) * (size_t)nmax);

    /* keygen */
    for (int i = 0; i < nk; i++) {
        uint64_t t0 = cpucycles();
        EVP_PKEY *k = keygen(alg);
        t[i] = cpucycles() - t0;
        EVP_PKEY_free(k);
    }
    EVP_PKEY *key = keygen(alg);
    size_t pk_len = 0, ct_len = 0, ss_len = 0;
    if (!EVP_PKEY_get_octet_string_param(key, OSSL_PKEY_PARAM_ENCODED_PUBLIC_KEY, NULL, 0, &pk_len))
        pk_len = 0;
    EVP_PKEY_CTX *ec = kem_ctx(key, alg, 1);
    if (EVP_PKEY_encapsulate(ec, NULL, &ct_len, NULL, &ss_len) <= 0) ossl_die("encapsulate(size)");
    report(alg, "keygen", t, nk, npt, pk_len, ct_len, ss_len);

    /* encaps: one context, reused, like a TLS client would */
    uint8_t *ct = xmalloc(ct_len), *ss = xmalloc(ss_len), *ss2 = xmalloc(ss_len);
    for (int i = 0; i < no; i++) {
        size_t cl = ct_len, sl = ss_len;
        uint64_t t0 = cpucycles();
        if (EVP_PKEY_encapsulate(ec, ct, &cl, ss, &sl) <= 0) ossl_die("encapsulate");
        t[i] = cpucycles() - t0;
    }
    report(alg, "encaps", t, no, npt, pk_len, ct_len, ss_len);

    /* decaps */
    EVP_PKEY_CTX *dc = kem_ctx(key, alg, 0);
    for (int i = 0; i < no; i++) {
        size_t sl = ss_len;
        uint64_t t0 = cpucycles();
        if (EVP_PKEY_decapsulate(dc, ss2, &sl, ct, ct_len) <= 0) ossl_die("decapsulate");
        t[i] = cpucycles() - t0;
    }
    if (memcmp(ss, ss2, ss_len)) die("%s: shared secrets differ", alg);
    report(alg, "decaps", t, no, npt, pk_len, ct_len, ss_len);

    EVP_PKEY_CTX_free(ec);
    EVP_PKEY_CTX_free(dc);
    EVP_PKEY_free(key);
    return 0;
}
