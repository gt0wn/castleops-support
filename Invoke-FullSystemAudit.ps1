#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only, multi-level disk space analysis across all fixed drives, plus a
  Windows services snapshot, for diagnosing low-disk-space and startup issues.
.DESCRIPTION
  No deletions, no moves, no service start/stop/config changes, no file content
  read -- names, sizes, paths, and dates only. Walks each fixed drive recursively
  up to -MaxDepth levels, reporting the largest folders found at ANY depth (not
  just top-level), so a 600GB "Users" folder gets broken down into the actual
  multi-gigabyte subfolders inside it instead of stopping at the parent.
.EXAMPLE
  .\Invoke-FullSystemAudit.ps1
.EXAMPLE
  .\Invoke-FullSystemAudit.ps1 -MaxDepth 5 -TopN 40
#>
[CmdletBinding()]
param(
  [int]$MaxDepth = 4,
  [int]$TopN = 40,
  [double]$MinReportGB = 0.5
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gameLibraryNames = '^(SteamLibrary|XboxGames|steamapps|Epic Games|Battle\.net)$'
$systemNames = '^(Windows|\$Recycle\.Bin|System Volume Information|Recovery|WindowsApps)$'

function Get-DirSizeBytes([System.IO.DirectoryInfo]$Dir) {
  $sum = 0L
  try {
    $files = $Dir.EnumerateFiles('*', [System.IO.SearchOption]::TopDirectoryOnly)
    foreach ($f in $files) { try { $sum += $f.Length } catch {} }
  } catch { return $sum }
  return $sum
}

# Recursive walk that reports every folder at every depth whose OWN total size
# (including descendants) clears $MinReportGB. Depth-limited so it terminates
# on deep trees instead of reporting every leaf folder individually.
function Measure-DirectoryTree {
  param(
    [System.IO.DirectoryInfo]$Dir,
    [int]$Depth,
    [System.Collections.Generic.List[object]]$Results
  )
  $ownBytes = Get-DirSizeBytes $Dir
  $totalBytes = $ownBytes
  $subResults = [System.Collections.Generic.List[object]]::new()
  if ($Depth -lt $MaxDepth) {
    try {
      $subdirs = $Dir.EnumerateDirectories()
      foreach ($sub in $subdirs) {
        if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $subTotal = Measure-DirectoryTree -Dir $sub -Depth ($Depth + 1) -Results $subResults
        $totalBytes += $subTotal
      }
    } catch {}
  } else {
    try {
      $totalBytes = (Get-ChildItem -LiteralPath $Dir.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
      if (-not $totalBytes) { $totalBytes = $ownBytes }
    } catch { $totalBytes = $ownBytes }
  }
  $gb = [math]::Round($totalBytes / 1GB, 2)
  if ($gb -ge $MinReportGB) {
    $category = switch -Regex ($Dir.Name) {
      $systemNames      { 'system — do not move' ; break }
      $gameLibraryNames { 'game library — move via launcher only' ; break }
      default           { if ($Depth -eq 0) { 'review' } else { 'review (nested)' } }
    }
    $Results.Add([pscustomobject]@{ Path = $Dir.FullName; SizeGB = $gb; Depth = $Depth; Category = $category })
  }
  foreach ($r in $subResults) { $Results.Add($r) }
  return $totalBytes
}

$drives = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | Sort-Object DriveLetter
$allResults = [System.Collections.Generic.List[object]]::new()
$driveSummary = [System.Collections.Generic.List[object]]::new()

foreach ($v in $drives) {
  $letter = $v.DriveLetter
  $root = "$letter`:\"
  Write-Host "Scanning $root (depth up to $MaxDepth, read-only)..."
  $freeGB = [math]::Round($v.SizeRemaining / 1GB, 1)
  $totalGB = [math]::Round($v.Size / 1GB, 1)
  $driveSummary.Add([pscustomobject]@{ Drive = "$letter`:"; FreeGB = $freeGB; TotalGB = $totalGB; PercentFree = [math]::Round(100 * $freeGB / $totalGB, 1) })
  $rootInfo = [System.IO.DirectoryInfo]::new($root)
  try {
    $topDirs = $rootInfo.EnumerateDirectories()
    foreach ($d in $topDirs) {
      if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
      [void](Measure-DirectoryTree -Dir $d -Depth 0 -Results $allResults)
    }
  } catch { Write-Warning "Could not fully enumerate $root -- $($_.Exception.Message)" }
}

$sortedFolders = $allResults | Sort-Object SizeGB -Descending | Select-Object -First $TopN

Write-Host "Collecting services snapshot (status/startup only, no config changes)..."
$services = Get-Service -ErrorAction SilentlyContinue |
  Select-Object Name, DisplayName, Status, StartType |
  Sort-Object Status, StartType, DisplayName
$autoStoppedCount = @($services | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' }).Count

$fullestDrive = $driveSummary | Sort-Object PercentFree | Select-Object -First 1 -ExpandProperty Drive
$otherDrive = $driveSummary | Where-Object { $_.Drive -ne $fullestDrive } | Sort-Object FreeGB -Descending | Select-Object -First 1 -ExpandProperty Drive
if (-not $otherDrive) { $otherDrive = $fullestDrive }
$biggestMovable = $sortedFolders | Where-Object { $_.Category -eq 'game library — move via launcher only' -and $_.Path.StartsWith("$fullestDrive\") } | Select-Object -First 1

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Full system audit — disk + services")
$lines.Add("")
$lines.Add("**Scanned:** $(Get-Date -Format 'yyyy-MM-dd HH:mm') local time  |  **Mode:** read-only, no files moved/deleted, no services changed")
$lines.Add("")
$lines.Add("## Drives")
$lines.Add("")
$lines.Add("| Drive | Free GB | Total GB | % Free |")
$lines.Add("|---|---:|---:|---:|")
foreach ($d in $driveSummary) { $lines.Add("| $($d.Drive) | $($d.FreeGB) | $($d.TotalGB) | $($d.PercentFree)% |") }
$lines.Add("")
$lines.Add("## Largest folders (any depth, top $TopN, >= $MinReportGB GB)")
$lines.Add("")
$lines.Add("| Size (GB) | Depth | Path | Category |")
$lines.Add("|---:|---:|---|---|")
foreach ($r in $sortedFolders) { $lines.Add("| $($r.SizeGB) | $($r.Depth) | $($r.Path) | $($r.Category) |") }
$lines.Add("")
$lines.Add("## Services")
$lines.Add("")
$lines.Add("$($services.Count) total. $autoStoppedCount set to Automatic but not currently Running (worth a look, not necessarily a problem).")
$lines.Add("")
$lines.Add("| Status | Start type | Service | Display name |")
$lines.Add("|---|---|---|---|")
foreach ($s in ($services | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' })) {
  $lines.Add("| $($s.Status) | $($s.StartType) | $($s.Name) | $($s.DisplayName) |")
}
$lines.Add("")
$lines.Add('Full service list omitted from this report for length -- re-run `Get-Service | Sort-Object Status` directly for the complete table if needed.')
$lines.Add("")
$lines.Add("## How to act on this")
$lines.Add("")
$lines.Add("- $fullestDrive\ is the fullest drive -- that's the one that needs space freed, not necessarily the biggest folder overall.")
if ($biggestMovable) {
  $lines.Add("- Biggest clean win on $fullestDrive\: **$($biggestMovable.Path)** ($($biggestMovable.SizeGB) GB) -- move via its launcher's own relocate feature to $otherDrive\, never by cut/paste.")
} else {
  $lines.Add("- No obvious game-library folder found on $fullestDrive\ over $MinReportGB GB -- check the highest-depth 'review' rows under $fullestDrive\ above directly; the deepest-nested one is usually the real answer.")
}
$lines.Add("- Rows marked **system**: leave alone entirely.")
$lines.Add("- Rows marked **review** or **review (nested)**: the deepest-nested large folder under each is usually the real answer -- check the highest-depth rows first, they're the most specific.")
$lines.Add("- A service **Automatic but not Running** is often harmless (fails-and-retries, or only needed on demand) but worth a one-line search on its exact name if something related is actually broken.")

$outPath = Join-Path (Get-Location) "FullSystemAudit.md"
$lines -join [Environment]::NewLine | Set-Content -LiteralPath $outPath -Encoding UTF8
Write-Host ""
Write-Host "Saved: $outPath"
Write-Host "Top consumer: $($sortedFolders[0].Path) -- $($sortedFolders[0].SizeGB) GB"
