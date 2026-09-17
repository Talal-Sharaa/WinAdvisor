# Verification

Phase 10: exactly what was verified, how, and what was not. The categories the project brief
asks for are used literally, and nothing is claimed that was not actually observed.

**Environment used for verification**

| | |
|---|---|
| OS | Windows 11 Pro Insider Preview, build 26220.9472 (25H2) |
| Hardware | Lenovo laptop, i5-1335U, 24 GB RAM, 2 × NVMe SSD |
| PowerShell | Windows PowerShell 5.1.26100.9472 and PowerShell 7.6.6 |
| Session | Standard user, **not elevated** |
| Workloads present | Docker (CLI only, engine stopped), WSL, .NET, Node, Python, Java, PostgreSQL, SQL Server, Chrome, Edge, Firefox, VS Code, Visual Studio, JetBrains, OneDrive, NVIDIA, Hyper-V, VirtualBox, npm, pip, uv, Bun, Gradle, Maven, Chocolatey, Scoop |
| Test framework | Pester 5.7.1 |

This was a genuinely representative developer workstation, which is what made several of
the bugs below findable.

---

## Implemented and tested

Verified by execution on the machine above, on both PowerShell versions.

**Static analysis.** All 57 PowerShell files parse cleanly on both versions
(`Tests/Test-Syntax.ps1`).

**Test suite.** 174 Pester tests, all passing on **both** Windows PowerShell 5.1 (74s) and
PowerShell 7.6.6 (29s):

| Area | Coverage |
|---|---|
| Path safety | Traversal, UNC, wildcards, alternate data streams, prefix-collision (`C:\TempEvil` vs `C:\Temp`) |
| Protected locations | Windows, WinSxS, Prefetch, Documents, Desktop, Downloads, DPAPI/credential stores; profile and drive roots protected while caches inside stay reachable |
| Protected segments | `.git`, `node_modules`, `site-packages`, `.venv` |
| Never-deleted types | VM disks, databases, mail stores, key material |
| Protected services and startup | Security, EDR, device management, accessibility |
| Risk / confidence | Ordering, rejection of unknown levels, independence of the two axes |
| Policy floors | Every operation kind policed; risk downgrade refused |
| Read-only guarantee | Every inspection mode read-only; approved delete of real files does nothing in DryRun |
| Approval | Fingerprint invalidation on tamper, replay across actions, batch ceiling |
| HIGH risk | Batch refused at three independent layers, including a forged record |
| MANUAL-ONLY | Refused at four layers, including a forged approval |
| Command catalog | Integrity, references, placeholder injection, quote/newline rejection, probe gate over every mutating entry |
| Configuration | Validation, partial merge, policy not user-overridable, drive-root token |
| Provider contract | All 20 providers complete; execution routed to the core; failure isolation |
| Execution | Real file deletion in a sandbox, age filtering, manifest re-validation, idempotency |
| End-to-end | Analysis → approval → execution → verification against real files |
| Rollback | Capture, JSON round-trip, real HKCU restore, crafted-record refusal |
| Reporting | HTML contains no external resources |
| Source encoding | Every PowerShell source file is 7-bit ASCII |

**Modes executed successfully against this machine:**

- `ViewSpecs` — full inventory. Correctly identified Windows 11 build 26220.9472, laptop
  chassis, 2 NVMe SSDs, memory modules with rated/configured speeds, NVIDIA MX550 VRAM from
  the driver key, both pagefiles, hibernation disabled, 27 of 35 startup items enabled, and
  top memory consumers.
- `Analyze` — all 20 providers ran; 17 active, 3 correctly inactive with stated reasons.
- `Storage` — attribution by category with the unattributed remainder reported.
- `DryRun` — complete pipeline in ~5 minutes, producing a 25-item plan across 6 categories,
  approval simulation, and HTML + JSON reports.

**Detection verified against reality.** Workload detection found every tool actually
installed. NuGet cache discovery via `dotnet nuget locals` found 11.89 GiB that the
conventional `%USERPROFILE%\.nuget\packages` assumption would have missed entirely — the
clearest vindication of asking the tool rather than guessing.

