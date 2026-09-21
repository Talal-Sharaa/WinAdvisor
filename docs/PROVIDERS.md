# Providers

One file per provider in `Providers/`, auto-discovered at module load. Each entry below
states what the provider measures, what it will act on, and — usually more importantly —
what it deliberately leaves alone.

Settings referenced here live under `Providers.<Name>.Settings` in
`Config/providers.json`.

---

## Windows

### `Windows.Temp` — temporary files and caches

**Measures and cleans:** per-user TEMP, machine TEMP (`%SystemRoot%\Temp`, admin), Windows
Error Reporting archive and queue (user and machine), application crash dumps, DirectX and
NVIDIA shader caches, the legacy WinINet cache.

**Age-filtered.** Only files older than `MinimumTempAgeDays` (7) or `MinimumCacheAgeDays`
(14) are proposed; a temp file written minutes ago is very likely still in use.

**Reports but never deletes:**

- `SoftwareDistribution\Download` — the supported way to clear it is Storage Sense or Disk
  Cleanup; removing it by hand can disrupt an in-flight update.
- `Prefetch` — Windows uses it to start applications faster and rebuilds it if deleted.
  Clearing it costs performance and saves almost nothing. It is on the protected path list.
- `Windows\Minidump` — often the only evidence of a bug check, and small.

Crash dumps are MODERATE, not LOW: a dump can be the only record of a fault that is hard to
reproduce.

### `Windows.Servicing` — component store and upgrade leftovers

**Measures** with `DISM /Online /Cleanup-Image /AnalyzeComponentStore`, the supported
mechanism. Directory size is meaningless for WinSxS — most of it is hard links to files that
also live in System32, so a naive sum counts the same bytes repeatedly.

**Acts** with `/StartComponentCleanup` (MODERATE) when DISM reports cleanup is recommended
or more than 1 GB is reclaimable. `/ResetBase` (HIGH) exists but is **off by default**
(`AllowResetBase`); Microsoft documents that no currently installed update can be
uninstalled afterwards.

DISM is never terminated mid-operation.

**Windows.old is reported, never deleted.** It carries ACLs that make a hand-rolled recursive
delete fail part-way and leave an undeletable remnant. The recommendation explains the
rollback window and points at Settings > System > Storage > Temporary files.

### `Windows.Startup` — startup programs

**Measures** Run keys (machine and user, 32- and 64-bit), startup folders, and logon or boot
scheduled tasks outside `\Microsoft\Windows\*`. Correlates each with running processes to
report what it actually costs in private memory.

**Acts** through Explorer's `StartupApproved` mechanism — the same one Task Manager's
Startup tab uses. The original Run value or shortcut is left completely intact, so
re-enabling is a single value write.

**Never proposed:** Security, Device management, Accessibility, Hardware and drivers,
Windows system, Cloud synchronization, and anything classified Unknown. Cloud sync is
excluded because stopping it looks like working normally until something is lost. Unknown
is excluded because an unrecognised entry is as likely to be a VPN client or a fingerprint
reader as it is to be clutter — those are surfaced as a MANUAL-ONLY item instead.

No storage figure is claimed for a startup change, and no memory saving is promised: if you
open the application anyway, it uses the same memory either way.

### `Windows.Services` — advisory only

Reports automatic-start services and how many are on the never-modify list. **Proposes
nothing.**

This is a product decision, not an unfinished feature. `Config/policies.json` carries a
`ServiceRecommendations` list for curated entries meeting the project's evidence bar; it
ships empty. The execution engine implements and tests the service operation kind with full
rollback, so a future entry executes safely — but none ships, because none has met the bar.

### `Windows.Hibernation` — a trade-off, not a saving

**Acts** with `powercfg /hibernate off` (HIGH, admin, restart, individually approved),
reversible via the documented counterpart which the rollback record names.

Presented as a trade-off because it is one. You recover the file's size permanently, and you
lose Hibernate *and* Fast Startup — the latter surprises people, because Fast Startup writes
the kernel session to the same file. On a laptop, the warning is explicit: without
hibernation, a critical battery level means losing unsaved work.

Stands down entirely when hibernation is already disabled.

