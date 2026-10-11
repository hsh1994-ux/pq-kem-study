/*
 * bench_ossl -- E1 benchmark of OpenSSL 3.5's own KEMs (RQ1 baseline).
 *
 *   bench_ossl ALG N_KEYGEN N_OPS      ALG: X25519 | ML-KEM-512/768/1024 |
 *                                           X25519MLKEM768 | ...
 *
 * Uses the generic EVP KEM API. X25519-DHKEM is X25519 wrapped as a KEM (DHKEM,
 * RFC 9180): encaps = ephemeral keygen + ECDH + HKDF. Output format is identical to bench_kem,
 * with tier "openssl".
 *
 * X25519-ECDH is plain ephemeral X25519 key agreement as TLS 1.3 uses it (no
 * KEM wrapper, no HKDF), reported in KEM roles so it lines up with the KEMs:
 *   keygen = client generates its key pair
 *   encaps = server generates its key pair and derives the shared secret
 *            from the client's public key (bytes -> key, then ECDH)
 *   decaps = client derives the shared secret from the server's public key
 * keygen + encaps + decaps = one full ECDHE exchange.
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
                   size_t pk, size_t ct, size_t ss, double ghz0, double ghz1) {
    qsort(t, (size_t)n, sizeof(uint64_t), cmp_u64);
    double mean = 0;
    for (int i = 0; i < n; i++) mean += (double)t[i];
    mean /= n;
    /* stack_bytes / sk_bytes not measured for OpenSSL (-1) */
    double med_ns = pct(t, n, .5) * npt;
    printf("openssl,%s,%s,%d,%s,%.6f,%llu,%llu,%llu,%llu,%.1f,%.1f,%.1f,%.1f,-1,%zu,-1,%zu,%zu,"
           "%.3f,%.3f,%.0f\n",
           alg, op, n, cpucycles_unit(), npt, (unsigned long long)t[0],
           (unsigned long long)pct(t, n, .25), (unsigned long long)pct(t, n, .5),
           (unsigned long long)pct(t, n, .75), mean, med_ns,
           pct(t, n, .25) * npt, pct(t, n, .75) * npt, pk, ct, ss, ghz0, ghz1,
           med_ns * (ghz0 + ghz1) / 2);
    fflush(stdout);
}

/* ECDH with a peer public key received as bytes, as in a TLS key share. */
static void derive(EVP_PKEY *mine, const uint8_t *peer_pub, size_t peer_len, uint8_t *out, size_t *out_len) {
    EVP_PKEY *peer = EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, NULL, peer_pub, peer_len);
    EVP_PKEY_CTX *c = EVP_PKEY_CTX_new_from_pkey(NULL, mine, NULL);
    if (!peer || !c || EVP_PKEY_derive_init(c) <= 0 || EVP_PKEY_derive_set_peer(c, peer) <= 0 ||
        EVP_PKEY_derive(c, out, out_len) <= 0)
        ossl_die("derive");
    EVP_PKEY_CTX_free(c);
    EVP_PKEY_free(peer);
}

static void raw_pub(EVP_PKEY *k, uint8_t *pub, size_t *len) {
    if (EVP_PKEY_get_raw_public_key(k, pub, len) <= 0) ossl_die("get_raw_public_key");
}

