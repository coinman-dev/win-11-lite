# План работ: скрипт `win-11-lite.ps1`

> Актуализация 11.09.2026: этот документ содержит исторический план. Исправления Edge, языков, OOBE, безопасной очистки и уточнённая граница balanced/max описаны в [отчёте проверки 08](08-audit-2026-09-11.md). Практическая установка исправленной сборки ещё предстоит; старый ISO в out не заменён.

**Дата:** 10.09.2026
**Статус:** план утверждён к реализации, код ещё не написан
**Основание:** отчёты `01`, `02`, решения из `03`

---

## 0. Что получится на выходе

Из любого оригинального ISO Windows 11 скрипт делает облегчённый ISO:

- та же редакция и язык, что в исходнике (определяется автоматически);
- обновлён до последнего накопительного обновления из Microsoft Update Catalog (сегодня — 26100.9445);
- без Edge (WebView2 оставлен), без Defender, без WinRE, без CJK-шрифтов, речи/OCR, WMP, IE, телеметрии и рекламы;
- с Hyper-V, WSL, контейнерами, рабочим Windows Update, обслуживаемым хранилищем компонентов;
- с предустановленным winget и ярлыком `Install-Firefox` на рабочем столе;
- ставится без Secure Boot и TPM 2.0, с локальным аккаунтом;
- рядом с ISO — `*_winre.wim` (для восстановления среды WinRE при желании), `*.sha256`, лог сборки.

Ожидаемый размер: **~2.2–2.7 ГБ** против 4.79 ГБ у оригинала. Точная цифра — после первого прогона.

---

## 1. Подготовка (делается один раз, требует администратора)

### 1.1. Windows ADK — Deployment Tools

Зачем: `oscdimg.exe` (сборка ISO) и DISM 10.1.26100.x. Хостовый DISM 19041 для образов 26100 не годится, а поддержка checkpoint-обновлений 24H2 есть только в свежем DISM.

Страница загрузки: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install — брать **ADK для Windows 11, версия 24H2** (на момент проверки — 10.1.26100.2454). WinPE add-on **не нужен**.

