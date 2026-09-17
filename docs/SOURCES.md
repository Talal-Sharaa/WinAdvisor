# Sources

Every non-obvious Windows behaviour, command, registry location and third-party integration
in WinAdvisor was checked against a primary source. Optimisation blogs were not used.

Source priority, as applied throughout:

1. Microsoft Learn / official Microsoft documentation
2. Official PowerShell documentation
3. Official vendor documentation for the tool concerned
4. Official open-source project documentation
5. Project source code, where documentation is insufficient

All links verified September 2026.

---

## Windows servicing and the component store

- **Clean Up the WinSxS Folder** —
  <https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder>

  Establishes `DISM /Online /Cleanup-Image /StartComponentCleanup` and `/ResetBase` as the
  supported cleanup mechanisms, and `/AnalyzeComponentStore` as the measurement. Carries the
  explicit warning that deleting files from WinSxS "may severely damage your system so that
  your PC might not boot and make it impossible to update", and that after `/ResetBase`
  "all existing update packages can't be uninstalled".

  Used by: `Core/CommandCatalog.ps1` (three DISM entries), `Providers/Windows.Servicing.ps1`,
  `Config/policies.json` (WinSxS on the protected path list).

- **Determine the actual size of the WinSxS folder** —
  <https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/determine-the-actual-size-of-the-winsxs-folder>

  Why directory size is meaningless for WinSxS: hard links mean a naive sum counts the same
  bytes many times over. This is why the provider refuses to estimate it and uses DISM.

- **Manage the Component Store** —
  <https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/manage-the-component-store>

  Background on the automatic `StartComponentCleanup` scheduled task and its 30-day
  per-component grace period, quoted in the recommendation text.

## Power configuration

- **powercfg command-line options** —
  <https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options>

  `powercfg /hibernate on|off`, `/a` for available sleep states, `/getactivescheme`.

  Used by: `Core/CommandCatalog.ps1`, `Providers/Windows.Hibernation.ps1`,
  `Core/Discovery.ps1`.

## Windows Subsystem for Linux

- **How to manage WSL disk space** —
  <https://learn.microsoft.com/en-us/windows/wsl/disk-space>

  The decisive source for the WSL provider being advisory only. Documents how to **expand**
  a WSL virtual hard disk; publishes no supported in-place shrink. Also states: "We recommend
  that you do not modify, move, or access the WSL related files located inside of your
  AppData folder using Windows tools or editors. Doing so could cause your Linux distribution
  to become corrupted."

  Also documents locating a distribution's `ext4.vhdx` through
  `HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss`, which is how the provider finds it.

- **Basic commands for WSL** —
  <https://learn.microsoft.com/en-us/windows/wsl/basic-commands>

  `wsl --list --verbose`, `--status`, `--version`, `--shutdown`. Also the warning that
  `wsl --unregister` permanently destroys all data in a distribution, which is why it is
  not in the catalog.

## Windows components and APIs

- **Windows Error Reporting** —
  <https://learn.microsoft.com/en-us/windows/win32/wer/windows-error-reporting>
  ReportArchive and ReportQueue layout, used by `Providers/Windows.Temp.ps1`.

- **Run and RunOnce registry keys** —
  <https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys>
  The startup locations enumerated by `Core/Workloads.ps1`.

- **System Restore** —
  <https://learn.microsoft.com/en-us/windows/win32/sr/system-restore-portal>
  Behaviour and limits, including that it does not restore personal files. Basis for the
  caveats in `Providers/Windows.RestorePoints.ps1`.

- **Recycle Bin** —
  <https://learn.microsoft.com/en-us/windows/win32/shell/recycle-bin>
  Per-volume, per-user `$Recycle.Bin\<SID>` layout.

- **Delivery Optimization** —
  <https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization>
  Cache behaviour and the `Delete-DeliveryOptimizationCache` cmdlet named in the report.

- **Storage Sense** —
  <https://learn.microsoft.com/en-us/windows/client-management/client-tools/disk-cleanup>
  The supported route for previous Windows installations and Windows Update cleanup, which
  WinAdvisor points at rather than reimplementing.

- **Win32_OperatingSystem, Win32_ComputerSystem, Win32_PhysicalMemory, Win32_VideoController** —
  <https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/computer-system-hardware-classes>

  Note on `Win32_VideoController.AdapterRAM`: it is a signed 32-bit value and wraps above
  4 GB. `Core/Discovery.ps1` prefers `HardwareInformation.qwMemorySize` from the display
  driver key and records `AdapterRAM` separately, labelled as unreliable.

- **Win32_PerfRawData_PerfOS_Memory** —
  <https://learn.microsoft.com/en-us/previous-versions/aa394314(v=vs.85)>
  Language-neutral property names for committed bytes and commit limit, unlike localised
  performance-counter paths. Basis for the commit-pressure measurement.

- **Get-PhysicalDisk** —
  <https://learn.microsoft.com/en-us/powershell/module/storage/get-physicaldisk>
  `MediaType` frequently reports `Unspecified` for NVMe, which is why `BusType` is consulted
  to classify drive kind.

- **ProductName on Windows 11** — `CurrentVersion\ProductName` still reads "Windows 10" on
  Windows 11 for application compatibility. `Core/Discovery.ps1` prefers
  `Win32_OperatingSystem.Caption` and keeps the registry value as `RegistryProductName`.
  Confirmed empirically on build 26220: registry reported "Windows 10 Pro" while Caption
  reported "Windows 11 Pro Insider Preview".

## NuGet and .NET

