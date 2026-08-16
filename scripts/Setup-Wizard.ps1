# Copyright (c) My Context Menu Tools contributors.
# Licensed under the MIT License.

[CmdletBinding()]
param(
    [ValidateSet("Auto", "x64", "arm64")]
    [string]$Architecture = "Auto",

    [ValidateSet("Automatic", "Gentle", "ClearCache", "Force")]
    [string]$ExplorerRestartMode = "Automatic",

    [ValidateSet("Enabled", "Disabled")]
    [string]$PerformanceVerb = "Enabled",

    [switch]$NonInteractive,
    [switch]$SkipPrerequisites,
    [switch]$SkipBuild,
    [switch]$SkipConfig,
    [switch]$SkipAppScan,
    [switch]$SkipValidation,
    [switch]$SkipRegistration
)

$ErrorActionPreference = "Stop"

function Resolve-NativeArchitecture {
    switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
        "Arm64" { "arm64"; return }
        "X64" { "x64"; return }
        default { throw "Unsupported native OS architecture '$([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)'." }
    }
}

if ($Architecture -eq "Auto") {
    $Architecture = Resolve-NativeArchitecture
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Question,

        [bool]$Default = $true
    )

    if ($NonInteractive) {
        return $Default
    }

    $suffix = if ($Default) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $answer = Read-Host "$Question $suffix"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
        Write-Host "Please answer yes or no."
    }
}

function Read-Choice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Question,

        [Parameter(Mandatory = $true)]
        [string[]]$Choices,

        [Parameter(Mandatory = $true)]
        [string]$Default
    )

    if ($NonInteractive) {
        return $Default
    }

    $choiceList = $Choices -join "/"
    while ($true) {
        $answer = Read-Host "$Question [$choiceList] (default: $Default)"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }
        foreach ($choice in $Choices) {
            if ($answer -ieq $choice) {
                return $choice
            }
        }
        Write-Host "Please choose one of: $choiceList"
    }
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    Write-Host ""
    Write-Host "== $Name =="
    & $Action
}

function Get-AppPresetSelection {
    if ($NonInteractive) {
        return @("All")
    }

    Write-Host "Supported app preset scan targets:"
    Write-Host "  1. All supported apps"
    Write-Host "  2. 7-Zip (top-level entry)"
    Write-Host "  3. Notepad++ (under My Tools)"
    Write-Host "  4. Skip app preset scan"

    while ($true) {
        $answer = Read-Host "Which app presets should I scan for? [1/2/3/4] (default: 1)"
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq "1") { return @("All") }
        if ($answer -eq "2") { return @("7-Zip") }
        if ($answer -eq "3") { return @("Notepad++") }
        if ($answer -eq "4") { return @() }
        Write-Host "Please choose 1, 2, 3, or 4."
    }
}

function Get-ExtensionProfileCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigRoot
    )

    $registryPath = Join-Path $ConfigRoot "Extensions\extensions.json"
    if (!(Test-Path -LiteralPath $registryPath -PathType Leaf)) {
        return 0
    }

    try {
        $profiles = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json -Depth 20
        return @($profiles).Count
    } catch {
        throw "Could not read extension profile registry at $registryPath. $($_.Exception.Message)"
    }
}

function Test-BuildUpToDate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [string]$PerformanceVerb
    )

    $buildDir = Join-Path $RepoRoot "build\$Architecture"
    $outputs = @(
        (Join-Path $buildDir "MyContextMenuToolsExplorerCommand.dll"),
        (Join-Path $buildDir "MyContextMenuTools.exe"),
        (Join-Path $buildDir "build-settings.json")
    )

    foreach ($output in $outputs) {
        if (!(Test-Path -LiteralPath $output -PathType Leaf)) {
            return $false
        }
    }

    $newestOutput = ($outputs | ForEach-Object {
        (Get-Item -LiteralPath $_).LastWriteTimeUtc
    } | Sort-Object | Select-Object -First 1)

    $inputRoots = @(
        (Join-Path $RepoRoot "src"),
        (Join-Path $RepoRoot "Assets")
    )
    $inputs = @(
        (Join-Path $RepoRoot "scripts\Build.ps1"),
        (Join-Path $RepoRoot "Package.appxmanifest")
    )

    foreach ($root in $inputRoots) {
        if (Test-Path -LiteralPath $root) {
            $inputs += Get-ChildItem -Recurse -File -LiteralPath $root | Select-Object -ExpandProperty FullName
        }
    }

    foreach ($input in $inputs) {
        if ((Test-Path -LiteralPath $input -PathType Leaf) -and (Get-Item -LiteralPath $input).LastWriteTimeUtc -gt $newestOutput) {
            return $false
        }
    }

    try {
        $settings = Get-Content -Raw -LiteralPath (Join-Path $buildDir "build-settings.json") | ConvertFrom-Json
        if ($settings.performanceVerb -ne $PerformanceVerb) {
            return $false
        }
    } catch {
        return $false
    }

    $true
}

$ScriptsDir = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $ScriptsDir "..")
$ConfigPath = Join-Path $env:LOCALAPPDATA "MyContextMenuTools\tools.jsonc"
$ConfigRoot = Split-Path -Parent $ConfigPath

Write-Host "My Context Menu Tools setup wizard"
Write-Host "Config path: $ConfigPath"

