# WinAdvisor

**Adaptive Windows 11 maintenance advisor, diagnostics toolkit and cleanup orchestrator.**

> Diagnose first. Recommend second. Execute last.

WinAdvisor answers one question about the machine it runs on:

> *What is actually consuming resources here, why, and what can I safely do about it?*

It is not a PC cleaner, a debloater or a RAM optimiser. It inspects a specific machine,
works out which of its findings actually apply, explains the evidence behind each one, and
drives native and vendor tools to act — only after you have approved each action
individually.

It is useful even if you never clean anything. `View Specs` alone is a thorough,
strictly read-only Windows diagnostic report.

---

## Contents

- [Quick start](#quick-start) · [What makes it different](#what-makes-it-different)
- [Modes](#modes) · [Safety model](#safety-model) · [Risk and confidence](#risk-and-confidence)
- [Providers](#providers) · [External integrations](#external-integrations)
- [Configuration](#configuration) · [Rollback](#rollback) · [Reports and logs](#reports-and-logs)
- [Adding a provider](#adding-a-provider) · [Testing](#testing)
- [Troubleshooting](#troubleshooting) · [Limitations](#limitations)

---

## Quick start

No installation. Clone or download, then:

```powershell
# Interactive menu. Read-only until you explicitly choose a cleanup mode.
.\WinAdvisor.ps1

# A complete, read-only machine specification.
.\WinAdvisor.ps1 -Mode ViewSpecs

# Full analysis with findings and evidence.
.\WinAdvisor.ps1 -Mode Analyze

# The entire pipeline with nothing changed. The best way to see what it would do.
.\WinAdvisor.ps1 -Mode DryRun
```

If PowerShell blocks the script, either unblock the downloaded files or run it for this
session only:

```powershell
Get-ChildItem -Recurse | Unblock-File
# or
powershell -ExecutionPolicy Bypass -File .\WinAdvisor.ps1
```

**Requirements:** Windows 11 (build 22000+) for changes; analysis runs on any Windows.
Windows PowerShell 5.1 or PowerShell 7+. No modules to install. Elevation is *not* required
— it is requested only for specific actions that genuinely need it.

---

## What makes it different

**It adapts to the machine.** A workstation running Docker, WSL, four package managers and
three IDEs gets a completely different analysis from an office laptop, because detection
drives the questions and the recommendations rather than a fixed checklist.

**Every recommendation carries its evidence.** What was measured, how, whether the
measurement was complete, the exact command that will run, what changes, what it costs, and
whether it can be undone.

**It delegates rather than reimplements.** Component store cleanup goes through DISM. NuGet
caches through `dotnet nuget locals`. Docker through the Docker CLI. Hibernation through
`powercfg`. WinAdvisor decides *what* and *why*; the vendor's own tool does the *how*.

**It measures honestly.**

- A location that could not be read is reported as `unknown`, never as `0`.
- A scan that hit its budget reports a lower bound, rendered as "at least".
- Predicted and measured savings are separate fields; a prediction is never reported as a
  result.
- **No performance claim is made anywhere.** Storage recovered and configuration changed
  are measured. Speed is not measured, so it is not claimed.

**It says no.** Docker volumes, WSL disks, the Recycle Bin, duplicates, unknown services and
unknown startup items are explained but never acted on. When safety cannot be positively
established, the answer is refusal.

---

## Modes

```
[1]  View specs                  full machine inventory            read-only
[2]  System analysis             findings and evidence             read-only
[3]  Storage analysis            where the space went              read-only
[4]  Startup and memory          what runs and what it costs       read-only
[5]  Generate maintenance plan   proposed actions only             read-only
[8]  Dry run                     full pipeline, no changes         read-only

[6]  Interactive cleanup         approve, then execute             changes the machine
[7]  Custom cleanup              choose providers first            changes the machine
[10] Rollback and recovery       restore recorded state            changes the machine

[9]  Reports and sessions        [11] Settings        [0] Exit
```

Every mode is also a command-line switch: `-Mode ViewSpecs`, `-Mode DryRun`, and so on.

### View Specs

Read-only, and thorough. Windows edition, version, build, install date and uptime;
manufacturer, model, chassis, firmware type, BIOS version, Secure Boot state and masked
serial; CPU topology and clocks; memory modules with rated and configured speeds, plus
commit charge against the commit limit; GPUs with real VRAM read from the driver key;
physical disks, volumes, filesystem usage and BitLocker state; pagefile, crash dump
configuration, hibernation, Fast Startup, power plan, System Protection, servicing state,
component store, optional features; detected workloads; installed applications and Store
packages; startup items by category; and top memory consumers.

### Storage analysis

Explains where the space went, by category, and reports what it could **not** attribute.
That unattributed figure is deliberate: a storage report that silently accounts for 40% of
a disk invites you to assume the other 60% is junk.

Deep scanning is never implicit. To look inside a specific directory:

```powershell
.\WinAdvisor.ps1 -Mode Storage -DeepScanPath 'D:\Projects'
```

### Dry Run

The complete pipeline — discovery, analysis, questions, planning, approval simulation,
command generation, reporting — with the final step withheld. It is the same code as a real
run in a session the execution engine refuses to act on, not a separate simulation.

The approval simulation shows exactly which items would have been batch-approved and which
would still need a decision, and why.

---

## Safety model

Seven independent layers. A bug in one does not open the others.

1. **Session mode** — `ReadOnly` is set once at construction from the mode and never
   flipped. Choosing cleanup from the menu creates a *new* session.
2. **Policy** — `Config/policies.json` sets a minimum risk per operation kind, so a service
   change cannot be presented as SAFE. Not overridable from a user config file.
3. **Approved roots** — a file delete references a root *by key*, resolved against roots
   registered this session. A hand-edited plan cannot point somewhere else.
4. **Command catalog** — providers supply a catalog id, never a command line. Windows tools
   resolve through System32, not PATH. No shell is ever involved.
5. **Approval fingerprint** — an approval is bound to the exact content of an action. Change
   anything about what would run and the approval no longer matches.
6. **Privilege** — actions needing administrator rights are blocked with an explanation,
   never silently skipped.
7. **Per-file validation** — every file is re-checked at the moment of deletion, including
   that its size and timestamp still match what you reviewed.

### Never, under any circumstances

Personal documents · files matched by extension pattern · directories judged by size alone ·
source repositories · databases · VM disks · Docker volumes · WSL distributions · browser
credentials, bookmarks, autofill, cookies, history or sessions · restore points · WinSxS
contents · Prefetch · any security feature · unknown services · unknown startup items ·
uninstalling applications · installing third-party tools.

The full audit, including the five issues found during the adversarial review and how they
were fixed, is in [docs/SAFETY.md](docs/SAFETY.md).

---

## Risk and confidence

Two independent axes, never blended into one score.

| Risk | Meaning |
|---|---|
| `SAFE` | Clearly disposable, no meaningful user impact. |
| `LOW` | Regenerable caches. Costs time to rebuild, nothing else. |
| `MODERATE` | Affects startup behaviour or application state. |
| `HIGH` | Persistent OS configuration, or materially affects functionality. Always individually approved. |
| `MANUAL-ONLY` | Explained, never executed. Personal data, ambiguity, or anything the toolkit cannot confidently understand. |

| Confidence | Meaning |
|---|---|
| `HIGH` | Directly measured, well understood. |
| `MEDIUM` | Measured, with some inference. |
| `LOW` | Inferred; verify before acting. |
| `UNKNOWN` | Could not be established. |

They are separate because the dangerous combination is specific:

```
Clear browser cache              LOW  risk   HIGH confidence   -> safe to batch approve
Unused-looking 38 GB directory   HIGH risk   LOW  confidence   -> manual review only
```

### Approval

The plan is presented in full before anything runs:

```
[A] Approve everything up to LOW risk in one go
[R] Review every item individually
[C] Cancel and change nothing
```

HIGH-risk items are never included in a batch. They require typing `YES` in full, per item.
MANUAL-ONLY items cannot be approved at all.

---

## Providers

20 providers, auto-discovered from `Providers/*.ps1`.

| Provider | Scope | Acts? |
|---|---|---|
| `Windows.Temp` | Temp, WER, crash dumps, shader caches, thumbnail cache | Yes |
| `Windows.Servicing` | Component store via DISM; Windows.old | DISM only |
| `Windows.Startup` | Run keys, startup folders, logon tasks | Yes, reversibly |
| `Windows.Services` | Service inventory | No — advisory |
| `Windows.Hibernation` | hiberfil.sys / Fast Startup trade-off | Yes, reversibly |
| `Windows.RestorePoints` | System Protection state | No — never removes one |
| `Windows.RecycleBin` | Recycle Bin size | No — advisory |
| `Windows.DeliveryOptimization` | DO cache | No — advisory |
| `Browsers.Chromium` | Chrome, Edge, Brave, Vivaldi, Opera caches | Cache only |
| `Browsers.Firefox` | Firefox cache | Cache only |
| `Containers.Docker` | Build cache, images, containers | Yes; volumes never |
| `Containers.Wsl` | Distributions and virtual disks | No — advisory |
| `Dev.DotNet` | NuGet caches via the official CLI | Yes |
| `Dev.Node` | npm, pnpm, Yarn, Bun | Yes |
| `Dev.Python` | pip, uv | Yes |
| `Dev.Jvm` | Gradle, Maven, Coursier | Yes |
| `Dev.Rust` | Cargo registry caches | Yes |
| `Dev.Editors` | VS Code, JetBrains, Visual Studio caches | Yes |
| `Storage.LargeFiles` | Large files by category | No — advisory |
| `External.Czkawka` | Duplicate detection | No — report only, opt-in |

Per-provider detail, including exactly what each does and does not touch, is in
[docs/PROVIDERS.md](docs/PROVIDERS.md).

### Developer workstation awareness

Only **global, regenerable caches** are ever proposed. Never touched: `node_modules`,
`bin`, `obj`, `dist`, `build`, `target`, `.vscode`, `.idea`, virtual environments, Git
repositories, Docker volumes, WSL distributions, database directories.

Two cases deserve specific mention because the filesystem does not distinguish them:

- **Maven's local repository** is MODERATE, not LOW. `mvn install` writes locally built
  artefacts alongside downloaded ones, and those may exist nowhere else.
- **pnpm's store** is never file-deleted. Installed projects hard-link into it, so only
  `pnpm store prune` is used.

---

## External integrations

WinAdvisor **never downloads or installs anything.** A provider with an external dependency
requires three things, all of which must be true:

1. the provider enabled in `Config/providers.json` (Czkawka is off by default);
2. `Safety.AllowExternalTools` set to `true` in your configuration (off by default);
3. the tool already present on PATH.

If a dependency is missing, the report says so and explains the options rather than
proceeding silently.

Czkawka, the only current integration, is invoked in report-only mode. **No deletion
argument exists in the command catalog**, so no configuration turns it into a deleting
provider.

---

## Configuration

Two files, deliberately separate.

**`Config/defaults.json`** — your preferences. Copy it, edit the copy, pass it with
`-ConfigPath`. A partial file is merged over the defaults, so state only what you are
changing.

```jsonc
{
  "Scanning": {
    "MinimumTempAgeDays": 7,       // never propose a temp file younger than this
    "MinimumCacheAgeDays": 14,
    "LargeFileThresholdMB": 1024,
    "MaxEntriesPerRoot": 50000,    // scan budget, per directory
    "MaxScanSecondsPerRoot": 8,
    "ExcludedPaths": []
  },
  "Risk": {
    "MaximumAutoApprovableRisk": "LOW",       // ceiling for batch approval
    "RequireIndividualApprovalAtOrAbove": "HIGH"
  },
  "Safety": {
    "CreateRestorePointBeforeHighRisk": true,
    "AllowExternalTools": false,
    "AllowDismAnalyze": true
  },
  "Reporting": { "Formats": ["Html", "Json"], "IncludeProcessPaths": true },
  "Logging":   { "Verbosity": "Normal" },
  "Providers": { "Enabled": [], "Disabled": [], "Settings": {} }
}
```

**`Config/policies.json`** — the safety policy: operation risk floors, protected paths,
protected services, never-deleted file types, and the (intentionally empty) curated service
recommendation list. **Not overridable from a user config file.** Editing it is editing the
project's safety guarantees.

Other useful switches:

```powershell
-IncludeProvider Dev.DotNet, Containers.Docker   # only these
-ExcludeProvider Browsers.Chromium               # everything but these
-DeepScanPath 'D:\Projects'                      # authorise recursion here
-ReportPath 'C:\Reports'
-NonInteractive                                  # never prompt; approves nothing
-PassThru                                        # return the session object
```

---

## Rollback

Reversible changes record their prior state before anything happens, written to disk
immediately so an interrupted run is still reversible:

```
Data/Rollback/<SessionId>/
├── metadata.json    machine and session context
├── actions.json     what was attempted and what happened
└── state.json       captured prior state
```

```powershell
Get-WaRollbackSession | Format-Table SessionId, StartedUtc, RecordCount, PendingCount
Invoke-WaRollback -SessionId WA-20260917-171818-141d1aef
```

Restoration is conservative. It reads the current value first: if it already matches the
recorded prior state, nothing is written. If it matches neither the prior value nor the
value WinAdvisor set, something else changed it since, and the record is skipped with an
explanation rather than overwriting whatever that was. `-Force` overrides.

**Deleted files are not recoverable.** WinAdvisor does not copy files before deleting them,
so it does not pretend otherwise:

```
Rollback unavailable.
The deleted content was classified as regenerable.
```

That is why only regenerable content is ever proposed for deletion.

---

## Reports and logs

```
Data/Reports/<SessionId>.html     self-contained report
Data/Reports/<SessionId>.json     same content, structured
Data/Logs/<SessionId>.log         human-readable
Data/Logs/<SessionId>.jsonl       one JSON object per line
Data/Sessions/<SessionId>.json    session summary
```

The HTML report has **no external resources** — no CDN, no fonts, no scripts fetched at view
time. A report describing your machine should not phone anywhere when you open it, and it
has to work offline. It adapts to light and dark colour schemes.

**Never logged or reported:** passwords, tokens, browser credentials, file contents, secret
environment variables, or process command lines — the last because command lines routinely
contain credentials. Machine serial numbers are masked to the final four characters so a
report can be shared when asking for help. Every string written passes a redaction filter,
because provider output is third-party text.

---

## Adding a provider

Drop a `.ps1` file in `Providers/`. It is discovered automatically.

```powershell
Register-WaProvider -Name 'Vendor.Thing' -Order 400 `
    -Title 'Thing caches' `
    -Category 'Developer tooling' `
    -Description 'What this covers, and explicitly what it does not touch.' `
    -Reference 'https://vendor.example/docs/cache' `
    -TestAvailable {
        param($Session)
        if (-not (Resolve-WaCommandPath -Name 'thing')) {
            return (New-WaProviderAvailability -Available $false -Reason 'thing is not on PATH.')
        }
        New-WaProviderAvailability -Available $true
    } `
    -GetInventory { param($Session) @() } `
    -GetAnalysis  { param($Session, $Inventory) @() } `
    -GetCleanupCandidates {
        param($Session, $Inventory)
        @(Get-WaCacheRootCandidate -Session $Session -Provider 'Vendor.Thing' `
            -Key 'vendor.thing.cache' -Title 'Thing cache' -Category 'Package-manager caches' `
            -Path (Join-Path (Get-WaBasePaths).LocalAppData 'Thing\Cache') `
            -AgeDays $Session.Config.MinimumCacheAgeDays `
            -Risk 'LOW' -Confidence 'HIGH' `
            -Explanation 'Downloaded artefacts. Re-fetched on demand.')
    } `
    -GetCleanupPlan {
        param($Session, $Candidates)
        @(foreach ($candidate in $Candidates) {
            New-WaFileCleanupRecommendation -Session $Session -Candidate $candidate `
                -Consequence 'The next run re-downloads what it needs.'
        })
    } | Out-Null
```

Rules that are enforced, not merely suggested:

- **Never call a mutating primitive.** Emit typed operations; the core executes them. Adding
  `Remove-Item` to a provider is a design error, and the audit will find it.
- **Prefer the vendor's own command** via `New-WaCommandRecommendation` and a catalog entry.
  Fall back to a file manifest only where no official mechanism exists.
- **Ask the tool where its data lives.** Do not hard-code a cache path; they move.
- **State the consequence.** Every recommendation says what the user loses.
- **Use MANUAL-ONLY freely.** `New-WaAdvisoryRecommendation` is the right answer whenever
  personal data, ambiguity or irreversibility is involved.
- Add per-provider settings to `Config/providers.json`, and a row to `docs/PROVIDERS.md`.

---

## Testing

```powershell
pwsh -NoProfile -File Tests/Test-Syntax.ps1     # parse gate
pwsh -NoProfile -File Tests/Run-Tests.ps1       # Pester 5 suite
pwsh -NoProfile -File Tests/Run-Tests.ps1 -Tag Safety
```

174 tests covering path safety and traversal, protected paths, services, startup items and
file types, risk and confidence vocabularies, operation policy floors, read-only guarantees,
approval enforcement and tampering, MANUAL-ONLY refusal at four layers, command catalog
integrity and argument injection, configuration validation, provider contract and failure
isolation, real file deletion in a sandbox, manifest re-validation, idempotency, and
rollback capture and restoration including crafted-record refusal.

Pester 5 is required and is **not** installed automatically — a project that tells you to
distrust silent downloads should not perform one.

---

## Troubleshooting

**"Component store analysis was not requested in this mode."**
DISM analysis needs elevation and runs in System Analysis, not View Specs. Run elevated and
choose `[2]`.

**"BitLocker state was not readable."**
`Get-BitLockerVolume` needs an elevated session on most editions.

**"Restore points could not be enumerated."**
The same: run elevated to see them.

**"The Docker CLI is installed but the engine did not respond."**
Docker Desktop is not running. Start it, or skip Docker when asked.

**An action is blocked as needing administrator rights.**
Intended. Actions are never silently skipped. Accept the offered elevated relaunch — it
repeats discovery and asks for approval again in that session, deliberately (see ADR-004).

**Analysis takes several minutes.**
Expected on a developer machine with large caches. Each directory has an 8-second budget and
there are ~25 of them. Lower `MaxScanSecondsPerRoot` for speed at the cost of completeness,
or use `-IncludeProvider` to narrow the run. `ViewSpecs` is fast.

**Fewer bytes reclaimed than estimated.**
Almost always locked files. Close the browser or editor and re-run. The report shows
reviewed, deleted and skipped counts separately.

**Free-space change does not match the reported figure.**
Expected, and explained in the report. Windows writes to disk continuously during a run.
*Measured during execution* is the defensible number; free-space change is context only.

---

## Limitations

Stated plainly.

- **Windows only**, and changes are limited to 64-bit Windows 11 client builds (22000+).
  Analysis runs anywhere Windows does.
- **Current user scope.** Other user profiles are not inspected. Per-user caches and Recycle
  Bin contents for other accounts are not measured, and that is reported rather than
  silently omitted.
- **Portable applications are invisible** to the installed-application inventory, which
  reads the uninstall registry.
- **Some measurements need elevation**: component store, BitLocker, restore points, Secure
  Boot.
- **Logical sizes, not physical allocation.** Figures may differ on compressed, deduplicated
  or sparse volumes.
- **Scans are bounded** and partial results say so. They understate; they never overstate.
- **No application uninstallation.** Use Bulk Crap Uninstaller.
- **No service changes ship.** The curated list is empty by design, and the reasoning is in
  [docs/RESEARCH.md](docs/RESEARCH.md).
- **WSL reclamation is advisory only**, because Microsoft documents no supported in-place
  shrink.
- **Delivery Optimization and Recycle Bin are advisory**, because the engine runs executables
  rather than arbitrary cmdlets (ADR-005).
- **No performance measurement**, and therefore no performance claim.

### Possible future work

A `PowerShellCommand` operation kind with its own allow-list catalog would let
`Delete-DeliveryOptimizationCache` and `Clear-RecycleBin` be offered as real actions. A
curated service knowledge base could populate the empty recommendation list. Multi-user
analysis would need elevation and a clear consent model.

---

## Documentation

| Document | Contents |
|---|---|
| [docs/RESEARCH.md](docs/RESEARCH.md) | Competitive analysis, tool evaluation, what is deliberately not built |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Structure, data model, safety layers, eight ADRs |
| [docs/SAFETY.md](docs/SAFETY.md) | The adversarial audit, findings, guarantees, residual risks |
| [docs/PROVIDERS.md](docs/PROVIDERS.md) | Per-provider detail |
| [docs/SOURCES.md](docs/SOURCES.md) | Every citation |
| [docs/VERIFICATION.md](docs/VERIFICATION.md) | What is tested, what is not, and what needs real-world validation |

## Licence

MIT. No code from any evaluated third-party project is included; see
[docs/SOURCES.md](docs/SOURCES.md) for the licence position on each.
