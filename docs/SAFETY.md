# Safety model and audit

Phase 9 of the project: a deliberate adversarial review of every code path capable of
deleting data, changing the registry, changing services, modifying startup behaviour,
running elevated commands, invoking external tools or changing Windows configuration.

The review was conducted by enumerating every mutating primitive in the codebase, then
asking of each: *what would it take to make this do something harmful?*

---

## The mutating surface

The complete list of calls that can change machine state:

| File | Primitive | Guard |
|---|---|---|
| `Core/Execution.ps1` | `[IO.File]::Delete` | approved root, policy, per-file re-validation |
| `Core/Execution.ps1` | Czkawka file / nonrecursive directory deletion | exact session manifest, HIGH risk, individual approval, retained-copy and content checks |
| `Core/Execution.ps1` | `Set-ItemProperty` / `New-ItemProperty` | HKLM/HKCU only, rollback captured first |
| `Core/Execution.ps1` | `Set-Service` | protected-service list, rollback captured first |
| `Core/Execution.ps1` | `Enable-/Disable-ScheduledTask` | `\Microsoft\Windows\*` refused, rollback first |
| `Core/Execution.ps1` | `Checkpoint-Computer` | additive only; never removes a restore point |
| `Core/Execution.ps1` | `Invoke-WaNativeProcess` | command catalog only |
| `Core/Rollback.ps1` | registry / service / task restore | same policy checks as the forward operation |
| `Core/Elevation.ps1` | `Start-Process -Verb RunAs` | fixed arguments, constrained mode |
| `Core/{Common,Logging,Reporting,Session,Rollback}.ps1` | `New-Item -ItemType Directory` | only under `Data/` |

**Providers contain no mutating primitives.** Czkawka report creation lives in
`Core/Czkawka.ps1`; target deletion lives in `Core/Execution.ps1`. `Core/CzkawkaInstaller.ps1`
downloads and verifies the pinned CLI into `Tools/Czkawka` on first enabled use. The
standalone `Scripts/Install-Czkawka.ps1` shares this implementation. Dependency setup can
run in inspection modes, after provider enablement and scan-root validation; it does not
change scan targets. A failed checksum never replaces an existing executable, incomplete
downloads are removed, and no unverified download is executed.

Everything else in `Providers/` reads, measures and describes.

### Czkawka cleanup exception

Czkawka 12.0.2 scans the six standard personal folders by default, or explicitly selected
folders when supplied. Missing, protected, linked and offline default roots are skipped.
Personal-file deletion still needs an explicit choice of exact targets. Each scan type is
one plan action. On the review screen (`Core/CzkawkaReview.ps1`) the user selects items,
individually or with Czkawka's bulk rules. The action is then rebuilt with exactly those
operations (`Set-WaPlanActionRecommendation`, which drops any earlier approval), and the
user approves that list individually by typing `YES`. This does not weaken `FileDelete` or
ordinary cache policy. `Safety.AllowExternalTools: false` or disabling the provider
prevents scanning and dependency download.
`CzkawkaDelete` has a HIGH floor, requires individual approval, and checks its parameters
against the session's scanned manifest as well as the approval fingerprint. No CLI deletion
flag is allowed. No duplicate or similar-image copy is kept automatically. A selection
covering a whole group is refused. Confirming a selection reserves the group's unselected
members, and deleting a member requires a reserved member of the same group to be present
and unchanged, and for duplicates byte-identical. That member is held open during the
delete. Local scope, exclusions, repository markers, protected extensions and links are
rechecked. Folder removal is nonrecursive and fails when new content appears. Deletion is
permanent and System Restore cannot recover it.

Regression and real-binary fixture tests are in `Tests/Czkawka.Tests.ps1`.

---

## Findings from the audit

Five issues were identified and fixed. All are covered by regression tests.

### F-1 — Rollback restoration did not honour the read-only gate

**Severity:** High.

`Restore-WaRollbackRecord` performed registry, service and scheduled-task writes without
calling `Assert-WaMutationAllowed`. Only the `NativeCommand` branch checked. The public
entry point always creates a mutable session, so this was not reachable in normal use, but
the invariant "no write happens without the gate" was not actually held by the code.

**Fix.** `Assert-WaMutationAllowed` at the top of `Restore-WaRollbackRecord`.
**Test.** *refuses a restore in a read-only session*.

### F-2 — Rollback records were trusted as if the engine had just produced them

**Severity:** High.

Rollback state is read from `Data/Rollback/<session>/state.json` — an ordinary file on disk,
editable by anyone who can write to the project directory. The restore branches took
`RestoreParameters` at face value:

- the registry branch did not check that `Path` was under HKLM or HKCU;
- the service branch did not consult the protected-service list;
- the scheduled-task branch did not apply the `\Microsoft\Windows\*` guard;
- the startup branch did not check the protected-startup patterns.

