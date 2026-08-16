# Copyright (c) My Context Menu Tools contributors.
# Licensed under the MIT License.

[CmdletBinding()]
param(
    [switch]$Help,

    [ValidateSet("List", "ListPresets", "Add", "Ensure", "Remove", "Refresh", "ScanExternal", "RemoveExternal")]
    [string]$Action = "List",

    [string]$Id,
    [string]$ExternalPackageFullName,
    [string]$Title,
    [string]$Include,
    [string]$Icon = "__appicon",

    [ValidateSet("None", "7Zip", "NotepadPlusPlus", "SuperDelete")]
    [string]$Preset = "None",

    [ValidateSet("files", "folders", "backgrounds")]
    [string[]]$Targets = @("files", "folders", "backgrounds"),

    [ValidateSet("Auto", "x64", "arm64")]
    [string]$Architecture = "Auto",

    [ValidateSet("Enabled", "Disabled")]
    [string]$PerformanceVerb = "Enabled",

    [switch]$DeferRegistration
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
$NoParameters = $PSBoundParameters.Count -eq 0
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
. (Join-Path $PSScriptRoot "PackageLogo.ps1")
$BuildDir = Join-Path $RepoRoot "build\$Architecture"
$ConfigRoot = Join-Path $env:LOCALAPPDATA "MyContextMenuTools"
$ExtensionsDir = Join-Path $ConfigRoot "Extensions"
$RegistryPath = Join-Path $ExtensionsDir "extensions.json"

function ConvertTo-SafeId([string]$Value) {
    $safe = ($Value -replace '[^A-Za-z0-9]', '')
    if (!$safe) { throw "Id must contain at least one letter or number." }
    $safe
}

function ConvertTo-JsonPathLiteral([string]$Path) {
    $Path.Replace('\', '\\')
}

function ConvertTo-JsonStringLiteral([string]$Value) {
    $Value | ConvertTo-Json -Compress
}

function ConvertTo-XmlLiteral([string]$Value) {
    [System.Security.SecurityElement]::Escape($Value)
}

function ConvertTo-PowerShellSingleQuotedLiteral([string]$Value) {
    "'" + $Value.Replace("'", "''") + "'"
}

function Get-Registry {
    if (!(Test-Path -LiteralPath $RegistryPath)) { return @() }
    $items = Get-Content -Raw -LiteralPath $RegistryPath | ConvertFrom-Json -Depth 20
    if (!$items) { return @() }
    @($items)
}

function Save-Registry($Items) {
    New-Item -ItemType Directory -Force -Path $ExtensionsDir | Out-Null
    $itemsArray = @($Items)
    if ($itemsArray.Count -eq 0) {
        "[]" | Set-Content -LiteralPath $RegistryPath -Encoding UTF8
        return
    }
    $itemsArray | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $RegistryPath -Encoding UTF8
}

function Write-HelpText {
    Write-Host "Manage app-owned top-level File Explorer context menu extension profiles."
    Write-Host ""
    Write-Host "The default 'My Tools' entry is managed by Register-DebugPackage.ps1 and tools.jsonc."
    Write-Host "This script is for optional additional top-level entries backed by modular JSONC includes."
    Write-Host ""
    Write-Host "Actions:"
    Write-Host "  List         Show extension profiles created by this script."
    Write-Host "  ListPresets  Show built-in presets that can be promoted to top-level entries."
    Write-Host "  Add          Create/register a separate top-level entry."
    Write-Host "  Ensure       Create or update a separate top-level entry."
    Write-Host "  Remove       Unregister and remove a profile."
    Write-Host "  Refresh      Regenerate profile config snapshots and re-register profile packages."
    Write-Host "  ScanExternal Find non-project MSIX/AppX context menu packages that can be removed."
    Write-Host "  RemoveExternal Remove one external package found by ScanExternal."
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\scripts\Manage-ContextMenuExtensions.ps1"
    Write-Host "  .\scripts\Manage-ContextMenuExtensions.ps1 -Action ListPresets"
    Write-Host "  .\scripts\Manage-ContextMenuExtensions.ps1 -Action Add -Preset 7Zip"
    Write-Host "  .\scripts\Manage-ContextMenuExtensions.ps1 -Action Add -Preset NotepadPlusPlus"
    Write-Host "  .\scripts\Manage-ContextMenuExtensions.ps1 -Action Add -Preset SuperDelete -Targets files"
    Write-Host "  .\scripts\Manage-ContextMenuExtensions.ps1 -Action Add -Id archive-tools -Title `"Archive Tools`" -Include `"..\Presets\7zip.jsonc`" -Icon `"%ProgramFiles%\7-Zip\7zFM.exe`""
    Write-Host "  .\scripts\Manage-ContextMenuExtensions.ps1 -Action Refresh -Id 7zip"
    Write-Host "  .\scripts\Manage-ContextMenuExtensions.ps1 -Action Remove -Id 7zip"
    Write-Host "  .\scripts\Manage-ContextMenuExtensions.ps1 -Action ScanExternal"
    Write-Host "  .\scripts\Manage-ContextMenuExtensions.ps1 -Action RemoveExternal -ExternalPackageFullName `"Package_1.0.0.0_x64__publisherid`""
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  -Preset       Convenience setup for 7Zip or NotepadPlusPlus. Preset names are accepted case-insensitively."
    Write-Host "  -Targets      Any of: files, folders, backgrounds. Defaults to all three."
    Write-Host "  -Architecture Build architecture for generated debug packages. Defaults to native OS architecture."
    Write-Host "  -PerformanceVerb Enabled or Disabled. Controls whether the load-time informational menu item is built in."
    Write-Host "  -DeferRegistration Save an Add/Ensure profile without registering its package yet."
    Write-Host "  -ExternalPackageFullName PackageFullName from ScanExternal to remove with RemoveExternal."
    Write-Host ""
    Write-Host "Generated profile configs are stored under:"
    Write-Host "  $ExtensionsDir"
}

function Get-AvailablePresets {
    $known = @(
        [pscustomobject]@{
            Preset = "7zip"
            Title = "7-Zip"
            Include = "..\Presets\7zip.jsonc"
            Description = "Promotes the 7-Zip legacy context menu preset."
        },
        [pscustomobject]@{
            Preset = "notepadplusplus"
            Title = "Notepad++"
            Include = "..\Presets\notepadplusplus.jsonc"
            Description = "Promotes the Notepad++ edit command preset."
        },
        [pscustomobject]@{
            Preset = "superdelete"
            Title = "Super Delete"
            Include = "..\Presets\superdelete.jsonc"
            Description = "Promotes lock-aware file deletion helpers."
        }
    )

    $presetDir = Join-Path $RepoRoot "config\presets"
    $files = @()
    if (Test-Path -LiteralPath $presetDir) {
        $files = Get-ChildItem -LiteralPath $presetDir -Filter "*.jsonc" | ForEach-Object {
            [pscustomobject]@{
                Preset = ""
                Title = $_.BaseName
                Include = "..\Presets\$($_.Name)"
                Description = "Modular JSONC preset file."
            }
        }
    }

    $known + @($files | Where-Object { $known.Include -notcontains $_.Include })
}

function Write-EmptyListHelp {
    Write-Host "No app-owned top-level context menu extension profiles are registered."
    Write-Host ""
    Write-Host "The default 'My Tools' entry is still managed by Register-DebugPackage.ps1 and tools.jsonc."
    Write-Host "Use this script when you want an additional top-level entry, for example 7-Zip."
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\scripts\Manage-ContextMenuExtensions.ps1 -Action Add -Preset 7Zip"
    Write-Host "  .\scripts\Manage-ContextMenuExtensions.ps1 -Action Add -Preset NotepadPlusPlus"
    Write-Host "  .\scripts\Manage-ContextMenuExtensions.ps1 -Action Add -Preset SuperDelete -Targets files"
    Write-Host "  .\scripts\Manage-ContextMenuExtensions.ps1 -Action Add -Id archive-tools -Title `"Archive Tools`" -Include `"..\Presets\7zip.jsonc`""
}

function New-ProfileClsid([int]$Slot, [string]$Kind) {
    $suffix = if ($Kind -eq "Background") { "5E" } else { "5D" }
    "CB098F2B-3127-44A2-B301-580F6984{0:X2}{1}" -f $Slot, $suffix
}

function Get-NextSlot($Items) {
    $used = @{}
    foreach ($item in $Items) { $used[[int]$item.slot] = $true }
    for ($slot = 1; $slot -le 127; $slot++) {
        if (!$used.ContainsKey($slot)) { return $slot }
    }
    throw "No extension profile slots are available."
}

function Ensure-Build {
    $settingsPath = Join-Path $BuildDir "build-settings.json"
    $settingsMatch = $false
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
            $settingsMatch = $settings.performanceVerb -eq $PerformanceVerb
        } catch {
            $settingsMatch = $false
        }
    }
    if (!(Test-Path (Join-Path $BuildDir "MyContextMenuToolsExplorerCommand.dll")) -or !(Test-Path (Join-Path $BuildDir "MyContextMenuTools.exe")) -or !$settingsMatch) {
        & (Join-Path $PSScriptRoot "Build.ps1") -Architecture $Architecture -PerformanceVerb $PerformanceVerb
    }
}

