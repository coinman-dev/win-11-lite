# Отчёт 5: как Full.Fast ставится без WinRE, что делают другие сборщики и какие приёмы стоит взять

**Дата:** 2026-09-11

Уточнение источников о ResetBase: [проверка 10](10-resetbase-sources-2026-09-11.md). Прежний пересказ Microsoft Q&A ошибочно превращал предположение независимого консультанта в подтверждённую позицию Microsoft.
**Метод:** разбор `boot.wim` обоих образов (7-Zip, DISM, реестр WinPE), строки в бинарниках установщика, пофайловое сравнение Full.Fast с оригиналом, чтение исходников tiny11builder, документации Microsoft и форумов. Всё, что помечено «проверено» — воспроизведено локально; «по источникам» — подтверждено минимум двумя независимыми публикациями; «гипотеза» — требует нашего теста.

---

## 0. Коротко

1. **В 24H2 два установщика, и они лежат в одном `boot.wim`.** Новый (ConX/MoSetup: `SetupHost.exe` → `SetupPrep.exe`) требует `winre.wim` — извлекает его в `SafeOS` и без него падает с `0x80070003`. Классический (`sources\setup.exe`, «BlueBox») без `winre.wim` обходится. Full.Fast просто подменил `boot.wim` на Windows 10, где нового установщика нет вовсе.
2. **Есть штатный переключатель.** Файл `\Windows\System32\winpeshl.ini` в `boot.wim` (индекс 2) с одной строкой `%SystemDrive%\sources\setup.exe, /legacy` запускает классический установщик, не трогая ничего больше. Это открывает: удаление `winre.wim` (−140 МБ в ISO), урезание `sources\` до трёх файлов (−210 МБ), полностью рабочий `autounattend.xml` и ключи вроде `/DynamicUpdate Disable`. Нужен тест в ВМ.
3. **`/ResetBase` оставляем выключенным по умолчанию.** Microsoft для checkpoint-медиа использует `/StartComponentCleanup`. Сообщения о сбоях обновления требуют различать обычный ResetBase и принудительное удаление baseline-пакетов; неизбежная поломка от одного ключа не доказана. Сравнение WIM до переэкспорта (3.97 → 4.00 ГБ) не измеряет экономию итогового ISO.
4. **MicroWin из WinUtil удалён 6 февраля 2026** — в списке инструментов его больше нет, живёт только форк.
5. Full.Fast сверх того, что делаем мы: снёс `NativeImages` (−385 МБ), `WinSxS\Backup` (−184 МБ), 23 пакета драйверов (−86 МБ), сжал кусты реестра (−80 МБ) и выпотрошил WinSxS до манифестов. Первые два приёма — кандидаты в пресет `max`.

---

## 1. Почему Full.Fast ставится без `winre.wim`

### 1.1. Два установщика в одном `boot.wim` (проверено)

Индекс 2 оригинального `boot.wim` 24H2, ключевые файлы:

| Файл в WinPE | Размер | Версия | Описание из ресурсов | Роль |
|---|---:|---|---|---|
| `X:\setup.exe` | 99 896 | 10.0.26100.1 | Windows Installer | лаунчер |
| `X:\sources\setup.exe` | 333 104 | 10.0.26100.1591 | Windows Installation and Setup | **классический движок («BlueBox»)** |
| `X:\sources\SetupHost.exe` | 910 776 | 10.0.26100.1591 | Modern Setup Host | новый движок (MoSetup) |
| `X:\sources\SetupPrep.exe` | 1 332 640 | 10.0.26100.1591 | Windows 11 Setup | новый UI (ConX) |

Цепочка запуска (проверено по реестру WinPE): `HKLM\SYSTEM\Setup\CmdLine = winpeshl.exe`, файла `winpeshl.ini` нет, `startnet.cmd` содержит только `wpeinit`. Значит `winpeshl` по умолчанию запускает `X:\setup.exe` → тот запускает `X:\sources\setup.exe` → тот поднимает `SetupHost.exe` → `SetupPrep.exe`, и мы видим новый интерфейс. Кнопка «Previous version of Setup» на первом экране заставляет `SetupPrep` и `SetupHost` выйти, и `sources\setup.exe` продолжает работать своим классическим UI.

Строки в бинарниках (проверено): в `SetupHost.exe` — `/Product Client`, `/Product Server`, `/Product AzsHci`, `LegacySetupInterrupt`, `Sources\SetupConfig.ini`; в `SetupPrep.exe` — «Setup is unable to launch legacy setup experience». То есть режим «legacy» заложен в сам продукт, а не является хаком.

### 1.2. Что именно требует `winre.wim` (проверено по нашему логу)

Наш `setuperr.log` от 11.09.2026 00:02:
```
MOUPG  CSetupManager::ExecuteDownlevelMode
SP     CExtractFilesFromWIM::DoExecute: Cannot extract file \Windows\System32\Recovery\winre.wim
       from D:\Sources\Install.esd. Error 0x80070003
