/*
 * botan_hs_client -- E2 TLS 1.3 handshake timer using Botan's TLS stack.
 *
 *   botan_hs_client HOST PORT GROUP N
 *
 * The Botan counterpart of hs_client (OpenSSL). Offers exactly one key-exchange
 * GROUP, in Botan's naming (x25519, x25519/ML-KEM-768, ML-KEM-768,
 * eFrodoKEM-640-SHAKE, ...), opens N fresh connections and prints one CSV
 * row per handshake, in the same format as hs_client:
 *
 *   group,i,ok,tcp_ns,tls_ns,total_ns,bytes_sent,bytes_received
 *
 * tls_ns runs from creating the TLS client (which sends the ClientHello) to
 * the moment Botan reports the session active (server Finished verified,
 * client Finished sent). No session resumption (Session_Manager_Noop); the
 * certificate is not verified: E2 measures key exchange, not PKI. Each flight
 * is written with one send() and TCP_NODELAY is set, like hs_client; the
 * server side is bin/botan_hs_server.
 */
#include <arpa/inet.h>
#include <linux/tcp.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>

#include <botan/auto_rng.h>
#include <botan/credentials_manager.h>
#include <botan/tls_callbacks.h>
#include <botan/tls_client.h>
#include <botan/tls_policy.h>
#include <botan/tls_session_manager_noop.h>

#include <cstdio>
#include <cstdlib>
#include <exception>
#include <memory>
#include <string>

#include "../common/cpucycles.h"

namespace {

int tcp_connect(const char *host, const char *port) {
    addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res)) return -1;
    int fd = socket(res->ai_family, res->ai_socktype, 0);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    int r = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);
    if (r) {
        close(fd);
        return -1;
    }
    return fd;
}

class Callbacks final : public Botan::TLS::Callbacks {
  public:
    explicit Callbacks(int fd) : m_fd(fd) {}
    bool active = false, failed = false;

    /* Collect a whole flight and write it with one send(), as OpenSSL does. */
    void tls_emit_data(std::span<const uint8_t> data) override { m_out.insert(m_out.end(), data.begin(), data.end()); }
    void flush() {
        size_t off = 0;
        while (off < m_out.size()) {
            ssize_t w = send(m_fd, m_out.data() + off, m_out.size() - off, MSG_NOSIGNAL);
            if (w <= 0) {
                failed = true;
                break;
            }
            off += (size_t)w;
        }
        m_out.clear();
    }
    void tls_record_received(uint64_t, std::span<const uint8_t>) override {}
    void tls_alert(Botan::TLS::Alert alert) override {
        if (alert.is_fatal()) {
            std::fprintf(stderr, "alert: %s\n", alert.type_string().c_str());
            failed = true;
        }
    }
    void tls_session_activated() override { active = true; }
    void tls_verify_cert_chain(const std::vector<Botan::X509_Certificate> &,
                               const std::vector<std::optional<Botan::OCSP::Response>> &,
                               const std::vector<Botan::Certificate_Store *> &, Botan::Usage_Type, std::string_view,
                               const Botan::TLS::Policy &) override {}

  private:
    int m_fd;
    std::vector<uint8_t> m_out;
};

}  // namespace

int main(int argc, char **argv) {
    if (argc != 5) {
        std::fprintf(stderr, "usage: botan_hs_client HOST PORT GROUP N\n");
        return 2;
    }
    const char *host = argv[1], *port = argv[2];
    const std::string group = argv[3];
    int n = std::atoi(argv[4]);

    auto policy = std::make_shared<Botan::TLS::Text_Policy>(
        "allow_tls12 = false\n"
        "allow_tls13 = true\n"
        "key_exchange_groups = " + group + "\n"
        "key_exchange_groups_to_offer = " + group + "\n");
    if (policy->key_exchange_groups().empty()) {
        std::fprintf(stderr, "group %s not available in Botan\n", group.c_str());
        return 3;
    }
    auto rng = std::make_shared<Botan::AutoSeeded_RNG>();
    auto sessions = std::make_shared<Botan::TLS::Session_Manager_Noop>();
    auto creds = std::make_shared<Botan::Credentials_Manager>();

    for (int i = 0; i < n; i++) {
        uint64_t t0 = pq_now_ns();
        int fd = tcp_connect(host, port);
        uint64_t t1 = pq_now_ns(), t2 = t1;
        bool ok = false;
        tcp_info ti{};
        if (fd >= 0) {
            auto cb = std::make_shared<Callbacks>(fd);
            try {
                /* No SNI (empty host name), like hs_client: Botan's server picks
                 * its certificate by host name, and the test certificate has none. */
                Botan::TLS::Client client(cb, sessions, creds, policy, rng,
                                          Botan::TLS::Server_Information("", (uint16_t)std::atoi(port)),
                                          Botan::TLS::Protocol_Version::TLS_V13);
                cb->flush(); /* ClientHello */
                uint8_t buf[16384];
                while (!cb->active && !cb->failed && !client.is_closed()) {
                    ssize_t r = recv(fd, buf, sizeof buf, 0);
                    if (r <= 0) break;
                    client.received_data(std::span<const uint8_t>(buf, (size_t)r));
                    cb->flush();
                }
                ok = cb->active && !cb->failed;
            } catch (const std::exception &e) {
                std::fprintf(stderr, "handshake %d: %s\n", i, e.what());
            }
            t2 = pq_now_ns();
            socklen_t tl = sizeof ti;
            getsockopt(fd, IPPROTO_TCP, TCP_INFO, &ti, &tl);
            close(fd); /* no close_notify: we only measure the handshake */
        }
        std::printf("%s,%d,%d,%llu,%llu,%llu,%llu,%llu\n", group.c_str(), i, ok ? 1 : 0,
                    (unsigned long long)(t1 - t0), (unsigned long long)(t2 - t1), (unsigned long long)(t2 - t0),
                    (unsigned long long)ti.tcpi_bytes_sent, (unsigned long long)ti.tcpi_bytes_received);
        std::fflush(stdout);
    }
    return 0;
}
