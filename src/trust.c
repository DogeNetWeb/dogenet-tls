/* trust.c — see trust.h. macOS `security` wrapper. */
#include "trust.h"

#include <stdio.h>
#include <stdlib.h>

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
