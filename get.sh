#!/bin/bash
#
# dogenet-tls installer — one command, macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/DogeNetWeb/dogenet-tls/main/get.sh | bash
#   curl -fsSL .../get.sh | bash -s -- --tld pepe
#   curl -fsSL .../get.sh | bash -s -- uninstall
#
# Clones the family, builds dnsd + dogenet-tls, installs them as boot
# daemons (systemd system units / LaunchDaemons — survive reboot and
# logout), then elevates to plant the CA / split-DNS / :443 redirect.
# install.sh by itself only does the OS half.
#
# Env: DOGENET_HOME (default ~/.dogenet), DOGENET_REF (default main),
#      DOGENET_TLD (default doge), DOGENET_PEER (comma-separated host:port;
#      doge default dogenet.shibpost.com:22556)
#
# Windows: install.ps1 (irm … | iex) — dogenet-tls is POSIX; the padlock
# there is dogenet-desktop.

set -euo pipefail

ORG="${DOGENET_ORG:-DogeNetWeb}"
REF="${DOGENET_REF:-main}"
HOME_DIR="${DOGENET_HOME:-$HOME/.dogenet}"
TLD="${DOGENET_TLD:-doge}"
PEER="${DOGENET_PEER:-}"
COIN="doge"
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
    pepe) COIN=pep;  PEER="${PEER:-dogenet.shibpost.com:33874,net.pepecoin.services:33874}" ;;
    doge) COIN=doge; PEER="${PEER:-dogenet.shibpost.com:22556}" ;;
    *) echo "TLD must be pepe or doge" >&2; exit 2 ;;
esac

os="$(uname -s)"
case "$os" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    MINGW*|MSYS*|CYGWIN*)
        echo "dogenet-tls is POSIX. On Windows:" >&2
        echo "  PowerShell:  irm https://raw.githubusercontent.com/$ORG/dogenet-tls/$REF/install.ps1 | iex" >&2
        echo "  cmd.exe:     powershell -NoProfile -ExecutionPolicy Bypass -Command \"irm https://raw.githubusercontent.com/$ORG/dogenet-tls/$REF/install.ps1 | iex\"" >&2
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
        elevate apt-get install -y git build-essential cmake pkg-config libssl-dev libsqlite3-dev libnss3-tools
    elif [ "$os" = macos ]; then
        have brew || die "install Homebrew, then: brew install git cmake pkg-config openssl@3 sqlite"
        brew install git cmake pkg-config openssl@3 sqlite
    else
        die "install git, a C compiler, cmake, pkg-config, OpenSSL 3, sqlite3 and re-run"
    fi
}

# Boot daemons, not login agents: they come up at startup without a
# session, keep running after logout, and restart if they die. The
# process still runs as the installing user (the proxy is loopback-only
# and must not be root). HOME is pinned so ~/.dogenet CA files resolve.
install_file() {
    local src="$1" dest="$2"
    elevate cp "$src" "$dest"
    elevate chmod 644 "$dest"
}

write_linux_units() {
    local user gid tmp flags="" p
    user="$(id -un)"
    gid="$(id -gn)"
    tmp="$(mktemp -d)"
    local IFS=,
    for p in $PEER; do
        [ -n "$p" ] || continue
        flags="$flags --peer $p"
    done
    unset IFS
    cat > "$tmp/dogenet-dnsd.service" <<EOF
[Unit]
Description=DogeNet DNS resolver (.$TLD)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$user
Group=$gid
Environment=HOME=$HOME
WorkingDirectory=$HOME_DIR
ExecStart=$BIN_DIR/dnsd --db $HOME_DIR/$COIN.db --store $HOME_DIR/dns-$COIN.db --coin $COIN --suffix $TLD --dns-port $DNS_PORT --tls-redirect 127.0.0.1$flags
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    cat > "$tmp/dogenet-tls.service" <<EOF
[Unit]
Description=DogeNet DANE TLS proxy (.$TLD)
After=network-online.target dogenet-dnsd.service
Wants=network-online.target dogenet-dnsd.service

[Service]
Type=simple
User=$user
Group=$gid
Environment=HOME=$HOME
WorkingDirectory=$HOME_DIR
ExecStart=$BIN_DIR/dogenet-tls --tld $TLD serve --db $HOME_DIR/$COIN.db --store $HOME_DIR/dns-$COIN.db --listen 127.0.0.1 --port $PROXY_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    # drop a leftover user-unit from the first installer, if any
    systemctl --user disable --now dogenet-tls.service dogenet-dnsd.service >/dev/null 2>&1 || true
    install_file "$tmp/dogenet-dnsd.service" /etc/systemd/system/dogenet-dnsd.service
    install_file "$tmp/dogenet-tls.service"  /etc/systemd/system/dogenet-tls.service
    rm -rf "$tmp"
    elevate systemctl daemon-reload
    elevate systemctl enable --now dogenet-dnsd.service dogenet-tls.service
}

