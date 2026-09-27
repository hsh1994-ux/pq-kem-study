/*
 * dudect_planted -- E3 controls that prove the timing test works (RQ3).
 *
 *   dudect_planted leaky SECONDS     early-exit comparison: MUST report "leak"
 *   dudect_planted ct    SECONDS     constant-time comparison: expect no evidence
 *
 * Both compare a 4 KiB input with a fixed secret. Class 0 = the secret
 * itself (full-length comparison), class 1 = random (the leaky version
 * returns at the first byte). If the leaky control is not detected on a
 * machine, a "no_evidence" result for a KEM on that machine means nothing.
 */
#define DUDECT_IMPLEMENTATION
#include "dudect/dudect.h"

#include <string.h>

#include "../common/cpucycles.h"
#include "../common/util.h"
#include "dudect_run.h"

#define N 4096 /* large enough that the planted leak dwarfs timer overhead */
static uint8_t secret[N];
static int leaky;

__attribute__((noinline)) static int cmp_leaky(const uint8_t *a, const uint8_t *b) {
    for (size_t i = 0; i < N; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

__attribute__((noinline)) static int cmp_ct(const uint8_t *a, const uint8_t *b) {
    volatile uint8_t d = 0;
    for (size_t i = 0; i < N; i++) d |= a[i] ^ b[i];
    return d == 0;
}

uint8_t do_one_computation(uint8_t *data) {
    uint8_t r = (uint8_t)(leaky ? cmp_leaky(data, secret) : cmp_ct(data, secret));
    dudect_sink ^= r; /* keeps the compiler from deleting the call */
    return r;
}

void prepare_inputs(dudect_config_t *c, uint8_t *input_data, uint8_t *classes) {
    randombytes(input_data, c->chunk_size * c->number_measurements);
    for (size_t i = 0; i < c->number_measurements; i++) {
        classes[i] = randombit();
        if (classes[i] == 0) memcpy(input_data + i * c->chunk_size, secret, N);
    }
}

int main(int argc, char **argv) {
    if (argc != 3 || (strcmp(argv[1], "leaky") && strcmp(argv[1], "ct")))
        die("usage: dudect_planted leaky|ct SECONDS");
    leaky = !strcmp(argv[1], "leaky");
    randombytes(secret, N);
    return dudect_run("control", leaky ? "planted-leaky-memcmp" : "planted-ct-memcmp",
                      "compare", N, atof(argv[2]), 5000);
}
