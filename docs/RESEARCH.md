# Research and competitive analysis

Phase 1 of the project: what already exists, what it does well, what WinAdvisor should
delegate to it, and what WinAdvisor should not build at all.

The guiding question throughout was not "can we implement this?" but "is there already a
supported mechanism, and would ours be better?" In almost every case the answer was that a
native or vendor mechanism exists and is better tested than anything we would write.

---

## Summary of decisions

| Capability | Decision | Mechanism |
|---|---|---|
| Component store (WinSxS) cleanup | Delegate | DISM `/Cleanup-Image` |
| Component store measurement | Delegate | DISM `/AnalyzeComponentStore` |
| Previous Windows installation | Advise only | Storage Sense / Disk Cleanup |
| Windows Update download cache | Advise only | Storage Sense / Disk Cleanup |
| Delivery Optimization cache | Advise only | `Delete-DeliveryOptimizationCache` |
| Hibernation / hiberfil.sys | Delegate | `powercfg /hibernate` |
| NuGet caches | Delegate | `dotnet nuget locals --clear` |
| npm / pnpm / Yarn caches | Delegate | each tool's own cache command |
| pip / uv caches | Delegate | `pip cache purge`, `uv cache prune` |
| Docker images, containers, build cache | Delegate | Docker CLI `prune` commands |
| Docker volumes | Advise only | never pruned |
| WSL disk reclamation | Advise only | no supported in-place shrink exists |
| Gradle / Maven / Cargo / editor caches | Implement | no official CLI exists; file manifests |
| Browser caches | Implement | documented profile layout; cache paths only |
| Duplicate / empty / temporary / similar-image / broken-file detection | Delegate, enabled by default | Czkawka 12.0.2 scans personal folders; WinAdvisor executes individually reviewed deletions |
| Application uninstall | Out of scope | Bulk Crap Uninstaller does this properly |
| Registry "cleaning" | Never | no evidence it helps; real potential to harm |
| Service disabling | Never by default | see below |
| Telemetry / debloat tweaks | Out of scope | WinUtil and Sophia Script own this space |

---

## Existing projects evaluated

### Chris Titus Tech WinUtil

**Licence:** MIT.
**Repository:** <https://github.com/ChrisTitusTech/winutil>

**What it does well.** A single-command WPF interface over a large, community-maintained
catalogue of Windows tweaks, application installs via winget/choco, and update
configuration. Enormous reach and a large contributor base keeping the tweak catalogue
current.

**Why WinAdvisor does not duplicate it.** WinUtil is a *tweak applier*: the user chooses
from a curated list of changes. WinAdvisor is a *diagnostic advisor*: it measures a
specific machine and derives recommendations from that measurement. The two answer
different questions — "apply these known-good tweaks" versus "what is actually consuming
resources here, and why".

**What we deliberately avoid duplicating.** Debloating, telemetry configuration, privacy
tweaks, application installation. These are policy preferences rather than maintenance
findings, and WinUtil already does them with far more community review than a new project
could attract.

**Licence position.** MIT permits reuse with attribution. No WinUtil code is copied into
WinAdvisor; the projects are architecturally unrelated.

### Sophia Script for Windows

**Licence:** MIT.
**Repository:** <https://github.com/farag2/Sophia-Script-for-Windows>

**What it does well.** A very large PowerShell module of Windows 10/11 configuration
functions, with the notable discipline that every tweak has a corresponding function to
restore the default, and that changes are made through documented mechanisms.

**Why WinAdvisor does not duplicate it.** Sophia Script is a configuration surface, not a
diagnostic one. It answers "set this machine up the way I like"; WinAdvisor answers "what
is wrong with this machine".

**What we borrowed conceptually.** The paired set/restore discipline is exactly right, and
WinAdvisor's rollback model reflects it: every reversible change records its prior state,
and the report names the counterpart command.

**Licence position.** MIT permits reuse. No Sophia Script code is copied; the reversibility
principle is a design idea, not source.

### BleachBit

**Licence:** GNU GPL v3 or later (source and cleaner definitions).
**Documentation:** <https://docs.bleachbit.org/doc/command-line-interface.html>

**What it does well.** A mature cross-platform cleaner with a large library of declarative
cleaner definitions, and a genuine CLI (`bleachbit_console.exe`) with `--list`, `--preview`
and `--clean`.

**Why WinAdvisor does not integrate it.** Two reasons, one practical and one legal.

Practically, BleachBit's model is the opposite of WinAdvisor's: it applies a broad catalogue
of cleaners by name, whereas WinAdvisor measures specific locations and explains each one.
Shelling out to `--clean` would hand control of *what gets deleted* to a definition file
this project cannot inspect or risk-classify, which breaks the central promise that every
deletion is individually validated against policy.

