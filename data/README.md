# Sources of the single-file builder's bundled resources

Users only need `win-11-lite.ps1` to run the builder. These three source files are embedded as readable PowerShell string literals in its generated resource block; the builder always reads that block, even if a neighboring `data/` folder exists. It writes the required runtime scripts into the Windows image itself. The separate installed-VM updater still uses the source files supplied in its update package.

After editing a resource, regenerate the standalone file and verify it:

```powershell
powershell.exe -NoProfile -File .\tools\Update-BundledResources.ps1
powershell.exe -NoProfile -File .\tools\Update-BundledResources.ps1 -Check
```

Run these commands from the repository root and commit both the edited sources and `win-11-lite.ps1`. `Test-Win11Lite` and `Test-SingleFile` reject stale resources. Resources use canonical Windows newlines when read from the bundle, so a Git LF checkout still writes byte-identical files into the image. No encoded archive, dynamic script download, or custom EXE is involved.

The retired `deployment-tools-28000.json` and `winpe-26100.json` catalogs are gone. `$script:AdkSources` in the builder pins only the addresses, sizes and hashes that the installers do not state: four 26H1 tool installers (2,445,312 bytes) with their nine CABs (6,641,932 bytes in total) and one WinPE add-on installer (1,015,808 bytes) with its two language archives. Every other detail, including the mapping of `fil<hash>` cabinet members to their real names and sizes, is read from the MSI `File`, `Component`, `Directory` and `Media` tables at build time; the installers are never executed. CAB sizes and hashes still come from the manifest of the Microsoft-signed [ADK bootstrapper](https://go.microsoft.com/fwlink/?linkid=2337875). No Microsoft binaries are redistributed here. The prepared DISM was verified as Microsoft-signed 10.0.28000.1 and both catalogs were confirmed to reproduce the retired JSON files exactly; complete image servicing still requires an elevated Windows process.

`Run-Setup.ps1` replaces the former custom EXE launcher for Prepare/Finalize and the SYSTEM guard worker. Children use `CreateNoWindow`, with output and exit codes retained in `launcher.log`. Guard presentation now bypasses this runner: the worker requests one limited, demand-start task in each desktop session after native OOBE completion. Standard opens the summary after checking, Debug opens the live log, and Silent requests no user process. Early Windows Setup entry points can still flash a console; no custom launcher executable is built or distributed.

`guard.ps1` contains the guard worker and read-only `-View` entry point; `Guard.UI.ps1` contains presentation helpers and demand-task registration. The builder writes both into the guest support directory automatically. Each run saves `guard-summary.txt`, full `guard-report.txt`, structured `guard-report.json`, and successful observations in `guard-state.json`. `guard-run.json` records the run ID and log offset. Program totals deduplicate installed/provisioned copies, and recurrence requires previous successful observations; failed re-removals are counted as reappearances without claiming success. Live log reading permits shared UTF-8 writes. The viewer uses [Task Scheduler RunEx](https://learn.microsoft.com/en-us/windows/win32/taskschd/registeredtask-runex) with a session ID so it runs as that session's user, not SYSTEM.

The pinned WinPE values were extracted on 2026-09-12 from the Windows PE add-on for ADK **10.1.26100.2454**, linked by Microsoft's [ADK download page](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install):

- Bootstrapper: `https://go.microsoft.com/fwlink/?linkid=2289981` (`adkwinpesetup.exe`). Authenticode signature: **Valid**, Microsoft Corporation.
- Resolved directory: `https://download.microsoft.com/download/5/5/6/556e01ec-9d78-417d-b1e1-d83a2eff20bc/ADKWinPEAddons/`.
- MSI: `Installers/Windows PE Optional Packages (DesktopEditions)-x86_en-us.msi`. The x86 in this installer filename does not describe its payload architecture: this MSI carries both amd64 and arm64 packages. Only the `amd64/WinPE_OCs` entries are included here.
- MSI SHA256: `F286C52FDF694C85F08F6EC0BA7702DE84F891040064B81163C8DA59A5C4DB4C`.
- MSI SHA1: `E9BFF116C9A65FECD7125112D8B20C9BA3001327`, matched against the signed bootstrapper's Burn manifest.

File paths and cabinet members are derived at build time from the MSI `Directory`, `Component`, `File` and `Media` tables. Archive sizes and SHA1 values come from the signed bootstrapper's payload manifest. The 320,140,822-byte language archive was downloaded and its hash verified; Russian CABs were extracted and their `update.mum` identities checked against amd64, ru-RU and Windows build 26100.

The add-on carries 37 languages (24 localized optional CABs each) and six font CABs. The language archive is shared by all languages; selecting Russian does not install the other languages. Fonts are downloaded only when the chosen language requires them.

On use, the builder verifies the installer and archive hashes, copies the selected language files, checks required package identities and writes a SHA256 cache manifest. Subsequent builds can reuse the prepared set without contacting Microsoft. Other WinPE builds require matching local files via `-SetupLanguageSource`.

`WinPE-LegacySetup` is an optional compatibility component; it is not required merely because Windows Setup is launched with `/legacy`. The source LTSC 26100.1742 boot image does not contain this component. The builder adds language satellites only for WinPE components actually present in the image. The regular WinPE Setup packages provide the modern and classic installer resources.
