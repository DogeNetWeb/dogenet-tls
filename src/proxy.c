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
}

/* Move any readable+decryptable data from `from` to `to`. 1 = keep going,
 * 0 = this direction is done (peer closed or hard error). */
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
                if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) continue;
                return 0;
            }
            off += w;
        }
    } while (SSL_pending(from) > 0);
    return 1;
}

/* Bidirectional plaintext relay between the two authenticated TLS sessions. */
static void splice(SSL *b, SSL *o) {
    int fb = SSL_get_fd(b), fo = SSL_get_fd(o);
    int mx = (fb > fo ? fb : fo) + 1;
    for (;;) {
        fd_set rf;
        FD_ZERO(&rf);
        FD_SET(fb, &rf);
        FD_SET(fo, &rf);
        if (select(mx, &rf, NULL, NULL, NULL) <= 0) break;
        if (FD_ISSET(fb, &rf) && !pump(b, o)) break;
        if (FD_ISSET(fo, &rf) && !pump(o, b)) break;
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
