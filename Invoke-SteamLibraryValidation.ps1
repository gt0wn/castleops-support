#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only validation that Steam's own records agree with what's actually on disk,
  across every registered Steam library folder (not just one drive).
.DESCRIPTION
  No files moved, no Steam process touched, no manifest files written. Finds every
  Steam library folder via libraryfolders.vdf, reads each game's appmanifest_*.acf,
  and checks: does Steam think it's fully installed, does the install folder actually
  exist, and does its real on-disk size roughly match what Steam recorded. Catches a
  move that silently broke Steam's bookkeeping -- does NOT confirm a game actually
  launches, which still needs a human to click Play.
.EXAMPLE
  .\Invoke-SteamLibraryValidation.ps1
.EXAMPLE
  .\Invoke-SteamLibraryValidation.ps1 -SteamPath "D:\Steam"
#>
[CmdletBinding()]
param(
  [string]$SteamPath,
  [double]$SizeMismatchPercent = 20
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-SteamPath {
  param([string]$Explicit)
  if ($Explicit) { return $Explicit }
  try {
    $regPath = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop
    if ($regPath.SteamPath) { return ($regPath.SteamPath -replace '/', '\') }
  } catch {}
  $default = "${env:ProgramFiles(x86)}\Steam"
  if (Test-Path -LiteralPath $default) { return $default }
  return $null
}

function Get-VdfValue {
  param([string]$Content, [string]$Key)
  $pattern = '"' + [regex]::Escape($Key) + '"\s+"([^"]*)"'
  $m = [regex]::Match($Content, $pattern)
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

$steamPath = Find-SteamPath -Explicit $SteamPath
if (-not $steamPath -or -not (Test-Path -LiteralPath $steamPath)) {
  throw "Could not find Steam install path. Pass it explicitly: -SteamPath 'C:\Program Files (x86)\Steam'"
}
Write-Host "Steam install: $steamPath"

$libraryVdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
if (-not (Test-Path -LiteralPath $libraryVdf)) { throw "libraryfolders.vdf not found at $libraryVdf" }
$vdfContent = Get-Content -LiteralPath $libraryVdf -Raw

# Every "path" value in the file is a registered library folder root.
$libraryPaths = [regex]::Matches($vdfContent, '"path"\s+"([^"]*)"') |
  ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' } | Select-Object -Unique
if ($libraryPaths.Count -eq 0) { $libraryPaths = @($steamPath) }
Write-Host "Found $($libraryPaths.Count) Steam library folder(s): $($libraryPaths -join ', ')"

$games = [System.Collections.Generic.List[object]]::new()
foreach ($lib in $libraryPaths) {
  $steamappsDir = Join-Path $lib 'steamapps'
  if (-not (Test-Path -LiteralPath $steamappsDir)) { continue }
  $manifests = Get-ChildItem -LiteralPath $steamappsDir -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue
  foreach ($manifest in $manifests) {
    $content = Get-Content -LiteralPath $manifest.FullName -Raw
    $appid = Get-VdfValue $content 'appid'
    $name = Get-VdfValue $content 'name'
    $stateFlags = Get-VdfValue $content 'StateFlags'
    $installDir = Get-VdfValue $content 'installdir'
    $sizeOnDiskStr = Get-VdfValue $content 'SizeOnDisk'
    $sizeOnDiskBytes = 0L
    if ($sizeOnDiskStr) { [void][long]::TryParse($sizeOnDiskStr, [ref]$sizeOnDiskBytes) }

    $installPath = if ($installDir) { Join-Path $steamappsDir "common\$installDir" } else { $null }
    $exists = $installPath -and (Test-Path -LiteralPath $installPath -PathType Container)
    $actualBytes = 0L
    if ($exists) {
      $actualBytes = (Get-ChildItem -LiteralPath $installPath -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
      if (-not $actualBytes) { $actualBytes = 0L }
    }

    $sizeDiffPercent = $null
    if ($sizeOnDiskBytes -gt 0) {
      $sizeDiffPercent = [math]::Round((100.0 * [math]::Abs($actualBytes - $sizeOnDiskBytes) / $sizeOnDiskBytes), 1)
    }

    $issues = [System.Collections.Generic.List[string]]::new()
    if ($stateFlags -ne '4') { $issues.Add("StateFlags=$stateFlags (not 4/normal) -- Steam may want to verify or update this game") }
    if (-not $exists) { $issues.Add("install folder not found at $installPath") }
    elseif ($null -ne $sizeDiffPercent -and $sizeDiffPercent -gt $SizeMismatchPercent) {
      $issues.Add("on-disk size differs from Steam's record by $sizeDiffPercent% (expected roughly $([math]::Round($sizeOnDiskBytes/1GB,1)) GB, found $([math]::Round($actualBytes/1GB,1)) GB)")
    }

    $games.Add([pscustomobject]@{
      Name = $name; AppId = $appid; Library = $lib; StateFlags = $stateFlags
      InstallPath = $installPath; Exists = $exists
      ExpectedGB = [math]::Round($sizeOnDiskBytes / 1GB, 2)
      ActualGB = [math]::Round($actualBytes / 1GB, 2)
      Issues = ($issues -join '; ')
    })
  }
}

$sorted = $games | Sort-Object { $_.Issues -ne '' }, Name -Descending
$flagged = @($games | Where-Object { $_.Issues -ne '' })

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Steam library validation")
$lines.Add("")
$lines.Add("**Scanned:** $(Get-Date -Format 'yyyy-MM-dd HH:mm') local time  |  read-only, nothing modified, Steam not touched")
$lines.Add("")
$lines.Add("$($games.Count) game(s) found across $($libraryPaths.Count) library folder(s). **$($flagged.Count) flagged for review.**")
$lines.Add("")
if ($flagged.Count -gt 0) {
  $lines.Add("## Flagged -- check these")
  $lines.Add("")
  $lines.Add("| Game | AppID | Library | Issue |")
  $lines.Add("|---|---|---|---|")
  foreach ($g in $flagged) { $lines.Add("| $($g.Name) | $($g.AppId) | $($g.Library) | $($g.Issues) |") }
  $lines.Add("")
}
$lines.Add("## All games")
$lines.Add("")
$lines.Add("| Game | AppID | Library | StateFlags | Expected GB | Actual GB | OK? |")
$lines.Add("|---|---|---|---:|---:|---:|---|")
foreach ($g in $sorted) {
  $ok = if ($g.Issues -eq '') { 'yes' } else { 'NO -- see above' }
  $lines.Add("| $($g.Name) | $($g.AppId) | $($g.Library) | $($g.StateFlags) | $($g.ExpectedGB) | $($g.ActualGB) | $ok |")
}
$lines.Add("")
$lines.Add("## What this does and doesn't prove")
$lines.Add("")
$lines.Add("- Confirms Steam's own manifest, the install folder, and the real on-disk size all agree. Catches a move that silently broke something.")
$lines.Add("- Does **not** confirm a game actually launches and plays -- that still needs someone to click Play and watch it load. Treat a clean report here as 'safe to try launching', not as 'confirmed working'.")

$outPath = Join-Path (Get-Location) "SteamLibraryValidation.md"
$lines -join [Environment]::NewLine | Set-Content -LiteralPath $outPath -Encoding UTF8
Write-Host ""
Write-Host "Saved: $outPath"
Write-Host "$($games.Count) games checked, $($flagged.Count) flagged."
