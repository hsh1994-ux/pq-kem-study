/*
 * botan_hs_server -- E2 TLS 1.3 server built on Botan's TLS stack.
 *
 *   botan_hs_server CERT KEY PORT GROUPS...
 *
 * Accepts connections one after the other and completes a TLS 1.3 handshake
 * with each, offering the given key-exchange GROUPS (Botan names). It replaces
 * the `botan tls_server` command-line demo, which writes every TLS record with
 * its own send() and leaves Nagle's algorithm on: TCP then holds the rest of
 * the server's flight until the client's ACK arrives, adding one round trip
 * to every handshake. Here, like OpenSSL's s_server, everything Botan
 * produces while processing one batch of received bytes is written with a
 * single send(), and TCP_NODELAY is set, so the handshake takes the round
 * trips the protocol needs and no more.
 *
 * No session tickets, no resumption: every handshake is a full one.
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <botan/auto_rng.h>
#include <botan/credentials_manager.h>
#include <botan/data_src.h>
#include <botan/pkcs8.h>
#include <botan/tls_callbacks.h>
#include <botan/tls_policy.h>
#include <botan/tls_server.h>
#include <botan/tls_session_manager_noop.h>
#include <botan/x509cert.h>

#include <cstdio>
#include <cstdlib>
#include <exception>
#include <memory>
#include <string>
#include <vector>

namespace {

class Credentials final : public Botan::Credentials_Manager {
  public:
    Credentials(const std::string &cert, const std::string &key) : m_cert(cert) {
        Botan::DataSource_Stream in(key);
        m_key = Botan::PKCS8::load_key(in);
    }
    std::vector<Botan::X509_Certificate> find_cert_chain(const std::vector<std::string> &,
                                                         const std::vector<Botan::AlgorithmIdentifier> &,
                                                         const std::vector<Botan::X509_DN> &, const std::string &,
                                                         const std::string &) override {
        return {m_cert};
    }
    std::shared_ptr<Botan::Private_Key> private_key_for(const Botan::X509_Certificate &, const std::string &,
                                                        const std::string &) override {
        return m_key;
    }

  private:
    Botan::X509_Certificate m_cert;
    std::shared_ptr<Botan::Private_Key> m_key;
};

/* Collects what Botan wants to send; flush() writes it in one send(). */
class Callbacks final : public Botan::TLS::Callbacks {
  public:
    explicit Callbacks(int fd) : m_fd(fd) {}
    bool failed = false;

    void tls_emit_data(std::span<const uint8_t> data) override { m_out.insert(m_out.end(), data.begin(), data.end()); }
    void tls_record_received(uint64_t, std::span<const uint8_t>) override {}
    void tls_alert(Botan::TLS::Alert alert) override {
        if (alert.is_fatal()) failed = true;
    }
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

  private:
    int m_fd;
    std::vector<uint8_t> m_out;
};

}  // namespace

int main(int argc, char **argv) {
    if (argc < 5) {
        std::fprintf(stderr, "usage: botan_hs_server CERT KEY PORT GROUPS...\n");
        return 2;
    }
    std::string groups;
    for (int i = 4; i < argc; i++) groups += std::string(i > 4 ? " " : "") + argv[i];
    auto policy = std::make_shared<Botan::TLS::Text_Policy>(
        "allow_tls12 = false\n"
        "allow_tls13 = true\n"
        "key_exchange_groups = " + groups + "\n"
        "new_session_tickets_upon_handshake_success = 0\n");
    auto rng = std::make_shared<Botan::AutoSeeded_RNG>();
    auto sessions = std::make_shared<Botan::TLS::Session_Manager_Noop>();
    auto creds = std::make_shared<Credentials>(argv[1], argv[2]);

    int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)std::atoi(argv[3]));
    if (bind(ls, (sockaddr *)&addr, sizeof addr) || listen(ls, 16)) {
        std::perror("bind/listen");
        return 1;
    }
    for (;;) {
        int fd = accept(ls, nullptr, nullptr);
        if (fd < 0) continue;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        auto cb = std::make_shared<Callbacks>(fd);
        try {
            Botan::TLS::Server server(cb, sessions, creds, policy, rng);
            uint8_t buf[16384];
            /* Serve until the client hangs up (it does so right after the handshake). */
            while (!cb->failed && !server.is_closed()) {
                ssize_t r = recv(fd, buf, sizeof buf, 0);
                if (r <= 0) break;
                server.received_data(std::span<const uint8_t>(buf, (size_t)r));
                cb->flush();
            }
        } catch (const std::exception &e) {
            std::fprintf(stderr, "connection: %s\n", e.what());
        }
        close(fd);
    }
}
