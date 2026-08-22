#!/bin/sh
# install-linux.sh — the privileged step that makes `*.<tld>` HTTPS Just Work
# in a browser on Linux. Same CLI as install.sh (which execs this on Linux):
#
#   sudo ./install.sh install   doge|pepe   [--dns-port 15353] [--proxy-port 8443]
#   sudo ./install.sh uninstall doge|pepe
#
# Three things, for ONE TLD:
#   1. trust the name-constrained root — nssdb as the real user (unprivileged
#      `install-ca`), then the Debian/Ubuntu/Fedora system store as root so
#      p11-kit / Firefox enterprise-roots / curl all see it;
#   2. systemd-resolved split-DNS: route *.<tld> at dnsd on 127.0.0.1:<dns-port>
#      WITHOUT replacing the box's global resolvers (a oneshot on `lo`);
#   3. nftables redirect 127.0.0.1:443 -> 127.0.0.1:<proxy-port> so a stock
#      :443 client (curl without --proxy) lands on the unprivileged proxy.
#      Best-effort: PAC (desktop) is the primary browser route; this is the
#      analogue of macOS pf, and install still succeeds if nft is missing.
#
# This script wires the OS. It does not start dnsd or the proxy.
set -eu

ACTION="${1:-}"
TLD="${2:-}"
DNS_PORT=15353
PROXY_PORT=8443
LOOPBACK=127.0.0.1
CERT=""

shift 2 2>/dev/null || { echo "usage: sudo $0 {install|uninstall} <doge|pepe> [opts]" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --dns-port)   DNS_PORT="$2";   shift 2 ;;
        --proxy-port) PROXY_PORT="$2"; shift 2 ;;
        --cert)       CERT="$2";       shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$TLD" in doge|pepe) ;; *)
    echo "TLD must be 'doge' or 'pepe' (this box serves exactly one)" >&2; exit 2 ;;
esac
case "$ACTION" in install|uninstall) ;; *)
    echo "action must be 'install' or 'uninstall'" >&2; exit 2 ;;
esac

if [ "$(id -u)" != "0" ]; then
    echo "must run as root (sudo) — it writes the system CA store and resolved/nft" >&2
    exit 1
fi

RUSER="${SUDO_USER:-${PKEXEC_UID:+$(id -un "$PKEXEC_UID")}}"
RUSER="${RUSER:-$(id -un)}"
RHOME="$(getent passwd "$RUSER" | cut -d: -f6)"
RHOME="${RHOME:-$(eval echo "~$RUSER")}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/pepenet-tls"

UNIT="pepenet-web-$TLD.service"
UNIT_PATH="/etc/systemd/system/$UNIT"
NFT_DIR="/etc/pepenet"
NFT_FILE="$NFT_DIR/nft-$TLD.nft"
CA_DEB="/usr/local/share/ca-certificates/pepenet-$TLD.crt"
CA_FED="/etc/pki/ca-trust/source/anchors/pepenet-$TLD.crt"

if [ -z "$CERT" ]; then
    CERT="$RHOME/.pepenet/pepenet-root-$TLD.crt"
fi

# ── system CA store ───────────────────────────────────────────────────────────
ca_install() {
    [ -f "$CERT" ] || { echo "no root cert at $CERT (run: $BIN --tld $TLD gen-ca)" >&2; return 1; }
    if [ -d /usr/local/share/ca-certificates ] && command -v update-ca-certificates >/dev/null 2>&1; then
        cp "$CERT" "$CA_DEB"
        chmod 644 "$CA_DEB"
        update-ca-certificates >/dev/null
        echo "   system store: $CA_DEB"
    elif command -v update-ca-trust >/dev/null 2>&1; then
        mkdir -p /etc/pki/ca-trust/source/anchors
        cp "$CERT" "$CA_FED"
        chmod 644 "$CA_FED"
        update-ca-trust extract
        echo "   system store: $CA_FED"
    else
        echo "   [WARN] no update-ca-certificates / update-ca-trust — system store skipped" >&2
        return 0
    fi
}

ca_uninstall() {
    rm -f "$CA_DEB" "$CA_FED"
    if command -v update-ca-certificates >/dev/null 2>&1; then
        update-ca-certificates >/dev/null 2>&1 || true
    elif command -v update-ca-trust >/dev/null 2>&1; then
        update-ca-trust extract >/dev/null 2>&1 || true
    fi
}

# ── systemd-resolved split-DNS on lo (routing-only domain ~$TLD) ──────────────
# Must NOT set DNS= in resolved.conf — that would make 127.0.0.1 a GLOBAL
# resolver and break every name dnsd does not serve. lo typically has no DNS
# servers of its own; attaching 127.0.0.1:$DNS_PORT + Domains=~$TLD routes
# only *.$TLD there and leaves wlan/eth DHCP resolvers alone.
write_unit() {
    mkdir -p /etc/systemd/system
    # `-` prefix: nft is best-effort (no nat / no nft → still want split-DNS).
    # resolvectl revert on stop puts lo back to its empty DNS list.
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=PepeNet .$TLD split-DNS + loopback :443 redirect
After=systemd-resolved.service
Wants=systemd-resolved.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/resolvectl dns lo $LOOPBACK:$DNS_PORT
ExecStart=/usr/bin/resolvectl domain lo ~$TLD
-ExecStart=/usr/sbin/nft -f $NFT_FILE
-ExecStop=/usr/bin/resolvectl revert lo
-ExecStop=/usr/sbin/nft delete table ip pepenet-$TLD

[Install]
WantedBy=multi-user.target
EOF
}

