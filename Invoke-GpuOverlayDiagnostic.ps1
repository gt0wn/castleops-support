#Requires -Version 5.1
<#
.SYNOPSIS
  Check GPU driver info and known overlay software for DXGI_ERROR_DEVICE_HUNG
  / DirectX crash troubleshooting. Optionally disable Xbox Game Bar's overlay.
.DESCRIPTION
  Read-only by default: reports installed GPU driver version/date (no network
  call -- compare manually against the vendor's site, this toolkit never
  calls out), scans for known overlay-software processes (Discord, MSI
  Afterburner/RTSS, NVIDIA Share), and reports Xbox Game Bar's in-game-overlay
  (GameDVR) registry state.
  With -Execute: disables ONLY the Xbox Game Bar / GameDVR overlay via its
  documented registry keys -- the one overlay source with a clean, reversible,
  scriptable toggle. Other overlays (Discord, MSI Afterburner) are reported
  only; disable those from inside each app's own settings. Refuses to run
  with -Execute if a recognized game process is active.
.EXAMPLE
  .\Invoke-GpuOverlayDiagnostic.ps1
.EXAMPLE
  .\Invoke-GpuOverlayDiagnostic.ps1 -Execute
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# GPU / overlay diagnostic")
$lines.Add("")
$lines.Add("**Scanned:** $(Get-Date -Format 'yyyy-MM-dd HH:mm') local time")
$lines.Add("")

# --- GPU driver info ---
$lines.Add("## GPU driver")
$lines.Add("")
$gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -notmatch 'Remote Display|Basic Render' }
$lines.Add("| Name | Driver version | Driver date |")
$lines.Add("|---|---|---|")
foreach ($g in $gpus) {
  $dateStr = if ($g.DriverDate) { ([datetime]$g.DriverDate).ToString('yyyy-MM-dd') } else { '(unknown)' }
  $lines.Add("| $($g.Name) | $($g.DriverVersion) | $dateStr |")
}
$lines.Add("")
$lines.Add("This script makes no network calls, so it can't check what the latest version actually is -- compare the date above against the vendor's own driver page (AMD Software / Adrenalin for AMD, NVIDIA App / GeForce Experience for NVIDIA) manually.")
$lines.Add("")

# --- Known overlay software processes ---
$lines.Add("## Overlay software currently running")
$lines.Add("")
$overlayApps = @{
  'Discord'              = 'Discord\.exe'
  'MSI Afterburner'      = 'MSIAfterburner\.exe'
  'RivaTuner Statistics Server (RTSS, used by Afterburner OSD)' = 'RTSS\.exe'
  'NVIDIA Share/ShadowPlay' = 'nvsphelper64|NVIDIA Share'
  'AMD Software overlay'   = 'RadeonSoftware'
}
$processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
$foundAny = $false
$lines.Add("| App | Running? |")
$lines.Add("|---|---|")
foreach ($entry in $overlayApps.GetEnumerator()) {
  $match = @($processes | Where-Object { $_.Name -match $entry.Value })
  $running = $match.Count -gt 0
  if ($running) { $foundAny = $true }
  $lines.Add("| $($entry.Key) | $(if($running){'yes'}else{'no'}) |")
}
$lines.Add("")
if ($foundAny) {
  $lines.Add("Any 'yes' above is a known, documented trigger for DX12 `DEVICE_HUNG`/overlay-related crashes on some driver versions. To test: disable that app's own in-game/on-screen overlay feature from its own settings (not something this script can safely do for third-party apps), then try the game again.")
} else {
  $lines.Add("None of the commonly-implicated third-party overlays were found running.")
}
$lines.Add("")

