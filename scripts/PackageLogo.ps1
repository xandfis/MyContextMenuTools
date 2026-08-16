# Copyright (c) My Context Menu Tools contributors.
# Licensed under the MIT License.

$PackageSquare44LogoFileName = "Square44x44Logo.png"

function Resolve-PackageLogoIconPath {
    param(
        [string]$Icon,

        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $assetsDir = Join-Path $RepoRoot "Assets"
    if ([string]::IsNullOrWhiteSpace($Icon) -or $Icon -eq "__none" -or $Icon -eq "__default" -or $Icon -eq "__exe" -or $Icon -eq "__appicon") {
        return (Join-Path $assetsDir "AppIcon.ico")
    }
    if ($Icon -eq "__ico") {
        return (Join-Path $assetsDir "Extension.ico")
    }
    if ($Icon -eq "__png") {
        return (Join-Path $assetsDir "Extension.png")
    }
    if ($Icon -eq "__svg") {
        return (Join-Path $assetsDir "Extension.ico")
    }

    $path = [Environment]::ExpandEnvironmentVariables($Icon)
    $path = $path.Trim('"')

    if ([System.IO.Path]::GetExtension($path).Equals(".svg", [System.StringComparison]::OrdinalIgnoreCase)) {
        $sidecarIco = [System.IO.Path]::ChangeExtension($path, ".ico")
        if (Test-Path -LiteralPath $sidecarIco -PathType Leaf) {
            return $sidecarIco
        }
    }

    $path
}

function ConvertTo-PackageSquare44Logo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $sourceFilePath = $SourcePath
    $iconResourceIndex = $null
    $resourceIndexSeparator = $SourcePath.LastIndexOf(",")
    if ($resourceIndexSeparator -gt 1 -and
        [int]::TryParse($SourcePath.Substring($resourceIndexSeparator + 1), [ref]$iconResourceIndex)) {
        $sourceFilePath = $SourcePath.Substring(0, $resourceIndexSeparator)
    }

    if (!(Test-Path -LiteralPath $sourceFilePath -PathType Leaf)) {
        throw "Package logo source was not found: $sourceFilePath"
    }

    Add-Type -AssemblyName System.Drawing
    if (!("NativeIconMethods" -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class NativeIconMethods
{
    [DllImport("Shell32.dll", CharSet = CharSet.Unicode)]
    public static extern uint ExtractIconEx(string lpszFile, int nIconIndex, IntPtr[] phiconLarge, IntPtr[] phiconSmall, uint nIcons);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
"@
    }

    $bitmap = $null
    $sourceImage = $null
    $sourceIcon = $null
    $canvas = $null
    $graphics = $null
    try {
        $extension = [System.IO.Path]::GetExtension($sourceFilePath)
        if ($extension.Equals(".ico", [System.StringComparison]::OrdinalIgnoreCase)) {
            $sourceIcon = [System.Drawing.Icon]::new($sourceFilePath, 44, 44)
            $bitmap = $sourceIcon.ToBitmap()
        } elseif ($extension.Equals(".png", [System.StringComparison]::OrdinalIgnoreCase) -or
            $extension.Equals(".jpg", [System.StringComparison]::OrdinalIgnoreCase) -or
            $extension.Equals(".jpeg", [System.StringComparison]::OrdinalIgnoreCase) -or
            $extension.Equals(".bmp", [System.StringComparison]::OrdinalIgnoreCase)) {
            $sourceImage = [System.Drawing.Image]::FromFile($sourceFilePath)
            $bitmap = [System.Drawing.Bitmap]::new($sourceImage)
        } else {
            if ($null -ne $iconResourceIndex) {
                $largeIcons = [IntPtr[]]::new(1)
                $smallIcons = [IntPtr[]]::new(1)
                [void][NativeIconMethods]::ExtractIconEx($sourceFilePath, $iconResourceIndex, $largeIcons, $smallIcons, 1)
                $iconHandle = if ($largeIcons[0] -ne [IntPtr]::Zero) { $largeIcons[0] } else { $smallIcons[0] }
                if ($iconHandle -ne [IntPtr]::Zero) {
                    $sourceIcon = [System.Drawing.Icon]::FromHandle($iconHandle).Clone()
                    if ($largeIcons[0] -ne [IntPtr]::Zero) { [void][NativeIconMethods]::DestroyIcon($largeIcons[0]) }
                    if ($smallIcons[0] -ne [IntPtr]::Zero) { [void][NativeIconMethods]::DestroyIcon($smallIcons[0]) }
                }
            } else {
                $sourceIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($sourceFilePath)
            }
            if (!$sourceIcon) {
                throw "No associated icon could be extracted from $SourcePath"
            }
            $bitmap = $sourceIcon.ToBitmap()
        }

        $canvas = [System.Drawing.Bitmap]::new(44, 44, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($canvas)
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

        $scale = [Math]::Min(44.0 / $bitmap.Width, 44.0 / $bitmap.Height)
        $width = [Math]::Max(1, [int][Math]::Round($bitmap.Width * $scale))
        $height = [Math]::Max(1, [int][Math]::Round($bitmap.Height * $scale))
        $x = [int][Math]::Floor((44 - $width) / 2)
        $y = [int][Math]::Floor((44 - $height) / 2)
        $graphics.DrawImage($bitmap, $x, $y, $width, $height)

        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DestinationPath) | Out-Null
        $canvas.Save($DestinationPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        if ($graphics) { $graphics.Dispose() }
        if ($canvas) { $canvas.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        if ($sourceImage) { $sourceImage.Dispose() }
        if ($sourceIcon) { $sourceIcon.Dispose() }
    }
}

function New-PackageSquare44Logo {
    param(
        [string]$Icon,

        [Parameter(Mandatory = $true)]
        [string]$PackageDir,

        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $sourcePath = Resolve-PackageLogoIconPath -Icon $Icon -RepoRoot $RepoRoot
    ConvertTo-PackageSquare44Logo -SourcePath $sourcePath -DestinationPath (Join-Path $PackageDir "Assets\$PackageSquare44LogoFileName")
}
