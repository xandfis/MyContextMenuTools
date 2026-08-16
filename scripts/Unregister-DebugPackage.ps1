# Copyright (c) My Context Menu Tools contributors.
# Licensed under the MIT License.

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$IncludeExtensionProfiles,

    [switch]$RemoveGeneratedPackageFiles
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

$packageNamePatterns = @("MyContextMenuTools")
if ($IncludeExtensionProfiles) {
    $packageNamePatterns += "MyContextMenuTools.Extension.*"
}

$packages = @(
    foreach ($pattern in $packageNamePatterns) {
        Get-AppxPackage -Name $pattern -ErrorAction SilentlyContinue
    }
) | Sort-Object PackageFullName -Unique

if ($packages.Count -eq 0) {
    Write-Host "No My Context Menu Tools package identities are registered."
} else {
    foreach ($package in $packages) {
        if ($PSCmdlet.ShouldProcess($package.PackageFullName, "Remove-AppxPackage")) {
            Write-Host "Unregistering $($package.PackageFullName)"
            Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
        }
    }
}

if ($RemoveGeneratedPackageFiles) {
    $generatedPaths = @(
        (Join-Path $RepoRoot ".winapp\debug"),
        (Join-Path $RepoRoot "scripts\.winapp\debug"),
        (Join-Path $RepoRoot "build\x64\package"),
        (Join-Path $RepoRoot "build\arm64\package"),
        (Join-Path $RepoRoot "build\x64\extensions"),
        (Join-Path $RepoRoot "build\arm64\extensions")
    )

    foreach ($path in $generatedPaths) {
        if (Test-Path -LiteralPath $path) {
            if ($PSCmdlet.ShouldProcess($path, "Remove generated package files")) {
                Remove-Item -Recurse -Force -LiteralPath $path
                Write-Host "Removed $path"
            }
        }
    }
}

$remaining = @(Get-AppxPackage -Name "MyContextMenuTools*" -ErrorAction SilentlyContinue)
if ($remaining.Count -eq 0) {
    Write-Host "No My Context Menu Tools package identities remain registered."
} else {
    Write-Warning "Some My Context Menu Tools package identities are still registered:"
    $remaining | Select-Object Name, Version, PackageFullName | Format-Table -AutoSize
    if (!$IncludeExtensionProfiles) {
        Write-Host "Run again with -IncludeExtensionProfiles to also remove optional top-level extension profiles."
    }
}