Тихая установка только нужного компонента:
```powershell
.\adksetup.exe /quiet /norestart /features OptionId.DeploymentTools
```
Результат: `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\` с папками `DISM\` и `Oscdimg\`.

Скрипт в preflight сам ищет эти пути; если не находит — останавливается с точной инструкцией. Опционально: ключ `-InstallAdk` — скрипт скачает `adksetup.exe` и поставит Deployment Tools сам.

### 1.2. Место на диске

Пиковое потребление за прогон ~30 ГБ (копия ISO 5 + `install.wim` растёт до ~9 ГБ после LCU + обновления 5 + ESD 2 + scratch). Рекомендуемый минимум — **40 ГБ свободных** на диске рабочего каталога. На `E:` сейчас 114 ГБ.

### 1.3. Интернет

Нужен для: Update Catalog (~5 ГБ обновлений), GitHub (winget ~300 МБ). Всё проверено с этой машины — доступно.

---

## 2. Структура проекта

```
E:\win-11-lite\
├── win-11-lite.ps1            основной скрипт (самодостаточный, шаблоны встроены)
├── iso\                       исходные ISO
├── out\                       результаты: *.iso, *_winre.wim, *.sha256, *.log
├── tmp\work\                  рабочий каталог (создаётся и удаляется скриптом)
├── tmp\updates\               кэш скачанных .msu (НЕ удаляется — чтобы не качать 5 ГБ на каждый прогон)
└── .ai\                       отчёты и план
```

Кэш обновлений — единственное, что переживает прогон. Его можно удалить вручную или ключом `-ClearCache`.

---

## 3. Интерфейс командной строки (актуально на 10.09.2026)

```powershell
.\win-11-lite.ps1 -InputIso <путь> [-Index N | -Edition <EditionID>] [параметры]
```

Философия умолчаний: **ничего лишнего без явной команды** — ни загрузок из интернета, ни дополнительных компонентов в образе, ни файлов на диске.

| Параметр | Алиасы | По умолчанию | Назначение |
|---|---|---|---|
| **`-InputIso`** | `-Iso`, `-Source` | **обязателен** | Исходный ISO |
| **`-Index`** | | — | Какую редакцию брать. **Обязателен, если в образе их несколько**: скрипт покажет список и остановится с кодом 2 |
| `-Edition` | | — | То же, но по EditionID (`IoTEnterpriseS`, `EnterpriseS`) |
| `-OutputIso` | `-Out` | `out\<имя-исходника>_lite.iso` | Готовый ISO |
| `-WorkDir` | `-TmpDir`, `-Temp`, `-Work` | `%TEMP%\win-11-lite\work`; при нехватке места — диск с наибольшим свободным объёмом | Рабочий каталог; удаляется в конце |
| `-UpdatesDir` | `-Updates` | папка `updates` рядом с `-WorkDir` | Кэш `.msu`; между прогонами не удаляется |
| `-Preset` | | `balanced` | `safe` / `balanced` / `max` |
| `-Keep` | | — | Не трогать вопреки пресету: `Defender`, `WinRE`, `Edge`, `Fonts`, `Speech`, `WMP`, `IE`, `Sandbox`, `AI` |
| `-RemoveExtra` | | — | Дополнительные capability/пакеты к удалению (regex) |
| **`-WithUpdates`** | `-Update` | выкл. | Скачать и встроить последний LCU + checkpoint + .NET CU. Без флага образ остаётся на исходном билде (**−1.5 ГБ к ISO**) |
| `-UpdateMode` | | `none` | `download` / `local` / `none`. Вручную нужен только для `local` |
| `-IncludeDotNetUpdate` | | `$true` | Интегрировать CU для .NET 3.5/4.8.1 (при `-WithUpdates`) |
| **`-WithWinget`** | `-Winget` | выкл. | Встроить App Installer (~300 МБ загрузки с GitHub) |
| `-NoBypass` | | — | Не встраивать обход TPM / Secure Boot |
| `-Unattend` | | встроенный шаблон | Свой `autounattend.xml` (или `none`) |
| `-Compression` | | `recovery` | `recovery` (LZMS → `install.esd`) / `max` (LZX → `install.wim`) |
| `-DriversDir` | | — | Интеграция драйверов (рекурсивно) |
| `-SkipIso` | | — | Остановиться на готовом `install.esd`, ISO не собирать |
| `-KeepWorkDir` | | — | Не удалять рабочий каталог (отладка) |
| `-ClearCache` | | — | Удалить кэш обновлений перед стартом |
| `-InstallAdk` | | — | Поставить ADK Deployment Tools, если не найден |
| **`-Debug`** | | выкл. | Лог работы + лог DISM (`/LogLevel:4`) в папку скрипта: `<имя ISO>_<дата-время>.log` и `.dism.log` |
| `-LogFile` | | — | Свой путь к логу (пишется независимо от `-Debug`) |
| `-DryRun` | | — | Показать план и оценки, ничего не менять. Работает без прав администратора |

### Коды возврата

| Код | Значение |
|---|---|
| 0 | Успех |
| 1 | Ошибка выполнения |
| **2** | Нужно выбрать редакцию: в образе их несколько, а `-Index`/`-Edition` не задан |

### Примеры

```powershell
# минимальная сборка: без обновлений, без winget, без логов
.\win-11-lite.ps1 -InputIso .\iso\en-us_..._ltsc_2024_x64_dvd_f6b14814.iso -Index 2

# полный набор: свежие патчи, winget, лог для разбора
.\win-11-lite.ps1 -InputIso .\iso\ru-ru_..._f9af5773.iso -WithUpdates -WithWinget -Debug

