/* proxy.c — see proxy.h. */
#include "proxy.h"
#include "ca.h"
#include "dane.h"

#include <openssl/ssl.h>

#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <pthread.h>
#include <poll.h>

typedef struct {
    X509           *root;
    EVP_PKEY       *rootkey;
    SSL_CTX        *server_ctx;   /* browser side; mints per-SNI leaves */
    SSL_CTX        *client_ctx;   /* origin side; DANE-enabled          */
    proxy_resolver  resolve;
    void           *ud;
    const ProxyEvents *ev;        /* may be NULL (CLI) */
} Proxy;

static void nosigpipe(int fd) {
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
}

/* SNI callback: mint a leaf for the requested name and install it on this
 * handshake. This is where the browser-facing cert comes from — one per SNI,
 * signed by the name-constrained root. */
static int sni_cb(SSL *ssl, int *al, void *arg) {
    Proxy *px = arg;
    const char *sni = SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name);
    if (!sni) return SSL_TLSEXT_ERR_NOACK;

    X509 *leaf; EVP_PKEY *lk;
    if (!ca_leaf_mint(px->root, px->rootkey, sni, &leaf, &lk)) {
        *al = SSL_AD_INTERNAL_ERROR;
        return SSL_TLSEXT_ERR_ALERT_FATAL;
    }
    int ok = SSL_use_certificate(ssl, leaf) == 1 && SSL_use_PrivateKey(ssl, lk) == 1;
    X509_free(leaf);            /* SSL_use_* took their own references */
    EVP_PKEY_free(lk);
    if (!ok) { *al = SSL_AD_INTERNAL_ERROR; return SSL_TLSEXT_ERR_ALERT_FATAL; }
    if (px->ev && px->ev->minted) px->ev->minted(px->ev->u, sni);
    return SSL_TLSEXT_ERR_OK;
}

/* Serve a small local page over the (trusted) browser session. Used fail-closed:
 * we present a leaf the browser trusts, but the body is OUR diagnostic — never
 * origin bytes we could not authenticate. */
static void serve_status(SSL *b, int code, const char *title, const char *detail) {
    char body[700], resp[1000];
    int bl = snprintf(body, sizeof body,
        "<!doctype html><meta charset=utf-8><title>%d %s</title>"
        "<h1>%d %s</h1><p>%s</p>"
        "<hr><small>pepenet-tls — chain-authenticated .doge/.pepe</small>\n",
        code, title, code, title, detail);
    int rl = snprintf(resp, sizeof resp,
        "HTTP/1.0 %d %s\r\nContent-Type: text/html; charset=utf-8\r\n"
        "Content-Length: %d\r\nConnection: close\r\n\r\n%s",
        code, title, bl, body);
    SSL_write(b, resp, rl);

    /* Drain whatever the browser already sent before we close.
     *
     * We answer these pages without ever reading the request, so the client's
     * GET is still sitting unread in our receive queue. On BSD/macOS, close()
     * on a socket with unread received data sends a TCP RST rather than a FIN,
     * and an RST makes the peer's kernel discard ITS receive buffer — including
     * the page we just wrote into it. The browser then shows a connection reset
     * instead of the diagnostic, which matters most on the 502 path: that IS
     * the fail-closed explanation of why the site was blocked.
     *
     * Bounded two ways so a silent or hostile peer cannot pin this thread: a
     * short receive timeout (we are closing regardless, so a slow client only
     * costs the timeout) and a cap on how much we are willing to swallow. */
    int fd = SSL_get_fd(b);
    if (fd >= 0) {
        struct timeval tv = { 0, 250000 };            /* 250 ms */
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    }
    char sink[4096];
    for (size_t drained = 0; drained < 64 * 1024; ) {
        int n = SSL_read(b, sink, sizeof sink);
        if (n <= 0) break;                            /* EOF, timeout, or error */
        drained += (size_t)n;
    }
}

/* Move any readable+decryptable data from `from` to `to`. 1 = keep going,
 * 0 = this direction is done (peer closed or hard error).
 *
 * The loop condition must be SSL_has_pending(), not SSL_pending() alone.
 * SSL_pending() reports only the decrypted bytes left in the record OpenSSL has
 * ALREADY processed; it says nothing about further whole records OpenSSL has
 * read off the socket into its own buffer but not yet unwrapped. When a request
 * spans several records — every POST, every upload, and TLS 1.3 routinely —
 * SSL_pending() goes to 0 with data still buffered, splice() returns to
 * select(), and the kernel reports the socket as empty because those bytes are
 * inside OpenSSL rather than the receive queue. The connection then blocks
 * forever, leaking a thread and two fds. SSL_has_pending() covers both cases. */
