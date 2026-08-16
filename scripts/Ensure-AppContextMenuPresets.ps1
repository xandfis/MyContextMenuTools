# Copyright (c) My Context Menu Tools contributors.
# Licensed under the MIT License.

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA "MyContextMenuTools\tools.jsonc"),

    [ValidateSet("All", "7Zip", "7-Zip", "NotepadPlusPlus", "Notepad++")]
    [string[]]$Apps = @("All"),

    [ValidateSet("AddToMyTools", "InstallOnly", "RemoveFromMyTools")]
    [string]$Mode = "AddToMyTools",

    [switch]$PassThru
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$SourcePresetDir = Join-Path $RepoRoot "config\presets"
$ConfigDir = Split-Path -Parent $ConfigPath
$TargetPresetDir = Join-Path $ConfigDir "Presets"

function ConvertTo-JsonPathLiteral([string]$Path) {
    $Path.Replace('\', '\\')
}

function Remove-JsonComments([string]$Text) {
    $output = [System.Text.StringBuilder]::new()
    $inString = $false
    $escaped = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($inString) {
            [void]$output.Append($ch)
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
            continue
        }
        if ($ch -eq '"') {
            $inString = $true
            [void]$output.Append($ch)
            continue
        }
        if ($ch -eq '/' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '/') {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
            if ($i -lt $Text.Length) { [void]$output.Append($Text[$i]) }
            continue
        }
        if ($ch -eq '/' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '*') {
            $i += 2
            while ($i + 1 -lt $Text.Length -and !($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) {
                if ($Text[$i] -eq "`n") { [void]$output.Append("`n") }
                $i++
            }
            $i++
            continue
        }
        [void]$output.Append($ch)
    }
    $output.ToString()
}

function Find-Executable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [string[]]$CandidateDirectories = @()
    )

    foreach ($directory in $CandidateDirectories) {
        if (!$directory) { continue }
        $candidate = Join-Path $directory $FileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $fromPath = Get-Command $FileName -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if ($fromPath -and (Test-Path -LiteralPath $fromPath -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $fromPath).Path
    }

    $null
}

function Get-7ZipInstall {
    $directories = @(
        (Join-Path $env:ProgramFiles "7-Zip")
    )
    if (${env:ProgramFiles(x86)}) {
        $directories += Join-Path ${env:ProgramFiles(x86)} "7-Zip"
    }

    $fileManager = Find-Executable "7zFM.exe" $directories
    if (!$fileManager) { return $null }

    $directory = Split-Path -Parent $fileManager
    $gui = Join-Path $directory "7zG.exe"
    if (!(Test-Path -LiteralPath $gui -PathType Leaf)) { return $null }

    [pscustomobject]@{
        Name = "7-Zip"
        IncludePath = "Presets\\7zip.jsonc"
        SourcePreset = Join-Path $SourcePresetDir "7zip.jsonc"
        TargetPreset = Join-Path $TargetPresetDir "7zip.jsonc"
        InstallDirectory = $directory
        Token = "%ProgramFiles%\\7-Zip"
    }
}

function Get-NotepadPlusPlusInstall {
    $directories = @(
        (Join-Path $env:ProgramFiles "Notepad++")
    )
    if (${env:ProgramFiles(x86)}) {
        $directories += Join-Path ${env:ProgramFiles(x86)} "Notepad++"
    }

    $editor = Find-Executable "notepad++.exe" $directories
    if (!$editor) { return $null }

    [pscustomobject]@{
        Name = "Notepad++"
        IncludePath = "Presets\\notepadplusplus.jsonc"
        SourcePreset = Join-Path $SourcePresetDir "notepadplusplus.jsonc"
        TargetPreset = Join-Path $TargetPresetDir "notepadplusplus.jsonc"
        InstallDirectory = Split-Path -Parent $editor
        Token = "%ProgramFiles%\\Notepad++"
    }
}

