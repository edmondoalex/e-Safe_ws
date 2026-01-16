<#
bump-build.ps1
Usage:
  .\bump-build.ps1              # increments current numeric version (e.g. 000022 -> 000023), commits and builds
  .\bump-build.ps1 -Version 000050  # set explicit version string
#>
param(
  [string]$Version
)

function PadVersion($n) { return $n.ToString('D6') }

$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location -Path $root
Write-Host "Repo root: $root"

# Read current version from driver.lua
$driverLua = Join-Path $root 'driver.lua'
$driverLuaText = Get-Content -Raw -Path $driverLua

if (-not $Version) {
  $m = [regex]::Match($driverLuaText, 'DRIVER_VERSION\s*=\s*"(\d+)"')
  if (-not $m.Success) { Write-Error "Cannot find DRIVER_VERSION in $driverLua"; exit 1 }
  $cur = [int]($m.Groups[1].Value)
  $newNum = $cur + 1
  $Version = PadVersion $newNum
} else {
  # normalize provided version (allow numeric)
  if ($Version -match '^\d+$') { $Version = PadVersion([int]$Version) }
}

Write-Host "Using version: $Version"

# Update driver.lua constant
$driverLuaText = [regex]::Replace($driverLuaText, 'DRIVER_VERSION\s*=\s*"\d+"', "DRIVER_VERSION = \"$Version\"")
Set-Content -Path $driverLua -Value $driverLuaText -Encoding UTF8

# Update dist copy if present
$distLua = Join-Path $root 'dist\_unzipped\driver.lua'
if (Test-Path $distLua) {
  $distText = Get-Content -Raw -Path $distLua
  $distText = [regex]::Replace($distText, 'DRIVER_VERSION\s*=\s*"\d+"', "DRIVER_VERSION = \"$Version\"")
  Set-Content -Path $distLua -Value $distText -Encoding UTF8
}

# Update driver.xml property default and <version>
$driverXml = Join-Path $root 'driver.xml'
if (-not (Test-Path $driverXml)) { Write-Error "driver.xml not found"; exit 1 }
$xmlText = Get-Content -Raw -Path $driverXml
# Replace <default>000021</default> for Driver Version property (first occurrence)
$xmlText = [regex]::Replace($xmlText, '(<name>Driver Version</name>\s*<type>STRING</type>\s*<default>)(\d+)(</default>)', "$1$Version$3", 1)
# Replace last <version> tag
$xmlText = [regex]::Replace($xmlText, '<version>\s*\d+\s*</version>', "<version>$Version</version>")
Set-Content -Path $driverXml -Value $xmlText -Encoding UTF8

# Update dist/_unzipped/driver.xml if exists
$distXml = Join-Path $root 'dist\_unzipped\driver.xml'
if (Test-Path $distXml) {
  $dtext = Get-Content -Raw -Path $distXml
  $dtext = [regex]::Replace($dtext, '(<name>Driver Version</name>\s*<type>STRING</type>\s*<default>)(\d+)(</default>)', "$1$Version$3", 1)
  $dtext = [regex]::Replace($dtext, '<version>\s*\d+\s*</version>', "<version>$Version</version>")
  Set-Content -Path $distXml -Value $dtext -Encoding UTF8
}

# Git commit
Write-Host "Staging changes..."
git add driver.lua driver.xml
if (Test-Path $distLua) { git add dist\_unzipped\driver.lua }
if (Test-Path $distXml) { git add dist\_unzipped\driver.xml }

$commitMsg = "Bump driver version to $Version"
Write-Host "Committing: $commitMsg"
git commit -m $commitMsg
Write-Host "Pushing to origin..."
git push

# Build .c4z using local driverpackager (dp3)
$packager = Join-Path $root '.ref\drivers-driverpackager\dp3\driverpackager.py'
if (-not (Test-Path $packager)) { Write-Warning "driverpackager.py not found in .ref; skipping build"; exit 0 }

Write-Host "Running driverpackager..."
Push-Location -Path (Split-Path -Parent $packager)
python driverpackager.py -v $root "$root\dist\c4z"
Pop-Location

Write-Host "Build complete. Output: $root\dist\c4z"