function Update-ProfileSnapshot($Entry) {
    & (Join-Path $PSScriptRoot "Update-CompiledConfigSnapshot.ps1") -ConfigPath $Entry.configPath
}

function Get-CompiledSnapshotPath([string]$ConfigPath) {
    $directory = Split-Path -Parent $ConfigPath
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
    Join-Path $directory "$stem.compiled.json"
}

function Get-PresetDefaults {
    param([string]$PresetName)

    if ($PresetName -ieq "7Zip") {
        return [pscustomobject]@{
            Id = "7zip"
            Title = "7-Zip"
            Include = "..\\Presets\\7zip.jsonc"
            Icon = "%ProgramFiles%\\7-Zip\\7zFM.exe"
        }
    }

    if ($PresetName -ieq "NotepadPlusPlus") {
        return [pscustomobject]@{
            Id = "notepadplusplus"
            Title = "Notepad++"
            Include = "..\\Presets\\notepadplusplus.jsonc"
            Icon = "%ProgramFiles%\\Notepad++\\notepad++.exe"
        }
    }

    if ($PresetName -ieq "SuperDelete") {
        return [pscustomobject]@{
            Id = "superdelete"
            Title = "Super Delete"
            Include = "..\\Presets\\superdelete.jsonc"
            Icon = "__appicon"
        }
    }

    $null
}

