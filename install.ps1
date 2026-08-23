# pepenet-tls Windows one-liner — irm …/install.ps1 | iex
#
# pepenet-tls is POSIX (systemd / LaunchDaemons). On Windows the padlock is
# PepeNet desktop: in-process resolver + DANE proxy, tray-resident. This
# script downloads the latest MSI, installs per-user (no admin), starts it
# hidden, and registers it to come back at every logon (HKCU Run + a
# restarting scheduled task).
#
#   irm https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/install.ps1 | iex
#   $env:PEPENET_UNINSTALL='1'; irm …/install.ps1 | iex
#
# Command Prompt (cmd.exe) — irm/iex are PowerShell:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/install.ps1 | iex"
#   set PEPENET_UNINSTALL=1 && powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/install.ps1 | iex"

$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$Owner = "PepeNetWeb"
$Repo  = "pepenet-desktop"
$Task  = "PepeNet"
$RunName = "PepeNet"
$ExeDefault = Join-Path $env:LOCALAPPDATA "Programs\PepeNet\pepenet.exe"

function Write-Step($msg) { Write-Host "==> $msg" }

function Get-PepenetExe {
    $fromReg = (Get-ItemProperty -Path "HKCU:\Software\PepeNet\Install" -Name exe -ErrorAction SilentlyContinue).exe
    if ($fromReg -and (Test-Path -LiteralPath $fromReg)) { return $fromReg }
    if (Test-Path -LiteralPath $ExeDefault) { return $ExeDefault }
    return $null
}

function Unregister-Startup {
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name $RunName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue
}

function Register-Startup([string]$exe) {
    $cmd = "`"$exe`" --background"
    New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Force | Out-Null
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name $RunName -Value $cmd

    # At-logon task with restart-on-failure — HKCU Run is the usual path;
    # the task is the always-on belt (sleep/hibernate, crash).
    Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue
    $action  = New-ScheduledTaskAction -Execute $exe -Argument "--background"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $Task -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
}

function Uninstall-Pepenet {
    Write-Step "stopping PepeNet"
    Get-Process -Name pepenet -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Unregister-Startup

    $uninst = @()
    $uninst += Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue
    $uninst += Get-ChildItem "HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue
    $hit = $uninst | ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
        Where-Object { $_.DisplayName -like "PepeNet*" } | Select-Object -First 1
    if ($hit -and $hit.PSChildName) {
        Write-Step "uninstalling MSI"
        $p = Start-Process msiexec.exe -ArgumentList @("/x", $hit.PSChildName, "/qn", "/norestart") -Wait -PassThru
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
            Write-Warning "msiexec /x exited $($p.ExitCode)"
        }
    } else {
        Write-Host "no PepeNet MSI product found (startup entries already cleared)"
    }
    Write-Host "done. %USERPROFILE%\.pepenet left in place."
}

function Install-Pepenet {
    Write-Step "fetching latest $Owner/$Repo Windows MSI"
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/releases/latest" -Headers @{ "User-Agent" = "pepenet-tls-installer" }
    $asset = $rel.assets | Where-Object { $_.name -match '(?i)windows.*\.msi$' } | Select-Object -First 1
    if (-not $asset) { throw "no Windows MSI on $($rel.html_url) — a desktop release has to ship one" }
    $msi = Join-Path $env:TEMP $asset.name
    Write-Step "downloading $($asset.name) ($([math]::Round($asset.size/1MB, 1)) MB)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msi -UseBasicParsing

    Write-Step "installing per-user (no admin)"
    $p = Start-Process msiexec.exe -ArgumentList @("/i", "`"$msi`"", "/qn", "/norestart") -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw "msiexec /i exited $($p.ExitCode)"
    }

    $exe = Get-PepenetExe
    if (-not $exe) { throw "pepenet.exe not found after MSI (expected $ExeDefault)" }

    Write-Step "registering logon autostart (tray --background)"
    Register-Startup $exe

    Write-Step "starting now"
    Get-Process -Name pepenet -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath $exe -ArgumentList "--background"

    Write-Host ""
    Write-Host "PepeNet $($rel.tag_name) is installed and set to start at logon."
    Write-Host "  $exe --background"
    Write-Host "Enable web access in the app (DNS & Web) for the .pepe padlock."
    Write-Host "Uninstall: `$env:PEPENET_UNINSTALL='1'; irm https://raw.githubusercontent.com/PepeNetWeb/pepenet-tls/linux/install.ps1 | iex"
}

if ($env:PEPENET_UNINSTALL -eq "1") { Uninstall-Pepenet } else { Install-Pepenet }
