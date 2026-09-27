/*
 * kemtool -- keygen / encaps / decaps on raw binary files, via liboqs.
 *
 * Built twice (bin/kemtool-ref, bin/kemtool-opt) against the portable and the
 * CPU-optimised liboqs builds, so E4 can check that a key made by one
 * implementation works with the other, and with OpenSSL.
 *
 *   kemtool list
 *   kemtool info   ALG
 *   kemtool keygen ALG PK SK
 *   kemtool encaps ALG PK CT SS
 *   kemtool decaps ALG SK CT SS
 *   kemtool selftest ALG N         N random round trips
 */
#include <oqs/oqs.h>
#include <stdint.h>

#include "../common/util.h"

#ifndef BUILD_TIER
#define BUILD_TIER "unknown"
#endif

static OQS_KEM *open_kem(const char *alg) {
    if (!OQS_KEM_alg_is_enabled(alg)) die("%s is not enabled in this liboqs build", alg);
    OQS_KEM *k = OQS_KEM_new(alg);
    if (!k) die("OQS_KEM_new(%s) failed", alg);
    return k;
}

static int cmd_list(void) {
    for (int i = 0; i < OQS_KEM_alg_count(); i++) {
        const char *a = OQS_KEM_alg_identifier((size_t)i);
        if (OQS_KEM_alg_is_enabled(a)) puts(a);
    }
    return 0;
}

static int cmd_info(const char *alg) {
    OQS_KEM *k = open_kem(alg);
    printf("alg=%s\ntier=%s\nnist_level=%u\nind_cca=%d\n"
           "pk_bytes=%zu\nsk_bytes=%zu\nct_bytes=%zu\nss_bytes=%zu\n",
           k->method_name, BUILD_TIER, k->claimed_nist_level, k->ind_cca,
           k->length_public_key, k->length_secret_key, k->length_ciphertext,
           k->length_shared_secret);
    OQS_KEM_free(k);
    return 0;
}

static int cmd_keygen(const char *alg, const char *pkf, const char *skf) {
    OQS_KEM *k = open_kem(alg);
    uint8_t *pk = xmalloc(k->length_public_key), *sk = xmalloc(k->length_secret_key);
    if (OQS_KEM_keypair(k, pk, sk) != OQS_SUCCESS) die("keypair failed");
    write_file(pkf, pk, k->length_public_key);
    write_file(skf, sk, k->length_secret_key);
    OQS_MEM_secure_free(sk, k->length_secret_key);
    free(pk);
    OQS_KEM_free(k);
    return 0;
}

static int cmd_encaps(const char *alg, const char *pkf, const char *ctf, const char *ssf) {
    OQS_KEM *k = open_kem(alg);
    uint8_t *pk = xmalloc(k->length_public_key), *ct = xmalloc(k->length_ciphertext),
            *ss = xmalloc(k->length_shared_secret);
    read_file(pkf, pk, k->length_public_key);
    if (OQS_KEM_encaps(k, ct, ss, pk) != OQS_SUCCESS) die("encaps failed");
    write_file(ctf, ct, k->length_ciphertext);
    write_file(ssf, ss, k->length_shared_secret);
    free(pk); free(ct); free(ss);
    OQS_KEM_free(k);
    return 0;
}

static int cmd_decaps(const char *alg, const char *skf, const char *ctf, const char *ssf) {
    OQS_KEM *k = open_kem(alg);
    uint8_t *sk = xmalloc(k->length_secret_key), *ct = xmalloc(k->length_ciphertext),
            *ss = xmalloc(k->length_shared_secret);
    read_file(skf, sk, k->length_secret_key);
    read_file(ctf, ct, k->length_ciphertext);
    if (OQS_KEM_decaps(k, ss, ct, sk) != OQS_SUCCESS) die("decaps failed");
    write_file(ssf, ss, k->length_shared_secret);
    OQS_MEM_secure_free(sk, k->length_secret_key);
    free(ct); free(ss);
    OQS_KEM_free(k);
    return 0;
}

static int cmd_selftest(const char *alg, int n) {
    OQS_KEM *k = open_kem(alg);
    uint8_t *pk = xmalloc(k->length_public_key), *sk = xmalloc(k->length_secret_key),
            *ct = xmalloc(k->length_ciphertext), *s1 = xmalloc(k->length_shared_secret),
            *s2 = xmalloc(k->length_shared_secret);
    int bad = 0;
    for (int i = 0; i < n; i++) {
        if (OQS_KEM_keypair(k, pk, sk) || OQS_KEM_encaps(k, ct, s1, pk) ||
            OQS_KEM_decaps(k, s2, ct, sk) || memcmp(s1, s2, k->length_shared_secret))
            bad++;
    }
    printf("%s %s %d/%d ok\n", alg, BUILD_TIER, n - bad, n);
    free(pk); free(sk); free(ct); free(s1); free(s2);
    OQS_KEM_free(k);
    return bad != 0;
}

int main(int argc, char **argv) {
    OQS_init();
    if (argc >= 2 && !strcmp(argv[1], "list")) return cmd_list();
    if (argc == 3 && !strcmp(argv[1], "info")) return cmd_info(argv[2]);
    if (argc == 5 && !strcmp(argv[1], "keygen")) return cmd_keygen(argv[2], argv[3], argv[4]);
    if (argc == 6 && !strcmp(argv[1], "encaps")) return cmd_encaps(argv[2], argv[3], argv[4], argv[5]);
    if (argc == 6 && !strcmp(argv[1], "decaps")) return cmd_decaps(argv[2], argv[3], argv[4], argv[5]);
    if (argc == 4 && !strcmp(argv[1], "selftest")) return cmd_selftest(argv[2], atoi(argv[3]));
    fprintf(stderr,
            "usage: kemtool list | info ALG | keygen ALG PK SK | encaps ALG PK CT SS\n"
            "               | decaps ALG SK CT SS | selftest ALG N\n");
    return 2;
}