function Ensure-RepoPresetInstalled([string]$PresetFileName) {
    $source = Join-Path $RepoRoot "config\presets\$PresetFileName"
    if (!(Test-Path -LiteralPath $source -PathType Leaf)) {
        return
    }

    $targetDir = Join-Path $ConfigRoot "Presets"
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    Copy-Item -Force -LiteralPath $source -Destination (Join-Path $targetDir $PresetFileName)
}

function Ensure-PresetInstalled {
    param(
        [string]$PresetName,
        [ref]$IconValue
    )

    if ($PresetName -ieq "7Zip") {
        & (Join-Path $PSScriptRoot "Ensure-AppContextMenuPresets.ps1") -Apps "7-Zip" -Mode InstallOnly | Out-Host
        $presetPath = Join-Path $ConfigRoot "Presets\7zip.jsonc"
    } elseif ($PresetName -ieq "NotepadPlusPlus") {
        & (Join-Path $PSScriptRoot "Ensure-AppContextMenuPresets.ps1") -Apps "Notepad++" -Mode InstallOnly | Out-Host
        $presetPath = Join-Path $ConfigRoot "Presets\notepadplusplus.jsonc"
    } else {
        if ($PresetName -ieq "SuperDelete") {
            Ensure-RepoPresetInstalled "superdelete.jsonc"
        }
        return
    }

    if (Test-Path -LiteralPath $presetPath) {
        $presetRaw = Get-Content -Raw -LiteralPath $presetPath
        $iconMatch = [regex]::Match($presetRaw, '"icon"\s*:\s*"([^"]+)"')
        if ($iconMatch.Success) {
            $IconValue.Value = $iconMatch.Groups[1].Value
        }
    }
}

