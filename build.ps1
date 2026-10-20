<#
.SYNOPSIS
    Packs the bg3_lootlog mod (the src folder) into dist\bg3_lootlog.pak.

.DESCRIPTION
    Packs the src folder with Divine.exe (LSLib) from the shared _tools folder of the modding base folder
    ($env:BG3_TOOLS overrides it) and lists the package contents. With -Deploy (or -ModsDir), deploy.ps1 then copies
    the .pak into the game's Mods folder.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build.ps1 -Deploy

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build.ps1 -ModsDir "Z:\Mods"
#>
param(
    # Copy the package to the game's Mods folder after the build (see deploy.ps1 for the default folder).
    [switch]$Deploy,
    # Mods folder for the deployment; implies -Deploy.
    [string]$ModsDir
)

$ErrorActionPreference = "Stop"

$ModFolder = "bg3_lootlog"
$root = $PSScriptRoot
$source = Join-Path $root "src"
$dist = Join-Path $root "dist"
$pak = Join-Path $dist "$ModFolder.pak"

# The shared tools: $env:BG3_TOOLS, else the first _tools folder above the project.
function Find-Tools {
    if ($env:BG3_TOOLS) {
        return $env:BG3_TOOLS
    }
    $dir = Split-Path $root -Parent
    while ($dir) {
        $candidate = Join-Path $dir "_tools"
        if (Test-Path $candidate) {
            return $candidate
        }
        $dir = Split-Path $dir -Parent
    }
    throw "No _tools folder above $root. Put LSLib (https://github.com/Norbyte/lslib/releases) into a folder _tools\lslib above the project, or set BG3_TOOLS."
}

$divine = Join-Path (Find-Tools) "lslib\Packed\Tools\Divine.exe"
if (-not (Test-Path $divine)) {
    throw "$divine not found. Put LSLib (https://github.com/Norbyte/lslib/releases) into _tools\lslib, or set BG3_TOOLS."
}

New-Item -ItemType Directory -Force $dist | Out-Null
if (Test-Path $pak) {
    Remove-Item $pak
}

& $divine --game bg3 --action create-package --source $source --destination $pak --compression-method lz4 --loglevel warn
if ($LASTEXITCODE -ne 0) {
    throw "Divine.exe create-package failed with exit code $LASTEXITCODE"
}

Write-Host "Package contents:"
& $divine --game bg3 --action list-package --source $pak --loglevel warn
if ($LASTEXITCODE -ne 0) {
    throw "Divine.exe list-package failed with exit code $LASTEXITCODE"
}

Write-Host "Built $pak"

if ($Deploy -or $ModsDir) {
    $deployArgs = @{}
    if ($ModsDir) {
        $deployArgs.ModsDir = $ModsDir
    }
    & (Join-Path $root "deploy.ps1") @deployArgs
    exit $LASTEXITCODE
}
