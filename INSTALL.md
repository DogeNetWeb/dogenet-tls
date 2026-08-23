# Installing PepeNet web access

Two shapes, one padlock (`https://<name>.pepe` in a stock browser):

| | macOS / Linux | Windows |
|---|---|---|
| **One command** | `get.sh` — builds `dnsd` + `pepenet-tls`, installs **boot daemons**, plants OS trust | `install.ps1` — installs **PepeNet desktop** (MSI), starts it hidden, registers logon autostart |
| **Always on** | systemd system units / LaunchDaemons (survive reboot and logout) | tray-resident desktop at every logon (HKCU Run + scheduled task). No session-less Windows service |
| **Who runs the proxy** | your user, not root (loopback only) | your user (the GUI app) |

`pepenet-tls` is POSIX. Windows does not get `dnsd` / `pepenet-tls` as services; the in-process desktop stack is the padlock there.

Architecture and the NameConstraints threat model: [`DESIGN.md`](DESIGN.md).

These one-liners currently track the **`linux` branch**. After that merges to `main`, switch the URL path from `linux` to `main`.

---

## One command

### macOS and Linux

```sh
curl -fsSL https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/get.sh | bash
```

```sh
# Dogecoin / .doge instead of Pepecoin / .pepe
curl -fsSL https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/get.sh | bash -s -- --tld doge
```

What `get.sh` does:

