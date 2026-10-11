#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only breakdown of what's using space on a drive, to inform move/clean decisions.
.DESCRIPTION
  No deletions, no moves, no file contents read -- folder sizes only. Scans top-level
  directories on the target drive plus common game-library locations, sorts by size,
  and flags which large folders are typically safe to relocate through a launcher vs
  which are system-owned and should not be touched.
.EXAMPLE
  .\Invoke-DiskSpaceBreakdown.ps1
.EXAMPLE
  .\Invoke-DiskSpaceBreakdown.ps1 -Drive E
#>
[CmdletBinding()]
param(
  [ValidatePattern('^[A-Za-z]$')][string]$Drive = 'C',
  [int]$TopN = 25
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = "$Drive`:\"
if (-not (Test-Path -LiteralPath $root)) { throw "Drive $root not found." }

# Known game-library install roots worth checking explicitly even if nested deep.
$gameLibraryHints = @(
  "$root" + 'Program Files (x86)\Steam\steamapps\common',
  "$root" + 'Program Files\Steam\steamapps\common',
  "$root" + 'SteamLibrary\steamapps\common',
  "$root" + 'Program Files (x86)\Battle.net',
  "$root" + 'Program Files (x86)\Epic Games',
  "$root" + 'XboxGames',
  "$root" + 'Program Files\WindowsApps'
)

function Get-FolderSizeGB([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
      Where-Object { -not $_.PSIsContainer } | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { return 0 }
    return [math]::Round($bytes / 1GB, 2)
  } catch { return $null }
}

Write-Host "Scanning $root top-level folders (read-only, no deletions)..."
$topLevel = Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue
$results = [System.Collections.Generic.List[object]]::new()
foreach ($dir in $topLevel) {
  $sizeGB = Get-FolderSizeGB $dir.FullName
  if ($null -ne $sizeGB) {
    $category = switch -Regex ($dir.Name) {
      '^(Windows)$'                              { 'system — do not move' ; break }
      '^(Program Files|Program Files \(x86\))$'   { 'mixed — check subfolders' ; break }
      '^(Users)$'                                 { 'mixed — profile data' ; break }
      '^(\$Recycle\.Bin|System Volume Information)$' { 'system — leave alone' ; break }
      '^(SteamLibrary|XboxGames)$'                { 'game library — safe to move via launcher' ; break }
      default                                     { 'review' }
    }
    $results.Add([pscustomobject]@{ Path = $dir.FullName; SizeGB = $sizeGB; Category = $category })
  }
}

Write-Host "Checking known game-library locations..."
foreach ($hint in $gameLibraryHints) {
  if (Test-Path -LiteralPath $hint) {
    $children = Get-ChildItem -LiteralPath $hint -Directory -Force -ErrorAction SilentlyContinue
    foreach ($game in $children) {
      $sizeGB = Get-FolderSizeGB $game.FullName
      if ($null -ne $sizeGB -and $sizeGB -gt 0.5) {
        $results.Add([pscustomobject]@{ Path = $game.FullName; SizeGB = $sizeGB; Category = 'installed game — movable via its launcher''s "move install" feature, never by cut/paste' })
      }
    }
  }
}

$sorted = $results | Sort-Object SizeGB -Descending | Select-Object -First $TopN

$vol = Get-Volume -DriveLetter $Drive -ErrorAction SilentlyContinue
$freeGB = if ($vol) { [math]::Round($vol.SizeRemaining / 1GB, 1) } else { $null }
$totalGB = if ($vol) { [math]::Round($vol.Size / 1GB, 1) } else { $null }

$otherDrive = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne $Drive -and $_.DriveType -eq 'Fixed' } |
  Sort-Object SizeRemaining -Descending | Select-Object -First 1 -ExpandProperty DriveLetter
if (-not $otherDrive) { $otherDrive = 'another drive' } else { $otherDrive = "$otherDrive`:" }

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# $Drive`: drive space breakdown")
$lines.Add("")
$lines.Add("**Free:** $freeGB GB of $totalGB GB  |  **Scanned:** $(Get-Date -Format 'yyyy-MM-dd HH:mm') local time")
$lines.Add("")
$lines.Add("No files were moved, deleted, or modified. This is a read-only size report.")
$lines.Add("")
$lines.Add("| Size (GB) | Path | Category |")
$lines.Add("|---:|---|---|")
foreach ($r in $sorted) { $lines.Add("| $($r.SizeGB) | $($r.Path) | $($r.Category) |") }
$lines.Add("")
$lines.Add("## How to act on this")
$lines.Add("")
$lines.Add("- Rows marked **game library** or **installed game**: open that game's launcher (Steam/Epic/Battle.net/Xbox app), use its own 'move install location' or 'manage install' feature to relocate to $otherDrive\. Never cut/paste game folders manually -- it breaks the launcher's registration.")
$lines.Add("- Rows marked **system**: leave alone entirely.")
$lines.Add("- Rows marked **mixed**: review the subfolder list yourself before moving anything inside.")

$outPath = Join-Path (Get-Location) "DiskSpaceBreakdown-$Drive.md"
$lines -join [Environment]::NewLine | Set-Content -LiteralPath $outPath -Encoding UTF8
Write-Host ""
Write-Host "Saved: $outPath"
Write-Host "Top consumer: $($sorted[0].Path) -- $($sorted[0].SizeGB) GB ($($sorted[0].Category))"
