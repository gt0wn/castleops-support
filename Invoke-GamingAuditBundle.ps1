#Requires -Version 5.1
<#
.SYNOPSIS
  Capture sanitized gaming-PC diagnostics, ZIP four reports + manifest, and
  optionally stage the ZIP to a Google Drive for desktop sync folder.
.DESCRIPTION
  Runs the existing local-only read-only audit, packages only allowlisted report
  files, and optionally copies the ZIP into a pre-existing Drive for desktop
  folder. Does not use GitHub tokens or Google API credentials. A successful
  local copy does NOT guarantee cloud sync; verify in drive.google.com.
.EXAMPLE
  .\Invoke-GamingAuditBundle.ps1
.EXAMPLE
  .\Invoke-GamingAuditBundle.ps1 -DriveFolder 'G:\My Drive\John Gaming Reports'
#>
[CmdletBinding()]
param(
    [ValidateRange(1,30)][int]$HistoryDays = 7,
    [ValidatePattern('^[a-z0-9][a-z0-9-]{1,38}$')][string]$AssetTag = 'john-gaming-pc',
    [string]$DriveFolder
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$collector = Join-Path $PSScriptRoot 'Invoke-GamingEndpointAudit.ps1'
$planner = Join-Path $PSScriptRoot 'New-GamingRemediationPlan.ps1'
if (-not (Test-Path -LiteralPath $collector -PathType Leaf) -or
    -not (Test-Path -LiteralPath $planner -PathType Leaf)) {
    throw 'Collector and plan script must be beside this wrapper.'
}
# Fail before collection if requested sync destination is missing; never
# auto-create a folder under an incorrect path or absent Google Drive mount.
$destination = $null
if (-not [string]::IsNullOrWhiteSpace($DriveFolder)) {
    if (-not (Test-Path -LiteralPath $DriveFolder -PathType Container)) {
        throw 'DriveFolder not found. Open Drive for desktop, sign into the intended account, and choose an existing sync folder.'
    }
    $destination = (Resolve-Path -LiteralPath $DriveFolder).ProviderPath
    if (-not [IO.Path]::IsPathRooted($destination)) {
        throw 'DriveFolder must be an absolute local folder path.'
    }
}
$startUtc = (Get-Date).ToUniversalTime()
Write-Host 'Starting read-only CastleOps gaming assessment...'
& $collector -HistoryDays $HistoryDays -AssetTag $AssetTag

$base = Join-Path $env:LOCALAPPDATA 'CastleOps\GamingEndpointAudit'
$candidates = @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction Stop |
    Where-Object {
        $_.Name -match '^\d{8}T\d{6}Z-[a-f0-9]{8}$' -and
        $_.CreationTimeUtc -ge $startUtc.AddSeconds(-5)
    } | Sort-Object CreationTimeUtc -Descending)
if ($candidates.Count -ne 1) {
    throw "Expected one new assessment from this invocation; found $($candidates.Count). No ZIP sent."
}
$runDir = $candidates[0].FullName
$files = @('assessment.json', 'REPORT.md', 'PLAN.json', 'PLAN.md')
foreach ($name in $files) {
    $p = Join-Path $runDir $name
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw "Incomplete assessment: missing $name. No ZIP sent."
    }
}
$assessment = Get-Content -LiteralPath (Join-Path $runDir 'assessment.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$plan = Get-Content -LiteralPath (Join-Path $runDir 'PLAN.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($assessment.schemaVersion -ne '1.0' -or $assessment.mode -ne 'live-readonly-discovery-summary' -or
    $assessment.assetTag -ne $AssetTag -or $assessment.runId -ne $candidates[0].Name -or
    $plan.sourceRunId -ne $assessment.runId -or $plan.mode -ne 'decision-plan-only') {
    throw 'Assessment or plan identity failed validation. No ZIP sent.'
}
$assessmentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $runDir 'assessment.json')).Hash.ToLowerInvariant()
if ($plan.sourceReportSha256 -ne $assessmentHash) {
    throw 'Plan hash does not match the assessment JSON. No ZIP sent.'
}
$name = "$AssetTag-$($assessment.runId).zip"
$zip = Join-Path $runDir $name
$stage = Join-Path ([IO.Path]::GetTempPath()) ('castleops-zip-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    $manifestFiles = @()
    foreach ($file in $files) {
        $src = Join-Path $runDir $file
        $dst = Join-Path $stage $file
        Copy-Item -LiteralPath $src -Destination $dst -ErrorAction Stop
        $manifestFiles += [ordered]@{
            name = $file
            sizeBytes = (Get-Item -LiteralPath $dst).Length
            sha256 = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $manifest = [ordered]@{
        schemaVersion = '1.0'
        assetTag = $AssetTag
        runId = [string]$assessment.runId
        packagedUtc = (Get-Date).ToUniversalTime().ToString('o')
        source = 'local-readonly-gaming-assessment'
        contents = $manifestFiles
        exclusions = @('No game/mod/save files', 'No full event logs or command lines',
            'No authentication tokens or account identifiers', 'No remediation')
    }
    $manifest | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $stage 'MANIFEST.json') -Encoding UTF8
    $packageFiles = @($files | ForEach-Object { Join-Path $stage $_ })
    $packageFiles += (Join-Path $stage 'MANIFEST.json')
    Compress-Archive -LiteralPath $packageFiles -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop

    # Round-trip ZIP shape check; opening the archive does not extract content.
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $names = @($archive.Entries | ForEach-Object { $_.FullName })
        if ($names.Count -ne 5 -or
            @($names | Where-Object { $_ -notin (@($files) + 'MANIFEST.json') }).Count -ne 0) {
            throw 'Unexpected ZIP members, refusing delivery.'
        }
    } finally { $archive.Dispose() }
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

$localHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "ZIP created: $zip"
Write-Host "SHA256: $localHash"
if ($null -ne $destination) {
    $remote = Join-Path $destination $name
    if (Test-Path -LiteralPath $remote) {
        throw 'A file with this run ID already exists in the sync folder. Refusing overwrite.'
    }
    Copy-Item -LiteralPath $zip -Destination $remote -ErrorAction Stop
    $remoteHash = (Get-FileHash -LiteralPath $remote -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($remoteHash -ne $localHash) {
        throw 'Local copy hash mismatch. Do not trust this staged upload.'
    }
    Write-Host "STAGED FOR GOOGLE DRIVE SYNC: $remote"
    Write-Warning 'Staging is not proof of cloud delivery. Verify this ZIP exists at drive.google.com before treating the run as published.'
}
else {
    Write-Host 'ZIP saved locally. No remote destination supplied; no upload attempted.'
}
Write-Host "Run ID: $($assessment.runId)"
