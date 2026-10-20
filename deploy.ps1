<#
.SYNOPSIS
    Copies dist\bg3_lootlog.pak into the game's Mods folder and replaces the old file safely.

.DESCRIPTION
    The running game locks the .pak files it loaded, and a file must not change while the game runs. The script checks
    the lock first; with -Wait it waits until the game is closed. The new file is copied under a temporary name,
    checked, and then swapped in with one rename, so the game never sees a half-written file.

    Exit codes: 0 = deployed or already up to date, 2 = the game is running (without -Wait), 1 = error.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Wait
#>
param(
    # The game's Mods folder. Default: Mods below $env:BG3_DATA_DIR (the BG3 user-data folder, for example a share of
    # the game PC), else the local %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods.
    [string]$ModsDir = $(if ($env:BG3_DATA_DIR) { Join-Path $env:BG3_DATA_DIR "Mods" } else { Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Mods" }),
    # Wait until the game releases the file instead of stopping.
    [switch]$Wait,
    [int]$WaitMinutes = 360
)

$ErrorActionPreference = "Stop"

$ModFolder = "bg3_lootlog"
$source = Join-Path $PSScriptRoot "dist\$ModFolder.pak"
$target = Join-Path $ModsDir "$ModFolder.pak"
$temp = "$target.tmp"

if (-not (Test-Path $source)) {
    throw "$source not found. Build it first with build.ps1."
}
if (-not (Test-Path $ModsDir)) {
    throw "The Mods folder is not reachable: $ModsDir (set BG3_DATA_DIR to the BG3 user-data folder, or use -ModsDir)"
}

function Test-Locked([string]$Path) {
    if (-not (Test-Path $Path)) {
        return $false
    }
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $stream.Close()
        return $false
    } catch {
        return $true
    }
}

function Get-Hash([string]$Path) {
    try {
        return (Get-FileHash $Path -ErrorAction Stop).Hash
    } catch {
        return $null
    }
}

$hash = Get-Hash $source
if ((Test-Path $target) -and (Get-Hash $target) -eq $hash) {
    Write-Host "Already up to date: $target" -ForegroundColor Green
    exit 0
}

if (Test-Locked $target) {
    if (-not $Wait) {
        Write-Host "The game is running and uses $target." -ForegroundColor Yellow
        Write-Host "Close the game and run this again, or use the -Wait option." -ForegroundColor Yellow
        exit 2
    }
    Write-Host "The game is running. Waiting until it is closed (checking every 5 seconds)..."
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    while (Test-Locked $target) {
        if ((Get-Date) -gt $deadline) {
            throw "The game did not release $target within $WaitMinutes minutes."
        }
        Start-Sleep -Seconds 5
    }
}

Copy-Item $source $temp -Force
if ((Get-FileHash $temp).Hash -ne $hash) {
    Remove-Item $temp -Force
    throw "The copy in $temp is damaged. Nothing was replaced."
}

try {
    if (Test-Path $target) {
        # [NullString]::Value: Windows PowerShell passes $null as "" to string parameters.
        [System.IO.File]::Replace($temp, $target, [NullString]::Value)
    } else {
        Move-Item $temp $target
    }
} catch {
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    throw "Could not replace $target (did the game start again?): $($_.Exception.Message)"
}

if ((Get-FileHash $target).Hash -ne $hash) {
    throw "Check failed: $target does not match $source."
}
Write-Host "Deployed: $source -> $target" -ForegroundColor Green
