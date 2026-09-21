# Architecture

WinAdvisor is a diagnostic and orchestration layer. It measures a specific Windows 11
machine, derives recommendations from what it measured, and — only after explicit approval —
drives native and vendor tools to act on them.

```
Inspect  ->  Profile  ->  Detect workloads  ->  Measure  ->  Findings
                                                                |
                                                                v
Report  <-  Verify  <-  Execute  <-  Approve  <-  Plan  <-  Questions
```

Everything left of *Approve* is read-only and produces identical results in every mode.
Dry Run is not a separate code path; it is the same pipeline in a session whose `ReadOnly`
flag makes the execution engine decline the final step.

---

## Repository structure

```
WinAdvisor/
├── WinAdvisor.ps1                  launcher (parameter parsing only)
├── WinAdvisor.psd1                 module manifest, public surface
├── WinAdvisor.psm1                 root module, load order
├── README.md
│
├── Config/
│   ├── defaults.json               user-tunable preferences
│   ├── policies.json               safety policy (not user-overridable)
│   └── providers.json              per-provider enablement and settings
│
├── Core/
│   ├── Common.ps1                  primitives: paths, formatting, native process, JSON
│   ├── Models.ps1                  the data model and its vocabularies
│   ├── Logging.ps1                 human-readable + JSON-lines logs
│   ├── Configuration.ps1           config/policy loading, token expansion, validation
│   ├── Safety.ps1                  path safety, protection checks, policy gates
│   ├── CommandCatalog.ps1          the allow-list of every external command
│   ├── Inventory.ps1               bounded filesystem measurement + scan cache
│   ├── Session.ps1                 session lifecycle and the read-only flag
│   ├── ProviderContract.ps1        provider registration and the 7-member interface
│   ├── Discovery.ps1               hardware, firmware, storage, Windows configuration
│   ├── Workloads.ps1               software detection, startup, processes
│   ├── Analysis.ps1                provider orchestration, findings, storage attribution
│   ├── RecommendationEngine.ps1    shared recommendation builders
│   ├── Questions.ps1               adaptive, device-specific questioning
│   ├── Planning.ps1                plan construction and summary
│   ├── Approval.ps1                approval records and enforcement
│   ├── Elevation.ps1               privilege handling
│   ├── Execution.ps1               the only code that changes the machine
│   ├── Rollback.ps1                rollback capture and restoration
│   ├── Verification.ps1            before/after measurement
│   ├── Reporting.ps1               self-contained HTML + JSON reports
│   ├── Interface.ps1               console rendering and the menu
│   ├── CzkawkaReview.ps1           review screen: choosing which Czkawka results to delete
│   └── Entry.ps1                   Start-WinAdvisor and the mode flows
│
├── Providers/                      one file per provider, auto-discovered
│   ├── Windows.Temp.ps1            Windows.Servicing.ps1    Windows.Startup.ps1
│   ├── Windows.Services.ps1        Windows.Hibernation.ps1  Windows.RestorePoints.ps1
│   ├── Windows.RecycleBin.ps1      Windows.DeliveryOptimization.ps1
│   ├── Browsers.Chromium.ps1       Browsers.Firefox.ps1
│   ├── Containers.Docker.ps1       Containers.Wsl.ps1
│   ├── Dev.DotNet.ps1              Dev.Node.ps1             Dev.Python.ps1
│   ├── Dev.Jvm.ps1                 Dev.Rust.ps1             Dev.Editors.ps1
│   ├── Storage.LargeFiles.ps1      External.Czkawka.ps1
│
├── Data/                           runtime output, git-ignored
│   ├── Logs/  Reports/  Sessions/  Rollback/
│
├── Tests/                          Pester 5 suite + syntax gate
└── docs/
    ├── RESEARCH.md   ARCHITECTURE.md   SAFETY.md
    ├── SOURCES.md    VERIFICATION.md   PROVIDERS.md
```

---

## The data model