**Degradation verified.** Docker CLI present with the engine stopped was correctly reported
as "the Docker CLI is installed but the engine did not respond", not as an error and not as
zero usage. BitLocker, restore points and Secure Boot were correctly reported as needing
elevation rather than as absent.

---

## Implemented but not exercised in this environment

Implemented and unit-tested, but not run against live system state here — in every case
because doing so would have modified the user's machine without being asked, or because the
precondition was absent.

| Capability | Why not exercised | What *was* verified |
|---|---|---|
| Real provider cleanup (NuGet, npm, browser caches) | Would modify this machine | The identical execute path is covered end to end against sandbox files; commands are catalog-resolved and previewed |
| `DISM /AnalyzeComponentStore` | Requires elevation | Catalog entry, argument vector, admin gate, `NeverKill`, output parser structure |
| `DISM /StartComponentCleanup` | Requires elevation; modifies servicing | Catalog entry, HIGH/MODERATE classification, admin gate |
| `powercfg /hibernate off` | Hibernation already disabled here | Provider stands down correctly; catalog entry and counterpart command |
| Docker prune commands | Engine not running | `docker system df` parsing, base-1000 conversion, degraded reporting |
| Elevated relaunch (UAC) | Session not elevated; would prompt | Requirement detection, per-action blocking with explanation, constrained mode parameter |
| `Checkpoint-Computer` | Requires elevation | Gate, and honest reporting when Windows declines |
| Czkawka duplicate scan | Tool not installed; disabled by default | Three-gate refusal, catalog entry, absence of any deletion argument |
| `ServiceStartupSet` | No service recommendation ships | Handler, protected-service refusal, rollback capture, restore |
| `ScheduledTaskState` | No task recommendation ships | Handler, servicing-task refusal, rollback |

The distinction that matters: the **execution engine** is exercised end to end by tests. What
is unexercised is specific *provider commands* against live state.

---

## Requires real Windows validation

Honest gaps that only broader real-world use will close.

- **Other hardware and editions.** Verified on one Lenovo laptop, one Windows edition. CIM
  classes vary: `Win32_PhysicalMemory.ConfiguredClockSpeed` is absent on some systems, and
  `Get-PhysicalDisk` reports `MediaType = Unspecified` for NVMe (handled via `BusType`, but
  other bus types are untested).
- **Elevated end-to-end run.** The elevated path — DISM analysis, component cleanup,
  restore point, hibernation — has not been run as a whole.
- **Domain-joined and managed machines.** This machine is domain-joined, but no Group Policy
  restrictions or MDM agents were exercised.
- **Localised Windows.** DISM output is localised and the parser matches on position and
  numeric patterns rather than English labels, but this was verified only implicitly (the
  command never ran) and never on a non-English installation.
- **Other browser and tool versions.** Chromium cache layout is stable but not guaranteed;
  Docker's `system df` JSON shape has changed historically.
- **Very large filesystems.** Scans are bounded, so behaviour is predictable, but a machine
  with far more data would produce more partial measurements than were seen here.

---

## Optional future enhancement

Not gaps in what was delivered; deliberate scope boundaries.

- **`PowerShellCommand` operation kind** with its own allow-list catalog, which would turn
  `Delete-DeliveryOptimizationCache` and `Clear-RecycleBin` from advisory into real actions
  (ADR-005).
- **Curated service knowledge base** to populate the intentionally empty
  `ServiceRecommendations` list, with the per-entry evidence the policy file demands.
- **Multi-user analysis**, requiring elevation and an explicit consent model.
- **Scheduled unattended analysis** producing a report without any execution.
- **Additional providers**: Steam and Epic shader caches, Podman, Hyper-V checkpoint
  reporting, OneDrive placeholder analysis.
- **Faster deep scanning** via a native enumeration helper, for whole-volume attribution.

---

## Bugs found and fixed during verification

Recorded because they show what the verification actually exercised. All were found by
running the toolkit on a real machine or by the test suite, not by inspection.

1. **User profile protected recursively** — silently classified every application cache as
   protected, so the toolkit reported findings but proposed almost nothing. Found when a
   scan of a 3.47 GiB Temp directory returned zero eligible files. Fixed by splitting
   protection into recursive `Paths` and exact-match `RootsOnly`. This was the most serious
   bug in the project: it failed in the direction of looking like a clean machine.

