# Windows 11 26H1 Home/Pro и Store/MSIX

Проверка и доработка от 12.09.2026. Файл `Ru_Windows_11_26H1_28000.2704.ISO` прочитан без изменения образов. Исследованы метаданные обоих WIM, манифесты приложений и копии реестра обеих редакций. Скрипт теперь готовит инструменты ветки 28000 и локальную учётную запись для Home/Pro; полная сборка и установка 26H1 в VM пока не выполнены.

## Состав проверенного ISO

| Образ | Индекс | Редакция | Архитектура | Версия | Язык |
|---|---:|---|---|---|---|
| install.wim | 1 | Home / `Core` | x64 | 28000.2704 | ru-RU |
| install.wim | 2 | Pro / `Professional` | x64 | 28000.2704 | ru-RU |
| boot.wim | 1 | Windows PE | x64 | 28000.2704 | ru-RU |
| boot.wim | 2 | Windows Setup | x64 | 28000.2704 | ru-RU |

ISO занимает 8 900 300 800 байт. Сборщик экспортирует **одну выбранную редакцию**; Home и Pro собираются отдельными запусками. Размер будущего облегчённого ISO не определялся.

Русский язык уже есть в Windows и установщике. Для этого ISO не нужны `-DownloadLanguage ru-RU`, повторный языковой LCU или пакеты WinPE от 26100. Автозагрузка языка установщика для ветки 28000 пока не настроена; при смене языка нужен соответствующий источник WinPE 28000.

## Что сохраняет balanced

| Компонент в обеих редакциях | Версия | Назначение |
|---|---|---|
| Microsoft.WindowsStore | 22503.1400.1.0 | Каталог, установка и обновления приложений |
| Microsoft.StorePurchaseApp | 22408.1400.1.0 | Покупки и лицензирование Store |
| Microsoft.DesktopAppInstaller | 1.24.25199.0 | App Installer и winget |
| Microsoft.UI.Xaml.2.8 | 8.2310.30001.0 | Интерфейс приложений |
| Microsoft.VCLibs.140.00 | 14.0.33519.0 | Библиотеки Visual C++ |
| Microsoft.VCLibs.140.00.UWPDesktop | 14.0.33728.0 | Библиотеки Visual C++ для настольных пакетов |
| Microsoft.NET.Native.Framework.2.2 | 2.2.29512.0 | .NET Native framework |
| Microsoft.NET.Native.Runtime.2.2 | 2.2.28604.0 | .NET Native runtime |

Также сохраняются имеющиеся Windows App Runtime 1.4–1.7, другие framework-пакеты, компоненты входа в учётную запись и WebView2. В `safe` и `balanced` Store, App Installer и перечисленные семейства зависимостей явно защищены от удаления; та же защита передаётся guard. Состав `max` не изменён.

