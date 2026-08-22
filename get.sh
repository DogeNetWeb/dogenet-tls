#!/bin/bash
#
# pepenet-tls installer — one command, macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/get.sh | bash
#   curl -fsSL .../get.sh | bash -s -- --tld pepe
#   curl -fsSL .../get.sh | bash -s -- uninstall
#
# Clones the family, builds dnsd + pepenet-tls, starts them as user services,
# then elevates to plant the CA / split-DNS / :443 redirect. That is the
# padlock: OS wiring PLUS the two daemons. install.sh by itself only does
# the OS half.
#
# Env: PEPENET_HOME (default ~/.pepenet), PEPENET_REF (default linux),
#      PEPENET_TLD (default pepe), PEPENET_PEER (default pepenet.shibpost.com:33874)
#
# Windows: install.ps1 (irm … | iex) — pepenet-tls is POSIX; the padlock
# there is pepenet-desktop.

set -euo pipefail

ORG="${PEPENET_ORG:-PepeNetWeb}"
REF="${PEPENET_REF:-linux}"
HOME_DIR="${PEPENET_HOME:-$HOME/.pepenet}"
TLD="${PEPENET_TLD:-pepe}"
PEER="${PEPENET_PEER:-}"
COIN="pep"
DNS_PORT=15353
PROXY_PORT=8443
SRC="$HOME_DIR/src"
BIN_DIR="$HOME_DIR/bin"
GH="https://github.com/$ORG"

ACTION="setup"
while [ $# -gt 0 ]; do
    case "$1" in
        uninstall|--uninstall) ACTION="uninstall"; shift ;;
        --tld)  TLD="$2"; shift 2 ;;
        --peer) PEER="$2"; shift 2 ;;
        --ref)  REF="$2"; shift 2 ;;
        --home) HOME_DIR="$2"; SRC="$HOME_DIR/src"; BIN_DIR="$HOME_DIR/bin"; shift 2 ;;
        -h|--help)
            echo "usage: get.sh [uninstall] [--tld pepe|doge] [--peer host:port]"
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$TLD" in
    pepe) COIN=pep;  PEER="${PEER:-pepenet.shibpost.com:33874}" ;;
    doge) COIN=doge; PEER="${PEER:-pepenet.shibpost.com:22556}" ;;
    *) echo "TLD must be pepe or doge" >&2; exit 2 ;;
esac

os="$(uname -s)"
case "$os" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    MINGW*|MSYS*|CYGWIN*)
        echo "pepenet-tls is POSIX. On Windows install PepeNet desktop:" >&2
        echo "  https://github.com/$ORG/pepenet-desktop/releases" >&2
        exit 1 ;;
    *) echo "unsupported OS: $os" >&2; exit 1 ;;
esac

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

elevate() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    elif have sudo; then
        sudo "$@"
    elif have pkexec; then
        pkexec "$@"
    else
        die "need sudo or pkexec to plant the CA / DNS route"
    fi
}

clone_or_update() {
    local url="$1" dest="$2"
    shift 2
    if [ -d "$dest/.git" ]; then
        log "updating $(basename "$dest")"
        git -C "$dest" fetch --tags origin >/dev/null
        git -C "$dest" checkout "$REF" >/dev/null 2>&1 \
            || git -C "$dest" checkout main >/dev/null 2>&1 \
            || true
        git -C "$dest" pull --ff-only >/dev/null 2>&1 || true
    else
        log "cloning $(basename "$dest") ($REF, falling back to default branch)"
        mkdir -p "$(dirname "$dest")"
        if ! git clone --branch "$REF" "$@" "$url" "$dest" 2>/dev/null; then
            git clone "$@" "$url" "$dest"
        fi
    fi
}