Every concept has a constructor in `Core/Models.ps1`, and vocabularies are validated at
construction so a misspelled risk level fails immediately rather than becoming `$null`
three layers later.

| Type | Purpose |
|---|---|
| `MachineProfile` | Everything discovery found. The input to all analysis. |
| `InstalledComponent` | A detected workload, with *how* it was detected and how confidently. |
| `StorageConsumer` | A measured (or unmeasurable) consumer of disk space, attributed to a category. |
| `Finding` | An observation. Findings never propose actions. |
| `CleanupCandidate` | A measured opportunity, before policy has decided anything. |
| `Recommendation` | A proposed action with evidence, risk, confidence, consequence and rollback. |
| `Operation` | One typed, executable step. The only things the engine can perform. |
| `PlannedAction` | A recommendation selected into a plan, carrying its approval and fingerprint. |
| `ExecutionResult` | What happened, including before/after state. |
| `RollbackRecord` | Captured prior state for a reversible change. |
| `Question` | An adaptive question raised only by what was detected. |
| `BaselineMetric` | One before/after measurable quantity. |
| `Session` | Mode, configuration, and everything discovered, proposed and done. |

### Vocabularies

```
Risk           SAFE | LOW | MODERATE | HIGH | MANUAL-ONLY
Confidence     HIGH | MEDIUM | LOW | UNKNOWN
BenefitClass   Measured | Estimated | Possible | Unknown
Reversibility  Reversible | PartiallyReversible | RegenerableOnly | Irreversible
```

Risk and confidence are **independent**. "Clear the browser cache" is LOW/HIGH. "This 38 GB
directory looks unused" is HIGH/LOW — precisely the combination that must never execute
automatically, which is why they are separate fields rather than one blended score.

`EstimatedBytes` and `MeasuredBytes` are likewise separate. `MeasuredBytes` stays `$null`
until the verification pass fills it from a real before/after comparison, so a prediction
can never be presented as a result.

---

## The safety model in layers

Each layer is independent. A bug in one does not open the others.

```
1  Session mode         ReadOnly is set once at construction and never flipped
2  Policy               operation risk floors, protected paths, protected services
3  Approved roots       a FileDelete can only reference a root a provider registered
4  Command catalog      external commands come from an allow-list, not from providers
5  Approval fingerprint an approval is bound to exact content; edits invalidate it
6  Privilege            admin-requiring operations are blocked, never silently skipped
7  Per-file validation  every file is re-checked at the moment of deletion
```

### Operation kinds

The complete set of things WinAdvisor can do to a machine:

```
FileDelete          delete a reviewed manifest of specific files
NativeCommand       run one catalog entry with catalog-controlled arguments
RegistryValueSet    write one named value, with rollback
ServiceStartupSet   change one service start mode, with rollback
ScheduledTaskState  enable/disable one scheduled task, with rollback
StartupItemState    enable/disable one startup item, with rollback
RestorePointCreate  create a System Restore checkpoint
```

There is no "run this command", no "delete this directory tree", and no provider-supplied
command line anywhere. Adding a capability means adding an operation kind, a handler and a
policy entry — a deliberate, reviewable change rather than a one-line provider edit.

---

## The provider contract

```
TestAvailable         is this provider relevant on this machine?
GetInventory          what components does it find?
GetAnalysis           what findings follow?
GetCleanupCandidates  what measured opportunities exist?
GetCleanupPlan        what recommendations, with typed operations, follow?
InvokeCleanup         fixed: always Core/Execution.ps1
TestResult            re-measure afterwards to verify what actually happened
```

Providers know their domain: where a tool keeps its caches, what its output means, what is
safe to propose. They are **not** responsible for changing anything.

`InvokeCleanup` is deliberately not overridable — see ADR-002. `TestResult` is per-provider
because precise verification needs domain knowledge: the Docker provider re-runs
`docker system df` rather than inferring from disk free space.