A crafted `state.json` could therefore have used the restore path to re-enable a service the
forward path would have refused to touch, or write to a hive the engine never writes to.

**Fix.** Every restore branch now re-applies the same policy checks as the corresponding
forward operation. A rollback record is treated as untrusted input: it is a *request* to
restore, not permission to act on an arbitrary target.
**Tests.** Four *refuses a crafted record…* cases covering registry hive, protected service,
Windows servicing task and protected startup item.

### F-3 — Deletion used the manifest path rather than the validated path

**Severity:** Low.

`Test-WaFileDeleteAllowed` normalises the path it validates and returns it, but
`Invoke-WaFileDeleteOperation` then deleted `$file.Path` — the original manifest string.
The two are equivalent because `GetFullPath` is deterministic, so this was a latent
weakness rather than an exploitable bug, but validating one string and acting on another is
the shape of a real vulnerability.

**Fix.** The preview now carries `$decision.Path`, the exact string that passed validation,
and the delete acts on that.

### F-4 — Elevation mode parameter was unconstrained

**Severity:** Low.

`Request-WaElevatedRelaunch -Mode` was a free `[string]` that becomes an argument to an
elevated process. All callers pass a literal, so it was not reachable, but an unconstrained
string feeding an elevated command line should not exist.

**Fix.** `ValidateSet` restricting it to the known modes.

### F-5 — The user profile was protected recursively, disabling the toolkit

**Severity:** High (correctness, not safety).

`{UserProfile}` was on the recursive protected-path list. Because virtually every
application cache lives under the user profile, this silently classified every cache file as
protected. The toolkit ran, reported findings, and proposed almost nothing — a failure that
looked like "this machine is clean" rather than an error.

Discovered when a scan of a 3.47 GiB user Temp directory returned zero eligible files.

**Fix.** Protection split into two lists. `Paths` are protected recursively; `RootsOnly`
protects the directory itself but not its contents. The user profile, the system drive,
LocalAppData, RoamingAppData and ProgramData moved to `RootsOnly`; Documents, Desktop,
Pictures, Videos, Music, Downloads, OneDrive, `.ssh`, `.gnupg`, `.aws`, `.kube` and the
DPAPI/credential stores remain recursive.
**Tests.** *protects the user profile root itself* and *does NOT protect application caches
inside the profile, or the toolkit is useless*.

---

## Attack-shaped questions and their answers

**Can a provider delete an arbitrary file?**
No. Routine cache providers build manifests through `Get-WaCacheRootCandidate`, which measures a
directory. The resulting operation references a root *by key*; the executor resolves that
key against roots registered in this session. Registering a root runs it through the
protected-path and protected-segment checks. Every individual file is then re-validated at
the moment of deletion.

Czkawka uses a separate manifest registered during the current scan. Its executor also
requires exact manifest and approval fingerprints, selected-root containment and individual
approval; a changed manifest or an out-of-scope target is refused.

**Can an edited plan file redirect a delete?**
No. Changing the root invalidates the action fingerprint, so the approval no longer matches
and execution refuses. Changing the root key to something unregistered fails to resolve.
A test covers the first case directly.

**Can a provider run an arbitrary command?**
No. Providers supply a catalog id, not a command line. The catalog owns the executable and
the argument vector. Placeholder values are validated against a declared regular expression
and refused on mismatch — a test attempts to smuggle `" --delete-files "` through the
Czkawka directory placeholder and is refused.

**Can PATH manipulation hijack an elevated command?**
No. Windows tools resolve through `System32` via the .NET special-folder API, never through
PATH. Third-party tools (docker, dotnet, npm) do resolve through PATH, but none of their
catalog entries requires administrator rights, so a PATH hijack cannot gain elevation
through WinAdvisor.

**Can argument injection reach a shell?**
No shell is ever involved: `UseShellExecute = $false`. Arguments containing a quote or
newline are rejected outright rather than escaped. Tests cover both.

**Can a HIGH-risk action slip through a batch approval?**
No, at three independent layers. `Grant-WaApproval` throws when batch scope is requested for
an action requiring individual approval. `Grant-WaBatchApproval` skips such actions and
reports why. `Test-WaApproval` independently rejects a batch-scoped approval record on a
HIGH-risk action, so a forged record fails too. A test forges one.

**Can a MANUAL-ONLY recommendation be executed?**
No, at four layers. It cannot be approved. `Test-WaApproval` refuses it unconditionally,
before looking at the record. `Invoke-WaPlan` skips it. And it carries no operations, so
there would be nothing to run even if the other three failed. All four are tested.

