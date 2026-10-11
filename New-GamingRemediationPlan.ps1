#Requires -Version 5.1
<#
.SYNOPSIS
  Build an evidence-bound, non-executing remediation plan from the newest
  local gaming assessment, or an explicitly specified assessment.json.
.DESCRIPTION
  Deterministic policy/decision engine. Does not run commands or modify Windows.
#>
[CmdletBinding()]
param([string]$AssessmentPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'CastleOps\GamingEndpointAudit'
if(-not $AssessmentPath) {
  $last=Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  if(-not $last){throw 'No diagnostic runs found. Run Invoke-GamingEndpointAudit.ps1 first.'}
  $AssessmentPath=Join-Path $last.FullName 'assessment.json'
}
if(-not (Test-Path -LiteralPath $AssessmentPath)){throw 'Assessment JSON not found.'}
$data=Get-Content -LiteralPath $AssessmentPath -Raw -Encoding UTF8 | ConvertFrom-Json
if($data.schemaVersion -ne '1.0' -or $data.mode -ne 'live-readonly-discovery-summary'){
  throw 'Unsupported or untrusted assessment format.'
}
$steps=[System.Collections.Generic.List[object]]::new()
function Add-Step([string]$Code,[string]$Priority,[string]$Approval,[string]$Observation,[string]$Action){
  $script:steps.Add([ordered]@{
    id=$Code;priority=$Priority;approval=$Approval
    observation=$Observation;recommendedAction=$Action
  })
}
$cats=@($data.eventSignatures | ForEach-Object { $_.category })
$procs=@($data.gaming.processes | ForEach-Object { $_.name })
if($cats -contains 'GamingServicesUI'){
  Add-Step 'XBOX-SERVICE-CRASH' 'high' 'Human verification' 'Historical GamingServicesUI crash signature found.' 'Check whether the timestamp is AFTER the last repair. If continuing, verify Xbox app, Gaming Services state, Microsoft Store updates and new event logs.'
}
if($procs -match '(?i)^cod.*\.exe$'){
  Add-Step 'COD-PROCESS-PRESENT' 'high' 'No automatic termination' 'Call of Duty process is present at inspection time.' 'If Xbox says Running, it may be real. Verify responsiveness and do not disrupt gameplay or an active sync.'
}
else {
  Add-Step 'XBOX-STALE-STATUS-CANDIDATE' 'medium' 'Interactive approval required' 'No recognized Call of Duty process observed.' 'Only if Xbox UI STILL says Running, request approval for RefreshXboxApp. This refreshes launcher state but is not a cloud sync reset.'
}
if(($cats -contains 'DisplayDriver') -or ($cats -contains 'Battlefield')){
  Add-Step 'GRAPHICS-CROSSGAME' 'high' 'Human diagnosis' 'Potential GPU/game failures in event history.' 'Correlate event time, validate official AMD driver, default Radeon settings and verify RAM stability. No automatic driver or BIOS change.'
}
if($cats -contains 'HardwareWHEA'){
  Add-Step 'HARDWARE-STABILITY' 'high' 'Human diagnosis' 'WHEA/hardware event recorded.' 'Check RAM EXPO settings, firmware support, CPU/GPU power, cooling and PSU model. Do not automatically stress-test or change firmware.'
}
foreach($vol in @($data.storage.volumes)){
  if($vol.letter -eq 'C' -and [double]$vol.sizeGB -gt 0 -and (100*[double]$vol.freeGB/[double]$vol.sizeGB) -lt 15) {
    Add-Step 'OS-DRIVE-FULL' 'medium' 'Human approval before deletion' 'Windows system volume has under 15% space free.' 'Move reinstallable games through official launchers to a physical second NVMe drive. Never move or delete mod/save folders blindly.'
  }
}
$boot=@($data.findings | Where-Object { $_.id -in @('ATTESTATION','ATTESTATION-UNKNOWN') })
if($boot.Count){
  Add-Step 'CALL-OF-DUTY-ATTESTATION' 'medium' 'Manual verification' 'TPM/Secure Boot needs verification.' 'Check Microsoft System Information and the official game requirements. Do not toggle BIOS or bypass RICOCHET.'
}
Add-Step 'CLOUD-SYNC-UI-ONLY' 'high' 'User identity verification' 'Cloud save and Running UI state are not available in assessment JSON.' 'Verify the intended Xbox profile and read the sync notification; do not reset cloud/local saves or account links.'
$plan=[ordered]@{
  schemaVersion='1.0';policy='castleops-windows-gaming-v1'
  mode='decision-plan-only';assetTag=$data.assetTag;sourceRunId=$data.runId
  sourceReportSha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $AssessmentPath).Hash.ToLowerInvariant()
  createdUtc=(Get-Date).ToUniversalTime().ToString('o')
  automation=[ordered]@{
    readOnlyAudit='eligible for opt-in scheduled operation'
    upload='only after private repository authentication and consent'
    refreshXboxApp='human-approved, user-present, no active games'
    restartGamingServices='human-approved, elevated, no active games'
    reinstallGpuDrivers='not authorized';removeMods='prohibited'
    resetSaves='prohibited';changeAccounts='prohibited'
    biosChanges='not authorized';disableAnticheat='prohibited'
  }
  decisions=@($steps.ToArray())
}
$dir=Split-Path -Parent $AssessmentPath
$planPath=Join-Path $dir 'PLAN.json'
$plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planPath -Encoding UTF8
$md=@('# Gaming endpoint agent decision plan','','**Source run:** '+$data.runId,'','No action has been executed. Actions require local approval.','','| Priority | Policy | Finding | Next action |','|---|---|---|---|')
foreach($s in $steps){$md+='| '+$s.priority+' | '+$s.approval+' | '+$s.id+' | '+$s.recommendedAction.Replace('|','/')+' |'}
$md+=@('','**Safety:** No mod, game, account, anti-cheat or cloud-save changes authorized.','')
$md -join [Environment]::NewLine | Set-Content -LiteralPath (Join-Path $dir 'PLAN.md') -Encoding UTF8
Write-Host "Plan generated: $planPath"
Write-Host "Decision count: $($steps.Count). No system changes made."
