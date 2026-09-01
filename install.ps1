# dogenet-tls Windows one-liner — irm …/install.ps1 | iex
#
# Headless padlock: installs dogenet-web.exe as a Windows Service (boot,
# LocalSystem, auto-restart), plants the name-constrained CA + NRPT + PAC.
# That is the systemd/LaunchDaemon analogue — not the GUI.
#
#   irm https://raw.githubusercontent.com/DogeNetWeb/dogenet-tls/main/install.ps1 | iex
#   $env:DOGENET_UNINSTALL='1'; irm …/install.ps1 | iex
#
# Command Prompt (cmd.exe) — irm/iex are PowerShell:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/DogeNetWeb/dogenet-tls/main/install.ps1 | iex"
#   set DOGENET_UNINSTALL=1 && powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/DogeNetWeb/dogenet-tls/main/install.ps1 | iex"
#
# dogenet-web.exe must be in the latest desktop MSI (0.2.0 GUI-only is not
# enough) or set DOGENET_WEB_EXE to a built copy.

$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$Owner   = "DogeNetWeb"
$Repo    = "dogenet-desktop"
$SvcName = "DogeNetWeb"
$Tld     = "doge"
$PacUrl  = "http://127.0.0.1:8444/proxy.pac"
$BinDir  = Join-Path $env:ProgramData "DogeNet\bin"
$DataDir = Join-Path $env:ProgramData "DogeNet\.dogenet"
$MsiExe  = Join-Path $env:LOCALAPPDATA "Programs\DogeNet\dogenet-web.exe"

function Write-Step($msg) { Write-Host "==> $msg" }

function Test-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (Test-Admin) { return }
    Write-Step "relaunching elevated (service + NRPT need admin)"
    $cmd = "irm https://raw.githubusercontent.com/$Owner/dogenet-tls/main/install.ps1 | iex"
    if ($env:DOGENET_UNINSTALL -eq "1") { $cmd = "`$env:DOGENET_UNINSTALL='1'; $cmd" }
    if ($env:DOGENET_WEB_EXE) { $cmd = "`$env:DOGENET_WEB_EXE='$($env:DOGENET_WEB_EXE)'; $cmd" }
    Start-Process powershell.exe -Verb RunAs -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $cmd)
    exit 0
}