function Write-ProfileConfig($Entry) {
    New-Item -ItemType Directory -Force -Path $ExtensionsDir | Out-Null
    $title = ConvertTo-JsonStringLiteral $Entry.title
    $tooltip = ConvertTo-JsonStringLiteral "Commands from My Context Menu Tools profile '$($Entry.id)'"
    $include = ConvertTo-JsonStringLiteral $Entry.include
    $iconValue = ConvertTo-JsonStringLiteral $Entry.icon
    $content = @"
{
  "menuTitle": $title,
  "menuTooltip": $tooltip,
  "menuIcon": $iconValue,
  "items": [
    {
      "include": $include
    }
  ]
}
"@
    Set-Content -LiteralPath $Entry.configPath -Value $content -Encoding UTF8
}

function New-Manifest([object]$Entry, [string]$PackageDir) {
    $titleXml = ConvertTo-XmlLiteral $Entry.title
    $selectionItems = ""
    if ($Entry.targets -contains "files") {
        $selectionItems += "            <desktop5:ItemType Type=`"*`">`r`n              <desktop5:Verb Id=`"$($Entry.verbPrefix)Files`" Clsid=`"$($Entry.selectionClsid)`" />`r`n            </desktop5:ItemType>`r`n"
    }
    if ($Entry.targets -contains "folders") {
        $selectionItems += "            <desktop5:ItemType Type=`"Directory`">`r`n              <desktop5:Verb Id=`"$($Entry.verbPrefix)Folders`" Clsid=`"$($Entry.selectionClsid)`" />`r`n            </desktop5:ItemType>`r`n"
    }
    if ($Entry.targets -contains "backgrounds") {
        $selectionItems += "            <desktop5:ItemType Type=`"Directory\Background`">`r`n              <desktop5:Verb Id=`"$($Entry.verbPrefix)Background`" Clsid=`"$($Entry.backgroundClsid)`" />`r`n            </desktop5:ItemType>`r`n"
    }

    $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package
  xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
  xmlns:uap10="http://schemas.microsoft.com/appx/manifest/uap/windows10/10"
  xmlns:com="http://schemas.microsoft.com/appx/manifest/com/windows10"
  xmlns:desktop4="http://schemas.microsoft.com/appx/manifest/desktop/windows10/4"
  xmlns:desktop5="http://schemas.microsoft.com/appx/manifest/desktop/windows10/5"
  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
  IgnorableNamespaces="uap uap10 com desktop4 desktop5 rescap">
  <Identity Name="$($Entry.packageName)" Publisher="CN=xandfis" Version="0.1.0.0" />
  <Properties>
    <DisplayName>$titleXml</DisplayName>
    <PublisherDisplayName>xandfis</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.18362.0" MaxVersionTested="10.0.26200.0" />
  </Dependencies>
  <Resources>
    <Resource Language="en-us" />
  </Resources>
  <Applications>
    <Application Id="$($Entry.verbPrefix)" Executable="MyContextMenuTools.exe" EntryPoint="Windows.FullTrustApplication" uap10:TrustLevel="mediumIL" uap10:RuntimeBehavior="packagedClassicApp">
      <uap:VisualElements DisplayName="$titleXml" Description="My Context Menu Tools extension profile" BackgroundColor="transparent" Square150x150Logo="Assets\MedTile.png" Square44x44Logo="Assets\Square44x44Logo.png">
        <uap:DefaultTile Wide310x150Logo="Assets\WideTile.png" />
      </uap:VisualElements>
      <Extensions>
        <com:Extension Category="windows.comServer">
          <com:ComServer>
            <com:SurrogateServer DisplayName="$titleXml">
              <com:Class Id="$($Entry.selectionClsid)" Path="MyContextMenuToolsExplorerCommand.dll" ThreadingModel="STA" />
              <com:Class Id="$($Entry.backgroundClsid)" Path="MyContextMenuToolsExplorerCommand.dll" ThreadingModel="STA" />
            </com:SurrogateServer>
          </com:ComServer>
        </com:Extension>
        <desktop4:Extension Category="windows.fileExplorerContextMenus">
          <desktop4:FileExplorerContextMenus>
$selectionItems          </desktop4:FileExplorerContextMenus>
        </desktop4:Extension>
      </Extensions>
    </Application>
  </Applications>
  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
  </Capabilities>
</Package>
"@
    Set-Content -LiteralPath (Join-Path $PackageDir "Package.appxmanifest") -Value $manifest -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $PackageDir "appxmanifest.xml") -Value $manifest -Encoding UTF8
}

