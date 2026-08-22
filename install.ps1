# pepenet-tls Windows entry — irm …/install.ps1 | iex
#
# pepenet-tls is a POSIX daemon (OpenSSL DANE + systemd/launchd). On Windows
# the padlock is the PepeNet desktop app (in-process resolver + proxy, MSI).
#
#   irm https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/install.ps1 | iex

$ErrorActionPreference = "Stop"
$releases = "https://github.com/PepeNetWeb/pepenet-desktop/releases/latest"
Write-Host "pepenet-tls does not ship a Windows daemon."
Write-Host "The one-command padlock on Windows is PepeNet desktop:"
Write-Host "  $releases"
try { Start-Process $releases } catch { }