1. Installs build deps if missing (`apt` / Homebrew).
2. Clones the family into `~/.pepenet/src/` (`namespace-indexer`, `namespace-protocol`, `pepenet-mesh`, `pepenet-dns`, `pepenet-tls`).
3. Builds `dnsd` and `pepenet-tls` into `~/.pepenet/bin/`.
4. Ensures the name-constrained `.$TLD` root CA under `~/.pepenet/`.
5. Installs **boot daemons** (see [Always on](#always-on)).
6. Elevates (`sudo`, or `pkexec` if sudo is missing) and runs `install.sh` to plant OS trust / DNS / `:443` redirect.

First run compiles from source. Later runs `git pull` + rebuild.

### Windows

PowerShell:

```powershell
irm https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/install.ps1 | iex
```

Command Prompt (`cmd.exe`) — `irm` / `iex` are PowerShell cmdlets, so cmd has to call PowerShell:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/install.ps1 | iex"
```

What `install.ps1` does:

1. Downloads the latest `Windows-PepeNet-*.msi` from [pepenet-desktop releases](https://github.com/PepeNetWeb/pepenet-desktop/releases).
2. `msiexec` per-user into `%LOCALAPPDATA%\Programs\PepeNet` (no admin).
3. Starts `pepenet.exe --background` (tray only).
4. Registers logon autostart: HKCU `\...\Run\PepeNet` and a restarting `PepeNet` scheduled task (AtLogOn).

Then open the app and **Enable web access** (DNS & Web tab) — one UAC prompt for the NRPT `.pepe` rule. The MSI does not plant that by itself.

Git-for-Windows `curl | bash` of `get.sh` will refuse and print the PowerShell line.

### Flags and environment (`get.sh`)

| | Default | Meaning |
|---|---|---|
| `--tld pepe\|doge` / `PEPENET_TLD` | `pepe` | one TLD per box |
| `--peer host:port` / `PEPENET_PEER` | `pepenet.shibpost.com:33874` (pep) or `:22556` (doge) | chain peer `dnsd` dials |
| `--ref` / `PEPENET_REF` | `linux` | git branch/tag to clone |
| `--home` / `PEPENET_HOME` | `~/.pepenet` | data, bins, source |
| `PEPENET_ORG` | `PepeNetWeb` | GitHub org |

---

## Uninstall

**macOS / Linux** — stops daemons, removes OS wiring, leaves `~/.pepenet` (chain db, zones, source):

```sh
curl -fsSL https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/get.sh | bash -s -- uninstall
```

Wipe data: `rm -rf ~/.pepenet`.

**Windows** — PowerShell:

```powershell
$env:PEPENET_UNINSTALL='1'; irm https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/install.ps1 | iex
```

Command Prompt:

```bat
set PEPENET_UNINSTALL=1 && powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/install.ps1 | iex"
```

Stops the process, drops Run + the scheduled task, `msiexec /x` the product. `%USERPROFILE%\.pepenet` stays.

---

## Always on

| OS | Mechanism | Survives |
|---|---|---|
| Linux | `/etc/systemd/system/pepenet-dnsd.service` and `pepenet-tls.service`, `User=` the installer, `Restart=always`, `WantedBy=multi-user.target` | reboot, logout, crash |
| macOS | `/Library/LaunchDaemons/com.pepenet.{dnsd,tls}.plist` with `UserName`, `RunAtLoad`, `KeepAlive` | reboot, logout, crash |
| Windows | HKCU Run + Task Scheduler `PepeNet` AtLogOn, `pepenet.exe --background` | logon, crash (3 restarts). Not a session-less service |

Linux/macOS processes still run **as you**. `HOME` is pinned so `~/.pepenet` CA files resolve when launched at boot.

Re-running `get.sh` retires leftover `--user` units / `LaunchAgents` from the first installer so they do not double-launch.

Useful checks:

```sh
# Linux
systemctl status pepenet-dnsd pepenet-tls
journalctl -u pepenet-tls -u pepenet-dnsd -e

# macOS
launchctl print system/com.pepenet.tls
tail -f ~/.pepenet/tls.log ~/.pepenet/dnsd.log
```

---

## What a padlock needs

Three pieces, all of them:

1. **Resolver** answering `*.pepe` on `127.0.0.1:15353`, with `--tls-redirect 127.0.0.1` so DANE names get `A=127.0.0.1`.
2. **DANE proxy** on `127.0.0.1:8443` (loopback `:443` is redirected here, or PAC skips `:443` entirely).
3. **OS trust** — the name-constrained root in the browser/OS store, plus a DNS or PAC path so the browser actually talks to (1)/(2).

`get.sh` starts (1) and (2) as daemons and plants (3).  
Desktop runs (1) and (2) **in-process**; Enable web access plants (3).  
`install.sh` **only** plants (3) and exits.

Ports (loopback):

| Port | Role |
|---|---|
| 15353 | DNS resolver (`dnsd` / desktop). Not 5353 — that is mDNS on macOS |
| 8443 | DANE proxy, unprivileged |
| 8444 | PAC + CONNECT front door (desktop; DoH-proof browser path) |
| 8445 | pf/nft redirect **target** on mac/Linux (never dial this port directly) |
| 443 | browser HTTPS — pf/nft redirect, or Windows binds it directly |
| 53 | Windows NRPT path only (desktop binds it; Unix does not) |

---

## OS wiring (CA / DNS / `:443`)

One TLD per machine. The root CA is NameConstraints-critical: it can only mint `*.pepe` or `*.doge`, never `google.com`.

### macOS — `install.sh`

Run as root. Unprivileged CA step drops to `$SUDO_USER`.

1. `pepenet-tls install-ca` → login keychain (`security add-trusted-cert`). GUI auth **is** consent.
2. `/etc/resolver/<tld>` → `127.0.0.1#15353`.
3. pf rdr `127.0.0.1:443 → :8443` (loopback rdr is flaky; PAC on desktop is the reliable browser path).
4. Firefox `user.js`: `security.enterprise_roots.enabled` (Firefox ignores the keychain otherwise).

### Linux — `install.sh` execs `install-linux.sh`

Elevation: already-root, else **pkexec if present, else sudo** (passwordless-sudo boxes that do not ship pkexec).

1. `install-ca` → `~/.pki/nssdb` via `certutil` if `libnss3-tools` is installed (missing certutil is a no-op).
2. System store: `/usr/local/share/ca-certificates/pepenet-<tld>.crt` + `update-ca-certificates` (Debian/Ubuntu) or `update-ca-trust` (Fedora). Chromium/Firefox-with-enterprise-roots read this via p11-kit.
3. systemd-resolved **split-DNS** on `lo`: `~<tld>` → `127.0.0.1:15353`. Never a global `DNS=` — that would send every name to dnsd.
4. Optional nftables table `pepenet-<tld>`: output-hook redirect `127.0.0.1:443 → :8443`. Best-effort; PAC still works if nft is missing.
5. Firefox `~/.mozilla/firefox/*/user.js` enterprise-roots pref.

Persisted by `get.sh` as `/etc/systemd/system/pepenet-web-<tld>.service` from `install-linux.sh` (resolved + nft at boot). The **proxy daemons** are the separate `pepenet-dnsd` / `pepenet-tls` units.

### Windows — desktop `packaging/install-helper.ps1`

Unprivileged: current-user Root store (Windows’ own warning dialog is consent) + HKCU PAC.  
Privileged (one UAC): NRPT `.<tld>` → `127.0.0.1`. No pf; the app binds `:443` and `:53` directly.

Desktop Enable web access also sets GNOME/KDE PAC on Linux and `networksetup` PAC on mac — primary browser route because DoH skips OS DNS.

### Helpers — do not mix them up

| Script | Tree | Job |
|---|---|---|
| `get.sh` | pepenet-tls | full POSIX install + boot daemons |
| `install.sh` / `install-linux.sh` | pepenet-tls | OS wiring only |
| `install.ps1` | pepenet-tls | Windows → desktop MSI + logon |
| `packaging/install-helper.sh` | pepenet-desktop | macOS privileged half (resolver file, PAC, pf) |
| `packaging/install-helper-linux.sh` | pepenet-desktop | Linux privileged half (system CA, resolved, nft) |
| `packaging/install-helper.ps1` | pepenet-desktop | Windows privileged half (NRPT) |

---

## After install — did it work?

```sh
# daemons (get.sh)
dig @127.0.0.1 -p 15353 pepenet.pepe A
curl -vI https://pepenet.pepe/

# macOS resolver
scutil --dns | grep -A2 pepe

# Linux split-DNS
resolvectl query pepenet.pepe
nft list table ip pepenet-pepe          # :443 rdr, if nft worked
```

Firefox: fully quit and reopen (enterprise-roots are read at startup).  
If the name resolves but the browser “can’t connect” on macOS, pf loopback rdr is the usual culprit — desktop PAC, or run the proxy on `:443` as root (see `install.sh` notes).

---

## Build from a checkout (no one-liner)

`make test` is hermetic (OpenSSL 3 + this tree). Ubuntu 24.04:

```sh
sudo apt install build-essential pkg-config libssl-dev libsqlite3-dev
make test
```

glibc + `-std=c11` hides `mkdtemp` / `setenv` / `fdopen`. The Makefile passes `-D_DEFAULT_SOURCE`. Same footgun is fixed in pepenet-mesh.

macOS: Homebrew `openssl@3` (Makefile pins `/opt/homebrew/opt/openssl@3`). System LibreSSL has no `SSL_dane_*`.

`make pepenet-tls` (the serve binary) also needs pepenet-dns, pepenet-mesh, and namespace-indexer. A lone `git clone pepenet-tls` cannot link it.

- **Siblings:** `pepenet-tls/` next to `pepenet-dns/`, `pepenet-mesh/`, `namespace-indexer/` (and `namespace-protocol/` for `make -C ../pepenet-mesh`).
- **Desktop embed:** this Makefile lives at `pepenet-desktop/tls/` after `git submodule update --init --recursive`. It detects `../dns`, `../mesh`, `../indexer`.

Override: `make DNS=/path IDX=/path NET=/path pepenet-tls`.

`libnss3-tools` (`certutil`) is optional.

OS wiring from a checkout (daemons **not** started):

```sh
sudo ./install.sh install pepe     # or doge
sudo ./install.sh uninstall pepe
```

Serve by hand:

```sh
dnsd --db ~/.pepenet/pep.db --store ~/.pepenet/dns-pep.db \
     --coin pep --suffix pepe --dns-port 15353 \
     --tls-redirect 127.0.0.1 --peer pepenet.shibpost.com:33874
./pepenet-tls --tld pepe serve --db ~/.pepenet/pep.db --store ~/.pepenet/dns-pep.db
```

---

## GUI client (wallet, Discover, Enable web access)

[pepenet-desktop](https://github.com/PepeNetWeb/pepenet-desktop) embeds the same dns/tls stack in-process. That is the right one-command shape when you want a wallet, not just a padlock daemon.

Build and packaging: [pepenet-desktop/INSTALL.md](https://github.com/PepeNetWeb/pepenet-desktop/blob/linux/INSTALL.md).
