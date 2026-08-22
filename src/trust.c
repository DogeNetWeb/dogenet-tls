/* trust.c — see trust.h. */
#include "trust.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#ifdef __APPLE__
/* -r trustRoot marks it a trusted anchor; no -d ⇒ the user login keychain
 * (unprivileged). macOS pops a GUI auth dialog to change trust settings —
 * expected: the operator is consenting to install this root. */
int trust_install(const char *certpath) {
    char cmd[1400];
    snprintf(cmd, sizeof cmd,
        "security add-trusted-cert -r trustRoot "
        "-k \"$HOME/Library/Keychains/login.keychain-db\" \"%s\"",
        certpath);
    return system(cmd) == 0;
}

int trust_uninstall(const char *certpath, const char *cn) {
    char cmd[1400];
    /* Drop trust settings, then delete the cert by CN (the active TLD's root,
     * e.g. "pepenet .doge root CA"). Both best-effort so an already-partly-
     * removed state still returns cleanly. */
    snprintf(cmd, sizeof cmd,
        "security remove-trusted-cert \"%s\" 2>/dev/null; "
        "security delete-certificate -c \"%s\" "
        "\"$HOME/Library/Keychains/login.keychain-db\" 2>/dev/null; true",
        certpath, cn);
    return system(cmd) == 0;
}

#elif defined(__linux__)

/* Nickname in the NSS db: the cert file's basename without .crt
 * (e.g. ~/.pepenet/pepenet-root-pepe.crt → "pepenet-root-pepe"). Stable
 * across install/uninstall without needing the CN at install time. */
static void nss_nick(const char *certpath, char *out, size_t cap) {
    const char *b = certpath ? strrchr(certpath, '/') : NULL;
    b = b ? b + 1 : (certpath ? certpath : "pepenet-root");
    snprintf(out, cap, "%s", b);
    size_t n = strlen(out);
    if (n > 4 && strcmp(out + n - 4, ".crt") == 0) out[n - 4] = 0;
}

static int have_certutil(void) {
    return system("command -v certutil >/dev/null 2>&1") == 0;
}

static int nssdb_path(char *out, size_t cap) {
    const char *home = getenv("HOME");
    if (!home || !home[0]) return 0;
    snprintf(out, cap, "%s/.pki/nssdb", home);
    return 1;
}

static int nssdb_ensure(const char *dir) {
    char cmd[700];
    snprintf(cmd, sizeof cmd, "mkdir -p \"%s\"", dir);
    if (system(cmd) != 0) return 0;
    char db[600];
    snprintf(db, sizeof db, "%s/cert9.db", dir);
    struct stat st;
    if (stat(db, &st) == 0) return 1;
    /* empty-password: this is a per-user TLS trust db, not a login keyring.
     * Chromium creates the same db the same way. */
    snprintf(cmd, sizeof cmd,
             "certutil -N -d sql:\"%s\" --empty-password >/dev/null 2>&1", dir);
    return system(cmd) == 0;
}

int trust_install(const char *certpath) {
    if (!certpath || !certpath[0]) return 0;
    struct stat st;
    if (stat(certpath, &st) != 0) return 0;
    /* No certutil → nothing for the unprivileged half to do. The privileged
     * helper plants the system store; p11-kit/Firefox enterprise-roots pick
     * it up. Returning 1 lets `install-ca` / desktop sysinstall proceed. */
    if (!have_certutil()) return 1;
    char dir[512], nick[128], cmd[1600];
    if (!nssdb_path(dir, sizeof dir) || !nssdb_ensure(dir)) return 0;
    nss_nick(certpath, nick, sizeof nick);
    /* delete+add keeps reinstall idempotent when the PEM rotated */
    snprintf(cmd, sizeof cmd,
        "certutil -D -d sql:\"%s\" -n \"%s\" >/dev/null 2>&1; "
        "certutil -A -d sql:\"%s\" -t \"C,,\" -n \"%s\" -i \"%s\"",
        dir, nick, dir, nick, certpath);
    return system(cmd) == 0;
}

int trust_uninstall(const char *certpath, const char *cn) {
    (void)cn;
    if (!have_certutil()) return 1;
    char dir[512], nick[128], cmd[900];
    if (!nssdb_path(dir, sizeof dir)) return 1;
    nss_nick(certpath, nick, sizeof nick);
    snprintf(cmd, sizeof cmd,
             "certutil -D -d sql:\"%s\" -n \"%s\" >/dev/null 2>&1; true",
             dir, nick);
    return system(cmd) == 0;
}

#else
int trust_install(const char *certpath) {
    (void)certpath;
    fprintf(stderr, "trust_install: no user trust-store backend on this OS\n");
    return 0;
}
int trust_uninstall(const char *certpath, const char *cn) {
    (void)certpath; (void)cn;
    return 0;
}
#endif
