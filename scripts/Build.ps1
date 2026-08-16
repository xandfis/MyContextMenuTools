# Copyright (c) My Context Menu Tools contributors.
# Licensed under the MIT License.

[CmdletBinding()]
param(
    [ValidateSet("Auto", "x64", "arm64")]
    [string]$Architecture = "Auto",

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
$BuildDir = Join-Path $RepoRoot "build\$Architecture"
$PackagesDir = Join-Path $RepoRoot "build\packages"
$GeneratedDir = Join-Path $BuildDir "generated"
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
$null = New-Item -ItemType Directory -Force -Path $PackagesDir
$null = New-Item -ItemType Directory -Force -Path $GeneratedDir
$PerformanceVerbDefine = if ($PerformanceVerb -eq "Enabled") { "/DMYTOOLS_SHOW_PERFORMANCE_VERB=1" } else { "/DMYTOOLS_SHOW_PERFORMANCE_VERB=0" }
$BuildSettingsPath = Join-Path $BuildDir "build-settings.json"
$PackagesConfigPath = Join-Path $RepoRoot "packages.config"
$PackageConfig = [xml](Get-Content -Raw -LiteralPath $PackagesConfigPath)
$WilVersion = ($PackageConfig.packages.package | Where-Object id -eq "Microsoft.Windows.ImplementationLibrary").version
$CppWinRTVersion = ($PackageConfig.packages.package | Where-Object id -eq "Microsoft.Windows.CppWinRT").version

function Restore-NativeDependencies {
    $nuget = Get-Command nuget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$nuget) {
        throw "NuGet was not found. Run scripts\Install-BuildPrerequisites.ps1."
    }

    & $nuget.Source install $PackagesConfigPath `
        -OutputDirectory $PackagesDir `
        -ExcludeVersion `
        -NonInteractive `
        -Source "https://www.nuget.org/api/v2/"
    if ($LASTEXITCODE -ne 0) {
        throw "NuGet dependency restore failed (exit code $LASTEXITCODE)."
    }
}

Restore-NativeDependencies

$WilIncludeDir = Join-Path $PackagesDir "Microsoft.Windows.ImplementationLibrary\include"
$CppWinRT = Join-Path $PackagesDir "Microsoft.Windows.CppWinRT\bin\cppwinrt.exe"
if (!(Test-Path -LiteralPath $WilIncludeDir -PathType Container)) {
    throw "WIL $WilVersion was not restored to $WilIncludeDir."
}
if (!(Test-Path -LiteralPath $CppWinRT -PathType Leaf)) {
    throw "C++/WinRT $CppWinRTVersion was not restored to $CppWinRT."
}

function Test-DeveloperEnvironment {
    (Get-Command cl.exe -ErrorAction SilentlyContinue) -and
        ![string]::IsNullOrWhiteSpace($env:INCLUDE) -and
        ![string]::IsNullOrWhiteSpace($env:LIB)
}

function Get-VisualStudioInstallationPath {
    $vcToolsComponent = switch ($Architecture) {
        "arm64" { "Microsoft.VisualStudio.Component.VC.Tools.ARM64" }
        "x64" { "Microsoft.VisualStudio.Component.VC.Tools.x86.x64" }
        default { throw "Unsupported build architecture '$Architecture'." }
    }

    $installationPath = & $vswhere -latest -products "*" -requires $vcToolsComponent -property installationPath
    if (!$installationPath) {
        throw "Visual Studio C++ build tools for $Architecture were not found. Run scripts\Install-BuildPrerequisites.ps1 -Architecture $Architecture."
    }

    $installationPath
}

function Write-BuildSettings {
    [pscustomobject]@{
        architecture = $Architecture
        performanceVerb = $PerformanceVerb
        wilVersion = $WilVersion
        cppWinRTVersion = $CppWinRTVersion
    } | ConvertTo-Json | Set-Content -LiteralPath $BuildSettingsPath -Encoding UTF8
}

if (Test-DeveloperEnvironment) {
    $compile = @(
        "cd /d `"$RepoRoot`"",
        "`"$CppWinRT`" -input sdk -output `"$GeneratedDir`" -base",
        "rc /nologo /fo `"$BuildDir\AppIcon.res`" src\AppIcon.rc",
        "cl /nologo /std:c++17 /EHsc /permissive- /W4 /DUNICODE /D_UNICODE $PerformanceVerbDefine /I`"$WilIncludeDir`" /I`"$GeneratedDir`" /LD src\ExplorerCommand.cpp src\ExplorerCommand.def /Fe`"$BuildDir\MyContextMenuToolsExplorerCommand.dll`" /Fo`"$BuildDir\ExplorerCommand.obj`" /link /guard:cf shlwapi.lib shell32.lib ole32.lib advapi32.lib user32.lib rstrtmgr.lib uuid.lib windowsapp.lib",
        "cl /nologo /std:c++17 /EHsc /DUNICODE /D_UNICODE src\StubApp.cpp `"$BuildDir\AppIcon.res`" /Fe`"$BuildDir\MyContextMenuTools.exe`" /Fo`"$BuildDir\StubApp.obj`" /link user32.lib"
    ) -join " && "
    & $env:ComSpec /c $compile
    if ($LASTEXITCODE -eq 0) {
        Write-BuildSettings
    }
    exit $LASTEXITCODE
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (!(Test-Path $vswhere)) {
    throw "MSVC was not found. Run scripts\Install-BuildPrerequisites.ps1 -Architecture $Architecture or use a Developer PowerShell."
}

$installationPath = Get-VisualStudioInstallationPath
$vcvars = Join-Path $installationPath "VC\Auxiliary\Build\vcvarsall.bat"
$vswhereDir = Split-Path -Parent $vswhere
$commands = @(
    "set `"PATH=$vswhereDir;%PATH%`"",
    "call `"$vcvars`" $Architecture >nul",
    "cd /d `"$RepoRoot`"",
    "`"$CppWinRT`" -input sdk -output `"$GeneratedDir`" -base",
    "rc /nologo /fo `"$BuildDir\AppIcon.res`" src\AppIcon.rc",
    "cl /nologo /std:c++17 /EHsc /permissive- /W4 /DUNICODE /D_UNICODE $PerformanceVerbDefine /I`"$WilIncludeDir`" /I`"$GeneratedDir`" /LD src\ExplorerCommand.cpp src\ExplorerCommand.def /Fe`"$BuildDir\MyContextMenuToolsExplorerCommand.dll`" /Fo`"$BuildDir\ExplorerCommand.obj`" /link /guard:cf shlwapi.lib shell32.lib ole32.lib advapi32.lib user32.lib rstrtmgr.lib uuid.lib windowsapp.lib",
    "cl /nologo /std:c++17 /EHsc /DUNICODE /D_UNICODE src\StubApp.cpp `"$BuildDir\AppIcon.res`" /Fe`"$BuildDir\MyContextMenuTools.exe`" /Fo`"$BuildDir\StubApp.obj`" /link user32.lib"
) -join " && "

& $env:ComSpec /c $commands
if ($LASTEXITCODE -eq 0) {
    Write-BuildSettings
}
exit $LASTEXITCODE