Every entry point runs through `Invoke-WaProviderStage`, which isolates failures. A provider
that throws — because a tool changed its output format, or a daemon is not running — is
recorded as degraded and the run continues. The report says which providers were degraded
and why, rather than silently omitting them.

---

## Architecture decisions

### ADR-001: Dot-sourced `.ps1` components, not nested modules

**Decision.** `WinAdvisor.psm1` dot-sources `Core/*.ps1` and `Providers/*.ps1` into a single
module session state.

**Why.** Nested modules in PowerShell each receive their own session state, which makes
cross-module helper visibility order-dependent and fragile on 5.1. A single session state
means providers can call safety primitives directly without every primitive having to
become a public, exported function. The public surface stays small and explicit: only the
functions listed in the manifest leave the module.

**Cost.** No per-file encapsulation. Mitigated by keeping the export list short and the
file boundaries meaningful.

### ADR-002: Providers describe intent; only the core executes

**Decision.** Providers emit typed `Operation` objects. `Core/Execution.ps1` is the only
code that interprets them.

**Why.** If every provider supplied its own execution body, the read-only guarantee, the
approval gate and the rollback capture would each have as many implementations as there are
providers, and a single careless provider would compromise all three. With one executor,
those guarantees are written once and tested once.

**Consequence.** A provider cannot invent a new way to change the machine. It can only
choose among operation kinds the engine already knows and policy already covers.

### ADR-003: External commands come from a catalog, not from providers

**Decision.** `Core/CommandCatalog.ps1` owns the executable and the argument vector for
every external command. Providers reference a catalog id.

**Why.** A provider can choose *which* documented operation runs, but not *what* runs. There
is no path from provider code to an arbitrary command line.

Parameterised entries declare placeholders with a validation pattern; a value that does not
match is refused rather than escaped. Windows tools resolve through `System32` rather than
PATH, so a writable PATH entry cannot decide which binary runs elevated. Arguments
containing a quote or newline are rejected outright, and no shell is ever involved.

### ADR-004: Approved work is never marshalled across the privilege boundary

**Decision.** When an approved action needs administrator rights and the session does not
have them, the action is blocked with an explanation. The user is offered a relaunch of the
whole toolkit elevated, which repeats discovery and asks for approval again in that session.

**Why.** Handing a serialised list of file paths and commands to an elevated child process
creates exactly the channel an attacker would want: anything able to influence that payload
gains administrator execution. Re-approving a handful of items is a small cost for removing
a privilege-escalation channel entirely.

**Cost.** Elevated work requires re-approval. Accepted deliberately.

### ADR-005: The engine runs executables, not arbitrary PowerShell cmdlets

**Decision.** `NativeCommand` executes catalog entries via `ProcessStartInfo`. There is no
operation kind that invokes an arbitrary PowerShell cmdlet.

**Why.** An executable plus a validated argument vector is a small, auditable surface. A
cmdlet invocation surface would be far larger and much harder to constrain.

**Cost.** Capabilities that exist only as cmdlets are advisory rather than automated:
`Delete-DeliveryOptimizationCache` and `Clear-RecycleBin` are named in the report with
instructions rather than run. A future `PowerShellCommand` operation kind with its own
allow-list catalog would close this gap; it is not needed for the current provider set.

### ADR-006: The Recycle Bin is measured, never emptied

**Decision.** Advisory only.

**Why.** The Recycle Bin holds files the user deleted and Windows deliberately kept
recoverable. "The user already deleted it" is not consent to destroy the copy that exists
precisely so the deletion can be undone. What the toolkit usefully adds is the number, which
Explorer does not show without asking; emptying it is one click away.

### ADR-007: Scans are bounded, and partial results say so

**Decision.** Every scan has an entry budget and a time budget. A scan that hits either
returns `Complete = $false`, and every figure derived from it is rendered as "at least".

**Why.** An unbounded recursive walk of a developer machine is millions of filesystem
operations. Bounding it keeps the tool usable; reporting the bound honestly keeps it
truthful. The alternative — presenting a partial sum as a total — is the kind of small
dishonesty that makes a maintenance tool untrustworthy.

