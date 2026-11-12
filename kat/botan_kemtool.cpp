/*
 * botan_kemtool -- keygen / encaps / decaps on raw binary files, via Botan 3.
 *
 * The Botan counterpart of kemtool (liboqs). E4 uses the two to check that a
 * public key made by one library can be encapsulated to by the other, and
 * that both then hold the same shared secret.
 *
 *   botan_kemtool info     ALG
 *   botan_kemtool keygen   ALG PK SK
 *   botan_kemtool encaps   ALG PK CT SS
 *   botan_kemtool decaps   ALG SK CT SS
 *   botan_kemtool selftest ALG N                 N random round trips
 *   botan_kemtool acvp-keygen ALG D_Z EK DK      (hex) ML-KEM only
 *   botan_kemtool acvp-encap  ALG M EK K C       (hex) ML-KEM only
 *   botan_kemtool acvp-decap  ALG DK K C         (hex) ML-KEM only
 *
 * PK/CT/SS files hold the same raw bytes as kemtool's. SK files hold Botan's
 * raw private key (for ML-KEM the 64-byte seed), only read back by this tool.
 * Exit codes: 0 ok, 1 failure/mismatch, 2 usage, 3 KEM not in Botan (HQC).
 */
#include <botan/hex.h>

#include <cstdio>
#include <cstring>
#include <exception>
#include <fstream>
#include <iterator>

#include "../common/botan_kem.h"

namespace {

std::vector<uint8_t> read_all(const char *path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error(std::string("cannot read ") + path);
    return {std::istreambuf_iterator<char>(f), {}};
}

void write_all(const char *path, std::span<const uint8_t> b) {
    std::ofstream f(path, std::ios::binary);
    f.write(reinterpret_cast<const char *>(b.data()), (std::streamsize)b.size());
    if (!f) throw std::runtime_error(std::string("cannot write ") + path);
}

/* Returns exactly the bytes it was given (FIPS 203's "m" for encapsulation),
 * and refuses to make up more. */
class Fixed_RNG final : public Botan::RandomNumberGenerator {
  public:
    explicit Fixed_RNG(std::vector<uint8_t> b) : m_buf(std::move(b)) {}
    bool accepts_input() const override { return false; }
    std::string name() const override { return "Fixed_RNG"; }
    void clear() override {}
    bool is_seeded() const override { return true; }

  protected:
    void fill_bytes_with_input(std::span<uint8_t> out, std::span<const uint8_t>) override {
        if (out.size() > m_buf.size() - m_pos) throw std::runtime_error("Fixed_RNG exhausted");
        std::memcpy(out.data(), m_buf.data() + m_pos, out.size());
        m_pos += out.size();
    }

  private:
    std::vector<uint8_t> m_buf;
    size_t m_pos = 0;
};

struct Kem {
    BotanKem k;
    Botan::System_RNG rng;
    explicit Kem(const char *alg) : k(botan_kem_or_exit(alg)) {}