**Can Dry Run change anything?**
No. The session's `ReadOnly` flag is set at construction from the mode and never mutated.
Every mutating primitive calls `Assert-WaMutationAllowed` first. A test approves a real
delete of real files in a sandbox, runs the plan in a DryRun session, and asserts the files
still exist.

**Can browsing the menu leave you in a mutable session?**
No. The menu runs read-only. Choosing Interactive Cleanup constructs a *new* session in
Cleanup mode rather than promoting the current one. There is no code path that flips
`ReadOnly`.

**Can a scan follow a junction out of its root?**
No. Any entry with the reparse-point, offline, recall-on-open or recall-on-data-access
attribute is skipped and marks the scan partial. Cloud placeholders are skipped for the same
reason, which also avoids forcing a multi-gigabyte OneDrive download. Every enumerated path
is additionally prefix-checked against the normalised root.

**Can a symlinked file inside a cache be deleted through the link?**
No. `Test-WaFileDeleteAllowed` checks the file's own attributes and then walks the whole
ancestor chain via `Test-WaPathUnlinked`, because a junction three levels up redirects
everything beneath it.

**Can a file in active use be deleted?**
Not without being noticed. The manifest records length and last-write time at review. Before
deletion both are compared against the file on disk; a mismatch means something wrote to it
between review and execution, and it is skipped with a recorded reason. Locked files simply
fail to delete and are counted, not retried or forced.

**Could a VM disk or database be caught in a cache sweep?**
No. `NeverDeleteExtensions` excludes virtual disks, databases, mail stores and key material
by extension wherever they are found, including inside an approved cache root. Their bytes
are still counted in the storage report, so the picture stays honest. A test drops a
`.vhdx` into a sandbox cache and asserts it is excluded from the manifest and refused by the
delete gate.

**Could a source repository be swept up?**
No. `ProtectedPathSegments` refuses any path containing `.git`, `.hg`, `.svn`,
`node_modules`, `site-packages`, `.venv`, `.terraform`, `System Volume Information` or
`$Recycle.Bin`.

---

## Standing guarantees

These hold by construction and are individually tested.

1. Personal documents are never deleted automatically.
2. No file is deleted by extension pattern or by directory size.
3. Source repositories, databases, VM disks and container volumes are never deleted.
4. WSL distributions are never removed, and no WSL mutation exists in the catalog.
5. Browser credentials, bookmarks, autofill, cookies, history and sessions are never touched.
6. Restore points are never removed. The toolkit only ever adds one.
7. WinSxS is never manipulated directly; servicing goes through DISM.
8. No security feature is ever disabled, or offered for disabling.
9. Unknown services and unknown startup items are never modified.
10. No application is ever uninstalled.
11. No third-party tool is ever downloaded or installed.
12. No performance improvement is ever claimed.
13. Cache clearing is never described as RAM optimisation.
14. Persistent configuration changes are always disclosed, with their rollback path.
15. HIGH-risk actions always require individual approval.
16. MANUAL-ONLY recommendations are never executed.
17. ViewSpecs, Analyze, Storage, Startup, Plan and DryRun never modify anything.
18. When safety cannot be positively established, the answer is refusal.

---

## Residual risks

Stated plainly, because a safety document that claims none is not credible.

**A cache clear still costs something.** Clearing an 11 GiB NuGet cache means the next build
of every project re-downloads. On a metered or slow connection that is a real cost, and the
recommendation says so, but the user has to weigh it.

**Locked files reduce the result, not the safety.** Cleaning with a browser or editor
running reclaims less than the estimate. The report distinguishes reviewed, deleted and
skipped counts so the shortfall is visible rather than mysterious.

**System Restore is not a safety net.** It does not restore personal files, it can be off
per volume, and Windows rate-limits and discards checkpoints. WinAdvisor attempts one before
the first HIGH-risk change and reports honestly when Windows declines. It is never presented
as an undo for a cleanup.

**Free-space deltas are noisy.** Windows Update, the search indexer and the pagefile all
write during a run. This is why the report separates *measured during execution* (the
defensible figure, from files counted as they were deleted or a tool's own report) from
*free-space change* (context only, and occasionally negative).

**Partial scans understate.** A scan that hits its budget reports a lower bound. The
estimate is then conservative rather than wrong, and every such figure is rendered with
"at least".

**Third-party output formats change.** Providers parse tool output, and tools change. Every
provider stage is failure-isolated, and a provider that cannot parse what it received
reports itself degraded rather than acting on a misreading. The Docker provider explicitly
refuses to propose anything when `docker system df` produces output it cannot parse.

**Advisory items are the user's risk.** Docker volumes, WSL disks and large
files are explained but not acted on. A user who follows the manual instructions is
operating outside the toolkit's guarantees, which is why those instructions carry their own
warnings.