macos_plist() {
    local label="$1" log="$2"
    shift 2
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>UserName</key><string>$(id -un)</string>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>WorkingDirectory</key><string>$HOME_DIR</string>
  <key>ProgramArguments</key><array>
$(for a in "$@"; do printf '    <string>%s</string>\n' "$a"; done)
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict></plist>
EOF
}

write_macos_agents() {
    local tmp="$HOME_DIR" p
    mkdir -p "$tmp"
    local dnsd_args=( "$BIN_DIR/dnsd" --db "$HOME_DIR/$COIN.db" --store "$HOME_DIR/dns-$COIN.db"
                      --coin "$COIN" --suffix "$TLD" --dns-port "$DNS_PORT"
                      --tls-redirect 127.0.0.1 )
    local IFS=,
    for p in $PEER; do
        [ -n "$p" ] || continue
        dnsd_args+=( --peer "$p" )
    done
    unset IFS
    macos_plist com.dogenet.dnsd "$HOME_DIR/dnsd.log" \
        "${dnsd_args[@]}" \
        > "$tmp/com.dogenet.dnsd.plist"
    macos_plist com.dogenet.tls "$HOME_DIR/tls.log" \
        "$BIN_DIR/dogenet-tls" --tld "$TLD" serve \
        --db "$HOME_DIR/$COIN.db" --store "$HOME_DIR/dns-$COIN.db" \
        --listen 127.0.0.1 --port "$PROXY_PORT" \
        > "$tmp/com.dogenet.tls.plist"
    # retire the login-only LaunchAgents from the first installer
    launchctl bootout "gui/$(id -u)/com.dogenet.dnsd" >/dev/null 2>&1 || true
    launchctl bootout "gui/$(id -u)/com.dogenet.tls" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/LaunchAgents/com.dogenet.dnsd.plist" \
          "$HOME/Library/LaunchAgents/com.dogenet.tls.plist"
    install_file "$tmp/com.dogenet.dnsd.plist" /Library/LaunchDaemons/com.dogenet.dnsd.plist
    install_file "$tmp/com.dogenet.tls.plist"  /Library/LaunchDaemons/com.dogenet.tls.plist
    elevate launchctl bootout system/com.dogenet.dnsd >/dev/null 2>&1 || true
    elevate launchctl bootout system/com.dogenet.tls >/dev/null 2>&1 || true
    elevate launchctl bootstrap system /Library/LaunchDaemons/com.dogenet.dnsd.plist
    elevate launchctl bootstrap system /Library/LaunchDaemons/com.dogenet.tls.plist
}

