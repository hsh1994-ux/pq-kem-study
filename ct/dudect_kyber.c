/*
 * dudect_kyber -- E3 KyberSlash control (RQ3).
 *
 * Linked against the pq-crystals Kyber768 reference code either *before*
 * (old) or *after* (fixed) the KyberSlash patches, compiled at a chosen
 * optimisation level (see ct/build_kyber.sh). Same fixed-vs-random
 * decapsulation test as dudect_kem.
 *
 * KyberSlash is a secret-dependent *division* (…/KYBER_Q). Whether it leaks
 * depends on (a) the compiler emitting a real DIV instruction instead of a
 * multiply-and-shift, and (b) the CPU's divider having data-dependent
 * latency. ct/build_kyber.sh records (a); this test measures (a)+(b).
 */
#define DUDECT_IMPLEMENTATION
#include "dudect/dudect.h"

#include <string.h>

#include "../common/cpucycles.h"
#include "../common/util.h"
#include "dudect_run.h"
#include "kem.h"

#ifndef KYBER_VARIANT
#define KYBER_VARIANT "unknown"
#endif

static uint8_t pk[CRYPTO_PUBLICKEYBYTES], sk[CRYPTO_SECRETKEYBYTES];
static uint8_t ct0[CRYPTO_CIPHERTEXTBYTES], ss[CRYPTO_BYTES];

uint8_t do_one_computation(uint8_t *data) {
    crypto_kem_dec(ss, data, sk);
    dudect_sink ^= ss[0];
    return ss[0];
}

void prepare_inputs(dudect_config_t *c, uint8_t *input_data, uint8_t *classes) {
    randombytes(input_data, c->chunk_size * c->number_measurements);
    for (size_t i = 0; i < c->number_measurements; i++) {
        classes[i] = randombit();
        if (classes[i] == 0) memcpy(input_data + i * c->chunk_size, ct0, c->chunk_size);
    }
}

int main(int argc, char **argv) {
    if (argc != 2) die("usage: dudect_kyber SECONDS");
    crypto_kem_keypair(pk, sk);
    crypto_kem_enc(ct0, ss, pk);
    return dudect_run("kyber-ref", "Kyber768-" KYBER_VARIANT, "decaps", CRYPTO_CIPHERTEXTBYTES,
                      atof(argv[1]), 10000);
}