SP     Operation failed: Extract files from WIM file PathForNewOSFile, index 1
       to C:\$WINDOWS.~BT\Sources\SafeOS. Error: 0x80070003
```
`MOUPG` — это MoSetup, новый движок. Он строит установку по схеме апгрейда: `Downlevel` → `SafeOS` → `First boot`, и для фазы SafeOS ему нужен `winre.wim` из образа. Классический движок применяет WIM напрямую и SafeOS не использует.

Подмена `winre.wim` пустым файлом (приём tiny11 Core) **на 24H2 не работает**: по источникам это даёт `0x8007000B` (невалидные данные), поэтому в tiny11-automated для 24H2+ введён обязательный флаг `PreserveWinRE`.

### 1.3. Как это сделал Full.Fast (проверено)

| | Оригинал 24H2 | Full.Fast |
|---|---|---|
| `boot.wim` | 26100.1591, 2 индекса, 514 МБ | **19041.631 (Windows 10 20H2)**, 1 индекс, 268 МБ |
| Установщик внутри | лаунчер + классический + MoSetup + ConX | только классический Win10 (`setup.exe` 74 КБ «Windows Installer», 166 файлов в `sources\`) |
| `sources\` на ISO | 877 файлов, 210 МБ (+ wim) | **4 файла**: `boot.wim`, `install.esd`, `EI.CFG`, `setup.exe` 0.3 МБ |
| `winre.wim` в образе | есть, 508 МБ | нет |

Грубо, но работает: у WinPE из Windows 10 нет `SetupHost`/`SetupPrep`, он не умеет ничего, кроме классической установки, и `winre.wim` ему не нужен. Побочный эффект — установщик образца 2020 года: старые inbox-драйверы в WinPE (NVMe/USB4/Wi-Fi новых чипсетов могут не подхватиться на этапе установки) и в целом чужеродный компонент в образе 2024–2026 года.

### 1.4. Штатное решение для 24H2 — `winpeshl.ini` (по источникам, нужен тест)

Положить в `boot.wim`, индекс 2, файл `\Windows\System32\winpeshl.ini`:
```ini
[LaunchApps]
%SystemDrive%\sources\setup.exe, /legacy
```
Подтверждено тремя независимыми публикациями (NTLite-форум, тред 6068; elevenforum, HowTo #48951 и тред #34964) и косвенно строками в `SetupPrep.exe`. Форумчане отмечают, что попытка переписать `HKLM\SYSTEM\Setup\CmdLine` на скрипт с `X:\setup.exe` **не даёт** legacy-режима — нужен именно ключ `/legacy` у `sources\setup.exe`.

**Что это даёт:**

| Эффект | Экономия / польза | Уверенность |
|---|---|---|
| `winre.wim` можно удалять из образа | −508 МБ развёрнутых, **~−140 МБ ISO** | высокая (классический движок без него обходится — это и делает Full.Fast) |
| `sources\` на ISO — только `boot.wim`, `install.esd`, `EI.CFG` | **−210 МБ ISO** | высокая для чистой установки с носителя (Full.Fast так живёт); ломает запуск `setup.exe` из работающей Windows (in-place) |
| `autounattend.xml` обрабатывается полностью | ConX «не обрабатывает oobeSystem на 25H2» (NTLite-форум); классический — обрабатывает | высокая |
| Ключи командной строки прямо в `winpeshl.ini` | `/DynamicUpdate Disable`, `/Telemetry Disable`, `/Compat IgnoreWarning`, `/ResizeRecoveryPartition Disable` (все документированы Microsoft) | средняя — надо проверить, какие из них классический движок принимает при загрузке с носителя |
| `LabConfig` в реестре WinPE работает как раньше | обход TPM/Secure Boot остаётся | высокая |

**Чем платим:** классический интерфейс (кому-то это плюс), нет функций нового установщика (их и не жалко — это DU, телеметрия, «облачное» восстановление), без WinRE не будет среды восстановления — но её можно вернуть позже через `reagentc /setreimage` из сохранённого файла, что уже реализовано в скрипте.

**План проверки (одна ВМ, ~40 минут):**
1. Смонтировать `boot.wim` idx 2, положить `winpeshl.ini`, закоммитить.
2. Собрать ISO с `-RemoveWinRE` (флаг уже есть).
3. Загрузить ВМ: должен появиться классический синий установщик, а не ConX.
4. Довести установку до OOBE, проверить `reagentc /info` (Disabled — ожидаемо) и что `autounattend` отработал (нет экрана аккаунта Microsoft).
5. Второй прогон — с урезанным `sources\` (3 файла).

Если тест проходит — это становится основным режимом, а «donor boot.wim» не нужен вовсе.

### 1.5. Запасные варианты, если `/legacy` не сработает

- **Donor `boot.wim` от 23H2** (22631) — Windows 11, классический установщик; рецепт «23H2 boot.wim + 24H2 install.wim» многократно подтверждён на elevenforum. Минус: 23H2-медиа Microsoft больше не раздаёт, брать через UUP dump.
- **Donor от Windows Server 2025** (26100) — то же ядро, установщик классический (именно поэтому `/product server` включает старый режим), ISO свободно доступен в Evaluation Center. **Гипотеза**: не проверено, что серверный WinPE без вопросов применяет клиентский образ.
- **Windows 10 22H2** — путь Full.Fast, худший из трёх.

---

## 2. Критично: `/ResetBase` на образах 24H2 и новее

### 2.1. Факты

- В RTM-образе LTSC 2024 (26100.1742) уже лежит **`Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.1742.1.10`** (проверено по листингу). Это и есть checkpoint-обновление KB5043080 — тот самый «baseline», относительно которого строятся все последующие LCU.
- Microsoft Q&A (5849454): независимый консультант Ramesh Srinivasan наблюдал пропажу данных KB5043080 и ошибки обновлений, но прямо пишет, что не уверен в связи с ResetBase. Ранее здесь это ошибочно называлось подтверждением инженера Microsoft; подробности — в проверке 10.
- Официальная процедура Microsoft для offline-медиа с чекпоинтами (Learn, «Checkpoint cumulative updates and the Microsoft Update Catalog»): `Add-Package` целевого LCU → **`/Cleanup-Image /StartComponentCleanup`** → `Unmount` → `Export-Image`. `/ResetBase` в ней отсутствует.
- В прежнем прогоне без обновлений WIM после ResetBase изменился с 3.97 до 4.00 ГБ. Размер WIM до переэкспорта не доказывает отсутствие экономии: нужны анализ компонентного хранилища и сравнение заново экспортированных образов.
- Тот же документ: LCU **не обновляет `winre.wim`** — для него нужны SSU + SafeOS Dynamic Update. Это ответ на вопрос, «уменьшить размер при обновлениях»: `winre.wim` от LCU не растёт вообще.

### 2.2. Что менять в скрипте

- Для билдов ≥ 26100 — `/Cleanup-Image /StartComponentCleanup` **без** `/ResetBase`, в обоих режимах (с обновлениями и без).
- `/ResetBase` оставить только за явным флагом с предупреждением о невозможности удалить уже установленные обновления и необходимости проверить дальнейшее обслуживание конкретного ISO.
- ISO отчёта 06 прошёл через `/ResetBase`; обновляемость требуется проверять установкой следующего LCU, а не считать заранее нарушенной по одному наличию ключа.

---

## 3. Что ещё вырезал Full.Fast — и мы пока нет (проверено по листингам)

| Каталог | Оригинал | Full.Fast | −МБ | Что это и цена |
|---|---:|---:|---:|---|
| `Windows\assembly\NativeImages_*` | 385 | 0 | **385** | Прекомпилированные .NET-сборки (NGEN). Регенерируются задачей `.NET Framework NGEN` при простое. Цена: первые запуски .NET-приложений (в т.ч. PowerShell 5.1) медленнее, пока NGEN не отработает. По отзывам — безопасно, ~250 МБ экономии в ISO |
| `Windows\WinSxS\Backup` | 184 | 0 | **184** | Резерв критичных файлов для `sfc` и `DISM /RestoreHealth` без внешнего источника. Windows Update **не** зависит. Модератор NTLite: удалять только на этапе сборки образа, не на живой системе; после удаления `sfc` потребует `/Source` |
| `Windows\System32\config\*` | 158 | 78 | **80** | `COMPONENTS` 38 → 4.3 МБ (следствие выпотрошенного WinSxS), `SOFTWARE` 65 → 53 МБ (удалённые компоненты + уплотнение куста). NTLite делает «Compact hives»; нам доступно только косвенно |
| `Windows\System32\DriverStore` | 443 | 357 | **86** | Удалено всего 23 пакета из 696: `ntprint`, `prnms003`, часть storage/sensor/TPM (`stornvme`, `storufs`, `uaspstor`, `tpm`, `tpmvsc`, `spaceport`…). Удаление `stornvme`/`uaspstor` — плохая идея для реального железа |
| `Windows\Boot` | 72 | 53 | 18 | CJK-шрифты загрузчика (у нас уже добавлено) |
| `Windows\Help` | 7 | 1 | 6 | |
| `Windows\WinSxS` целиком | 7370 | 50 | 7320 | Осталось: `Manifests` (476), стек обслуживания, VC-рантаймы. `servicing\Packages` (2881 `.mum/.cat`) оставлены — CBS «думает», что пакеты есть. Это рецепт tiny11 Core |

Итог: помимо WinSxS, Full.Fast получил ещё ~660 МБ развёрнутых данных (~180–200 МБ ISO) четырьмя приёмами, из которых два (NativeImages, WinSxS\Backup) применимы у нас в пресете `max`.

---

## 4. Инструменты: что они делают на самом деле

Проверено по исходникам (tiny11builder, tiny11Coremaker), README (остальные) и документации.

### 4.1. tiny11builder (ntdevlabs) — `tiny11maker.ps1`
- DISM + `oscdimg` из ADK; индекс спрашивает через `Read-Host`.
- Удаляет 47 provisioned Appx (список из Home/Pro: Clipchamp, Xbox, Teams, Bing…), **не удаляет Defender, не удаляет `winre.wim`**.
- Edge и `System32\Microsoft-Edge-Webview` — файлами через `takeown`/`icacls` (**WebView2 сносит**, в отличие от нас).
- Реестр: `LabConfig` × 5 + `MoSetup\AllowUpgradesWithUnsupportedTPMOrCPU` в `boot.wim` и `install.wim`; `BypassNRO`; `ContentDeliveryManager`; `AllowTelemetry=0`; `TurnOffWindowsCopilot`; `Teams\DisableInstallation`; `BitLocker\PreventDeviceEncryption=1`; `OneDrive\DisableFileSyncNGSC`; `ReserveManager\ShippedWithReserves=0` (отключает зарезервированное хранилище — **полезный приём**).
- Удаляет XML задач планировщика: Compatibility Appraiser, CEIP, ProgramDataUpdater, QueueReporting.
- Экспорт `/Compress:recovery`, **`/ResetBase`** (см. §2 — на 24H2 это их проблема).
- `oscdimg -m -o -u2 -udfver102 -bootdata:2#p0,e,b…etfsboot.com#pEF,e,b…efisys.bin`.
- `autounattend.xml` качается с GitHub при отсутствии; содержит `<Compact>true</Compact>`.