function Get-AppxManifestPath($Package) {
    if (!$Package.InstallLocation) { return "" }
    foreach ($fileName in @("AppxManifest.xml", "appxmanifest.xml", "Package.appxmanifest")) {
        $path = Join-Path $Package.InstallLocation $fileName
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    ""
}

function Test-ProjectOwnedPackage($Package) {
    $Package.Name -eq "MyContextMenuTools" -or
        $Package.Name -like "MyContextMenuTools.Extension.*" -or
        $Package.PackageFullName -like "MyContextMenuTools*"
}

function Get-ManifestAttribute([System.Xml.XmlNode]$Node, [string]$Name) {
    $attribute = $Node.Attributes | Where-Object { $_.LocalName -eq $Name } | Select-Object -First 1
    if ($attribute) { return $attribute.Value }
    ""
}

function Get-ExternalContextMenuPackages {
    $packages = @(Get-AppxPackage -ErrorAction Stop)
    foreach ($package in $packages) {
        if (Test-ProjectOwnedPackage $package) { continue }

        $manifestPath = Get-AppxManifestPath $package
        if (!$manifestPath) { continue }

        try {
            [xml]$manifest = Get-Content -Raw -LiteralPath $manifestPath
        } catch {
            Write-Warning "Could not read manifest for $($package.PackageFullName): $($_.Exception.Message)"
            continue
        }

        $extensions = @($manifest.SelectNodes("//*[local-name()='Extension' and @Category='windows.fileExplorerContextMenus']"))
        if ($extensions.Count -eq 0) { continue }

        $targets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $verbs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($extension in $extensions) {
            foreach ($itemType in @($extension.SelectNodes(".//*[local-name()='ItemType']"))) {
                $type = Get-ManifestAttribute $itemType "Type"
                if ($type) { [void]$targets.Add($type) }
            }
            foreach ($verb in @($extension.SelectNodes(".//*[local-name()='Verb']"))) {
                $id = Get-ManifestAttribute $verb "Id"
                if ($id) { [void]$verbs.Add($id) }
            }
        }

        $removeCommand = ".\scripts\Manage-ContextMenuExtensions.ps1 -Action RemoveExternal -ExternalPackageFullName " + (ConvertTo-PowerShellSingleQuotedLiteral $package.PackageFullName)
        [pscustomobject]@{
            name = $package.Name
            packageFullName = $package.PackageFullName
            publisher = $package.Publisher
            version = $package.Version
            architecture = $package.Architecture
            targets = @($targets) -join ", "
            verbs = @($verbs) -join ", "
            installLocation = $package.InstallLocation
            manifestPath = $manifestPath
            removeCommand = $removeCommand
        }
    }
}

function Get-ExternalContextMenuPackageToRemove([string]$PackageFullName, [object[]]$Candidates) {
    $candidate = $Candidates | Where-Object { $_.packageFullName -ieq $PackageFullName } | Select-Object -First 1
    if (!$candidate) {
        throw "External MSIX/AppX context menu package was not found by ScanExternal: $PackageFullName"
    }
    if ($candidate.name -eq "MyContextMenuTools" -or $candidate.name -like "MyContextMenuTools.Extension.*") {
        throw "Refusing to remove a My Context Menu Tools package with RemoveExternal. Use Remove or Unregister-DebugPackage.ps1 for project-owned entries."
    }

    $candidate
}

function Register-EntryPackage($Entry) {
    if (!(Get-Command winapp.exe -ErrorAction SilentlyContinue)) {
        throw "The winapp CLI was not found. Run scripts\Install-BuildPrerequisites.ps1."
    }

    Ensure-Build
    Update-ProfileSnapshot $Entry
    $packageDir = Join-Path $BuildDir "extensions\$($Entry.id)\package"
    Remove-Item -Recurse -Force $packageDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
    New-Manifest $Entry $packageDir
    Copy-Item -Force -LiteralPath (Join-Path $BuildDir "MyContextMenuToolsExplorerCommand.dll") -Destination (Join-Path $packageDir "MyContextMenuToolsExplorerCommand.dll")
    Copy-Item -Force -LiteralPath (Join-Path $BuildDir "MyContextMenuTools.exe") -Destination (Join-Path $packageDir "MyContextMenuTools.exe")
    Copy-Item -Recurse -Force -LiteralPath (Join-Path $RepoRoot "Assets") -Destination (Join-Path $packageDir "Assets")
    New-PackageSquare44Logo -Icon $Entry.icon -PackageDir $packageDir -RepoRoot $RepoRoot

    $existing = Get-AppxPackage -Name $Entry.packageName -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-AppxPackage -Package $existing.PackageFullName -ErrorAction Stop
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $packageDir ".winapp") | Out-Null
    Push-Location -LiteralPath $packageDir
    try {
        winapp create-debug-identity (Join-Path $packageDir "MyContextMenuTools.exe") --manifest (Join-Path $packageDir "Package.appxmanifest") --keep-identity
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to register extension package $($Entry.packageName)."
    }

    $registeredPackage = Get-AppxPackage -Name $Entry.packageName -ErrorAction Stop
    $registeredPackageDir = $registeredPackage.InstallLocation
    if ($registeredPackageDir -ne $packageDir) {
        Copy-Item -Force -LiteralPath (Join-Path $packageDir "Package.appxmanifest") -Destination (Join-Path $registeredPackageDir "Package.appxmanifest")
        Copy-Item -Force -LiteralPath (Join-Path $packageDir "appxmanifest.xml") -Destination (Join-Path $registeredPackageDir "appxmanifest.xml")
        Remove-Item -Recurse -Force (Join-Path $registeredPackageDir "Assets") -ErrorAction SilentlyContinue
        Copy-Item -Recurse -Force -LiteralPath (Join-Path $packageDir "Assets") -Destination (Join-Path $registeredPackageDir "Assets")
        New-PackageSquare44Logo -Icon $Entry.icon -PackageDir $registeredPackageDir -RepoRoot $RepoRoot
        Copy-Item -Force -LiteralPath (Join-Path $packageDir "MyContextMenuToolsExplorerCommand.dll") -Destination (Join-Path $registeredPackageDir "MyContextMenuToolsExplorerCommand.dll")
        Copy-Item -Force -LiteralPath (Join-Path $packageDir "MyContextMenuTools.exe") -Destination (Join-Path $registeredPackageDir "MyContextMenuTools.exe")
    }
}