Recursion is never implicit. Deep scanning happens only for directories named explicitly
with `-DeepScanPath`.

### ADR-008: Scan results are cached during analysis only

**Decision.** Directory scans are memoised for the analysis phase and the cache is cleared
before before/after measurement.

**Why.** Providers legitimately measure the same root twice — a size in `GetAnalysis`, a
manifest in `GetCleanupCandidates`. Rescanning a multi-gigabyte cache for the second answer
is wasted work. But verification must read the real filesystem: returning a cached
pre-cleanup size as the post-cleanup result would fabricate the one number the entire report
rests on.

The cache key is deliberately independent of the age cutoff. The walk collects every
policy-allowed file with its timestamps, and the cutoff is applied afterwards to split that
list, so one walk answers for any threshold.

---

## Storage attribution

Attribution covers what the enabled providers know how to measure. The remainder —
applications, user data and Windows itself — is reported as **unattributed** rather than
hidden.

That figure is shown on purpose. A storage report that silently accounts for 40% of a disk
and stays quiet about the rest invites the conclusion that the missing 60% is junk. Showing
it, with the percentage, is the honest presentation, and it is what prompts the optional
deep-scan question when attribution falls below 60%.

---

## Logging and reporting

Two log sinks per session: a human-readable `.log` and a machine-readable `.jsonl`. Every
string passes a redaction filter before it is written, because provider stdout is
third-party text.

Process command lines are **never collected** — they routinely contain credentials and
access tokens. Machine serial numbers appear masked to the final four characters, so a
report can be shared when asking for help.

The HTML report leads with the measured outcome of the run, because that is the question
the reader opened it with; the inventory, the per-action detail and the rollback record
follow as the evidence behind it. The three space figures (measured during execution, volume
free-space delta, prediction) are shown side by side and never reconciled into one number.

Execution also reports itself as it goes. `Invoke-WaPlan` takes an optional `-OnProgress`
sink and announces each step: the baseline measurement, each action as it starts and
finishes, progress within a long deletion, and a heartbeat while a native command such as
DISM is still running. The sink is presentation only - it cannot influence what runs, and a
sink that throws is dropped in favour of a `Write-Progress` bar rather than stopping a
change that is already under way. With no sink, the same steps are drawn as that bar.

The HTML report is a single self-contained file with no external resources: no CDN, no
fonts, no scripts fetched at view time. A report describing a specific machine should not
phone anywhere when it is opened, and it has to work on a machine with no network.

---

## Compatibility

Targets Windows 11 (build 22000+), 64-bit client editions, for *changes*. Analysis and
reporting run anywhere Windows does.

Verified on **Windows PowerShell 5.1** and **PowerShell 7.6**: the full Pester suite passes
on both. The code avoids PowerShell 7-only syntax (`??`, ternary, `-Parallel`) throughout.

Four cross-version constraints are load-bearing, each discovered by actually running on both:

**Sources are 7-bit ASCII, enforced by a test.** Windows PowerShell 5.1 reads a BOM-less
UTF-8 script as ANSI. A non-ASCII character therefore arrives as mojibake on 5.1, and if it
sits near a quote the corruption can run far enough to break the surrounding string literal
and leak raw source into the console — which is exactly what the box-drawing characters in
the menu did before this rule existed. Documentation is UTF-8; code is not.

**`@($list)` is avoided for generic lists.** On PowerShell 7.6, `@()` around a
`System.Collections.Generic.List` throws `ArgumentException: Argument types do not match`
from `PSToObjectArrayBinder`. Generic lists use `.ToArray()`; `ConvertTo-WaArray` handles
the general case.

**`-Include` is not used with `-LiteralPath`.** On 5.1 the combination is unreliable and
matches far more than intended. File type is filtered on `.Extension`.

**`$PSScriptRoot` is not used in a `param()` default.** On 5.1 it is empty at that point.
It is resolved in the script body instead.