### 4.2. tiny11 Core — `tiny11Coremaker.ps1`
- Всё из regular плюс: WinSxS заменяется урезанной копией (`Catalogs`, `FileMaps`, `Fusion`, `Manifests`), **`winre.wim` — пустой файл**, `wuauserv` Start=4, `WaaSMedicSvc`/`UsoSvc` удаляются из реестра, Defender-службы Start=4, `RunOnce StopWUPostOOBE = net stop wuauserv`.
- Результат 1–2 ГБ ISO, необновляемый образ. Автор reforged-версии от Core отказался.

### 4.3. tiny11-automated (kelexine) и tiny11maker-reforged (chrisGrando)
- tiny11-automated: CI/CD-обёртка (GitHub Actions, чексуммы, SourceForge), параметры `-INDEX`, `-SCRATCH`, `-SkipCleanup`, `-ENABLE_DOTNET35`, **`-PreserveWinRE` — обязателен на 24H2+**, иначе `0x8007000B`.
- reforged: переписанный `tiny11maker.ps1` с GUI и лаунчером, только 24H2/25H2; автор прямо пишет, что ноябрьский релиз ntdev «performed terribly» на 24H2.

### 4.4. MicroWin (WinUtil, Chris Titus) — **удалён из проекта 06.02.2026** (коммит #3999)
- До удаления: выбор ISO (в т.ч. автозагрузка через Fido), удаление Appx по префиксам, **экспорт драйверов с текущей машины** (`Export-WindowsDriver -Online`) в `install.wim` и `boot.wim` idx 2, запись на USB (GPT/FAT32), `autounattend` с `LabConfig`, локальным пользователем и `FirstLogon.ps1`; опции «Keep Defender/Edge/Store».
- Полезный трюк, который стоит позаимствовать: **скачивание `oscdimg.exe` напрямую из ADK-кабов Microsoft с проверкой хэша** вместо установки всего ADK.
- Сегодня живёт только в форке `fortunamagix/winutil-Microwin`. Команда `irm christitus.com/win | iex` MicroWin больше не содержит.

