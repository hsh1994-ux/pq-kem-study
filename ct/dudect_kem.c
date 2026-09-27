/*
 * dudect_kem -- E3 timing-leakage test of liboqs decapsulation (RQ3).
 *
 *   dudect_kem ALG SECONDS
 *
 * Fixed-vs-random test on decapsulation with one fixed secret key:
 *   class 0: the same valid ciphertext every time
 *   class 1: uniformly random bytes (decrypts to garbage and exercises the
 *            FO implicit-rejection path)
 * A constant-time decapsulation takes the same time for both classes.
 */
#define DUDECT_IMPLEMENTATION
#include "dudect/dudect.h"

#include <oqs/oqs.h>
#include <string.h>

#include "../common/cpucycles.h"
#include "../common/util.h"
#include "dudect_run.h"

#ifndef BUILD_TIER
#define BUILD_TIER "unknown"
#endif

static OQS_KEM *K;
static uint8_t *pk, *sk, *ct0, *ss;

uint8_t do_one_computation(uint8_t *data) {
    OQS_KEM_decaps(K, ss, data, sk);
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
    if (argc != 3) die("usage: dudect_kem ALG SECONDS");
    OQS_init();
    K = OQS_KEM_new(argv[1]);
    if (!K) die("%s not enabled", argv[1]);
    pk = xmalloc(K->length_public_key);
    sk = xmalloc(K->length_secret_key);
    ct0 = xmalloc(K->length_ciphertext);
    ss = xmalloc(K->length_shared_secret);
    if (OQS_KEM_keypair(K, pk, sk) || OQS_KEM_encaps(K, ct0, ss, pk)) die("setup failed");

    /* Aim for ~0.5 s per batch so slow KEMs still report progress. */
    uint64_t t0 = pq_now_ns();
    for (int i = 0; i < 5; i++) do_one_computation(ct0);
    double per_call = (double)(pq_now_ns() - t0) / 5e9;
    size_t per_batch = (size_t)(0.5 / (per_call > 1e-7 ? per_call : 1e-7));
    if (per_batch < 100) per_batch = 100;
    if (per_batch > 20000) per_batch = 20000;

    return dudect_run(BUILD_TIER, argv[1], "decaps", K->length_ciphertext, atof(argv[2]), per_batch);
}
