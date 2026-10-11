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
dates), or send anything anywhere on their own. Two scripts have real side
effects and are gated behind an explicit flag plus a typed confirmation before
they do anything — everything else is look-only.

## Quick start — no download, no git clone needed

Run directly from this repo (public, no auth required):

```powershell
irm https://raw.githubusercontent.com/gt0wn/castleops-support/main/Invoke-GamingAuditBundle.ps1 -OutFile Invoke-GamingAuditBundle.ps1
irm https://raw.githubusercontent.com/gt0wn/castleops-support/main/Invoke-GamingEndpointAudit.ps1 -OutFile Invoke-GamingEndpointAudit.ps1
irm https://raw.githubusercontent.com/gt0wn/castleops-support/main/New-GamingRemediationPlan.ps1 -OutFile New-GamingRemediationPlan.ps1
powershell -ExecutionPolicy Bypass -File .\Invoke-GamingAuditBundle.ps1
```

`Invoke-GamingAuditBundle.ps1` needs the other two scripts (collector + planner)
in the same folder — it calls them internally. The three `irm` lines above fetch
all three into your current directory before running.

For the disk-space / services audit instead:

```powershell
irm https://raw.githubusercontent.com/gt0wn/castleops-support/main/Invoke-FullSystemAudit.ps1 -OutFile Invoke-FullSystemAudit.ps1
powershell -ExecutionPolicy Bypass -File .\Invoke-FullSystemAudit.ps1
```

If your PowerShell execution policy blocks even that:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

(`-Scope CurrentUser` keeps it to your account only, no admin rights needed.)

## Scripts

| Script | What it does |
|---|---|
| `Invoke-GamingEndpointAudit.ps1` | Hardware/OS/GPU/driver inventory + categorized recent crash-signature events. Calls the planner automatically at the end. |
| `New-GamingRemediationPlan.ps1` | Turns the assessment into a prioritized, human-approval-gated action list. Never executes anything itself. |
| `Invoke-GamingSafeRemediation.ps1` | The only script with real side effects — two reversible actions (refresh Xbox app launcher state, restart Gaming Services), both require `-Execute` plus typing an exact approval phrase, both refuse to run if a game process is active. |
| `Register-GamingAuditTask.ps1` | Optional: installs a daily local-only scheduled task running the read-only collector. No admin, no network action. |
| `Invoke-GamingAuditBundle.ps1` | Runs the collector, then zips the four sanitized output files (assessment, report, plan x2) with a SHA-256 manifest — the one most people actually want to run. |
| `Invoke-DiskSpaceBreakdown.ps1` | Read-only top-level disk usage breakdown for one drive, flags game-library folders as safe to relocate via their launcher. |
| `Invoke-FullSystemAudit.ps1` | Recursive multi-level disk usage across all fixed drives (finds the real largest folders at any depth, not just top-level) plus a Windows services snapshot. |

## Output

Everything writes to your current directory or `%LOCALAPPDATA%\CastleOps\GamingEndpointAudit\<timestamp>\`
— never anywhere else, never automatically. What you do with the output (keep it,
delete it, send it to someone) is entirely up to you.