# посмотреть, что будет сделано, не трогая ничего
.\win-11-lite.ps1 -InputIso .\iso\original.iso -DryRun
```

Скрипт проверяет права администратора и отказывается работать без них (кроме `-DryRun`).

---

## 4. Пайплайн — 16 стадий

Каждая стадия пишет в лог заголовок, время, результат. Ошибка на любой стадии → `finally` размонтирует всё с `/Discard`, чистит рабочий каталог (если не `-KeepWorkDir`) и печатает, на какой стадии упало.

### Стадия 0 — Preflight
- права администратора (кроме `-WhatIf`);
- поиск ADK: `Deployment Tools\amd64\DISM\dism.exe` и `Oscdimg\oscdimg.exe`. **Все операции с образами идут через `dism.exe` из ADK**, не через модуль PowerShell `Dism` (он тянет `DismApi.dll` хоста версии 19041). Смешивать версии DISM на одном смонтированном образе нельзя;
- свободное место ≥ 40 ГБ на диске `WorkDir`;
- при `download` — доступность `catalog.update.microsoft.com` и `api.github.com`;
- нет «висящих» точек монтирования: `dism /Get-MountedImageInfo`, при необходимости `dism /Cleanup-Mountpoints`.

### Стадия 1 — Распаковка ISO
`Mount-DiskImage -Access ReadOnly` → `robocopy /E /R:2 /W:2` в `WorkDir\iso` → `Dismount-DiskImage`. Запоминается метка тома (для `oscdimg`). Атрибут read-only с файлов снимается.

### Стадия 2 — Паспорт образа
`dism /Get-ImageInfo /ImageFile:WorkDir\iso\sources\install.wim` (или `.esd`) — список индексов, EditionID, язык, билд. Выбор индекса по правилу из §3. Из билда определяется маркетинговое имя для поиска в каталоге: `26100 → 24H2`, `26200 → 25H2`, `22631 → 23H2`, `22621 → 22H2`. Если `install.esd` — сначала экспорт в WIM.

Язык образа (`DEFAULT` из XML) сохраняется — нужен для `Install-Firefox`.

### Стадия 3 — Экспорт выбранного индекса
`dism /Export-Image /SourceImageFile:... /SourceIndex:N /DestinationImageFile:WorkDir\install.wim /Compress:max /CheckIntegrity` — получаем одноиндексный WIM, дальше работаем только с ним. Оригинальная копия в `WorkDir\iso\sources\` удаляется (место).

### Стадия 4 — Загрузка обновлений (`UpdateMode = download`)
Три запроса к каталогу (проверены вживую 10.09.2026, парсинг HTML без внешних модулей):

1. **LCU**: поиск `Cumulative Update for Windows 11, version <24H2> for <x64>-based Systems` → отбросить строки с `Dynamic Update` и `Preview` → взять самую свежую по дате. `DownloadDialog.aspx` возвращает **два** `.msu`: сам LCU и checkpoint (сегодня `kb5043080` + `kb5124008`). Оба — в `UpdatesDir\lcu\`.
2. **.NET CU** (если `-IncludeDotNetUpdate`): `Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version <24H2> for <x64>` → без `Preview` → самая свежая → `UpdatesDir\dotnet\`. Сегодня KB5126052.
3. SSU отдельно **не нужен** — с Windows 11 он встроен в LCU.

Файлы кладутся в **раздельные папки** — это требование DISM для checkpoint-механизма: в папке с целевым LCU должны лежать только он и его чекпоинты, ничего постороннего.

Кэш: если файл с таким именем уже есть и размер совпадает — не качаем. `UpdateMode = local` — берём всё из `UpdatesDir` как есть (структура папок та же). `none` — стадии 4 и 6 пропускаются.

### Стадия 5 — Монтирование
`dism /Mount-Image /ImageFile:WorkDir\install.wim /Index:1 /MountDir:WorkDir\mount`.

### Стадия 6 — Интеграция обновлений
```
dism /Image:mount /Add-Package /PackagePath:UpdatesDir\lcu\<lcu>.msu     ← чекпоинт подхватится сам из той же папки
dism /Image:mount /Add-Package /PackagePath:UpdatesDir\dotnet\<net>.msu
```
Самая долгая стадия: 30–60 минут, `install.wim` вырастает до ~9 ГБ. После неё билд образа = 26100.9445.

**Порядок принципиален: сначала обновления, потом удаления.** LCU может принести обратно то, что мы вырежем (в частности, Edge и компоненты Defender), поэтому режем уже обновлённый образ.

### Стадия 7 — Сохранение WinRE
`copy mount\Windows\System32\Recovery\Winre.wim → out\<имя>_winre.wim`, затем файл из образа удаляется (`ReAgent.xml` остаётся).

**Поправка к сказанному ранее:** LCU **не обновляет** `Winre.wim` внутри `install.wim` (для WinRE есть отдельный Safe OS Dynamic Update). Сохранённый файл будет версии 26100.1742 — исходной. С `reagentc /setreimage` он всё равно работает; при желании его можно обновить Safe OS DU отдельно, но в план это не входит.

### Стадия 8 — Удаление: capabilities (самый чистый способ)
`dism /Image:mount /Get-Capabilities` → фильтр по regex → `dism /Remove-Capability /CapabilityName:...`. Имена **без привязки к языку** — для ru-RU образа это будут `~~~ru-RU~`, для en-US — `~~~en-US~`, regex ловит оба.

| Пресет | Regex по имени capability | Что это |
|---|---|---|
| balanced | `^Language\.(Handwriting\|OCR\|Speech\|TextToSpeech)~` | Рукописный ввод, OCR, распознавание и синтез речи |
| balanced | `^Media\.WindowsMediaPlayer~` | Windows Media Player |
| balanced | `^Microsoft\.Windows\.MSPaint~` | Классический Paint |
| balanced | `^App\.StepsRecorder~` | Steps Recorder |
| balanced | `^Browser\.InternetExplorer~` | IE11 (в 24H2 это заглушка) |
| balanced | `^Microsoft\.Windows\.Sense\.Client~` | Defender for Endpoint (159 МБ) |
| max | `^Hello\.Face\.` | Windows Hello Face |
| max | `^MathRecognizer~` | Распознавание формул |
| max | `^Print\.Fax\.Scan~` | Факс и сканирование |
| max | `^Microsoft\.Windows\.PowerShell\.ISE~` | PowerShell ISE |

**Не трогаем никогда:** `Language.Basic` (шрифты/раскладки языка), `LanguageFeatures-WordBreaking` (поиск), `Microsoft.Windows.Notepad.System`, `OpenSSH.Client`, `Windows.Client.ShellComponents`, `Microsoft.Windows.Ethernet/Wifi.Client.*` (сетевые драйверы), `DirectX.Configuration.Database`.

### Стадия 9 — Удаление: CBS-пакеты
`dism /Get-Packages /Format:Table` → фильтр → `dism /Remove-Package /PackageName:...`. Имена взяты из фактического состава образа (отчёт 02, §4; проверено 10.09.2026):

| Пресет | Regex по имени пакета | Что это | МБ |
|---|---|---|---:|
| balanced | `^Microsoft-OneCore-Fonts-DesktopFonts-Supplement-(Hans\|Hant\|Jpan\|Kore)-Package` | CJK-шрифты | 252 |
| balanced | `^Windows-Defender-AM-Default-Definitions(-OptionalWrapper)?-Package` | Сигнатуры Defender | 144 |
| balanced | `^Windows-Defender-ApplicationGuard-Inbox(-WOW64)?-Package` | Application Guard | |
| balanced | `^Windows-Defender-Group-Policy-Package` | Шаблоны политик Defender | |
| balanced | `^Microsoft-Windows-SenseClient(-FoD)?-Package` | ATP (если не ушёл с capability) | |
| balanced | `^Microsoft-Windows-MicrosoftEdgeDevToolsClient-Package` | Edge DevTools | |
| balanced | `^Microsoft-Windows-WinOcr-` | OCR-движок | |
| balanced | `^Microsoft-Windows-(MediaPlayer\|Media-Player\|WMPNetworkSharingService\|WindowsMediaPlayer-Troubleshooters\|Multimedia-WMPDMC)-` | Хвосты WMP | |
| max | `^Microsoft-Windows-Printing-(XPSServices\|XpsDocumentWriter-Opt)-Package` | XPS | |
| max | `^Microsoft-Windows-Embedded-` | UWF, Shell Launcher, Keyboard Filter | |
| max | `^Microsoft-Windows-(Telnet\|TFTP\|SimpleTCP\|PeerDist\|OfflineFiles)-` | Легаси-сеть | ~0 |
| max | `^Microsoft-Windows-IIS-\|^Microsoft-Windows-DirectoryServices-` | IIS, AD-инструменты | 11 |
| max | `^Containers-\|^HyperV-\|^Microsoft-Hyper-V-\|^Microsoft-Windows-Lxss-` | Виртуализация | 98 |

**Оставляем `Microsoft-Windows-PhotoBasic-*`** (Windows Photo Viewer): в LTSC нет приложения «Фотографии», это единственный просмотрщик картинок. Full.Fast тоже его оставил.

**Не трогаем:** `Microsoft-Edge-WebView-FOD-Package`, `Microsoft-OneCore-Edge-WebRuntime-Package` (это и есть WebView2), `Microsoft-OneCore-Fonts-DesktopFonts-NonLeanSupplement-Package` (обычные шрифты).

Пакеты `Wrapper`/`WOW64`/`merged` удаляются вместе с основным — DISM сам разрешает зависимости; если пакет помечен `permanent`, ошибка логируется и стадия продолжается (это не фатально).

### Стадия 10 — Удаление: provisioned Appx
`dism /Get-ProvisionedAppxPackages` → удалить `Microsoft.SecHealthUI_*` (интерфейс «Безопасность Windows»). В LTSC больше нечего — остаются только фреймворки `UI.Xaml` и `VCLibs` (нужны winget).

### Стадия 11 — Edge и Defender: файлы
Ни браузер Edge, ни ядро Defender **не являются CBS-пакетами** (проверено по составу образа: Edge ставится как обычное приложение, Defender AM входит в Foundation). Поэтому — файловый уровень с `takeown /F ... /R /A` + `icacls ... /grant Administrators:F /T`, затем удаление:

**Edge (удаляем):**
- `Program Files (x86)\Microsoft\Edge`
- `Program Files (x86)\Microsoft\EdgeCore`
- ярлыки `Microsoft Edge.lnk` в `ProgramData\...\Start Menu\Programs`, `Users\Public\Desktop`, `Users\Default\...\TaskBar`

**Edge (оставляем):** `Program Files (x86)\Microsoft\EdgeWebView`, `Program Files (x86)\Microsoft\EdgeUpdate` (нужен для обновления WebView2), `Windows\System32\Microsoft-Edge-WebView`.

**Defender (удаляем):**
- `Program Files\Windows Defender`, `Program Files (x86)\Windows Defender`
- `Program Files\Windows Defender Advanced Threat Protection`
- `ProgramData\Microsoft\Windows Defender`
- `Windows\System32\Tasks\Microsoft\Windows\Windows Defender\*`

Честная оговорка: бинарники Defender принадлежат Foundation-компоненту, и `sfc /scannow` или следующий LCU могут их вернуть. Что **не** вернётся — отключение служб в реестре (стадия 12): именно оно делает Defender мёртвым надолго, а удаление файлов — просто экономия места.

### Стадия 12 — Реестр offline
Кусты монтируются через `reg load`:
- `HKLM\LITE_SOFTWARE` ← `mount\Windows\System32\config\SOFTWARE`
- `HKLM\LITE_SYSTEM` ← `mount\Windows\System32\config\SYSTEM`
- `HKLM\LITE_DEFAULT` ← `mount\Users\Default\NTUSER.DAT`

и обязательно выгружаются в `finally` (незакрытый куст = битый образ).

**Службы → `Start = 4` (SYSTEM\ControlSet001\Services):**
- Defender: `WinDefend`, `WdNisSvc`, `WdNisDrv`, `WdFilter`, `WdBoot`, `Sense`, `SecurityHealthService`, `webthreatdefsvc`, `webthreatdefusersvc`, `MsSecCore`, `MsSecFlt`, `MsSecWfp`, `SgrmBroker`, `SgrmAgent`
- Телеметрия: `DiagTrack`, `dmwappushservice`, `diagnosticshub.standardcollector.service`, `WerSvc`, `wercplsupport`
- **Оставляем** `wscsvc` (Security Center — в нём регистрируется Avast) и `mpssvc` (брандмауэр)

**SOFTWARE — политики:**
- `Policies\Microsoft\Windows Defender`: `DisableAntiSpyware=1`, `DisableAntiVirus=1`; `Real-Time Protection\DisableRealtimeMonitoring=1`
- `Policies\Microsoft\Windows\System\EnableSmartScreen=0`
- `Policies\Microsoft\Windows\DataCollection\AllowTelemetry=0`; `Microsoft\Windows\CurrentVersion\Policies\DataCollection\AllowTelemetry=0`
- `Policies\Microsoft\Windows\CloudContent`: `DisableWindowsConsumerFeatures=1`, `DisableSoftLanding=1`, `DisableCloudOptimizedContent=1`
- `Policies\Microsoft\Windows\WindowsCopilot\TurnOffWindowsCopilot=1`; `Policies\Microsoft\Windows\WindowsAI`: `DisableAIDataAnalysis=1`, `AllowRecallEnablement=0`
- `Policies\Microsoft\EdgeUpdate`: `Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}=0` (запрет установки Edge Stable — GUID подтверждён), `Install{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}=1`, `Update{F3017226-...}=1` (WebView2 ставить и обновлять можно)
- удалить: `Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge`, `Microsoft\Windows\CurrentVersion\App Paths\msedge.exe`, `Clients\StartMenuInternet\Microsoft Edge`, `Microsoft\EdgeUpdate\ClientState\{56EB18F8-...}`
- `Microsoft\Windows\CurrentVersion\OOBE\BypassNRO=1`

**SYSTEM — обход требований:**
- `Setup\LabConfig`: `BypassTPMCheck`, `BypassSecureBootCheck`, `BypassRAMCheck`, `BypassStorageCheck`, `BypassCPUCheck` = 1
- `Setup\MoSetup\AllowUpgradesWithUnsupportedTPMOrCPU=1`

**DEFAULT (профиль по умолчанию для новых пользователей):**
- `Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager`: `SubscribedContent-*Enabled=0` (310093, 338388, 338389, 338393, 353694, 353696), `SilentInstalledAppsEnabled=0`, `SystemPaneSuggestionsEnabled=0`, `SoftLandingEnabled=0`
- `...\Explorer\Advanced`: `TaskbarDa=0` (виджеты), `TaskbarMn=0` (чат), `ShowCopilotButton=0`, `Start_IrisRecommendations=0`
- `...\AdvertisingInfo\Enabled=0`; `...\Privacy\TailoredExperiencesWithDiagnosticDataEnabled=0`
- `...\Search\SearchboxTaskbarMode=1` (поиск — иконкой)

Только пресет `max` дополнительно удаляет папки `Windows\SystemApps\*` из списка Full.Fast (Xbox, PeopleExperienceHost, ContentDeliveryManager, AIX и т.д.). В `balanced` они остаются, но выключены политиками — так надёжнее.

### Стадия 13 — Добавление: winget и Install-Firefox

**winget.** С GitHub (`microsoft/winget-cli`, latest — сейчас v1.29.290, проверено):
- `Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle` (207 МБ)
- `DesktopAppInstaller_Dependencies.zip` (93 МБ) → из него `x64\Microsoft.VCLibs.140.00.UWPDesktop_*.appx` и `x64\Microsoft.UI.Xaml.2.8_*.appx`
- `*_License1.xml`

```
dism /Image:mount /Add-ProvisionedAppxPackage
     /PackagePath:...msixbundle
     /DependencyPackagePath:...UWPDesktop.appx /DependencyPackagePath:...UI.Xaml.appx
     /LicensePath:...License1.xml