static int pump(SSL *from, SSL *to) {
    do {
        char buf[16384];
        int n = SSL_read(from, buf, sizeof buf);
        if (n <= 0) {
            int e = SSL_get_error(from, n);
            return (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) ? 1 : 0;
        }
        for (int off = 0; off < n; ) {
            int w = SSL_write(to, buf + off, n - off);
            if (w <= 0) {
                int e = SSL_get_error(to, w);
                if (e != SSL_ERROR_WANT_READ && e != SSL_ERROR_WANT_WRITE) return 0;
                /* Non-blocking: wait for the far side to be ready rather than
                 * spinning on it. */
                struct pollfd wp = { SSL_get_fd(to),
                                     (short)(e == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT), 0 };
                if (poll(&wp, 1, -1) <= 0) return 0;
                continue;
            }
            off += w;
        }
    } while (SSL_pending(from) > 0 || SSL_has_pending(from));
    return 1;
}

/* Does this session hold bytes that select() cannot see? SSL_pending() covers
 * plaintext already decrypted; SSL_has_pending() also covers whole records read
 * off the socket but not yet unwrapped. Either way the kernel receive queue is
 * empty, so select() would report "nothing to read" and block on data we are
 * already holding. */
static int buffered(SSL *s) { return SSL_pending(s) > 0 || SSL_has_pending(s); }

/* Bidirectional plaintext relay between the two authenticated TLS sessions.
 *
 * The pre-select drain below is load-bearing, not an optimisation. OpenSSL reads
 * in record-sized gulps, and SSL_accept() itself can pull the client's first
 * application-data records off the socket while completing the handshake — so a
 * request can be sitting INSIDE the SSL object before this loop runs even once.
 * Blocking in select() first would then wait forever on a socket whose bytes we
 * already have: the browser waits for a response, we wait for a request we are
 * holding, and the origin waits for the rest of it. Draining what is buffered
 * before every poll() is what makes the relay safe. */
static void set_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl != -1) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/* Bidirectional plaintext relay between the two authenticated TLS sessions. */
static void splice(SSL *b, SSL *o) {
    int fb = SSL_get_fd(b), fo = SSL_get_fd(o);

    /* Both sides must be non-blocking for the relay to be safe.
     *
     * select() reporting a socket readable does NOT mean application data is
     * available: the bytes may be a TLS record that yields none. TLS 1.3 origins
     * routinely send NewSessionTicket right after the handshake, and a KeyUpdate
     * or renegotiation can do the same at any time. On a BLOCKING socket,
     * SSL_read then consumes that record, finds no application data, and blocks
     * — starving the opposite direction. That is a genuine three-way deadlock:
     * the browser waits for a response, we wait inside SSL_read on the origin,
     * and the origin waits for the rest of a request still sitting unread in our
     * browser socket. It strikes whenever a request spans several records, which
     * is every POST, every upload, and TLS 1.3 as a matter of course.
     * Non-blocking turns that block into WANT_READ, which pump() treats as
     * "nothing more this direction" and returns, so the loop keeps serving both. */
    set_nonblock(fb);
    set_nonblock(fo);
    for (;;) {
        int moved = 0;
        if (buffered(b)) { if (!pump(b, o)) break; moved = 1; }
        if (buffered(o)) { if (!pump(o, b)) break; moved = 1; }
        if (moved) continue;              /* re-check before trusting poll() */

        /* poll(), not select(): FD_SET on a descriptor >= FD_SETSIZE (1024)
         * writes past the 128-byte fd_set on this thread's stack, and select()
         * with nfds > FD_SETSIZE just fails with EINVAL. A busy proxy holds two
         * fds per tunnel, so that is reachable rather than theoretical. */
        struct pollfd pf[2] = { { fb, POLLIN, 0 }, { fo, POLLIN, 0 } };
        if (poll(pf, 2, -1) <= 0) break;
        if ((pf[0].revents & (POLLIN | POLLHUP | POLLERR)) && !pump(b, o)) break;
        if ((pf[1].revents & (POLLIN | POLLHUP | POLLERR)) && !pump(o, b)) break;
    }
}

