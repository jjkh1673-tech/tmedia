#Requires -Version 5.1
<#
.SYNOPSIS
    Install tmedia on Windows (per-user, no administrator rights required).

.DESCRIPTION
    Creates %LOCALAPPDATA%\tmedia\{venv,tmedia.py,tmedia.cmd}, installs
    Telethon / rich / cryptg into an isolated venv, and adds the folder to the
    user PATH so `tmedia` works from any terminal.

    Windows has no zenity and no os.pwrite: tmedia automatically uses the
    terminal file-picker fallback and Telethon's download_media() path.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\assets\setup_windows.ps1
    powershell -ExecutionPolicy Bypass -File .\assets\setup_windows.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$Source = (Join-Path $PSScriptRoot '..\src\tmedia.py')
)

$ErrorActionPreference = 'Stop'
$AppDir   = Join-Path $env:LOCALAPPDATA 'tmedia'
$VenvDir  = Join-Path $AppDir 'venv'
$PythonExe = Join-Path $VenvDir 'Scripts\python.exe'
$AppPy    = Join-Path $AppDir 'tmedia.py'
$Launcher = Join-Path $AppDir 'tmedia.cmd'

function Write-Step([string]$Message) { Write-Host "`n[+] $Message" -ForegroundColor Cyan }
function Stop-WithError([string]$Message) {
    Write-Host "`n[!] $Message" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- uninstall
if ($Uninstall) {
    Write-Step 'Uninstalling tmedia ...'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) {
        $kept = $userPath -split ';' | Where-Object { $_ -and ($_ -ne $AppDir) }
        [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
    }
    if (Test-Path -LiteralPath $AppDir) {
        Remove-Item -LiteralPath $AppDir -Recurse -Force
    }
    Write-Host '[+] Removed. Restart your terminal.' -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------- python
$pythonCmd = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $pythonCmd) { $pythonCmd = (Get-Command python3 -ErrorAction SilentlyContinue).Source }
if (-not $pythonCmd) {
    Stop-WithError 'Python 3.8+ not found. Install from https://www.python.org/downloads/ and tick "Add python.exe to PATH".'
}

Write-Step 'Checking Python version ...'
$versionText = (& $pythonCmd -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $versionText) { Stop-WithError 'Could not determine the Python version.' }
if ([version]($versionText.Trim()) -lt [version]'3.8') {
    Stop-WithError "Python 3.8+ required (found $versionText)."
}
Write-Host "    Python $versionText at $pythonCmd"

# ---------------------------------------------------------------- venv
Write-Step "Configuring virtual environment at $VenvDir ..."
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if (Test-Path -LiteralPath $PythonExe) {
    Write-Host '    existing venv reused (idempotent)'
} else {
    & $pythonCmd -m venv $VenvDir
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $PythonExe)) {
        Stop-WithError 'python -m venv failed. Make sure the "venv" component was installed with Python.'
    }
}

# ---------------------------------------------------------------- deps
Write-Step 'Installing Python dependencies (Telethon, rich, cryptg) ...'
& $PythonExe -m pip install --quiet --no-input --disable-pip-version-check "Telethon>=1.36,<2" "rich>=13,<15"
if ($LASTEXITCODE -ne 0) { Stop-WithError 'Could not install Telethon / rich (check your network).' }
& $PythonExe -m pip install --quiet --no-input --disable-pip-version-check "cryptg>=0.4"
if ($LASTEXITCODE -ne 0) {
    Write-Host '    [i] cryptg wheel unavailable (optional accelerator) - continuing' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- source
Write-Step 'Installing tmedia source ...'
try { $resolved = (Resolve-Path -LiteralPath $Source -ErrorAction Stop).Path }
catch { Stop-WithError "Cannot find src/tmedia.py (looked at: $Source)." }
Copy-Item -LiteralPath $resolved -Destination $AppPy -Force

# ---------------------------------------------------------------- launcher
Write-Step "Registering 'tmedia' command ..."
$launcherBody = @'
@echo off
"%~dp0venv\Scripts\python.exe" "%~dp0tmedia.py" %*
'@
Set-Content -LiteralPath $Launcher -Value $launcherBody -Encoding ASCII

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
if (($userPath -split ';') -notcontains $AppDir) {
    $newPath = if ($userPath.Trim()) { "$userPath;$AppDir" } else { $AppDir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host '    added to user PATH - RESTART your terminal once' -ForegroundColor Yellow
}
$env:Path = "$env:Path;$AppDir"

# ---------------------------------------------------------------- verify
Write-Step 'Verifying installation ...'
& $PythonExe $AppPy --version
if ($LASTEXITCODE -ne 0) { Stop-WithError 'Verification failed.' }

Write-Host "`n[+] tmedia installed successfully." -ForegroundColor Green
Write-Host "[+] Open a NEW terminal and type:  tmedia" -ForegroundColor Green
Write-Host "[+] Check credential/session recovery:  tmedia --doctor" -ForegroundColor Green
Write-Host "[+] If this PC has no credentials yet, use a profile from another PC:" -ForegroundColor Gray
Write-Host "      tmedia --import-profile <file>" -ForegroundColor Gray
