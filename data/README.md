# WinPE language download catalog

Keep this directory next to `win-11-lite.ps1`. `winpe-26100.json` maps the files in Microsoft's WinPE add-on to the x64 language CABs required by the builder. It contains filenames and integrity metadata, not redistributed Microsoft binaries.

The catalog was extracted on 2026-09-12 from the Windows PE add-on for ADK **10.1.26100.2454**, linked by Microsoft's [ADK download page](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install):

- Bootstrapper: `https://go.microsoft.com/fwlink/?linkid=2289981` (`adkwinpesetup.exe`). Authenticode signature: **Valid**, Microsoft Corporation.
- Resolved directory: `https://download.microsoft.com/download/5/5/6/556e01ec-9d78-417d-b1e1-d83a2eff20bc/ADKWinPEAddons/`.
- MSI: `Installers/Windows PE Optional Packages (DesktopEditions)-x86_en-us.msi`. The x86 in this installer filename does not describe its payload architecture: this MSI carries both amd64 and arm64 packages. Only the `amd64/WinPE_OCs` entries are included here.
- MSI SHA256: `F286C52FDF694C85F08F6EC0BA7702DE84F891040064B81163C8DA59A5C4DB4C`.
- MSI SHA1: `E9BFF116C9A65FECD7125112D8B20C9BA3001327`, matched against the signed bootstrapper's Burn manifest.

File paths and cabinet members are derived from MSI `Directory`, `Component`, `File` and `Media` tables. Archive sizes and SHA1 values come from the signed bootstrapper's payload manifest. The 320,140,822-byte language archive was downloaded and its hash verified; Russian CABs were extracted and their `update.mum` identities checked against amd64, ru-RU and Windows build 26100.

The catalog includes 37 languages (24 localized optional CABs each) and six font CABs. The language archive is shared by all languages; selecting Russian does not install the other languages. Fonts are downloaded only when the chosen language requires them.

On use, the builder verifies the archive hash, copies the selected language files, checks required package identities and writes a SHA256 cache manifest. Subsequent builds can reuse the prepared set without contacting Microsoft. Other WinPE builds require matching local files via `-SetupLanguageSource`.

`WinPE-LegacySetup` is an optional compatibility component; it is not required merely because Windows Setup is launched with `/legacy`. The source LTSC 26100.1742 boot image does not contain this component. The builder adds language satellites only for WinPE components actually present in the image. The regular WinPE Setup packages provide the modern and classic installer resources.