static void handle(Proxy *px, int cfd) {
    nosigpipe(cfd);
    SSL *b = SSL_new(px->server_ctx);
    if (!b) { close(cfd); return; }
    SSL_set_fd(b, cfd);

    if (SSL_accept(b) == 1) {                       /* leaf minted in sni_cb */
        const char *sni = SSL_get_servername(b, TLSEXT_NAMETYPE_host_name);
        OriginInfo oi;
        char err[160];
        if (!sni || !px->resolve(sni, &oi, px->ud)) {
            if (px->ev && px->ev->verdict && sni)
                px->ev->verdict(px->ev->u, sni, 0, "");
            serve_status(b, 404, "unknown .doge/.pepe name", sni ? sni : "(no SNI)");
        } else {
            SSL *o = NULL; int ofd = -1;
            DaneResult r = dane_connect(px->client_ctx, oi.host, oi.port, sni,
                                        oi.usage, oi.selector, oi.mtype,
                                        oi.assoc, oi.assoc_len, &o, &ofd, err, sizeof err);
            if (px->ev && px->ev->verdict)
                px->ev->verdict(px->ev->u, sni, r == DANE_OK, oi.host);
            if (r == DANE_OK) {
                splice(b, o);
                SSL_shutdown(o); close(ofd); SSL_free(o);
            } else {
                serve_status(b, 502, "origin failed DANE authentication", err);
            }
        }
        SSL_shutdown(b);
    }
    SSL_free(b);
    close(cfd);
}

struct conn { Proxy *px; int fd; };

static void *conn_thread(void *a) {
    struct conn *c = a;
    handle(c->px, c->fd);
    free(c);
    return NULL;
}

int proxy_listen(const char *ip, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, ip, &sa.sin_addr) != 1 ||
        bind(fd, (struct sockaddr *)&sa, sizeof sa) != 0 ||
        listen(fd, 64) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int proxy_serve_ctl(int lfd, X509 *root, EVP_PKEY *rootkey,
                    proxy_resolver resolve, void *ud,
                    const ProxyEvents *ev, volatile int *stop) {
    Proxy *px = calloc(1, sizeof *px);
    if (!px) return 1;
    px->root = root;
    px->rootkey = rootkey;
    px->resolve = resolve;
    px->ud = ud;
    px->ev = ev;
    px->client_ctx = dane_client_ctx();
    px->server_ctx = SSL_CTX_new(TLS_server_method());
    if (!px->client_ctx || !px->server_ctx) { free(px); return 1; }
    SSL_CTX_set_min_proto_version(px->server_ctx, TLS1_2_VERSION);
    SSL_CTX_set_tlsext_servername_callback(px->server_ctx, sni_cb);
    SSL_CTX_set_tlsext_servername_arg(px->server_ctx, px);

    for (;;) {
        if (stop) {                        /* poll the flag between accepts */
            struct pollfd pfd = { lfd, POLLIN, 0 };
            if (*stop) break;
            if (poll(&pfd, 1, 500) <= 0) { if (*stop) break; continue; }
        }
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) { if (errno == EINTR) continue; break; }
        struct conn *c = malloc(sizeof *c);
        if (!c) { close(cfd); continue; }
        c->px = px;
        c->fd = cfd;
        pthread_t t;
        if (pthread_create(&t, NULL, conn_thread, c) != 0) { free(c); close(cfd); continue; }
        pthread_detach(t);
    }
    /* px + contexts are intentionally not freed: detached per-connection
     * threads may still hold them; the embedding host stops once at exit. */
    return 0;
}

int proxy_serve(int lfd, X509 *root, EVP_PKEY *rootkey,
                proxy_resolver resolve, void *ud) {
    return proxy_serve_ctl(lfd, root, rootkey, resolve, ud, NULL, NULL);
}

int proxy_run(const char *ip, int port, X509 *root, EVP_PKEY *rootkey,
              proxy_resolver resolve, void *ud) {
    int lfd = proxy_listen(ip, port);
    if (lfd < 0) return 1;
    return proxy_serve(lfd, root, rootkey, resolve, ud);
}