function Install-PresetFile($Preset) {
    New-Item -ItemType Directory -Force -Path $TargetPresetDir | Out-Null
    $content = Get-Content -Raw -LiteralPath $Preset.SourcePreset
    $content = $content.Replace($Preset.Token, (ConvertTo-JsonPathLiteral $Preset.InstallDirectory))
    Set-Content -LiteralPath $Preset.TargetPreset -Value $content -Encoding UTF8
}

function Add-IncludeReference {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RawConfig,

        [Parameter(Mandatory = $true)]
        [string]$IncludePath
    )

    if ((Remove-JsonComments $RawConfig).Contains($IncludePath)) {
        return $RawConfig
    }

    $includeBlock = "    {`r`n      `"include`": `"$IncludePath`"`r`n    }"
    $beforeConfigShortcut = [regex]::new('(?ms)^    \{\r?\n      "type": "separator"\r?\n    \},\r?\n    \{\r?\n      "id": "open-tools-config"')
    if ($beforeConfigShortcut.IsMatch($RawConfig)) {
        $match = $beforeConfigShortcut.Match($RawConfig)
        return $RawConfig.Substring(0, $match.Index) + "$includeBlock,`r`n" + $match.Value + $RawConfig.Substring($match.Index + $match.Length)
    }

    $itemsStart = [regex]::new('(?ms)("items"\s*:\s*\[\s*)')
    if ($itemsStart.IsMatch($RawConfig)) {
        $match = $itemsStart.Match($RawConfig)
        return $RawConfig.Substring(0, $match.Index) + $match.Groups[1].Value + "`r`n$includeBlock," + $RawConfig.Substring($match.Index + $match.Length)
    }

    throw "Could not find an items array in $ConfigPath."
}

function Remove-IncludeReference {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RawConfig,

        [Parameter(Mandatory = $true)]
        [string]$IncludePath
    )

    $propertyPattern = '"(?:include|\$include)"'
    $pattern = '(?ms)^[ \t]*\{\s*' + $propertyPattern + '\s*:\s*"' + [regex]::Escape($IncludePath) + '"\s*\}\s*,?\r?\n'
    [regex]::Replace($RawConfig, $pattern, "")
}

if ($Mode -ne "InstallOnly") {
    if (!(Test-Path -LiteralPath $ConfigPath)) {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        Copy-Item -Force (Join-Path $RepoRoot "config\tools.jsonc") $ConfigPath
    }

    if (!(Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }
}

$selected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($app in $Apps) {
    if ($app -eq "All") {
        [void]$selected.Add("7Zip")
        [void]$selected.Add("NotepadPlusPlus")
    } elseif ($app -eq "7-Zip") {
        [void]$selected.Add("7Zip")
    } elseif ($app -eq "Notepad++") {
        [void]$selected.Add("NotepadPlusPlus")
    } else {
        [void]$selected.Add($app)
    }
}

$presets = @()
if ($selected.Contains("7Zip")) {
    $preset = Get-7ZipInstall
    if ($preset) { $presets += $preset } else { Write-Host "7-Zip was not found." }
}
if ($selected.Contains("NotepadPlusPlus")) {
    $preset = Get-NotepadPlusPlusInstall
    if ($preset) { $presets += $preset } else { Write-Host "Notepad++ was not found." }
}

if (!$presets) {
    Write-Host "No matching apps were found."
    return
}

$raw = if ($Mode -ne "InstallOnly") { Get-Content -Raw -LiteralPath $ConfigPath } else { "" }
foreach ($preset in $presets) {
    Install-PresetFile $preset
    if ($Mode -eq "AddToMyTools") {
        $raw = Add-IncludeReference $raw $preset.IncludePath
    } elseif ($Mode -eq "RemoveFromMyTools") {
        $updated = Remove-IncludeReference $raw $preset.IncludePath
        if ($updated -cne $raw) {
            Write-Host "Removed $($preset.Name) preset from My Tools."
        }
        $raw = $updated
    }
    Write-Host "Ensured $($preset.Name) preset at $($preset.TargetPreset)"
}

if ($Mode -ne "InstallOnly") {
    Set-Content -LiteralPath $ConfigPath -Value $raw -Encoding UTF8
    Write-Host "Updated $ConfigPath"
}

if ($PassThru) {
    $presets
}
