#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only local Windows gaming endpoint assessment and sanitized report.
.DESCRIPTION
  No game launches, repairs, registry writes, save access, mod changes,
  service stops, process termination, elevation, or anti-cheat manipulation.
  Xbox cloud synchronization status cannot be directly inspected by this tool.
  Running the command again produces a new point-in-time assessment.
.EXAMPLE
  .\Invoke-GamingEndpointAudit.ps1
#>
[CmdletBinding()]
param(
  [ValidateRange(1,30)][int]$HistoryDays=7,
  [ValidatePattern('^[a-z0-9][a-z0-9-]{1,38}$')][string]$AssetTag='john-gaming-pc'
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + ([guid]::NewGuid().ToString('N').Substring(0,8))
$base = Join-Path $env:LOCALAPPDATA 'CastleOps\GamingEndpointAudit'
$folder = Join-Path $base $runId
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$warnings = [System.Collections.Generic.List[string]]::new()
$findings = [System.Collections.Generic.List[object]]::new()
function Collect([scriptblock]$Action,[string]$Name) {
  try { return (& $Action) } catch {
    $script:warnings.Add("$Name unavailable ($($_.Exception.GetType().Name)).")
    return $null
  }
}
function Add-Finding([string]$Id,[string]$Severity,[string]$Observation,[string]$Next,[string]$Confidence='medium') {
  $script:findings.Add([ordered]@{
    id=$Id; severity=$Severity; confidence=$Confidence
    observation=$Observation; nextAction=$Next
  })
}
function PercentFree($Vol) {
  if ($null -eq $Vol -or [double]$Vol.sizeGB -le 0) { return $null }
  return [math]::Round((100 * [double]$Vol.freeGB / [double]$Vol.sizeGB),1)
}
function ShortEvents([string]$LogName,[int[]]$Ids) {
  $cutoff=(Get-Date).AddDays(-$HistoryDays)
  $events = Collect {
    @(Get-WinEvent -FilterHashtable @{LogName=$LogName;Id=$Ids;StartTime=$cutoff} -MaxEvents 350 -ErrorAction Stop)
  } "Event log $LogName"
  $output = @()
  foreach($e in @($events)) {
    if ($null -eq $e) { continue }
    $message = [string]$e.Message
    $category = $null
    if ($message -match '(?i)GamingServicesUI') { $category='GamingServicesUI' }
    elseif ($message -match '(?i)(cod\.exe|Call of Duty|ModernWarfare|codhq)') { $category='CallOfDuty' }
    elseif ($message -match '(?i)(BF2042|Battlefield)') { $category='Battlefield' }
    elseif ($message -match '(?i)(amdwddmg|amdkmdag|Display driver|Radeon)') { $category='DisplayDriver' }
    elseif ($e.ProviderName -match 'WHEA') { $category='HardwareWHEA' }
    elseif ($e.Id -eq 41) { $category='UnexpectedRestart' }
    elseif ($message -match '(?i)GamingServices') { $category='GamingServices' }
    if (-not $category) { continue }
    $ex=''; if ($message -match '(?i)0x[cC]0000374|c0000374') { $ex='0xC0000374' }
    elseif ($message -match '(?i)0x887A0006') { $ex='0x887A0006' }
    $output += [ordered]@{
      utc=$e.TimeCreated.ToUniversalTime().ToString('o')
      log=$LogName;eventId=[int]$e.Id;category=$category
      exception=$ex
    }
  }
  return @($output)
}

Write-Host "CastleOps Gaming Endpoint Audit - $runId"
Write-Host 'Inventorying Windows, graphics, NVMe/storage, gaming services and crash signatures...'

$os = Collect { Get-CimInstance Win32_OperatingSystem } 'Windows OS'
$cpu = Collect { Get-CimInstance Win32_Processor | Select-Object -First 1 } 'CPU'
$board = Collect { Get-CimInstance Win32_BaseBoard | Select-Object -First 1 } 'Motherboard'
$bios = Collect { Get-CimInstance Win32_BIOS | Select-Object -First 1 } 'BIOS'
$memory = @(Collect { Get-CimInstance Win32_PhysicalMemory } 'Memory')
$graphics = @()
foreach($g in @(Collect { Get-CimInstance Win32_VideoController } 'GPU')) {
  if ($null -eq $g) { continue }
  $graphics += [ordered]@{
    name=[string]$g.Name; driver=[string]$g.DriverVersion
    vramGB= $(if ($g.AdapterRAM -and $g.AdapterRAM -lt 4294967295) { [math]::Round($g.AdapterRAM/1GB,1) } else { $null })
  }
}
$drives = @()
foreach($d in @(Collect { Get-Disk } 'Physical disks')) {
  if ($null -eq $d) { continue }
  $drives += [ordered]@{
    diskNumber=[int]$d.Number; model=[string]$d.FriendlyName
    busType=[string]$d.BusType; health=[string]$d.HealthStatus
    sizeGB=[math]::Round($d.Size/1GB,1)
  }
}
$volumes = @()
foreach($p in @(Collect { Get-Partition | Where-Object { $_.DriveLetter } } 'Drive letters')) {
  if($null -eq $p) { continue }
  $v = Collect { Get-Volume -DriveLetter $p.DriveLetter } "Volume $($p.DriveLetter)"
  if($null -eq $v) { continue }
  $volumes += [ordered]@{
    letter=[string]$p.DriveLetter;diskNumber=[int]$p.DiskNumber
    filesystem=[string]$v.FileSystem
    sizeGB=[math]::Round($v.Size/1GB,1)
    freeGB=[math]::Round($v.SizeRemaining/1GB,1)
  }
}
$services = @()
foreach($name in @('GamingServices','GamingServicesNet','XblAuthManager','XblGameSave','XboxNetApiSvc','InstallService')) {
  $s=Collect { Get-Service -Name $name } "Service $name"
  if ($s) { $services += [ordered]@{name=$name;status=[string]$s.Status;startup=[string]$s.StartType} }
  else { $services += [ordered]@{name=$name;status='NotFoundOrUnavailable';startup='Unknown'} }
}
$packages=@()
foreach($p in @(Collect { Get-AppxPackage -ErrorAction Stop | Where-Object { $_.Name -match 'GamingServices|Xbox|GameBar' } } 'Xbox packages')) {
  if ($p) { $packages += [ordered]@{name=[string]$p.Name;version=[string]$p.Version} }
}
$processes=@()
foreach($p in @(Collect { Get-CimInstance Win32_Process | Where-Object {
  $_.Name -match '(?i)^(cod|cod22|cod23|cod24|cod25|codhq|BF2042|GamingServicesUI|XboxPcApp|CrashHandler|CrashReport)\.exe$'
}} 'Gaming process scan')) {
  if ($p) { $processes += [ordered]@{name=[string]$p.Name;pid=[int]$p.ProcessId;parentPid=[int]$p.ParentProcessId} }
}
$secureBoot=Collect { [bool](Confirm-SecureBootUEFI) } 'Secure Boot'
$tpm=Collect { Get-Tpm | Select-Object TpmPresent,TpmReady } 'TPM'
$gameMode=Collect { (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\GameBar' -ErrorAction Stop).AutoGameModeEnabled } 'Game Mode'
$hags=Collect { (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction Stop).HwSchMode } 'HAGS preference'
$insider=Collect { (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\Applicability' -ErrorAction Stop).BranchName } 'Insider branch'
$preference=@()
$gp=Collect { Get-ItemProperty -Path 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -ErrorAction Stop } 'GPU application preferences'
if($gp) {
  foreach($property in $gp.PSObject.Properties) {
    $exe=[IO.Path]::GetFileName([string]$property.Name)
    if ($exe -match '(?i)^(cod|cod22|cod23|cod24|cod25|codhq|BF2042)\.exe$') {
      $preference += [ordered]@{executable=$exe;preference=[string]$property.Value}
    }
  }
}
$appEvents=@(ShortEvents -LogName 'Application' -Ids @(1000,1001,1002))
$sysEvents=@(ShortEvents -LogName 'System' -Ids @(41,1001,4101,17,18,19))
$allEvents=@($appEvents)+@($sysEvents)
$gpuNames=@($graphics | ForEach-Object { $_.name })
if(-not ($gpuNames -match 'RX 9060 XT')) {
  Add-Finding 'GPU-IDENTITY' 'warning' 'Expected RX 9060 XT not confirmed by current GPU inventory.' 'Verify Device Manager and the official AMD graphics driver.' 'medium'
}
else { Add-Finding 'GPU-IDENTITY' 'pass' 'RX 9060 XT detected in current Windows inventory.' 'Preserve stock tuning for baseline gameplay.' 'high' }
if(@($allEvents | Where-Object { $_.category -eq 'GamingServicesUI' }).Count -gt 0) {
  Add-Finding 'GAMING-SERVICES-CRASHES' 'warning' 'GamingServicesUI crash events observed in selected history window.' 'Compare event timestamps to the completed repair and verify whether NEW crashes appear.' 'high'
}
if(@($allEvents | Where-Object { $_.category -eq 'DisplayDriver' }).Count -gt 0) {
  Add-Finding 'GRAPHICS-ERRORS' 'warning' 'Display-driver related events appear in Windows logs.' 'Correlate errors with game crash timestamps; test recommended AMD driver and default tuning.' 'medium'
}
if(@($allEvents | Where-Object { $_.category -eq 'HardwareWHEA' }).Count -gt 0) {
  Add-Finding 'WHEA-EVENTS' 'warning' 'Windows hardware error telemetry appears in event logs.' 'Review detailed WHEA errors locally and evaluate memory, power and hardware stability.' 'medium'
}
foreach($v in $volumes) {
  if($v.letter -eq 'C' -and (PercentFree $v) -lt 15) {
    Add-Finding 'SYSTEM-DISK-SPACE' 'warning' 'C: has less than 15% free storage.' 'Free space or plan a second physical NVMe for games; do not delete user data automatically.' 'high'
  }
}
if(-not @($drives | Where-Object { $_.busType -eq 'NVMe' }).Count) {
  Add-Finding 'NVME-UNCONFIRMED' 'unknown' 'An NVMe disk was not confirmed in storage inventory.' 'Verify Get-Disk output, controller driver and physical storage type.' 'low'
}
if($null -eq $secureBoot -or $null -eq $tpm) {
  Add-Finding 'ATTESTATION-UNKNOWN' 'unknown' 'Secure Boot or TPM state could not be established.' 'Verify in System Information and Windows Security before Call of Duty multiplayer tests.' 'low'
}
elseif(-not $secureBoot -or -not $tpm.TpmReady) {
  Add-Finding 'ATTESTATION' 'warning' 'Secure Boot or TPM readiness is not enabled.' 'Verify firmware settings and game requirements; do not alter BIOS automatically.' 'high'
}
if($os -and [int]$os.BuildNumber -ge 26000) {
  Add-Finding 'WINDOWS-BUILD' 'review' "Windows build $($os.BuildNumber) should be checked for release/Insider status." 'Run winver and review Windows Insider Program; do not downgrade without backup.' 'medium'
}
if(@($processes | Where-Object { $_.name -match '(?i)^cod' }).Count -gt 0) {
  Add-Finding 'COD-PROCESS' 'info' 'A Call of Duty process is currently present.' 'If Xbox shows Running, this may be legitimate; inspect responsiveness before stopping it.' 'high'
}
else {
  Add-Finding 'COD-STATUS-UNOBSERVABLE' 'unknown' 'No recognized Call of Duty process was found at collection time.' 'If Xbox still says Running, capture the app status; the Xbox internal sync flag is not exposed by this collector.' 'high'
}
Add-Finding 'SYNC-BOUNDARY' 'unknown' 'Xbox cloud-save sync status is not available from these Windows inventory APIs.' 'Record the timestamp and text of the Xbox Game sync incomplete notice. Do not clear local or cloud saves.' 'high'
Add-Finding 'PSU-NOT-DETECTABLE' 'review' 'Power supply wattage and quality cannot be read reliably by standard Windows APIs.' 'Confirm PSU model physically against the existing 600W inventory; evaluate reputable 850W replacement separately.' 'high'

$payload=[ordered]@{
 schemaVersion='1.0';mode='live-readonly-discovery-summary'
 source='windows-local-powershell';assetTag=$AssetTag;runId=$runId
 utc=(Get-Date).ToUniversalTime().ToString('o');historyDays=$HistoryDays
 limitations=@('No live game benchmark or stability stress test','No direct access to Xbox cloud sync state','No personal files, game saves, mods, or anti-cheat inspected','No full crash messages or process command lines exported','BIOS/PSU values may require human confirmation')
 hardware=[ordered]@{
  cpu=$(if($cpu){[string]$cpu.Name}else{$null})
  motherboard=$(if($board){[string]$board.Manufacturer+' '+[string]$board.Product}else{$null})
  biosVersion=$(if($bios){[string]$bios.SMBIOSBIOSVersion}else{$null})
  ramGB=[math]::Round((@($memory | Measure-Object -Property Capacity -Sum)[0].Sum)/1GB,1)
  ramConfiguredMHz=@($memory | Where-Object { $_ } | ForEach-Object {[int]$_.ConfiguredClockSpeed} | Select-Object -Unique)
  gpus=$graphics
 }
 windows=[ordered]@{
  caption=$(if($os){[string]$os.Caption}else{$null})
  build=$(if($os){[string]$os.BuildNumber}else{$null})
  insiderBranch=$insider;secureBoot=$secureBoot
  tpmReady=$(if($tpm){[bool]$tpm.TpmReady}else{$null})
  gameModeSetting=$gameMode;hagsRegistrySetting=$hags
  gpuAppPreferences=$preference
 }
 storage=[ordered]@{disks=$drives;volumes=$volumes}
 gaming=[ordered]@{services=$services;packages=$packages;processes=$processes}
 eventSignatures=$allEvents
 findings=@($findings.ToArray())
 collectorWarnings=@($warnings.ToArray())
}
$json=$payload | ConvertTo-Json -Depth 12
$jsonPath=Join-Path $folder 'assessment.json'
[IO.File]::WriteAllText($jsonPath,$json,[Text.UTF8Encoding]::new($false))
$hash=(Get-FileHash -Algorithm SHA256 -LiteralPath $jsonPath).Hash.ToLowerInvariant()
$lines=[System.Collections.Generic.List[string]]::new()
$lines.Add("# CastleOps Windows Gaming Endpoint Assessment")
$lines.Add("")
$lines.Add("**Asset:** $AssetTag  |  **Run:** $runId  |  **Mode:** Read-only")
$lines.Add("")
$lines.Add("**Timestamp (UTC):** $($payload.utc)")
$lines.Add("")
$lines.Add("## Observations and next actions")
$lines.Add("")
$lines.Add("| Severity | Finding | Observation | Next action |")
$lines.Add("|---|---|---|---|")
foreach($f in $findings) {
  $safeObs=([string]$f.observation).Replace('|','/')
  $safeNext=([string]$f.nextAction).Replace('|','/')
  $lines.Add("| $($f.severity) | $($f.id) | $safeObs | $safeNext |")
}
$lines.Add("")
$lines.Add("## Disks and available capacity")
$lines.Add("")
$lines.Add("| Volume | Disk | Filesystem | Free GB | Capacity GB |")
$lines.Add("|---|---|---|---:|---:|")
foreach($v in $volumes) { $lines.Add("| $($v.letter): | $($v.diskNumber) | $($v.filesystem) | $($v.freeGB) | $($v.sizeGB) |") }
$lines.Add("")
$lines.Add("## Evidence and limitations")
$lines.Add("")
$lines.Add("- Local assessment SHA-256: " + $hash)
$lines.Add("- Raw event messages and process command lines were not collected.")
$lines.Add("- Xbox app Running/Sync Incomplete status requires separate UI confirmation.")
$lines.Add("- This run did not launch games, change configuration, or perform remediation.")
$lines.Add("- A WARNING is not proof of root cause; compare with timestamps and additional checks.")
$md=$lines -join [Environment]::NewLine
$mdPath=Join-Path $folder 'REPORT.md'
[IO.File]::WriteAllText($mdPath,$md,[Text.UTF8Encoding]::new($false))
Write-Host "Saved $jsonPath"
Write-Host "Saved $mdPath"
# Generate the policy decision plan locally before local completion.
$planner = Join-Path $PSScriptRoot 'New-GamingRemediationPlan.ps1'
if(-not (Test-Path -LiteralPath $planner)) { throw 'Required policy planner is missing. Local collection incomplete.' }
& $planner -AssessmentPath $jsonPath

Write-Host "Assessment completed. Local report directory: $folder"
# Findings are observations, not a declaration of operational fitness.
