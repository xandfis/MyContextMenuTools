# Copyright (c) My Context Menu Tools contributors.
# Licensed under the MIT License.

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA "MyContextMenuTools\tools.jsonc"),
    [string]$SnapshotPath
)

$ErrorActionPreference = "Stop"

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

function ConvertFrom-JsoncFile([string]$Path) {
    $raw = Get-Content -Raw -LiteralPath $Path
    (Remove-JsonComments $raw) | ConvertFrom-Json -Depth 100
}

function Expand-CommandPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    [Environment]::ExpandEnvironmentVariables($Path)
}

function Resolve-ConfigRelativePath([string]$Path, [string]$BaseDirectory) {
    $expanded = Expand-CommandPath $Path
    if ([System.IO.Path]::IsPathRooted($expanded)) { return $expanded }
    Join-Path $BaseDirectory $expanded
}

function Get-DefaultSnapshotPath([string]$Path) {
    $directory = Split-Path -Parent $Path
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    Join-Path $directory "$stem.compiled.json"
}

function Get-FileStamp([string]$Path) {
    ([System.IO.File]::GetLastWriteTimeUtc($Path)).ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Add-Source([string]$Path, [System.Collections.Specialized.OrderedDictionary]$Sources) {
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if (!$Sources.Contains($resolved)) {
        $Sources[$resolved] = Get-FileStamp $resolved
    }
    $resolved
}

function Get-IncludeValues($Item) {
    $property = $Item.PSObject.Properties["include"]
    if (!$property) { $property = $Item.PSObject.Properties["`$include"] }
    if (!$property) { return @() }
    if ($property.Value -is [array]) { return @($property.Value) }
    @($property.Value)
}

function Convert-JsonValue($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return [string]$Value }
    if ($Value -is [array]) {
        return @($Value | ForEach-Object { Convert-JsonValue $_ })
    }
    if ($Value -is [pscustomobject]) {
        $object = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $object[$property.Name] = Convert-JsonValue $property.Value
        }
        return $object
    }
    $Value
}

function Convert-CompiledItems($Items, [string]$BaseDirectory, [int]$Depth, [System.Collections.Specialized.OrderedDictionary]$Sources) {
    if ($Depth -le 0 -or !$Items) { return @() }

    $compiled = @()
    foreach ($item in @($Items)) {
        $includeValues = @(Get-IncludeValues $item)
        if ($includeValues.Count -gt 0) {
            foreach ($include in $includeValues) {
                $includePath = Resolve-ConfigRelativePath ([string]$include) $BaseDirectory
                $resolvedInclude = Add-Source $includePath $Sources
                $included = ConvertFrom-JsoncFile $resolvedInclude
                $includeBase = Split-Path -Parent $resolvedInclude
                if ($included -is [array]) {
                    $compiled += Convert-CompiledItems $included $includeBase ($Depth - 1) $Sources
                } elseif ($included.PSObject.Properties["items"]) {
                    $compiled += Convert-CompiledItems $included.items $includeBase ($Depth - 1) $Sources
                } else {
                    $compiled += Convert-CompiledItems @($included) $includeBase ($Depth - 1) $Sources
                }
            }
            continue
        }

        $object = [ordered]@{}
        foreach ($property in $item.PSObject.Properties) {
            if ($property.Name -eq "include" -or $property.Name -eq "`$include") {
                continue
            }
            if ($property.Name -eq "children") {
                $object[$property.Name] = @(Convert-CompiledItems $property.Value $BaseDirectory $Depth $Sources)
            } else {
                $object[$property.Name] = Convert-JsonValue $property.Value
            }
        }
        $compiled += $object
    }
    $compiled
}

if (!(Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath. Run scripts\Install-DefaultConfig.ps1 first."
}

$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
if (!$SnapshotPath) {
    $SnapshotPath = Get-DefaultSnapshotPath $ConfigPath
}

$sources = [ordered]@{}
Add-Source $ConfigPath $sources | Out-Null
$config = ConvertFrom-JsoncFile $ConfigPath
$configBase = Split-Path -Parent $ConfigPath

$compiledConfig = [ordered]@{}
foreach ($name in @("menuTitle", "menuTooltip", "menuIcon")) {
    $property = $config.PSObject.Properties[$name]
    if ($property) {
        $compiledConfig[$name] = $property.Value
    }
}
$compiledConfig["items"] = @(Convert-CompiledItems $config.items $configBase 8 $sources)

$snapshot = [ordered]@{
    format = "MyContextMenuTools.CompiledConfig.v1"
    sources = @($sources.GetEnumerator() | ForEach-Object {
        [ordered]@{
            path = $_.Key
            lastWriteTime = $_.Value
        }
    })
    config = $compiledConfig
}

$snapshotDirectory = Split-Path -Parent $SnapshotPath
New-Item -ItemType Directory -Force -Path $snapshotDirectory | Out-Null
$snapshot | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $SnapshotPath -Encoding UTF8
Write-Host "Updated compiled config snapshot at $SnapshotPath"
