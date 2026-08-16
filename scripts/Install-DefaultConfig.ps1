# Copyright (c) My Context Menu Tools contributors.
# Licensed under the MIT License.

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$PreserveConfig
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$TargetDir = Join-Path $env:LOCALAPPDATA "MyContextMenuTools"
$Target = Join-Path $TargetDir "tools.jsonc"
$PresetTargetDir = Join-Path $TargetDir "Presets"

New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
New-Item -ItemType Directory -Force -Path $PresetTargetDir | Out-Null
Get-ChildItem -LiteralPath (Join-Path $RepoRoot "config\presets") -Filter "*.jsonc" | ForEach-Object {
    Copy-Item -Force -LiteralPath $_.FullName -Destination (Join-Path $PresetTargetDir $_.Name)
}

if (!(Test-Path -LiteralPath $Target)) {
    Copy-Item -Force (Join-Path $RepoRoot "config\tools.jsonc") $Target
    Write-Host "Installed default config at $Target"
} elseif ($Force) {
    Copy-Item -Force (Join-Path $RepoRoot "config\tools.jsonc") $Target
    Write-Host "Overwrote config at $Target"
} elseif ($PreserveConfig) {
    Write-Host "Kept existing config at $Target"
} else {
    Write-Host "Config already exists at $Target"
    $answer = Read-Host "Overwrite it with the default config? [y/N]"
    if ($answer -match '^(y|yes)$') {
        Copy-Item -Force (Join-Path $RepoRoot "config\tools.jsonc") $Target
        Write-Host "Overwrote config at $Target"
    } else {
        Write-Host "Kept existing config at $Target"
    }
}

& (Join-Path $PSScriptRoot "Update-CompiledConfigSnapshot.ps1") -ConfigPath $Target