App Installer отвечает за установку двойным щелчком по `.msix`, `.msixbundle`, `.appx`, `.appxbundle` и `.appinstaller`. Это отдельное от магазина приложение. Microsoft подтверждает этот способ установки в [документации App Installer](https://learn.microsoft.com/en-us/windows/msix/app-installer/app-installer-root). Сам MSIX — установочный пакет; установленные приложения запускаются через меню Пуск и зарегистрированные ярлыки.

В проверенном ISO присутствуют `AppInstaller.exe`, `winget.exe` и обработчики указанных расширений. Все 24 прямые зависимости Store/App Installer/StorePurchaseApp в двух редакциях удовлетворены. Среди зависимостей остальных сохраняемых приложений также не найдено отсутствующих или выбранных для удаления пакетов. Это проверка манифестов и правил, а не запуск приложений в установленной Windows.

В исходном реестре `AppXSvc`, `StateRepository` и `mpssvc` имеют Start=2; `ClipSVC`, `InstallService`, `LicenseManager`, `AppReadiness`, `TokenBroker`, `BITS`, `wuauserv`, `DoSvc` — Start=3. Скрипт и guard не отключают эти службы. Постоянных политик запрета Store в исходном образе и правилах сборщика не найдено. Временная блокировка сети и Windows Update снимается финализатором после OOBE.

После уточнения состава `balanced` 13.09.2026 из 62 семейств приложений в каждой редакции правила сохраняют 44, включая библиотеки. К прежним 12 удалениям (Clipchamp, BingNews, BingWeather, Copilot, GetHelp, MicrosoftOfficeHub, Solitaire, OutlookForWindows, SecHealthUI, FeedbackHub, YourPhone и MSTeams) добавлены Microsoft.ZuneMusic (современный Media Player), Microsoft.GamingApp (Xbox), Microsoft.XboxGamingOverlay (Game Bar), Microsoft.XboxSpeechToTextOverlay, Microsoft.Todos (To Do) и MicrosoftCorporationII.MicrosoftFamily (Family). Для других образов учтены также ZuneVideo, XboxApp и XboxGameOverlay. Эти правила передаются guard и учитывают `-Keep WMP` / `-Keep Apps`. Paint, Photos, Calculator, Notepad, Terminal, медиакодеки, Xbox Identity Provider и Xbox TCUI сохраняются. Новый результат удаления ещё требует пересборки и проверки в VM.

`-WithWinget` не обязателен для сохранения имеющегося App Installer/winget. Без этого параметра остаётся версия из ISO; с ним подготавливается дополнительный пакет для интеграции. Мастер проверяет наличие winget в выбранном индексе и пропускает вопрос о загрузке, если winget уже встроен. Удаление или отключение App Installer/winget не предлагается. Сохранение компонентов не добавляет отсутствующий Store в исходный LTSC.

## Исправления по результатам проверки

- Билд 28000 больше не определяется как 25H2: используются версия 26H1, каталоги `lcu-26H1` / `dotnet-26H1` и запросы этой ветки. Неизвестные ветки не получают обновления от другой версии по умолчанию.
- `EI.CFG` для Home/Pro получает `Retail` и `VL=0`. Для корпоративных редакций признак VL задаётся отдельно: значение `Volume` в поле Channel заменено допустимым `Retail`. Формат подтверждён [документацией Microsoft](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-edition-configuration-and-product-id-files--eicfg-and-pidtxt?view=windows-10). Существующий `EI.CFG` исходного носителя сохраняется.
- Сохранение Store/MSIX закреплено в правилах удаления и guard; план больше не пишет «winget: нет», когда компонент просто не добавляется отдельно.
- Паспорт WIM/ESD читается непосредственно из XML-ресурса с проверкой границ файла и запретом внешних XML-сущностей. Для выбора редакции и DryRun не нужны старый системный DISM или 7-Zip. Уже подключённый пользователем ISO не отключается мастером.
- DISM выбирается по версии образа. Для 26H1 старый DISM 26100 заменяется в конкретном запуске отдельным комплектом DISM 28000 из кэша. Девять CAB (~6,3 МиБ) и 194 извлечённых файла проверяются по SHA256; установленный ADK остаётся на месте. Кэш повторно использован при запрещённой загрузке. Без обязательных инструментов сборка останавливается до изменения образа. Для собственного комплекта есть `-DismPath`.
- Режим `auto` теперь предлагает одинаковый выбор для всех поддерживаемых версий и редакций: 1 — ввод пользователя при установке Windows (по умолчанию), 2 — до сборки ISO. При предварительном задании Windows получает стандартный блок `UserAccounts/LocalAccounts`; пароль передаётся как SecureString, в ISO записывается с кодированием Windows, без автоматического входа. Кодирование восстановимо и не защищает пароль при передаче ISO другим людям. `-AccountMode setup` оставляет ввод учётной записи установщику, а `-Unattend` сохраняет управление собственным answer-файлом. [Описание LocalAccounts](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-useraccounts-localaccounts).
- Answer-файл явно выбирает итоговый индекс 1 после экспорта любой исходной редакции. Для Home/Pro при отсутствии ключа не создаётся пустой элемент `Key`, а `WillShowUI=OnError` оставляет возможность ввести ключ при ошибке. [Формат ключа](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-setup-userdata-productkey-key), [показ интерфейса](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-setup-userdata-productkey-willshowui).

На дату проверки реальный запрос Microsoft Update Catalog вернул для x64 LCU KB5124012 / 28000.2954 и .NET KB5126053. Пакеты не скачивались и не применялись. Версия исходного образа 28000.2704 соответствует [KB5121000](https://support.microsoft.com/en-us/servicing/os/windows-11/2026/08/kb5121000-windows-11-26h1-security-update).

## Что ещё требует VM

1. Обслуживание обоих WIM и итоговая загрузка. Реально подготовлен Microsoft-signed DISM 10.0.28000.1 x64 из ADK; его запуск в доступном неадминистративном процессе вернул 740 — требуются повышенные права. Это не проверка обслуживания. Microsoft описывает ADK 28000 как комплект для 26H1 Arm64; наличие x64-инструментов подтверждено содержимым пакетов, а успешное обслуживание конкретного ISO следует проверить полным прогоном. [Матрица ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install).
2. Создание локальной учётной записи в Home и Pro через новый `LocalAccounts`, запрос ключа и первый вход. Подтверждённое завершение OOBE на IoT LTSC 24H2 не доказывает такое же поведение потребительских редакций 26H1. Для LTSC доступен тот же выбор способа создания аккаунта; по умолчанию пользователь вводится при установке.
3. Store: открытие, установка/обновление приложения и лицензирование после возврата сети. App Installer: установка подписанного MSIX с подходящими зависимостями. Затем повторный вход с guard и повторная проверка приложения.
4. Отдельно — `-LegacySetup`, `-RemoveWinRE`, `-TrimSources` и интеграция новых LCU. Эти сочетания на 28000 ещё не проверены.

Microsoft описывает 26H1 как выпуск для определённых новых аппаратных платформ, а не массовое обновление существующих компьютеров. Наличие x64 ISO и пакетов в каталоге не заменяет проверку конкретного оборудования. [Статус 26H1](https://learn.microsoft.com/en-us/windows/release-health/status-windows-11-26H1).

## Проверки скрипта и первый запуск

Наборы обслуживания (55), основной (164), загрузок (80), языка установщика (54), совместимости (61) и guard (41) прошли на PowerShell 5.1 и 7; неизменённые наборы имеют предыдущие успешные прогоны. Суммарно в проекте 691 проверка на версию. Реальный DryRun Home прошёл на PowerShell 7, Pro — на 5.1; отдельно проверен прежний LTSC. Реальная подготовка CAB и повторное использование инструментов без загрузки проверены отдельно от тестов с заглушками. Обслужование WIM и guard на хосте не запускались.

Проверить план Pro:

```powershell
.\win-11-lite.ps1 -InputIso .\iso\Ru_Windows_11_26H1_28000.2704.ISO `
    -Edition Professional -Preset balanced -DryRun
```

Для Home заменить `Professional` на `Core`. Для первой сборки в VM убрать `-DryRun`, добавить `-Guard Debug` и задать пользователя в появившемся диалоге. Для запуска без вопросов об аккаунте указать `-LocalUserName User`; необязательный пароль — `-LocalUserPassword (Read-Host -AsSecureString)`. Без пароля получится локальный аккаунт с пустым паролем. Язык и App Installer уже есть в исходном образе.
