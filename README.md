# pepenet-tls

DANE-aware local TLS proxy for PepeNet. Name-constrained root CA + DANE
origin check + a loopback proxy so `https://foo.pepe` shows a padlock.
Architecture and the security model: [`DESIGN.md`](DESIGN.md).

## Install (one command)

Clones the family, builds `dnsd` + `pepenet-tls`, installs them as **boot
daemons** (systemd system units / LaunchDaemons — they come back after
reboot and stay up if they crash), then plants the CA / split-DNS /
`:443` redirect. The process still runs as you, not root.

**macOS / Linux**

```sh
curl -fsSL https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/get.sh | bash
```

```sh
# doge instead of pepe
curl -fsSL https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/get.sh | bash -s -- --tld doge

# undo (stops daemons, removes OS wiring; keeps ~/.pepenet data)
curl -fsSL https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/get.sh | bash -s -- uninstall
```

**Windows**

pepenet-tls is POSIX (no Windows service). The padlock is PepeNet
desktop — same in-process resolver + proxy, tray-resident. The
one-liner downloads the latest MSI, installs per-user, starts it
hidden, and registers it at every logon:

```powershell
irm https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/install.ps1 | iex
```

```powershell
# undo
$env:PEPENET_UNINSTALL='1'; irm https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/install.ps1 | iex
```

Then **Enable web access** in the app (one UAC prompt for the NRPT
rule). Quit leaves the wiring planted; the tray is the always-on
shape — there is no session-less Windows service.

`get.sh` defaults to the `linux` branch (OpenSSL/glibc/sudo work) and
`~/.pepenet`. Override with `PEPENET_REF`, `PEPENET_HOME`, `PEPENET_TLD`,
`PEPENET_PEER`.

## Build

Needs **OpenSSL 3** (DANE: `SSL_dane_*`). LibreSSL does not work.

`make test` is hermetic: OpenSSL + this tree. Ubuntu 24.04:

```sh
sudo apt install build-essential pkg-config libssl-dev libsqlite3-dev
make test
```

macOS: Homebrew `openssl@3` (the Makefile pins `/opt/homebrew/opt/openssl@3`).

`make pepenet-tls` (the serve binary) **also** needs pepenet-dns, pepenet-mesh,
and namespace-indexer. A lone `git clone pepenet-tls` cannot link it. Either:

- clone the family as **siblings** (`pepenet-tls/` next to `pepenet-dns/`,
  `pepenet-mesh/`, `namespace-indexer/`), or
- build from **pepenet-desktop/tls/** after `git submodule update --init
  --recursive` — the Makefile detects `../dns`, `../mesh`, `../indexer`.

Override with `make DNS=/path IDX=/path NET=/path pepenet-tls`.

`libnss3-tools` (`certutil`) is optional: without it, `install-ca` is a
no-op on the user NSS db and the privileged installer still plants the
system store.

## Install (OS wiring only)

`install.sh` plants the CA and (when present) split-DNS / a `:443`
redirect, then **exits**. It never starts `dnsd` or `pepenet-tls serve`.
A padlock still needs those two processes running.

The one-command shape is **pepenet-desktop**: Enable web access runs the
resolver and proxy in-process, then elevates (pkexec, or sudo if pkexec
is missing) to plant the same OS wiring.

Standalone, after `make pepenet-tls`:

```sh
sudo ./install.sh install pepe          # or doge — OS only
# dnsd --tls-redirect 127.0.0.1 --suffix pepe --dns-port 15353
# ./pepenet-tls --tld pepe serve --db <indexer.db> --store <carrier.db>
sudo ./install.sh uninstall pepe
```

Linux: system CA store + systemd-resolved split-DNS (`*.pepe` only) +
optional nftables `:443 → :8443`. See `install-linux.sh`.

