[English](/README.md) | [Русский](/README.ru_RU.md)

# win-11-lite

[![Windows 11 x64](https://img.shields.io/badge/Windows%2011-x64-0078D4.svg)](#requirements-and-supported-images)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE.svg)](#requirements-and-supported-images)
[![Tests](https://img.shields.io/badge/tests-1516-success.svg)](#validation-status)

**win-11-lite** builds a smaller, privacy-focused Windows 11 installation ISO from an original Microsoft x64 image. Windows 10 images based on build 19041 (2004–22H2, including LTSC 2021) are also supported, with [some differences](#windows-10). It removes selected inbox applications and components, applies privacy and OOBE settings, can integrate updates, languages and drivers, and exports one chosen Windows edition into a new bootable ISO.

The builder is a single PowerShell file. Download [`win-11-lite.ps1`](win-11-lite.ps1); no `data`, `tools`, generator, custom executable, Git, or GitHub CLI is required at runtime.

> [!WARNING]
> This project deliberately removes Windows components. The default `balanced` preset removes Microsoft Defender, Windows Security, Recall and other AI components, speech/OCR features, Media Player, Xbox/Game Bar and selected consumer apps. Review the plan with `-DryRun` and test the resulting ISO in a VM before using it on a real machine.

## Quick Start

Download the one required file:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/coinman-dev/win-11-lite/main/win-11-lite.ps1 -OutFile .\win-11-lite.ps1
.\win-11-lite.ps1
```

Running without parameters opens the interactive wizard. It finds nearby ISO files, asks which edition and preset to use, and requests administrator rights when the build starts. Instead of a file you can enter a folder, for example `F:\OS\Windows\`: the wizard lists the ISO files in it and lets you pick one by number. The same happens when `-InputIso` points to a folder; without interactive input, a folder or a non-ISO file stops the build with a clear message.

If the selected ISO is locked by another process, inaccessible or contains no readable Windows image, the wizard stops immediately with the ISO path and the original error. It does not ask for a work folder or continue to later steps.

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

> [!IMPORTANT]
> Antivirus software may block Guard as a threat. Guard runs hidden as `SYSTEM` and disables Windows security services and policies, which behavior analysis treats like malware that disables protection (for example, Avast reports `IDP.HEUR`). Do not quarantine the file: the same `Win11Lite.ps1` also performs preparation and finalization. Add `C:\Windows\Setup\Scripts\Win11Lite\Win11Lite.ps1` to your antivirus exclusions instead. Only `SYSTEM`, Administrators and TrustedInstaller can modify it. The builder repeats this warning in the build plan and in the final summary whenever Guard is enabled.

If the report window opens and closes within a second while the report files are still being written, check `%TEMP%` for the signed-in user. Some third-party installers rewrite `HKCU\Environment` and drop its `TEMP` and `TMP` values; the session then inherits `C:\Windows\TEMP`, which standard users may write to but not enumerate, so the OOBE state check cannot compile its helper and the window closes without output. The daily log now records the reason. Restore the Windows defaults without elevation:

```powershell
reg.exe add "HKCU\Environment" /v TEMP /t REG_EXPAND_SZ /d "%USERPROFILE%\AppData\Local\Temp" /f
reg.exe add "HKCU\Environment" /v TMP  /t REG_EXPAND_SZ /d "%USERPROFILE%\AppData\Local\Temp" /f
```

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
| `balanced` | Default lite desktop | Adds Defender/Windows Security removal, speech/handwriting/OCR/Text-to-Speech, Recall/Copilot/AI components, classic and modern Media Player, IE stub, classic Paint, Steps Recorder, diagnostics, CJK fonts/IME where safe, OneDrive installers, NGEN cache, Xbox/Game Bar, Family, To Do and selected consumer apps. Keeps Store/MSIX, App Installer/winget, WebView2, servicing, Hyper-V and WSL (removed only with `-RemoveVirtualization`). |
| `max` | Deliberately aggressive image reduction | Adds WebView2/Edge Update, component backups, PowerShell ISE, WMIC, Hello Face, formula recognition, fax/scan and extra FoD removal, and the virtualization features with their files: Hyper-V with Hyper-V Manager, WSL and Virtual Machine Platform, Windows Hypervisor Platform, Windows Sandbox and containers (keep them with `-Keep Virtualization`). Application compatibility and future servicing may break. VBScript remains as an explicit dependency of the hidden setup launcher. |

For `balanced` and `max`, the wizard asks separately whether to remove the built-in antivirus (Microsoft Defender and Windows Security). The default is yes, with a warning to remove it only if another antivirus will be installed, because otherwise Windows is left without malware protection. Answering no is the same as `-Keep Defender`: Defender, its services and policies stay, and Guard does not touch them.

The wizard then asks whether to remove the virtualization features: Hyper-V with Hyper-V Manager, WSL2 and the Virtual Machine Platform, Windows Hypervisor Platform, Windows Sandbox and containers. The default is no, except in `max`, where it is yes. The warning says to remove them only if you will not use virtualization, because WSL, Docker Desktop, Hyper-V virtual machines and Sandbox stop working and cannot be enabled again without the source image. Yes in `safe` or `balanced` is `-RemoveVirtualization`; no in `max` is `-Keep Virtualization`. The features are removed with `DISM /Disable-Feature /Remove`. The Hyper-V guest integration services that let this Windows run inside a VM belong to the core system and stay. The hypervisor used by virtualization-based security also belongs to the core system: Windows Home has no Hyper-V features and still runs VBS. Guard does not monitor these features.

On Windows 11, widgets are disabled by the documented `Allow widgets` policy (`SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests=0`). Since the September 2026 update, the host's User Choice Protection Driver (UCPD) denies `reg.exe` and PowerShell writes to this value even in a mounted image hive, so the build puts it in the image's local Group Policy (`Windows\System32\GroupPolicy\Machine\Registry.pol` and `gpt.ini`). The Group Policy service applies it in the installed Windows and restores it if it is removed, so Guard does not monitor it. The policy is visible and can be changed in `gpedit.msc` under Computer Configuration > Administrative Templates > Windows Components > Widgets. Windows 10 does not have this policy, so it is not written there.

Selected consumer Appx targets include Clipchamp, Bing News/Weather, Get Help/Get Started, Office Hub, Solitaire, Feedback Hub, Phone Link, new Outlook, Teams, Xbox/Game Bar, Family and Microsoft To Do. Exact matches depend on what the source image contains.

The capability-removal stage reports the total inventory separately from the capabilities selected for removal and retained by the build rules. Its final summary counts successful removals, failures and operations deferred because servicing is pending. A DISM removal error is recorded and processing continues with the next selected capability.

### What `balanced` explicitly preserves

- Microsoft Store, Store Purchase App and Desktop App Installer;
- an existing winget installation and Store/MSIX licensing/deployment services;
- VCLibs, UI.Xaml, .NET Native and Windows App Runtime frameworks;
- WebView2 and Edge Update components required by ordinary applications;
- Hyper-V, WSL, containers (unless `-RemoveVirtualization`), networking and Windows Update servicing;
- Notepad, the basic photo viewer, language-basic resources and required network capabilities;
- Windows Script Host/VBScript for the hidden setup launcher.

`-Keep` overrides a preset for a named group:

```text
Defender, WinRE, Edge, Fonts, Speech, WMP, IE, Sandbox, AI,
Apps, Family, ToDo, OneDrive, NativeImages, Virtualization
```

Examples: `-Keep Edge,Defender`, `-Keep Family,ToDo`, or `-Keep Apps`. `Apps` also protects Family and To Do. `Sandbox` is accepted as a compatibility selector and has no effect: Windows Sandbox is removed only together with the other virtualization features, so keep it with `-Keep Virtualization`.

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

If a saved adapter has not appeared or its enabled state is unconfirmed, restoration state and the task are retained. The finalizer retries detection, uses an unambiguous PnPDeviceID match after a GUID change, and restores other adapters independently of a failure. Task Scheduler retries failed runs up to three times at one-minute intervals; later sign-ins can retry again. Unrelated disabled adapters keep their state.

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

For non-interactive builds use `-AccountMode setup`, or supply `-LocalUserName` (and optionally a SecureString `-LocalUserPassword`) to select image-time account creation. Without `-AutoInstall`, no automatic logon is configured. A password embedded in an answer file is recoverable; Windows answer-file encoding is not encryption.

`-Unattend <file>` gives control to a custom answer file. `-Unattend none` prevents the builder from adding one. With a custom/disabled answer file, the user is responsible for OOBE, account and first-logon behavior.

### Automatic installation (`-AutoInstall`)

`-AutoInstall` produces media that install Windows without a single question and then sign in automatically. The wizard asks for it right after the edition; the default is no.

```powershell
.\win-11-lite.ps1 -InputIso .\iso\ltsc.iso -Index 1 -AutoInstall -Guard Standard
```

> [!CAUTION]
> **Disk 0 is erased without confirmation.** Use it in VMs or on PCs where disk 0 is the system disk. When installing from USB, the flash drive itself may be disk 0.

- **Boot:** UEFI boots from the ISO without *Press any key* (`efisys_noprompt.bin`). The BIOS prompt appears only once a bootable disk exists, that is, after installation. Remove the ISO after installation if the firmware would boot it first again.
- **Disk:** `win11lite\disk.cmd` on the media reads `PEFirmwareType` in WinPE and wipes disk 0 with `diskpart`. UEFI gets GPT with a 300 MB ESP, a 16 MB MSR and the Windows partition; BIOS gets MBR with a 300 MB active *System Reserved* partition and the Windows partition. Setup then uses `InstallToAvailablePartition`, because the Windows partition number differs between the two layouts.
- **Account:** by default the built-in Administrator is enabled with a blank password and signs in automatically. The answer file uses the language-neutral name `Administrator`, as Microsoft documents, so this also works on localized images such as ru-RU, where the account is shown as *Администратор*. With `-LocalUserName` (and optionally `-LocalUserPassword`) that local administrator is created and signs in instead. Microsoft Store (UWP) apps do not start under the built-in Administrator by default; use `-LocalUserName` if you need them.
- **Keys:** Enterprise, Education and LTSC editions need no key. Home and Pro require `-ProductKey`, otherwise the build stops before any download, because Setup would ask for the key.
- **Conflicts:** `-AutoInstall` cannot be combined with `-Unattend` or `-AccountMode setup`.

The builder prints the disk warning in the build plan and again in the final summary. The answer file, the partitioning scripts and the actual command line were checked in tests, including the real `cmd.exe` with substituted `reg`/`diskpart`. A real unattended installation in a VM has not been performed yet.

Hardware requirement bypasses for TPM, Secure Boot, CPU, RAM and storage are included by default. Use `-NoBypass` to omit them. The builder also prevents automatic device encryption and disables reserved storage for new installations.

---

## Image size options

| Option | Effect |
| --- | --- |
| `-Compression recovery` | Export `install.esd` with solid LZMS compression; smallest default output. |
| `-Compression max` | Export `install.wim` with maximum WIM compression; generally faster to install but larger. |
| `-CompactOS` | Request CompactOS/LZX for the installed system; saves installed disk space at a CPU cost. |
| `-LegacySetup` | Boot the classic Setup path through `winpeshl.ini`. Windows 11 only; ignored for Windows 10, whose Setup is already classic. |
| `-TrimSources` | Keep only files needed for boot installation; running `setup.exe` from an existing Windows installation is no longer supported. Requires classic Setup on Windows 11. |
| `-RemoveWinRE` | Remove `Windows\System32\Recovery\Winre.wim`; on Windows 11 requires classic Setup unless protected with `-Keep WinRE`. |
| `-SaveWinRE` | Copy the removed recovery image beside the output ISO as `*_winre.wim`. It is not stored inside the ISO. |

WinRE is the installed Windows Recovery Environment. It is different from WinPE in `boot.wim`, which continues to boot and run Windows Setup.

`recovery` compression is memory-hungry: DISM compresses 64 MiB solid LZMS chunks on every logical processor. The builder assumes about 1 GB of commit memory (RAM plus page file) per logical processor; this estimate is derived from the wimlib author's figure of about 480 MiB per thread for 32 MiB chunks. It compares that with free commit plus the room the page file can still grow: up to its maximum, or, for a system-managed page file, up to 3 × RAM or 4 GB (whichever is larger), limited to one eighth of the volume and the free space. If memory is short, the numbers, the largest memory users (for example `vmmemWSL`, the WSL virtual machine; `wsl --shutdown` frees it) and the remedies are shown. For every preset, the wizard asks how to compress the final image: `recovery` (`install.esd`, best compression, the default) or `max` (`install.wim`, larger ISO). The memory need and any shortage warning appear right before that question, so the build does not ask again. The whole build runs at below-normal CPU priority by default (`-Priority`), so `recovery` compression uses all cores without slowing down other programs; memory and disk access are not deprioritized. A command-line build in an interactive console shows the warning in the plan and asks, before any image work, whether to keep `recovery` (default) after freeing memory, switch to `max` or cancel. DryRun and non-interactive builds only warn. Memory is checked again right before the export, and a DISM error 8 during `recovery` compression is reported as a memory shortage with the same advice.

### Memory files in installed Windows

New builds default to a **128–4096 MB paging file**, with `swapfile.sys`, hibernation/Fast Startup and crash dumps disabled. These choices are independent of the preset and ISO compression. The wizard offers separate choices, `-DryRun` displays the selections, and build metadata stores them in `MemoryFiles`.

| Parameter | Default and effect |
| --- | --- |
| `-PageFileMode custom|system` | `custom`: use the configured range; `system`: let Windows size the paging file. |
| `-PageFileMinMB <MB>` | `128`: initial size of `pagefile.sys`. |
| `-PageFileMaxMB <MB>` | `4096`: growth limit. For a fixed 128 MB file, use `-PageFileMaxMB 128`. |
| `-SwapFile disabled|system` | `disabled`: request disabling through `SwapfileControl=0`; `system`: remove the override and let Windows manage swap. |
| `-Hibernation disabled|system` | `disabled`: disable hibernation, Fast Startup and `hiberfil.sys`; `system`: keep source image settings. |
| `-CrashDumps disabled|system` | `disabled`: disable crash dumps (`MEMORY.DMP`/Minidump), full live dumps, DumpStack logging and dedicated dump file configuration; `system`: keep source settings. |

A small paging file limits the total memory available to apps. For memory-heavy workloads, increase `-PageFileMaxMB` or choose `-PageFileMode system`. Disabling hibernation also disables Fast Startup; disabling dumps removes that troubleshooting data. These options do not disable memory compression in RAM.

There is no documented supported setting to cap `swapfile.sys` at 16 MB: an observed size on one machine is not guaranteed on another. `SwapfileControl` is an undocumented override; its effect and Store/MSIX app compatibility need validation on the target Windows version. Use `-SwapFile system` for normal Windows management.

Settings are written to every ControlSet in the image SYSTEM hive and reapplied during setup preparation/finalization. Existing registry keys, unrelated values and child keys are preserved; failures report the full value path. Paging/swap and DumpStack changes may need a restart to finish resizing or removing files; the builder does not restart Windows automatically. After finalization, `C:\Windows\Setup\Scripts\Win11Lite\memory-files-report.json` records requested settings and observed sizes. It is a snapshot at finalization, not a promise of sizes after a restart. Guard does not reapply these settings at every logon.

VMDK size, ISO size and used space on C: are different measurements. Compare used space inside both Windows installations, including memory files. Identical sizes on different hardware are not guaranteed. See Microsoft's documentation on [paging](https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/how-to-determine-the-appropriate-page-file-size-for-64-bit-versions-of-windows), [powercfg](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options) and [full live dumps](https://learn.microsoft.com/en-us/windows/win32/wer/wer-settings).

---

## Requirements and supported images

- Windows host with Windows PowerShell 5.1 or PowerShell 7;
- administrator rights for a real build (requested automatically);
- an original Windows 11 x64 ISO, or a Windows 10 x64 ISO based on build 19041 (versions 2004–22H2, including LTSC 2021);
- about 30 GB free space, or about 45 GB with current updates;
- Windows ADK Deployment Tools, or network/cache access that lets the script prepare compatible tools. When the built-in DISM is new enough and only `oscdimg` is missing, the builder prepares `oscdimg` from pinned Microsoft ADK packages (about 8.6 MiB, archive SHA256, signature, cache) without installing the ADK; `-InstallAdk` still installs Deployment Tools instead;
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

### Windows 10

Windows 10 media for versions 2004–22H2 store the shared base build 19041 in the WIM metadata; the version is set by an enablement package. LTSC 2021 media, for example, report `10.0.19041.1288`.

| Build in the WIM | Edition | Release label for updates |
| ---: | --- | --- |
| 19041 | `EnterpriseS`, `IoTEnterpriseS` (LTSC 2021) | 21H2 |
| 19041 | other editions | 22H2 |
| 19044 | any | 21H2 |
| 19045 | any | 22H2 |

Older branches such as 17763 (LTSC 2019) are rejected. Differences from Windows 11:

- Windows 10 Setup is already the classic one. `-LegacySetup` is accepted and ignored, because `setup.exe /legacy` exists only in Windows 11. `-TrimSources` and `-RemoveWinRE` do not require it, and `boot.wim` is left unchanged.
- The TPM, Secure Boot, CPU, RAM and storage bypasses are Windows 11 checks and are not added.
- Languages are not added. `-AddLanguage`, `-DownloadLanguage`, and a `-SetupLanguage` different from the image language stop the build before any download. Use an ISO in the required language.
- `-WithUpdates` downloads the `Cumulative Update for Windows 10 Version 21H2/22H2 for x64-based Systems` (about 0.9 GB; the servicing stack is included) and, unless `-IncludeDotNetUpdate $false` is set, the `.NET Framework 3.5 and 4.8` update that matches the in-box .NET 4.8. Windows 10 updates use their own cache folders (`lcu-win10-21H2`), separate from Windows 11 21H2.
- The removal rules are the same as for Windows 11. In `balanced` this also removes Internet Explorer 11, which is still a working browser in Windows 10, and classic Paint, the only Paint in LTSC. Keep them with `-Keep IE` or `-Keep Misc`. Windows 10 has no Recall or Windows 11 AI components; the Copilot policies are still written.
- The widgets policy (`AllowNewsAndInterests`) exists only in Windows 11 and is not written.

A real Windows 10 LTSC 2021 ISO passed DryRun, and the update selection was checked against the live Microsoft Update Catalog. A real build reached the offline-registry stage, where the host's UCPD rejected the widgets policy; that is fixed, but the build has not been rerun yet. A full Windows 10 build and installation in a VM have not been performed yet.

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
| `-RemoveVirtualization` | Remove the virtualization features with their files in any preset: Hyper-V with Hyper-V Manager, WSL and Virtual Machine Platform, Windows Hypervisor Platform, Windows Sandbox, containers and Application Guard. `max` does this by default; keep them there with `-Keep Virtualization`. |
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
| `-LegacySetup` | Use classic Windows Setup (Windows 11). |
| `-RemoveWinRE` | Remove the installed recovery image. |
| `-SaveWinRE` | Save a copy of the removed `winre.wim` beside the ISO. |
| `-TrimSources` | Remove setup files not required for boot installation. |
| `-CompactOS` | Install Windows in CompactOS mode. |
| `-PageFileMode custom|system` | Use a custom paging range or Windows management; default custom. |
| `-PageFileMinMB <MB>` | Initial paging file size; default 128 MB. |
| `-PageFileMaxMB <MB>` | Maximum paging file size; default 4096 MB, at least the initial size. |
| `-SwapFile disabled|system` | Disable swap through an override or let Windows manage it; default disabled. |
| `-Hibernation disabled|system` | Disable hibernation/Fast Startup or keep source settings; default disabled. |
| `-CrashDumps disabled|system` | Disable crash/full live dumps and DumpStack or keep source settings; default disabled. |
| `-Compression recovery|max` | Choose `install.esd` or `install.wim`; default `recovery`. |
| `-Priority BelowNormal|Idle|Normal` | CPU priority for the build; default `BelowNormal`. DISM, robocopy and oscdimg inherit it, so other programs stay responsive. `Idle` uses only spare CPU time; `Normal` does not lower it. |
| `-ResetBase` | Make integrated updates non-removable. |
| `-ProductKey <key>` | Product key for the generated answer file. |
| `-AccountMode auto|image|setup` | Choose where the local user is configured. |
| `-LocalUserName <name>` | Local administrator name for answer-file creation. |
| `-LocalUserPassword <SecureString>` | Optional local-user password. |
| `-Unattend <file|none>` | Supply a custom answer file or disable generated `autounattend.xml`. |
| `-AutoInstall` | Install without any question and sign in automatically: **erases disk 0**, boots UEFI without *Press any key*, uses the built-in Administrator without a password unless `-LocalUserName` is given. Home/Pro need `-ProductKey`. |

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

Every builder progress bar switches to a moving `...` indicator after five minutes without a change in the displayed whole percentage, while the elapsed timer keeps running. Hidden changes such as 1.1% to 1.9%, both displayed as 1%, do not reset that interval. A new displayed value automatically restores the percentage bar; this can repeat during the same operation. The rule applies to DISM operations, file copying and ISO creation. A reported 100% while the process is still running continues to show the existing completion-wait indicator.

If a build is interrupted (for example with Ctrl+C during a DISM operation), cleanup discards the mounted image, and the work folder is kept if that fails. DISM loads the image registry hives as `HKLM\{GUID}<drive>:/.../mount/...`; an interrupted DISM leaves them loaded, and they keep the image locked (`0xc1420117`, "The directory could not be completely unmounted"). Cleanup and the next run unload such hives, but only those inside this build's own mount folders and only when no DISM process is running, then discard the leftover image. If the discard still fails, close Explorer windows and programs open in the work folder; as a last resort, run `dism /Cleanup-Mountpoints` as administrator.

Guest runtime files live under `C:\Windows\Setup\Scripts\Win11Lite`. For VM diagnostics, use the relevant daily files under `Logs` and the latest `guard-report.txt/json`. Entries identify `prepare`, `finalize`, `launcher`, `vbs-launcher` or a Guard run ID. Host build logs cannot show what happened after Windows booted.

---

## Validation status

As of 2026-09-27, 14 suites contain **1,516 checks**. The 1,292 checks present before the Guard report fix passed on each of Windows PowerShell 5.1 and PowerShell 7. The 224 checks added since then (12 for the Guard report window, 27 for Windows 10, 36 for `-AutoInstall`, 6 for the wizard antivirus question, 39 for virtualization removal, 12 for choosing an ISO and single-edition images, 6 for preparing `oscdimg` without the ADK, 10 for the widgets policy in local Group Policy, 19 for hives left by an interrupted DISM, 1 for the 128–4096 MB paging default, 43 for the `recovery` memory check and the wizard compression question, 13 for the build CPU priority) have run on Windows PowerShell 5.1 only, because PowerShell 7 is not installed on the machine used for them. All 14 suites passed there. They cover parsers, safe paths, work-drive capacity, downloads/cache, WIM/ADK, languages, answer files, removal rules, Guard reports/history, log retention, OOBE networking, memory files, child processes, progress, CMD and VBS. For the memory-file and network changes, eight affected suites passed: **646 checks on each PowerShell version**; other suites were not rerun. DryRun against a real ISO passed with RU/7 and EN/5.1. The ISO-read fix passed all 151 Servicing checks on each runtime, including a real file-sharing violation with mocked ISO APIs. The latest registry fix passed MemoryFiles 72 and SingleFile 45 on each runtime (117 checks), including actual registry operations and deletion-denying ACLs inside a disposable HKCU fixture. The capability-counter change passed all 246 Main checks on each runtime, including continuing after a removal error with mocked DISM.

Tests that exercise Guard, OOBE, registry, services or servicing use controlled fixtures for system operations. Registry preservation tests also use the real provider inside a disposable HKCU key, with HKLM paths redirected there. They are not presented as a real VM result. Real builds and prior VM logs confirm substantial parts of the 24H2/26H1 flow; current memory-file/network changes, the newest VBS launcher, localized winget Firefox installation and current `max` exception still need a fresh installation.

Run the complete test set sequentially:

```powershell
$suites = 'Test-SingleFile', 'Test-Win11Lite', 'Test-WindowsBatch', 'Test-WingetDetection', 'Test-Guard', 'Test-GuardModes', 'Test-GuestLogs', 'Test-Downloads', 'Test-SetupLanguage', 'Test-OobeNetwork', 'Test-SetupLauncher', 'Test-Compatibility', 'Test-Servicing', 'Test-MemoryFiles'
foreach ($suite in $suites) {
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\tests\$suite.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Failed: $suite" }
}
```

Replace `powershell.exe` with `pwsh.exe` for PowerShell 7. Run Guard suites sequentially.

See [CHANGELOG.md](CHANGELOG.md) for implementation history and [COMPATIBILITY.md](COMPATIBILITY.md) for the detailed 26H1 Home/Pro, Store/MSIX and servicing audit.

ISO files, downloaded Microsoft packages, build output, logs and local research material are excluded from Git.