$buildNeeded = !(Test-BuildUpToDate -RepoRoot $RepoRoot -Architecture $Architecture -PerformanceVerb $PerformanceVerb)
$needsBuildTools = !$SkipBuild -or !$SkipRegistration
$needsWinAppCli = !$SkipRegistration
if (!$SkipPrerequisites -and ($needsBuildTools -or $needsWinAppCli)) {
    $prerequisiteArguments = @{
        Architecture = $Architecture
        CheckOnly = $true
        Quiet = $true
        SkipBuildTools = !$needsBuildTools
        SkipWinAppCli = !$needsWinAppCli
    }
    $prerequisiteStatus = & (Join-Path $ScriptsDir "Install-BuildPrerequisites.ps1") @prerequisiteArguments
    if (!$prerequisiteStatus.Ready) {
        $missingPrerequisites = @()
        if (!$prerequisiteStatus.BuildToolsReady) {
            $missingPrerequisites += "Visual Studio C++ build tools and Windows SDK"
        }
        if (!$prerequisiteStatus.WinAppCliReady) {
            $missingPrerequisites += "Windows App Development CLI"
        }

        if (Read-YesNo "Install missing prerequisites with winget ($($missingPrerequisites -join ", "))?" $true) {
            $installArguments = @{
                Architecture = $Architecture
                NonInteractive = $NonInteractive
                SkipBuildTools = !$needsBuildTools
                SkipWinAppCli = !$needsWinAppCli
            }
            Invoke-Step "Install build prerequisites" {
                & (Join-Path $ScriptsDir "Install-BuildPrerequisites.ps1") @installArguments
            }
        } else {
            Write-Warning "Skipped prerequisite installation. Build or registration may fail until the missing tools are installed."
        }
    }
}

if (!$SkipBuild) {
    $buildQuestion = if ($buildNeeded) {
        "Build output is missing or stale. Build runtime binaries for $Architecture?"
    } else {
        "Build appears up to date. Rebuild runtime binaries for $Architecture anyway?"
    }

    if (Read-YesNo $buildQuestion $buildNeeded) {
        Invoke-Step "Build" {
            & (Join-Path $ScriptsDir "Build.ps1") -Architecture $Architecture -PerformanceVerb $PerformanceVerb
        }
    } else {
        Write-Host "Skipped build."
    }
}

if (!$SkipConfig -and (Read-YesNo "Install or update the default config and preset files?" $true)) {
    Invoke-Step "Install default config" {
        if ($NonInteractive) {
            & (Join-Path $ScriptsDir "Install-DefaultConfig.ps1") -PreserveConfig
        } else {
            & (Join-Path $ScriptsDir "Install-DefaultConfig.ps1")
        }
    }
}

if (!$SkipAppScan -and (Read-YesNo "Scan for supported apps that still use legacy context-menu verbs?" $true)) {
    $apps = Get-AppPresetSelection
    if ($apps.Count -gt 0) {
        $scanAll = $apps -contains "All"
        $scan7Zip = $scanAll -or $apps -contains "7Zip" -or $apps -contains "7-Zip"
        $scanNotepadPlusPlus = $scanAll -or $apps -contains "NotepadPlusPlus" -or $apps -contains "Notepad++"

        if ($scan7Zip) {
            $detected7Zip = @(Invoke-Step "Detect 7-Zip preset" {
                & (Join-Path $ScriptsDir "Ensure-AppContextMenuPresets.ps1") -ConfigPath $ConfigPath -Apps "7-Zip" -Mode RemoveFromMyTools -PassThru
            })
            if ($detected7Zip | Where-Object { $_.Name -eq "7-Zip" }) {
                Invoke-Step "Configure top-level 7-Zip entry" {
                    & (Join-Path $ScriptsDir "Manage-ContextMenuExtensions.ps1") -Action Ensure -Preset 7Zip -Targets files, folders -Architecture $Architecture -PerformanceVerb $PerformanceVerb -DeferRegistration
                }
            }
        }

        if ($scanNotepadPlusPlus) {
            Invoke-Step "Ensure My Tools app presets" {
                & (Join-Path $ScriptsDir "Ensure-AppContextMenuPresets.ps1") -ConfigPath $ConfigPath -Apps "Notepad++"
            }
        }
    } else {
        Write-Host "Skipped app preset scan."
    }
}

if (!$SkipValidation -and (Read-YesNo "Validate the config and offer fixes for missing app paths?" $true)) {
    Invoke-Step "Validate config" {
        if ($NonInteractive) {
            & (Join-Path $ScriptsDir "Validate-ToolsConfig.ps1") -ConfigPath $ConfigPath
        } else {
            & (Join-Path $ScriptsDir "Validate-ToolsConfig.ps1") -ConfigPath $ConfigPath -OfferFixes
        }
    }
}

if (!$SkipRegistration -and (Read-YesNo "Register the debug package for File Explorer?" $true)) {
    $restartMode = Read-Choice "How aggressive should Explorer restarts be?" @("Automatic", "Gentle", "ClearCache", "Force") $ExplorerRestartMode
    Invoke-Step "Register debug package" {
        & (Join-Path $ScriptsDir "Register-DebugPackage.ps1") -Architecture $Architecture -ExplorerRestartMode $restartMode -PerformanceVerb $PerformanceVerb
    }

    if ((Get-ExtensionProfileCount $ConfigRoot) -gt 0) {
        Invoke-Step "Refresh extension profile packages" {
            & (Join-Path $ScriptsDir "Manage-ContextMenuExtensions.ps1") -Action Refresh -Architecture $Architecture -PerformanceVerb $PerformanceVerb
        }
    }
}

Write-Host ""
Write-Host "Setup wizard complete."