$items = @(Get-Registry)

if ($Help) {
    Write-HelpText
    return
}

if ($Action -eq "ListPresets") {
    Get-AvailablePresets | Format-Table -AutoSize
    return
}

if ($Action -eq "ScanExternal") {
    $externalCandidates = @(Get-ExternalContextMenuPackages)
    if ($externalCandidates.Count -eq 0) {
        Write-Host "No removable non-project MSIX/AppX context menu packages were found."
        return
    }

    $externalCandidates |
        Select-Object name, version, architecture, targets, verbs, packageFullName, removeCommand |
        Format-List
    Write-Host ""
    Write-Host "To remove one package, rerun with -Action RemoveExternal -ExternalPackageFullName set to its packageFullName."
    return
}

if ($Action -eq "RemoveExternal") {
    if (!$ExternalPackageFullName) { throw "-ExternalPackageFullName is required for RemoveExternal." }
    $externalCandidates = @(Get-ExternalContextMenuPackages)
    $candidate = Get-ExternalContextMenuPackageToRemove $ExternalPackageFullName $externalCandidates
    Remove-AppxPackage -Package $candidate.packageFullName -ErrorAction Stop
    Write-Host "Removed external context menu package '$($candidate.packageFullName)'."
    return
}

if ($Action -eq "List") {
    if ($NoParameters) {
        Write-Host "Tip: run .\scripts\Manage-ContextMenuExtensions.ps1 -Help for full instructions."
        Write-Host ""
    }
    if ($items.Count -eq 0) {
        Write-EmptyListHelp
        return
    }
    $items | Select-Object id, title, slot, packageName, targets, configPath | Format-Table -AutoSize
    return
}

