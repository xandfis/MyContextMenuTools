# Copyright (c) My Context Menu Tools contributors.
# Licensed under the MIT License.

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA "MyContextMenuTools\tools.jsonc"),
    [switch]$OfferFixes
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

function Expand-CommandPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    [Environment]::ExpandEnvironmentVariables($Path)
}

function Resolve-ConfigRelativePath([string]$Path, [string]$BaseDirectory) {
    $expanded = Expand-CommandPath $Path
    if ([System.IO.Path]::IsPathRooted($expanded)) { return $expanded }
    Join-Path $BaseDirectory $expanded
}

function ConvertFrom-JsoncFile([string]$Path) {
    $raw = Get-Content -Raw -LiteralPath $Path
    $json = Remove-JsonComments $raw
    $json | ConvertFrom-Json -Depth 50
}

function Get-IncludeValues($Item) {
    $property = $Item.PSObject.Properties["include"]
    if (!$property) { $property = $Item.PSObject.Properties["`$include"] }
    if (!$property) { return @() }

    if ($property.Value -is [array]) { return @($property.Value) }
    @($property.Value)
}

function Expand-ConfigItems($Items, [string]$BaseDirectory, [int]$Depth = 8) {
    if ($Depth -le 0) { return @() }

    $expanded = @()
    foreach ($item in $Items) {
        $includeValues = @(Get-IncludeValues $item)
        if ($includeValues.Count -gt 0) {
            foreach ($include in $includeValues) {
                $includePath = Resolve-ConfigRelativePath ([string]$include) $BaseDirectory
                if (!(Test-Path -LiteralPath $includePath)) {
                    throw "Included config file not found: $includePath"
                }
                $included = ConvertFrom-JsoncFile $includePath
                $includeBase = Split-Path -Parent $includePath
                if ($included -is [array]) {
                    $expanded += Expand-ConfigItems $included $includeBase ($Depth - 1)
                } elseif ($included.items) {
                    $expanded += Expand-ConfigItems $included.items $includeBase ($Depth - 1)
                } else {
                    $expanded += $included
                }
            }
            continue
        }

        if ($item.children) {
            $item.children = @(Expand-ConfigItems $item.children $BaseDirectory $Depth)
        }
        $expanded += $item
    }
    $expanded
}

function Find-KnownExecutable([string]$Command) {
    $expanded = Expand-CommandPath $Command
    if (Test-Path -LiteralPath $expanded -PathType Leaf) { return $expanded }

    $fileName = Split-Path -Leaf $expanded
    if (!$fileName) { $fileName = $expanded }

    $candidates = @()
    if ($fileName -ieq "7zFM.exe" -or $fileName -ieq "7zG.exe" -or $fileName -ieq "7z.exe") {
        $candidates += Join-Path $env:ProgramFiles "7-Zip\$fileName"
        if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} "7-Zip\$fileName" }
    }
    if ($fileName -ieq "notepad++.exe") {
        $candidates += Join-Path $env:ProgramFiles "Notepad++\notepad++.exe"
        if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} "Notepad++\notepad++.exe" }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $fromPath = Get-Command $fileName -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if ($fromPath) { return $fromPath }
    $null
}

function Get-ToolItems($Items, [string]$Prefix = "") {
    foreach ($item in $Items) {
        if ($item.type -ieq "separator" -or $item.type -ieq "divider" -or $item.separator -eq $true) {
            continue
        }
        $name = if ($Prefix) { "$Prefix > $($item.title)" } else { $item.title }
        if ($item.command) {
            [pscustomobject]@{ Name = $name; Item = $item }
        }
        if ($item.children) {
            Get-ToolItems $item.children $name
        }
    }
}

if (!(Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath. Run scripts\Install-DefaultConfig.ps1 first."
}

$raw = Get-Content -Raw -LiteralPath $ConfigPath
$config = ConvertFrom-JsoncFile $ConfigPath
$items = Expand-ConfigItems $config.items (Split-Path -Parent $ConfigPath)

$problems = @()
foreach ($entry in Get-ToolItems $items) {
    $command = [string]$entry.Item.command
    $expanded = Expand-CommandPath $command
    $isPathLike = $expanded.Contains('\') -or $expanded.Contains('/') -or [System.IO.Path]::IsPathRooted($expanded)
    $found = Find-KnownExecutable $command
    if (!$found) {
        $problems += [pscustomobject]@{ Tool = $entry.Name; Command = $command; Status = "NotFound"; Suggested = "" }
        continue
    }

    if ($isPathLike -and $expanded -ne $found -and (Split-Path -Leaf $expanded) -ieq (Split-Path -Leaf $found)) {
        $problems += [pscustomobject]@{ Tool = $entry.Name; Command = $command; Status = "PathMismatch"; Suggested = $found }
    }
}

if (!$problems) {
    Write-Host "Config is valid and all configured executables were found."
    exit 0
}

$problems | Format-Table -AutoSize

if (!$OfferFixes) {
    exit 1
}

foreach ($problem in $problems) {
    if ($problem.Status -eq "PathMismatch" -and $problem.Suggested) {
        $answer = Read-Host "Update '$($problem.Command)' to '$($problem.Suggested)'? [y/N]"
        if ($answer -match '^(y|yes)$') {
            $raw = $raw.Replace($problem.Command.Replace('\', '\\'), $problem.Suggested.Replace('\', '\\'))
            $raw = $raw.Replace($problem.Command, $problem.Suggested)
        }
    } elseif ($problem.Status -eq "NotFound") {
        $path = Read-Host "Enter path for '$($problem.Command)' or press Enter to skip"
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $raw = $raw.Replace($problem.Command.Replace('\', '\\'), $path.Replace('\', '\\'))
            $raw = $raw.Replace($problem.Command, $path)
        }
    }
}

Set-Content -LiteralPath $ConfigPath -Value $raw -Encoding UTF8
Write-Host "Updated $ConfigPath"