```
Кэшируется в `UpdatesDir\winget\`. Источник `msstore` на LTSC работать не будет (нет Store), основной `winget` — будет.

**Install-Firefox.** Файл `Users\Public\Desktop\Install-Firefox.cmd` (виден всем пользователям):
```bat
@echo off
title Install Firefox
where winget >nul 2>&1 && (
    winget install --id Mozilla.Firefox -e --accept-package-agreements --accept-source-agreements
    if not errorlevel 1 goto :eof
)
echo winget unavailable, downloading directly...
curl.exe -L -o "%TEMP%\FirefoxSetup.exe" "https://download.mozilla.org/?product=firefox-latest&os=win64&lang=@@LANG@@"
if exist "%TEMP%\FirefoxSetup.exe" start "" /wait "%TEMP%\FirefoxSetup.exe"
```
`@@LANG@@` подставляется при сборке из языка образа по таблице Mozilla: `ru-RU→ru`, `en-US→en-US`, `en-GB→en-GB`, `de-DE→de`, `fr-FR→fr`, `uk-UA→uk`, `pl-PL→pl`, `it-IT→it`, `es-ES→es-ES`, `pt-BR→pt-BR`, `tr-TR→tr`, `cs-CZ→cs`, `ja-JP→ja`, `zh-CN→zh-CN`, `zh-TW→zh-TW`, `ko-KR→ko`, `nl-NL→nl`, `kk-KZ→kk`, `be-BY→be`; для неизвестного — первые две буквы тега, при неудаче Mozilla сама отдаст en-US. Ссылка проверена: для `ru` отдаёт `Firefox Setup 155.0.1.exe`.

Если у winget при установке Firefox что-то пойдёт не так — скрипт молча падает на `curl`.

### Стадия 14 — Очистка хранилища и фиксация
```
dism /Image:mount /Cleanup-Image /StartComponentCleanup /ResetBase
dism /Unmount-Image /MountDir:mount /Commit
```
`ResetBase` — 15–30 минут. После него интегрированный LCU становится неудаляемым — это нормально для образа.

Затем `boot.wim`: монтируется индекс 2 (Setup), в его `SYSTEM` добавляются те же `LabConfig`/`MoSetup`, размонтируется с `/Commit`. То же для индекса 1 (WinPE) — на случай загрузки в него. Оба индекса остаются, `boot.wim` не подменяется (в отличие от Full.Fast).

### Стадия 15 — Экспорт
```
dism /Export-Image /SourceImageFile:WorkDir\install.wim /SourceIndex:1
     /DestinationImageFile:WorkDir\iso\sources\install.esd /Compress:recovery /CheckIntegrity