2. **Scan performance** — 958 entries in 8 seconds, making every measurement a severe
   underestimate. Caused by per-file `Get-Item` calls and re-evaluating ~30 protected paths
   per file. Fixed by using `EnumerateFileSystemInfos` and precomputing the protected paths
   that fall *within* the root (normally none). Now 22,522 entries in the same budget — 23×
   faster.

3. **`@($genericList)` throws on PowerShell 7.6.6** — `ArgumentException: Argument types do
   not match` from `PSToObjectArrayBinder`. Broke 7 providers. Reproduced minimally,
   confirmed `.ToArray()` is unaffected, and corrected 89 occurrences across 28 files.

4. **`$_` shadowed inside `switch`** — in a `Where-Object` block, `$_.Risk` inside a `switch`
   read the switch subject rather than the pipeline item, breaking question filtering.

5. **`Math::Max(0, <long>)` overflow** — an untyped `0` selected the Int32 overload, which
   cannot hold a byte count from a modern disk.

6. **Registry enumeration with `-ErrorAction Stop`** — one denied subkey under the display
   class discarded all GPU VRAM data for a standard user.

7. **`ProductName` reports "Windows 10" on Windows 11** — a documented Microsoft
   compatibility quirk. The tool was telling a Windows 11 user they were on Windows 10.
   Fixed by preferring `Win32_OperatingSystem.Caption`.

8. **Drive-root token trimmed to `C:`** — `{SystemDrive}` expanded to `C:\` then trimmed to
   `C:`, which fails path normalisation, silently dropping the protection. Found by a test
   written specifically to check that the drive root was protected.

9. **Provider reading its own finding from `Session.Findings`** — not yet populated at plan
   time, so the Recycle Bin provider produced no recommendation.

10. **Non-ASCII source broke the menu on 5.1** — Windows PowerShell reads a BOM-less UTF-8
    script as ANSI, so the box-drawing characters in the menu became mojibake, and the
    corruption ran far enough to leak raw source into the console. Found by running the
    menu on 5.1. All sources are now 7-bit ASCII, enforced by a test.

11. **`-Include` with `-LiteralPath` is unreliable on 5.1** — both the syntax gate and the
    encoding test silently matched every file rather than just PowerShell sources, pulling
    in Markdown docs and runtime logs. Now filtered on `.Extension` explicitly.

12. **`$PSScriptRoot` is empty in a `param()` default on 5.1** — the syntax gate failed to
    start. Resolved in the body instead.

13. **Encoding test took 13 minutes on 5.1** — piping every byte of every source file
    through `Where-Object`. Replaced with `[Array]::FindIndex`; the whole suite went from
    292s to 74s on 5.1.

14. **JSON report was 6.1 MB** — it embedded full file manifests, which both bloated the
    report and wrote thousands of the user's file paths to disk, contradicting the principle
    already applied to session records. Manifests are now summarised by count and size, and
    the report is 228 KB.

15. **Five audit findings** — read-only gate missing on rollback restore; rollback records
    trusted without re-applying policy; deletion using the manifest path rather than the
    validated path; unconstrained elevation mode parameter. All fixed with regression tests;
    see [SAFETY.md](SAFETY.md).

Items 10 to 13 are worth noting as a group: every one was a **PowerShell 5.1-only** failure
that passed cleanly on 7.6.6. Claiming 5.1 support without running the suite on 5.1 would
have been wrong four times over.

---

## Reproducing this verification

```powershell
pwsh -NoProfile -File Tests/Test-Syntax.ps1            # 57 files parse
pwsh -NoProfile -File Tests/Run-Tests.ps1              # 174 tests
powershell -NoProfile -File Tests/Run-Tests.ps1        # same, on 5.1

.\WinAdvisor.ps1 -Mode ViewSpecs -NonInteractive       # read-only inventory
.\WinAdvisor.ps1 -Mode DryRun    -NonInteractive       # full pipeline, no changes
```

`DryRun` is the honest way to evaluate this toolkit on your own machine: it runs the
complete pipeline, generates every command, simulates approval, and changes nothing.