ensure_deps() {
    local missing=()
    have git    || missing+=(git)
    have cc     || missing+=(cc)
    have make   || missing+=(make)
    have cmake  || missing+=(cmake)
    have pkg-config || missing+=(pkg-config)
    if [ "$os" = linux ]; then
        pkg-config --exists openssl 2>/dev/null || missing+=(libssl)
        pkg-config --exists sqlite3 2>/dev/null || missing+=(libsqlite3)
    fi
    [ ${#missing[@]} -eq 0 ] && return 0
    log "missing: ${missing[*]}"
    if [ "$os" = linux ] && have apt-get; then
        elevate apt-get install -y git build-essential cmake pkg-config libssl-dev libsqlite3-dev
    elif [ "$os" = macos ]; then
        have brew || die "install Homebrew, then: brew install git cmake pkg-config openssl@3 sqlite"
        brew install git cmake pkg-config openssl@3 sqlite
    else
        die "install git, a C compiler, cmake, pkg-config, OpenSSL 3, sqlite3 and re-run"
    fi
}

write_linux_units() {
    local unitdir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$unitdir"
    cat > "$unitdir/pepenet-dnsd.service" <<EOF
[Unit]
Description=PepeNet DNS resolver (.$TLD)
After=network-online.target

[Service]
ExecStart=$BIN_DIR/dnsd --db $HOME_DIR/$COIN.db --store $HOME_DIR/dns-$COIN.db --coin $COIN --suffix $TLD --dns-port $DNS_PORT --tls-redirect 127.0.0.1 --peer $PEER
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    cat > "$unitdir/pepenet-tls.service" <<EOF
[Unit]
Description=PepeNet DANE TLS proxy (.$TLD)
After=pepenet-dnsd.service
Wants=pepenet-dnsd.service

[Service]
ExecStart=$BIN_DIR/pepenet-tls --tld $TLD serve --db $HOME_DIR/$COIN.db --store $HOME_DIR/dns-$COIN.db --listen 127.0.0.1 --port $PROXY_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    if ! systemctl --user enable --now pepenet-dnsd.service pepenet-tls.service; then
        log "WARNING: systemd --user could not start the daemons. Run:"
        echo "  $BIN_DIR/dnsd --db $HOME_DIR/$COIN.db --store $HOME_DIR/dns-$COIN.db --coin $COIN --suffix $TLD --dns-port $DNS_PORT --tls-redirect 127.0.0.1 --peer $PEER"
        echo "  $BIN_DIR/pepenet-tls --tld $TLD serve --db $HOME_DIR/$COIN.db --store $HOME_DIR/dns-$COIN.db --listen 127.0.0.1 --port $PROXY_PORT"
    fi
    if have loginctl; then
        elevate loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
    fi
}

write_macos_agents() {
    local dir="$HOME/Library/LaunchAgents"
    mkdir -p "$dir"
    cat > "$dir/com.pepenet.dnsd.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.pepenet.dnsd</string>
  <key>ProgramArguments</key><array>
    <string>$BIN_DIR/dnsd</string>
    <string>--db</string><string>$HOME_DIR/$COIN.db</string>
    <string>--store</string><string>$HOME_DIR/dns-$COIN.db</string>
    <string>--coin</string><string>$COIN</string>
    <string>--suffix</string><string>$TLD</string>
    <string>--dns-port</string><string>$DNS_PORT</string>
    <string>--tls-redirect</string><string>127.0.0.1</string>
    <string>--peer</string><string>$PEER</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME_DIR/dnsd.log</string>
  <key>StandardErrorPath</key><string>$HOME_DIR/dnsd.log</string>
</dict></plist>
EOF
    cat > "$dir/com.pepenet.tls.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.pepenet.tls</string>
  <key>ProgramArguments</key><array>
    <string>$BIN_DIR/pepenet-tls</string>
    <string>--tld</string><string>$TLD</string>
    <string>serve</string>
    <string>--db</string><string>$HOME_DIR/$COIN.db</string>
    <string>--store</string><string>$HOME_DIR/dns-$COIN.db</string>
    <string>--listen</string><string>127.0.0.1</string>
    <string>--port</string><string>$PROXY_PORT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME_DIR/tls.log</string>
  <key>StandardErrorPath</key><string>$HOME_DIR/tls.log</string>
</dict></plist>
EOF
    launchctl bootout "gui/$(id -u)/com.pepenet.dnsd" >/dev/null 2>&1 || true
    launchctl bootout "gui/$(id -u)/com.pepenet.tls" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$dir/com.pepenet.dnsd.plist"
    launchctl bootstrap "gui/$(id -u)" "$dir/com.pepenet.tls.plist"
}

stop_services() {
    if [ "$os" = linux ]; then
        systemctl --user disable --now pepenet-tls.service pepenet-dnsd.service >/dev/null 2>&1 || true
    else
        launchctl bootout "gui/$(id -u)/com.pepenet.tls" >/dev/null 2>&1 || true
        launchctl bootout "gui/$(id -u)/com.pepenet.dnsd" >/dev/null 2>&1 || true
    fi
}

do_uninstall() {
    log "stopping daemons"
    stop_services
    if [ -x "$SRC/pepenet-tls/install.sh" ]; then
        log "removing OS wiring (CA / DNS / redirect)"
        elevate "$SRC/pepenet-tls/install.sh" uninstall "$TLD" || true
    fi
    rm -f "$BIN_DIR/dnsd" "$BIN_DIR/pepenet-tls"
    log "left $HOME_DIR (chain db, zone store, source). rm -rf $HOME_DIR to wipe."
}

do_setup() {
    mkdir -p "$HOME_DIR" "$BIN_DIR" "$SRC"
    ensure_deps

    clone_or_update "$GH/namespace-indexer.git"  "$SRC/namespace-indexer" --recursive
    clone_or_update "$GH/namespace-protocol.git" "$SRC/namespace-protocol"
    clone_or_update "$GH/pepenet-mesh.git"       "$SRC/pepenet-mesh"
    clone_or_update "$GH/pepenet-dns.git"        "$SRC/pepenet-dns"
    clone_or_update "$GH/pepenet-tls.git"        "$SRC/pepenet-tls"

    # glibc + -std=c11 hides mkdtemp/fdopen; the linux branches already pin
    # _DEFAULT_SOURCE, but dns/indexer on main may not. Harmless elsewhere.
    local posix="-std=c11 -D_DEFAULT_SOURCE -O2 -Wall -Wextra"
    log "building mesh (libsecp + libpepenetnet.a)"
    make -C "$SRC/pepenet-mesh" CFLAGS="$posix -Wshadow" -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
    log "building dnsd"
    make -C "$SRC/pepenet-dns" CFLAGS="$posix -Wshadow" dnsd
    log "building pepenet-tls"
    if [ "$os" = macos ]; then
        make -C "$SRC/pepenet-tls" pepenet-tls
    else
        make -C "$SRC/pepenet-tls" CFLAGS="$posix $(pkg-config --cflags openssl)" pepenet-tls
    fi

    cp -f "$SRC/pepenet-dns/dnsd" "$BIN_DIR/dnsd"
    cp -f "$SRC/pepenet-tls/pepenet-tls" "$BIN_DIR/pepenet-tls"
    chmod +x "$BIN_DIR/dnsd" "$BIN_DIR/pepenet-tls"

    log "ensuring the name-constrained .$TLD root"
    "$BIN_DIR/pepenet-tls" --tld "$TLD" gen-ca

    log "starting user services (dnsd + pepenet-tls)"
    if [ "$os" = linux ]; then
        write_linux_units
    else
        write_macos_agents
    fi

    log "planting OS trust / DNS / :443 redirect (sudo/pkexec)"
    elevate "$SRC/pepenet-tls/install.sh" install "$TLD"

    cat <<EOF

.$TLD is live on this box.

  resolver  127.0.0.1:$DNS_PORT
  proxy     127.0.0.1:$PROXY_PORT
  data      $HOME_DIR
  binaries  $BIN_DIR

Open https://<name>.$TLD in a browser (quit+reopen Firefox if you use it).
Uninstall:  curl -fsSL https://raw.githubusercontent.com/$ORG/pepenet-tls/$REF/get.sh | bash -s -- uninstall
EOF
}

if [ "$ACTION" = uninstall ]; then
    do_uninstall
else
    do_setup
fi
