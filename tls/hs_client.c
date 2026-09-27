/*
 * hs_client -- E2 TLS 1.3 handshake timer (RQ2).
 *
 *   hs_client HOST PORT GROUP N
 *
 * Opens N fresh connections offering exactly one key-exchange GROUP
 * (e.g. x25519, X25519MLKEM768, MLKEM768, frodo640shake) and prints one CSV
 * row per handshake (no header):
 *
 *   group,i,ok,tcp_ns,tls_ns,total_ns,bytes_sent,bytes_received
 *
 * tcp_ns   = connect() (TCP three-way handshake, 1 RTT)
 * tls_ns   = SSL_connect() (ClientHello .. Finished)
 * bytes_*  = TCP payload bytes from the kernel's tcp_info (sent includes any
 *            retransmissions), i.e. what went on
 *            the wire including TLS record overhead and the certificate chain.
 *
 * Session tickets are disabled so every handshake is a full one. The
 * certificate is not verified: E2 measures key exchange, not PKI.
 */
#include <arpa/inet.h>
#include <linux/tcp.h>
#include <netdb.h>
#include <openssl/err.h>
#include <openssl/provider.h>
#include <openssl/ssl.h>
#include <stdint.h>
#include <sys/socket.h>
#include <unistd.h>

#include "../common/cpucycles.h"
#include "../common/util.h"

static int tcp_connect(const char *host, const char *port) {
    struct addrinfo hints = {0}, *res;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res)) die("getaddrinfo %s:%s", host, port);
    int fd = socket(res->ai_family, res->ai_socktype, 0);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    int r = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);
    if (r) { close(fd); return -1; }
    return fd;
}

int main(int argc, char **argv) {
    if (argc != 5) die("usage: hs_client HOST PORT GROUP N");
    const char *host = argv[1], *port = argv[2], *group = argv[3];
    int n = atoi(argv[4]);

    /* default provider for classical + native ML-KEM; oqsprovider if present */
    OSSL_PROVIDER_load(NULL, "default");
    OSSL_PROVIDER_load(NULL, "oqsprovider"); /* ignore failure: native groups still work */
    ERR_clear_error();

    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION);
    SSL_CTX_set_options(ctx, SSL_OP_NO_TICKET);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    if (SSL_CTX_set1_groups_list(ctx, group) != 1) die("group %s not available", group);

    for (int i = 0; i < n; i++) {
        uint64_t t0 = pq_now_ns();
        int fd = tcp_connect(host, port);
        uint64_t t1 = pq_now_ns();
        int ok = 0;
        uint64_t t2 = t1;
        struct tcp_info ti = {0};
        if (fd >= 0) {
            SSL *s = SSL_new(ctx);
            SSL_set_fd(s, fd);
            ok = SSL_connect(s) == 1;
            t2 = pq_now_ns();
            socklen_t tl = sizeof ti;
            getsockopt(fd, IPPROTO_TCP, TCP_INFO, &ti, &tl);
            if (!ok) ERR_print_errors_fp(stderr);
            SSL_free(s); /* no close_notify: we only measure the handshake */
            close(fd);
        }
        printf("%s,%d,%d,%llu,%llu,%llu,%llu,%llu\n", group, i, ok,
               (unsigned long long)(t1 - t0), (unsigned long long)(t2 - t1),
               (unsigned long long)(t2 - t0), (unsigned long long)ti.tcpi_bytes_sent,
               (unsigned long long)ti.tcpi_bytes_received);
        fflush(stdout);
    }
    SSL_CTX_free(ctx);
    return 0;
}
