# Copyright (c) My Context Menu Tools contributors.
# Licensed under the MIT License.

[CmdletBinding()]
param(
    [ValidateSet("Auto", "x64", "arm64")]
    [string]$Architecture = "Auto",

    [ValidateSet("Automatic", "Gentle", "ClearCache", "Force")]
    [string]$ExplorerRestartMode = "Automatic",

    [ValidateSet("Enabled", "Disabled")]
    [string]$PerformanceVerb = "Enabled"
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

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
. (Join-Path $PSScriptRoot "PackageLogo.ps1")
$BuildDir = Join-Path $RepoRoot "build\$Architecture"
$AutomaticExplorerRestart = $ExplorerRestartMode -eq "Automatic"
$AllowExplorerRestart = $ExplorerRestartMode -in @("ClearCache", "Force")
$ForceExplorerRestart = $ExplorerRestartMode -eq "Force"

function Restart-ExplorerShell {
    param(
        [string]$Message = "Restarting Explorer."
    )

    Write-Warning $Message
    $processes = Get-Process -Name explorer -ErrorAction SilentlyContinue
    foreach ($process in $processes) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
    Start-Process explorer.exe
    Start-Sleep -Seconds 2
}

function Enable-ForceExplorerRestart {
    $script:AllowExplorerRestart = $true
    $script:ForceExplorerRestart = $true
    $script:ExplorerRestartMode = "Force"
}

function Confirm-ForceExplorerRestart {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    if (!$AutomaticExplorerRestart) {
        return $false
    }

    Write-Warning $Reason
    $answer = Read-Host "Escalate to Force mode and restart Explorer now? [Y/n]"
    if ($answer -match '^(n|no)$') {
        return $false
    }

    Enable-ForceExplorerRestart
    $true
}

function Copy-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [switch]$Recurse,
        [switch]$RestartExplorerOnFailure,

        [int]$GentleSeconds = 10
    )

    $restartedExplorer = $false
    $deadline = (Get-Date).AddSeconds($GentleSeconds)
    while ($true) {
        try {
            if ($Recurse) {
                Copy-Item -Recurse -Force -LiteralPath $Source -Destination $Destination
            } else {
                Copy-Item -Force -LiteralPath $Source -Destination $Destination
            }
            return
        } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 1
                continue
            }

            if ($RestartExplorerOnFailure -and !$restartedExplorer) {
                Restart-ExplorerShell "Runtime files appear to be locked. Restarting Explorer and retrying the copy."
                $restartedExplorer = $true
                continue
            }

            if (!$restartedExplorer -and (Confirm-ForceExplorerRestart "Runtime files still appear to be locked after $GentleSeconds seconds.")) {
                Restart-ExplorerShell "Runtime files appear to be locked. Restarting Explorer and retrying the copy."
                $restartedExplorer = $true
                continue
            }

            throw
        }
    }
}

function Copy-RuntimeFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if ($AllowExplorerRestart) {
        Copy-WithRetry $Source $Destination -RestartExplorerOnFailure
    } else {
        Copy-WithRetry $Source $Destination
    }
}

function Invoke-CreateDebugIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageDir
    )

    New-Item -ItemType Directory -Force -Path (Join-Path $PackageDir ".winapp") | Out-Null
    Push-Location -LiteralPath $PackageDir
    try {
        winapp create-debug-identity (Join-Path $PackageDir "MyContextMenuTools.exe") --manifest (Join-Path $PackageDir "Package.appxmanifest") --keep-identity
    } finally {
        Pop-Location
    }
}