### `Windows.RestorePoints` — advisory only

Reports System Protection state, restore point count and shadow-copy storage. **Never
removes a restore point.**

Also sets expectations, because System Restore is routinely mistaken for a general undo: it
does not restore personal files, protection can be off per volume, and Windows discards
older checkpoints as the allocation fills.

### `Windows.RecycleBin` — advisory only

Measures per volume for the current user. **Never empties it.**

The bin holds files you deleted and Windows deliberately kept recoverable; "already deleted"
is not consent to destroy the copy that exists so the deletion can be undone. What the
toolkit usefully adds is the number, which Explorer does not show without asking.

Other accounts have their own Recycle Bin storage this session cannot measure, and the
report says so.

### `Windows.DeliveryOptimization` — advisory only

Reports the cache size and names `Delete-DeliveryOptimizationCache` as the supported way to
clear it. Windows caps and trims this cache itself, so intervening is rarely worthwhile.
Advisory because the engine runs executables rather than arbitrary cmdlets (ADR-005).

---

## Browsers

### `Browsers.Chromium` — Chrome, Edge, Brave, Vivaldi, Opera, Chromium

**Cleans, per profile:** `Cache\Cache_Data`, `Service Worker\CacheStorage` and
`ScriptCache`, `Code Cache\js` and `\wasm`, `GPUCache`, `DawnCache`, `DawnGraphiteCache`,
`DawnWebGPUCache`, and the user-data-level `ShaderCache`, `GrShaderCache`,
`GraphiteDawnCache`.

The subdirectory list is an explicit allow-list. It is never derived by scanning a profile
for things that look like caches, because a heuristic that guesses wrong here deletes
someone's passwords.

**Never touched:** `Login Data` (saved passwords), `Web Data` (autofill and payment
methods), `Cookies` (sign-in sessions), `History`, `Bookmarks`, `Preferences`, `Extensions`,
`Sessions`, `Local Storage`.

You stay signed in to websites: sign-in state lives in cookies. The browser need not be
closed — files it holds open are skipped, which simply means you reclaim less.

### `Browsers.Firefox`

Firefox splits its data conveniently: the profile (bookmarks, passwords, cookies, history)
lives under Roaming AppData, while the disk cache lives under Local AppData. Only `cache2`,
`startupCache` and `OfflineCache` are targeted; the profile directory is never approached.

---

## Containers

### `Containers.Docker`

**Measures** with `docker system df`. Docker reports base-1000 sizes (GB = 10⁹), and the
parser accounts for it — treating GB as 2³⁰ would overstate every figure by ~7%.

| Recommendation | Risk | Notes |
|---|---|---|
| `docker builder prune` | MODERATE | The safest large reclaim. No image, container or volume affected. |
| `docker image prune` | LOW | Dangling images only. Amount not predictable, so none is claimed. |
| `docker image prune --all` | MODERATE | Tagged images too. Offered only above 1 GB reclaimable. |
| `docker container prune` | MODERATE | Stopped containers and their writable layers. |

**Volumes are never pruned.** `docker volume prune` is not in the command catalog at all.
Volumes hold the data containers exist to keep, and Docker's "unused" means only that no
container currently references it — which a database volume satisfies the moment its
container is removed. They are listed as MANUAL-ONLY with instructions.

If the CLI is present but the engine is not running, that is reported as a normal state
rather than an error. If `docker system df` produces output the provider cannot parse, it
proposes nothing rather than acting on a misreading.

### `Containers.Wsl` — advisory only

Enumerates distributions from `HKCU:\...\Lxss` and measures each `ext4.vhdx`.

**Performs no WSL operation at all**, and there is no WSL mutation in the command catalog.
Microsoft documents how to *expand* a WSL virtual disk but publishes no supported in-place
shrink, and advises against touching WSL files under AppData with Windows tools.

The report explains that a WSL disk only ever grows — deleting files inside frees space for
Linux but does not shrink the `.vhdx` — and describes the options with their risks. Never
delete an `ext4.vhdx`; never run `wsl --unregister` to save space.

---

## Developer tooling

Only **global, regenerable caches**. Project directories, build output, source trees,
virtual environments and lock files are never touched.

### `Dev.DotNet`

