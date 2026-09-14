[English](/README.md) | [Русский](/README.ru_RU.md)

# win-11-lite

[![Windows 11 x64](https://img.shields.io/badge/Windows%2011-x64-0078D4.svg)](#requirements-and-supported-images)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE.svg)](#requirements-and-supported-images)
[![Tests](https://img.shields.io/badge/tests-1181%20%C3%97%202-success.svg)](#validation-status)

**win-11-lite** builds a smaller, privacy-focused Windows 11 installation ISO from an original Microsoft x64 image. It removes selected inbox applications and components, applies privacy and OOBE settings, can integrate updates, languages and drivers, and exports one chosen Windows edition into a new bootable ISO.

The builder is a single PowerShell file. Download [`win-11-lite.ps1`](win-11-lite.ps1); no `data`, `tools`, generator, custom executable, Git, or GitHub CLI is required at runtime.

> [!WARNING]
> This project deliberately removes Windows components. The default `balanced` preset removes Microsoft Defender, Windows Security, Recall and other AI components, speech/OCR features, Media Player, Xbox/Game Bar and selected consumer apps. Review the plan with `-DryRun` and test the resulting ISO in a VM before using it on a real machine.

## Quick Start

Download the one required file:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/coinman-dev/win-11-lite/main/win-11-lite.ps1 -OutFile .\win-11-lite.ps1
.\win-11-lite.ps1
```

Running without parameters opens the interactive wizard. It finds nearby ISO files, asks which edition and preset to use, and requests administrator rights when the build starts.

Preview an image and the complete removal plan without elevation or modification:

```powershell
.\win-11-lite.ps1 -InputIso .\iso\original.iso -Index 2 -DryRun
```

A compact Pro build with Guard enabled:

```powershell
.\win-11-lite.ps1 -InputIso .\iso\original.iso -Edition Professional -Preset balanced -Guard Standard -LegacySetup -TrimSources -RemoveWinRE -SaveWinRE
```

Add current updates, winget, drivers and Russian Windows/Setup language:

```powershell
.\win-11-lite.ps1 -InputIso .\iso\original.iso -Index 2 -WithUpdates -WithWinget -DriversDir .\drivers -DownloadLanguage ru-RU -Guard Standard -Debug
```

The output ISO is written to `out\<source-name>_lite.iso` by default. Use `-UILang ru` or `-UILang en` to select the builder UI independently of the Windows image language.

---

## Why Guard exists

Removing a component from an offline image is not always permanent. A cumulative or feature update can provision an inbox app again, restore Edge or Defender files, re-enable a service, or reset a policy. **Guard makes the selected build state persistent after Windows is installed.**

When enabled, the `win-11-lite guard` scheduled task runs as `SYSTEM` after user sign-in with a 30-second delay. It waits until Windows reports that OOBE is complete, then:

- inventories the applications, provisioned packages, Windows capabilities, files and directories selected by the build;
- removes targets that have returned and cleans Edge again when needed;
- verifies and reapplies the selected machine policies;
- disables or stops monitored services that have been restored;
- checks the outcome of every operation instead of reporting an attempted action as success;
- keeps history so the report can distinguish the first observation from a confirmed reappearance.

Guard is not an antivirus, backup tool, or general Windows repair service. It enforces the specific removals and settings recorded when the ISO was built.

### Guard modes

`-Guard` is one parameter with four values:

| Mode | Behavior |
| --- | --- |
| `None` | Do not embed Guard. This is the command-line default. |
| `Standard` | Run in the background and open a concise result after the check. This is the wizard default. |
| `Debug` | Open a live, detailed log window and show the full result. |
| `Silent` | Run without a user window; write all reports to disk. |

```powershell
-Guard None
-Guard Standard
-Guard Debug
-Guard Silent
```

The old `-GuardMode` and `-GuardDebug` parameters no longer exist.

### Guard reports

Reports are stored in `C:\Windows\Setup\Scripts\Win11Lite\`:

| File | Contents |
| --- | --- |
| `guard-summary.txt` | Concise counts, short names for found objects, outcomes, errors and Guard control commands. |
| `guard-report.txt` | Full human-readable report with before/after state and technical details. |
| `guard-report.json` | Structured report with run ID, completeness, inventory state and item-level outcomes. |
| `guard-state.json` | History used to identify confirmed reappearances and repeated fixes. |
| `Logs\YYYY-MM-DD.log` | One daily log for Guard, preparation, finalization and both launchers, including full Guard reports, worker output and exit codes. |

Logs retain **today and the previous 29 days**. Repeated runs append to the same daily file; midnight starts a new one. Old daily files are removed automatically when the guest runtime writes its first log entry of the day. Debug follows its current Guard run across midnight. The latest `guard-report.txt/json` and `guard-summary.txt` are overwritten on each check; `guard-state.json` remains the working state for detecting restored components. Legacy log files stop growing and are removed once their last write is older than the retention window. Cleanup targets only recognized log files and never traverses filesystem links.

Standard and Debug display the path to the full report before closing. Unknown inventory state, pending servicing and failed verification are never counted as successful removal.

Disable future Guard runs from an elevated Terminal:

```powershell
schtasks.exe /Change /TN "\win-11-lite guard" /Disable
```

Enable Guard again:

```powershell
schtasks.exe /Change /TN "\win-11-lite guard" /Enable
```

Disabling the task does not stop a check already running and does not restore removed applications or policies. After re-enabling it, Guard runs at the next sign-in. Updating Guard itself requires rebuilding the ISO.

---

## Why Recall is removed

Windows Recall is an optional Copilot+ PC feature. If the user opts in, Windows saves screenshots of the active screen every few seconds and when the active content changes, then indexes the images and recognized text for later search. Microsoft states that snapshots remain local, are encrypted, require Windows Hello to access, and are not uploaded to Microsoft by Recall. Sensitive-information filtering is enabled by default. [Microsoft Recall overview](https://support.microsoft.com/en-us/windows/ai/ai-features/retrace-your-steps-with-recall), [privacy architecture](https://support.microsoft.com/en-us/windows/privacy/privacy-and-control-over-your-recall-experience).

That protection does not make screen history irrelevant. Anything visible in a terminal, browser, mail client, database tool, cloud control panel, password dialog or customer document can potentially appear in a retained screenshot. Microsoft notes that parts of filtered sites can still appear and that remote clients are captured unless they implement screen-capture protection. Its enterprise guidance explicitly calls allowing screenshots of content that must not be exfiltrated a general security risk. [Manage Recall for Windows clients](https://learn.microsoft.com/en-us/windows/client-management/manage-recall#bring-your-own-device-byod-considerations).

This matters on personal workstations used to administer servers: SSH terminals, hosting dashboards, API tokens, internal hostnames, customer records and private messages may all be displayed during ordinary work. Recall does not itself leak this data to the cloud, but it creates an additional searchable store of sensitive screen history. A compromised Windows session, an unsafe export, or a remote client without capture protection can turn that history into another source of exposure.

`balanced` and `max` therefore take a removal-oriented approach:

- set `AllowRecallEnablement=0` and `DisableAIDataAnalysis=1` for machine/default-user policy;
- disable Recall data providers and Recall export, and disable Click to Do and the Settings agent;
- request supported removal of the `Recall` optional feature and payload in `balanced`;
- remove matching Recall, Copilot, AI Fabric, AIX and AugLoop files/packages when present;
- pass the core Recall/Copilot policies and selected AI paths to Guard so updates cannot silently undo them.

Microsoft documents that disabling the Allow Recall policy disables the component, removes its bits, and deletes previously saved snapshots after restart; it also documents `Disable-WindowsOptionalFeature -Online -FeatureName "Recall" -Remove` for payload removal. [Microsoft policy reference](https://learn.microsoft.com/en-us/windows/client-management/manage-recall#allow-recall-and-snapshots-policies).

Recall is opt-in in current consumer Windows and removed by default on managed commercial devices. The project removes it because its design goal is a lean system with no retained screen timeline, not because Recall secretly uploads every screenshot.

---

## Presets

Presets are cumulative. `balanced` includes `safe`; `max` includes both and adds more destructive rules.

| Preset | Intended use | Main actions |
| --- | --- | --- |
| `safe` | Small privacy cleanup while keeping Defender and normal app compatibility | Removes the Edge browser and shortcuts while keeping WebView2; disables telemetry services/policies, advertising, suggestions and widgets; applies setup/OOBE privacy settings. |
| `balanced` | Default lite desktop | Adds Defender/Windows Security removal, speech/handwriting/OCR/Text-to-Speech, Recall/Copilot/AI components, classic and modern Media Player, IE stub, classic Paint, Steps Recorder, diagnostics, CJK fonts/IME where safe, OneDrive installers, NGEN cache, Xbox/Game Bar, Family, To Do and selected consumer apps. Keeps Store/MSIX, App Installer/winget, WebView2, servicing, Hyper-V and WSL. |
| `max` | Deliberately aggressive image reduction | Adds WebView2/Edge Update, component backups, PowerShell ISE, WMIC, Hello Face, formula recognition, fax/scan and extra FoD removal. Application compatibility and future servicing may break. VBScript remains as an explicit dependency of the hidden setup launcher. |

Selected consumer Appx targets include Clipchamp, Bing News/Weather, Get Help/Get Started, Office Hub, Solitaire, Feedback Hub, Phone Link, new Outlook, Teams, Xbox/Game Bar, Family and Microsoft To Do. Exact matches depend on what the source image contains.

### What `balanced` explicitly preserves

- Microsoft Store, Store Purchase App and Desktop App Installer;
- an existing winget installation and Store/MSIX licensing/deployment services;
- VCLibs, UI.Xaml, .NET Native and Windows App Runtime frameworks;
- WebView2 and Edge Update components required by ordinary applications;
- Hyper-V, WSL, containers, networking and Windows Update servicing;
- Notepad, the basic photo viewer, language-basic resources and required network capabilities;
- Windows Script Host/VBScript for the hidden setup launcher.

`-Keep` overrides a preset for a named group:

```text
Defender, WinRE, Edge, Fonts, Speech, WMP, IE, Sandbox, AI,
Apps, Family, ToDo, OneDrive, NativeImages
```

Examples: `-Keep Edge,Defender`, `-Keep Family,ToDo`, or `-Keep Apps`. `Apps` also protects Family and To Do. `Sandbox` is accepted as a compatibility selector; the current removal tables do not target Windows Sandbox.

> [!CAUTION]
> `balanced` removes Microsoft Defender, SmartScreen policy protection and the Windows Security application. Use `safe` or `-Keep Defender` if this machine should retain the built-in antivirus.

---

## OOBE, updates and the hidden launcher

By default, the builder prevents Windows Setup from downloading updates during OOBE:

1. During the `specialize` pass it creates a temporary outbound firewall block, records enabled adapters and disables only those adapters.
2. `SetupComplete` repeats detection for adapters that appeared late.
3. At first sign-in a finalizer waits for the native `OOBEComplete` signal.
4. It restores only the adapters changed by the builder, removes its own firewall rule and temporary Windows Update/OOBE policies, then performs the final Edge cleanup.

Use `-NoOobeNetworkBlock` to leave networking available during OOBE.

To avoid the brief black PowerShell window that Windows Setup can show, every preset preserves VBScript and uses a generated text file, `Run-Setup.vbs`, when `wscript.exe` and `vbscript.dll` exist in the image. WScript creates the first PowerShell process hidden, waits for its result and propagates the exit code. No custom EXE is compiled or embedded. If the source image lacks the host or engine, the builder reports the fallback to direct PowerShell, where an initial console may appear.

VBS and PowerShell write to the same daily `Logs\YYYY-MM-DD.log`, tagged `vbs-launcher` and `launcher`. The new launcher has passed real WScript fixture tests; appearance and antivirus behavior during a complete VM installation still require verification.

---

## Updates, winget and offline preparation

All selected downloads are prepared before the working directory is wiped, the ISO is copied, or a WIM is mounted:

- Windows LCU and required checkpoint packages;
- the .NET Framework cumulative update;
- Windows language packs and any LCU required to repair their resources;
- WinPE/Setup language packages and a compatible boot-image LCU;
- winget bundle, license and dependencies;
- DISM/oscdimg tools required for newer image branches.

After this preparation succeeds, the remainder of the build requires no network access. Incomplete `.part` files are not accepted. Cached sets are checked by size and SHA-256 and survive build cancellation. If an optional download fails, the interactive builder identifies the component and lets the user skip it or cancel; non-interactive builds cancel rather than silently producing a different image.

`-WithUpdates` selects online discovery/download. `-UpdateMode local` consumes MSU files already placed in `-UpdatesDir`; use `-LcuFile` and `-DotNetUpdateFile` when the directory contains multiple candidates. `-ResetBase` is opt-in because it makes installed updates permanently non-removable.

If App Installer/winget already exists in the selected edition, the wizard keeps it and skips the download question. `-WithWinget` integrates a newer package; it is not required to preserve the source version.

---

## Windows and Setup languages

The Windows display language and the Setup/WinPE language are separate choices.

| Command | Result |
| --- | --- |
| `-DownloadLanguage ru-RU` | Download and add Russian; the first requested language becomes the Windows default. |
| `-AddLanguage ru-RU -LanguageSource <path>` | Add packages from a local Languages and Optional Features source. |
| `-SetupLanguage auto` | Make Setup follow the first prepared Windows language; this is the default. |
| `-SetupLanguage original` | Keep the source Setup language. |
| `-SetupLanguage de-DE` | Select Setup language independently. |
| `-SetupLanguageSource <WinPE_OCs>` | Use local WinPE language CABs. |
| `-LanguageUpdatePath <LCU.msu>` | Reapply a compatible LCU after adding Windows languages. |
| `-SetupLanguageUpdatePath <LCU.msu>` | Repair an updated `boot.wim` after adding its language. |

Automatic WinPE language preparation currently supports build 26100 amd64. Other builds need a compatible local source unless the source `boot.wim` already has the desired language. For 26100.1742 media, automatic language addition also prepares the original KB5043080 LCU.

The script reads the package layout from pinned Microsoft ADK installers instead of carrying a generated package catalog. It extracts only the requested language and font packages.

---

## Accounts and answer files

For every supported Windows edition, `-AccountMode auto` offers:

1. create/configure the user during Windows Setup — the default;
2. enter a local account now and place it in the generated answer file.

For non-interactive builds use `-AccountMode setup`, or supply `-LocalUserName` (and optionally a SecureString `-LocalUserPassword`) to select image-time account creation. No automatic logon is configured. A password embedded in an answer file is recoverable; Windows answer-file encoding is not encryption.

`-Unattend <file>` gives control to a custom answer file. `-Unattend none` prevents the builder from adding one. With a custom/disabled answer file, the user is responsible for OOBE, account and first-logon behavior.

Hardware requirement bypasses for TPM, Secure Boot, CPU, RAM and storage are included by default. Use `-NoBypass` to omit them. The builder also prevents automatic device encryption and disables reserved storage for new installations.

---

## Image size options

| Option | Effect |
| --- | --- |
| `-Compression recovery` | Export `install.esd` with solid LZMS compression; smallest default output. |
| `-Compression max` | Export `install.wim` with maximum WIM compression; generally faster to install but larger. |
| `-CompactOS` | Request CompactOS/LZX for the installed system; saves installed disk space at a CPU cost. |
| `-LegacySetup` | Boot the classic Setup path through `winpeshl.ini`. |
| `-TrimSources` | Keep only files needed for boot installation; running `setup.exe` from an existing Windows installation is no longer supported. Requires classic Setup. |
| `-RemoveWinRE` | Remove `Windows\System32\Recovery\Winre.wim`; requires classic Setup unless protected with `-Keep WinRE`. |
| `-SaveWinRE` | Copy the removed recovery image beside the output ISO as `*_winre.wim`. It is not stored inside the ISO. |

WinRE is the installed Windows Recovery Environment. It is different from WinPE in `boot.wim`, which continues to boot and run Windows Setup.

---

## Requirements and supported images

- Windows host with Windows PowerShell 5.1 or PowerShell 7;
- administrator rights for a real build (requested automatically);
- an original Windows 11 x64 ISO;
- about 30 GB free space, or about 45 GB with current updates;
- Windows ADK Deployment Tools, or network/cache access that lets the script prepare compatible tools;
- internet only for selected items that are not already cached.

Before preparing downloads or work files, the builder requires at least **30 GB free on the work drive, or 45 GB with updates**. If the selected location has insufficient or unmeasurable free space, it asks for another work directory and repeats validation until a suitable path is entered. Without interactive input, the build stops with an error; pass a different `-WorkDir`. `-DryRun` can still display the plan. Automatic drive selection applies only when no work path was explicitly chosen and selects a disk meeting the full requirement.

Recognized Windows 11 branches:

| Build | Release label |
| ---: | --- |
| 22000 | 21H2 |
| 22621 | 22H2 |
| 22631 | 23H2 |
| 26100 | 24H2 |
| 26200 | 25H2 |
| 28000 | 26H1 |

Unknown branches stop instead of borrowing updates or servicing tools from another release. For build 28000, the builder can prepare pinned x64 DISM 10.0.28000.1 and oscdimg files from Microsoft ADK packages without replacing the installed ADK. See the [26H1 Home/Pro and Store/MSIX compatibility audit](COMPATIBILITY.md).

---

## Command-line reference

The table covers every user-facing parameter. Run `Get-Help .\win-11-lite.ps1 -Full` for the embedded help.

### Source, output and removal selection

| Parameter | Purpose |
| --- | --- |
| `-InputIso <file>` | Source Windows ISO. The wizard can discover nearby ISO files. |
| `-OutputIso <file>` | Output ISO path. Defaults to `out\<source>_lite.iso`. |
| `-Index <n>` | Source WIM/ESD index. Required when the source contains multiple editions unless `-Edition` is used. |
| `-Edition <EditionID>` | Select by EditionID, for example `Professional` or `IoTEnterpriseS`. |
| `-Preset safe|balanced|max` | Removal depth; default `balanced`. |
| `-Keep <groups[]>` | Preserve selected groups against the preset. |
| `-RemoveExtra <regex[]>` | Additional capability/package identity regular expressions. Advanced and potentially destructive. |
| `-WorkDir <directory>` | Working directory. Insufficient space requires a replacement path in the dialog or stops a non-interactive build. The builder only wipes a directory bearing its ownership marker. |
| `-UpdatesDir <directory>` | Persistent download/update cache. |

### Updates, languages and packages

| Parameter | Purpose |
| --- | --- |
| `-WithUpdates` | Discover and integrate current Windows/.NET updates. |
| `-UpdateMode none|download|local` | Update source; `WithUpdates` changes `none` to `download`. |
| `-IncludeDotNetUpdate <bool>` | Include the .NET cumulative update; default `true` when updates are selected. |
| `-LcuFile <name>` | Explicit target LCU filename in a local cache. |
| `-DotNetUpdateFile <name>` | Explicit target .NET update filename. |
| `-WithWinget` | Download and integrate a winget/App Installer package. Existing source winget is preserved without it. |
| `-AddLanguage <tags[]>` | Languages to add from `LanguageSource`. |
| `-LanguageSource <path>` | Local LoF/CAB directory or image. |
| `-DownloadLanguage <tags[]>` | Download Windows language packages. |
| `-SetupLanguage <tag|auto|original>` | Select the Setup language independently. |
| `-SetupLanguageSource <path>` | Local WinPE language source. |
| `-LanguageUpdatePath <MSU>` | Compatible LCU to reapply after Windows language addition. |
| `-SetupLanguageUpdatePath <MSU>` | Compatible LCU for localized `boot.wim`. |
| `-DriversDir <directory>` | Recursively integrate drivers with DISM. |
| `-ClearCache` | Clear only a cache marked as owned by this builder before preparation. |

### Setup, accounts and behavior

| Parameter | Purpose |
| --- | --- |
| `-Guard None|Standard|Debug|Silent` | Disable Guard or select its report mode. CLI default `None`; wizard default `Standard`. |
| `-NoBypass` | Do not add TPM/Secure Boot/CPU/RAM/storage bypasses. |
| `-NoOobeNetworkBlock` | Keep networking available during OOBE. |
| `-LegacySetup` | Use classic Windows Setup. |
| `-RemoveWinRE` | Remove the installed recovery image. |
| `-SaveWinRE` | Save a copy of the removed `winre.wim` beside the ISO. |
| `-TrimSources` | Remove setup files not required for boot installation. |
| `-CompactOS` | Install Windows in CompactOS mode. |
| `-Compression recovery|max` | Choose `install.esd` or `install.wim`; default `recovery`. |
| `-ResetBase` | Make integrated updates non-removable. |
| `-ProductKey <key>` | Product key for the generated answer file. |
| `-AccountMode auto|image|setup` | Choose where the local user is configured. |
| `-LocalUserName <name>` | Local administrator name for answer-file creation. |
| `-LocalUserPassword <SecureString>` | Optional local-user password. |
| `-Unattend <file|none>` | Supply a custom answer file or disable generated `autounattend.xml`. |

### Tools, diagnostics and automation

| Parameter | Purpose |
| --- | --- |
| `-InstallAdk` | Install ADK Deployment Tools when a compatible installation is missing. |
| `-DismPath <file>` | Use an explicit compatible `dism.exe`. |
| `-SkipIso` | Stop with the prepared distribution instead of running oscdimg; preserves the working directory. |
| `-KeepWorkDir` | Keep build files after completion or failure. |
| `-LogFile <file>` | Explicit main transcript path; also enables details and DISM logs. |
| `-Debug` | Enable the three builder log files without filling the console with verbose command lines. |
| `-DryRun` | Read metadata and print the plan without modification or elevation. |
| `-Interactive` | Force the wizard (`-Wizard` alias). |
| `-UILang auto|ru|en` | Builder message language, independent of image language. |
| `-NoPause` | Do not wait for a key before an interactive/elevated process exits. |

`-Elevated` is an internal forwarding flag set by the builder when it restarts itself as administrator; do not pass it manually.

---

## Firefox shortcut

The builder reports the Firefox download language when generating the shortcut, after Windows language integration is complete.

The finished Windows image contains `Install-Firefox.cmd` on the Public Desktop. At run time it:

1. tries winget from the `winget` source only, avoiding a broken `msstore` source;
2. selects a package matching the Windows image language (`Mozilla.Firefox.ru` for ru-RU, the base `Mozilla.Firefox` for en-US, and localized IDs for other mapped languages);
3. falls back to Mozilla's direct `firefox-latest` URL with the same language;
4. deletes the one-time installer shortcut only after success.

The shortcut remains after download failure or installer cancellation so it can be retried.

---

## Output, logs and audit data

| File | Purpose |
| --- | --- |
| `*_lite.iso` | Bootable result. |
| `*_lite.sha256` | SHA-256 checksum. |
| `*_lite.image-audit.json` | Component-store measurements, removal failures and targets still reported by DISM. |
| `*_lite_winre.wim` | Optional saved WinRE copy. |
| `win11-lite-build.json` in the ISO root | Build ID, source/output, preset, Keep list, language, update and Guard choices. |

Builder logging creates a main `.log`, a `.details.log` for commands/technical diagnostics, and a `.dism.log`. DISM can show more than one 0–100% internal phase; `100% — done` is displayed only after a successful process exit.

Every builder progress bar switches to a moving `...` indicator after five minutes without a changed percentage, while the elapsed timer keeps running. A new value automatically restores the percentage bar; this can repeat during the same operation. The rule applies to DISM operations, file copying and ISO creation. A reported 100% while the process is still running continues to show the existing completion-wait indicator.

Guest runtime files live under `C:\Windows\Setup\Scripts\Win11Lite`. For VM diagnostics, use the relevant daily files under `Logs` and the latest `guard-report.txt/json`. Entries identify `prepare`, `finalize`, `launcher`, `vbs-launcher` or a Guard run ID. Host build logs cannot show what happened after Windows booted.

---

## Validation status

As of 2026-09-14, 13 suites contain **1,181 checks on Windows PowerShell 5.1 and another 1,181 on PowerShell 7**. They cover parsers, safe paths, work-drive capacity and retry prompts, downloads/cache, WIM metadata, ADK catalogs, languages, answer files, Appx/removal rules, Guard reports/history, daily log retention and midnight rollover, OOBE networking, real child processes, progress stalls and recovery, Windows batch files and the WScript launcher.

Tests that exercise Guard, OOBE, registry, services or servicing replace system APIs with controlled fixtures. They are not presented as a real VM result. Real builds and prior VM logs confirm substantial parts of the 24H2/26H1 flow; the newest VBS launcher, localized winget Firefox installation and current `max` exception still need a fresh VM installation.

Run the complete test set sequentially:

```powershell
$suites = 'Test-SingleFile', 'Test-Win11Lite', 'Test-WindowsBatch', 'Test-WingetDetection', 'Test-Guard', 'Test-GuardModes', 'Test-GuestLogs', 'Test-Downloads', 'Test-SetupLanguage', 'Test-OobeNetwork', 'Test-SetupLauncher', 'Test-Compatibility', 'Test-Servicing'
foreach ($suite in $suites) {
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\tests\$suite.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Failed: $suite" }
}
```

Replace `powershell.exe` with `pwsh.exe` for PowerShell 7. Run Guard suites sequentially.

See [CHANGELOG.md](CHANGELOG.md) for implementation history and [COMPATIBILITY.md](COMPATIBILITY.md) for the detailed 26H1 Home/Pro, Store/MSIX and servicing audit.

ISO files, downloaded Microsoft packages, build output, logs and local research material are excluded from Git.
