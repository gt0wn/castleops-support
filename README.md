# CastleOps Support Scripts

Read-only Windows diagnostic scripts, public and safe to inspect before running. No
credentials, no network calls to anything but local Windows APIs, no persistent
remote access, no telemetry. Written for one specific use case (diagnosing a
friend's gaming PC) but generic enough to be useful on any Windows 10/11 machine.

## What these do and don't do

**Do:** read hardware/OS/driver info, Windows event logs (categorized, not raw),
disk usage by folder, and Windows services status. Write plain local report files
(JSON/Markdown) that you choose what to do with.

**Never:** modify files, change settings, start/stop services, delete anything,
read the *contents* of your documents/photos/saves (only names, sizes, paths,
dates), or send anything anywhere on their own. Three scripts have real side
effects and are gated behind an explicit flag plus a typed confirmation before
they do anything — everything else is look-only.

## Execution policy — do this first if scripts won't run at all

Windows blocks `.ps1` files from running at all by default. This is scoped to
your account only, no admin rights needed:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

## Quick start — no download, no git clone needed

Everything below runs directly from this repo (public, no auth required).

### Pull every script at once (do this first)

```powershell
cd C:\temp
$files = @(
  'Invoke-DiskSpaceBreakdown.ps1',
  'Invoke-FolderBreakdown.ps1',
  'Invoke-FullSystemAudit.ps1',
  'Invoke-GamingAuditBundle.ps1',
  'Invoke-GamingEndpointAudit.ps1',
  'Invoke-GamingSafeRemediation.ps1',
  'Invoke-GamingServicesPackageReset.ps1',
  'Invoke-GpuOverlayDiagnostic.ps1',
  'Invoke-SteamLibraryValidation.ps1',
  'Invoke-TempProfileDiagnostic.ps1',
  'New-GamingRemediationPlan.ps1',
  'Register-GamingAuditTask.ps1'
)
foreach ($f in $files) { irm "https://raw.githubusercontent.com/gt0wn/castleops-support/main/$f" -OutFile $f }
Get-ChildItem *.ps1 | Select-Object Name, Length
```

Re-run this block any time to refresh to the latest version of everything.

### Gaming endpoint audit (hardware/GPU/driver + crash events)

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-GamingAuditBundle.ps1
```

Needs `Invoke-GamingEndpointAudit.ps1` and `New-GamingRemediationPlan.ps1` in the
same folder — it calls them internally. Produces `assessment.json`, `REPORT.md`,
`PLAN.json`, `PLAN.md`, and a ready-to-send ZIP of all four.

### Full system audit (disk usage across all drives + services)

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-FullSystemAudit.ps1
```

Finds the real largest folders at any depth (not just top-level), across every
fixed drive, plus a Windows services snapshot. Saves `FullSystemAudit.md`.

### Drill into one specific folder

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-FolderBreakdown.ps1 -Path "C:\Users\<name>\AppData\Local\Google"
```

Same logic as the full audit, scoped to one folder tree so it runs fast and deep
for investigating a single suspicious folder. Saves `FolderBreakdown-<name>.md`.

### Steam library validation (after moving games between drives)

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-SteamLibraryValidation.ps1
```

Auto-detects every registered Steam library folder from `libraryfolders.vdf` and
cross-checks each game's manifest against what's actually on disk — catches a
move that silently broke Steam's bookkeeping. Does **not** confirm a game
actually launches; that still needs a human to click Play. Saves
`SteamLibraryValidation.md`.

### Gaming Services package reset (fixes recurring 0xC0000374 crashes)

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-GamingServicesPackageReset.ps1
```

If `GamingServicesUI` keeps crashing with event `0xC0000374`
(`STATUS_HEAP_CORRUPTION`) in Windows' Application log, that's a corrupted
Gaming Services app package, not a GPU/driver issue. With no flag, shows a
`-WhatIf` preview only — nothing changes. To actually reset it:

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-GamingServicesPackageReset.ps1 -Execute
```

Requires typing an exact approval phrase, refuses to run if a recognized game
process is active, and clears only the package's own cache/state — never your
games, saves, or other app data.

### Temporary profile diagnostic

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-TempProfileDiagnostic.ps1
```

Run this if Windows says *"You've been signed in with a temporary profile."*
Checks free space, the profile registry state, and recent User Profile Service
event log errors — tells you the actual cause before anything gets changed.
Saves `TempProfileDiagnostic.md`.

## Scripts

| Script | What it does |
|---|---|
| `Invoke-GamingEndpointAudit.ps1` | Hardware/OS/GPU/driver inventory + categorized recent crash-signature events. Calls the planner automatically at the end. |
| `New-GamingRemediationPlan.ps1` | Turns the assessment into a prioritized, human-approval-gated action list. Never executes anything itself. |
| `Invoke-GamingSafeRemediation.ps1` | Two reversible actions (refresh Xbox app launcher state, restart Gaming Services) — both require `-Execute` plus typing an exact approval phrase, both refuse to run if a game process is active. |
| `Register-GamingAuditTask.ps1` | Optional: installs a daily local-only scheduled task running the read-only collector. No admin, no network action. |
| `Invoke-GamingAuditBundle.ps1` | Runs the collector, then zips the four sanitized output files (assessment, report, plan x2) with a SHA-256 manifest — the one most people actually want to run. |
| `Invoke-DiskSpaceBreakdown.ps1` | Read-only top-level disk usage breakdown for one drive, flags game-library folders as safe to relocate via their launcher. |
| `Invoke-FullSystemAudit.ps1` | Recursive multi-level disk usage across all fixed drives (finds the real largest folders at any depth, not just top-level) plus a Windows services snapshot. |
| `Invoke-FolderBreakdown.ps1` | Same recursive logic as the full audit, scoped to one folder you specify — fast, deep drill-down instead of a whole-drive scan. |
| `Invoke-SteamLibraryValidation.ps1` | Cross-checks Steam's own manifests against what's actually on disk, across every registered library folder. Catches a broken move. |
| `Invoke-TempProfileDiagnostic.ps1` | Read-only root-cause check for a Windows "temporary profile" problem — free space, profile registry state, event log errors. |
| `Invoke-GamingServicesPackageReset.ps1` | Resets the Gaming Services app package — the real fix for recurring `GamingServicesUI` `0xC0000374` crashes. `-Execute` plus typed approval required; refuses to run if a game is active. |
| `Invoke-GpuOverlayDiagnostic.ps1` | Reports GPU driver version/date and known overlay software (Discord, MSI Afterburner, etc.) for `DXGI_ERROR_DEVICE_HUNG` troubleshooting. Can disable Xbox Game Bar's overlay specifically — `-Execute` plus typed approval required. |

## Output

Everything writes to your current directory or `%LOCALAPPDATA%\CastleOps\GamingEndpointAudit\<timestamp>\`
— never anywhere else, never automatically. What you do with the output (keep it,
delete it, send it to someone) is entirely up to you.