- **nuget locals / dotnet nuget locals** —
  <https://learn.microsoft.com/en-us/nuget/reference/cli-reference/cli-ref-locals>
  Cache names (`global-packages`, `http-cache`, `temp`, `plugins-cache`, `all`) and the
  `--list` / `--clear` operations.

- **Managing the global packages and cache folders** —
  <https://learn.microsoft.com/en-us/nuget/consume-packages/managing-the-global-packages-and-cache-folders>
  Confirms the global-packages folder is relocatable via `NUGET_PACKAGES` and NuGet.Config,
  which is why the provider asks NuGet where its caches are rather than assuming a path.

- **dotnet command** — <https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet>
  `--list-sdks`, `--list-runtimes`.

## Docker

- **docker system df** — <https://docs.docker.com/reference/cli/docker/system/df/>
  Reports size and reclaimable space per category; `--format` supports JSON output.
- **docker builder prune** — <https://docs.docker.com/reference/cli/docker/builder/prune/>
- **docker image prune** — <https://docs.docker.com/reference/cli/docker/image/prune/>
  Without `--all`, only dangling images; with it, every image not used by an existing
  container.
- **docker container prune** — <https://docs.docker.com/reference/cli/docker/container/prune/>
- **docker volume prune** — <https://docs.docker.com/reference/cli/docker/volume/prune/>
  Read for the advisory text only. Not in the command catalog.

Docker reports human sizes in base 1000 (`GB` = 10⁹), which `ConvertFrom-WaDockerSize`
handles distinctly from binary `GiB`.

## Package managers

- **npm cache** — <https://docs.npmjs.com/cli/v10/commands/npm-cache>
  Documents that the cache is self-healing and safe to delete, and that `clean` requires
  `--force`.
- **pnpm store** — <https://pnpm.io/cli/store>
  `store path`, `store prune`. The documentation's warning that projects hard-link into the
  store is why WinAdvisor never file-deletes a pnpm store.
- **Yarn cache** — <https://classic.yarnpkg.com/en/docs/cli/cache>
- **pip cache** — <https://pip.pypa.io/en/stable/cli/pip_cache/>
- **uv CLI reference** — <https://docs.astral.sh/uv/reference/cli/>
  `cache dir`, `cache prune`, `cache clean`.
- **Cargo home** — <https://doc.rust-lang.org/cargo/guide/cargo-home.html>
  Layout of `registry/cache`, `registry/src`, `registry/index`, and the `CARGO_HOME`
  override.
- **Gradle directory layout** —
  <https://docs.gradle.org/current/userguide/directory_layout.html>
- **Maven local repository** —
  <https://maven.apache.org/guides/introduction/introduction-to-repositories.html>
  Confirms `mvn install` writes locally built artefacts into the same directory as
  downloaded ones, which is why it is classified MODERATE rather than LOW.

## Browsers

- **Chromium user data directory** —
  <https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md>
  Profile layout for Chrome, Edge, Brave, Vivaldi and Chromium. Basis for the explicit
  cache-subdirectory allow-list, and for knowing which files hold credentials and bookmarks
  so they can be excluded.

- **Firefox profiles** —
  <https://support.mozilla.org/en-US/kb/profiles-where-firefox-stores-user-data>
  Confirms the split between the Roaming AppData profile (passwords, bookmarks, history)
  and the Local AppData cache, which is what lets the cache be cleared without approaching
  the profile.

## Third-party projects evaluated

Licences confirmed from each project's own repository.

| Project | Licence | Repository |
|---|---|---|
| Chris Titus Tech WinUtil | MIT | <https://github.com/ChrisTitusTech/winutil> |
| Sophia Script for Windows | MIT | <https://github.com/farag2/Sophia-Script-for-Windows> |
| BleachBit | GPL-3.0-or-later | <https://github.com/bleachbit/bleachbit> |
| Czkawka (GTK + `czkawka_cli`) | MIT | <https://github.com/qarmin/czkawka> |
| Czkawka (Krokiet front end) | GPL-3.0-only | same repository |
| Bulk Crap Uninstaller | Apache-2.0 | <https://github.com/Klocman/Bulk-Crap-Uninstaller> |
| Pester (test dependency) | Apache-2.0 | <https://github.com/pester/Pester> |

- **Czkawka CLI usage** —
  <https://github.com/qarmin/czkawka/blob/master/czkawka_cli/README.md>
  The `dup` subcommand, `--directories`, `--search-method`, `--file-to-save`. Deletion flags
  were read specifically so they could be excluded; none appears in the command catalog.

- **BleachBit CLI** —
  <https://docs.bleachbit.org/doc/command-line-interface.html>
  Read during evaluation. Not integrated — see [RESEARCH.md](RESEARCH.md) for the reasoning,
  which is both architectural and licence-related.

**Licence position.** WinAdvisor copies no code from any of these projects. Czkawka is the
only one invoked, as a separate process, and only when the user has installed it and
explicitly enabled it. Invoking a separate process does not create a derivative work.
BleachBit's GPLv3 cleaner definitions are deliberately not translated or reused, since doing
so would place this project under GPL obligations.

## PowerShell

- **about_Execution_Policies** —
  <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies>
- **Set-StrictMode** —
  <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/set-strictmode>
- **Pester** — <https://pester.dev/docs/quick-start>

**Engine behaviour worked around.** On PowerShell 7.6.6, `@($list)` around a
`System.Collections.Generic.List` throws `ArgumentException: Argument types do not match`
from `PSToObjectArrayBinder`. Reproduced minimally and confirmed that `.ToArray()` is
unaffected. The codebase uses `.ToArray()` for generic lists throughout; `ConvertTo-WaArray`
handles the general case. Verified working on both 5.1 and 7.6.6.
