# dogenet-tls

DANE-aware local TLS proxy for DogeNet. Name-constrained root CA + DANE
origin check + a loopback proxy so `https://foo.doge` shows a padlock.
Architecture and the security model: [`DESIGN.md`](DESIGN.md).

**Install, uninstall, boot daemons, OS wiring, and build:**
[`INSTALL.md`](INSTALL.md).

```sh
# macOS / Linux — padlock daemons at boot
curl -fsSL https://raw.githubusercontent.com/DogeNetWeb/dogenet-tls/main/get.sh | bash
```

```powershell
# Windows PowerShell — dogenet-web Windows Service (headless padlock)
irm https://raw.githubusercontent.com/DogeNetWeb/dogenet-tls/main/install.ps1 | iex
```

```bat
:: Windows Command Prompt
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/DogeNetWeb/dogenet-tls/main/install.ps1 | iex"
```

