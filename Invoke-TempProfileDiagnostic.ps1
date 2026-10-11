#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only diagnosis of a Windows "temporary profile" problem.
.DESCRIPTION
  No registry writes, no profile changes, no deletions. Reads the ProfileList
  registry key for duplicate/failed-state entries, pulls recent User Profile
  Service event log errors, and reports current free space (low disk space
  during logon is the single most common cause). Tells you what's actually
  wrong before anything gets changed.
.EXAMPLE
  .\Invoke-TempProfileDiagnostic.ps1
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Temporary profile diagnostic")
$lines.Add("")
$lines.Add("**Scanned:** $(Get-Date -Format 'yyyy-MM-dd HH:mm') local time  |  read-only, no registry or profile changes made")
$lines.Add("")

# --- Free space on the system drive ---
$sysDrive = $env:SystemDrive.TrimEnd(':')
$vol = Get-Volume -DriveLetter $sysDrive -ErrorAction SilentlyContinue
$freeGB = if ($vol) { [math]::Round($vol.SizeRemaining / 1GB, 2) } else { $null }
$lines.Add("## Free space on $sysDrive`:")
$lines.Add("")
if ($null -ne $freeGB) {
  $lines.Add("**$freeGB GB free.** Windows profile loading needs headroom to extend NTUSER.DAT and write temp files during logon -- under roughly 1-2 GB free at the moment of logon is a known, common cause of a forced temporary profile.")
} else {
  $lines.Add("Could not read free space for $sysDrive`:.")
}
$lines.Add("")

# --- ProfileList registry state ---
$lines.Add("## ProfileList registry entries")
$lines.Add("")
$profileListPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$profiles = Get-ChildItem -LiteralPath $profileListPath -ErrorAction SilentlyContinue
$lines.Add("| SID | ProfileImagePath | State | RefCount |")
$lines.Add("|---|---|---:|---:|")
foreach ($p in $profiles) {
  $props = Get-ItemProperty -LiteralPath $p.PSPath -ErrorAction SilentlyContinue
  $sid = $p.PSChildName
  $path = if ($props -and $props.PSObject.Properties['ProfileImagePath']) { $props.ProfileImagePath } else { '(none)' }
  $state = if ($props -and $props.PSObject.Properties['State']) { $props.State } else { '(none)' }
  $refCount = if ($props -and $props.PSObject.Properties['RefCount']) { $props.RefCount } else { '(none)' }
  $lines.Add("| $sid | $path | $state | $refCount |")
}
$lines.Add("")
$bakEntries = @($profiles | Where-Object { $_.PSChildName -like '*.bak' })
if ($bakEntries.Count -gt 0) {
  $lines.Add("**Found $($bakEntries.Count) `.bak`-suffixed SID entr$(if($bakEntries.Count -eq 1){'y'}else{'ies'}) above.** This is the classic signature of a temporary-profile problem: Windows created a second, temporary SID entry because it couldn't load the real one, and your real profile's original entry should still be present at the plain (non-.bak) SID. Compare the ProfileImagePath values -- the real one usually still points to the correct C:\Users\<name> folder.")
} else {
  $lines.Add("No `.bak`-suffixed entries found. If you're still seeing a temporary-profile message, the cause may be something other than a duplicate registry entry -- check the event log section below.")
}
$lines.Add("")

# --- Recent User Profile Service errors ---
$lines.Add("## Recent User Profile Service events")
$lines.Add("")
$events = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-User Profiles Service'; StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue |
  Sort-Object TimeCreated -Descending | Select-Object -First 10
if ($events) {
  $lines.Add("| Time (local) | Level | Event ID | Message |")
  $lines.Add("|---|---|---:|---|")
  foreach ($e in $events) {
    $msg = ($e.Message -split "`n")[0] -replace '\|', '/'
    $lines.Add("| $($e.TimeCreated) | $($e.LevelDisplayName) | $($e.Id) | $msg |")
  }
} else {
  $lines.Add("No User Profile Service events found in the last 7 days (or the log couldn't be read).")
}
$lines.Add("")
$lines.Add("## What to do with this")
$lines.Add("")
$lines.Add("- If free space above is under ~2 GB: free more space first, reboot, log in again -- this alone resolves many cases.")
$lines.Add("- If a `.bak` entry exists: do NOT delete anything in the registry based on a guess. Send this report back and decide the exact fix together -- the wrong entry deleted here can actually sever access to the real profile folder.")
$lines.Add("- Event IDs 1511/1515/1521/1053 in the table above are the standard ones that name the specific cause directly in their message text.")

$outPath = Join-Path (Get-Location) "TempProfileDiagnostic.md"
$lines -join [Environment]::NewLine | Set-Content -LiteralPath $outPath -Encoding UTF8
Write-Host "Saved: $outPath"
Write-Host "Free space on $sysDrive`: $freeGB GB"
if ($bakEntries.Count -gt 0) { Write-Host "Found $($bakEntries.Count) .bak profile entry/entries -- see report." }
