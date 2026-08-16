# Copyright (c) My Context Menu Tools contributors.
# Licensed under the MIT License.

[CmdletBinding()]
param(
    [ValidateSet("Auto", "x64", "arm64")]
    [string]$Architecture = "Auto",

    [switch]$CheckOnly,
    [switch]$NonInteractive,
    [switch]$SkipBuildTools,
    [switch]$SkipNuGet,
    [switch]$SkipWinAppCli,
    [switch]$Quiet
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

function Write-Status {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (!$Quiet) {
        Write-Host $Message
    }
}

function Get-VsWherePath {
    $defaultPath = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $defaultPath -PathType Leaf) {
        return $defaultPath
    }

    $command = Get-Command vswhere.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    $null
}

function Get-VcToolsComponent {
    switch ($Architecture) {
        "arm64" { "Microsoft.VisualStudio.Component.VC.Tools.ARM64"; return }
        "x64" { "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"; return }
        default { throw "Unsupported build architecture '$Architecture'." }
    }
}

function Test-BuildToolchain {
    if ((Get-Command cl.exe -ErrorAction SilentlyContinue) -and
        (Get-Command rc.exe -ErrorAction SilentlyContinue) -and
        ![string]::IsNullOrWhiteSpace($env:INCLUDE) -and
        ![string]::IsNullOrWhiteSpace($env:LIB)) {
        return $true
    }

    $vswhere = Get-VsWherePath
    if (!$vswhere) {
        return $false
    }

    $installationPath = & $vswhere -latest -products "*" -requires (Get-VcToolsComponent) -property installationPath 2>$null |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($installationPath)) {
        return $false
    }

    $vcvars = Join-Path $installationPath "VC\Auxiliary\Build\vcvarsall.bat"
    if (!(Test-Path -LiteralPath $vcvars -PathType Leaf)) {
        return $false
    }

    $vswhereDir = Split-Path -Parent $vswhere
    $checkCommand = @(
        "set `"PATH=$vswhereDir;%PATH%`"",
        "call `"$vcvars`" $Architecture >nul",
        "where cl.exe >nul 2>nul",
        "where rc.exe >nul 2>nul"
    ) -join " && "
    & $env:ComSpec /d /s /c $checkCommand
    $LASTEXITCODE -eq 0
}

function Test-WinAppCli {
    [bool](Get-Command winapp.exe -ErrorAction SilentlyContinue)
}

function Test-NuGet {
    [bool](Get-Command nuget.exe -ErrorAction SilentlyContinue)
}

function Get-PrerequisiteStatus {
    $buildToolsReady = $SkipBuildTools -or (Test-BuildToolchain)
    $nugetReady = $SkipNuGet -or (Test-NuGet)
    $winAppCliReady = $SkipWinAppCli -or (Test-WinAppCli)

    [pscustomobject]@{
        Architecture = $Architecture
        WingetReady = [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
        BuildToolsReady = $buildToolsReady
        NuGetReady = $nugetReady
        WinAppCliReady = $winAppCliReady
        Ready = $buildToolsReady -and $nugetReady -and $winAppCliReady
    }
}

function Update-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = @($env:Path, $machinePath, $userPath) -join ";"
}

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [string]$Override,
        [switch]$Force
    )

    $arguments = @(
        "install",
        "--id", $PackageId,
        "--exact",
        "--source", "winget",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )
    if ($NonInteractive) {
        $arguments += "--silent"
    }
    if (![string]::IsNullOrWhiteSpace($Override)) {
        $arguments += @("--override", $Override)
    }
    if ($Force) {
        $arguments += "--force"
    }

    Write-Status "Running: winget install --id $PackageId"
    & winget.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $PackageId (exit code $LASTEXITCODE)."
    }
}

$status = Get-PrerequisiteStatus
Write-Status "Build tools for $Architecture`: $(if ($status.BuildToolsReady) { "ready" } else { "missing" })"
Write-Status "NuGet CLI: $(if ($status.NuGetReady) { "ready" } else { "missing" })"
Write-Status "Windows App Development CLI: $(if ($status.WinAppCliReady) { "ready" } else { "missing" })"

if ($CheckOnly) {
    $status
    return
}

if ($status.Ready) {
    Write-Status "All requested build prerequisites are ready."
    return
}

if (!$status.WingetReady) {
    throw "winget is required to install missing prerequisites. Install or update App Installer from the Microsoft Store, then rerun this script."
}

if (!$status.BuildToolsReady) {
    $uiMode = if ($NonInteractive) { "--quiet" } else { "--passive" }
    $override = @(
        "--wait",
        $uiMode,
        "--norestart",
        "--add", "Microsoft.VisualStudio.Workload.VCTools",
        "--add", (Get-VcToolsComponent),
        "--add", "Microsoft.VisualStudio.Component.Windows11SDK.26100"
    ) -join " "

    Write-Status "Installing Visual Studio Build Tools, MSVC for $Architecture, and Windows 11 SDK 26100."
    Invoke-WingetInstall -PackageId "Microsoft.VisualStudio.2022.BuildTools" -Override $override -Force
}

if (!$status.NuGetReady) {
    Write-Status "Installing the NuGet CLI."
    Invoke-WingetInstall -PackageId "Microsoft.NuGet"
}

if (!$status.WinAppCliReady) {
    Write-Status "Installing the Windows App Development CLI."
    Invoke-WingetInstall -PackageId "Microsoft.WinAppCli"
}

Update-ProcessPath
$status = Get-PrerequisiteStatus
if (!$status.Ready) {
    $missing = @()
    if (!$status.BuildToolsReady) { $missing += "Visual Studio C++ build tools or Windows SDK" }
    if (!$status.NuGetReady) { $missing += "NuGet CLI" }
    if (!$status.WinAppCliReady) { $missing += "winapp CLI" }
    throw "Installation completed, but the following prerequisites could not be detected: $($missing -join ", "). Restart Windows if an installer requested it, then rerun this script with -CheckOnly."
}

Write-Status "All requested build prerequisites are ready."