Asks NuGet where its caches are with `dotnet nuget locals all --list` rather than assuming
`%USERPROFILE%\.nuget\packages`, because `NUGET_PACKAGES` and NuGet.Config relocate it. On
the machine used to develop this project that assumption would have found nothing while the
real cache held 11.89 GiB.

Clears through `dotnet nuget locals <cache> --clear` — the official mechanism, which keeps
NuGet's metadata consistent in a way that deleting the directory does not.

### `Dev.Node` — npm, pnpm, Yarn, Bun

Each tool is asked where its cache lives and cleaned with its own command.

**pnpm is never file-deleted.** Installed projects hard-link into the content-addressable
store, so deleting the directory corrupts every project depending on it. Only
`pnpm store prune` is used, and because it removes only unreferenced packages, no byte
figure is claimed.

Bun has no catalog command, so its install cache is handled as a file manifest — safe
because it is a flat directory of downloaded tarballs with no hard links into projects.

### `Dev.Python` — pip, uv

`pip cache purge`, `uv cache prune`. Virtual environments and `site-packages` are never
touched: a `.venv` is the environment a project runs in, not a cache. The policy segment
list blocks both regardless of what a provider asks for.

Worth knowing: rebuilding a wheel that needs a compiler is slower than downloading one, so
clearing the pip cache on a machine that builds native extensions has a real cost.

uv takes an exclusive lock on its cache to prune it and waits `UV_LOCK_TIMEOUT` seconds
(300 by default) for other uv processes to finish. Tools started with `uvx` live inside
the cache and hold a lock while they run, so on a machine with a uvx-hosted language server
or MCP server open, pruning can never proceed. The catalog entry sets `UV_LOCK_TIMEOUT=30`
and declares the "cache is currently in-use" output as a busy signal, so the action is
reported as skipped after half a minute with an explanation, rather than failed after
five. `--force` is never used.

### `Dev.Jvm` — Gradle, Maven, Coursier

Gradle dependency cache, build cache, daemon logs (LOW) and wrapper distributions
(MODERATE — each is tens of megabytes and an offline build of a project pinned to a removed
version will fail).

**The Maven local repository is MODERATE, not LOW.** `mvn install` writes locally built
artefacts into `~/.m2/repository` alongside downloaded ones, and those may exist nowhere
else. A dependency from Maven Central can always be fetched again; a snapshot built last
week from a since-rebased branch cannot. The filesystem gives no way to tell them apart, so
the risk classification reflects that rather than pretending the directory is disposable.

### `Dev.Rust`

`registry/cache`, `registry/src`, `registry/index` under `CARGO_HOME`.

Excluded: `target/` (project build output, and `cargo clean` is the right tool), `.cargo/bin`
(installed binaries — removing them uninstalls working tools), `.cargo/git` (checkouts that
may reference commits no longer reachable from any branch).

### `Dev.Editors` — VS Code, JetBrains, Visual Studio

VS Code `Cache`, `CachedData`, `CachedExtensionVSIXs`, `Code Cache`, `GPUCache`, logs;
JetBrains `caches`, `index`, `log`, `tmp` per product; Visual Studio `ComponentModelCache`
and designer shadow caches.

**Never touched:** extensions and plugins (removing them uninstalls working tools),
settings and keymaps, workspace storage (per-project state including unsaved buffers and
local history, which JetBrains uses as a genuine recovery mechanism).

**Visual Studio's installer package cache is reported, never deleted.** Visual Studio needs
it to repair, modify or uninstall itself. The supported way to shrink it is the Visual
Studio Installer.

Clearing a JetBrains index means reindexing on next open, which on a large project takes
minutes and a lot of CPU — the recommendation says so.

---

## Storage and external

### `Storage.LargeFiles` — advisory only

Reports files above `LargeFileThresholdMB` (1 GB), categorised by type.

**Nothing is ever proposed for deletion based on size.** A 40 GB file may be a forgotten ISO
or the virtual machine someone's job depends on, and size does not distinguish them.

Only looks where told: without `-DeepScanPath` it examines the top level of the user profile
and says so.

### `External.Czkawka` — default scanning, reviewed deletion

