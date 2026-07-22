/* trust.h — install / remove the pepenet root in the OS trust store.
 *
 * Slice 1 targets the macOS user login keychain via `security`; modifying root
 * trust settings triggers a GUI auth prompt — that IS the operator's deliberate
 * consent to trust the `.doge`/`.pepe` root (DESIGN.md §2). Firefox/Chrome NSS
 * (`certutil`) is a follow-on (DESIGN.md §8; `certutil` not installed on this box).
 */
#ifndef PEPENET_TLS_TRUST_H
#define PEPENET_TLS_TRUST_H

/* Install `certpath` (PEM) as a trusted root in the login keychain. 1 on success. */
int trust_install(const char *certpath);

/* Remove the root's trust settings + the cert itself (matched by subject CN,
 * e.g. ca_root_cn()). Best-effort; 1 on success. */
int trust_uninstall(const char *certpath, const char *cn);

#endif