### 4.5. WinISOUtil (yusufklncc/winisoutil)
- Интерактивное меню + unattended по `.json`-профилю (schema v2), `-UpdatesPath`/`-DriversPath`, удаление лишних редакций из ISO, WIM и ESD, твики из `src\tweaks.ps1`, `trap` для безопасного размонтирования при ошибке, SHA-256 архивов.
- Требует ADK; монтирует в `%TEMP%\WinISOUtil`. Ничего про WinRE, checkpoint, legacy-установщик.

### 4.6. Windows-ISO-Debloater (itsNileshHere)
- Appx, capabilities, packages, OneDrive, Edge — опциями; **«Remove AI Components» в стандартном наборе**; ESD-сжатие опцией.
- **Два способа сборки ISO: `oscdimg` или `IMAPI2FS`** — встроенный COM-API Windows, ADK не нужен. `IFileSystemImage2::put_BootImageOptionsArray` поддерживает массив загрузочных образов (BIOS + UEFI), т.е. полноценный гибридный ISO без внешних бинарников. Для нас — запасной путь, если на машине нет ADK (DISM всё равно нужен из ADK, но `oscdimg` можно заменить).
- CLI: `-noPrompt -isoPath -winEdition -outputISO` + `yes/no`-опции.

### 4.7. MSMG Toolkit
- Батники над DISM, последний релиз **13.7 от мая 2024** — до 24H2; работа с 24H2/25H2 «community-tested». Сильная сторона — гранулярный список компонентов и интеграция локализаций/.NET/VC++. Для 24H2 с чекпоинтами устарел.

