# deploy.ps1 -- Copy aRotationHelper addon files into a selected WoW client AddOns folder.
# Usage:
#   .\scripts\deploy.ps1
#   .\scripts\deploy.ps1 -Destination "D:\Games\WoW\_classic_\Interface\AddOns\aRotationHelper"
#   .\scripts\deploy.ps1 -ClientFlavor classic_era

param(
    [string]$Source      = "C:\git\aRotationHelper",
    [string]$Destination = "",
    [ValidateSet("classic", "anniversary", "classic_era")]
    [string]$ClientFlavor = "classic"
)

if (-not $Destination -or $Destination.Trim() -eq "") {
    $base = "C:\Program Files (x86)\World of Warcraft"
    switch ($ClientFlavor) {
        "classic"      { $branch = "_classic_" }
        "anniversary"  { $branch = "_anniversary_" }
        "classic_era"  { $branch = "_classic_era_" }
        default          { $branch = "_classic_" }
    }
    $Destination = Join-Path $base "$branch\Interface\AddOns\aRotationHelper"
}

$addonDirs  = @("core", "rotations", "ui")
$addonFiles = @("aRotationHelper.toc", "aRotationHelper.lua")

if (Test-Path $Destination) {
    Remove-Item $Destination -Recurse -Force
}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null

foreach ($file in $addonFiles) {
    $src = Join-Path $Source $file
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $Destination $file) -Force
    } else {
        Write-Warning "Missing file: $src"
    }
}

foreach ($dir in $addonDirs) {
    $srcDir = Join-Path $Source $dir
    if (Test-Path $srcDir) {
        Copy-Item $srcDir (Join-Path $Destination $dir) -Recurse -Force
    }
}

Write-Host "Deployed aRotationHelper to $Destination" -ForegroundColor Green