Legally, the cleaner definitions are GPLv3. Invoking an installed binary as a separate
process does not create a derivative work, but copying or translating its cleaner
definitions into WinAdvisor would place this MIT-licensed project under GPL obligations.
That line is easy to cross accidentally, and there is no compelling reason to go near it.

**Position.** Not integrated. BleachBit is a good tool; users who want it should use it
directly.

### Czkawka

**Licence:** MIT for the GTK application and `czkawka_cli`. (The newer Krokiet front end is
GPL-3.0-only; WinAdvisor does not use it.)
**Repository:** <https://github.com/qarmin/czkawka>

**What it does well.** Fast, correct duplicate detection with size-then-hash grouping,
plus empty-folder, broken-symlink and similar-image detection. Written in Rust and much
faster than anything equivalent in PowerShell.

**Decision: delegate scanning, then review exact deletions.** The versioned integration
supports duplicates, empty folders, empty files, temporary files, similar images and broken files.
It enables external tools by default and scans the six standard personal folders unless
explicit folders replace them. It requires CLI 12.0.2. Missing binaries
are downloaded automatically from the pinned release and SHA-256 verified before use.
An offline opt-out and a standalone installer are available.

No deletion argument exists in the command catalog. Czkawka supplies JSON reports and
WinAdvisor converts validated candidates into HIGH-risk operations that require individual
approval. Retained paths are shown and revalidated. Similar-image matches can contain
different content, so visual review remains the user's decision. See
[the provider contract](PROVIDERS.md#externalczkawka--default-scanning-reviewed-deletion).

### Bulk Crap Uninstaller

**Licence:** Apache 2.0.
**Repository:** <https://github.com/Klocman/Bulk-Crap-Uninstaller>

**What it does well.** Genuinely excellent application removal: it finds uninstallers the
registry does not list, runs them quietly, detects leftovers, and handles Store apps,
Steam apps and portable software.

**Decision: out of scope.** WinAdvisor inventories installed applications for context but
does not uninstall anything. Application removal is a large, fiddly problem domain that BCU
has already solved, and a half-implementation would be worse than useless.

WinAdvisor also deliberately refuses to label software "bloatware". It reports neutral
descriptions — optional OEM utility, startup-heavy application, large application, unknown
application — because calling unfamiliar software bloat is how people remove the driver
utility their docking station needs.

### Windows Storage Sense and Disk Cleanup

**Vendor:** Microsoft, built in.

**What they do well.** They are the supported path for several things that are genuinely
awkward to do by hand: previous Windows installations, Windows Update cleanup, Delivery
Optimization files, and per-user temporary file policies on a schedule.

**Decision: advise, do not replace.** Windows.old in particular carries ACLs that make a
hand-rolled recursive delete fail part-way and leave an undeletable remnant. WinAdvisor
measures it, explains the rollback-window trade-off, and points at Settings > System >
Storage > Temporary files. That is more useful than a delete that half-works.

---

## Native mechanisms adopted

### DISM for the component store

WinSxS cannot be measured by summing directory sizes: most of its content is hard links to
files that also live in System32, so a naive sum counts the same bytes repeatedly. Microsoft
documents `DISM /Online /Cleanup-Image /AnalyzeComponentStore` as the measurement and
`/StartComponentCleanup` as the cleanup, and warns explicitly that deleting files from
WinSxS can make a machine unbootable and unable to update.

WinAdvisor therefore never touches WinSxS directly. `/ResetBase` is available but disabled
by default and classified HIGH, because Microsoft documents that no currently installed
update can be uninstalled afterwards.

DISM is also never terminated mid-operation. The command catalog marks every DISM entry
`NeverKill`, so a long-running servicing operation is allowed to finish rather than being
killed on a timeout, which can leave the component store needing repair.

### powercfg for hibernation

`powercfg /hibernate off` is the documented way to remove hiberfil.sys, and
`powercfg /hibernate on` reverses it. WinAdvisor records the counterpart command as the
rollback path.

The recommendation is framed as a trade-off rather than a saving, and specifically warns
that Fast Startup stops working too — the part people are usually surprised by, because
Fast Startup writes the kernel session to the same file.

### Package manager CLIs

Every package manager in scope has an official cache command, and each is asked where its
own cache lives rather than assuming a default path:

- `dotnet nuget locals <cache> --clear` — and the NuGet global-packages folder is routinely
  relocated by `NUGET_PACKAGES` or NuGet.Config, so guessing `%USERPROFILE%\.nuget\packages`
  measures the wrong directory. On the development machine used to build this project, that
  guess would have found nothing while the real cache held 11.89 GiB.
- `npm cache clean --force` — npm treats its cache as disposable and self-heals.
- `pnpm store prune` — **never** a file delete. Installed projects hard-link into the pnpm
  store, so deleting the store directory corrupts every project that depends on it.
- `yarn cache clean`, `pip cache purge`, `uv cache prune`.

Where no official command exists — Gradle, Maven, Cargo, editor caches — WinAdvisor falls
back to validated file manifests against explicitly named directories.

### Docker CLI

`docker system df --format "{{json .}}"` gives usage and reclaimable space per category and
is the basis for every Docker recommendation. Cleanup uses `docker builder prune`,
`docker image prune` (with and without `--all`) and `docker container prune`.

Docker reports human-readable sizes in base 1000 (GB = 10⁹), unlike the binary units used
elsewhere in the toolkit. The parser accounts for the difference; treating GB as 2³⁰ would
overstate every Docker figure by about 7%.

**Volumes are never pruned.** `docker volume prune` is not in the catalog at all. Volumes
hold the data containers exist to keep, and Docker's definition of "unused" — no container
currently references it — is satisfied by a database volume whose container was removed
last week. A test asserts no mutating volume command exists.

### WSL

This is the one case where research changed the design.

Microsoft's "How to manage WSL disk space" documents how to **expand** a WSL virtual hard
disk. It documents no supported in-place shrink. The same page states that WSL files under
AppData should not be modified, moved or accessed with Windows tools, because doing so can
corrupt the distribution.

The commonly shared shrink procedures — `diskpart compact vdisk`, `Optimize-VHD`, or
enabling sparse mode — are not covered by that documentation as a supported reclamation
path, and all of them operate directly on the file Microsoft says not to touch.

**Decision: WSL is advisory only.** There is no WSL mutation in the command catalog. This
is not a missing feature; there is no documented safe operation to expose. The provider
measures the virtual disks, explains that a WSL disk only ever grows, describes the options
with their risks, and leaves the decision to the person who owns the data.

`wsl --unregister` is likewise never offered. It permanently destroys everything in a
distribution, which is not a cleanup operation.

---

## Things deliberately not built

**Registry cleaning.** There is no credible evidence that removing orphaned registry keys
improves performance on a modern Windows installation, and there is a well-documented
history of registry cleaners breaking working systems. Not implemented, and not planned.

**RAM optimisation.** Trimming process working sets or purging the standby list makes Task
Manager show a larger free-memory number and makes the machine slower, because the data
Windows had cached must be read from disk again. WinAdvisor diagnoses *persistent memory
consumers* instead — what is resident, what it costs, and whether it starts automatically —
and reports commit charge against the commit limit as the measurement that actually
indicates memory pressure.

**Mass service disabling.** The most common piece of Windows optimisation folklore, and the
one whose damage is hardest to attribute because it surfaces weeks later as a printer that
will not print or a VPN that will not connect. `Config/policies.json` carries a
`ServiceRecommendations` list for curated entries that meet the project's evidence bar;
**it ships empty**. The execution engine implements and tests the service operation kind
with full rollback so a future curated entry executes safely, but no entry ships, because
none has met the bar.

**Prefetch deletion.** Windows uses Prefetch to start applications faster and rebuilds it if
deleted. Clearing it costs performance and saves almost nothing. It is on the protected path
list, and a test asserts it.

**Pagefile tuning.** Reported, never changed. A system-managed pagefile satisfies crash-dump
requirements and adapts to commit demand; disabling it lowers the commit limit and makes
memory pressure worse under exactly the workloads that make people want to disable it.

**Timer resolution, scheduler and network tweaks.** No measurement WinAdvisor can perform
would justify any of them.

**Security feature changes.** Out of scope entirely. Defender, the firewall, SmartScreen,
Credential Guard, Secure Boot, BitLocker, UAC, VBS, Windows Update security servicing, EDR
agents and device-management agents are all on a never-touch list. Weakening security is not
an optimisation.

---

## Where WinAdvisor adds something new

The gap in the existing landscape is not another cleaner. It is the diagnostic layer:

1. **Workload-aware analysis.** A machine with Docker, WSL, four package managers and three
   IDEs gets a different set of questions and recommendations from an office laptop, because
   detection drives the analysis rather than a fixed checklist.
2. **Evidence attached to every recommendation.** What was measured, how, whether the
   measurement was complete, what exact command will run, what changes, and what it costs.
3. **Risk and confidence kept separate.** "Clear the browser cache" is LOW risk and HIGH
   confidence. "This 38 GB directory looks unused" is HIGH risk and LOW confidence — the
   combination that must never execute automatically.
4. **Honest measurement.** A location that could not be read is reported as unknown, never
   as zero. A scan that hit its budget reports a lower bound, never a total. Predicted and
   measured savings are separate fields, and no performance claim is made anywhere.
5. **Orchestration over reimplementation.** For each finding the toolkit names the right
   execution provider — DISM, powercfg, the Docker CLI, the NuGet CLI — and drives it,
   rather than writing its own version.

Sources for every claim above are listed in [SOURCES.md](SOURCES.md).
