#Requires -Version 5.1
<#
.SYNOPSIS
  Human-approved, allowlisted gaming launcher/service recovery.
.DESCRIPTION
  With no -Execute: reports eligibility only. With -Execute: requires an
  interactive typed approval, no detected active games, and elevated access
  for service restarts. No save, mod, game-file, registry, GPU driver, or
  anti-cheat modification. Not suitable for unattended execution.
.EXAMPLE
  .\Invoke-GamingSafeRemediation.ps1 -Action RefreshXboxApp
.EXAMPLE
  .\Invoke-GamingSafeRemediation.ps1 -Action RefreshXboxApp -Execute
#>
[CmdletBinding()]
param(
  [ValidateSet('RefreshXboxApp','RestartGamingServices')]
  [string]$Action='RefreshXboxApp',
  [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$base=Join-Path $env:LOCALAPPDATA 'CastleOps\GamingEndpointAudit'
$id=(Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')+'-'+([guid]::NewGuid().ToString('N').Substring(0,8))
$out=Join-Path $base "remediation-$id"
New-Item -ItemType Directory -Path $out -Force | Out-Null
$start=(Get-Date).ToUniversalTime()
$state=[ordered]@{
  schemaVersion='1.0';mode='attended-reversible-recovery'
  action=$Action;startUtc=$start.ToString('o')
  executionRequested=[bool]$Execute;status='not-executed'
  decisions=@();before=@();after=@();notes=@()
}
function Snapshot {
  $items=@()
  foreach($name in @('GamingServices','GamingServicesNet')){
    $s=Get-Service -Name $name -ErrorAction SilentlyContinue
    if($s){$items += [ordered]@{name=$name;status=[string]$s.Status}}
  }
  return @($items)
}
function Save {
  $state.finishUtc=(Get-Date).ToUniversalTime().ToString('o')
  $json=Join-Path $out 'recovery.json'
  $state | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $json -Encoding UTF8
  Write-Host "Recovery record: $json"
}
$state.before=@(Snapshot)
try {
  $processes=@(Get-CimInstance Win32_Process -ErrorAction Stop)
  $gameRx='(?i)^(cod(\d+)?|codhq|ModernWarfare|bf2042|bf6|gta5|gta5_enhanced|fivem|r5apex|fortniteclient-win64-shipping|rainbowsix|rainbowsix_vulkan)\.exe$'
  $activeGames=@($processes | Where-Object { $_.Name -match $gameRx })
  if($activeGames.Count -gt 0){
    $state.status='blocked-game-active'
    $state.notes=@('Detected an active protected game executable; no recovery was attempted.','Close games normally first. Never kill a running game to satisfy an automated fix.')
    Write-Warning "A game appears active. No modifications made."
  }
  elseif(-not $Execute){
    $state.status='plan-only'
    $state.notes=@("Eligible for approval-gated $Action only if Xbox has a confirmed problem.",'No processes or services changed.')
    Write-Host "DRY RUN: $Action is available only with -Execute and typed interactive approval."
  }
  else {
    if([Environment]::UserInteractive -ne $true){throw 'Interactive user session required.'}
    if($Action -eq 'RestartGamingServices'){
      $admin=([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
      if(-not $admin){throw 'RestartGamingServices requires Windows Terminal / PowerShell as Administrator.'}
    }
    Write-Warning "Action: $Action. This may interrupt Xbox launcher tasks. It does not restart cloud sync directly."
    $approval=Read-Host "To approve this action, type exactly APPROVE $Action"
    if($approval -cne "APPROVE $Action"){
      $state.status='declined'
      $state.notes=@('Approval phrase was not provided. No changes made.')
      Write-Warning 'Declined. No changes.'
    }
    elseif($Action -eq 'RefreshXboxApp'){
      $apps=@($processes | Where-Object { $_.Name -in @('XboxPcApp.exe','Xbox.exe') })
      $closed=0
      foreach($p in $apps){
        $live=Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if($live -and $live.ProcessName -eq [IO.Path]::GetFileNameWithoutExtension([string]$p.Name)){
          Stop-Process -Id $p.ProcessId -ErrorAction Stop
          $closed++
        }
      }
      $state.status='completed'
      $state.notes=@("Closed $closed recognized Xbox app process(es). Reopen Xbox manually; check gamertag, game status, and cloud sync notice.",'No game process, saves, mods or anticheat intentionally touched.')
      Write-Host "Xbox app process count closed: $closed"
    }
    else {
      $n=0
      foreach($name in @('GamingServices','GamingServicesNet')){
        $s=Get-Service -Name $name -ErrorAction SilentlyContinue
        if($s -and $s.Status -eq 'Running'){
          Restart-Service -Name $name -ErrorAction Stop
          $n++
        }
      }
      $state.status='completed'
      $state.notes=@("Restarted $n running Xbox Gaming Services service(s). Stopped/demand services were left alone.",'Restarting a service does not force Xbox cloud-save synchronization. Reopen Xbox and verify the UI.')
      Write-Host "Running Xbox services restarted: $n"
    }
  }
}
catch {
  $state.status='error'
  $state.notes=@("Action ended with $($_.Exception.GetType().Name): $($_.Exception.Message)")
  Write-Warning $state.notes[0]
}
finally {
  $state.after=@(Snapshot)
  Save
}
if($state.status -eq 'error'){exit 1}