function Test-BuildMatchesSettings {
    $settingsPath = Join-Path $BuildDir "build-settings.json"
    if (!(Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return $false
    }
    try {
        $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
        return $settings.performanceVerb -eq $PerformanceVerb
    } catch {
        return $false
    }
}

if (!(Test-Path (Join-Path $BuildDir "MyContextMenuToolsExplorerCommand.dll")) -or !(Test-Path (Join-Path $BuildDir "MyContextMenuTools.exe")) -or !(Test-BuildMatchesSettings)) {
    & (Join-Path $PSScriptRoot "Build.ps1") -Architecture $Architecture -PerformanceVerb $PerformanceVerb
}

if (!(Get-Command winapp.exe -ErrorAction SilentlyContinue)) {
    throw "The winapp CLI was not found. Run scripts\Install-BuildPrerequisites.ps1."
}

$ExistingPackage = Get-AppxPackage -Name MyContextMenuTools -ErrorAction SilentlyContinue
if ($ExistingPackage) {
    if ($ForceExplorerRestart) {
        Restart-ExplorerShell "Restarting Explorer before unregistering the existing debug package."
    }
    Write-Host "Unregistering existing package identity $($ExistingPackage.PackageFullName)"
    try {
        Remove-AppxPackage -Package $ExistingPackage.PackageFullName -ErrorAction Stop
    } catch {
        $unregisterSucceeded = $false
        if (!$AllowExplorerRestart) {
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 1
                try {
                    Remove-AppxPackage -Package $ExistingPackage.PackageFullName -ErrorAction Stop
                    $unregisterSucceeded = $true
                    break
                } catch {
                    continue
                }
            }
        }

        if ($unregisterSucceeded) {
            Write-Host "Unregistered existing package after a Gentle retry."
        } elseif (!$AllowExplorerRestart -and (Confirm-ForceExplorerRestart "Existing package could not be unregistered after 10 seconds in Gentle mode.")) {
            Restart-ExplorerShell "Restarting Explorer before retrying package unregister."
            Remove-AppxPackage -Package $ExistingPackage.PackageFullName -ErrorAction Stop
        } elseif (!$AllowExplorerRestart -or $ForceExplorerRestart) {
            throw
        } else {
            Restart-ExplorerShell "Existing package could not be unregistered cleanly. Restarting Explorer and retrying once."
            Remove-AppxPackage -Package $ExistingPackage.PackageFullName -ErrorAction Stop
        }
    }

    $unregistered = $false
    for ($attempt = 1; $attempt -le 40; $attempt++) {
        if (!(Get-AppxPackage -Name MyContextMenuTools -ErrorAction SilentlyContinue)) {
            $unregistered = $true
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if (!$unregistered) {
        if (!$AllowExplorerRestart -and (Confirm-ForceExplorerRestart "Existing package did not unregister after 10 seconds in Gentle mode.")) {
            Restart-ExplorerShell "Restarting Explorer and waiting for package unregister."
            for ($attempt = 1; $attempt -le 40; $attempt++) {
                if (!(Get-AppxPackage -Name MyContextMenuTools -ErrorAction SilentlyContinue)) {
                    $unregistered = $true
                    break
                }
                Start-Sleep -Milliseconds 250
            }
        }

        if (!$unregistered) {
            throw "Timed out waiting for the existing MyContextMenuTools package to unregister."
        }
    }
}

$PackageDir = Join-Path $BuildDir "package"
Remove-Item -Recurse -Force $PackageDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null
Copy-WithRetry (Join-Path $RepoRoot "Package.appxmanifest") (Join-Path $PackageDir "Package.appxmanifest")
Copy-WithRetry (Join-Path $RepoRoot "Package.appxmanifest") (Join-Path $PackageDir "appxmanifest.xml")
Remove-Item -Recurse -Force (Join-Path $PackageDir "Assets") -ErrorAction SilentlyContinue
Copy-WithRetry (Join-Path $RepoRoot "Assets") (Join-Path $PackageDir "Assets") -Recurse
New-PackageSquare44Logo -Icon "__appicon" -PackageDir $PackageDir -RepoRoot $RepoRoot
Copy-RuntimeFile (Join-Path $BuildDir "MyContextMenuToolsExplorerCommand.dll") (Join-Path $PackageDir "MyContextMenuToolsExplorerCommand.dll")
Copy-RuntimeFile (Join-Path $BuildDir "MyContextMenuTools.exe") (Join-Path $PackageDir "MyContextMenuTools.exe")

Invoke-CreateDebugIdentity $PackageDir
if ($LASTEXITCODE -ne 0) {
    if (!$AllowExplorerRestart -and (Confirm-ForceExplorerRestart "Debug package identity creation failed in Gentle mode.")) {
        Restart-ExplorerShell "Restarting Explorer before retrying debug package identity creation."
        Invoke-CreateDebugIdentity $PackageDir
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the debug package identity."
    }
}
$RegisteredPackage = Get-AppxPackage -Name MyContextMenuTools -ErrorAction Stop

$RegisteredPackageDir = $RegisteredPackage.InstallLocation
if ($RegisteredPackageDir -ne $PackageDir) {
    Copy-WithRetry (Join-Path $RepoRoot "Package.appxmanifest") (Join-Path $RegisteredPackageDir "Package.appxmanifest")
    Copy-WithRetry (Join-Path $RepoRoot "Package.appxmanifest") (Join-Path $RegisteredPackageDir "appxmanifest.xml")
    Remove-Item -Recurse -Force (Join-Path $RegisteredPackageDir "Assets") -ErrorAction SilentlyContinue
    Copy-WithRetry (Join-Path $RepoRoot "Assets") (Join-Path $RegisteredPackageDir "Assets") -Recurse
    New-PackageSquare44Logo -Icon "__appicon" -PackageDir $RegisteredPackageDir -RepoRoot $RepoRoot
    Copy-RuntimeFile (Join-Path $BuildDir "MyContextMenuToolsExplorerCommand.dll") (Join-Path $RegisteredPackageDir "MyContextMenuToolsExplorerCommand.dll")
    Copy-RuntimeFile (Join-Path $BuildDir "MyContextMenuTools.exe") (Join-Path $RegisteredPackageDir "MyContextMenuTools.exe")
}

$ConfigPath = Join-Path $env:LOCALAPPDATA "MyContextMenuTools\tools.jsonc"
if (Test-Path -LiteralPath $ConfigPath) {
    & (Join-Path $PSScriptRoot "Update-CompiledConfigSnapshot.ps1") -ConfigPath $ConfigPath
} else {
    Write-Warning "Config file not found at $ConfigPath. Skipping compiled config snapshot generation."
}
$ExtensionsDir = Join-Path $env:LOCALAPPDATA "MyContextMenuTools\Extensions"
if (Test-Path -LiteralPath $ExtensionsDir) {
    Get-ChildItem -LiteralPath $ExtensionsDir -Filter "slot-*.jsonc" -File | ForEach-Object {
        & (Join-Path $PSScriptRoot "Update-CompiledConfigSnapshot.ps1") -ConfigPath $_.FullName
    }
}

if ($AllowExplorerRestart) {
    Restart-ExplorerShell "Restarting Explorer to reload the debug package and refresh context-menu icons."
} else {
    if ($AutomaticExplorerRestart) {
        Write-Host "Explorer was not restarted. Automatic mode completed with Gentle behavior."
    } else {
        Write-Host "Explorer was not restarted. Use -ExplorerRestartMode Automatic, ClearCache, or Force when Explorer needs to reload shell state."
    }
}

$ConfigDir = Join-Path $env:LOCALAPPDATA "MyContextMenuTools"
$ShortcutPath = Join-Path $env:USERPROFILE "My Context Menu Tools Config.lnk"
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

$Shell = New-Object -ComObject WScript.Shell
$Shortcut = $Shell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = $ConfigDir
$Shortcut.WorkingDirectory = $ConfigDir
$Shortcut.Description = "Open the My Context Menu Tools configuration folder"
$Shortcut.Save()

Write-Host "Registered debug package from $PackageDir"
Write-Host "Copied runtime files to $RegisteredPackageDir"
Write-Host "Created config folder shortcut at $ShortcutPath"
Write-Host "Run scripts\Install-DefaultConfig.ps1 if you need to reset the local config."
