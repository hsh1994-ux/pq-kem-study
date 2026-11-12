/*
 * bench_botan -- E1 microbenchmark for one KEM as implemented by Botan 3.
 *
 *   bench_botan ALG N_KEYGEN N_OPS        ALG: a liboqs name from kems.conf
 *
 * Same CSV row format as bench_kem (tier "botan"), so the two libraries land
 * in the same table. Exits 3 with "unsupported,ALG" for KEMs Botan does not
 * implement (HQC).
 *
 * What is timed, chosen to match liboqs' bytes-in / bytes-out API and what a
 * TLS 1.3 peer actually does:
 *   keygen = generate a key pair and encode the public key to bytes
 *            (the client sends those bytes)
 *   encaps = public key from bytes -> PK_KEM_Encryptor -> encapsulate
 *            (the server receives the client's bytes)
 *   decaps = PK_KEM_Decryptor on the key object from keygen -> decapsulate
 *            (the client still holds its key object; Botan may keep values it
 *            precomputed at key generation, which is Botan's design choice)
 * Randomness: Botan's System_RNG (the OS RNG, getrandom), like liboqs here.
 * Shared secret: "Raw" (no KDF), the plain KEM output as in liboqs.
 *
 * Stack use is measured as in bench_kem (pattern-filled thread stack).
 * Botan keeps most buffers on the heap (secure_vector), so its stack numbers
 * are small and not directly comparable with the C libraries.
 */
#include <pthread.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <vector>

#include "../common/botan_kem.h"
#include "../common/cpucycles.h"

#define STACK_SIZE (16u << 20)
#define PATTERN 0xA5

enum op { OP_NONE, OP_KEYGEN, OP_ENCAPS, OP_DECAPS };
static const char *op_name[] = {"none", "keygen", "encaps", "decaps"};

struct ctx {
    BotanKem kem;
    Botan::System_RNG rng;
    std::unique_ptr<Botan::Private_Key> sk;
    std::vector<uint8_t> pk, ct, ss;
    enum op op = OP_NONE;
    bool failed = false;
};

static void die(const char *msg) {
    std::fprintf(stderr, "%s\n", msg);
    std::exit(1);
}

static void run_op(ctx *c) {
    try {
        switch (c->op) {
        case OP_KEYGEN:
            c->sk = c->kem.keygen(c->rng);
            c->pk = botan_pk_bytes(*c->sk);
            break;
        case OP_ENCAPS: {
            auto pub = c->kem.load_public(c->pk);
            Botan::PK_KEM_Encryptor enc(*pub, "Raw");
            enc.encrypt(std::span<uint8_t>(c->ct), std::span<uint8_t>(c->ss), c->rng, c->ss.size());
            break;
        }
        case OP_DECAPS: {
            Botan::PK_KEM_Decryptor dec(*c->sk, c->rng, "Raw");
            dec.decrypt(std::span<uint8_t>(c->ss), std::span<const uint8_t>(c->ct), c->ss.size());
            break;
        }
        default:
            break;
        }
    } catch (const std::exception &e) {
        std::fprintf(stderr, "%s %s failed: %s\n", c->kem.name.c_str(), op_name[c->op], e.what());
        c->failed = true;
    }
}

static void *thread_main(void *arg) {
    run_op(static_cast<ctx *>(arg));
    return nullptr;
}

static size_t stack_used(ctx *c) {
    std::vector<uint8_t> stack(STACK_SIZE, PATTERN);
    pthread_attr_t attr;
    pthread_t th;
    pthread_attr_init(&attr);
    if (pthread_attr_setstack(&attr, stack.data(), STACK_SIZE)) die("pthread_attr_setstack");
    if (pthread_create(&th, &attr, thread_main, c)) die("pthread_create");
    pthread_join(th, nullptr);
    pthread_attr_destroy(&attr);
    size_t untouched = 0;
    while (untouched < STACK_SIZE && stack[untouched] == PATTERN) untouched++;
    return STACK_SIZE - untouched;
}

static uint64_t pct(const std::vector<uint64_t> &s, double p) {
    return s[(size_t)(p * (double)(s.size() - 1) + 0.5)];
}

static void bench(ctx *c, enum op op, int n, double ns_per_tick, size_t base_stack) {
    std::vector<uint64_t> t((size_t)n);
    c->op = op;
    for (int i = 0; i < (n < 10 ? 1 : n / 10); i++) run_op(c); /* warm-up */
    double ghz0 = pq_core_ghz();
    for (int i = 0; i < n; i++) {
        uint64_t t0 = cpucycles();
        run_op(c);
        t[(size_t)i] = cpucycles() - t0;
    }
    double ghz1 = pq_core_ghz();
    if (c->failed) die("operation failed");
    std::sort(t.begin(), t.end());
    double mean = 0;
    for (auto x : t) mean += (double)x;
    mean /= n;
    size_t st = stack_used(c);
    st = st > base_stack ? st - base_stack : 0;
    double med_ns = (double)pct(t, .5) * ns_per_tick;
    std::printf("botan,%s,%s,%d,%s,%.6f,%llu,%llu,%llu,%llu,%.1f,%.1f,%.1f,%.1f,%zu,%zu,%zu,%zu,%zu,"
                "%.3f,%.3f,%.0f\n",
                c->kem.name.c_str(), op_name[op], n, cpucycles_unit(), ns_per_tick, (unsigned long long)t[0],
                (unsigned long long)pct(t, .25), (unsigned long long)pct(t, .5), (unsigned long long)pct(t, .75),
                mean, med_ns, (double)pct(t, .25) * ns_per_tick, (double)pct(t, .75) * ns_per_tick, st,
                c->pk.size(), botan_sk_bytes(*c->sk).size(), c->ct.size(), c->ss.size(), ghz0, ghz1,
                med_ns * (ghz0 + ghz1) / 2);
    std::fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc != 4) die("usage: bench_botan ALG N_KEYGEN N_OPS");
    ctx c;
    c.kem = botan_kem_or_exit(argv[1]);
    int nk = std::atoi(argv[2]), no = std::atoi(argv[3]);

    /* sizes from a first key pair */
    c.op = OP_KEYGEN;
    run_op(&c);
    if (c.failed) die("keygen failed");
    {
        auto pub = c.kem.load_public(c.pk);
        Botan::PK_KEM_Encryptor enc(*pub, "Raw");
        c.ct.resize(enc.encapsulated_key_length());
        c.ss.resize(enc.shared_key_length(0));
    }

    double ns_per_tick = cpucycles_ns_per_tick();
    const char *wm = std::getenv("WARMUP_MS");
    pq_spin_ms(wm ? (unsigned)std::atoi(wm) : 200);
    c.op = OP_NONE;
    size_t base = stack_used(&c);

    bench(&c, OP_KEYGEN, nk, ns_per_tick, base); /* leaves a valid key pair */
    c.op = OP_ENCAPS;
    run_op(&c); /* valid ciphertext for decaps */
    bench(&c, OP_ENCAPS, no, ns_per_tick, base);
    bench(&c, OP_DECAPS, no, ns_per_tick, base);
    return 0;
}