# --- Xbox Game Bar / GameDVR overlay state ---
$lines.Add("## Xbox Game Bar in-game overlay (GameDVR)")
$lines.Add("")
$gameDvrPath = 'HKCU:\System\GameConfigStore'
$appCapturePath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'
$gameDvrProp = Get-ItemProperty -Path $gameDvrPath -Name 'GameDVR_Enabled' -ErrorAction SilentlyContinue
$appCaptureProp = Get-ItemProperty -Path $appCapturePath -Name 'AppCaptureEnabled' -ErrorAction SilentlyContinue
$gameDvrEnabled = if ($gameDvrProp -and $gameDvrProp.PSObject.Properties['GameDVR_Enabled']) { [bool]$gameDvrProp.GameDVR_Enabled } else { $null }
$appCaptureEnabled = if ($appCaptureProp -and $appCaptureProp.PSObject.Properties['AppCaptureEnabled']) { [bool]$appCaptureProp.AppCaptureEnabled } else { $null }
$currentlyOn = ($gameDvrEnabled -ne $false) -and ($appCaptureEnabled -ne $false)
$lines.Add("Current state: **$(if($currentlyOn){'enabled (or Windows default, which is enabled)'}else{'disabled'})**")
$lines.Add("")
$lines.Add("This is the one overlay source this script can safely and reversibly toggle -- it's also the one most directly tied to the GamingServicesUI issue already diagnosed on this machine, since it's part of the same Xbox/Game Bar subsystem.")
$lines.Add("")

if (-not $Execute) {
  $lines.Add("Preview only -- nothing changed. Re-run with -Execute to disable this overlay.")
  Write-Host "Preview complete. GPU driver, overlay processes, and GameDVR state reported below."
} else {
  $processesForGameCheck = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $gameRx = '(?i)^(cod(\d+)?|codhq|ModernWarfare|bf2042|bf6|gta5|gta5_enhanced|fivem|r5apex|fortniteclient-win64-shipping|rainbowsix|rainbowsix_vulkan)\.exe$'
  $activeGames = @($processesForGameCheck | Where-Object { $_.Name -match $gameRx })
  if ($activeGames.Count -gt 0) {
    $matchedList = @($activeGames | ForEach-Object { "$($_.Name) (PID $($_.ProcessId))" })
    $lines.Add("**BLOCKED**: active game process detected ($($matchedList -join ', ')) -- no changes made. Close games first.")
    Write-Warning "A game appears active: $($matchedList -join ', '). No changes made."
  }
  elseif (-not $currentlyOn) {
    $lines.Add("Already disabled -- no change needed.")
    Write-Host "GameDVR overlay already disabled."
  }
  else {
    Write-Warning "This disables the Xbox Game Bar in-game overlay (screenshots/clips via Win+G stop working). Does not affect games, saves, or other apps."
    $approval = Read-Host "To approve, type exactly APPROVE DisableGameOverlay"
    if ($approval -cne 'APPROVE DisableGameOverlay') {
      $lines.Add("Declined -- approval phrase not provided. No changes made.")
      Write-Warning "Declined. No changes."
    } else {
      if ($PSCmdlet.ShouldProcess('GameDVR overlay', 'Disable')) {
        if (-not (Test-Path $gameDvrPath)) { New-Item -Path $gameDvrPath -Force | Out-Null }
        Set-ItemProperty -Path $gameDvrPath -Name 'GameDVR_Enabled' -Value 0 -Type DWord
        if (-not (Test-Path $appCapturePath)) { New-Item -Path $appCapturePath -Force | Out-Null }
        Set-ItemProperty -Path $appCapturePath -Name 'AppCaptureEnabled' -Value 0 -Type DWord
        $lines.Add("**Done.** GameDVR overlay disabled via registry. A reboot or sign-out/in may be needed for it to fully take effect in-game.")
        Write-Host "GameDVR overlay disabled."
      }
    }
  }
}

$outPath = Join-Path (Get-Location) "GpuOverlayDiagnostic.md"
$lines -join [Environment]::NewLine | Set-Content -LiteralPath $outPath -Encoding UTF8
Write-Host "Saved: $outPath"
