#Requires -Version 5.1
<#
.SYNOPSIS
  Install or remove an opt-in daily, read-only CastleOps gaming audit task.
.DESCRIPTION
  Scheduled task runs as the signed-in user, without elevation or embedded
  credentials. It never runs remediation or publishes endpoint data.
  GitHub uploads require a separate trusted publisher.
.EXAMPLE
  .\Register-GamingAuditTask.ps1 -Install -At 19:00
.EXAMPLE
  .\Register-GamingAuditTask.ps1 -Install -At 19:00 -Replace
.EXAMPLE
  .\Register-GamingAuditTask.ps1 -Remove
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [switch]$Install,[switch]$Remove,
  [switch]$Replace,
  [ValidatePattern('^(?:[01][0-9]|2[0-3]):[0-5][0-9]$')]
  [string]$At='19:00',
  [ValidatePattern('^[a-z0-9][a-z0-9-]{1,38}$')]
  [string]$AssetTag='john-gaming-pc'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([bool]$Install -eq [bool]$Remove){
  throw 'Specify exactly one of -Install or -Remove.'
}
$taskName='CastleOps - Gaming Endpoint ReadOnly Audit'
if($Remove) {
  if($PSCmdlet.ShouldProcess($taskName,'Remove scheduled task')){
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    Write-Host "Removed scheduled task: $taskName"
  }
  return
}
$script=Join-Path $PSScriptRoot 'Invoke-GamingEndpointAudit.ps1'
$planner=Join-Path $PSScriptRoot 'New-GamingRemediationPlan.ps1'
if(-not (Test-Path -LiteralPath $script) -or -not (Test-Path -LiteralPath $planner)){
  throw 'Keep the collector and planner in the same folder before installation.'
}
$existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($existing -and -not $Replace){throw "Task already exists. Use -Replace to update explicitly."}
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments='-NoLogo -NoProfile -NonInteractive -File "' + $script + '" -AssetTag "' + $AssetTag + '"'
$trigger=New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($At,'HH:mm',[Globalization.CultureInfo]::InvariantCulture))
$action=New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $PSScriptRoot
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
$identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal=New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
if($PSCmdlet.ShouldProcess($taskName,"Install daily $At local-only read-only assessment task")){
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force:$Replace -ErrorAction Stop | Out-Null
  Write-Host "Scheduled: daily $At, interactive Windows identity $identity."
  Write-Host 'Publication disabled by policy. No remediation runs unattended.'
  Write-Host 'Windows user must be signed in; missed runs require a subsequent opportunity to start.'
}