function Get-Helper {
    $local = @(
        (Join-Path $BinDir "install-helper.ps1"),
        (Join-Path (Split-Path $MsiExe -Parent) "resources\install-helper.ps1")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($local) { return $local }
    $out = Join-Path $env:TEMP "dogenet-install-helper.ps1"
    Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$Owner/dogenet-desktop/main/packaging/install-helper.ps1" -OutFile $out
    return $out
}

function Install-OsWiring([string]$cert) {
    if (Test-Path $cert) {
        Write-Step "trusting the .$Tld root in the current-user store"
        & certutil -user -addstore -f Root $cert | Out-Null
    } else {
        Write-Warning "CA file not ready yet ($cert) — start the service, then re-run or Enable web access later"
    }
    Write-Step "PAC $PacUrl (HKCU)"
    $inet = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $cur = (Get-ItemProperty $inet -Name AutoConfigURL -ErrorAction SilentlyContinue).AutoConfigURL
    if ($cur -and $cur -ne $PacUrl) {
        Write-Host "  AutoConfigURL is foreign ($cur) — leaving it"
    } else {
        New-Item -Path $inet -Force | Out-Null
        Set-ItemProperty -Path $inet -Name AutoConfigURL -Value $PacUrl
    }
    $helper = Get-Helper
    Write-Step "NRPT .$Tld -> 127.0.0.1 (elevated helper)"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -Action install -Tld $Tld
}

function Uninstall-OsWiring {
    $helper = Get-Helper
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -Action uninstall -Tld $Tld
    $inet = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $cur = (Get-ItemProperty $inet -Name AutoConfigURL -ErrorAction SilentlyContinue).AutoConfigURL
    if ($cur -eq $PacUrl) { Remove-ItemProperty -Path $inet -Name AutoConfigURL -ErrorAction SilentlyContinue }
}

function Get-WebExeFromRelease {
    Write-Step "fetching latest $Owner/$Repo Windows build"
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/releases/latest" -Headers @{ "User-Agent" = "dogenet-web-installer" }
    $zip = $rel.assets | Where-Object { $_.name -match '(?i)dogenet-web.*\.(zip|exe)$' } | Select-Object -First 1
    if ($zip) {
        $path = Join-Path $env:TEMP $zip.name
        Invoke-WebRequest -UseBasicParsing -Uri $zip.browser_download_url -OutFile $path
        if ($path -like "*.zip") {
            $dest = Join-Path $env:TEMP "dogenet-web-unpack"
            if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
            Expand-Archive $path $dest
            return Get-ChildItem $dest -Recurse -Filter dogenet-web.exe | Select-Object -First 1 -ExpandProperty FullName
        }
        return $path
    }
    $msi = $rel.assets | Where-Object { $_.name -match '(?i)windows.*\.msi$' } | Select-Object -First 1
    if (-not $msi) { throw "no Windows MSI or dogenet-web asset on $($rel.html_url)" }
    $msiPath = Join-Path $env:TEMP $msi.name
    Write-Step "downloading $($msi.name) (need dogenet-web.exe inside)"
    Invoke-WebRequest -UseBasicParsing -Uri $msi.browser_download_url -OutFile $msiPath
    Write-Step "installing per-user MSI (vehicle for dogenet-web.exe)"
    $p = Start-Process msiexec.exe -ArgumentList @("/i", "`"$msiPath`"", "/qn", "/norestart") -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "msiexec /i exited $($p.ExitCode)" }
    if (-not (Test-Path $MsiExe)) {
        throw @"
this release's MSI has no dogenet-web.exe (GUI-only).
Build dogenet-desktop:
  cmake --build build-win --target dogenet-web
then: `$env:DOGENET_WEB_EXE='C:\path\dogenet-web.exe'; irm … | iex
"@
    }
    return $MsiExe
}

function Uninstall-Dogenet {
    Assert-Admin
    Write-Step "stopping service $SvcName"
    if (Get-Service -Name $SvcName -ErrorAction SilentlyContinue) {
        Stop-Service -Name $SvcName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        & sc.exe delete $SvcName | Out-Null
    }
    Uninstall-OsWiring
    Write-Host "left $DataDir (chain db). binaries in $BinDir."
}

function Install-Dogenet {
    Assert-Admin
    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    $src = $env:DOGENET_WEB_EXE
    if (-not $src -or -not (Test-Path $src)) { $src = Get-WebExeFromRelease }
    Write-Step "installing $src -> $BinDir"
    Copy-Item -Force $src (Join-Path $BinDir "dogenet-web.exe")
    $helperSrc = Join-Path (Split-Path $src) "install-helper.ps1"
    if (Test-Path $helperSrc) { Copy-Item -Force $helperSrc (Join-Path $BinDir "install-helper.ps1") }
    $exe = Join-Path $BinDir "dogenet-web.exe"

    Write-Step "Windows Service $SvcName (Automatic, LocalSystem, restart on fail)"
    if (Get-Service -Name $SvcName -ErrorAction SilentlyContinue) {
        Stop-Service $SvcName -Force -ErrorAction SilentlyContinue
        & sc.exe delete $SvcName | Out-Null
        Start-Sleep -Seconds 1
    }
    New-Service -Name $SvcName -DisplayName "DogeNet web (DNS + DANE proxy)" `
        -BinaryPathName "`"$exe`"" -StartupType Automatic | Out-Null
    & sc.exe failure $SvcName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    & sc.exe config $SvcName start= delayed-auto | Out-Null
    Start-Service $SvcName

    $cert = Join-Path $DataDir "dogenet-root-$Tld.crt"
    Write-Step "waiting for CA $cert"
    $ok = $false
    foreach ($i in 1..20) {
        if (Test-Path $cert) { $ok = $true; break }
        Start-Sleep -Seconds 1
    }
    Install-OsWiring $cert
    if (-not $ok) { Write-Warning "service is up but CA not on disk yet — check: Get-Service $SvcName" }

    Write-Host ""
    Write-Host "DogeNet web is a boot service ($SvcName)."
    Write-Host "  $exe"
    Write-Host "  data $DataDir"
    Write-Host "Uninstall: `$env:DOGENET_UNINSTALL='1'; irm https://raw.githubusercontent.com/DogeNetWeb/dogenet-tls/main/install.ps1 | iex"
}

if ($env:DOGENET_UNINSTALL -eq "1") { Uninstall-Dogenet } else { Install-Dogenet }