    void encaps(const Botan::Public_Key &pub, Botan::RandomNumberGenerator &r, std::vector<uint8_t> &ct,
                std::vector<uint8_t> &ss) {
        Botan::PK_KEM_Encryptor enc(pub, "Raw");
        ct.resize(enc.encapsulated_key_length());
        ss.resize(enc.shared_key_length(0));
        enc.encrypt(std::span<uint8_t>(ct), std::span<uint8_t>(ss), r, ss.size());
    }
    std::vector<uint8_t> decaps(const Botan::Private_Key &sk, std::span<const uint8_t> ct) {
        Botan::PK_KEM_Decryptor dec(sk, rng, "Raw");
        std::vector<uint8_t> ss(dec.shared_key_length(0));
        dec.decrypt(std::span<uint8_t>(ss), ct, ss.size());
        return ss;
    }
};

int cmd_info(const char *alg) {
    Kem m(alg);
    auto sk = m.k.keygen(m.rng);
    std::vector<uint8_t> ct, ss;
    m.encaps(*sk, m.rng, ct, ss);
    std::printf("alg=%s\ntier=botan\npk_bytes=%zu\nsk_bytes=%zu\nct_bytes=%zu\nss_bytes=%zu\n", alg,
                botan_pk_bytes(*sk).size(), botan_sk_bytes(*sk).size(), ct.size(), ss.size());
    return 0;
}

int cmd_keygen(const char *alg, const char *pkf, const char *skf) {
    Kem m(alg);
    auto sk = m.k.keygen(m.rng);
    write_all(pkf, botan_pk_bytes(*sk));
    write_all(skf, botan_sk_bytes(*sk));
    return 0;
}

int cmd_encaps(const char *alg, const char *pkf, const char *ctf, const char *ssf) {
    Kem m(alg);
    auto pub = m.k.load_public(read_all(pkf));
    std::vector<uint8_t> ct, ss;
    m.encaps(*pub, m.rng, ct, ss);
    write_all(ctf, ct);
    write_all(ssf, ss);
    return 0;
}

int cmd_decaps(const char *alg, const char *skf, const char *ctf, const char *ssf) {
    Kem m(alg);
    auto sk = m.k.load_private(read_all(skf));
    write_all(ssf, m.decaps(*sk, read_all(ctf)));
    return 0;
}

int cmd_selftest(const char *alg, int n) {
    Kem m(alg);
    int bad = 0;
    for (int i = 0; i < n; i++) {
        try {
            auto sk = m.k.keygen(m.rng);
            auto pub = m.k.load_public(botan_pk_bytes(*sk));
            std::vector<uint8_t> ct, s1;
            m.encaps(*pub, m.rng, ct, s1);
            bad += m.decaps(*sk, ct) != s1;
        } catch (const std::exception &e) {
            std::fprintf(stderr, "%s\n", e.what());
            bad++;
        }
    }
    std::printf("%s botan %d/%d ok\n", alg, n - bad, n);
    return bad != 0;
}

/* ---- NIST ACVP (FIPS 203), ML-KEM only ---- */
bool is_ml_kem(const char *alg) { return std::strncmp(alg, "ML-KEM-", 7) == 0; }

int cmd_acvp_keygen(const char *alg, const char *dz, const char *ek, const char *dk) {
    Kem m(alg);
    auto sk = m.k.load_private(Botan::hex_decode(dz)); /* the 64-byte seed d || z */
    auto &ml = dynamic_cast<const Botan::ML_KEM_PrivateKey &>(*sk);
    auto dk_got = ml.formatted_raw_private_key_bits(Botan::MlPrivateKeyFormat::Expanded);
    bool ok = sk->raw_public_key_bits() == Botan::hex_decode(ek) &&
              std::vector<uint8_t>(dk_got.begin(), dk_got.end()) == Botan::hex_decode(dk);
    return ok ? 0 : 1;
}

int cmd_acvp_encap(const char *alg, const char *mh, const char *ek, const char *k, const char *c) {
    Kem m(alg);
    auto pub = m.k.load_public(Botan::hex_decode(ek));
    Fixed_RNG fixed(Botan::hex_decode(mh));
    std::vector<uint8_t> ct, ss;
    m.encaps(*pub, fixed, ct, ss);
    return ct == Botan::hex_decode(c) && ss == Botan::hex_decode(k) ? 0 : 1;
}

int cmd_acvp_decap(const char *alg, const char *dk, const char *k, const char *c) {
    Kem m(alg);
    auto sk = m.k.load_private(Botan::hex_decode(dk)); /* the expanded key of FIPS 203 */
    return m.decaps(*sk, Botan::hex_decode(c)) == Botan::hex_decode(k) ? 0 : 1;
}

}  // namespace

int main(int argc, char **argv) {
    try {
        std::string c = argc >= 2 ? argv[1] : "";
        if (c == "info" && argc == 3) return cmd_info(argv[2]);
        if (c == "keygen" && argc == 5) return cmd_keygen(argv[2], argv[3], argv[4]);
        if (c == "encaps" && argc == 6) return cmd_encaps(argv[2], argv[3], argv[4], argv[5]);
        if (c == "decaps" && argc == 6) return cmd_decaps(argv[2], argv[3], argv[4], argv[5]);
        if (c == "selftest" && argc == 4) return cmd_selftest(argv[2], std::atoi(argv[3]));
        if (c.rfind("acvp-", 0) == 0 && argc >= 3 && !is_ml_kem(argv[2])) return 2;
        if (c == "acvp-keygen" && argc == 6) return cmd_acvp_keygen(argv[2], argv[3], argv[4], argv[5]);
        if (c == "acvp-encap" && argc == 7) return cmd_acvp_encap(argv[2], argv[3], argv[4], argv[5], argv[6]);
        if (c == "acvp-decap" && argc == 6) return cmd_acvp_decap(argv[2], argv[3], argv[4], argv[5]);
    } catch (const std::exception &e) {
        std::fprintf(stderr, "error: %s\n", e.what());
        return 1;
    }
    std::fprintf(stderr,
                 "usage: botan_kemtool info ALG | keygen ALG PK SK | encaps ALG PK CT SS | decaps ALG SK CT SS\n"
                 "                     | selftest ALG N | acvp-keygen ALG D_Z EK DK\n"
                 "                     | acvp-encap ALG M EK K C | acvp-decap ALG DK K C\n");
    return 2;
}
