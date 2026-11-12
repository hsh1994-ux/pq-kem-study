/*
 * botan_kem.h -- the KEMs of the study, as implemented by Botan 3.
 *
 * Maps the liboqs names used everywhere in this repository (kems.conf) to
 * Botan's key classes. Botan implements ML-KEM, FrodoKEM (the ISO version
 * with salt, as in liboqs) and Classic McEliece (round 4, non-"f"
 * parameter sets, as in liboqs). Botan has no HQC: botan_kem() returns
 * std::nullopt for it, and the tools print "unsupported" and exit 3.
 *
 * Keys travel between tools as raw bytes, exactly like liboqs:
 *   public key  = raw_public_key_bits()   (identical encoding to liboqs)
 *   private key = raw_private_key_bits()  (Botan's own format: for ML-KEM the
 *                 64-byte seed d||z of FIPS 203, for the others the raw key of
 *                 the specification)
 * The shared secret is the raw KEM output ("Raw": no extra KDF), so it can be
 * compared byte for byte with liboqs.
 */
#ifndef PQ_BOTAN_KEM_H
#define PQ_BOTAN_KEM_H

#include <botan/cmce.h>
#include <botan/frodokem.h>
#include <botan/ml_kem.h>
#include <botan/pubkey.h>
#include <botan/system_rng.h>

#include <cstdio>
#include <cstdlib>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

struct BotanKem {
    std::string name;  // liboqs name, e.g. "ML-KEM-768"
    std::function<std::unique_ptr<Botan::Private_Key>(Botan::RandomNumberGenerator&)> keygen;
    std::function<std::unique_ptr<Botan::Public_Key>(std::span<const uint8_t>)> load_public;
    std::function<std::unique_ptr<Botan::Private_Key>(std::span<const uint8_t>)> load_private;
};

inline std::optional<BotanKem> botan_kem(std::string_view alg) {
    using namespace Botan;
    auto ml_kem = [&](KyberMode::Mode m) {
        return BotanKem{std::string(alg),
                        [m](RandomNumberGenerator& r) { return std::make_unique<ML_KEM_PrivateKey>(r, m); },
                        [m](std::span<const uint8_t> b) { return std::make_unique<ML_KEM_PublicKey>(b, m); },
                        [m](std::span<const uint8_t> b) { return std::make_unique<ML_KEM_PrivateKey>(b, m); }};
    };
    auto frodo = [&](FrodoKEMMode::Mode m) {
        return BotanKem{std::string(alg),
                        [m](RandomNumberGenerator& r) { return std::make_unique<FrodoKEM_PrivateKey>(r, m); },
                        [m](std::span<const uint8_t> b) { return std::make_unique<FrodoKEM_PublicKey>(b, m); },
                        [m](std::span<const uint8_t> b) { return std::make_unique<FrodoKEM_PrivateKey>(b, m); }};
    };
    auto mce = [&](Classic_McEliece_Parameter_Set::Code c) {
        return BotanKem{
            std::string(alg),
            [c](RandomNumberGenerator& r) { return std::make_unique<Classic_McEliece_PrivateKey>(r, c); },
            [c](std::span<const uint8_t> b) { return std::make_unique<Classic_McEliece_PublicKey>(b, c); },
            [c](std::span<const uint8_t> b) { return std::make_unique<Classic_McEliece_PrivateKey>(b, c); }};
    };
    if (alg == "ML-KEM-512") return ml_kem(KyberMode::ML_KEM_512);
    if (alg == "ML-KEM-768") return ml_kem(KyberMode::ML_KEM_768);
    if (alg == "ML-KEM-1024") return ml_kem(KyberMode::ML_KEM_1024);
    if (alg == "FrodoKEM-640-SHAKE") return frodo(FrodoKEMMode::FrodoKEM640_SHAKE);
    if (alg == "FrodoKEM-976-SHAKE") return frodo(FrodoKEMMode::FrodoKEM976_SHAKE);
    if (alg == "FrodoKEM-1344-SHAKE") return frodo(FrodoKEMMode::FrodoKEM1344_SHAKE);
    if (alg == "Classic-McEliece-348864") return mce(Classic_McEliece_Parameter_Set::ClassicMcEliece_348864);
    if (alg == "Classic-McEliece-460896") return mce(Classic_McEliece_Parameter_Set::ClassicMcEliece_460896);
    if (alg == "Classic-McEliece-6688128") return mce(Classic_McEliece_Parameter_Set::ClassicMcEliece_6688128);
    return std::nullopt;  // HQC and anything else: not in Botan
}

/* Exit code 3 = "this KEM is not implemented by Botan"; the drivers record it
 * as such instead of as a failure. */
inline BotanKem botan_kem_or_exit(std::string_view alg) {
    auto k = botan_kem(alg);
    if (!k) {
        std::printf("unsupported,%.*s\n", (int)alg.size(), alg.data());
        std::exit(3);
    }
    return *k;
}

inline std::vector<uint8_t> botan_pk_bytes(const Botan::Private_Key& sk) { return sk.raw_public_key_bits(); }

inline std::vector<uint8_t> botan_sk_bytes(const Botan::Private_Key& sk) {
    auto s = sk.raw_private_key_bits();
    return {s.begin(), s.end()};
}

#endif
