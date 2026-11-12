/*
 * dudect_botan -- E3 timing-leakage test of Botan's decapsulation (RQ3).
 *
 *   dudect_botan ALG SECONDS [fr|ff]
 *
 * The Botan counterpart of dudect_kem (liboqs), with the same two classes:
 * class 0 is always the same valid ciphertext; class 1 is a uniformly random
 * byte string (fr, default: exercises the implicit-rejection path) or a second
 * valid ciphertext (ff, fixed-vs-fixed follow-up). One fixed private key and
 * one PK_KEM_Decryptor are made before measuring, so only the decapsulation
 * itself is timed. Prints the same RESULT line as dudect_kem, tier "botan".
 * Exits 3 for KEMs Botan does not implement (HQC).
 */
#define DUDECT_IMPLEMENTATION
#include "dudect/dudect.h"

#include <cstring>
#include <memory>
#include <vector>

#include "../common/botan_kem.h"
#include "../common/cpucycles.h"
#include "dudect_run.h"

static std::unique_ptr<Botan::PK_KEM_Decryptor> DEC;
static std::vector<uint8_t> ct0, ct1, ss;
static int fixed_fixed;

uint8_t do_one_computation(uint8_t *data) {
    DEC->decrypt(std::span<uint8_t>(ss), std::span<const uint8_t>(data, ct0.size()), ss.size());
    dudect_sink ^= ss[0];
    return ss[0];
}

void prepare_inputs(dudect_config_t *c, uint8_t *input_data, uint8_t *classes) {
    randombytes(input_data, c->chunk_size * c->number_measurements);
    for (size_t i = 0; i < c->number_measurements; i++) {
        classes[i] = randombit();
        if (classes[i] == 0) std::memcpy(input_data + i * c->chunk_size, ct0.data(), c->chunk_size);
        else if (fixed_fixed) std::memcpy(input_data + i * c->chunk_size, ct1.data(), c->chunk_size);
    }
}

int main(int argc, char **argv) {
    if (argc != 3 && argc != 4) {
        std::fprintf(stderr, "usage: dudect_botan ALG SECONDS [fr|ff]\n");
        return 2;
    }
    fixed_fixed = argc == 4 && !std::strcmp(argv[3], "ff");
    BotanKem kem = botan_kem_or_exit(argv[1]);
    Botan::System_RNG rng;
    auto sk = kem.keygen(rng);
    Botan::PK_KEM_Encryptor enc(*sk, "Raw");
    ct0.resize(enc.encapsulated_key_length());
    ct1.resize(ct0.size());
    ss.resize(enc.shared_key_length(0));
    enc.encrypt(std::span<uint8_t>(ct0), std::span<uint8_t>(ss), rng, ss.size());
    enc.encrypt(std::span<uint8_t>(ct1), std::span<uint8_t>(ss), rng, ss.size());
    DEC = std::make_unique<Botan::PK_KEM_Decryptor>(*sk, rng, "Raw");

    /* Aim for ~0.5 s per batch so slow KEMs still report progress. */
    uint64_t t0 = pq_now_ns();
    for (int i = 0; i < 5; i++) do_one_computation(ct0.data());
    double per_call = (double)(pq_now_ns() - t0) / 5e9;
    size_t per_batch = (size_t)(0.5 / (per_call > 1e-7 ? per_call : 1e-7));
    if (per_batch < 100) per_batch = 100;
    if (per_batch > 20000) per_batch = 20000;

    return dudect_run("botan", argv[1], fixed_fixed ? "decaps-ff" : "decaps", ct0.size(), std::atof(argv[2]),
                      per_batch);
}