stop_services() {
    if [ "$os" = linux ]; then
        elevate systemctl disable --now dogenet-tls.service dogenet-dnsd.service >/dev/null 2>&1 || true
        elevate rm -f /etc/systemd/system/dogenet-tls.service /etc/systemd/system/dogenet-dnsd.service
        elevate systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl --user disable --now dogenet-tls.service dogenet-dnsd.service >/dev/null 2>&1 || true
    else
        elevate launchctl bootout system/com.dogenet.tls >/dev/null 2>&1 || true
        elevate launchctl bootout system/com.dogenet.dnsd >/dev/null 2>&1 || true
        elevate rm -f /Library/LaunchDaemons/com.dogenet.tls.plist \
                      /Library/LaunchDaemons/com.dogenet.dnsd.plist
        launchctl bootout "gui/$(id -u)/com.dogenet.tls" >/dev/null 2>&1 || true
        launchctl bootout "gui/$(id -u)/com.dogenet.dnsd" >/dev/null 2>&1 || true
        rm -f "$HOME/Library/LaunchAgents/com.dogenet.tls.plist" \
              "$HOME/Library/LaunchAgents/com.dogenet.dnsd.plist"
    fi
}

do_uninstall() {
    log "stopping daemons"
    stop_services
    if [ -x "$SRC/dogenet-tls/install.sh" ]; then
        log "removing OS wiring (CA / DNS / redirect)"
        elevate "$SRC/dogenet-tls/install.sh" uninstall "$TLD" || true
    fi
    rm -f "$BIN_DIR/dnsd" "$BIN_DIR/dogenet-tls"
    log "left $HOME_DIR (chain db, zone store, source). rm -rf $HOME_DIR to wipe."
}

do_setup() {
    mkdir -p "$HOME_DIR" "$BIN_DIR" "$SRC"
    ensure_deps

    clone_or_update "$GH/namespace-indexer.git"  "$SRC/namespace-indexer" --recursive
    clone_or_update "$GH/namespace-protocol.git" "$SRC/namespace-protocol"
    clone_or_update "$GH/dogenet-mesh.git"       "$SRC/dogenet-mesh"
    clone_or_update "$GH/dogenet-dns.git"        "$SRC/dogenet-dns"
    clone_or_update "$GH/dogenet-tls.git"        "$SRC/dogenet-tls"

    # glibc + -std=c11 hides mkdtemp/fdopen; mesh pins _DEFAULT_SOURCE.
    # Harmless elsewhere.
    local posix="-std=c11 -D_DEFAULT_SOURCE -O2 -Wall -Wextra"
    log "building mesh (libsecp + libdogenetnet.a)"
    make -C "$SRC/dogenet-mesh" CFLAGS="$posix -Wshadow" -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
    log "building dnsd"
    make -C "$SRC/dogenet-dns" CFLAGS="$posix -Wshadow" dnsd
    log "building dogenet-tls"
    if [ "$os" = macos ]; then
        make -C "$SRC/dogenet-tls" dogenet-tls
    else
        make -C "$SRC/dogenet-tls" CFLAGS="$posix $(pkg-config --cflags openssl)" dogenet-tls
    fi

    cp -f "$SRC/dogenet-dns/dnsd" "$BIN_DIR/dnsd"
    cp -f "$SRC/dogenet-tls/dogenet-tls" "$BIN_DIR/dogenet-tls"
    chmod +x "$BIN_DIR/dnsd" "$BIN_DIR/dogenet-tls"

    log "ensuring the name-constrained .$TLD root"
    "$BIN_DIR/dogenet-tls" --tld "$TLD" gen-ca

    log "installing boot daemons (dnsd + dogenet-tls — Restart=always, survive reboot)"
    if [ "$os" = linux ]; then
        write_linux_units
    else
        write_macos_agents
    fi

    log "planting OS trust / DNS / :443 redirect (sudo/pkexec)"
    elevate "$SRC/dogenet-tls/install.sh" install "$TLD"

    cat <<EOF

.$TLD is live on this box.

  resolver  127.0.0.1:$DNS_PORT
  proxy     127.0.0.1:$PROXY_PORT
  data      $HOME_DIR
  binaries  $BIN_DIR

Open https://<name>.$TLD in a browser (quit+reopen Firefox if you use it).
Uninstall:  curl -fsSL https://raw.githubusercontent.com/$ORG/dogenet-tls/$REF/get.sh | bash -s -- uninstall
EOF
}

if [ "$ACTION" = uninstall ]; then
    do_uninstall
else
    do_setup
fi
