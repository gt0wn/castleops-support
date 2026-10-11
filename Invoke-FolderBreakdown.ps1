#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only recursive size breakdown of one specific folder, to any depth.
.DESCRIPTION
  No deletions, no moves, no content read -- names/sizes/dates only. Point it
  at any folder and it reports the largest subfolders found at any depth
  inside it, same logic as Invoke-FullSystemAudit.ps1 but scoped to one tree
  so it runs fast and deep instead of scanning an entire drive.
.EXAMPLE
  .\Invoke-FolderBreakdown.ps1 -Path "C:\Users\parke\AppData\Local\Google"
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Path,
  [int]$MaxDepth = 6,
  [int]$TopN = 30,
  [double]$MinReportGB = 0.1
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Folder not found: $Path" }

function Get-DirSizeBytes([System.IO.DirectoryInfo]$Dir) {
  $sum = 0L
  try {
    foreach ($f in $Dir.EnumerateFiles('*', [System.IO.SearchOption]::TopDirectoryOnly)) {
      try { $sum += $f.Length } catch {}
    }
  } catch {}
  return $sum
}

function Measure-DirectoryTree {
  param([System.IO.DirectoryInfo]$Dir, [int]$Depth, [System.Collections.Generic.List[object]]$Results)
  $ownBytes = Get-DirSizeBytes $Dir
  $totalBytes = $ownBytes
  $subResults = [System.Collections.Generic.List[object]]::new()
  if ($Depth -lt $MaxDepth) {
    try {
      foreach ($sub in $Dir.EnumerateDirectories()) {
        if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $totalBytes += Measure-DirectoryTree -Dir $sub -Depth ($Depth + 1) -Results $subResults
      }
    } catch {}
  } else {
    try {
      $t = (Get-ChildItem -LiteralPath $Dir.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
      if ($t) { $totalBytes = $t }
    } catch {}
  }
  $gb = [math]::Round($totalBytes / 1GB, 3)
  if ($gb -ge $MinReportGB) {
    $Results.Add([pscustomobject]@{ Path = $Dir.FullName; SizeGB = $gb; Depth = $Depth })
  }
  foreach ($r in $subResults) { $Results.Add($r) }
  return $totalBytes
}

Write-Host "Scanning $Path (depth up to $MaxDepth, read-only)..."
$results = [System.Collections.Generic.List[object]]::new()
$rootInfo = [System.IO.DirectoryInfo]::new($Path)
$rootTotalBytes = $rootInfo | ForEach-Object {
  $own = Get-DirSizeBytes $_
  $t = $own
  foreach ($sub in $_.EnumerateDirectories()) {
    if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
    $t += Measure-DirectoryTree -Dir $sub -Depth 1 -Results $results
  }
  $t
}
$rootGB = [math]::Round(($rootTotalBytes | Select-Object -Last 1) / 1GB, 2)

$sorted = $results | Sort-Object SizeGB -Descending | Select-Object -First $TopN

Write-Host ""
Write-Host "Total size of $Path -- $rootGB GB"
Write-Host ""
$sorted | Format-Table -AutoSize Depth, SizeGB, Path

$outPath = Join-Path (Get-Location) ("FolderBreakdown-" + ($rootInfo.Name -replace '[^a-zA-Z0-9]', '_') + ".md")
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Folder breakdown: $Path")
$lines.Add("")
$lines.Add("**Total:** $rootGB GB  |  **Scanned:** $(Get-Date -Format 'yyyy-MM-dd HH:mm') local time  |  read-only, nothing modified")
$lines.Add("")
$lines.Add("| Size (GB) | Depth | Path |")
$lines.Add("|---:|---:|---|")
foreach ($r in $sorted) { $lines.Add("| $($r.SizeGB) | $($r.Depth) | $($r.Path) |") }
$lines -join [Environment]::NewLine | Set-Content -LiteralPath $outPath -Encoding UTF8
Write-Host ""
Write-Host "Saved: $outPath"