```
`Unmount /Commit` не освобождает место внутри WIM — экспорт делает это и одновременно сжимает LZMS. 20–40 минут. При `-Compression max` — `install.wim` с `/Compress:max`. Исходный `install.wim` из `sources\` удаляется.

В корень `WorkDir\iso` кладётся `autounattend.xml` (§5).

### Стадия 16 — ISO, контрольная сумма, уборка
```
oscdimg.exe -m -o -u2 -udfver102 -l<метка>
  -bootdata:2#p0,e,b"iso\boot\etfsboot.com"#pEF,e,b"iso\efi\microsoft\boot\efisys.bin"
  "WorkDir\iso" "out\<имя>_lite.iso"
```
Метка — исходная + `_LITE` (обрезка до 32 символов). Далее `Get-FileHash -Algorithm SHA256` → `out\<имя>_lite.sha256`; итоговая таблица в лог и на экран: исходный размер / итоговый / билд / что удалено / что добавлено / время по стадиям; `Remove-Item WorkDir -Recurse -Force`.

---

## 5. `autounattend.xml` — встроенный шаблон

Только то, что решено; ничего лишнего:

| Pass | Что делает |
|---|---|
| `windowsPE` | `RunSynchronous`: `reg add HKLM\SYSTEM\Setup\LabConfig` × 5 ключей (дублирует стадию 14 — на случай загрузки с чужого `boot.wim`); `AcceptEula`; язык интерфейса установщика = язык образа; **выбор индекса и разметки диска не задаётся** — установщик спрашивает, как обычно |
| `specialize` | ничего (сеть **не** отключаем, в отличие от Full.Fast) |
| `oobeSystem` | `HideOnlineAccountScreens=true`, `HideEULAPage=true`, `HideWirelessSetupInOOBE=true`, `ProtectYourPC=3`; локальная учётка **не создаётся** — OOBE показывает экран создания локального пользователя (решение №16) |

Ключ `-Unattend none` убирает файл совсем; `-Unattend <путь>` подставляет свой.

---

## 6. Матрица пресетов (окончательная)

| | `safe` | `balanced` | `max` |
|---|---|---|---|
| Обновления (LCU + .NET) | да | да | да |
| Edge браузер / WebView2 | удалить / оставить | удалить / оставить | удалить / **удалить** |
| Defender | политики + службы выкл., файлы на месте | **удалить** | удалить |
| WinRE | оставить | **удалить** (файл сохранён) | удалить |
| CJK-шрифты | оставить | **удалить** | удалить |
| Speech / OCR / Handwriting / TTS | оставить | удалить | удалить |
| WMP, Paint, StepsRecorder, IE | оставить | удалить | удалить |
| Телеметрия, реклама, Copilot | выкл. политиками | выкл. политиками | выкл. + папки SystemApps |
| Hyper-V, WSL, контейнеры | оставить | **оставить** | удалить |
| Hello Face, MathRecognizer, Fax, XPS, ISE | оставить | оставить | удалить |
| Embedded (UWF, Shell Launcher) | оставить | оставить | удалить |
| winget + Install-Firefox | да | да | да |
| Обход TPM / Secure Boot | да | да | да |
| `ResetBase` | нет | **да** | да |
| Windows Update | работает | **работает** | работает |
| Обслуживаемость образа | полная | **полная** | полная (WinSxS не сносим даже в `max` — это единственное, чем `max` отличается от Full.Fast в лучшую сторону) |

---

## 7. Приёмочное тестирование

Тест — на Hyper-V этой же машины (он у вас есть):

1. VM Gen 2, **Secure Boot выключен**, TPM не добавлять, 4 ГБ RAM, 40 ГБ диск, сеть — Default Switch.
2. Загрузка с `out\*_lite.iso` → установка должна пройти без экрана «This PC can't run Windows 11».
3. OOBE: экран аккаунта Microsoft не показывается, предлагается локальный пользователь.
4. После входа:
   - `winver` → 26100.9445;
   - `winget --version` → работает; двойной клик по `Install-Firefox` → Firefox ставится;
   - `Get-Service WinDefend, DiagTrack` → Disabled; `Get-AppxPackage *SecHealth*` → пусто;
   - `Test-Path "C:\Program Files (x86)\Microsoft\Edge"` → False; `...\EdgeWebView` → True;
   - `Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All, VirtualMachinePlatform, Microsoft-Windows-Subsystem-Linux` → Disabled (не Absent!) — значит payload на месте, включаются одной командой;
   - Параметры → Центр обновления → «Проверить наличие обновлений» → ищет, не ругается;
   - `sfc /scannow` — ожидаемо найдёт и восстановит удалённые бинарники Defender (они CBS-защищённые); службы при этом остаются выключенными. Это не ошибка сборки;
   - `Get-WindowsCapability -Online | ? State -eq Installed` — ни одной `Language.Speech/OCR`, `Media.WindowsMediaPlayer`.
5. Отдельно: `reagentc /info` → Disabled (WinRE удалён). Проверка восстановления: скопировать `out\*_winre.wim` в `C:\Windows\System32\Recovery\Winre.wim`, `reagentc /setreimage /path C:\Windows\System32\Recovery`, `reagentc /enable` → Enabled.

---

## 8. Риски и запасные ходы

| Риск | Вероятность | План Б |
|---|---|---|
| ADK DISM на хосте Windows 10 19044 не сможет обслуживать образ 26100 (ошибка при `Mount`/`Add-Package`) | низкая, но реальная | Пересборка в VM с Windows 11 24H2; скрипт тот же |
| `Add-ProvisionedAppxPackage` для winget падает на Win10-хосте | средняя | Тот же обход; либо `-NoWinget` и ставить winget вручную после установки |
| Часть пакетов помечена `permanent` и не удаляется | высокая для отдельных пакетов | Логируем, продолжаем. Не блокирует сборку |
| LCU возвращает Edge при первом же обновлении на установленной системе | средняя | Политика `EdgeUpdate\Install{56EB...}=0` уже в образе — это штатный механизм блокировки |
| `BypassNRO` не работает на свежем LCU | низкая (Enterprise/LTSC и так допускают локальный аккаунт) | Резерв: полная автоматизация учётки через `-Unattend` со своим XML |
| Интеграция LCU падает по checkpoint | низкая при ADK DISM | Проверить, что в папке `lcu\` только два `.msu`; `-UpdateMode local` с ручной раскладкой |
| Незакрытый `reg load` или упавший `Mount` оставляют мусор | — | `finally` всегда выгружает кусты и делает `/Cleanup-Mountpoints`; на старте — проверка висящих точек |

---

## 9. Порядок действий

| # | Кто | Что | Время |
|---|---|---|---|
| 1 | я | Написать `win-11-lite.ps1` по этому плану; прогнать `-WhatIf` без прав (паспорт ISO, план удалений, оценка) | сегодня |
| 2 | вы | Установить ADK Deployment Tools (§1.1) — или дать скрипту `-InstallAdk` | 5 мин |
| 3 | вы | Запустить из сессии с правами администратора:<br>`.\win-11-lite.ps1 -InputIso .\iso\en-us_windows_11_iot_enterprise_ltsc_2024_x64_dvd_f6b14814.iso` | 1.5–3 ч |
| 4 | я | Разобрать `out\*.log`, поправить скрипт; повторный прогон использует кэш обновлений, так что вторая итерация быстрее | — |
| 5 | вы | Установить в Hyper-V по §7, сообщить результат | 30 мин |
| 6 | оба | Итерации до зелёного теста. Ожидание — 2–4 прогона | — |
| 7 | вы | Тот же скрипт на `ru-ru_windows_11_enterprise_ltsc_2024_x64_dvd_f9af5773.iso` — проверка универсальности | 1.5–3 ч |

Первый прогон — с `-KeepWorkDir`, чтобы при ошибке было что смотреть. Уборка рабочего каталога включается по умолчанию, как договорились, но на отладке она мешает.

---

## Источники, проверенные при составлении плана

- [DISM OS Package Servicing — checkpoint cumulative updates (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-operating-system-package-servicing-command-line-options?view=windows-11)
- [Add-WindowsPackage (Microsoft Learn)](https://learn.microsoft.com/en-us/powershell/module/dism/add-windowspackage?view=windowsserver2022-ps)
- [Microsoft Edge Update policies — GUID Edge / WebView2 (Microsoft Learn)](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-update-policies)
- [Windows ADK — состав Deployment Tools, oscdimg (matrixpost)](https://blog.matrixpost.net/microsoft-oscdimg-quickly-creating-iso-files-from-the-command-line/)
- [Установка ADK для Windows Server 2025 / 24H2 (bogdancaraman)](https://blog.bogdancaraman.com/adk-windows-server-2025-installation/)
- [KB5074109 — DISM sequencing & offline servicing (WindowsForum)](https://windowsforum.com/threads/kb5074109-january-2026-windows-11-update-dism-sequencing-offline-image-servicing.396693/)
- [microsoft/winget-cli releases — v1.29.290 (GitHub API, 10.09.2026)](https://github.com/microsoft/winget-cli/releases)
- [Microsoft Update Catalog — KB5124008 / KB5126052 (проверено запросами 10.09.2026)](https://www.catalog.update.microsoft.com/)