### 4.8. NTLite (коммерческий)
- Единственный, кто штатно умеет: снос `WinSxS\Backup`, удаление `.NET native images`, чистку DriverStore по классам, уплотнение кустов реестра, удаление WinRE с осознанием последствий, компоненты внутри `winre.wim`. Именно эти приёмы видны в Full.Fast.

### 4.9. Другой класс: дебло́ат во время установки, образ не трогается
- **UnattendedWinstall** (memstechtips) — один большой `autounattend.xml`: удаление приложений, реестр, настройки — всё через `RunSynchronous`/`FirstLogonCommands`. **Winhance** имеет Builder Mode, генерирующий такой XML; **WIMUtil** (архивирован в пользу Winhance) распаковывал ISO, вкладывал XML и **драйверы с текущей машины**.
- **Rufus** кладёт `unattend.xml` в `sources\$OEM$\$$\Panther\` — это альтернативное место, которое новый установщик тоже читает; 4.14 (апрель 2026) добавил «Quality of Life» — снос Copilot, OneDrive, нового Outlook, быстрого старта.
- **AveYo MediaCreationTool.bat** — патчит `winsetup.dll` в `boot.wim` для снятия проверок, «Skip TPM Check v2» через IFEO, `PID.txt`/`EI.cfg`, `auto.cmd`.
- Плюсы класса: нулевой риск для обслуживаемости, всегда совместимо с обновлениями. Минусы: ISO не уменьшается, Edge/Defender таким способом не убрать, время установки больше. Для нас — не замена, но `FirstLogonCommands` и `$OEM$\$$\Panther` стоит держать в арсенале.

### 4.10. wimlib
- Solid-LZMS как у DISM `/Compress:recovery`; DISM по умолчанию 64 МиБ chunk, wimlib 32 МиБ (можно 128 МиБ — на 2.6 ГБ разница ~30 МБ). Выигрыш в размере единицы процентов, выигрыш во времени заметный (многопоточность). `wimlib-imagex optimize --solid` — дожать уже готовый ESD. Опционально, не приоритет.

---

## 5. Каталог приёмов с оценкой

| # | Приём | Экономия | Риск / цена | Решение |
|---|---|---:|---|---|
| 1 | `winpeshl.ini` → `sources\setup.exe /legacy` | сам по себе 0, открывает №2–4 | классический UI; нужен тест | **тест → в balanced** |
| 2 | Удаление `winre.wim` (при №1) | ~140 МБ ISO | нет среды восстановления; возвращается `reagentc` из сохранённого файла | **после теста — флаг `-RemoveWinRE` без предупреждения о неустанавливаемости** |
| 3 | `sources\` → `boot.wim` + `install.esd` + `EI.CFG` (при №1) | ~210 МБ ISO | нельзя запускать `setup.exe` из Windows (in-place) | **флаг `-TrimSources`** |
| 4 | Ключи установщика в `winpeshl.ini`: `/DynamicUpdate Disable /Telemetry Disable` | 0 | нужно проверить, что классический движок с носителя их принимает | тест вместе с №1 |
| 5 | **Не включать `/ResetBase` по умолчанию** | экономия не измерена корректно | сохраняется удаление установленных обновлений; совместимость после ResetBase требует проверки | **оставлено выключенным** |
| 6 | Удаление `Windows\assembly\NativeImages_*` | ~250 МБ ISO | первые запуски .NET-приложений медленнее до отработки NGEN | **в `max`**, возможно в balanced после теста |
| 7 | Удаление `WinSxS\Backup` | ~60 МБ ISO | `sfc`/`RestoreHealth` только с `/Source`; WU работает | **в `max`** |
| 8 | `ReserveManager\ShippedWithReserves=0` (из tiny11) | 0 в ISO, **до 7 ГБ на диске** после установки | нет | **в balanced** — бесплатно |
| 9 | `<Compact>true</Compact>` в `autounattend` (CompactOS) | 0 в ISO, ~2 ГБ на диске | небольшая нагрузка на CPU при чтении системных файлов | флаг `-CompactOS` |
| 10 | `BitLocker\PreventDeviceEncryption=1` (из tiny11) | — | отключает автошифрование устройства при OOBE — для домашнего использования скорее плюс (нет сюрприза с ключом восстановления) | **в balanced** |
| 11 | Удаление XML задач телеметрии из `System32\Tasks` (tiny11) | — | безопасно | в balanced (дополняет отключение служб) |
| 12 | `oscdimg` без ADK — скачать из ADK-кабов (MicroWin) или IMAPI2FS (ISO-Debloater) | — | DISM из ADK всё равно нужен | опция на будущее |
| 13 | Драйверы с текущей машины `Export-WindowsDriver -Online` → в образ и `boot.wim` (MicroWin/WIMUtil) | — | образ становится «под конкретное железо» | флаг `-DriversFromHost` |
| 14 | wimlib solid 128 МиБ | 1–3 % | внешний бинарник | нет |
| 15 | Чистка DriverStore | 86 МБ у Full.Fast | Full.Fast удалил `stornvme`, `uaspstor`, `tpm` — на реальном железе это риск не увидеть диск | **нет** (кроме принтерных `ntprint`/`prn*` в `max`) |
| 16 | Потрошение WinSxS до манифестов (tiny11 Core / Full.Fast) | ~1.5 ГБ ISO | необновляемый образ | нет, по-прежнему |
| 17 | Пустой `winre.wim` (tiny11 Core) | — | `0x8007000B` на 24H2 | нет |
| 18 | SafeOS DU в `winre.wim` + Setup DU в `sources\` при `-WithUpdates` | — | правильное обслуживание медиа по Microsoft; +время | позже, если `-WithUpdates` будет востребован |
| 19 | Удаление индекса 1 из `boot.wim` | единицы МБ | — | нет, не стоит возни |

---

## 6. Что менять в скрипте — по приоритету

1. **`/ResetBase` → только `/StartComponentCleanup`** для билдов ≥ 26100. Обязательно, до любого следующего прогона.
2. **Режим legacy-установщика**: стадия «boot.wim» дописывает `winpeshl.ini` в индекс 2 (и в индекс 1 — на случай ручного запуска). Флаг `-LegacySetup`, после успешного теста — включён в `balanced`.
3. При `-LegacySetup`: `-RemoveWinRE` теряет предупреждение о неустанавливаемости; появляется `-TrimSources`.
4. В balanced добавить реестр: `ShippedWithReserves=0`, `PreventDeviceEncryption=1`, удаление XML задач Appraiser/CEIP/QueueReporting.
5. В `max` добавить: `NativeImages_*`, `WinSxS\Backup`, принтерные драйверы.
6. Флаги `-CompactOS`, `-DriversFromHost` — по желанию.
7. Обновить отчёт 06 и план 04 (стадия 14, WinRE, sources).

Порядок проверки: сначала пересборка с п.1 и стандартным (не legacy) установщиком — убедиться, что образ с `winre.wim` ставится и OOBE даёт локальный аккаунт. Затем отдельная сборка с `-LegacySetup -RemoveWinRE -TrimSources` — целевой вариант, ожидаемый ISO **~2.8 ГБ**.

---

## Источники

**Legacy-установщик и `winre.wim`**
- [Win 11 25H2 unattend.xml issues — NTLite Forums (рецепт `winpeshl.ini`, ConX не обрабатывает oobeSystem)](https://ntlite.com/community/threads/win-11-25h2-unattend-xml-issues.6068/)
- [HowTo: Modify ISO to launch legacy installer + bypass eligibility checks — ElevenForum](https://www.elevenforum.com/t/howto-modify-iso-to-launch-legacy-installer-bypass-eligibility-checks.48951/)
- [How do I bypass the New Windows Install and only have the Old Setup? — ElevenForum](https://www.elevenforum.com/t/how-do-i-bypass-the-new-windows-install-and-only-have-to-old-setup.34964/)
- [W11 24H2 and old installation setup — ElevenForum (гибрид 23H2 boot.wim, CmdLine не помогает)](https://www.elevenforum.com/t/w11-24h2-and-old-installation-setup.25706/)
- [What are the differences between sources\setup.exe and setup.exe — Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/876600/what-are-the-differences-between-sourcessetup-exe)
- [kelexine/tiny11-automated — PreserveWinRE обязателен на 24H2+ (0x8007000B)](https://github.com/kelexine/tiny11-automated)
- [ntdevlabs/tiny11builder, issue #121 «missing winre.wim» (0x80070003)](https://github.com/ntdevlabs/tiny11builder/issues/121)
- [Windows Setup Automation Overview — SetupConfig.ini, порядок поиска answer-файлов (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-automation-overview)
- [Windows Setup Command-Line Options — /DynamicUpdate, /Telemetry, /ResizeRecoveryPartition, /Compat, /Uninstall (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-command-line-options)

**`/ResetBase` и чекпоинты**
- [Checkpoint cumulative updates and the Microsoft Update Catalog — официальная процедура для offline-медиа (Microsoft Learn)](https://learn.microsoft.com/en-us/windows/deployment/update/catalog-checkpoint-cumulative-updates)
- [Обсуждение ResetBase — Microsoft Q&A (сообщения сообщества, причинная связь не подтверждена)](https://learn.microsoft.com/en-ca/answers/questions/5849454/dism-online-cleanup-image-startcomponentcleanup-re)
- [Windows 11 IoT LTSC 25H2 — update problems, rollback — ElevenForum](https://www.elevenforum.com/t/windows-11-iot-ltsc-enterprise-25h2-update-problems-rollback.43830/)
- [LCU error 0x800f0838 after in-place upgrade 24H2 — Broadcom Community](https://community.broadcom.com/discussion/lcu-error-0x800f0838-after-inplace-upgrade-win11-24h2)

**Инструменты**
- [ntdevlabs/tiny11builder — tiny11maker.ps1](https://raw.githubusercontent.com/ntdevlabs/tiny11builder/main/tiny11maker.ps1) · [tiny11Coremaker.ps1](https://raw.githubusercontent.com/ntdevlabs/tiny11builder/main/tiny11Coremaker.ps1)
- [chrisGrando/tiny11maker-reforged](https://github.com/chrisGrando/tiny11maker-reforged)
- [ChrisTitusTech/winutil — коммит «Remove microwin (#3999)», 06.02.2026](https://github.com/ChrisTitusTech/winutil/commit/fcc548147783b03b6fc2e26e1278b86f09a4aa40) · [MicroWin — DeepWiki](https://deepwiki.com/ChrisTitusTech/winutil/7-microwin-iso-customization) · [форк fortunamagix/winutil-Microwin](https://github.com/fortunamagix/winutil-Microwin)
- [yusufklncc/winisoutil](https://github.com/yusufklncc/winisoutil) · [NicoUnterburger/WinISO-deBloater](https://github.com/NicoUnterburger/WinISO-deBloater)
- [itsNileshHere/Windows-ISO-Debloater (AI-компоненты, IMAPI2FS)](https://github.com/itsNileshHere/Windows-ISO-Debloater)
- [MSMG Toolkit 13.7 — MajorGeeks](https://www.majorgeeks.com/files/details/msmg_toolkit.html) · [MSMG Toolkit: Decrapify Windows 11 25H2 — muso.sk](https://www.muso.sk/decrapify-windows-11-with-msmg-toolkit)
- [memstechtips/UnattendedWinstall](https://github.com/memstechtips/UnattendedWinstall) · [Winhance releases](https://github.com/memstechtips/Winhance/releases) · [WIMUtil (архив)](https://github.com/memstechtips/WIMUtil)
- [AveYo/MediaCreationTool.bat](https://github.com/AveYo/MediaCreationTool.bat)
- [Rufus 4.14 — Quality of Life Enhancements (memstechtips)](https://memstechtips.com/rufus-update-windows-11-customizations/) · [Rufus adds 24H2 bypass, local account fix — Neowin](https://www.neowin.net/news/rufus-adds-windows-11-24h2-unsupported-pc-bypass-for-in-place-upgrades-local-account-fix/)
- [wimlib — Compression](https://wimlib.net/compression.html) · [wimlib vs DISM performance](https://wimlib.net/forums/viewtopic.php?t=338)

**Отдельные приёмы**
- [WinSxS\Backup folder question — NTLite Forums (последствия удаления)](https://ntlite.com/community/threads/winsxs-backup-folder-question.4054/)
- [Removing Windows Component Store (WinSxS) — NTLite Forums](https://ntlite.com/community/threads/removing-windows-component-store-winsxs.3154/)
- [How can I reduce "assembly" and "Microsoft.NET" — WinReducer forum (NativeImages)](https://winreducer.forumotion.com/t358-answered-how-can-i-reduce-assembly-and-microsoft-net)
- [IFileSystemImage2::put_BootImageOptionsArray — IMAPI2FS (Microsoft Learn)](https://learn.microsoft.com/en-us/windows/win32/api/imapi2fs/nf-imapi2fs-ifilesystemimage2-put_bootimageoptionsarray)
- [Tiny11 Core shrinks Windows 11 ISO to 2 GB — Tom's Hardware (CompactOS)](https://www.tomshardware.com/news/tiny11-core-shrinks-windows-11-iso-to-2gb-installation-to-33gb)
- [How to empty the LCU folder in Win11 — ElevenForum](https://www.elevenforum.com/t/how-to-empty-the-lcu-folder-in-win11.3948/)
