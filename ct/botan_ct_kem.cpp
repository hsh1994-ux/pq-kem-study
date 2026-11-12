/*
 * botan_ct_kem -- E3 Valgrind driver for Botan's KEMs (RQ3).
 *
 *   valgrind --tool=memcheck botan_ct_kem ALG
 *
 * Built against build/botan-ct, a Botan configured --with-valgrind: Botan's
 * own CT::poison annotations then mark its secret values (private keys, the
 * decapsulated message, ...) as "undefined" for Memcheck, which reports any
 * conditional branch or memory address that depends on them. This is Botan's
 * own constant-time methodology (its CI runs the same check). It differs from
 * liboqs' test_kem run, where *all* random bytes are marked secret and known,
 * legitimately public uses are suppressed afterwards.
 *
 * Exercises key generation, encapsulation, decapsulation of a valid
 * ciphertext and of a random one (implicit rejection), twice each.
 * Exits 3 for KEMs Botan does not implement (HQC).
 *
 *   valgrind --tool=memcheck botan_ct_kem control
 *
 * Positive control: poisons one random byte with Botan's own CT::poison and
 * branches on it. Memcheck MUST report this; if it does not, the annotations
 * are not active and the KEM results of this build mean nothing.
 */
#include <botan/internal/ct_utils.h> /* internal header: CT::poison (control only) */
#include <botan/internal/target_info.h>

#include <cstdio>
#include <cstring>
#include <vector>

#include "../common/botan_kem.h"

#if !defined(BOTAN_HAS_VALGRIND)
#error "botan_ct_kem must be built against Botan configured --with-valgrind (build/botan-ct)"
#endif

static int control() {
    Botan::System_RNG rng;
    uint8_t secret = rng.next_byte();
    Botan::CT::poison(&secret, 1);
    volatile int sink = 0;
    if (secret & 1) sink = 1; /* deliberate secret-dependent branch */
    Botan::CT::unpoison(&secret, 1);
    std::printf("control done (%d)\n", sink);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: botan_ct_kem ALG\n");
        return 2;
    }
    if (!std::strcmp(argv[1], "control")) return control();
    BotanKem kem = botan_kem_or_exit(argv[1]);
    Botan::System_RNG rng;
    /* No checks on the results here: a comparison in this file would itself
     * branch on values Botan may still have marked secret. Correctness is E4. */
    for (int round = 0; round < 2; round++) {
        auto sk = kem.keygen(rng);
        auto pub = kem.load_public(botan_pk_bytes(*sk));
        Botan::PK_KEM_Encryptor enc(*pub, "Raw");
        Botan::PK_KEM_Decryptor dec(*sk, rng, "Raw");
        std::vector<uint8_t> ct(enc.encapsulated_key_length()), s1(enc.shared_key_length(0)), s2(s1.size());
        enc.encrypt(std::span<uint8_t>(ct), std::span<uint8_t>(s1), rng, s1.size());
        dec.decrypt(std::span<uint8_t>(s2), std::span<const uint8_t>(ct), s2.size());
        rng.randomize(ct); /* random ciphertext: implicit rejection */
        dec.decrypt(std::span<uint8_t>(s2), std::span<const uint8_t>(ct), s2.size());
    }
    std::printf("%s botan ct driver done\n", argv[1]);
    return 0;
}