# nft is best-effort: a missing binary, a kernel without nat, or a policy
# that forbids output-hook redirect must not fail the install. The unit's
# ExecStart for nft is similarly allowed to fail via `-` in the unit — we
# write a real ExecStart and tolerate failure at enable-time below.
write_nft() {
    mkdir -p "$NFT_DIR"
    cat > "$NFT_FILE" <<EOF
# pepenet-$TLD — locally-originated 127.0.0.1:443 → the unprivileged proxy.
# Loaded after a best-effort delete so a reinstall is idempotent (flush
# would fail the first time the table does not exist).
table ip pepenet-$TLD {
    chain output {
        type nat hook output priority -100;
        ip daddr $LOOPBACK tcp dport 443 redirect to :$PROXY_PORT
    }
}
EOF
}

apply_runtime() {
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl dns lo "$LOOPBACK:$DNS_PORT" || \
            echo "   [WARN] resolvectl dns lo failed — split-DNS not active" >&2
        resolvectl domain lo "~$TLD" || \
            echo "   [WARN] resolvectl domain lo failed" >&2
    else
        echo "   [WARN] resolvectl missing — no split-DNS (PAC / explicit --resolve still work)" >&2
    fi
    if command -v nft >/dev/null 2>&1; then
        nft delete table ip pepenet-$TLD >/dev/null 2>&1 || true
        nft -f "$NFT_FILE" || echo "   [WARN] nft failed — :443 redirect off (PAC unaffected)" >&2
    else
        echo "   [WARN] nft missing — :443 redirect off" >&2
    fi
}

# ── Firefox enterprise-roots (p11-kit reads the SYSTEM store on Linux) ────────
FF_MARK="// pepenet-tls: trust OS roots (incl. the .$TLD root CA)"
FF_PREF='user_pref("security.enterprise_roots.enabled", true);'

firefox_profiles() {
    echo "$RHOME/.mozilla/firefox"
}

firefox_install() {
    pd="$(firefox_profiles)"
    [ -d "$pd" ] || { echo "   (no Firefox profiles — skipping)"; return 0; }
    n=0
    for prof in "$pd"/*/; do
        [ -d "$prof" ] || continue
        uj="${prof}user.js"
        if grep -qs 'security.enterprise_roots.enabled' "$uj" 2>/dev/null; then
            continue
        fi
        printf '%s\n%s\n' "$FF_MARK" "$FF_PREF" >> "$uj"
        chown "$RUSER:" "$uj" 2>/dev/null || true
        n=$((n + 1))
    done
    echo "   enabled enterprise roots in $n Firefox profile(s) — restart Firefox to apply"
}

firefox_uninstall() {
    pd="$(firefox_profiles)"
    [ -d "$pd" ] || return 0
    for prof in "$pd"/*/; do
        uj="${prof}user.js"
        [ -f "$uj" ] || continue
        sed -i '/pepenet-tls: trust OS roots/,+1d' "$uj" 2>/dev/null || true
    done
}

do_install() {
    echo "==> 1/4 trusting the name-constrained .$TLD root (nssdb as $RUSER)"
    if [ -x "$BIN" ]; then
        sudo -u "$RUSER" env HOME="$RHOME" "$BIN" --tld "$TLD" install-ca || \
            echo "   [WARN] nssdb install failed (certutil missing?); system store still planted" >&2
    else
        echo "   (no $BIN — skipping nssdb; gen-ca + install-ca later if you want Chromium's user db)"
    fi
    echo "==> 2/4 system CA store"
    ca_install

    echo "==> 3/4 split-DNS + :443 redirect (resolved on lo, nftables)"
    write_nft
    write_unit
    apply_runtime
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl enable --now "$UNIT" >/dev/null 2>&1 || \
            echo "   [WARN] systemctl enable $UNIT failed — runtime apply above still ran" >&2
    fi

    echo "==> 4/4 Firefox trust (enterprise_roots → p11-kit system store)"
    firefox_install

    cat <<EOF

installed for .$TLD. To go live:
  1. run dnsd with:   --tls-redirect $LOOPBACK --suffix $TLD --dns-port $DNS_PORT
  2. run the proxy:   $BIN --tld $TLD serve --db <indexer.db> --store <carrier.db> --port $PROXY_PORT
  3. verify:          curl -v https://<name>.$TLD/    (expect the padlock, no CA warning)
  4. Firefox/Chromium: fully quit + reopen (roots are read at startup)

manual verification:
  - resolvectl query <name>.$TLD                       # split-DNS → $LOOPBACK
  - nft list table ip pepenet-$TLD                     # :443 redirect (if nft worked)
  - awk -F: '/pepenet-$TLD/{print}' /etc/ca-certificates.conf  # Debian system store
EOF
}

do_uninstall() {
    echo "==> removing .$TLD root (nssdb as $RUSER + system store)"
    [ -x "$BIN" ] && sudo -u "$RUSER" env HOME="$RHOME" "$BIN" --tld "$TLD" uninstall-ca || true
    ca_uninstall

    echo "==> reverting Firefox enterprise-roots pref"
    firefox_uninstall

    echo "==> removing split-DNS + nft"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
    fi
    rm -f "$UNIT_PATH" "$NFT_FILE"
    rmdir "$NFT_DIR" 2>/dev/null || true
    command -v resolvectl >/dev/null 2>&1 && resolvectl revert lo 2>/dev/null || true
    command -v nft >/dev/null 2>&1 && nft delete table ip pepenet-$TLD 2>/dev/null || true
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
    echo "done."
}

case "$ACTION" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
esac