if ($Action -eq "Refresh") {
    $profiles = if ($Id) {
        @($items | Where-Object { $_.id -ieq $Id })
    } else {
        @($items)
    }
    if ($profiles.Count -eq 0) {
        if ($Id) {
            throw "Extension profile '$Id' was not found."
        }
        Write-EmptyListHelp
        return
    }

    foreach ($entry in $profiles) {
        Write-ProfileConfig $entry
        Register-EntryPackage $entry
        Write-Host "Refreshed extension profile '$($entry.id)'."
    }
    return
}

if ($Action -eq "Remove") {
    if (!$Id) { throw "-Id is required for Remove." }
    $entry = $items | Where-Object { $_.id -ieq $Id } | Select-Object -First 1
    if (!$entry) { throw "Extension profile '$Id' was not found." }
    $existing = Get-AppxPackage -Name $entry.packageName -ErrorAction SilentlyContinue
    if ($existing) {
        try {
            Remove-AppxPackage -Package $existing.PackageFullName -ErrorAction Stop
        } catch {
            Write-Warning "Could not unregister package '$($entry.packageName)': $($_.Exception.Message)"
            Write-Warning "Removing local profile state anyway. If the package remains registered, remove it later with Remove-AppxPackage."
        }
    }
    $items = @($items | Where-Object { $_.id -ine $entry.id })
    Remove-Item -Force -LiteralPath (Get-CompiledSnapshotPath $entry.configPath) -ErrorAction SilentlyContinue
    Save-Registry $items
    Write-Host "Removed extension profile '$($entry.id)'."
    return
}

if ($Action -eq "Add" -or $Action -eq "Ensure") {
    $defaults = Get-PresetDefaults $Preset
    if ($defaults) {
        if (!$Id) { $Id = $defaults.Id }
        if (!$Title) { $Title = $defaults.Title }
        if (!$Include) { $Include = $defaults.Include }
        if ($Icon -eq "__appicon") { $Icon = $defaults.Icon }
    }

    if (!$Id -or !$Title -or !$Include) {
        throw "$Action requires -Id, -Title, and -Include, or use -Preset 7Zip / -Preset NotepadPlusPlus."
    }
    $existingEntry = $items | Where-Object { $_.id -ieq $Id } | Select-Object -First 1
    if ($existingEntry -and $Action -eq "Add") {
        throw "Extension profile '$Id' already exists. Remove it first or choose a different -Id."
    }

    Ensure-PresetInstalled $Preset ([ref]$Icon)

    if ($existingEntry) {
        $existingEntry.title = $Title
        $existingEntry.include = $Include
        $existingEntry.icon = $Icon
        $existingEntry.targets = @($Targets)
        Write-ProfileConfig $existingEntry
        if (!$DeferRegistration) {
            Register-EntryPackage $existingEntry
        }
        Save-Registry $items
        Write-Host "Ensured extension profile '$Id' as top-level '$Title'."
        return
    }

    $safeId = ConvertTo-SafeId $Id
    $slot = Get-NextSlot $items
    $entry = [pscustomobject]@{
        id = $Id
        safeId = $safeId
        verbPrefix = "Extension$safeId"
        title = $Title
        include = $Include
        icon = $Icon
        slot = $slot
        targets = @($Targets)
        packageName = "MyContextMenuTools.Extension.$safeId"
        selectionClsid = New-ProfileClsid $slot "Selection"
        backgroundClsid = New-ProfileClsid $slot "Background"
        configPath = Join-Path $ExtensionsDir ("slot-{0:x2}.jsonc" -f $slot)
    }
    Write-ProfileConfig $entry
    if (!$DeferRegistration) {
        Register-EntryPackage $entry
    }
    Save-Registry (@($items) + $entry)
    $verb = if ($Action -eq "Ensure") { "Ensured" } else { "Added" }
    Write-Host "$verb extension profile '$Id' as top-level '$Title'."
    return
}
