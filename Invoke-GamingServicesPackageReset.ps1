#Requires -Version 5.1
<#
.SYNOPSIS
  Reset the Gaming Services app package to a clean state -- the real fix for
  recurring GamingServicesUI STATUS_HEAP_CORRUPTION (0xC0000374) crashes.
.DESCRIPTION
  Uses the built-in Reset-AppxPackage cmdlet -- the exact PowerShell equivalent
  of Settings > Apps > Gaming Services > Advanced options > Reset. Clears the
  package's own local cache/state; does not touch game saves, which live with
  the games themselves or in the cloud, not inside this package.
  With no -Execute: shows what would happen (Reset-AppxPackage -WhatIf) and
  current package info, changes nothing.
  With -Execute: requires a typed approval phrase, refuses if a recognized game
  process is active, then performs the real reset and verifies the package is
  still present and healthy afterward.
.EXAMPLE
  .\Invoke-GamingServicesPackageReset.ps1
.EXAMPLE
  .\Invoke-GamingServicesPackageReset.ps1 -Execute
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$base = Join-Path $env:LOCALAPPDATA 'CastleOps\GamingEndpointAudit'
$id = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + ([guid]::NewGuid().ToString('N').Substring(0,8))
$out = Join-Path $base "gamingservices-reset-$id"
New-Item -ItemType Directory -Path $out -Force | Out-Null
$state = [ordered]@{
  schemaVersion='1.0'; mode='attended-package-reset'
  startUtc=(Get-Date).ToUniversalTime().ToString('o')
  executionRequested=[bool]$Execute; status='not-executed'
  package=$null; notes=@()
}

function Save {
  $state.finishUtc = (Get-Date).ToUniversalTime().ToString('o')
  $json = Join-Path $out 'reset-record.json'
  $state | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $json -Encoding UTF8
  Write-Host "Record: $json"
}

try {
  $pkg = Get-AppxPackage -Name '*GamingServices*' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $pkg) {
    $state.status = 'not-found'
    $state.notes = @('No Gaming Services package found for the current user. Nothing to reset.')
    Write-Warning $state.notes[0]
  } else {
    $state.package = [ordered]@{ Name=$pkg.Name; PackageFullName=$pkg.PackageFullName; Version=$pkg.Version.ToString() }
    Write-Host "Found: $($pkg.PackageFullName)"

    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $gameRx = '(?i)^(cod(\d+)?|codhq|ModernWarfare|bf2042|bf6|gta5|gta5_enhanced|fivem|r5apex|fortniteclient-win64-shipping|rainbowsix|rainbowsix_vulkan)\.exe$'
    $activeGames = @($processes | Where-Object { $_.Name -match $gameRx })

    if ($activeGames.Count -gt 0) {
      $state.status = 'blocked-game-active'
      $state.notes = @('Detected an active protected game executable; no reset attempted.', 'Close games normally first.')
      Write-Warning "A game appears active. No changes made."
    }
    elseif (-not $Execute) {
      $state.status = 'plan-only'
      Write-Host ""
      Write-Host "DRY RUN -- what Reset-AppxPackage would do:"
      Reset-AppxPackage -Package $pkg.PackageFullName -WhatIf
      $state.notes = @('Preview only. Re-run with -Execute and typed approval to actually reset.')
    }
    else {
      Write-Warning "This clears Gaming Services' own local cache/state (not game saves, not your games). This may interrupt any in-progress Xbox app session."
      $approval = Read-Host "To approve, type exactly APPROVE ResetGamingServices"
      if ($approval -cne 'APPROVE ResetGamingServices') {
        $state.status = 'declined'
        $state.notes = @('Approval phrase was not provided. No changes made.')
        Write-Warning 'Declined. No changes.'
      } else {
        if ($PSCmdlet.ShouldProcess($pkg.PackageFullName, 'Reset Appx package')) {
          Reset-AppxPackage -Package $pkg.PackageFullName -Confirm:$false
          Start-Sleep -Seconds 2
          $after = Get-AppxPackage -Name '*GamingServices*' -ErrorAction SilentlyContinue | Select-Object -First 1
          if ($after) {
            $state.status = 'completed'
            $state.notes = @("Reset completed. Package still present: $($after.PackageFullName).", 'Reopen the Xbox app and test. If GamingServicesUI crashes (event 0xC0000374) continue after this, the next step is a full uninstall + reinstall of the Xbox app via the Microsoft Store.')
            Write-Host "Reset completed."
          } else {
            $state.status = 'reset-then-missing'
            $state.notes = @('Reset ran without error, but the package could not be found afterward. Reinstall the Xbox app from the Microsoft Store.')
            Write-Warning $state.notes[0]
          }
        }
      }
    }
  }
}
catch {
  $state.status = 'error'
  $state.notes = @("Action ended with $($_.Exception.GetType().Name): $($_.Exception.Message)")
  Write-Warning $state.notes[0]
}
finally {
  Save
}
if ($state.status -eq 'error') { exit 1 }