Enabled by default with `Safety.AllowExternalTools` and Czkawka CLI **12.0.2**.
Without `DeepScanPaths`, scans the configured `DefaultScanPaths`: Downloads, Desktop,
Documents, Pictures, Videos and Music. Explicit paths replace those defaults. A missing,
protected or linked folder is skipped and reported, and the remaining folders are still
scanned. Explicit paths never fall back to the defaults, so scope can only shrink; when no
folder is left, the provider does not run and the cleanup flow says why.
Resolve the executable via `ExecutablePath`, the local `Tools/Czkawka` installation,
or `ExecutableName` on PATH. When missing, `AutoDownload` (true by default) downloads the
pinned Windows release into `Tools/Czkawka`, verifies its SHA-256, then verifies its version.
This also happens in analysis and DryRun; scan targets remain untouched in inspection modes.
Downloads require external tools to be enabled and valid scan folders. Both the provider
and automatic download are enabled by default; `Providers.Disabled` or
`Safety.AllowExternalTools: false` disables Czkawka.
Set `AutoDownload` false for offline use. `Scripts/Install-Czkawka.ps1` uses the same
installer for manual setup/repair. Invalid custom paths and incompatible installed versions
are reported without replacement. Network and checksum failures prevent the scan.

`ScanTypes` selects `duplicates`, `empty-folders`, `empty-files`, `temporary`, and
`similar-images`, and `broken-files`. All selected roots are scanned together. Catalog entries request JSON,
disable caches and suppress the special exit code for finding matches. Reports remain
under `Data/Reports/Czkawka/<SessionId>`; unsuccessful scans propose no deletions.

Each eligible target becomes one `CzkawkaDelete` operation with a HIGH risk floor. Each
scan type is one plan action holding all of its candidates, with nothing selected. The
review screen (`Core/CzkawkaReview.ps1`) shows the candidates in pages. You pick items there
with Czkawka's own bulk selection rules, taken from Krokiet 12.0.2:

| Scan type | Rules offered |
|---|---|
| Duplicates | select all except longest path, shortest path, biggest size, smallest size, newest or oldest; invert selection in group; invert selection; deselect all; select all; custom |
| Similar images | as duplicates, plus select all except biggest resolution or smallest resolution |
| Empty folders, empty files, temporary files, broken files | invert selection; deselect all; select all; custom |

`t 3, 7-12` toggles single items. "Select all except X" spares the first file in a group
on a tie, and path length compares the folder before the file name. "Invert selection in
group" flips only groups that already have a selection. Custom selection matches a
wildcard against the full path, ignoring case, and never selects the last unselected file
in a group. After you finish and type YES, the action is rebuilt with exactly the selected
operations and approved individually. It can never be batch-approved.

Every member of a duplicate or similar-image group is a candidate, and no copy is kept
automatically. A selection that covers a whole group cannot be confirmed. When a selection
is confirmed, the unselected members of each affected group are reserved for the session.
A group member is deleted only when a reserved member of the same group is present and
unchanged, and for duplicates still byte-identical. A path found by several scan types
belongs to the first one. A group left with one member is dropped. Similarity is not
equality: compare the images in a group before selecting. Recent temporary files are
filtered using the normal minimum temp age and both creation and modification time.

Broken files use Czkawka's default PDF, audio, image, archive, font and markup validators.
The reported validation error appears under the file on the review screen. Validation failure does
not imply that the file is unrecoverable. Optional FFmpeg/ffprobe video checks are disabled.
Like every file candidate, a repaired or otherwise changed file is skipped at execution.

The core executor verifies the session manifest, current scope, metadata and SHA-256
again. It checks and holds the kept file against writes/deletion while removing the
approved target. Empty directory trees must have the same reviewed directory membership
and contain no files, including hidden files. Removal is nonrecursive, deepest first.

Personal folders are permitted only for this operation; ordinary cache protections remain
unchanged. OS paths, protected extensions, repositories, excluded paths, links and offline
placeholders remain blocked. Scan roots are never deleted. All deletions bypass the
Recycle Bin and are irreversible. DryRun/Plan/Analyze never delete scan targets.

See the [quick-start commands](../README.md#czkawka-1202).