static int bench_ecdh(const char *label, int nk, int no, double npt, uint64_t *t) {
    double g0, g1;
    uint8_t cpub[32], spub[32], ss1[32], ss2[32];
    size_t cl = 32, sl = 32, l1 = 32, l2 = 32;

    g0 = pq_core_ghz();
    for (int i = 0; i < nk; i++) {
        uint64_t t0 = cpucycles();
        EVP_PKEY *k = keygen("X25519");
        size_t len = 32;
        raw_pub(k, cpub, &len); /* the client's key share */
        t[i] = cpucycles() - t0;
        EVP_PKEY_free(k);
    }
    g1 = pq_core_ghz();
    report(label, "keygen", t, nk, npt, 32, 32, 32, g0, g1);

    EVP_PKEY *client = keygen("X25519");
    raw_pub(client, cpub, &cl);

    EVP_PKEY *server = NULL;
    g0 = pq_core_ghz();
    for (int i = 0; i < no; i++) {
        uint64_t t0 = cpucycles();
        EVP_PKEY *s = keygen("X25519");
        sl = 32;
        raw_pub(s, spub, &sl);
        l1 = 32;
        derive(s, cpub, cl, ss1, &l1);
        t[i] = cpucycles() - t0;
        EVP_PKEY_free(server);
        server = s;
    }
    g1 = pq_core_ghz();
    report(label, "encaps", t, no, npt, 32, 32, 32, g0, g1);

    g0 = pq_core_ghz();
    for (int i = 0; i < no; i++) {
        uint64_t t0 = cpucycles();
        l2 = 32;
        derive(client, spub, sl, ss2, &l2);
        t[i] = cpucycles() - t0;
    }
    g1 = pq_core_ghz();
    if (l1 != l2 || memcmp(ss1, ss2, l1)) die("%s: shared secrets differ", label);
    report(label, "decaps", t, no, npt, 32, 32, 32, g0, g1);

    EVP_PKEY_free(server);
    EVP_PKEY_free(client);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 4) die("usage: bench_ossl ALG N_KEYGEN N_OPS");
    const char *alg = argv[1];
    int nk = atoi(argv[2]), no = atoi(argv[3]);
    double npt = cpucycles_ns_per_tick();
    const char *wm = getenv("WARMUP_MS");
    pq_spin_ms(wm ? (unsigned)atoi(wm) : 200);
    double g0, g1;
    int nmax = nk > no ? nk : no;
    uint64_t *t = xmalloc(sizeof(uint64_t) * (size_t)nmax);
    if (!strcmp(alg, "X25519-ECDH")) return bench_ecdh(alg, nk, no, npt, t);
    /* "X25519-DHKEM" is reported under that name but is OpenSSL's X25519 key type. */
    const char *evp = !strcmp(alg, "X25519-DHKEM") ? "X25519" : alg;

    /* keygen */
    g0 = pq_core_ghz();
    for (int i = 0; i < nk; i++) {
        uint64_t t0 = cpucycles();
        EVP_PKEY *k = keygen(evp);
        t[i] = cpucycles() - t0;
        EVP_PKEY_free(k);
    }
    g1 = pq_core_ghz();
    EVP_PKEY *key = keygen(evp);
    size_t pk_len = 0, ct_len = 0, ss_len = 0;
    if (!EVP_PKEY_get_octet_string_param(key, OSSL_PKEY_PARAM_ENCODED_PUBLIC_KEY, NULL, 0, &pk_len))
        pk_len = 0;
    EVP_PKEY_CTX *ec = kem_ctx(key, evp, 1);
    if (EVP_PKEY_encapsulate(ec, NULL, &ct_len, NULL, &ss_len) <= 0) ossl_die("encapsulate(size)");
    report(alg, "keygen", t, nk, npt, pk_len, ct_len, ss_len, g0, g1);

    /* encaps: one context, reused, like a TLS client would */
    uint8_t *ct = xmalloc(ct_len), *ss = xmalloc(ss_len), *ss2 = xmalloc(ss_len);
    g0 = pq_core_ghz();
    for (int i = 0; i < no; i++) {
        size_t cl = ct_len, sl = ss_len;
        uint64_t t0 = cpucycles();
        if (EVP_PKEY_encapsulate(ec, ct, &cl, ss, &sl) <= 0) ossl_die("encapsulate");
        t[i] = cpucycles() - t0;
    }
    g1 = pq_core_ghz();
    report(alg, "encaps", t, no, npt, pk_len, ct_len, ss_len, g0, g1);

    /* decaps */
    EVP_PKEY_CTX *dc = kem_ctx(key, evp, 0);
    g0 = pq_core_ghz();
    for (int i = 0; i < no; i++) {
        size_t sl = ss_len;
        uint64_t t0 = cpucycles();
        if (EVP_PKEY_decapsulate(dc, ss2, &sl, ct, ct_len) <= 0) ossl_die("decapsulate");
        t[i] = cpucycles() - t0;
    }
    g1 = pq_core_ghz();
    if (memcmp(ss, ss2, ss_len)) die("%s: shared secrets differ", alg);
    report(alg, "decaps", t, no, npt, pk_len, ct_len, ss_len, g0, g1);

    EVP_PKEY_CTX_free(ec);
    EVP_PKEY_CTX_free(dc);
    EVP_PKEY_free(key);
    return 0;
}
