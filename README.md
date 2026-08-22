# pepenet-tls

DANE-aware local TLS proxy for PepeNet. Name-constrained root CA + DANE
origin check + a loopback proxy so `https://foo.pepe` shows a padlock.
Architecture and the security model: [`DESIGN.md`](DESIGN.md).

## Build

Needs **OpenSSL 3** (DANE: `SSL_dane_*`). LibreSSL does not work.

### macOS

Homebrew `openssl@3` (the Makefile pins `/opt/homebrew/opt/openssl@3`):

```sh
make test
```

### Linux (Ubuntu 24.04)

```sh
sudo apt install build-essential pkg-config libssl-dev libsqlite3-dev
make test
```

`libnss3-tools` (`certutil`) is optional: without it, `install-ca` is a
no-op on the user NSS db and the privileged installer still plants the
system store.

## Install (browser padlock)

One TLD per box. The script is privileged; it does not start the daemons.

```sh
make pepenet-tls
sudo ./install.sh install pepe          # or doge
# dnsd --tls-redirect 127.0.0.1 --suffix pepe --dns-port 15353
# ./pepenet-tls --tld pepe serve --db <indexer.db> --store <carrier.db>
sudo ./install.sh uninstall pepe
```

Linux specifics: system CA store + systemd-resolved split-DNS (`*.pepe` only)
+ optional nftables `:443 → :8443`. See `install-linux.sh`.

