<#
.SYNOPSIS
    Собирает облегчённый (lite) ISO из оригинального образа Windows 11.

.DESCRIPTION
    Универсальный сборщик: работает с любым оригинальным ISO Windows 11 — редакция,
    язык и версия определяются из самого образа.
    Для запуска достаточно этого PS1: каталоги загрузок и служебные сценарии
    встроены в файл. Скачивать папки data или tools рядом со сборщиком не требуется.

    Что делается всегда (пресет balanced):
      * удаляется браузер Edge (WebView2 остаётся — он нужен обычным программам),
        Defender, распознавание и синтез речи, OCR, Media Player, Internet Explorer,
        CJK-шрифты, Paint, Steps Recorder, диагностика;
      * вырезаются Recall, Copilot, AI Fabric и прочие AI-компоненты — файлами
        и политиками сразу;
      * отключаются телеметрия, реклама и «рекомендации» в offline-реестре;
      * остаются нетронутыми Hyper-V, WSL, контейнеры и рабочий Windows Update;
      * на общий рабочий стол кладётся ярлык Install-Firefox;
      * встраивается обход проверок TPM 2.0 и Secure Boot;
      * обновления отключаются на время установки и включаются сразу после неё;
      * итоговый ISO собирается через oscdimg.

    Все загрузки выполняются до копирования и обработки образа. При ошибке
    можно продолжить без компонента или отменить сборку. Полный проверенный
    кэш позволяет собирать без сети; -ClearCache заставляет скачать его заново.

    Только по явным ключам: обновления (-WithUpdates), winget (-WithWinget),
    языки (-DownloadLanguage), классический установщик (-LegacySetup),
    удаление WinRE (-RemoveWinRE), урезание sources (-TrimSources).

    Запуск без параметров открывает диалог с вопросами и сам запрашивает права
    администратора. Справка: Get-Help .\win-11-lite.ps1 -Full

.EXAMPLE
    .\win-11-lite.ps1

    Запуск без параметров: скрипт покажет список ISO рядом с собой, спросит
    редакцию, рабочую папку, язык и остальное, запросит права администратора.

.EXAMPLE
    .\win-11-lite.ps1 -InputIso .\iso\en-us_..._ltsc_2024_x64_dvd_f6b14814.iso -Index 2

    Минимальная сборка: без обновлений, без winget, со штатным установщиком.

.EXAMPLE
    .\win-11-lite.ps1 -InputIso .\iso\original.iso -Index 2 -LegacySetup -RemoveWinRE -TrimSources

    Самый компактный образ (примерно на 650 МБ меньше). Классический установщик
    позволяет обойтись без winre.wim; ставится только загрузкой с носителя.

.EXAMPLE
    .\win-11-lite.ps1 -InputIso .\iso\en-us.iso -Index 2 -DownloadLanguage ru-RU

    Скачивает русский языковой пакет с серверов Microsoft (около 37 МБ)
    и делает русский языком системы по умолчанию. Для обновлённого ISO также
    повторно применяется исходный LCU: для 26100.1742 это KB5043080 (~509 МБ).
    Установщик также переводится на русский: при первом запуске нужен архив
    WinPE (~305 МБ). Оставить язык установщика исходным: -SetupLanguage original.

.EXAMPLE
    .\win-11-lite.ps1 -InputIso .\iso\original.iso -Index 2 -WithUpdates -WithWinget -Debug

    Встраивает последнее накопительное обновление и winget, пишет подробный лог
    работы и лог DISM в подпапку log.

.EXAMPLE
    .\win-11-lite.ps1 -InputIso .\iso\original.iso -DryRun

    Показывает паспорт образа и план работ, ничего не меняя.
    Права администратора не нужны.

.NOTES
    Требуется: права администратора (запрашиваются автоматически),
    Windows ADK с компонентом Deployment Tools, свободное место — около 30 ГБ,
    а с ключом -WithUpdates около 45 ГБ.

    Язык сообщений выбирается по языку Windows, переопределяется ключом -UILang.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    # Исходный ISO. Если не указан, скрипт покажет список ISO-файлов рядом
    # с собой и предложит выбрать.
    [Parameter(Position = 0)]
    [Alias('Iso', 'Source')]
    [string]$InputIso,

    # Готовый ISO. По умолчанию: <папка скрипта>\out\<имя исходника>_lite.iso
    [Alias('Out')]
    [string]$OutputIso,

    # Рабочий каталог. Удаляется после сборки (если не задан -KeepWorkDir).
    # По умолчанию — временная папка Windows; если на её диске меньше 40 ГБ,
    # скрипт сам перенесёт работу на локальный диск с наибольшим свободным местом.
    [Alias('TmpDir', 'Temp', 'Work')]
    [string]$WorkDir,

    # Кэш скачанных обновлений. НЕ удаляется между прогонами.
    # По умолчанию — папка updates рядом с рабочим каталогом.
    [Alias('Updates')]
    [string]$UpdatesDir,

    # Индекс образа внутри install.wim. Обязателен, если редакций в образе
    # несколько: скрипт покажет список и остановится, пока вы не выберете.
    [int]$Index = 0,

    # Выбор образа по EditionID (альтернатива -Index), например IoTEnterpriseS.
    [string]$Edition,

    # Профиль чистки.
    [ValidateSet('safe', 'balanced', 'max')]
    [string]$Preset = 'balanced',

    # Что оставить вопреки пресету.
    [ValidateSet('Defender', 'WinRE', 'Edge', 'Fonts', 'Speech', 'WMP', 'IE', 'Sandbox', 'AI', 'Apps', 'OneDrive', 'NativeImages')]
    [string[]]$Keep = @(),

    # Дополнительные regex для удаления пакетов и возможностей.
    [string[]]$RemoveExtra = @(),

    # Скачать и встроить последние обновления. Без этого флага образ собирается
    # на исходном билде, а патчи приезжают через Windows Update после установки —
    # это экономит около 1.5 ГБ в готовом ISO.
    [Alias('Update')]
    [switch]$WithUpdates,

    # Откуда брать обновления. Задавать вручную нужно только для режима local
    # (свои .msu в -UpdatesDir); -WithUpdates включает 'download'.
    [ValidateSet('download', 'local', 'none')]
    [string]$UpdateMode = 'none',

    # Интегрировать накопительное обновление для .NET Framework.
    [bool]$IncludeDotNetUpdate = $true,

    # Встроить winget (App Installer) в образ. По умолчанию не ставится —
    # это ~300 МБ загрузки с GitHub и лишний компонент в образе.
    [Alias('Winget')]
    [switch]$WithWinget,

    # Не встраивать обход TPM / Secure Boot.
    [switch]$NoBypass,

    # Не отключать сеть на время OOBE. По умолчанию адаптеры выключаются в проходе
    # specialize и включаются обратно при первом входе — иначе Windows 11 24H2
    # на экране «Получение новейших функций и обновлений» скачивает и ставит
    # обновления мимо всех политик Windows Update. С этим флагом экран вернётся.
    [switch]$NoOobeNetworkBlock,

    # Запускать классический установщик вместо нового (ConX/MoSetup).
    # В boot.wim кладётся winpeshl.ini с вызовом sources\setup.exe /legacy.
    # Новый установщик 24H2 обязательно извлекает winre.wim в SafeOS —
    # классический этого не делает, поэтому только с этим флагом имеет смысл
    # -RemoveWinRE и -TrimSources.
    [Alias('Legacy')]
    [switch]$LegacySetup,

    # Удалить среду восстановления (winre.wim, ~508 МБ).
    # Без -LegacySetup установка упадёт с 0x80070003: новый установщик
    # Windows 11 извлекает winre.wim в SafeOS на этапе подготовки.
    [switch]$RemoveWinRE,

    # Сохранить копию winre.wim рядом с готовым ISO (файл *_winre.wim, ~508 МБ).
    # Нужна, только если потом планируете вернуть среду восстановления
    # через reagentc. Без этого ключа файл просто удаляется.
    [Alias('KeepWinRE')]
    [switch]$SaveWinRE,

    # Оставить в sources boot.wim, install.*, EI.CFG и ресурсы выбранного установщика.
    # Установка с носителя работает, запуск setup.exe из работающей Windows — нет.
    [switch]$TrimSources,

    # Ставить систему в сжатом виде (CompactOS, LZX) — экономит ~2 ГБ на диске,
    # ценой небольшой нагрузки на процессор при чтении системных файлов.
    [switch]$CompactOS,

    # Встроить в образ сторожевой скрипт. При каждом входе пользователя он
    # проверяет, не вернули ли обновления удалённые компоненты и не сброшены ли
    # политики, и при необходимости убирает их снова.
    [Alias('Watchdog')]
    [switch]$Guard,

    # Standard: только итог; Debug: живой журнал; Silent: отчёты только в файлах.
    [ValidateSet('Debug','Standard','Silent')]
    [string]$GuardMode = 'Standard',
    # Совместимость со старыми командами: true -> Debug, false -> Silent.
    [switch]$GuardDebug,

    # Языки, которые надо встроить в образ: ru-RU, de-DE, fr-FR и любые другие.
    # Первый в списке становится языком интерфейса по умолчанию.
    # Требует -LanguageSource. Без этого ключа языки не трогаются вовсе.
    [Alias('Language', 'Lang')]
    [string[]]$AddLanguage,

    # Откуда брать языковые пакеты: ISO «Languages and Optional Features»
    # (для 24H2 в нём объединены LP, LIP и FoD) либо папка с распакованными .cab.
    [Alias('LangSource')]
    [string]$LanguageSource,

    # Скачать языковые пакеты вместо использования локального источника.
    # Файлы берутся с CDN Microsoft (tlu.dl.delivery.mp.microsoft.com), список
    # ссылок — через каталог uupdump.net. Проверяются по SHA-256.
    [Alias('DownloadLang')]
    [string[]]$DownloadLanguage,

    # Язык установщика: auto = первый добавляемый язык Windows; original = язык ISO.
    # Отдельные пакеты WinPE скачиваются заранее (для build 26100, x64).
    [string]$SetupLanguage = 'auto',

    # Необязательный локальный источник: каталог WinPE_OCs из ADK/LoF.
    [string]$SetupLanguageSource,

    # LCU для языковых ресурсов boot.wim, если его ревизия не известна сборщику.
    [string]$SetupLanguageUpdatePath,

    # LCU для повторного обслуживания языков (MSU той же или более новой версии).
    # Для исходного LTSC 26100.1742 при -DownloadLanguage автоматически берётся
    # KB5043080. Это не обновление до последней версии Windows.
    [string]$LanguageUpdatePath,

    # Для локального кэша с несколькими MSU: явные имена целевых обновлений.
    [string]$LcuFile,
    [string]$DotNetUpdateFile,


    # Разрешить /ResetBase: установленные обновления станут неудаляемыми.
    # По умолчанию только /StartComponentCleanup, как в процедуре Microsoft
    # для offline-медиа с checkpoint-обновлениями. Совместимость конкретного
    # образа после ResetBase с последующим обслуживанием нужно проверять в VM.
    [switch]$ResetBase,

    # Ключ продукта для autounattend. Для корпоративных редакций (LTSC,
    # Enterprise) не нужен: канал и редакция задаются через EI.CFG, а ключ
    # вводится уже после установки.
    [string]$ProductKey,

    # auto: для Home/Pro 26H1 задаём локальный аккаунт до сборки; setup — ввод в Windows.
    [ValidateSet('auto','image','setup')]
    [string]$AccountMode = 'auto',
    [string]$LocalUserName,
    [Security.SecureString]$LocalUserPassword,

    # Свой autounattend.xml, либо 'none' чтобы не класть его вовсе.
    [string]$Unattend,

    # Сжатие итогового образа: recovery = install.esd (меньше), max = install.wim (быстрее ставится).
    [ValidateSet('recovery', 'max')]
    [string]$Compression = 'recovery',

    # Папка с драйверами для интеграции (рекурсивно).
    [string]$DriversDir,

    # Остановиться на готовом install.esd, ISO не собирать.
    [switch]$SkipIso,

    # Не удалять рабочий каталог после сборки.
    [switch]$KeepWorkDir,

    # Очистить кэш обновлений перед стартом.
    [switch]$ClearCache,

    # Установить Windows ADK (Deployment Tools), если он не найден.
    [switch]$InstallAdk,

    # Явный путь к совместимому dism.exe; иначе выбирается подходящий комплект.
    [string]$DismPath,

    # Файл лога. Если не задан, лог пишется только при -Debug — в подпапку log
    # рядом со скриптом, с именем <имя исходного ISO>_<дата-время>.log.
    # Технические сообщения — в соседнем .details.log, журнал DISM — в .dism.log.
    [string]$LogFile,

    # Показать план и оценки, ничего не менять. Работает без прав администратора.
    [switch]$DryRun,

    # Задать параметры в диалоге. Включается само, если скрипт запущен без единого
    # параметра — например, двойным щелчком.
    [Alias('Wizard')]
    [switch]$Interactive,

    # Язык сообщений скрипта. По умолчанию: русский на русской Windows,
    # английский на любой другой.
    [ValidateSet('auto', 'ru', 'en')]
    [Alias('Locale')]
    [string]$UILang = 'auto',

    # Не ждать нажатия клавиши перед выходом. Нужно для запуска по расписанию
    # и из других скриптов.
    [switch]$NoPause,

    # Служебный: скрипт сам ставит его при перезапуске с правами администратора.
    # Вручную передавать не нужно.
    [switch]$Elevated
)

# -Debug включает файлы диагностики, сохраняя обычный вид консоли.
$script:DebugMode = $PSBoundParameters.ContainsKey('Debug') -and [bool]$PSBoundParameters['Debug']
if ($script:DebugMode -or $LogFile) {
    $DebugPreference = 'SilentlyContinue'
    $VerbosePreference = 'SilentlyContinue'
}

$script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# Язык сообщений: смотрим на язык интерфейса Windows, затем на язык системы
$script:Lang = $UILang
if ($script:Lang -eq 'auto') {
    $ui = ''
    try { $ui = (Get-UICulture).Name } catch { }
    if (-not $ui) { $ui = $PSUICulture }
    if (-not $ui) { try { $ui = (Get-Culture).Name } catch { } }
    $script:Lang = if ($ui -like 'ru*') { 'ru' } else { 'en' }
}

# Возвращает сообщение на текущем языке. Обе строки уже интерполированы,
# поэтому подстановка значений работает сама собой.
function T {
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Ru,
          [Parameter(Position = 1)][AllowEmptyString()][string]$En)
    if ($script:Lang -eq 'en' -and $PSBoundParameters.ContainsKey('En')) { return $En }
    $Ru
}

# Запуск без параметров (двойной щелчок, «Выполнить с помощью PowerShell») —
# значит, человек ждёт диалога, а не молчаливого отказа
$script:WizardMode = $Interactive -or ($PSBoundParameters.Count -eq 0) -or ($Elevated -and $PSBoundParameters.Count -eq 1)

# Паузу держим там, где окно закроется само: диалог или перезапуск от администратора
$script:PauseOnExit = $script:WizardMode -or $Elevated
if($PSBoundParameters.ContainsKey('GuardDebug')){
    $legacyGuardMode=if($GuardDebug){'Debug'}else{'Silent'}
    if($PSBoundParameters.ContainsKey('GuardMode') -and $GuardMode -ne $legacyGuardMode){throw (T 'GuardMode противоречит GuardDebug; укажите один режим guard.' 'GuardMode conflicts with GuardDebug; specify one guard mode.')}
    $GuardMode=$legacyGuardMode
}

function Test-CanPrompt {
    -not [Console]::IsInputRedirected -and [Environment]::UserInteractive
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Окно, открытое двойным щелчком, закрывается вместе с процессом — без паузы
# человек не успевает прочитать ни итог, ни текст ошибки.
# Способы чтения клавиши перебираем по очереди: в pwsh, запущенном через -File,
# RawUI.ReadKey доступен не всегда, поэтому одного варианта мало.
function Wait-BeforeExit {
    if ($NoPause -or -not $script:PauseOnExit) { return }
    try { if ([Console]::IsInputRedirected) { return } } catch { return }

    Write-Host ''
    Write-Host (T '  Нажмите любую клавишу для выхода...' '  Press any key to exit...') -ForegroundColor DarkCyan

    try {
        $null = [Console]::ReadKey($true)
        return
    } catch { }
    try {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return
    } catch { }
    try {
        $null = Read-Host
        return
    } catch { }
    # Совсем крайний случай: дать хотя бы прочитать текст
    Start-Sleep -Seconds 20
}

# Перезапуск с запросом прав администратора: собираем ту же команду обратно
function Get-ElevationCommand {
    param([string]$ScriptPath, [Collections.IDictionary]$Parameters)
    $forward = @{}
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [switch]) { $value = [bool]$value }
        $forward[$key] = $value
    }
    $forward['Elevated'] = $true
    $serialized = [Management.Automation.PSSerializer]::Serialize($forward)
    $payload = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($serialized))
    $quotedPath = $ScriptPath.Replace("'", "''")
    $command = "`$forward = [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$payload'))); & '$quotedPath' @forward"
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
}

function Restart-Elevated {
    param([Collections.IDictionary]$Parameters)
    $scriptPath = $MyInvocation.ScriptName
    if (-not $scriptPath) { $scriptPath = Join-Path $script:ScriptRoot 'win-11-lite.ps1' }

    # PowerShell 7 и Windows PowerShell запускаются разными исполняемыми файлами
    $host7 = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
    if (-not $host7 -or $host7 -notmatch '(pwsh|powershell)\.exe$') {
        $host7 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    }

    $encoded = Get-ElevationCommand -ScriptPath $scriptPath -Parameters $Parameters
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)

    Write-Host ''
    Write-Host (T '  Для работы с образами нужны права администратора.' '  Administrator rights are required to service images.') -ForegroundColor Yellow
    Write-Host (T '  Перезапускаю скрипт — подтвердите запрос системы.' '  Restarting the script - please confirm the system prompt.') -ForegroundColor Yellow
    try {
        Start-Process -FilePath $host7 -ArgumentList $argList -WorkingDirectory (Get-Location).Path -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Host ''
        Write-Host (T '  Запуск от имени администратора отменён.' '  Elevation was cancelled.') -ForegroundColor Red
        Write-Host (T '  Откройте PowerShell от имени администратора и запустите скрипт оттуда.' '  Open PowerShell as administrator and run the script from there.') -ForegroundColor Red
        $script:PauseOnExit = $true
        Wait-BeforeExit
        exit 1
    }
}

function Read-YesNo {
    param([string]$Question, [bool]$Default = $false)
    $hint = if ($Default) { T '[Да/нет]' '[Yes/no]' } else { T '[да/Нет]' '[yes/No]' }
    while ($true) {
        $answer = (Read-Host "  $Question $hint").Trim().ToLower()
        if (-not $answer) { return $Default }
        if ($answer -in @('д', 'да', 'y', 'yes', '1', '+')) { return $true }
        if ($answer -in @('н', 'нет', 'n', 'no', '0', '-')) { return $false }
        Write-Host (T '  Ответьте «да» или «нет» (Enter — значение по умолчанию).' '  Answer yes or no (Enter keeps the default).') -ForegroundColor Yellow
    }
}

function Read-Option {
    param(
        [string]$Question,
        [string[]]$Items,          # что показываем
        [string[]]$Values,         # что возвращаем; по умолчанию совпадает с Items
        [int]$Default = 1
    )
    if (-not $Values) { $Values = $Items }
    Write-Host ''
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $mark = if ($i + 1 -eq $Default) { '*' } else { ' ' }
        Write-Host ("   {0}{1,2}. {2}" -f $mark, ($i + 1), $Items[$i])
    }
    Write-Host ''
    while ($true) {
        $answer = (Read-Host "  $Question (1-$($Items.Count), Enter — $Default)").Trim()
        if (-not $answer) { return $Values[$Default - 1] }
        if ($answer -match '^\d+$') {
            $n = [int]$answer
            if ($n -ge 1 -and $n -le $Items.Count) { return $Values[$n - 1] }
        }
        Write-Host (T "  Введите число от 1 до $($Items.Count)." "  Enter a number between 1 and $($Items.Count).") -ForegroundColor Yellow
    }
}

function Read-PathOrDefault {
    param([string]$Question, [string]$Default)
    $answer = (Read-Host "  $Question`n  [Enter — $Default]").Trim().Trim('"')
    if (-not $answer) { return $Default }
    $answer
}

# XML-паспорт WIM/ESD читается без монтирования и без версии DISM на хосте.
# XML resource в заголовке WIM не сжат, даже у install.esd с LZMS-сжатием данных.
function Get-WimImageList {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $header = $reader.ReadBytes(208)
        if ($header.Length -ne 208 -or [Text.Encoding]::ASCII.GetString($header,0,8) -ne "MSWIM`0`0`0") {
            throw (T 'Некорректный заголовок WIM/ESD' 'Invalid WIM/ESD header')
        }
        $resource = [BitConverter]::ToUInt64($header,72)
        $length = $resource -band [uint64]0x00FFFFFFFFFFFFFF
        $offset = [BitConverter]::ToUInt64($header,80)
        $original = [BitConverter]::ToUInt64($header,88)
        if (($header[79] -band 4) -or $length -ne $original -or $length -lt 2 -or $length -gt 16MB -or
            $offset -lt 208 -or $offset -gt [uint64]$stream.Length -or $length -gt ([uint64]$stream.Length - $offset)) {
            throw (T 'Недоступный или повреждённый XML-паспорт WIM/ESD' 'Unsupported or damaged WIM/ESD XML metadata')
        }
        $null = $stream.Seek([int64]$offset,[IO.SeekOrigin]::Begin)
        $bytes = $reader.ReadBytes([int]$length)
        if ($bytes.Length -ne $length) { throw (T 'XML-паспорт WIM/ESD прочитан не полностью' 'Incomplete WIM/ESD XML metadata') }
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $text = [IO.StringReader]::new([Text.Encoding]::Unicode.GetString($bytes).TrimStart([char]0xFEFF))
        $xmlReader = [Xml.XmlReader]::Create($text,$settings)
        try { $xml = [xml]::new(); $xml.XmlResolver=$null; $xml.Load($xmlReader) } finally { $xmlReader.Dispose(); $text.Dispose() }
    } finally { $reader.Dispose(); $stream.Dispose() }
    $entries = @($xml.WIM.IMAGE)
    if (-not $entries.Count -or $entries.Count -ne [BitConverter]::ToUInt32($header,44)) { throw (T 'Число индексов в WIM/ESD не совпадает с паспортом' 'WIM/ESD image count does not match its metadata') }
    foreach ($entry in $entries) {
        # Первым оставляем основной язык: именно его выбирает план сборки.
        $languages = @([string]$entry.WINDOWS.LANGUAGES.DEFAULT) + @($entry.WINDOWS.LANGUAGES.LANGUAGE | ForEach-Object { [string]$_ })
        [PSCustomObject]@{
            Index        = [int]$entry.INDEX
            Name         = [string]$entry.NAME
            EditionId    = [string]$entry.WINDOWS.EDITIONID
            Architecture = [string]$entry.WINDOWS.ARCH
            Languages    = (($languages | Where-Object { $_ } | Select-Object -Unique) -join ',')
            Version      = '{0}.{1}.{2}.{3}' -f $entry.WINDOWS.VERSION.MAJOR,$entry.WINDOWS.VERSION.MINOR,$entry.WINDOWS.VERSION.BUILD,$entry.WINDOWS.VERSION.SPBUILD
            Size         = [int64]$entry.TOTALBYTES
        }
    }
}

# Читает список изданий из ISO, чтобы спросить о редакции до начала работы
function Get-IsoEditions {
    param([string]$Path)
    $result = @()
    $mounted = $null
    $owned = $false
    try {
        $mounted = Get-DiskImage -ImagePath $Path -ErrorAction Stop
        if (-not $mounted.Attached) { $mounted = Mount-DiskImage -ImagePath $Path -PassThru -Access ReadOnly -ErrorAction Stop; $owned = $true }
        Start-Sleep -Seconds 2
        $drive = "$(($mounted | Get-Volume).DriveLetter):"
        $wim = Join-Path $drive 'sources\install.wim'
        if (-not (Test-Path -LiteralPath $wim)) { $wim = Join-Path $drive 'sources\install.esd' }
        if (-not (Test-Path -LiteralPath $wim)) { return @() }
        $result = @(Get-WimImageList -Path $wim)
    } catch {
        Write-Host (T "  Не удалось прочитать образ: $($_.Exception.Message)" "  Could not read the image: $($_.Exception.Message)") -ForegroundColor Yellow
    } finally {
        if ($owned) { try { Dismount-DiskImage -ImagePath $Path | Out-Null } catch { } }
    }
    $result
}

# Выбор исходного ISO, когда параметр не задан: показываем всё, что лежит
# рядом со скриптом, вместо безликого запроса PowerShell «InputIso:»
function Select-InputIso {
    $roots = @($script:ScriptRoot)
    $roots += @(Get-ChildItem -LiteralPath $script:ScriptRoot -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^(\.ai|\.git|tmp|out|log)$' } |   # out — результаты, log — журналы
                Select-Object -ExpandProperty FullName)
    $cwd = (Get-Location).Path
    if ($cwd -ne $script:ScriptRoot -and (Test-Path -LiteralPath $cwd)) { $roots += $cwd }

    $found = @()
    foreach ($root in ($roots | Sort-Object -Unique)) {
        $found += @(Get-ChildItem -LiteralPath $root -Filter *.iso -File -ErrorAction SilentlyContinue)
    }
    $found = @($found | Sort-Object FullName -Unique | Sort-Object Length -Descending)

    Write-Host ''
    if ($found.Count -gt 0) {
        Write-Host (T "  ISO-файлы рядом со скриптом ($script:ScriptRoot):" "  ISO files next to the script ($script:ScriptRoot):") -ForegroundColor White
        Write-Host ''
        for ($i = 0; $i -lt $found.Count; $i++) {
            $rel = $found[$i].FullName
            if ($rel.StartsWith($script:ScriptRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $rel = $rel.Substring($script:ScriptRoot.Length).TrimStart('\')
            }
            Write-Host ("   {0,2}. {1,-70} {2,8}" -f ($i + 1), $rel, (Format-Size $found[$i].Length))
        }
    } else {
        Write-Host (T '  Рядом со скриптом ISO-файлов не найдено.' '  No ISO files found next to the script.') -ForegroundColor Yellow
    }
    $ownOption = $found.Count + 1
    Write-Host ((T "   {0,2}. Указать свой файл" "   {0,2}. Choose another file") -f $ownOption)
    Write-Host ''

    # IsInputRedirected надёжнее UserInteractive: при запуске из планировщика или
    # через пайп второй остаётся True, и Read-Host просто зависает
    if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) {
        throw (T 'Не указан -InputIso, а спросить интерактивно нельзя (ввод перенаправлен). Укажите файл параметром: -InputIso <путь>' '-InputIso was not provided and cannot be asked interactively (input is redirected). Pass the file explicitly: -InputIso <path>')
    }

    while ($true) {
        $answer = (Read-Host (T "  С каким файлом работать (1-$ownOption)" "  Which file should I use (1-$ownOption)")).Trim()
        if (-not $answer) { continue }
        if ($answer -match '^\d+$') {
            $n = [int]$answer
            if ($n -ge 1 -and $n -le $found.Count) { return $found[$n - 1].FullName }
            if ($n -eq $ownOption) {
                $path = (Read-Host (T '  Путь к ISO' '  Path to the ISO')).Trim().Trim('"')
                if ($path -and (Test-Path -LiteralPath $path)) { return (Resolve-Path -LiteralPath $path).Path }
                Write-Host (T '  Файл не найден, попробуйте ещё раз.' '  File not found, try again.') -ForegroundColor Yellow
                continue
            }
        }
        # Разрешаем и просто вставить путь вместо номера
        $maybePath = $answer.Trim('"')
        if (Test-Path -LiteralPath $maybePath) { return (Resolve-Path -LiteralPath $maybePath).Path }
        Write-Host (T "  Введите число от 1 до $ownOption или путь к файлу." "  Enter a number between 1 and $ownOption, or a file path.") -ForegroundColor Yellow
    }
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# -WithUpdates — удобный переключатель поверх -UpdateMode
if ($WithUpdates -and $UpdateMode -eq 'none') { $UpdateMode = 'download' }

# Заданы ли каталоги явно — важно: подбирать диск автоматически можно только
# тогда, когда пользователь не указал путь сам
$script:WorkDirExplicit    = $PSBoundParameters.ContainsKey('WorkDir')
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) 'win-11-lite-work' }

#region ── Что удаляем: таблицы ─────────────────────────────────────────────────

# Возможности Windows (Get-Capabilities). Имена не зависят от языка образа:
# regex ловит любой языковой суффикс.
$script:CapabilityRules = @(
    @{ Preset = 'balanced'; Group = 'Speech';   Pattern = '^Language\.(Handwriting|OCR|Speech|TextToSpeech)~';  Desc = (T 'Рукописный ввод, OCR, распознавание и синтез речи' 'Handwriting, OCR, speech recognition and synthesis') }
    @{ Preset = 'balanced'; Group = 'WMP';      Pattern = '^Media\.WindowsMediaPlayer~';                        Desc = (T 'Windows Media Player' 'Windows Media Player') }
    @{ Preset = 'balanced'; Group = 'Misc';     Pattern = '^Microsoft\.Windows\.MSPaint~';                      Desc = (T 'Классический Paint' 'Classic Paint') }
    @{ Preset = 'balanced'; Group = 'Misc';     Pattern = '^App\.StepsRecorder~';                               Desc = (T 'Steps Recorder' 'Steps Recorder') }
    @{ Preset = 'balanced'; Group = 'IE';       Pattern = '^Browser\.InternetExplorer~';                        Desc = (T 'Internet Explorer 11 (в 24H2 — заглушка)' 'Internet Explorer 11 (a stub in 24H2)') }
    @{ Preset = 'balanced'; Group = 'Defender'; Pattern = '^Microsoft\.Windows\.Sense\.Client~';                 Desc = (T 'Defender for Endpoint' 'Defender for Endpoint') }
    @{ Preset = 'max';      Group = 'Misc';     Pattern = '^Hello\.Face\.';                                     Desc = (T 'Windows Hello Face' 'Windows Hello Face') }
    @{ Preset = 'max';      Group = 'Misc';     Pattern = '^MathRecognizer~';                                   Desc = (T 'Распознавание формул' 'Math recognizer') }
    @{ Preset = 'max';      Group = 'Misc';     Pattern = '^Print\.Fax\.Scan~';                                 Desc = (T 'Факс и сканирование' 'Fax and scan') }
    @{ Preset = 'max';      Group = 'Misc';     Pattern = '^Microsoft\.Windows\.PowerShell\.ISE~';               Desc = (T 'PowerShell ISE' 'PowerShell ISE') }
)

# Пакеты компонентов.
# ВАЖНО (проверено на реальном образе 26100.9445): dism /Get-Packages показывает
# только пакеты верхнего уровня — FOD-компоненты, языковые пакеты и rollup'ы,
# всего около 50 штук. Внутренние компоненты из Windows\servicing\Packages
# (Recall, CJK-шрифты, Media Player, IE и прочие) входят в Foundation-пакет и
# через /Remove-Package недоступны — их убираем возможностями (CapabilityRules)
# либо файлами (FolderRules / FontPatterns).
$script:PackageRules = @(
    @{ Preset = 'balanced'; Group = 'Defender'; Pattern = '^Microsoft-Windows-SenseClient-FoD-Package';                Desc = (T 'Defender ATP (FOD)' 'Defender ATP (FOD)') }
    @{ Preset = 'balanced'; Group = 'Misc';     Pattern = '^Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package'; Desc = (T 'Дополнительные обои' 'Extra wallpapers') }
    @{ Preset = 'balanced'; Group = 'Misc';     Pattern = '^Microsoft-Windows-TabletPCMath-Package';                   Desc = (T 'Панель математического ввода' 'Math input panel') }
    @{ Preset = 'balanced'; Group = 'AI';       Pattern = '^Microsoft-Windows-Hello-Face-Package';                     Desc = (T 'Windows Hello Face' 'Windows Hello Face') }
    @{ Preset = 'max';      Group = 'Misc';     Pattern = '^Microsoft-Windows-PowerShell-ISE-FOD-Package';             Desc = (T 'PowerShell ISE' 'PowerShell ISE') }
    @{ Preset = 'max';      Group = 'Misc';     Pattern = '^Microsoft-Windows-(VBSCRIPT|WMIC)-FoD-Package';            Desc = (T 'VBScript и WMIC' 'VBScript and WMIC') }
    @{ Preset = 'max';      Group = 'Misc';     Pattern = '^Microsoft-Windows-Printing-PMCPPC-FoD-Package';            Desc = (T 'Драйверы печати PMC PPC' 'PMC PPC print drivers') }
)

# CJK-шрифты (~254 МБ). Пакетами не удаляются — только файлами.
# micross.ttf (Microsoft Sans Serif) в список не входит: это системный шрифт.
$script:FontPatterns = @(
    'mingliu*.ttc', 'mingliub.ttc', 'msjh*.ttc', 'msyh*.ttc', 'simsun*.ttc', 'simsunb.ttf',
    'SimsunExtG.ttf', 'malgun*.ttf', 'YuGoth*.ttc', 'meiryo*.ttc', 'batang.ttc', 'gulim.ttc',
    'kaiu.ttf', 'MSGOTHIC.TTC', 'MSMINCHO.TTC', 'simkai.ttf', 'simfang.ttf', 'simhei.ttf', 'Dengb.ttf'
)

# CJK-шрифты загрузчика (Windows\Boot\Fonts) — нужны только для загрузочных
# экранов на китайском, японском и корейском.
$script:BootFontPatterns = @(
    'malgun*_boot.ttf', 'msyh*_boot.ttf', 'msjh*_boot.ttf', 'meiryo*_boot.ttf',
    'simsun*_boot.ttf', 'chs_boot.ttf', 'cht_boot.ttf', 'jpn_boot.ttf', 'kor_boot.ttf'
)

# Никогда не трогаем — даже если попадает под regex выше или из -RemoveExtra.
$script:NeverRemove = @(
    'Microsoft-Edge-WebView-FOD-Package'                            # WebView2 — нужен приложениям
    'Microsoft-OneCore-Edge-WebRuntime-Package'                     # WebView2 runtime
    'Microsoft-OneCore-Fonts-DesktopFonts-NonLeanSupplement-Package' # обычные шрифты
    '^Language\.Basic~'                                             # раскладки и шрифты языка
    'LanguageFeatures-WordBreaking'                                 # поиск в системе
    'Microsoft\.Windows\.Notepad'
    'OpenSSH\.Client'
    'Windows\.Client\.ShellComponents'
    'Microsoft\.Windows\.Ethernet\.Client'
    'Microsoft\.Windows\.Wifi\.Client'
    'DirectX\.Configuration\.Database'
    'Microsoft-Windows-PhotoBasic'                                  # единственный просмотрщик картинок в LTSC
)

# Платформа Store/MSIX сохраняется в safe и balanced, включая зависимости.
# Список также передаётся guard; состав агрессивного max не меняется.
$script:AppPlatformProtected = @(
    '^Microsoft\.(WindowsStore|StorePurchaseApp|DesktopAppInstaller)(_|$)'
    '^Microsoft\.(VCLibs\.|UI\.Xaml\.|NET\.Native\.|WindowsAppRuntime\.)'
    '^Microsoft\.Services\.Store\.Engagement(_|$)'
    '^Microsoft\.(AAD\.BrokerPlugin|AccountsControl|Windows\.CloudExperienceHost|Windows\.AppResolverUX)(_|$)'
)

# Provisioned Appx на удаление.
$script:AppxRules = @(
    @{ Preset = 'balanced'; Group = 'Defender'; Pattern = '^Microsoft\.SecHealthUI'; Desc = (T 'Интерфейс «Безопасность Windows»' 'Windows Security app') }
    @{ Preset = 'balanced'; Group = 'AI'; Pattern = '^Microsoft\.(Copilot|Windows\.Ai\.Copilot\.Provider)$'; Desc = 'Copilot' }
    @{ Preset = 'balanced'; Group = 'Apps'; Pattern = '^(Clipchamp\.Clipchamp|Microsoft\.(BingNews|BingWeather|GetHelp|Getstarted|MicrosoftOfficeHub|MicrosoftSolitaireCollection|WindowsFeedbackHub|YourPhone|OutlookForWindows)|MicrosoftTeams|MSTeams)$'; Desc = (T 'Необязательные потребительские приложения' 'Optional consumer apps') }
)

# Папки, удаляемые файловым способом (Edge и Defender не являются CBS-пакетами).
$script:FolderRules = @(
    @{ Preset = 'safe'; Group = 'Edge'; Path = 'Program Files\Microsoft\Edge'; Desc = (T 'Браузер Edge (x64)' 'Edge browser (x64)') }
    @{ Preset = 'safe';     Group = 'Edge';     Path = 'Program Files (x86)\Microsoft\Edge';                        Desc = (T 'Браузер Edge' 'Edge browser') }
    @{ Preset = 'safe';     Group = 'Edge';     Path = 'Program Files (x86)\Microsoft\EdgeCore';                    Desc = (T 'Ядро Edge' 'Edge core') }
    @{ Preset = 'balanced'; Group = 'Defender'; Path = 'Program Files\Windows Defender';                            Desc = (T 'Defender (бинарники)' 'Defender (binaries)') }
    @{ Preset = 'balanced'; Group = 'Defender'; Path = 'Program Files (x86)\Windows Defender';                      Desc = (T 'Defender (x86)' 'Defender (x86)') }
    @{ Preset = 'balanced'; Group = 'Defender'; Path = 'Program Files\Windows Defender Advanced Threat Protection'; Desc = (T 'Defender ATP (~159 МБ)' 'Defender ATP (about 159 MB)') }
    @{ Preset = 'balanced'; Group = 'Defender'; Path = 'ProgramData\Microsoft\Windows Defender';                    Desc = (T 'Сигнатуры Defender' 'Defender signatures') }
    @{ Preset = 'balanced'; Group = 'Defender'; Path = 'Windows\System32\Tasks\Microsoft\Windows\Windows Defender'; Desc = (T 'Задачи Defender' 'Defender scheduled tasks') }
    @{ Preset = 'balanced'; Group = 'Speech';   Path = 'Windows\Speech';                                            Desc = (T 'SAPI 5.1 (старый синтез речи)' 'SAPI 5.1 (legacy speech synthesis)') }
    @{ Preset = 'balanced'; Group = 'Speech';   Path = 'Windows\Speech_OneCore';                                    Desc = (T 'Speech OneCore' 'Speech OneCore') }
    @{ Preset = 'balanced'; Group = 'Defender'; Path = 'ProgramData\Microsoft\Windows Defender Advanced Threat Protection'; Desc = (T 'Defender ATP (данные)' 'Defender ATP (data)') }
    @{ Preset = 'balanced'; Group = 'Misc';     Path = 'Windows\diagnostics';                                       Desc = (T 'Сценарии диагностики' 'Troubleshooting packs') }
    @{ Preset = 'balanced'; Group = 'Fonts';    Path = 'Windows\IME';                                               Desc = (T 'Восточноазиатский ввод (IME)' 'East Asian input (IME)') }
    # NGEN пересоберёт образы фоновой задачей при простое; до этого первые
    # запуски .NET-приложений и PowerShell 5.1 будут медленнее (~385 МБ, ~96 МБ в ISO)
    @{ Preset = 'balanced'; Group = 'NativeImages'; Path = 'Windows\assembly\NativeImages_v4.0.30319_64'; Desc = (T 'Кэш NGEN (x64)' 'NGEN cache (x64)') }
    @{ Preset = 'balanced'; Group = 'NativeImages'; Path = 'Windows\assembly\NativeImages_v4.0.30319_32'; Desc = (T 'Кэш NGEN (x86)' 'NGEN cache (x86)') }
    # max — осознанный режим с потерей совместимости. Его состав сохранён.
    @{ Preset = 'max'; Group = 'Edge'; Path = 'Program Files (x86)\Microsoft\EdgeWebView'; Desc = 'WebView2' }
    @{ Preset = 'max'; Group = 'Edge'; Path = 'Program Files (x86)\Microsoft\EdgeUpdate'; Desc = 'Edge Update' }
    @{ Preset = 'max'; Group = 'Misc'; Path = 'Windows\WinSxS\Backup'; Desc = (T 'Резервные копии компонентов' 'Component backups') }
)

# Задания планировщика: файлы определений удаляются вместе со службами
$script:TaskFiles = @(
    @{ Preset = 'balanced'; Group = 'Telemetry'; Path = 'Windows\System32\Tasks\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser';    Desc = (T 'Compatibility Appraiser' 'Compatibility Appraiser') }
    @{ Preset = 'balanced'; Group = 'Telemetry'; Path = 'Windows\System32\Tasks\Microsoft\Windows\Application Experience\ProgramDataUpdater';                   Desc = (T 'ProgramDataUpdater' 'ProgramDataUpdater') }
    @{ Preset = 'balanced'; Group = 'Telemetry'; Path = 'Windows\System32\Tasks\Microsoft\Windows\Customer Experience Improvement Program\Consolidator';        Desc = (T 'CEIP Consolidator' 'CEIP Consolidator') }
    @{ Preset = 'balanced'; Group = 'Telemetry'; Path = 'Windows\System32\Tasks\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip';             Desc = (T 'CEIP USB' 'CEIP USB') }
    @{ Preset = 'balanced'; Group = 'Telemetry'; Path = 'Windows\System32\Tasks\Microsoft\Windows\Windows Error Reporting\QueueReporting';                      Desc = (T 'Отчёты об ошибках' 'Error reporting') }
    @{ Preset = 'balanced'; Group = 'Telemetry'; Path = 'Windows\System32\Tasks\Microsoft\Windows\Feedback\Siuf\DmClient';                                      Desc = (T 'Feedback DmClient' 'Feedback DmClient') }
    @{ Preset = 'balanced'; Group = 'Telemetry'; Path = 'Windows\System32\Tasks\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload';                    Desc = (T 'Feedback DmClient (сценарии)' 'Feedback DmClient (scenarios)') }
)

# Каталоги AI-компонентов. Ищутся по маске: точные имена меняются от билда к
# билду (после накопительных обновлений появляется, например, AIFabric.CBS.1.6).
$script:AiFolderPatterns = @(
    @{ Parent = 'Windows\SystemApps'; Mask = 'MicrosoftWindows.Client.AIX_*';   Desc = (T 'AI Experiences (AIX)' 'AI Experiences (AIX)') }
    @{ Parent = 'Windows\SystemApps'; Mask = 'Microsoft.AIFabric.CBS*';         Desc = (T 'AI Fabric — локальные AI-модели' 'AI Fabric - local AI models') }
    @{ Parent = 'Windows\SystemApps'; Mask = 'Microsoft.Windows.AugLoop.CBS_*'; Desc = (T 'AugLoop' 'AugLoop') }
    @{ Parent = 'Windows\InboxApps';  Mask = 'Microsoft.Copilot_*';             Desc = (T 'Установочный пакет Copilot' 'Copilot installer package') }
)

# Отдельные файлы на удаление.
$script:FileRules = @(
    @{ Preset = 'balanced'; Group = 'OneDrive'; Path = 'Windows\System32\OneDriveSetup.exe'; Desc = (T 'Установщик OneDrive (x64)' 'OneDrive installer (x64)') }
    @{ Preset = 'balanced'; Group = 'OneDrive'; Path = 'Windows\SysWOW64\OneDriveSetup.exe'; Desc = (T 'Установщик OneDrive (x86)' 'OneDrive installer (x86)') }
    @{ Preset = 'safe';     Group = 'Edge'; Path = 'ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk'; Desc = (T 'Ярлык Edge в меню Пуск' 'Edge shortcut in the Start menu') }
    @{ Preset = 'safe';     Group = 'Edge'; Path = 'Users\Public\Desktop\Microsoft Edge.lnk';                              Desc = (T 'Ярлык Edge на рабочем столе' 'Edge shortcut on the desktop') }
)

# Службы, переводимые в Start=4 (отключены).
$script:DisableServices = @(
    @{ Group = 'Defender';  Names = @('WinDefend', 'WdNisSvc', 'WdNisDrv', 'WdFilter', 'WdBoot', 'Sense',
                                      'SecurityHealthService', 'webthreatdefsvc', 'MsSecCore', 'MsSecFlt',
                                      'MsSecWfp', 'SgrmBroker', 'SgrmAgent') }
    @{ Group = 'Telemetry'; Names = @('DiagTrack', 'dmwappushservice', 'diagnosticshub.standardcollector.service',
                                      'WerSvc', 'wercplsupport') }
)

# Соответствие языка образа коду языка Mozilla для ссылки на загрузку Firefox.
$script:MozillaLang = @{
    'ru-RU' = 'ru';    'en-US' = 'en-US'; 'en-GB' = 'en-GB'; 'de-DE' = 'de';    'fr-FR' = 'fr'
    'uk-UA' = 'uk';    'pl-PL' = 'pl';    'it-IT' = 'it';    'es-ES' = 'es-ES'; 'pt-BR' = 'pt-BR'
    'tr-TR' = 'tr';    'cs-CZ' = 'cs';    'ja-JP' = 'ja';    'zh-CN' = 'zh-CN'; 'zh-TW' = 'zh-TW'
    'ko-KR' = 'ko';    'nl-NL' = 'nl';    'kk-KZ' = 'kk';    'be-BY' = 'be';    'sv-SE' = 'sv-SE'
}

#endregion

#region ── Логирование и вспомогательные функции ────────────────────────────────

$script:StageNo = 0
$script:StageTimes = [ordered]@{}
$script:StageStart = $null
$script:StartedAt = Get-Date

function Write-Stage {
    param([string]$Title)
    if ($script:StageStart) {
        $prev = @($script:StageTimes.Keys)[-1]
        $script:StageTimes[$prev] = (Get-Date) - $script:StageStart
    }
    $script:StageNo++
    $script:StageStart = Get-Date
    $script:StageTimes["$($script:StageNo). $Title"] = [TimeSpan]::Zero
    Write-Host ''
    Write-Host ('─' * 78) -ForegroundColor DarkCyan
    Write-Host ("[{0:HH:mm:ss}] " -f (Get-Date)) -NoNewline -ForegroundColor Cyan
    Write-Host ((T 'Стадия' 'Stage') + " $($script:StageNo): $Title") -ForegroundColor Cyan
    Write-Host ('─' * 78) -ForegroundColor DarkCyan
}

function Write-Step { param([string]$Message) Write-Host "  → $Message" -ForegroundColor Gray }
function Write-Ok   { param([string]$Message) Write-Host "  ✓ $Message" -ForegroundColor Green }
function Write-Note { param([string]$Message) Write-Host "  ! $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "  ✗ $Message" -ForegroundColor Red }

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} ' -f ($Bytes / 1GB)) + (T 'ГБ' 'GB') }
    if ($Bytes -ge 1MB) { return ('{0:N1} ' -f ($Bytes / 1MB)) + (T 'МБ' 'MB') }
    return ('{0:N0} ' -f ($Bytes / 1KB)) + (T 'КБ' 'KB')
}

# Полосу рисуем только в настоящей консоли: при перенаправлении вывода
# возврат каретки превращается в мусор из сотен строк
$script:CanDrawProgress = $false
try { $script:CanDrawProgress = -not [Console]::IsOutputRedirected } catch { }

# Вид строки:  [████████····································]  21%  00:01  Экспорт индекса 2
# Полоса слева шириной до 40 знаков; при узкой консоли она сжимается или
# убирается совсем, чтобы строка никогда не доходила до столбца переноса.
function Get-ProgressLine {
    param([string]$Activity, [int]$Percent, [int]$Phase = 1, [TimeSpan]$Elapsed,
          [int]$Width = 80, [switch]$Done, [switch]$Failed)
    $limit = [Math]::Max(1, $Width - 1) # Последний столбец вызывает перенос строки.
    $percent = [Math]::Max(0, [Math]::Min(100, $Percent))
    $waiting = -not $Done -and $percent -eq 100
    if ($Done -and -not $Failed) { $percent = 100 }
    $time = '{0:00}:{1:00}' -f [Math]::Floor($Elapsed.TotalMinutes), $Elapsed.Seconds
    $activityText = ($Activity -replace '[\r\n\t]', ' ')
    # Идентификатор KB полезнее длинного имени MSU с хэшем.
    $activityText = [regex]::Replace($activityText, '(?i)windows[^\s]*?-(kb\d+)[^\s]*\.msu', { param($m) $m.Groups[1].Value.ToUpperInvariant() })
    # Одна операция DISM может несколько раз пройти 0–100% (checkpoint + цель):
    # номер этапа показываем только со второго, чтобы не шуметь в обычном случае.
    if ($Done) { $activityText += if ($Failed) { T ' — ОШИБКА' ' - FAILED' } else { T ' — готово' ' - done' } }
    elseif ($Phase -gt 1) { $activityText += (T ' (этап ' ' (phase ') + "$Phase)" }
    if ($waiting) { $activityText = (T 'ожидание завершения — ' 'waiting for completion - ') + $activityText }
    $percentText = if ($Done -and $Failed) { ' ERR' } elseif ($waiting) { ' ...' } else { '{0,3}%' -f $percent }
    $tail = ' {0}  {1}  {2}' -f $percentText, $time, $activityText
    $barWidth = [Math]::Min(40, $limit - 2 - 2 - $tail.Length)
    $line = if ($barWidth -ge 8) {
        if ($waiting) {
            # 100% от утилиты не означает, что процесс уже завершён. Не рисуем
            # выдуманные 99%: пока ждём выхода/нового этапа, показываем движение.
            $position = [int]([Math]::Max(0, [Math]::Floor($Elapsed.TotalMilliseconds / 500)) % ($barWidth - 2))
            '  [' + ('·' * $position) + '███' + ('·' * ($barWidth - $position - 3)) + ']' + $tail
        } else {
            $filled = [int][Math]::Round($barWidth * $percent / 100)
            '  [' + ('█' * $filled) + ('·' * ($barWidth - $filled)) + ']' + $tail
        }
    } else { ' ' + $tail }
    if ($line.Length -gt $limit) { $line = $line.Substring(0, [Math]::Max(0, $limit - 1)) + '…' }
    $line
}

function Write-ProgressBar {
    param([string]$Activity, [int]$Percent, [int]$Phase = 1, [switch]$Done, [switch]$Failed)
    if (-not $script:CanDrawProgress) { return }
    $width = 80
    try {
        $width = [Math]::Min([Console]::WindowWidth, [Console]::BufferWidth)
        if ($width -lt 2) { return }
    } catch { return }
    $elapsed = if ($script:ProgressStarted) { (Get-Date) - $script:ProgressStarted } else { [TimeSpan]::Zero }
    $line = Get-ProgressLine -Activity $Activity -Percent $Percent -Phase $Phase -Elapsed $elapsed -Width $width -Done:$Done -Failed:$Failed
    # Прямая запись в консоль не засоряет transcript каждым кадром.
    # Цвет ставим на уровне консоли, а не Write-Host, по той же причине.
    $previous = [Console]::ForegroundColor
    try {
        [Console]::ForegroundColor = if ($Failed) { [ConsoleColor]::Red } else { [ConsoleColor]::Cyan }
        [Console]::Write("`r" + $line.PadRight($width - 1))
    } finally { [Console]::ForegroundColor = $previous }
    if ($Done) { [Console]::WriteLine() }
}

function Update-ProgressState {
    param([hashtable]$State, [string]$Text)
    $text = $Text.Trim()
    if (-not $text) { return }
    if ($text -match '(\d{1,3})(?:[.,]\d+)?%') {
        $percent = [Math]::Min(100, [int]$matches[1])
        # Один Add-Package может обслуживать checkpoint и целевой пакет.
        # DISM не сообщает общий процент: показываем отдельные этапы честно.
        if ($State.Percent -ge 0 -and $percent -lt $State.Percent) { $State.Phase++ }
        $State.Percent = $percent
    } else { $State.Lines.Add($text) }
}

# Единая обёртка над dism.exe. /English обязателен — иначе парсинг вывода
# ломается на локализованных системах.
function Write-DiagnosticLog {
    param([string]$Message)
    if (-not $script:DetailLogPath) {
        # Явный -Verbose без логирования остаётся доступным для диагностики.
        Write-Verbose $Message
        return
    }
    if ($script:DetailLogFailed) { return }
    try {
        # Transcript имеет своего писателя. Технический журнал пишется отдельно,
        # чтобы не конфликтовать с ним и не выводить строки через консоль.
        [IO.File]::AppendAllText($script:DetailLogPath, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message`r`n", [Text.UTF8Encoding]::new($true))
    } catch {
        $script:DetailLogFailed = $true
        Write-Warning (T "Не удалось дописать технический журнал $script:DetailLogPath : $($_.Exception.Message)" "Could not append to diagnostic log $script:DetailLogPath : $($_.Exception.Message)")
    }
}

function Invoke-Dism {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFail,
        [switch]$Quiet,
        [string]$Activity          # задан — показываем полосу вместо вывода DISM
    )
    $all = @('/English') + $Arguments
    # И -Debug, и явный -LogFile включают собственный подробный журнал DISM.
    if ($script:DismLogPath) {
        $all += @("/LogPath:$script:DismLogPath", '/LogLevel:4')
    }
    Write-DiagnosticLog "dism $($all -join ' ')"

    if ($Activity -and $script:CanDrawProgress) {
        $run = Invoke-ProgressProcess -Exe $script:Dism -Arguments $all -Activity $Activity -SuccessCodes @(0, 3010)
        $output = $run.Output
        $code = $run.ExitCode
    } elseif ($Quiet) {
        $output = & $script:Dism @all 2>&1
        $code = $LASTEXITCODE
    } else {
        $output = & $script:Dism @all 2>&1 | Tee-Object -Variable teed
        $output = $teed
        $code = $LASTEXITCODE
    }
    if (-not (Test-DismSuccess $code) -and -not $AllowFail) {
        $tail = ($output | Select-Object -Last 12) -join "`n"
        throw (T "DISM завершился с кодом $code`n$tail" "DISM exited with code $code`n$tail")
    }
    [PSCustomObject]@{ ExitCode = $code; Output = $output }
}

# Долгий внешний процесс показываем одной полосой вместо его собственного вывода.
# Источник процентов у каждого свой: dism.exe рисует полосу в stdout, oscdimg
# пишет строки «N% complete» в stderr, а robocopy с /NP молчит — для него
# процент считается по данным на диске через -GetPercent.
# Живой поток читаем посимвольно: полоса перерисовывается возвратом каретки,
# ждать перевода строки бессмысленно, его может не быть минутами.
function Invoke-ProgressProcess {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$Activity,
        [string]$WorkingDirectory,   # процесс не наследует Push-Location оболочки
        [int[]]$SuccessCodes = @(0),
        [scriptblock]$GetPercent,    # задан — процент берём отсюда, а не из вывода
        [switch]$ProgressOnStdErr    # проценты в stderr, сообщения в stdout (oscdimg)
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding(437)
    $psi.StandardErrorEncoding = [Text.Encoding]::GetEncoding(437)

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $script:ProgressStarted = Get-Date
    $lines = [System.Collections.Generic.List[string]]::new()
    $buffer = New-Object System.Text.StringBuilder
    $state = @{ Percent = -1; Phase = 1; Lines = $lines }
    $exitCode = -1
    try {
        $null = $proc.Start()
        # Один поток читаем живым, второй забираем целиком по завершении процесса.
        $reader = if ($ProgressOnStdErr) { $proc.StandardError } else { $proc.StandardOutput }
        $restTask = if ($ProgressOnStdErr) { $proc.StandardOutput.ReadToEndAsync() } else { $proc.StandardError.ReadToEndAsync() }
        Write-ProgressBar -Activity $Activity -Percent 0
        $chars = New-Object char[] 2048
        $readTask = $reader.ReadAsync($chars, 0, $chars.Length)
        $lastDraw = [DateTime]::MinValue
        $reading = $true
        while ($reading -or -not $proc.HasExited -or -not $restTask.IsCompleted) {
            if ($reading -and $readTask.IsCompleted) {
                $count = $readTask.GetAwaiter().GetResult()
                if ($count -eq 0) {
                    $reading = $false
                    Update-ProgressState -State $state -Text $buffer.ToString()
                    $null = $buffer.Clear()
                }
                for ($i = 0; $i -lt $count; $i++) {
                    $c = $chars[$i]
                    if ($c -eq "`r" -or $c -eq "`n" -or $c -eq [char]8) {
                        Update-ProgressState -State $state -Text $buffer.ToString()
                        $null = $buffer.Clear()
                    } else { $null = $buffer.Append($c) }
                }
                if ($reading) { $readTask = $reader.ReadAsync($chars, 0, $chars.Length) }
            }
            if (((Get-Date) - $lastDraw).TotalMilliseconds -ge 500) {
                # Отказ внешнего счётчика гасим: индикация не должна ломать сборку.
                if ($GetPercent) { try { $state.Percent = [int](& $GetPercent) } catch { } }
                Write-ProgressBar -Activity $Activity -Percent ([Math]::Max(0, $state.Percent)) -Phase $state.Phase
                $lastDraw = Get-Date
            }
            # Даже после закрытия stdout/stderr процесс может ещё работать.
            # До его выхода продолжаем обновлять время и индикатор ожидания.
            if (-not $reading -or -not $readTask.IsCompleted) { Start-Sleep -Milliseconds 100 }
        }
        Update-ProgressState -State $state -Text $buffer.ToString()
        $restText = $restTask.GetAwaiter().GetResult()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        if ($restText.Trim()) { $lines.Add($restText.Trim()) }
        $failed = $exitCode -notin $SuccessCodes
        Write-ProgressBar -Activity $Activity -Percent $(if ($failed) { [Math]::Max(0, $state.Percent) } else { 100 }) -Phase $state.Phase -Done -Failed:$failed
        $tool = [IO.Path]::GetFileName($Exe)
        Write-DiagnosticLog (T "$tool завершился: этапов $($state.Phase), код $exitCode, операция: $Activity" "$tool finished: $($state.Phase) phases, code $exitCode, operation: $Activity")
    } finally { $proc.Dispose() }
    [PSCustomObject]@{ ExitCode = $exitCode; Output = $lines.ToArray() }
}

# robocopy с /NP не сообщает прогресс, поэтому процент копирования берём с
# диска: объём источника известен заранее, а приёмник растёт файл за файлом.
# Дерево перечисляется во время интенсивной записи — опрашиваем не часто.
$script:CopyPolled = $null
$script:CopyPercent = 0
function Get-CopyPercent {
    param([string]$Path, [int64]$TotalBytes)
    if ($TotalBytes -le 0) { return $script:CopyPercent }
    if ($script:CopyPolled -and ((Get-Date) - $script:CopyPolled).TotalSeconds -lt 2) { return $script:CopyPercent }
    $script:CopyPolled = Get-Date
    $copied = 0L
    Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        ForEach-Object { $copied += $_.Length }
    # 100% ставит только завершившийся процесс; счётчик не идёт назад.
    $script:CopyPercent = [Math]::Max($script:CopyPercent, [Math]::Min(99, [int](100 * $copied / $TotalBytes)))
    $script:CopyPercent
}

# Разбирает вывод dism вида "Ключ : Значение" в список объектов.
# Разделителем записей служит поле $Key.
function ConvertFrom-DismList {
    param([string[]]$Lines, [string]$Key)
    $result = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in $Lines) {
        if ($line -match '^\s*([A-Za-z][A-Za-z0-9 _\-]*?)\s*:\s*(.*?)\s*$') {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim()
            if ($name -eq $Key) {
                if ($current) { $result.Add($current) }
                $current = [ordered]@{ $Key = $value }
            } elseif ($current) {
                $current[$name] = $value
            }
        }
    }
    if ($current) { $result.Add($current) }
    $result | ForEach-Object { [PSCustomObject]$_ }
}

function Get-ProtectedPatterns {
    $script:NeverRemove
    if ($Preset -ne 'max') { $script:AppPlatformProtected }
}

function Test-Protected {
    param([string]$Name)
    foreach ($rule in ($script:CapabilityRules + $script:PackageRules)) {
        if ($Keep -contains $rule.Group -and $Name -match $rule.Pattern) { return $true }
    }
    foreach ($p in @(Get-ProtectedPatterns)) {
        if ($Name -match $p) { return $true }
    }
    $false
}

function Get-WindowsRelease {
    param([int]$Build)
    # Новые ветки не должны получать обновления от последней известной версии.
    switch ($Build) {
        22000 { '21H2' }
        22621 { '22H2' }
        22631 { '23H2' }
        26100 { '24H2' }
        26200 { '25H2' }
        28000 { '26H1' }
        default { throw (T "Неизвестная ветка Windows: $Build. Подбор обновлений для неё не настроен." "Unknown Windows build branch: $Build. Update selection is not configured for it.") }
    }
}

function Get-EditionConfig {
    param([string]$EditionId)
    # EI.CFG допускает OEM/Retail, а признак Volume задаётся отдельно в [VL].
    # Обычные Home/Pro не должны превращаться в корпоративный установочный носитель.
    $volume = if ($EditionId -match '^(Enterprise|Education|IoTEnterpriseS)') { 1 } else { 0 }
    "[EditionID]`r`n$EditionId`r`n`r`n[Channel]`r`nRetail`r`n`r`n[VL]`r`n$volume`r`n"
}

function Resolve-AccountMode {
    param([int]$Build,[string]$EditionId,[string]$Mode,[string]$Name,[string]$AnswerFile)
    if ($AnswerFile) {
        if ($Name -or $Mode -eq 'image') { throw (T 'Локальный аккаунт задавайте в собственном answer-файле' 'Configure the local account in your custom answer file') }
        return 'setup'
    }
    if ($Mode -eq 'setup') {
        if ($Name) { throw (T '-LocalUserName несовместим с -AccountMode setup' '-LocalUserName cannot be combined with -AccountMode setup') }
        return 'setup'
    }
    if ($Mode -eq 'image' -or $Name -or ($Build -eq 28000 -and $EditionId -match '^(Core|Professional)')) { return 'image' }
    'setup'
}

function Assert-LocalUserName {
    param([string]$Name)
    if (-not $Name -or $Name.Length -gt 20 -or $Name -ne $Name.Trim() -or $Name.EndsWith('.') -or
        $Name -match '["/\\\[\]:;|=,+*?<>\x00-\x1f]' -or $Name -match '^\.+$' -or
        $Name -in @('Administrator','Администратор','Guest','Гость','DefaultAccount','WDAGUtilityAccount','defaultuser0')) {
        throw (T 'Недопустимое имя локального пользователя: используйте до 20 символов без служебных знаков и имён встроенных учётных записей' 'Invalid local user name: use up to 20 characters without reserved punctuation or built-in account names')
    }
}

function Test-SecureStringEqual {
    param([Security.SecureString]$Left,[Security.SecureString]$Right)
    if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
    if ($Left.Length -ne $Right.Length) { return $false }
    $leftPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Left)
    $rightPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Right)
    try {
        $difference = 0
        for ($index = 0; $index -lt $Left.Length; $index++) {
            $difference = $difference -bor (
                [Runtime.InteropServices.Marshal]::ReadInt16($leftPointer, $index * 2) -bxor
                [Runtime.InteropServices.Marshal]::ReadInt16($rightPointer, $index * 2)
            )
        }
        return $difference -eq 0
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($leftPointer)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($rightPointer)
    }
}

function Read-ConfirmedLocalAccountPassword {
    while ($true) {
        $password = Read-Host (T '  Пароль (пусто — без пароля)' '  Password (empty for no password)') -AsSecureString
        if ($password.Length -eq 0) { return $password }
        $confirmation = Read-Host (T '  Подтвердите пароль' '  Confirm password') -AsSecureString
        if (Test-SecureStringEqual -Left $password -Right $confirmation) {
            $confirmation.Dispose()
            return $password
        }
        $password.Dispose()
        $confirmation.Dispose()
        Write-Host (T '  Пароли не совпадают. Введите пароль ещё раз.' '  Passwords do not match. Enter the password again.') -ForegroundColor Yellow
    }
}

function Read-LocalAccountOptions {
    param([int]$Build,[string]$EditionId,[string]$Mode,[string]$Name,[Security.SecureString]$Password,[switch]$Preview)
    $resolved = Resolve-AccountMode -Build $Build -EditionId $EditionId -Mode $Mode -Name $Name -AnswerFile $Unattend
    if ($Password -and $resolved -ne 'image') { throw (T 'Пароль указан без создаваемого локального аккаунта' 'A password was supplied without a local account to create') }
    if ($resolved -eq 'image' -and -not $Name -and -not $Preview) {
        if (-not (Test-CanPrompt)) { throw (T 'Для Home/Pro 26H1 укажите -LocalUserName <имя> или -AccountMode setup для ввода при установке Windows' 'For Home/Pro 26H1, specify -LocalUserName <name> or -AccountMode setup to enter it during Windows Setup') }
        $resolved = Read-Option -Question (T 'Где задать локального пользователя' 'Where to configure the local user') -Items @((T 'Сейчас, до сборки ISO' 'Now, before building the ISO'),(T 'При установке Windows' 'During Windows Setup')) -Values @('image','setup') -Default 1
        if ($resolved -eq 'image') {
            $Name = (Read-Host (T '  Имя локального пользователя' '  Local user name')).Trim()
            Assert-LocalUserName $Name
            Write-Note (T 'Пароль попадёт в установочный answer-файл ISO; кодирование Windows не является шифрованием.' 'The password is stored in the ISO answer file; Windows encoding is not encryption.')
            $Password = Read-ConfirmedLocalAccountPassword
        }
    }
    if ($Name) { Assert-LocalUserName $Name }
    [pscustomobject]@{Mode=$resolved;Name=$Name;Password=$Password}
}

function Get-LocalAccountXml {
    param([string]$Name,[Security.SecureString]$Password)
    if (-not $Name) { return '' }
    Assert-LocalUserName $Name
    $escaped = [Security.SecurityElement]::Escape($Name)
    $plain = ''
    if ($Password) {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($plain+'Password'))
    $plain = $null
    @"

            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Password><Value>$encoded</Value><PlainText>false</PlainText></Password>
                        <DisplayName>$escaped</DisplayName>
                        <Group>Administrators</Group>
                        <Name>$escaped</Name>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
"@
}

function Get-ImageInstallXml {
    param([bool]$Compact)
    $compactSetting = if ($Compact) { "`r`n                    <Compact>true</Compact>" } else { '' }
    @"

            <ImageInstall>
                <OSImage>$compactSetting
                    <InstallFrom>
                        <MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData>
                    </InstallFrom>
                </OSImage>
            </ImageInstall>
"@
}

function Get-ProductKeyUiMode {
    param([string]$EditionId)
    if ($EditionId -match '^(Core|Professional)') { return 'OnError' }
    'Never'
}

# Активна ли группа удаления при текущем пресете и -Keep.
function Test-GroupActive {
    param([string]$RulePreset, [string]$Group)
    if ($Keep -contains $Group) { return $false }
    if ($Preset -ne 'max' -and $Group -eq 'Fonts' -and @($script:ImageLanguages + $AddLanguage + $DownloadLanguage | Where-Object { $_ -match '^(zh|ja|ko)(-|$)' }).Count) { return $false }
    $order = @{ 'safe' = 0; 'balanced' = 1; 'max' = 2 }
    $order[$Preset] -ge $order[$RulePreset]
}

function Test-DismSuccess {
    param([int]$Code)
    $Code -in @(0, 3010)
}

$script:ImageAudit = [ordered]@{ ComponentStore = @(); RemovalFailures = @(); RemainingRemovals = @() }
$script:ImageAuditPath = $null

function Save-ImageAudit {
    if (-not $script:ImageAuditPath) { return }
    try {
        $script:ImageAudit | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ImageAuditPath -Encoding UTF8
    } catch {
        Write-Note (T "Не удалось сохранить отчёт образа: $($_.Exception.Message)" "Could not save image audit: $($_.Exception.Message)")
    }
}

function Write-ComponentStoreReport {
    param([string]$Image, [string]$Phase)
    Write-Step (T "Анализ WinSxS: $Phase" "WinSxS analysis: $Phase")
    try {
        $result = Invoke-Dism -Arguments @("/Image:$Image", '/Cleanup-Image', '/AnalyzeComponentStore') -AllowFail -Quiet `
                              -Activity (T "Анализ хранилища компонентов: $Phase" "Analyzing the component store: $Phase")
    } catch {
        $result = [pscustomobject]@{ ExitCode = -1; Output = @($_.Exception.Message) }
    }
    $script:ImageAudit.ComponentStore += [pscustomobject]@{ Phase = $Phase; ExitCode = $result.ExitCode; Output = @($result.Output | ForEach-Object { "$_" }) }
    if (Test-DismSuccess $result.ExitCode) {
        # DISM учитывает hard links. Сумма Length в WinSxS этого не делает.
        foreach ($line in $result.Output) {
            if ($line -match '^\s*(Actual Size of Component Store|Shared with Windows|Backups and Disabled Features|Cache and Temporary Data|Number of Reclaimable Packages|Component Store Cleanup Recommended)\s*:\s*(.*)$') {
                $label = switch ($matches[1]) {
                    'Actual Size of Component Store' { T 'Фактический размер' 'Actual size' }
                    'Shared with Windows' { T 'Общие с Windows файлы' 'Shared with Windows' }
                    'Backups and Disabled Features' { T 'Резервные копии и отключённые функции' 'Backups and disabled features' }
                    'Cache and Temporary Data' { T 'Кэш и временные данные' 'Cache and temporary data' }
                    'Number of Reclaimable Packages' { T 'Пакетов доступно для очистки' 'Reclaimable packages' }
                    'Component Store Cleanup Recommended' { T 'Рекомендована очистка' 'Cleanup recommended' }
                }
                Write-Step "$label : $($matches[2])"
            }
        }
    } else {
        Write-Note (T "Анализ WinSxS недоступен (код $($result.ExitCode)); размер не оценён" "WinSxS analysis unavailable (code $($result.ExitCode)); size not estimated")
    }
    Save-ImageAudit
}

function Write-ServicingRemovalFailure {
    param([string]$Kind, [string]$Name, $Result)
    $hex = '0x{0:X8}' -f ([long]$Result.ExitCode -band 0xFFFFFFFFL)
    $detail = (@($Result.Output | Select-Object -Last 12) -join [Environment]::NewLine).Trim()
    $reason = if ($hex -eq '0x800F0825') {
        if ($detail -match 'Permanent package') { 'PermanentPackage' } else { 'CannotUninstall' }
    } elseif ($hex -eq '0x800F0805') { 'InvalidPackage' } else { 'DismFailure' }
    $script:ImageAudit.RemovalFailures += [pscustomobject]@{ Kind = $Kind; Name = $Name; ExitCode = $Result.ExitCode; HResult = $hex; Reason = $reason; Detail = $detail }
    Write-Note (T "$Name не удалён: $hex ($($Result.ExitCode))`n$detail" "$Name was not removed: $hex ($($Result.ExitCode))`n$detail")
    Save-ImageAudit
}

function Get-PackageRemovalSkipReason {
    param([string]$PackageName)
    # Sense уже удаляется через capability. После отказа CBS повторение той же
    # операции через базовый пакет и его язык не обходит запрет обслуживания.
    if ($Preset -ne 'balanced' -or $PackageName -notmatch '^Microsoft-Windows-SenseClient-FoD-Package~') { return }
    $failure = @($script:ImageAudit.RemovalFailures | Where-Object {
        $_.Kind -eq 'Capability' -and $_.Name -eq 'Microsoft.Windows.Sense.Client~~~~'
    } | Select-Object -Last 1)
    if ($failure.Count) { return "CapabilityRemovalRejected: $($failure[0].HResult)" }
}

function Get-RequestedRemovalItems {
    param([object[]]$Items, [string]$Identity, [object[]]$Rules, [switch]$IncludeExtra)
    $patterns = @($Rules | Where-Object { Test-GroupActive -RulePreset $_.Preset -Group $_.Group } | ForEach-Object { $_.Pattern })
    if ($IncludeExtra) { $patterns += $RemoveExtra }
    foreach ($item in $Items) {
        $name = $item.$Identity
        if (Test-Protected $name) { continue }
        if ($item.State -in @('Not Present', 'NotPresent', 'Removed', 'Superseded', 'Disabled with Payload Removed')) { continue }
        foreach ($pattern in $patterns) {
            if ($name -match $pattern) { $item; break }
        }
    }
}

function Remove-OfflineRecall {
    param([string]$Image)
    # В balanced обслуживаем сам optional feature, прежде чем удалять файлы.
    # Политики отключают Recall после установки, но не уменьшают ISO сами по себе.
    if ($Preset -ne 'balanced' -or -not (Test-GroupActive -RulePreset 'balanced' -Group 'AI')) { return }
    $raw = Invoke-Dism -Arguments @("/Image:$Image", '/Get-Features', '/Format:List') -Quiet
    $recall = @(ConvertFrom-DismList -Lines $raw.Output -Key 'Feature Name' | Where-Object { $_.'Feature Name' -eq 'Recall' })
    foreach ($feature in $recall) {
        if ($feature.State -eq 'Disabled with Payload Removed') { continue }
        if ($feature.State -match 'Pending') {
            Write-Note (T "Recall: $($feature.State) — требуется завершение обслуживания при загрузке Windows" "Recall: $($feature.State) - servicing must complete when Windows boots")
            continue
        }
        $result = Invoke-Dism -Arguments @("/Image:$Image", '/Disable-Feature', '/FeatureName:Recall', '/Remove') -AllowFail -Quiet `
                              -Activity (T 'Удаление компонента Recall' 'Removing the Recall feature')
        if (Test-DismSuccess $result.ExitCode) { Write-Ok (T 'DISM принял удаление Recall; итоговое состояние будет проверено' 'DISM accepted Recall removal; its final state will be checked') }
        else { Write-ServicingRemovalFailure -Kind 'Feature' -Name 'Recall' -Result $result }
    }
}

function Write-RemainingRemovalReport {
    param([string]$Image)
    $remaining = @()
    foreach ($kind in @(
        @{ Name = 'Capability'; Query = '/Get-Capabilities'; Identity = 'Capability Identity'; Rules = $script:CapabilityRules; Extra = $true }
        @{ Name = 'Package'; Query = '/Get-Packages'; Identity = 'Package Identity'; Rules = $script:PackageRules; Extra = $true }
        @{ Name = 'Appx'; Query = '/Get-ProvisionedAppxPackages'; Identity = 'DisplayName'; Rules = $script:AppxRules; Extra = $false }
        @{ Name = 'Feature'; Query = '/Get-Features'; Identity = 'Feature Name'; Rules = @(@{ Preset = 'balanced'; Group = 'AI'; Pattern = '^Recall$' }); Extra = $false }
    )) {
        $queryArgs = @("/Image:$Image", $kind.Query)
        if ($kind.Name -eq 'Feature') { $queryArgs += '/Format:List' }
        $raw = Invoke-Dism -Arguments $queryArgs -Quiet
        $items = @(ConvertFrom-DismList -Lines $raw.Output -Key $kind.Identity)
        foreach ($item in @(Get-RequestedRemovalItems -Items $items -Identity $kind.Identity -Rules $kind.Rules -IncludeExtra:$kind.Extra)) {
            $state = if ($kind.Name -eq 'Appx') { 'Provisioned' } else { $item.State }
            $remaining += [pscustomobject]@{ Kind = $kind.Name; Name = $item.($kind.Identity); State = $state }
        }
    }
    $script:ImageAudit.RemainingRemovals = $remaining
    Save-ImageAudit
    if ($remaining.Count) {
        Write-Note (T "В образе осталось выбранных для удаления компонентов: $($remaining.Count)" "Selected components still present in the image: $($remaining.Count)")
        foreach ($item in $remaining) { Write-Note "$($item.Kind): $($item.Name) — $($item.State)" }
        if (@($remaining | Where-Object { $_.State -match 'Pending' }).Count) {
            Write-Note (T 'Pending означает незавершённое обслуживание: требуется загрузка Windows. Сохранение и повторное монтирование WIM не заменяют загрузку.' 'Pending means servicing is incomplete: Windows must boot. Saving and remounting the WIM does not replace booting.')
        }
    } else { Write-Ok (T 'В списках DISM не осталось выбранных компонентов' 'No selected components remain in DISM inventories') }
}

# Где 24H2 держит встроенный WebView2. Полный runtime — это CBS-компонент
# Microsoft-Edge-WebView в System32\Microsoft-Edge-WebView; каталог версии в
# Program Files (x86)\Microsoft\EdgeWebView\Application — жёсткие ссылки на него.
# Возвращает те корни, в которых сейчас есть msedgewebview2.exe.
function Get-WebViewRuntimeRoots {
    param([Parameter(Mandatory)][string]$Image)
    foreach ($relative in @('Windows\System32\Microsoft-Edge-WebView', 'Program Files (x86)\Microsoft\EdgeWebView', 'Program Files\Microsoft\EdgeWebView')) {
        $root = Join-Path $Image $relative
        if (-not (Test-Path -LiteralPath $root)) { continue }
        if (@(Get-ChildItem -LiteralPath $root -Recurse -Filter 'msedgewebview2.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1).Count) { $root }
    }
}

function Assert-ImageFileState {
    param([string]$Image)
    if (@($script:PreservedWebView).Count) {
        $present = @(Get-WebViewRuntimeRoots -Image $Image)
        if (-not $present.Count) {
            throw (T 'Удалён защищённый компонент WebView2: в образе не осталось msedgewebview2.exe' 'A protected WebView2 component was removed: no msedgewebview2.exe remains in the image')
        }
        # LCU заменяет встроенный пакет WebView2 целиком (проверено на KB5124008:
        # 122.0.2365.106 → 151.0.4129.59). CBS отпроецирует прежний каталог версии
        # из Program Files (x86), а новый компонент кладёт runtime в System32.
        # Это обслуживание Windows, а не наша чистка: WebView2 в образе остаётся.
        $versions = @($present | ForEach-Object {
            Get-ChildItem -LiteralPath $_ -Recurse -Filter '*.manifest' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -match '^\d+(\.\d+){3}$' } | ForEach-Object { $_.BaseName }
        } | Sort-Object -Unique)
        foreach ($root in $script:PreservedWebView) {
            if ($present -contains $root) { continue }
            Write-Note (T "WebView2 больше не в $root — обслуживание DISM заменило встроенный пакет. Runtime$(if ($versions) { " $($versions -join ', ')" }) остаётся в: $($present -join ', '). Проверьте в VM, что после первого входа приложения с WebView2 работают." "WebView2 is no longer in $root - DISM servicing replaced the in-box package. The runtime$(if ($versions) { " $($versions -join ', ')" }) remains in: $($present -join ', '). Verify in a VM that WebView2 apps work after first logon.")
        }
        if ($script:ImageAudit) {
            $script:ImageAudit['WebView'] = [pscustomobject]@{ Preserved = @($script:PreservedWebView); Present = $present; Versions = $versions }
        }
    }
    if (Test-GroupActive -RulePreset 'safe' -Group 'Edge') {
        foreach ($relative in @('Program Files (x86)\Microsoft\Edge', 'Program Files\Microsoft\Edge')) {
            if (Test-Path -LiteralPath (Join-Path $Image $relative)) { throw (T "Edge остался в образе: $relative" "Edge remains in the image: $relative") }
        }
    }
}

# Все удаления ограничены конкретным деревом. Ссылки в родительских каталогах
# запрещены: иначе путь способен выйти из смонтированного WIM. Сам удаляемый
# файл может быть non-name-surrogate reparse point WIM/WOF — его можно удалить
# только как конечный объект, без рекурсивного обхода.
function Assert-ChildPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [switch]$AllowLeafReparse
    )
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if (-not $full.StartsWith("$base\", [StringComparison]::OrdinalIgnoreCase)) {
        throw (T "Путь вне разрешённого каталога: $full (корень: $base)" "Path is outside the allowed directory: $full (root: $base)")
    }
    $cursor = if ($AllowLeafReparse) { Split-Path $full -Parent } else { $full }
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw (T "Отказываюсь обрабатывать путь через ссылку файловой системы: $cursor" "Refusing a path through a reparse point: $cursor")
        }
        $cursor = Split-Path $cursor -Parent
    }
    $full
}

# Тихий запуск нативной утилиты с возвратом кода завершения.
# В Windows PowerShell 5.1 при $ErrorActionPreference = 'Stop' перенаправление
# stderr (*>&1) превращает первую же строку ошибки в исключение, и код возврата
# до вызывающего не доходит: reg query по отсутствующему ключу или takeown
# ронял бы всю сборку. Настройки меняются только в области этой функции.
function Invoke-NativeQuiet {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @())
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    & $FilePath @Arguments *>&1 | Out-Null
    $LASTEXITCODE
}

# Снимает владение и даёт полные права администраторам на путь в образе.
# S-1-5-32-544 = Administrators, не зависит от языка системы.
# Ключи /R и /T применимы только к каталогам — для файла они игнорируются
# и владение не меняется, из-за чего удаление падает с «Access denied».
function Grant-ImagePathAccess {
    param([Parameter(Mandatory)][string]$Path, [switch]$Recurse)
    if ($Recurse) {
        $null = Invoke-NativeQuiet takeown.exe @('/F', $Path, '/R', '/A', '/D', 'Y')
        $null = Invoke-NativeQuiet icacls.exe @($Path, '/grant', '*S-1-5-32-544:(F)', '/T', '/C', '/Q')
    } else {
        $null = Invoke-NativeQuiet takeown.exe @('/F', $Path, '/A')
        $null = Invoke-NativeQuiet icacls.exe @($Path, '/grant', '*S-1-5-32-544:(F)', '/C', '/Q')
    }
}

# Снимает владение и права, затем удаляет путь внутри смонтированного образа.
function Remove-ImagePath {
    param([string]$FullPath, [string]$Description)
    $FullPath = Assert-ChildPath -Path $FullPath -Root $mountDir -AllowLeafReparse
    if (-not (Test-Path -LiteralPath $FullPath)) { return $false }
    $size = 0
    $item = $null
    try {
        $item = Get-Item -LiteralPath $FullPath -Force
        $size = if ($item.PSIsContainer) {
            (Get-ChildItem -LiteralPath $FullPath -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        } else { $item.Length }
    } catch { }

    $isLeafReparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if ($isLeafReparse -and $item.PSIsContainer) {
        # Remove-Item -Recurse для junction/symlink каталога может затронуть цель.
        # Таких объектов скрипт не удаляет автоматически.
        Write-Note (T "$Description — ссылка-каталог пропущена" "$Description - directory reparse point skipped")
        return $false
    }
    Grant-ImagePathAccess -Path $FullPath -Recurse:([bool]$item.PSIsContainer)
    try {
        if ($isLeafReparse) {
            # WIM/WOF file reparse point: remove the file entry, never traverse it.
            Remove-Item -LiteralPath $FullPath -Force -ErrorAction Stop
        } else {
            Remove-Item -LiteralPath $FullPath -Recurse -Force -ErrorAction Stop
        }
        Write-Ok (T "$Description — удалено ($(Format-Size $size))" "$Description - removed ($(Format-Size $size))")
        $script:FreedBytes += $size
        return $true
    } catch {
        Write-Note (T "$Description — не удалось удалить: $($_.Exception.Message)" "$Description - could not remove: $($_.Exception.Message)")
        return $false
    }
}

#endregion

#region ── Microsoft Update Catalog ─────────────────────────────────────────────

function Search-Catalog {
    param([Parameter(Mandatory)][string]$Query)
    if ($script:DownloadsClosed) { throw (T 'Поиск в сети после подготовки запрещён' 'Network lookup is closed after preparation') }
    $url = 'https://www.catalog.update.microsoft.com/Search.aspx?q=' + [uri]::EscapeDataString($Query)
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
    $rows = [regex]::Matches($resp.Content, '(?s)<tr[^>]*id="([0-9a-f\-]{36})_R\d+".*?</tr>')
    foreach ($row in $rows) {
        $cells = [regex]::Matches($row.Value, '(?s)<td[^>]*>(.*?)</td>') |
                 ForEach-Object { (($_.Groups[1].Value -replace '<[^>]+>', ' ') -replace '&nbsp;', ' ' -replace '\s+', ' ').Trim() }
        if ($cells.Count -lt 7) { continue }
        # Каталог отдаёт дату в формате M/d/yyyy независимо от локали клиента
        $date = [datetime]::MinValue
        try { $date = [datetime]::Parse($cells[4], [Globalization.CultureInfo]::InvariantCulture) } catch { }
        [PSCustomObject]@{
            Id      = $row.Groups[1].Value
            Title   = $cells[1]
            Product = $cells[2]
            Date    = $date
            SizeMB  = [double]($cells[6] -replace '[^\d\.]', '')
        }
    }
}

# Возвращает прямые ссылки на .msu. Для 24H2 каталог отдаёт вместе с целевым
# обновлением ещё и checkpoint — оба нужны, DISM разберётся сам.
function Get-CatalogLinks {
    param([Parameter(Mandatory)][string]$UpdateId)
    if ($script:DownloadsClosed) { throw (T 'Поиск в сети после подготовки запрещён' 'Network lookup is closed after preparation') }
    $payload = '[{"size":0,"languages":"","uidInfo":"' + $UpdateId + '","updateID":"' + $UpdateId + '"}]'
    $resp = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' `
                              -Method Post -Body @{ updateIDs = $payload } -UseBasicParsing -TimeoutSec 60
    [regex]::Matches($resp.Content, "(?<=downloadInformation\[\d+\]\.files\[\d+\]\.url = ')[^']+") |
        ForEach-Object { $_.Value }
}

function Save-Url {
    param([string]$Url, [string]$Destination)
    if ($script:DownloadsClosed) { throw (T 'Загрузка после начала обработки образа запрещена' 'Downloads are closed after image processing starts') }
    $name = Split-Path $Destination -Leaf
    $marker = "$Destination.size"
    if (Test-SavedUrl $Destination) {
        Write-Ok (T "$name — уже в кэше" "$name - already cached")
        return
    }
    Write-Step (T "Загрузка $name ..." "Downloading $name ...")
    # Незавершённая загрузка никогда не становится готовым файлом кэша.
    $partial = "$Destination.part"
    try {
        & curl.exe -L --fail --connect-timeout 15 --speed-limit 1024 --speed-time 60 --retry 2 --retry-delay 3 -o $partial $Url
        if ($LASTEXITCODE -ne 0) { throw (T "Не удалось скачать $Url (curl код $LASTEXITCODE)" "Failed to download $Url (curl code $LASTEXITCODE)") }
        $size = (Get-Item -LiteralPath $partial).Length
        if ($size -le 0) { throw (T "Получен пустой файл: $name" "Downloaded file is empty: $name") }
        Remove-Item -LiteralPath $marker, "$Destination.sha256" -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $partial -Destination $Destination -Force
        Set-Content -LiteralPath "$Destination.sha256" -Value (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -Encoding ascii
        Set-Content -LiteralPath $marker -Value $size -Encoding ascii
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
    Write-Ok (T "$name — загружено ($(Format-Size $size))" "$name - downloaded ($(Format-Size $size))")
}

function Test-SavedUrl {
    param([string]$Path)
    try {
        $expected = [int64](Get-Content -LiteralPath "$Path.size" -Raw -ErrorAction Stop).Trim()
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($file.PSIsContainer -or $expected -le 0 -or $file.Length -ne $expected) { return $false }
        if (Test-Path -LiteralPath "$Path.sha256") {
            $hash = (Get-Content -LiteralPath "$Path.sha256" -Raw -ErrorAction Stop).Trim()
            if ($hash -notmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $hash) { return $false }
        }
        return $true
    } catch { return $false }
}

# Манифест записывается только для полного комплекта, включая checkpoint MSU.
# Хэши позволяют пользоваться кэшем без GitHub/UUP/Update Catalog.
function Read-PreparedCache {
    param([string]$Directory, [string]$Key)
    try {
        $manifest = Get-Content -LiteralPath (Join-Path $Directory "$Key.ready.json") -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($manifest.Schema -ne 1 -or $manifest.Key -ne $Key -or -not @($manifest.Files).Count) { return }
        foreach ($entry in $manifest.Files) {
            $path = Assert-ChildPath -Path (Join-Path $Directory $entry.Name) -Root $Directory
            $file = Get-Item -LiteralPath $path -ErrorAction Stop
            if ($file.PSIsContainer -or $file.Length -le 0 -or $file.Length -ne $entry.Size -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.SHA256) { return }
        }
        return $manifest
    } catch { return }
}

function Write-PreparedCache {
    param([string]$Directory, [string]$Key, [string[]]$Files, $Data)
    if (-not $Files.Count) { throw (T 'Пустой комплект загрузки' 'Empty download set') }
    $root = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $entries = @(foreach ($path in $Files) {
        $full = Assert-ChildPath -Path $path -Root $root
        $file = Get-Item -LiteralPath $full
        if ($file.PSIsContainer -or $file.Length -le 0) { throw (T "Пустой файл: $full" "Empty file: $full") }
        [ordered]@{ Name = $full.Substring($root.Length + 1); Size = $file.Length; SHA256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash }
    })
    $manifest = [ordered]@{ Schema = 1; Key = $Key; Files = $entries; Data = $Data }
    $path = Join-Path $Directory "$Key.ready.json"
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$path.part" -Encoding UTF8
    Move-Item -LiteralPath "$path.part" -Destination $path -Force
}

function Confirm-SkipDownload {
    param([string]$Component, [string]$Reason)
    Write-Note (T "Не удалось подготовить ${Component}: $Reason" "Could not prepare ${Component}: $Reason")
    if (-not (Test-CanPrompt)) {
        throw (T "Сборка отменена: нельзя спросить, продолжать ли без $Component. Повторите запуск в интерактивной консоли или уберите этот компонент из параметров." "Build cancelled: cannot ask whether to continue without $Component. Run in an interactive console or remove this component from the options.")
    }
    if (-not (Read-YesNo -Question (T "Продолжить без «$Component»? Нет — отменить сборку" "Continue without '$Component'? No cancels the build") -Default $false)) {
        throw (T 'Сборка отменена до обработки образа' 'Build cancelled before image processing')
    }
    $script:SkippedDownloads += $Component
    Write-Note (T "Продолжаю без: $Component" "Continuing without: $Component")
}

function Remove-ForeignUpdateFiles {
    param([string]$Directory, [string[]]$Expected)
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter *.msu -File | Where-Object { $_.Name -notin $Expected })) {
        $null = Assert-ChildPath -Path $file.FullName -Root $Directory
        Remove-Item -LiteralPath $file.FullName -Force
        Remove-Item -LiteralPath "$($file.FullName).size" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$($file.FullName).sha256" -Force -ErrorAction SilentlyContinue
    }
}

function Get-LocalUpdatePayload {
    param([string]$Directory, [string]$FileName)
    $target = Get-UpdateTarget -Directory $Directory -FileName $FileName
    if ($target.PSIsContainer -or $target.Length -le 0) { throw (T "Пустой локальный MSU: $($target.FullName)" "Empty local MSU: $($target.FullName)") }
    if (Test-Path -LiteralPath (Join-Path $Directory 'update.ready.json')) {
        if (-not (Read-PreparedCache -Directory $Directory -Key 'update')) {
            throw (T "Неполный или повреждённый комплект обновлений: $Directory" "Incomplete or corrupt update set: $Directory")
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter *.msu -File)) {
        if ($file.Length -le 0 -or ((Test-Path -LiteralPath "$($file.FullName).size") -and -not (Test-SavedUrl $file.FullName))) {
            throw (T "Неполный или повреждённый MSU: $($file.Name)" "Incomplete or corrupt MSU: $($file.Name)")
        }
    }
    $target
}

function Save-CatalogPayload {
    param([string]$Query, [string]$Directory, [string]$TitlePattern = 'Cumulative Update', [switch]$CacheFirst)
    if ($script:DownloadsClosed) { throw (T 'Подготовка загрузок уже завершена' 'Download preparation is already complete') }
    $cached = Read-PreparedCache -Directory $Directory -Key 'update'
    if (-not ($CacheFirst -and $cached)) {
        try {
            $update = Search-Catalog -Query $Query | Where-Object {
                $_.Title -match $TitlePattern -and $_.Title -notmatch 'Dynamic|Preview' -and
                ($TitlePattern -eq '\.NET Framework' -or $_.Title -notmatch '\.NET')
            } | Sort-Object Date -Descending | Select-Object -First 1
            if (-not $update) { throw (T "Обновление не найдено: $Query" "Update not found: $Query") }
            if ($update.Title -notmatch '\((KB\d+)\)') { throw (T 'В названии обновления нет KB' 'Update title has no KB identifier') }
            $kb = $matches[1]
            Write-Ok $update.Title
            $null = New-Item -ItemType Directory -Path $Directory -Force
            $files = @(foreach ($url in @(Get-CatalogLinks -UpdateId $update.Id)) {
                $name = [IO.Path]::GetFileName(([uri]$url).LocalPath)
                if ($name -notmatch '\.msu$') { continue }
                $path = Join-Path $Directory $name
                Save-Url -Url $url -Destination $path
                $path
            })
            $targets = @($files | Where-Object { (Split-Path $_ -Leaf) -match "$kb(?:_|\.|-)" })
            if ($targets.Count -ne 1) { throw (T "Не найден единственный MSU для $kb" "Cannot identify a unique MSU for $kb") }
            $targetName = Split-Path $targets[0] -Leaf
            Remove-ForeignUpdateFiles -Directory $Directory -Expected @($files | ForEach-Object { Split-Path $_ -Leaf })
            Set-Content -LiteralPath (Join-Path $Directory 'target.txt') -Value $targetName -Encoding ascii
            Write-PreparedCache -Directory $Directory -Key 'update' -Files $files -Data @{ Target = $targetName; Title = $update.Title }
            return $targets[0]
        } catch {
            $reason = $_.Exception.Message
            # Проверяем заново: неудачный новый комплект мог изменить файлы старого.
            $cached = Read-PreparedCache -Directory $Directory -Key 'update'
            if (-not $cached) { throw }
            Write-Note (T "Новые обновления недоступны: $reason" "New updates are unavailable: $reason")
        }
    }
    if ($cached.Data.Target -notin @($cached.Files.Name)) { throw (T 'В кэше нет целевого MSU' 'Cached target MSU is missing') }
    Remove-ForeignUpdateFiles -Directory $Directory -Expected @($cached.Files.Name)
    Set-Content -LiteralPath (Join-Path $Directory 'target.txt') -Value $cached.Data.Target -Encoding ascii
    Write-Ok (T "Использую полный проверенный кэш: $($cached.Data.Title)" "Using the complete verified cache: $($cached.Data.Title)")
    Join-Path $Directory $cached.Data.Target
}

function Save-WingetPayload {
    param([string]$Directory)
    if ($script:DownloadsClosed) { throw (T 'Подготовка загрузок уже завершена' 'Download preparation is already complete') }
    $cached = Read-PreparedCache -Directory $Directory -Key 'winget'
    if (-not $cached) {
        $null = New-Item -ItemType Directory -Path $Directory -Force
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers @{ 'User-Agent' = 'win-11-lite' } -TimeoutSec 30
        $bundleAsset = $release.assets | Where-Object { $_.name -like '*.msixbundle' } | Select-Object -First 1
        $licenseAsset = $release.assets | Where-Object { $_.name -like '*License1.xml' } | Select-Object -First 1
        $depsAsset = $release.assets | Where-Object { $_.name -eq 'DesktopAppInstaller_Dependencies.zip' } | Select-Object -First 1
        $assets = @($bundleAsset, $licenseAsset, $depsAsset)
        foreach ($asset in $assets) {
            if (-not $asset -or -not $asset.browser_download_url -or [IO.Path]::GetFileName($asset.name) -ne $asset.name) {
                throw (T 'В релизе winget нет полного комплекта: bundle, лицензия, зависимости' 'Winget release is missing its bundle, license or dependencies')
            }
            Save-Url -Url $asset.browser_download_url -Destination (Join-Path $Directory $asset.name)
        }
        $data = @{ Bundle = $bundleAsset.name; License = $licenseAsset.name; Dependencies = $depsAsset.name; Version = $release.tag_name }
    } else {
        $data = $cached.Data
        Write-Ok (T "winget $($data.Version) — полный комплект в кэше" "winget $($data.Version) - complete set cached")
    }
    $bundle = Assert-ChildPath -Path (Join-Path $Directory $data.Bundle) -Root $Directory
    $license = Assert-ChildPath -Path (Join-Path $Directory $data.License) -Root $Directory
    $deps = Assert-ChildPath -Path (Join-Path $Directory $data.Dependencies) -Root $Directory
    $depsDir = Assert-ChildPath -Path (Join-Path $Directory 'deps') -Root $Directory
    if (Test-Path -LiteralPath $depsDir) { Remove-Item -LiteralPath $depsDir -Recurse -Force }
    Expand-Archive -LiteralPath $deps -DestinationPath $depsDir -Force
    $depFiles = @(Get-ChildItem -LiteralPath $depsDir -Recurse -File |
        Where-Object { $_.Extension -in @('.appx', '.msix') -and $_.FullName -match '\\(x64|neutral)\\' })
    if (-not $depFiles.Count) { throw (T 'В архиве winget нет зависимостей x64/neutral' 'Winget archive has no x64/neutral dependencies') }
    $null = [xml](Get-Content -LiteralPath $license -Raw)
    Write-PreparedCache -Directory $Directory -Key 'winget' -Files @($bundle, $license, $deps) -Data $data
    [pscustomobject]@{ Bundle = $bundle; License = $license; Dependencies = @($depFiles.FullName); Version = $data.Version }
}

#endregion

#region ── Языковые пакеты ──────────────────────────────────────────────────────

# Имена отличаются между источниками:
#   LoF ISO : Microsoft-Windows-Client-Language-Pack_x64_ru-ru.cab
#   UUP     : Microsoft-Windows-Client-LanguagePack-Package-amd64-ru-RU.esd
# Поэтому подбираем регулярным выражением, а не точным именем.
function Get-SetupFontPackage {
    param([string]$Tag)
    if ($Tag -in @('ja-JP','ko-KR','zh-CN','zh-HK','zh-TW')) { return "WinPE-FontSupport-$($Tag.ToUpperInvariant()).cab" }
    if ($Tag -eq 'th-TH') { return 'WinPE-FontSupport-WinRE.cab' }
}

function Get-CabIdentity {
    param([string]$Path, [string]$Scratch)
    $null = New-Item -ItemType Directory -Path $Scratch -Force
    $mum = Join-Path $Scratch 'update.mum'
    if (Test-Path -LiteralPath $mum) { Remove-Item -LiteralPath $mum -Force }
    $result = Invoke-NativeQuiet expand.exe @($Path, '-F:update.mum', $Scratch)
    if ($result -ne 0 -or -not (Test-Path -LiteralPath $mum)) { throw (T "Не удалось прочитать CAB: $Path" "Could not read CAB: $Path") }
    ([xml](Get-Content -LiteralPath $mum -Raw)).assembly.assemblyIdentity
}

function Save-SetupLanguagePayload {
    param([string]$Tag, [int]$Build, [string]$Directory, [string]$Source)
    if ($script:DownloadsClosed) { throw (T 'Подготовка загрузок уже завершена' 'Download preparation is already complete') }
    $tagLower = $Tag.ToLowerInvariant()
    if ($tagLower -notmatch '^[a-z]{2}-[a-z]{2}$') { throw (T "Язык WinPE не поддерживается: $Tag" "Unsupported WinPE language: $Tag") }
    $required = @('lp.cab', "WinPE-Setup_$tagLower.cab", "WinPE-Setup-Client_$tagLower.cab")
    $font = Get-SetupFontPackage $Tag
    $key = "setup-$Build-$tagLower"
    $dir = Join-Path $Directory $key
    $localeDir = Join-Path $dir $tagLower
    $cached = Read-PreparedCache -Directory $dir -Key 'setup'
    if ($cached -and @($required | Where-Object { "$tagLower/$_" -notin @($cached.Files.Name -replace '\\','/') }).Count -eq 0 -and
        (-not $font -or $font -in @($cached.Files.Name))) {
        Write-Ok (T "Установщик $Tag — полный комплект WinPE в кэше" "Setup $Tag - complete WinPE set cached")
        return [pscustomobject]@{ Tag=$Tag; Build=$Build; Directory=$dir; LocaleDirectory=$localeDir; Font=$font }
    }
    $null = New-Item -ItemType Directory -Path $localeDir -Force
    $files = @()
    if ($Source) {
        $sourceLocale = Join-Path $Source $tagLower
        foreach ($name in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $sourceLocale $name) -PathType Leaf)) { throw (T "Нет $name в $sourceLocale" "Missing $name in $sourceLocale") }
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $sourceLocale -Filter *.cab -File)) {
            $dest = Join-Path $localeDir $file.Name
            Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
            $files += $dest
        }
        if ($font) {
            $dest = Join-Path $dir $font
            Copy-Item -LiteralPath (Join-Path $Source $font) -Destination $dest -Force
            $files += $dest
        }
    } else {
        if ($Build -ne 26100) { throw (T "Автозагрузка WinPE для билда $Build не настроена. Укажите совместимый каталог -SetupLanguageSource <WinPE_OCs>." "WinPE downloads for build $Build are not configured. Supply matching -SetupLanguageSource <WinPE_OCs>.") }
        $catalog = Get-BundledResource -Name "winpe-$Build.json" | ConvertFrom-Json
        if ($catalog.Build -ne $Build -or $catalog.Architecture -ne 'amd64') { throw (T 'Несовместимый каталог WinPE' 'Incompatible WinPE catalog') }
        $selected = @($catalog.Files | Where-Object { $_.Path -like "$tagLower/*" -or ($font -and $_.Path -eq $font) })
        foreach ($name in $required) {
            if ("$tagLower/$name" -notin @($selected.Path)) { throw (T "Microsoft WinPE не содержит $name" "Microsoft WinPE does not contain $name") }
        }
        if ($font -and $font -notin @($selected.Path)) { throw (T "Нет обязательных шрифтов $font" "Required fonts missing: $font") }
        $archiveDir = Join-Path $Directory "winpe-$Build-archives"
        $null = New-Item -ItemType Directory -Path $archiveDir -Force
        foreach ($archiveName in @($selected.Archive | Sort-Object -Unique)) {
            $archive = $catalog.Archives | Where-Object { $_.Name -eq $archiveName } | Select-Object -First 1
            if (-not $archive -or [IO.Path]::GetFileName($archiveName) -ne $archiveName) { throw (T 'Неверный архив WinPE' 'Invalid WinPE archive') }
            $archivePath = Join-Path $archiveDir $archiveName
            # SHA1 взят из манифеста подписанного Microsoft bootstrapper, не с сайта-зеркала.
            $valid = (Test-Path -LiteralPath $archivePath) -and (Get-Item -LiteralPath $archivePath).Length -eq $archive.Size -and
                (Get-FileHash -LiteralPath $archivePath -Algorithm SHA1).Hash -eq $archive.SHA1
            if (-not $valid) {
                Remove-Item -LiteralPath "$archivePath.size" -Force -ErrorAction SilentlyContinue
                Write-Step (T "Загружаю комплект языков WinPE ($(Format-Size $archive.Size)); повторно он не скачивается" "Downloading WinPE language archive ($(Format-Size $archive.Size)); it will be reused")
                Save-Url -Url ($catalog.BaseUrl + $archiveName) -Destination $archivePath
                if ((Get-Item -LiteralPath $archivePath).Length -ne $archive.Size -or (Get-FileHash -LiteralPath $archivePath -Algorithm SHA1).Hash -ne $archive.SHA1) {
                    throw (T "Контрольная сумма архива WinPE не совпала: $archiveName" "WinPE archive checksum mismatch: $archiveName")
                }
            }
            $extractDir = Join-Path $archiveDir 'extract'
            $null = New-Item -ItemType Directory -Path $extractDir -Force
            # Один проход по CAB: последовательная распаковка каждого файла повторяла бы чтение 305 МБ.
            $result = Invoke-NativeQuiet expand.exe @($archivePath, '-F:*', $extractDir)
            if ($result -ne 0) { throw (T 'Не удалось распаковать архив WinPE' 'Failed to extract WinPE archive') }
            foreach ($entry in @($selected | Where-Object { $_.Archive -eq $archiveName })) {
                if ($entry.Member -notmatch '^fil[a-f0-9]{32}$') { throw (T 'Неверное имя файла WinPE' 'Invalid WinPE member name') }
                $dest = Assert-ChildPath -Path (Join-Path $dir $entry.Path) -Root $dir
                $file = Get-Item -LiteralPath (Join-Path $extractDir $entry.Member)
                if ($file.Length -ne $entry.Size) { throw (T "Неполный файл WinPE: $($entry.Path)" "Incomplete WinPE file: $($entry.Path)") }
                Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
                $files += $dest
            }
            $null = Assert-ChildPath -Path $extractDir -Root $archiveDir
            Remove-Item -LiteralPath $extractDir -Recurse -Force
        }
    }
    foreach ($name in $required) {
        $identity = Get-CabIdentity -Path (Join-Path $localeDir $name) -Scratch (Join-Path $dir 'metadata')
        $expectedName = if ($name -eq 'lp.cab') { 'Microsoft-Windows-WinPE-LanguagePack-Package' } else { ($name -split '_')[0] + '-Package' }
        if ($identity.name -ne $expectedName -or $identity.processorArchitecture -ne 'amd64' -or
            $identity.language -ne $Tag -or ([version]$identity.version).Build -ne $Build) {
            throw (T "Несовместимый пакет WinPE: $name ($($identity.OuterXml))" "Incompatible WinPE package: $name ($($identity.OuterXml))")
        }
    }
    foreach ($stale in @(Get-ChildItem -LiteralPath $localeDir -Filter *.cab -File | Where-Object { $_.FullName -notin $files })) {
        $null = Assert-ChildPath -Path $stale.FullName -Root $dir
        Remove-Item -LiteralPath $stale.FullName -Force
    }
    Write-PreparedCache -Directory $dir -Key 'setup' -Files $files -Data @{Tag=$Tag;Build=$Build}
    [pscustomobject]@{ Tag=$Tag; Build=$Build; Directory=$dir; LocaleDirectory=$localeDir; Font=$font }
}

function Add-SetupLanguage {
    param([string]$Image, [string]$WindowsImage, [string]$Distribution, $Payload, [string]$RepairUpdate, [switch]$Legacy)
    $tag = $Payload.Tag
    $inventory = Invoke-Dism -Arguments @("/Image:$Image", '/Get-Packages') -Quiet
    $packages = @(ConvertFrom-DismList -Lines $inventory.Output -Key 'Package Identity')
    $names = @($packages | Where-Object { $_.'Package Identity' -match '^WinPE-.+-Package~[^~]+~amd64~~' } |
        ForEach-Object { ($_.'Package Identity' -split '-Package~')[0] } | Sort-Object -Unique)
    foreach ($required in @('WinPE-Setup','WinPE-Setup-Client')) {
        if ($required -notin $names) { throw (T "В boot.wim нет $required" "boot.wim does not contain $required") }
    }
    $paths = @((Join-Path $Payload.LocaleDirectory 'lp.cab'))
    foreach ($name in $names) {
        $file = Join-Path $Payload.LocaleDirectory "${name}_$tag.cab"
        if (Test-Path -LiteralPath $file -PathType Leaf) { $paths += $file }
        elseif ($name -in @('WinPE-Setup','WinPE-Setup-Client','WinPE-LegacySetup')) { throw (T "Нет языкового пакета $name для $tag" "Missing $name language package for $tag") }
    }
    if ($Payload.Font) { $paths += Join-Path $Payload.Directory $Payload.Font }
    foreach ($path in $paths) {
        Invoke-Dism -Arguments @("/Image:$Image", '/Add-Package', "/PackagePath:$path") -Activity (T "Язык установщика: $(Split-Path $path -Leaf)" "Setup language: $(Split-Path $path -Leaf)") | Out-Null
    }
    if ($RepairUpdate) {
        Invoke-Dism -Arguments @("/Image:$Image", '/Add-Package', "/PackagePath:$RepairUpdate") -Activity (T 'Обновление языковых ресурсов WinPE' 'Servicing WinPE language resources') | Out-Null
    }
    Invoke-Dism -Arguments @("/Image:$Image", "/Set-AllIntl:$tag") -Quiet | Out-Null
    # Ресурсы обоих установщиков доставлены пакетами WinPE. Копируем уже
    # обслуженные файлы из boot.wim; русскоязычный ISO-донор не требуется.
    $resources = Join-Path $Image "sources\$tag"
    $requiredMui = @('setup.exe.mui', 'spwizres.dll.mui')
    if (-not $Legacy -and $Payload.Build -ge 26100) { $requiredMui += 'mediasetupuimgr.dll.mui' }
    foreach ($name in $requiredMui) {
        $file = Get-Item -LiteralPath (Join-Path $resources $name) -ErrorAction Stop
        if ($file.Length -le 0) { throw (T "Пустой ресурс установщика: $name" "Empty Setup resource: $name") }
    }
    $dest = Join-Path $Distribution "sources\$tag"
    $null = New-Item -ItemType Directory -Path $dest -Force
    Get-ChildItem -LiteralPath $resources -Force | Copy-Item -Destination $dest -Recurse -Force
    foreach ($name in @('setup.exe','setuphost.exe')) {
        $file = Join-Path $Image "sources\$name"
        if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination (Join-Path $Distribution "sources\$name") -Force }
    }
    Invoke-Dism -Arguments @("/Image:$WindowsImage", '/Gen-LangINI', "/Distribution:$Distribution") -Quiet | Out-Null
    Invoke-Dism -Arguments @("/Image:$Image", "/Set-SetupUILang:$tag", "/Distribution:$Distribution") -Quiet | Out-Null
    Copy-Item -LiteralPath (Join-Path $Distribution 'sources\lang.ini') -Destination (Join-Path $Image 'sources\lang.ini') -Force
    $intl = Invoke-Dism -Arguments @("/Image:$Image", '/Get-Intl') -Quiet
    if (-not @($intl.Output | Where-Object { $_ -match ('Default system UI language\s*:\s*' + [regex]::Escape($tag) + '\s*$') }).Count) {
        throw (T "Язык WinPE $tag не подтверждён DISM" "WinPE language $tag was not confirmed by DISM")
    }
    Write-Ok (T "Установщик переведён на $tag" "Setup translated to $tag")
}

function Get-LanguagePattern {
    param([string]$Tag, [string]$Kind)
    $t = [regex]::Escape($Tag)
    switch ($Kind) {
        'Pack' { "Client-Language-?Pack.*$t.*\.(cab|esd)$" }
        'LXP'  { "LanguageExperiencePack.*$t.*\.(appx|appxbundle)$" }
        default { "LanguageFeatures-$Kind-$t.*\.(cab|esd)$" }
    }
}

function Find-LanguagePackage {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][ValidateSet('Pack', 'Basic', 'Handwriting', 'OCR', 'Speech', 'TextToSpeech', 'LXP')][string]$Kind
    )
    $pattern = Get-LanguagePattern -Tag $Tag -Kind $Kind
    Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern } |
        Sort-Object Length -Descending | Select-Object -First 1
}

function Get-FodSourceName {
    param([string]$Tag, [string]$Kind = 'Basic')
    "Microsoft-Windows-LanguageFeatures-$Kind-$($Tag.ToLowerInvariant())-Package~31bf3856ad364e35~amd64~~.cab"
}

function Assert-ImageLanguages {
    param([string]$Image, [string[]]$Languages, [string]$SourceLanguage)
    foreach ($tag in $Languages) {
        $info = Invoke-Dism -Arguments @("/Image:$Image", '/Get-CapabilityInfo', "/CapabilityName:Language.Basic~~~$tag~0.0.1.0") -Quiet
        if (-not @($info.Output | Where-Object { $_ -match '^\s*State\s*:\s*Installed\s*$' }).Count) {
            throw (T "Language.Basic для $tag не установлен — сборка остановлена" "Language.Basic for $tag is not installed; build stopped")
        }
        # Regression for the supplied screenshot: English Settings on a Russian OS.
        # Compare the same MUI file across languages, not MUI versus EXE versions.
        if ($tag -eq 'ru-RU' -and $SourceLanguage -ne $tag) {
            $baseMui = Join-Path $Image "Windows\ImmersiveControlPanel\$SourceLanguage\SystemSettings.exe.mui"
            $newMui = Join-Path $Image "Windows\ImmersiveControlPanel\$tag\SystemSettings.exe.mui"
            if (-not (Test-Path -LiteralPath $newMui)) { throw (T 'Отсутствуют русские ресурсы приложения Параметры' 'Russian Settings resources are missing') }
            foreach ($relative in @(
                "Windows\ImmersiveControlPanel\pris\resources.$tag.pri",
                "Windows\SystemResources\Windows.UI.SettingsAppThreshold\pris\Windows.UI.SettingsAppThreshold.$tag.pri"
            )) {
                $resource = Get-Item -LiteralPath (Join-Path $Image $relative) -ErrorAction SilentlyContinue
                if (-not $resource -or $resource.Length -eq 0) {
                    throw (T "Отсутствует языковой PRI-ресурс Параметров: $relative" "Settings language PRI resource is missing: $relative")
                }
            }
            if (Test-Path -LiteralPath $baseMui) {
                $a = [Diagnostics.FileVersionInfo]::GetVersionInfo($baseMui)
                $b = [Diagnostics.FileVersionInfo]::GetVersionInfo($newMui)
                $sourceVersion = [version]("{0}.{1}.{2}.{3}" -f $a.FileMajorPart,$a.FileMinorPart,$a.FileBuildPart,$a.FilePrivatePart)
                $targetVersion = [version]("{0}.{1}.{2}.{3}" -f $b.FileMajorPart,$b.FileMinorPart,$b.FileBuildPart,$b.FilePrivatePart)
                if ($targetVersion -lt $sourceVersion) {
                    throw (T "Русские ресурсы Параметров устарели ($targetVersion < $sourceVersion). Нужен повторный LCU после добавления языка." "Russian Settings resources are older ($targetVersion < $sourceVersion). Reapply the LCU after adding the language.")
                }
            }
        }
    }
}

function Get-UpdateTarget {
    param([string]$Directory, [string]$FileName)
    if (-not $FileName) {
        $marker = Join-Path $Directory 'target.txt'
        if (Test-Path -LiteralPath $marker) { $FileName = (Get-Content -LiteralPath $marker -Raw).Trim() }
    }
    if ($FileName) {
        if ([IO.Path]::GetFileName($FileName) -ne $FileName) { throw (T 'Нужно имя MSU внутри папки кэша, без пути' 'Specify an MSU filename within the cache, without a path') }
        $file = Get-Item -LiteralPath (Join-Path $Directory $FileName) -ErrorAction Stop
        if ($file.Extension -ne '.msu') { throw (T 'Целевое обновление должно быть MSU' 'Target update must be an MSU') }
        return $file
    }
    $files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.msu' -File -ErrorAction SilentlyContinue)
    if ($files.Count -ne 1) {
        throw (T "Нельзя однозначно выбрать обновление в $Directory. Задайте -LcuFile или -DotNetUpdateFile; выбор по размеру ненадёжен." "Cannot identify the target update in $Directory. Specify -LcuFile or -DotNetUpdateFile; size is not a reliable selection rule.")
    }
    $files[0]
}

function Write-WindowsBatchFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    # cmd.exe некорректно разбирает UTF-8 с LF после chcp 65001.
    # Формат CMD не должен зависеть от переводов строк самого PS1.
    $text = [regex]::Replace($Content, '\r\n|\r|\n', "`r`n").TrimEnd("`r", "`n") + "`r`n"
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
}

function Write-FirefoxInstallerFile {
    param([string]$Path, [string]$Content)
    Write-WindowsBatchFile -Path $Path -Content $Content
    # Общий рабочий стол читается обычными пользователями. Разрешаем удалить
    # только этот одноразовый файл, чтобы не запрашивать UAC после установки.
    $acl = Get-Acl -LiteralPath $Path
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($users, [Security.AccessControl.FileSystemRights]::Delete, [Security.AccessControl.AccessControlType]::Allow)
    $null = $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-FirefoxInstallerCommand {
    param([string]$Language = 'en-US', [ValidatePattern('^[a-zA-Z0-9-]+$')][string]$MozillaLanguage = 'en-US')
    $ru = $Language -like 'ru*'
    $title = if ($ru) { 'Установка Mozilla Firefox' } else { 'Installing Mozilla Firefox' }
    $tryWinget = if ($ru) { 'Пробую через winget...' } else { 'Trying winget...' }
    $fallback = if ($ru) { 'winget не справился, качаю установщик напрямую...' } else { 'winget failed, downloading the installer directly...' }
    $noNet = if ($ru) { 'Не удалось скачать установщик. Проверьте подключение к интернету.' } else { 'Could not download the installer. Check your internet connection.' }
    $installError = if ($ru) { 'Установщик завершился с кодом' } else { 'Installer exited with code' }
    $done = if ($ru) { 'Готово.' } else { 'Done.' }
    @"
@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
title Install Firefox
echo.
echo  $title
echo.
where winget >nul 2>&1
if not errorlevel 1 (
    echo  $tryWinget
    winget install --id Mozilla.Firefox -e --accept-package-agreements --accept-source-agreements
    if errorlevel 0 if not errorlevel 1 goto :done
    echo.
    echo  $fallback
)
set "FFSETUP=%TEMP%\Win11Lite-Firefox-%RANDOM%-%RANDOM%.exe"
curl.exe -L --fail --retry 2 -o "%FFSETUP%" "https://download.mozilla.org/?product=firefox-latest&os=win64&lang=$MozillaLanguage"
if errorlevel 1 (
    del /f /q "%FFSETUP%" >nul 2>&1
    echo  $noNet
    pause
    exit /b 1
)
start "" /wait "%FFSETUP%"
set "FFRESULT=%ERRORLEVEL%"
del /f /q "%FFSETUP%" >nul 2>&1
if not "%FFRESULT%"=="0" (
    echo  $installError %FFRESULT%.
    pause
    exit /b %FFRESULT%
)
:done
echo.
echo  $done
timeout /t 3 >nul 2>&1
(goto) 2>nul & del /f /q "%~f0" >nul 2>&1
"@
}

#region Bundled resources
# Generated from data/ by tools/Update-BundledResources.ps1. No external files are read at runtime.
function Get-BundledResource {
    param([Parameter(Mandatory)][string]$Name)
    $text = switch ($Name) {
        'deployment-tools-28000.json' {
'{
  "Schema": 1,
  "Build": 28000,
  "Architecture": "amd64",
  "AdkVersion": "10.1.28000.1",
  "Source": "https://go.microsoft.com/fwlink/?linkid=2337875",
  "Archives": [
    {
      "Name": "7e6e508fe7702607bff0b24b764e4990.cab",
      "Url": "https://download.microsoft.com/download/615540bc-be0b-433a-b91b-1f2b0642bb24/adk/Installers/7e6e508fe7702607bff0b24b764e4990.cab",
      "Size": 22144,
      "SHA1": "DCF99A8B8D95C403A72EDB1129022DC9FB8A439A",
      "Files": [
        {
          "Source": "fil10629605047f88042483d018c9ec7360",
          "Path": "amd64\\DISM\\zh-tw\\siloedpackageprovider.dll.mui",
          "Size": 6144,
          "SHA256": "B6C9268941CA21ED09A946F18258524F35B6ED741DF3B9D282C135CAB5956BA7"
        },
        {
          "Source": "fil10a53f73dfbab89ec1b09e83117224e1",
          "Path": "amd64\\DISM\\zh-cn\\siloedpackageprovider.dll.mui",
          "Size": 6144,
          "SHA256": "D98407BE86B7AAF57DEFC598D89A270203689F9B1D187A4FB8F6FE5B9F914C62"
        },
        {
          "Source": "fil200885fcdb70b764d20b41e6fa34d77b",
          "Path": "amd64\\DISM\\ko-kr\\siloedpackageprovider.dll.mui",
          "Size": 6144,
          "SHA256": "672D5EBAEC30A9EDCBE1AC2B8C88DDAB7830220636CAA1ABC4A9E7F8BF2A6DBE"
        },
        {
          "Source": "fil687d6dad0032a39f4f868061d198a7f7",
          "Path": "amd64\\DISM\\pt-br\\siloedpackageprovider.dll.mui",
          "Size": 6144,
          "SHA256": "0622844583F8D8648CCD165B6529E4F9A71B7A50AE6DAB63F263D3B04B461817"
        },
        {
          "Source": "fil9eb6be42a02a8a74f9805f0f831fc8b2",
          "Path": "amd64\\DISM\\fr-fr\\siloedpackageprovider.dll.mui",
          "Size": 6144,
          "SHA256": "6BD947CF8AD9CB7CF209164CD858E6248D81B62743E21E73715158243ECFA302"
        },
        {
          "Source": "filc3fe6b5230241df1d0fde7f075f01cb3",
          "Path": "amd64\\DISM\\es-es\\siloedpackageprovider.dll.mui",
          "Size": 6144,
          "SHA256": "ED8BB489450E04FE1B3B2050314E5D887F63DBE432FF17D06154C443734374F9"
        },
        {
          "Source": "fild1e81d0b544b123950ef04361ff1eb4d",
          "Path": "amd64\\DISM\\ru-ru\\siloedpackageprovider.dll.mui",
          "Size": 6144,
          "SHA256": "9C84C7ED1A6849BF065DC92F8B0F0F14847C5C2362C0641787F7DF7A6703A546"
        },
        {
          "Source": "file74677b91dc9cc86e07f0392174fe424",
          "Path": "amd64\\DISM\\ja-jp\\siloedpackageprovider.dll.mui",
          "Size": 6144,
          "SHA256": "C9E5F56D172B6DC394E31CDE6F04D2AA7FFDCCE8662BAAFCEAB5919E84330A7D"
        },
        {
          "Source": "file7646c8e3699a3ef580df65c5f3fabbd",
          "Path": "amd64\\DISM\\en-us\\siloedpackageprovider.dll.mui",
          "Size": 6144,
          "SHA256": "7801C6D33354FA6816D5BAD8F9EEB0F248244B4181EADE5EB19F1B48FFB44ACE"
        },
        {
          "Source": "fileba782597c58c45b46a82c5bcc0840ac",
          "Path": "amd64\\DISM\\it-it\\siloedpackageprovider.dll.mui",
          "Size": 6144,
          "SHA256": "0A524CA1E464D3868B2B71E15D26857580FFC8A93886F50D2D1221A4E542807C"
        },
        {
          "Source": "filec13dfc1d5d0c25b6b97b42f1654d0f1",
          "Path": "amd64\\DISM\\de-de\\siloedpackageprovider.dll.mui",
          "Size": 6144,
          "SHA256": "52D83D36FC88368E78B3C679861233CF14CF0EFC8DE68BB962CD5D43BDBC86A2"
        }
      ],
      "SHA256": "8FA5E667C61D9018A2D8EDD495DEDFDB05DE85E15E8B3E6E4A4DBCB7B5FD38AA"
    },
    {
      "Name": "831d004a8f355684ab94810176e8d4ec.cab",
      "Url": "https://download.microsoft.com/download/615540bc-be0b-433a-b91b-1f2b0642bb24/adk/Installers/831d004a8f355684ab94810176e8d4ec.cab",
      "Size": 60160,
      "SHA1": "5A5E84D0E2A9D0F332A3EFB02C6A8CF3926B2665",
      "Files": [
        {
          "Source": "fil0427d89cc7be22ef4ab93e42290e175d",
          "Path": "amd64\\DISM\\siloedpackageprovider.dll",
          "Size": 141688,
          "SHA256": "45D94DD4140320685AC7B74AB28AB6AA010592687829B879A6B7438C88FEB909"
        }
      ],
      "SHA256": "727ADAEBCB02FEA15341B973C110A5F82513FEBADD59D38030923989CB3229C8"
    },
    {
      "Name": "8624feeaa6661d6216b5f27da0e30f65.cab",
      "Url": "https://download.microsoft.com/download/615540bc-be0b-433a-b91b-1f2b0642bb24/adk/Installers/8624feeaa6661d6216b5f27da0e30f65.cab",
      "Size": 47680,
      "SHA1": "F934EB44CF71B1C045F2E2F7A118EAA3A8B84CA0",
      "Files": [
        {
          "Source": "fil07c0b0e03a282cec7eeff620914cb470",
          "Path": "amd64\\DISM\\ja-jp\\wimgapi.dll.mui",
          "Size": 10752,
          "SHA256": "A71B5DECA89DA332EDB287A0853E5649822C9B47735DF8A87045AB2278830BF7"
        },
        {
          "Source": "fil2d338f3c49ef6c9840a1aabd4593925f",
          "Path": "amd64\\DISM\\de-de\\wimgapi.dll.mui",
          "Size": 20480,
          "SHA256": "BDEFF45F8A35CE707006E28DE9C61E7DC611B240FD68AEBCEEDFEF80DD1DE903"
        },
        {
          "Source": "fil5667e7cd4fd8a42e89652ea4ec2b3ea0",
          "Path": "amd64\\DISM\\zh-tw\\wimgapi.dll.mui",
          "Size": 7680,
          "SHA256": "7928F70F0EC22BE12682B6BAD25F4B246F6A602A307A75C91037ECA5FAA1C3F3"
        },
        {
          "Source": "fil5c977e880f7f7ac861e65967eb55bb95",
          "Path": "amd64\\DISM\\es-es\\wimgapi.dll.mui",
          "Size": 17920,
          "SHA256": "F3EB8A2AF00E06C07249B0A30D1CCC2E014A241DA18C4D40391220F3DBC07F50"
        },
        {
          "Source": "fila8fbf36099ced48cb5c953ed5f8bfba6",
          "Path": "amd64\\DISM\\fr-fr\\wimgapi.dll.mui",
          "Size": 19456,
          "SHA256": "6DE01DCA8EC63E70E4E7D8F0F2DDB8FF5952C45BF776824884160FC80721917B"
        },
        {
          "Source": "filb3b938e3e11fe7c0b9563fbd53e5128b",
          "Path": "amd64\\DISM\\zh-cn\\wimgapi.dll.mui",
          "Size": 7680,
          "SHA256": "3C4A0855F90141478B25A27E2361484F1F95F0C176E1DE2D4FC06E0128A9FFA2"
        },
        {
          "Source": "filde9afefaa42125eae13683af865e36b4",
          "Path": "amd64\\DISM\\ko-kr\\wimgapi.dll.mui",
          "Size": 10240,
          "SHA256": "DA8B3EDB145705E0EA83DF3B3E2B28B798051B84EBBDA6891604A0023D82113E"
        },
        {
          "Source": "fildf4522c241fb4db2c542bb7eb5527ddc",
          "Path": "amd64\\DISM\\ru-ru\\wimgapi.dll.mui",
          "Size": 17408,
          "SHA256": "E9C6B26CA0850ADB9F8322B0A6A6ED7568352032A622979DEB42132099AE914A"
        },
        {
          "Source": "file09aa3647a272d2f6c72027cb3a5dfd4",
          "Path": "amd64\\DISM\\it-it\\wimgapi.dll.mui",
          "Size": 18432,
          "SHA256": "08EB343F732AE6500A86E3D4BC879DC32DD8C621E6C3912C010095D196F961E3"
        },
        {
          "Source": "file23d7e7d3c43b4eec1f4488d28a5f1bc",
          "Path": "amd64\\DISM\\pt-br\\wimgapi.dll.mui",
          "Size": 17920,
          "SHA256": "5FCE52473C659353C1A21687035F81084F7B1D835C87A196E865EE3A9C5371B8"
        },
        {
          "Source": "file7bf8c0d634293405b38e624668ce2a6",
          "Path": "amd64\\DISM\\en-us\\wimgapi.dll.mui",
          "Size": 16384,
          "SHA256": "83A13F9213BC9225CE2D6F6BD806A1569E99664B0B1DF8537795C9310039F5FF"
        }
      ],
      "SHA256": "4D88B3710347F9FF8B0876BED0E6740FC1FC551CE108A3A1E25E87FE68B2BFC6"
    },
    {
      "Name": "a7eb3390a15bcd2c80a978c75f2dcc4f.cab",
      "Url": "https://download.microsoft.com/download/615540bc-be0b-433a-b91b-1f2b0642bb24/adk/Installers/a7eb3390a15bcd2c80a978c75f2dcc4f.cab",
      "Size": 2241362,
      "SHA1": "CAC7BA0B44CA39FB909C1553F0EC0F79DB667B77",
      "Files": [
        {
          "Source": "filae2e2cf527fff8f24e09628a45206c97",
          "Path": "amd64\\DISM\\deployprovider.dll",
          "Size": 719264,
          "SHA256": "FB50D85D81C2B7E900D7EAC2D60EFF5A97BDAE31EA6A2F6E3FE674A568E6348E"
        },
        {
          "Source": "fil5df4699ae9e87b34e1bba2136121ea7e",
          "Path": "amd64\\DISM\\dism.exe",
          "Size": 330144,
          "SHA256": "00A6E3C6C2CDCD192CCEC94FCD94E5FEA420EF5BA9DE9FC587FFAA3973BDD905"
        },
        {
          "Source": "filffc75e13d6cd5caaca65765510bf8d50",
          "Path": "amd64\\DISM\\dism.Format.ps1xml",
          "Size": 27404,
          "SHA256": "3DEDAD2E97A73EC903D228B363D7EBFFB3350A72B267B8447C55EACAEA5ACD7B"
        },
        {
          "Source": "filc2ae17f886791fd1ae47c16bc3c6a170",
          "Path": "amd64\\DISM\\dism.psd1",
          "Size": 3318,
          "SHA256": "D96CC58B6C9DBC16059C60FE64F797E12BCAEF8F4CDAE9A3242B74F494CE043E"
        },
        {
          "Source": "fil12ddaade2166e11368fa9861bdb13704",
          "Path": "amd64\\DISM\\dism.psm1",
          "Size": 16788,
          "SHA256": "D6D0F81EDA138414247F5DD49748579377A2CA8613CC7DDCE5CCBED3D56D34E2"
        },
        {
          "Source": "filee8a3d4167cd6dd4302de1321dce38d1",
          "Path": "amd64\\DISM\\dism.Types.ps1xml",
          "Size": 20378,
          "SHA256": "79DED6BBD74C833BB715B33687FE1CA9EFF8A769A7938EC3C81935530E042749"
        },
        {
          "Source": "file1467cef9b504782cdf6e4e203275454",
          "Path": "amd64\\DISM\\dismapi.dll",
          "Size": 1210744,
          "SHA256": "3432DC6797258C5C543A35729CF6DCE9B9BA4832B0577033E7DA6BE797795481"
        },
        {
          "Source": "fil29a5cb24b27b5cacc29dd1b9e93f60bc",
          "Path": "amd64\\DISM\\dismcore.dll",
          "Size": 534904,
          "SHA256": "A215E32F3F8552B0119693C4B3D8AE716B41E395DF5A5C379F6883D0822335F2"
        },
        {
          "Source": "fil46c001e61736775ceb28dc21d42dc139",
          "Path": "amd64\\DISM\\dismcoreps.dll",
          "Size": 244088,
          "SHA256": "5468DCEC48A6D0AD814B5E8B85717270F126530AB4169485976C16C0002A3919"
        },
        {
          "Source": "fil36e598a8fd9aee7b4ac8620ddd36cb08",
          "Path": "amd64\\DISM\\dismprov.dll",
          "Size": 301472,
          "SHA256": "A5CB0750E24FF63FD079E5AB94511B067FA96614B68FB6D3965604985195A161"
        },
        {
          "Source": "fil115b6a04b0f064d0666d190061f7d8fc",
          "Path": "amd64\\DISM\\ffuprovider.dll",
          "Size": 706968,
          "SHA256": "A46DD267559FE0C05924C0011E10B06595ABA7CFE555F7B68907B00220F3899A"
        },
        {
          "Source": "fil8bcd27caf06f979ab8d9dfa9b7fbe3bf",
          "Path": "amd64\\DISM\\folderprovider.dll",
          "Size": 96624,
          "SHA256": "6C04AC7C4C274B0C4C94D2EB4FD9B8775B4747185F9648ADD524C431FDDFAFB9"
        },
        {
          "Source": "fil2051206e8159d97acbeca53b2c6b0ae4",
          "Path": "amd64\\DISM\\imagingprovider.dll",
          "Size": 252280,
          "SHA256": "A5754CDE99A706086C0C70352D90A2B1D85EF753F8386BDC838D51C392B425DE"
        },
        {
          "Source": "file631ed944f2cd40f21aaade0b9273762",
          "Path": "amd64\\DISM\\logprovider.dll",
          "Size": 190840,
          "SHA256": "5C35DA5B34191018197837AA72F7C2B3684E065FE0BF824D6CA63F07F5B4752C"
        },
        {
          "Source": "fil04bc0d3879473c96270c5dbc1a892e6a",
          "Path": "amd64\\DISM\\Microsoft.Dism.Powershell.dll",
          "Size": 160120,
          "SHA256": "F7B61956B08DEEBE77DAED643131FC7CEBC9AEC5112F3860F9C478D23EE157D7"
        },
        {
          "Source": "filc27ff32e9f0714b5d61fa2ae19010e4d",
          "Path": "amd64\\DISM\\osimageprovider.dll",
          "Size": 567672,
          "SHA256": "FFE6AAE4597D24D127D8E4553B7F4F1F660620A3EA093364D43442DBA61D28C3"
        },
        {
          "Source": "fil1c879bd0f5001fe0610ca0e8afe3b303",
          "Path": "amd64\\DISM\\pkgmgr.exe",
          "Size": 317816,
          "SHA256": "E37C03365A179914C13FD3D337D6A1D6D3B1D1A7DBF4EE7C253D359C0154EEEE"
        },
        {
          "Source": "fil8175a3c715d1482ce03631c5035fc233",
          "Path": "amd64\\DISM\\vhdprovider.dll",
          "Size": 600480,
          "SHA256": "201684A6290E55C31ACAD1FE74F1681097459E06B355F9C205B9D7BA83E3223D"
        },
        {
          "Source": "fil23b7bb6723efd36fe466cd8fb59675a7",
          "Path": "amd64\\DISM\\wimprovider.dll",
          "Size": 702880,
          "SHA256": "D32902C17263738DD26F322865B82D910E33242FAF60CCE7974BE77C6E31DC78"
        },
        {
          "Source": "fil4b70f9579a26a772fabf39372c923657",
          "Path": "amd64\\DISM\\ssshim.dll",
          "Size": 170400,
          "SHA256": "B9234A53FF95E0BCA885B56879EAC2C1C6022F585BFC2FB885BDF46C3A747762"
        }
      ],
      "SHA256": "2AA07C8458C645B0B7C414EAF11C6568DC2D4BC48DF29B1599C80C92319A655C"
    },
    {
      "Name": "abbeaf25720d61b6b6339ada72bdd038.cab",
      "Url": "https://download.microsoft.com/download/615540bc-be0b-433a-b91b-1f2b0642bb24/adk/Installers/abbeaf25720d61b6b6339ada72bdd038.cab",
      "Size": 150430,
      "SHA1": "C7DDC3574C6C25FFA197CE0CC6A01BD4A4C828EA",
      "Files": [
        {
          "Source": "fil70d7eca70fd68d2d7114b61160d9e64a",
          "Path": "amd64\\DISM\\ru-ru\\deployprovider.dll.mui",
          "Size": 3072,
          "SHA256": "66C848CC14AB15B16689FC4357824688675A9977BD114FC12CE7E6ABFCE67C12"
        },
        {
          "Source": "fil0738659a8f7434b672786ec253b47ef4",
          "Path": "amd64\\DISM\\ru-ru\\dism.exe.mui",
          "Size": 32256,
          "SHA256": "A366ED96D9D835ECDAAF20A42BEE2415C7DE9C6E0EC694927D4D941639942A23"
        },
        {
          "Source": "fil073027846f11ca5e2b45794519a1df16",
          "Path": "amd64\\DISM\\ru-ru\\dismapi.dll.mui",
          "Size": 5120,
          "SHA256": "5CA9327204A01C2800112CD1876B2DA24ED5C26C50F5014721E180CEF255F7C4"
        },
        {
          "Source": "filf60453450be9ed172f9f3ac1f25555d5",
          "Path": "amd64\\DISM\\ru-ru\\dismcore.dll.mui",
          "Size": 7680,
          "SHA256": "D18D0E8ED045D81D472F3251EE800E436EAE196190A26B7E859ACD419900C11B"
        },
        {
          "Source": "fil5c85aa8befb59c9c9e69b7640133eb0d",
          "Path": "amd64\\DISM\\ru-ru\\dismprov.dll.mui",
          "Size": 2560,
          "SHA256": "716BE8D45AEC10F902BD842C8F71384FBAD9D3B0D6012459C0815E2723F42D27"
        },
        {
          "Source": "fildbbb3c53d269851719f63eed0c386c6c",
          "Path": "amd64\\DISM\\ru-ru\\ffuprovider.dll.mui",
          "Size": 10240,
          "SHA256": "E4FA42835E1F33A8DBD8FE358E8C6CA45CC70E03DF614B08808A5BC253366AAB"
        },
        {
          "Source": "fil001f753c2a24b7b01d6cada30c87e213",
          "Path": "amd64\\DISM\\ru-ru\\folderprovider.dll.mui",
          "Size": 2560,
          "SHA256": "19024EF7AFFECC959DA0E3F14A88412AEEB11368076417541B51671A091E0DB7"
        },
        {
          "Source": "fil4eeed9471f38861f06107fe03955638a",
          "Path": "amd64\\DISM\\ru-ru\\imagingprovider.dll.mui",
          "Size": 20480,
          "SHA256": "50CE8A462337AFE5DA05A8A913FA00FC4C8196E5FEE5BBC82A588E81D77B946A"
        },
        {
          "Source": "file51aaebc06bebdb561bf85817c701b2f",
          "Path": "amd64\\DISM\\ru-ru\\logprovider.dll.mui",
          "Size": 6656,
          "SHA256": "9CF84CF58981BD853A62394A77A8F6A7FB56145D52F3181B086C0741DE107496"
        },
        {
          "Source": "fila332c4590d93eeb506f41218a2b0d402",
          "Path": "amd64\\DISM\\ru-ru\\osimageprovider.dll.mui",
          "Size": 3072,
          "SHA256": "9D79EB2A110E7D471635A86219F9E70D6841A7CB3AD27DA1B7D3AB72E26CA2E7"
        },
        {
          "Source": "fil0b61f198d355eee6c5359ca595bc5b56",
          "Path": "amd64\\DISM\\ru-ru\\VHDProvider.dll.mui",
          "Size": 8704,
          "SHA256": "2EE4D1259590222BD65ECFA65AF2549DF88D11E19F86048C62C4B56229CB0254"
        },
        {
          "Source": "fil3ef717901086e85de902105149f6e419",
          "Path": "amd64\\DISM\\ru-ru\\wimprovider.dll.mui",
          "Size": 30208,
          "SHA256": "1DBA369829C739EA46426E3ED244C6316E158D177B033F35906146E494CA5DB6"
        },
        {
          "Source": "filc0e24f6cf454c84707b20ee2b7d83764",
          "Path": "amd64\\DISM\\de-de\\deployprovider.dll.mui",
          "Size": 3072,
          "SHA256": "6C37FF4DC485E4E5F1A64AD49DC005653853D3E790BF7AFA6503D6A96548E638"
        },
        {
          "Source": "fil86cc1953fc27d8cafbccdaffbe26739f",
          "Path": "amd64\\DISM\\de-de\\dism.exe.mui",
          "Size": 33792,
          "SHA256": "3DE86F41B55825E84BEE9940A98E0B30DD8704A45D3422D7BE908B95B404346D"
        },
        {
          "Source": "fila28c82c6f9bf76792e7d750078ee8e5d",
          "Path": "amd64\\DISM\\de-de\\dismapi.dll.mui",
          "Size": 5120,
          "SHA256": "12AF76C9DCDEB61D2D2D6DF21117A6C60CC97BEE5DD13AD521EA8DED82C1E79E"
        },
        {
          "Source": "fil87ab5b464c6c779fd524c2d14ffd3b69",
          "Path": "amd64\\DISM\\de-de\\dismcore.dll.mui",
          "Size": 8192,
          "SHA256": "437FFF5882B96AA4F9DF8C3A611C485D2C6F069BF304ADF4D179FE38C50F50FE"
        },
        {
          "Source": "fil163560af49bad1808c59542514d713c9",
          "Path": "amd64\\DISM\\de-de\\dismprov.dll.mui",
          "Size": 2560,
          "SHA256": "F47FAD70CD675360B24081C3D9CF10AC596019522E68069B2A1F7F16646BD256"
        },
        {
          "Source": "fil00d07fc4ce2f705fe1fb8d79edf4c2b8",
          "Path": "amd64\\DISM\\de-de\\ffuprovider.dll.mui",
          "Size": 11264,
          "SHA256": "DBC55C193E44C4BBD44F273F0509FA3F3B869A7C3D3610E98CED682B8AF86FF7"
        },
        {
          "Source": "fil34b6fda3f9ba4c8db099b28547060510",
          "Path": "amd64\\DISM\\de-de\\folderprovider.dll.mui",
          "Size": 2560,
          "SHA256": "427353C0F96C71D2AC0BD88B769140AE746423AE3073BA4E9EB50CB189942C2A"
        },
        {
          "Source": "filb7c173f53276512846da49677a35f0a8",
          "Path": "amd64\\DISM\\de-de\\imagingprovider.dll.mui",
          "Size": 21504,
          "SHA256": "B7DBE8E5E15D6E96AD41C4C10C60CD95E15FC7B9432FA80D5CAF72B874E78106"
        },
        {
          "Source": "filc416fdb11292558926ec3da59de64cb8",
          "Path": "amd64\\DISM\\de-de\\logprovider.dll.mui",
          "Size": 6656,
          "SHA256": "229DC1AE03EB7139C2ED96F96DF2A464C1767960F311B4684AA6C5ACD376C2A9"
        },
        {
          "Source": "fil32aa5d374c94f648e8ee39d2ba081c80",
          "Path": "amd64\\DISM\\de-de\\osimageprovider.dll.mui",
          "Size": 3072,
          "SHA256": "33C561BBC09DF02A467B7D73CD9CC2425EE8A608CBC5E192F51755C53D16DA6E"
        },
        {
          "Source": "fil3d0380d7b59434c8c096053ea7361c92",
          "Path": "amd64\\DISM\\de-de\\VHDProvider.dll.mui",
          "Size": 9216,
          "SHA256": "EB4C986114E4E5B5596D2E0D2D65438382B2A3EC182D088808C67D3718CB597E"
        },
        {
          "Source": "filfa3d5224ea6c4de752b3dea9cdf18bb9",
          "Path": "amd64\\DISM\\de-de\\wimprovider.dll.mui",
          "Size": 32768,
          "SHA256": "C4F944984DD82FD1366C1B6A8EAE5D3BFF90B075C1DF2126D2D69EBC3AF70CBE"
        },
        {
          "Source": "file6f7b31ac8b147d7de5d34e5565447f3",
          "Path": "amd64\\DISM\\fr-fr\\deployprovider.dll.mui",
          "Size": 3072,
          "SHA256": "F29E1ECF32C9DBBA7538CF251A9D18C021955049693596577286192C8BC20FC2"
        },
        {
          "Source": "fil7c033ec327a343716bb08b8c17bd44c0",
          "Path": "amd64\\DISM\\fr-fr\\dism.exe.mui",
          "Size": 35328,
          "SHA256": "3A8057A05BC46716D65AC4FE2D4CD1CCDE545B63E06CA0984C668DFD9399BFC5"
        },
        {
          "Source": "fil7771e2cc6681fa897c60600ef21ff70b",
          "Path": "amd64\\DISM\\fr-fr\\dismapi.dll.mui",
          "Size": 5120,
          "SHA256": "90EB642F51DDCE5C0F2F647F50C80ADE0DE47B9929F6FFEBF29C4B825090FB2E"
        },
        {
          "Source": "fild918f79247f3daea13d2fdb78c3e9d58",
          "Path": "amd64\\DISM\\fr-fr\\dismcore.dll.mui",
          "Size": 8192,
          "SHA256": "67001D57369DED02B28ED3F776D114BE01F56FB0130553634508922AF36D7B42"
        },
        {
          "Source": "fildbfae3670565e361a08a0f43994934e3",
          "Path": "amd64\\DISM\\fr-fr\\dismprov.dll.mui",
          "Size": 2560,
          "SHA256": "A61F5A8C1837969C933E485F678BAE172EC026F9321FF7D9E5C4082384546CF7"
        },
        {
          "Source": "fil416f529eaacd697e2f0b35abd09a6031",
          "Path": "amd64\\DISM\\fr-fr\\ffuprovider.dll.mui",
          "Size": 10240,
          "SHA256": "5D13C6D7893004D07C0B331720CAD531C03C79590E7FF68CED5A79496EC7069E"
        },
        {
          "Source": "filaf85a70c5eb1280e492cc555319efd74",
          "Path": "amd64\\DISM\\fr-fr\\folderprovider.dll.mui",
          "Size": 2560,
          "SHA256": "FDB51E86080DF1CF0CF96A975FB1F1F96ABC6501AD107187339E2498C082CF89"
        },
        {
          "Source": "fildc59fe3b6adda0f62a8eb967e925e342",
          "Path": "amd64\\DISM\\fr-fr\\imagingprovider.dll.mui",
          "Size": 20480,
          "SHA256": "53C652FBFBC829D8EBFF1979A7AA2848DBD0FE6537E4F8679158078DCC3B2F88"
        },
        {
          "Source": "file474737d19164cd657caec9ef40c24ba",
          "Path": "amd64\\DISM\\fr-fr\\logprovider.dll.mui",
          "Size": 6656,
          "SHA256": "84191D6DC7C6A641C4123197BFA6C15B41A1DA94F1079BE85E57CECCBBF097DD"
        },
        {
          "Source": "file1f37c38cb1142dd93dd645e69126f15",
          "Path": "amd64\\DISM\\fr-fr\\osimageprovider.dll.mui",
          "Size": 3072,
          "SHA256": "A406B8F7AA065F77DE6B9F679C3FDC90C29183818E7BCA99DA066D22D3DDE3A8"
        },
        {
          "Source": "fil95e71e5f21d32dd212e600377a9e4047",
          "Path": "amd64\\DISM\\fr-fr\\VHDProvider.dll.mui",
          "Size": 8704,
          "SHA256": "870E5D898416F45B7DCADD62365A280FF82BAB57602E54A8F4B26E4144172F2E"
        },
        {
          "Source": "fil05bac0a81a50be9e571cdf63bbe9c4e6",
          "Path": "amd64\\DISM\\fr-fr\\wimprovider.dll.mui",
          "Size": 32256,
          "SHA256": "C38D3690D4421471E38AD0E659D6D1E50FEED65F0715F110490C4128C184F77A"
        },
        {
          "Source": "filb2814e1ba3f35fc5b1a8719e59cda5bd",
          "Path": "amd64\\DISM\\zh-tw\\deployprovider.dll.mui",
          "Size": 2560,
          "SHA256": "C2CC11E354C5F026D9A77D993A56FAEFCD2184B8503DB2148A1DAC3C9F4E965A"
        },
        {
          "Source": "fil54902bad9d6f6e6a74a3b03698e90a9c",
          "Path": "amd64\\DISM\\zh-tw\\dism.exe.mui",
          "Size": 16896,
          "SHA256": "B1C5EE57D02F17FDD38BD4E0BAA3DF967BBE467B08BD3591F7645570E9F21BE2"
        },
        {
          "Source": "filb5d6923952566ba71543a47fbec94d52",
          "Path": "amd64\\DISM\\zh-tw\\dismapi.dll.mui",
          "Size": 5120,
          "SHA256": "4E2BC6758C8EA96D238137AD8A0CE6850CEE2A2307F17C7F37A9B370C0F9F2C2"
        },
        {
          "Source": "fil4889ff3df8514ce5f4034ce894cd3979",
          "Path": "amd64\\DISM\\zh-tw\\dismcore.dll.mui",
          "Size": 4608,
          "SHA256": "E4374E4E627F5DC211BB0BFAE0AA2D52ECA4CC15F22B2B4F84846F207A50A6A8"
        },
        {
          "Source": "fil91072ff89fee98c4b078d633bd95609d",
          "Path": "amd64\\DISM\\zh-tw\\dismprov.dll.mui",
          "Size": 2560,
          "SHA256": "9D63D30E36ED5A4BC934994DD0BCF0CDA866D01E7CFB9A187F9BBBA79C930526"
        },
        {
          "Source": "file1e9100f0a6e03305af32efb26262465",
          "Path": "amd64\\DISM\\zh-tw\\ffuprovider.dll.mui",
          "Size": 7168,
          "SHA256": "9D010A991F3017F9F590325B11A569EAA3F9AAD0BABEEFD72ADE4FB7E2D6F1C0"
        },
        {
          "Source": "fil0722816d1d0c93cd9a648dad45c6e8e2",
          "Path": "amd64\\DISM\\zh-tw\\folderprovider.dll.mui",
          "Size": 2560,
          "SHA256": "0CA1BC2E198283A585B14A83D8547EF47897E9CE0D9F76789253367E2413D88C"
        },
        {
          "Source": "fil2926d438a9498ac27477c6daab84539c",
          "Path": "amd64\\DISM\\zh-tw\\imagingprovider.dll.mui",
          "Size": 12800,
          "SHA256": "A3615C9BEE99C13BB011EEE41E61E776A7D80C1E589050C49760753E76000FBC"
        },
        {
          "Source": "fil1e9d0ef9384e4d0f68ef23f21782cb5b",
          "Path": "amd64\\DISM\\zh-tw\\logprovider.dll.mui",
          "Size": 4096,
          "SHA256": "18129C756175478F9C15E06426A45C9C18C7726D53C3B62167BEACE192E07BE6"
        },
        {
          "Source": "file20a10d563fd3125abc2bc9027122c0b",
          "Path": "amd64\\DISM\\zh-tw\\osimageprovider.dll.mui",
          "Size": 3072,
          "SHA256": "B575B72E2A9D1CE2D7963C33EFC740D1F80BB880E9A221D81001AA9E7AA5177B"
        },
        {
          "Source": "fil358979cd168546134acdd6f994f30604",
          "Path": "amd64\\DISM\\zh-tw\\VHDProvider.dll.mui",
          "Size": 4608,
          "SHA256": "C22AA2E3F58C24A224BD4F8786968C3A7C1DBD39FE9EBB0C664F9625C4635BBA"
        },
        {
          "Source": "fil4f80b47f8dbd830ee3f8bf0bbe82887e",
          "Path": "amd64\\DISM\\zh-tw\\wimprovider.dll.mui",
          "Size": 18432,
          "SHA256": "CAD30F2DFD2CCECB580E35D8805B777128C73244E1648382822909067A76C415"
        },
        {
          "Source": "fil4bd0372b16c858582abaa1c2443b86ed",
          "Path": "amd64\\DISM\\zh-cn\\deployprovider.dll.mui",
          "Size": 2560,
          "SHA256": "30C5B24DDD754D535D00A589DE35E40CC61DD122FDECEADB166BBA5CCC4027DC"
        },
        {
          "Source": "file07628f46e4502652a135a692837cc89",
          "Path": "amd64\\DISM\\zh-cn\\dism.exe.mui",
          "Size": 16896,
          "SHA256": "4D22A1D7177544A03058BA2582010AA66BC045EA251F68768635F4165BFE1355"
        },
        {
          "Source": "fil32a61cb93a00fbaec83dcd78bd04f656",
          "Path": "amd64\\DISM\\zh-cn\\dismapi.dll.mui",
          "Size": 5120,
          "SHA256": "8371B4753D9F6105F56484E9224AFB42DE5F01DE652C6528437B339062F4F7F9"
        },
        {
          "Source": "fil7abe1f172db3ff125dacfe642ee969bc",
          "Path": "amd64\\DISM\\zh-cn\\dismcore.dll.mui",
          "Size": 4608,
          "SHA256": "A0068E0A930917835B31FB6F361DA6DAB4966B3BD76F1E4BB64FD68AF406986D"
        },
        {
          "Source": "fil1ea29e6310a76110cf2fdcf848c0c5f5",
          "Path": "amd64\\DISM\\zh-cn\\dismprov.dll.mui",
          "Size": 2560,
          "SHA256": "B4695B6B68DF2A38D60D5F88A1533D4504FB89F7C88F4EB412C28363B078B3B6"
        },
        {
          "Source": "filaa43c4f00b748ce6ddb700ff5a825cb9",
          "Path": "amd64\\DISM\\zh-cn\\ffuprovider.dll.mui",
          "Size": 7168,
          "SHA256": "36367B694671956A85F08E58BFAAF84FFA259E7C0F88527FB38F342834B8D1FE"
        },
        {
          "Source": "filc2a78a760bf00e8cb4feae3b8d91cd20",
          "Path": "amd64\\DISM\\zh-cn\\folderprovider.dll.mui",
          "Size": 2560,
          "SHA256": "15C7F009D3726A0B0B34C5D5CF04B898BA8D913DFCFD6D798C84C032AAFA1CC9"
        },
        {
          "Source": "fil8fb54b93dbd1a67a2384d4a4cf38ebd9",
          "Path": "amd64\\DISM\\zh-cn\\imagingprovider.dll.mui",
          "Size": 13312,
          "SHA256": "87B7F5B515D29B9508DB320F4A8A9DDB1306DC7358EDEB4399FCA71508DF1F02"
        },
        {
          "Source": "fil0c9435b8a8197a1d1e13955fb9469c98",
          "Path": "amd64\\DISM\\zh-cn\\logprovider.dll.mui",
          "Size": 4608,
          "SHA256": "4669329D4477A0838A7206E26F76CCD531AB9AA5A1A960B178AC05025163D2D3"
        },
        {
          "Source": "fil288d14995f71d279a520b59edfe46b88",
          "Path": "amd64\\DISM\\zh-cn\\osimageprovider.dll.mui",
          "Size": 3072,
          "SHA256": "D928FC39153C898E15800899147863E33DDDF32B3229C5443406B1B444EAD94E"
        },
        {
          "Source": "fil18a0a8a353c8f4dea78f39dc1db5bb30",
          "Path": "amd64\\DISM\\zh-cn\\VHDProvider.dll.mui",
          "Size": 4608,
          "SHA256": "5BD1673743A3F80C127AEFD244BBD6F069E64EC9893F46E541F1423E7372F4B1"
        },
        {
          "Source": "fil542b8c2c7d74e14469d46c191015acec",
          "Path": "amd64\\DISM\\zh-cn\\wimprovider.dll.mui",
          "Size": 18944,
          "SHA256": "5A82ED34A0DA86EE06B96183554B569B8F02EC8C10E48EB174DFA89ECE7E55FA"
        },
        {
          "Source": "filfc7bd135b70a740ae025d59c4a4e7288",
          "Path": "amd64\\DISM\\pt-br\\deployprovider.dll.mui",
          "Size": 3072,
          "SHA256": "7B2D47AAA801F3E7733D29CF77277986171BA6190A41EA872C6211F4534443BB"
        },
        {
          "Source": "fil2f5f942a6e4dd738a75663d60afc322f",
          "Path": "amd64\\DISM\\pt-br\\dism.exe.mui",
          "Size": 31232,
          "SHA256": "23743F27B00EAD409F5E4CBA95B23D08EF12726DD3F9E0A16F259BF49A2ACA7F"
        },
        {
          "Source": "filee880624f76e562ea4281b07ad23c3d9",
          "Path": "amd64\\DISM\\pt-br\\dismapi.dll.mui",
          "Size": 5120,
          "SHA256": "47FF34B58CB4AC70B81796179CE0CB622064E4FE54BAD60A972E22D1D9B78B20"
        },
        {
          "Source": "fil8ab295151f7a58279b4db3ebda2c54b0",
          "Path": "amd64\\DISM\\pt-br\\dismcore.dll.mui",
          "Size": 7680,
          "SHA256": "F259599034AAEE4832DF8DC0AC983C4106F57FFC6B08DCEC59E399FEADEA0703"
        },
        {
          "Source": "fil7008980227acd335f1745c5150f001a3",
          "Path": "amd64\\DISM\\pt-br\\dismprov.dll.mui",
          "Size": 2560,
          "SHA256": "FDD3ACEAF922A2C40E71844B8D4A9E2AA788E717A458C0946287245C5E1961A8"
        },
        {
          "Source": "filffb50ed8bae3474d196b2477f62c5045",
          "Path": "amd64\\DISM\\pt-br\\ffuprovider.dll.mui",
          "Size": 10240,
          "SHA256": "84991C4C2955AD5D57F12590F4AC603CA04B9EED1E479BE6CF0510673E9CC4CB"
        },
        {
          "Source": "fil43013a95f35d0bf7471637e028fc392c",
          "Path": "amd64\\DISM\\pt-br\\folderprovider.dll.mui",
          "Size": 2560,
          "SHA256": "226E068460CF26AE82B87E861753408A4389E61D4E6F236F7A38EC6A1056C1A5"
        },
        {
          "Source": "fil7f7b3119172a592989a1ee0de5d7cc6c",
          "Path": "amd64\\DISM\\pt-br\\imagingprovider.dll.mui",
          "Size": 19968,
          "SHA256": "FCAAE075195C346442746E4CBED315EC268EAAC0292997EF25D67F90E3A213F2"
        },
        {
          "Source": "fil515fd150c058aa932ed92bb441b56340",
          "Path": "amd64\\DISM\\pt-br\\logprovider.dll.mui",
          "Size": 6144,
          "SHA256": "8CF0284DC7281CAC0AE5FE312012ED7F31643606C07DB9F212BEA98C019ABE54"
        },
        {
          "Source": "fil0d92ae9886ef121927270eb0cd7e543f",
          "Path": "amd64\\DISM\\pt-br\\osimageprovider.dll.mui",
          "Size": 3072,
          "SHA256": "C5BD793E66226FC290F86D90FD92F9241BC715DCAA85680F3C11814BFFA447AB"
        },
        {
          "Source": "fil434420006e84d2887c8cba4c489b7dc4",
          "Path": "amd64\\DISM\\pt-br\\VHDProvider.dll.mui",
          "Size": 8192,
          "SHA256": "E1D7A307286898E3E2CC99D7D80A080293D6B62C733F27DD822E1FBD100B7339"
        },
        {
          "Source": "fil25b3227015530b952a619e44b2b6f4ed",
          "Path": "amd64\\DISM\\pt-br\\wimprovider.dll.mui",
          "Size": 30208,
          "SHA256": "D1C8BCCB24298723DE05FEB8F4BC688480A02A220045DBED1B569BA3174D7846"
        },
        {
          "Source": "fil1832a375c4e6bf7357a82940dda91b77",
          "Path": "amd64\\DISM\\en-us\\deployprovider.dll.mui",
          "Size": 2560,
          "SHA256": "C430BC8EEADEBE2D97E290B551EF352EB535FE927EFA9021CC6A2B911BD99A43"
        },
        {
          "Source": "fil1481931406c79d11fa64acef0b7bf4de",
          "Path": "amd64\\DISM\\en-us\\dism.exe.mui",
          "Size": 30208,
          "SHA256": "C841EBC3B60A8127EC2FAC4E0AAC96D2C167DB2B5DD8BCDB6AE900D1521DB7CC"
        },
        {
          "Source": "filf89f2e99085870cf245541c7c51766bb",
          "Path": "amd64\\DISM\\en-us\\dismapi.dll.mui",
          "Size": 5120,
          "SHA256": "3863037E52025F1F511754849CB1245A0027209167502D243A1A6A70B9BA5388"
        },
        {
          "Source": "fil24ece41a209945a00a1ffbdc75f9019f",
          "Path": "amd64\\DISM\\en-us\\dismcore.dll.mui",
          "Size": 7680,
          "SHA256": "9E636A9A5A13E37BABD2E0C1304218EE51C2AEABB022EEFCBF145A65EDC04BBD"
        },
        {
          "Source": "fil7288fefe48138ed62dd54cbf9f05bb3f",
          "Path": "amd64\\DISM\\en-us\\dismprov.dll.mui",
          "Size": 2560,
          "SHA256": "6BDBF9A3DDB3485856D0FCE709B80FD1A41D5472E046C7B89CA080EA12B04ADA"
        },
        {
          "Source": "fil561c80b97ba3200ec6b1ee5b8934e1dc",
          "Path": "amd64\\DISM\\en-us\\ffuprovider.dll.mui",
          "Size": 9728,
          "SHA256": "4C6B992F976E6675B48074BB4580A6366EE3FEA155A1C00CBAFBBA031C45F612"
        },
        {
          "Source": "filb23a0f699b4a1df4619cacd283f19b27",
          "Path": "amd64\\DISM\\en-us\\folderprovider.dll.mui",
          "Size": 2560,
          "SHA256": "D064C6FAAE6E9F6DB04CAC10382265DABF9F7CEEB74DCF8D4DDA75BE9B92CD53"
        },
        {
          "Source": "fil533f02f47e595caabe7943f4d3baf135",
          "Path": "amd64\\DISM\\en-us\\imagingprovider.dll.mui",
          "Size": 18944,
          "SHA256": "F896EFEFF0054082271E6F6EB96D3FE15E2CB30D2BF87F14E3AA34DB7C4714AF"
        },
        {
          "Source": "filb67e2312fbf5d3e5990c36ae967a0611",
          "Path": "amd64\\DISM\\en-us\\logprovider.dll.mui",
          "Size": 6144,
          "SHA256": "E207AE939CC23C264C53DE1929DC7FA7EEE5C8B2B3355CD10816E60E9B6448E9"
        },
        {
          "Source": "fil1063142e91c9880be5f86431aaaa6410",
          "Path": "amd64\\DISM\\en-us\\osimageprovider.dll.mui",
          "Size": 3072,
          "SHA256": "C41F8876CB506B7F078BB8820ADB60AA60ED677B9304F4500BFD53E43C40B5CC"
        },
        {
          "Source": "fila80c2f1246ed9f7ced78801fbd0a8a5b",
          "Path": "amd64\\DISM\\en-us\\VHDProvider.dll.mui",
          "Size": 7680,
          "SHA256": "BE81EC7777B012430918A995C45E4C47F951960ECC0FB440190771F48C688225"
        },
        {
          "Source": "fil5f7f81c1ebd058aae5cfd35cdea5177d",
          "Path": "amd64\\DISM\\en-us\\wimprovider.dll.mui",
          "Size": 28160,
          "SHA256": "B37F21040BD5B7F88BB1AFD656087EC1863E4912CB46AA85F15866BB760D5BB3"
        },
        {
          "Source": "filbb1a01d9a7c560ffdfa9d1fe5382d7cd",
          "Path": "amd64\\DISM\\es-es\\deployprovider.dll.mui",
          "Size": 3072,
          "SHA256": "1A5F88E1F5C68337120A7ACFF568B15D110D05C34C4A4DF05D92E0F01E9DA3BF"
        },
        {
          "Source": "fil558c21f188cd84cc98b93cb2c76a4f8d",
          "Path": "amd64\\DISM\\es-es\\dism.exe.mui",
          "Size": 33280,
          "SHA256": "BF408E16EDBF3F229E59EE704781A1365D78410D12250E763B4B7EC55B22423B"
        },
        {
          "Source": "filb49f29b1e48148bf7654241b095f8d81",
          "Path": "amd64\\DISM\\es-es\\dismapi.dll.mui",
          "Size": 5120,
          "SHA256": "07601E4DE0B7BE2BB59F0C0876745652D8185B1BFC3E55825488C164EBA18B16"
        },
        {
          "Source": "filff50acbf5aa3e831c39e10e1842ec138",
          "Path": "amd64\\DISM\\es-es\\dismcore.dll.mui",
          "Size": 7680,
          "SHA256": "181B4E2D4D0350DC4C5769D44FD869A204D92E4C720A52FB9D719E3D68CC6BF2"
        },
        {
          "Source": "filb46e2f4909f1be02a2f8871da0ca7ea8",
          "Path": "amd64\\DISM\\es-es\\dismprov.dll.mui",
          "Size": 2560,
          "SHA256": "2E67DD59EEAE83861858851F320FFF5A8E9FBD732D85A3471D1CDB5A10CD1476"
        },
        {
          "Source": "fild7094cb63608e00e8b35902851c72d5d",
          "Path": "amd64\\DISM\\es-es\\ffuprovider.dll.mui",
          "Size": 10240,
          "SHA256": "67010DA9E618AD8B4DB10DB51068270AC80B39E8AA4A926399EDBDDA4FE61501"
        },
        {
          "Source": "filb8bd562498de4d0395f979ae08cd6049",
          "Path": "amd64\\DISM\\es-es\\folderprovider.dll.mui",
          "Size": 2560,
          "SHA256": "6A13949D546CB3C73933346DDE6C219581C9515FE335DB3FF387862D986855B7"
        },
        {
          "Source": "filad1fc34ad5e93a936af33bf908761fe0",
          "Path": "amd64\\DISM\\es-es\\imagingprovider.dll.mui",
          "Size": 20480,
          "SHA256": "CC3A94E687D2B5C1AE618952FC79098075C9B7E9A32AAD95842576E097CDBF0A"
        },
        {
          "Source": "fil56cef7cb259b601adceea7a0f1099fff",
          "Path": "amd64\\DISM\\es-es\\logprovider.dll.mui",
          "Size": 6144,
          "SHA256": "325E1D5E296F3F7A9730B43F6039016943D64435C2A4EB2BBB3D6B62AA750370"
        },
        {
          "Source": "fil2ed49a5e086f627bcde078a8b613ea06",
          "Path": "amd64\\DISM\\es-es\\osimageprovider.dll.mui",
          "Size": 3072,
          "SHA256": "570A09C5BE9E7A7063FE9782F8B4F2A7413A8D144948BB344BF9533EBBE842E8"
        },
        {
          "Source": "fil1ccfe4939d8a138fc9e7459061612ca8",
          "Path": "amd64\\DISM\\es-es\\VHDProvider.dll.mui",
          "Size": 8192,
          "SHA256": "389A44E554403552DB00488DD44C3A76AD81BDA82408E41D5F5993B7D94A15F1"
        },
        {
          "Source": "filf267683923a0ef42c8d10caaa538ca6c",
          "Path": "amd64\\DISM\\es-es\\wimprovider.dll.mui",
          "Size": 31744,
          "SHA256": "403088F582897C95DD8D54E43B1236E3F9040BDAB7364C8490262C184C9FDCBF"
        },
        {
          "Source": "fil345222b65cf4b8dc691eeeb24eb2aa75",
          "Path": "amd64\\DISM\\it-it\\deployprovider.dll.mui",
          "Size": 3072,
          "SHA256": "D918ED61EA55E587B4525408772793173F6C3A76B9F3912D990CE5571DB23751"
        },
        {
          "Source": "fil9b5489937ea77249d83df30b0cd367b0",
          "Path": "amd64\\DISM\\it-it\\dism.exe.mui",
          "Size": 36352,
          "SHA256": "48E7203A6B9FDEFA929A86E336F7BDEB433590FE3BF6D571E74665B29E10221C"
        },
        {
          "Source": "fil4cc8cbaa7dc08db0a6efcdfd3df05810",
          "Path": "amd64\\DISM\\it-it\\dismapi.dll.mui",
          "Size": 5120,
          "SHA256": "C20F91CE02A1080B91C2D1D9ADB9437A2423F3F3CF1D0C930559489DDF71BF4D"
        },
        {
          "Source": "fil1e0bc4e08fb94f1d2a96631de041e5ae",
          "Path": "amd64\\DISM\\it-it\\dismcore.dll.mui",
          "Size": 8704,
          "SHA256": "7E61A6C1721DF0D1061733A8A8C0EA7454CF039CF4E543675C269EE93B6F2276"
        },
        {
          "Source": "fil521d9e058d0315f050ceb58a6f7d8ada",
          "Path": "amd64\\DISM\\it-it\\dismprov.dll.mui",
          "Size": 2560,
          "SHA256": "6A8C6E3995384C2E9F115D934C91A7D57A056DC5564A8BDBCB1D35ABA7E9E0C6"
        },
        {
          "Source": "fila10435f8093dcc95e4a0e3e3b7887e99",
          "Path": "amd64\\DISM\\it-it\\ffuprovider.dll.mui",
          "Size": 10752,
          "SHA256": "A27A1B44C30D7343B1DF6E66624C5F3BA9AD00DACC750D53C0E0E228248112A4"
        },
        {
          "Source": "fil5cbc2d0c17b5452e84daffe96d40bbfd",
          "Path": "amd64\\DISM\\it-it\\folderprovider.dll.mui",
          "Size": 2560,
          "SHA256": "381764FC6283E42E393489584FA1A0473DC4D0E7B0D1739A42E3F5EA25F00E63"
        },
        {
          "Source": "filde2565c80955e3ce46841c7fba63bf0b",
          "Path": "amd64\\DISM\\it-it\\imagingprovider.dll.mui",
          "Size": 20480,
          "SHA256": "8D1650B3FEF7380F9732F1A078DAE81D34413D0355A3B45E5BC783E0AF996F96"
        },
        {
          "Source": "fil8f5bac05a98307a2867240cc2b139301",
          "Path": "amd64\\DISM\\it-it\\logprovider.dll.mui",
          "Size": 6656,
          "SHA256": "519A724035BC5E8A1645303294ACB5E72CF7ECA4097700EB78400F942F5AA54C"
        },
        {
          "Source": "filbfd02006dd29c5725bd1e25ecc99bc63",
          "Path": "amd64\\DISM\\it-it\\osimageprovider.dll.mui",
          "Size": 3072,
          "SHA256": "D03C02AC4AE365D5EB179C8ED816A15C0FD64882777A50FD8944453AACF8DFC8"
        },
        {
          "Source": "fil95d37e5b79e17cf12672823c86b88644",
          "Path": "amd64\\DISM\\it-it\\VHDProvider.dll.mui",
          "Size": 8704,
          "SHA256": "9A4EB9119D809ED8C38550A352E6B6782A5C8B0257F01DEB70A0D1978054145F"
        },
        {
          "Source": "filf80ad0e0e74ccbe3ac24996e06e6c702",
          "Path": "amd64\\DISM\\it-it\\wimprovider.dll.mui",
          "Size": 32256,
          "SHA256": "212975032A048EF3F5A0F56044AC09569AFC7839E2CDB46E45B47C5085F60D86"
        },
        {
          "Source": "filb6ddfad3144b5d877823c54b4b20fd54",
          "Path": "amd64\\DISM\\ko-kr\\deployprovider.dll.mui",
          "Size": 2560,
          "SHA256": "611C686F11235F0311762B855A92737E458A2B3ED07D928BCF7C3511192D400F"
        },
        {
          "Source": "fild9672343c29aeecaef7630408c7d1b48",
          "Path": "amd64\\DISM\\ko-kr\\dism.exe.mui",
          "Size": 20480,
          "SHA256": "5A7B670AC4553C651C509FAF427219468622FD10069B404ACB41A5C4B7C66956"
        },
        {
          "Source": "file1a4f2ca3aba44501fd77c353bef7a74",
          "Path": "amd64\\DISM\\ko-kr\\dismapi.dll.mui",
          "Size": 5120,
          "SHA256": "76DCFBA45F99E9F8BB66F9ACC9B7AAA2D47C301522DE2D695121AA634DF7E731"
        },
        {
          "Source": "fil9faf020497d276abb8ff275736a3816a",
          "Path": "amd64\\DISM\\ko-kr\\dismcore.dll.mui",
          "Size": 5120,
          "SHA256": "435B46CD424E5D629D217601303821E877A08C0E806DB7BD9AF32E4FC27352AA"
        },
        {
          "Source": "filbc5ac5e6070bfe20c7af48f66e65262f",
          "Path": "amd64\\DISM\\ko-kr\\dismprov.dll.mui",
          "Size": 2560,
          "SHA256": "02FED4EE659BBA306F77BBEC143CEBC84CD319B14CC61A8EC97016217B2AA021"
        },
        {
          "Source": "fila36c29a23646f6ad61e7a37f23a09ab1",
          "Path": "amd64\\DISM\\ko-kr\\ffuprovider.dll.mui",
          "Size": 7680,
          "SHA256": "6BF60630C3B9665A8A54FDD3AD683EBFE571801400C5F138319D777424705D98"
        },
        {
          "Source": "filf359cb7adbbae0e9c5794254d40d013e",
          "Path": "amd64\\DISM\\ko-kr\\folderprovider.dll.mui",
          "Size": 2560,
          "SHA256": "ECDC948D8DB6380E0C6D27AE83458689E239C914CB7BD933EFD861A0549EC11F"
        },
        {
          "Source": "fil8ae308ad428f9d65a20fb0ce470b1556",
          "Path": "amd64\\DISM\\ko-kr\\imagingprovider.dll.mui",
          "Size": 14848,
          "SHA256": "A142BC353E5CD682CDB923DD3F0229A9AFD44B9E2CC02EA13A5354476A386136"
        },
        {
          "Source": "filabe529fb0b8633a8f781b5fd5c8a8eeb",
          "Path": "amd64\\DISM\\ko-kr\\logprovider.dll.mui",
          "Size": 4608,
          "SHA256": "08D2778BF774C7386241F84B25ED9384731A69102689A6490777A5ECB990840D"
        },
        {
          "Source": "filb5cb5a4ba65e5e99a4abbc2db31fbd26",
          "Path": "amd64\\DISM\\ko-kr\\osimageprovider.dll.mui",
          "Size": 3072,
          "SHA256": "C71BC6E532EAB5E45BD4C6AAA48A18490F13C6F05DC0609F549ECC714DB4E622"
        },
        {
          "Source": "filf627de3629ae62b6a32de896f9dc96ee",
          "Path": "amd64\\DISM\\ko-kr\\VHDProvider.dll.mui",
          "Size": 5632,
          "SHA256": "5A7EC03A0555B6B005E4C84373D1AF62C9C242116BC2C210DE7B5071CB68C8D8"
        },
        {
          "Source": "fil2e101031962c00a675b0c07fb0afba48",
          "Path": "amd64\\DISM\\ko-kr\\wimprovider.dll.mui",
          "Size": 21504,
          "SHA256": "FCB653B125D0081EB111F35C7D9FD94521A50723F45E98F0B048654B9B4488E6"
        },
        {
          "Source": "fil90f8caf69b0be485d5142a2c4b742525",
          "Path": "amd64\\DISM\\ja-jp\\deployprovider.dll.mui",
          "Size": 2560,
          "SHA256": "2B33A3B1A99E1FB19F087175A8D08BF4B7E0194FB95003A39F5D752556CB9633"
        },
        {
          "Source": "filf044a8eaa164a53fa3a6c25600b2c551",
          "Path": "amd64\\DISM\\ja-jp\\dism.exe.mui",
          "Size": 21504,
          "SHA256": "B0B4AA609816266835F78807106BC2C374C19D402A086F71DC2D7E11B28A8A77"
        },
        {
          "Source": "fil8f884f818ccac06d8fdab78d74cf892c",
          "Path": "amd64\\DISM\\ja-jp\\dismapi.dll.mui",
          "Size": 5120,
          "SHA256": "A13015EED7B48F33778D7FB2A53BD0D64A0E1A52AEC3CFA037063590A9230707"
        },
        {
          "Source": "fil5d6434d91b54f1cc4a40c85186b2f5cc",
          "Path": "amd64\\DISM\\ja-jp\\dismcore.dll.mui",
          "Size": 5632,
          "SHA256": "0B3F39A84A98124C5A4D46AC934999460ADB4DC8F8E8C3E7A9164223FFCE6A20"
        },
        {
          "Source": "fil51efc102dafad4179358725c9c3d9088",
          "Path": "amd64\\DISM\\ja-jp\\dismprov.dll.mui",
          "Size": 2560,
          "SHA256": "4CDA9E3FE18B0291E4B4481F7BBF5612F4E7863547FAD06F2874DD13BC235FE4"
        },
        {
          "Source": "fil8e6b97117bb4918b8b4f415e0414bb13",
          "Path": "amd64\\DISM\\ja-jp\\ffuprovider.dll.mui",
          "Size": 8192,
          "SHA256": "08D8D1D79F96F640A91CE979368D1B3924C44CD95F92E73B808D715A6EC75EF2"
        },
        {
          "Source": "fil4bdf946743763900e1bfeaf646c3c800",
          "Path": "amd64\\DISM\\ja-jp\\folderprovider.dll.mui",
          "Size": 2560,
          "SHA256": "69C9D87E41808EEB6CC1B5173FE3F84A2A2E3F0B3B0B390AE1E88F6990E5F04D"
        },
        {
          "Source": "filf355c654b54f338a1843dc74f825ed1d",
          "Path": "amd64\\DISM\\ja-jp\\imagingprovider.dll.mui",
          "Size": 15360,
          "SHA256": "211E8BB07159CAA94A6D2180DEF8158554441A956509377588F3767CE53B2160"
        },
        {
          "Source": "filbcecde734dab43fa1f263af5cbf470dd",
          "Path": "amd64\\DISM\\ja-jp\\logprovider.dll.mui",
          "Size": 5120,
          "SHA256": "50B7A72679BF083B29FA9D5CC699F0C55079A998FAED84D3E8704FE6C65A6EE8"
        },
        {
          "Source": "filb2180665aa4d739654b169d7edec78f6",
          "Path": "amd64\\DISM\\ja-jp\\osimageprovider.dll.mui",
          "Size": 3072,
          "SHA256": "DB3A07892E372D36B6FA5C86E10BBA8CCE03564F4556D0F0D67A9C9AAE8FC97C"
        },
        {
          "Source": "fil4e23cbe67ca60491cde377215f0d2b90",
          "Path": "amd64\\DISM\\ja-jp\\VHDProvider.dll.mui",
          "Size": 5632,
          "SHA256": "001E3CA7B604610D99B9194C2BFF6D39A3C640382804E14B78EA80B2B399A57B"
        },
        {
          "Source": "fil74b792687cdebbb200c3b9aee52e928f",
          "Path": "amd64\\DISM\\ja-jp\\wimprovider.dll.mui",
          "Size": 22016,
          "SHA256": "1B17C2F2EA35805C1E22ABA3226D72907A1DD1256D4059C847951886EFB7C2D5"
        }
      ],
      "SHA256": "9084EE165708AB99ED02796138643B81E143C985CBEB7D65CB9D38280775A175"
    },
    {
      "Name": "bbf55224a0290f00676ddc410f004498.cab",
      "Url": "https://download.microsoft.com/download/615540bc-be0b-433a-b91b-1f2b0642bb24/adk/Installers/bbf55224a0290f00676ddc410f004498.cab",
      "Size": 77768,
      "SHA1": "2757E5530EB4006BEE63C3C25870B7C7E526F144",
      "Files": [
        {
          "Source": "fild40c79d789d460e48dc1cbd485d6fc2e",
          "Path": "amd64\\Oscdimg\\oscdimg.exe",
          "Size": 153976,
          "SHA256": "1DB4BD2D7231895D345B9AD8E4330C9BE18C446D3C4AE9E9E07F3F242D78F67E"
        }
      ],
      "SHA256": "13AD65CCC488CEBD8E5EF969A68C44DD0E2C64255460D26F1D560763F474DBCE"
    },
    {
      "Name": "bf7b6300431984daf850cc213043c7eb.cab",
      "Url": "https://download.microsoft.com/download/615540bc-be0b-433a-b91b-1f2b0642bb24/adk/Installers/bf7b6300431984daf850cc213043c7eb.cab",
      "Size": 2196206,
      "SHA1": "34E6B4DD953905984A7DBD3DFFF1919BF0402BAE",
      "Files": [
        {
          "Source": "fil7b9ccf20a1eafdd2e70d4e809b027e3d",
          "Path": "amd64\\Oscdimg\\efisys.bin",
          "Size": 1474560,
          "SHA256": "9E9D29DA943769018E24A957CD90025F6EAFBB68E84E3779664C5251F405F94E"
        },
        {
          "Source": "fil2041ed1cb2cecc505c5644040dd2d958",
          "Path": "amd64\\Oscdimg\\efisys_EX.bin",
          "Size": 1474560,
          "SHA256": "384490F3770081AA97E2D3C1B63D3F449DDF0DF1F5B24621C10164B1D17ADC76"
        },
        {
          "Source": "fil449d57a492af92416002a31c2676d95a",
          "Path": "amd64\\Oscdimg\\efisys_noprompt.bin",
          "Size": 1474560,
          "SHA256": "400187C3BDE8EF8A281BC9D2798483B815C4039397B1CCDEB9E9B7796F4272E0"
        },
        {
          "Source": "filea358cebe7c9f014804bf1b5667282b7",
          "Path": "amd64\\Oscdimg\\efisys_noprompt_EX.bin",
          "Size": 1474560,
          "SHA256": "8190D8D13FAF005369330DF56171BC44E497B94DB4A0AA5CE68FDA3AC22AE892"
        },
        {
          "Source": "fil7aeefbb301038b471aa8f11225062ad4",
          "Path": "amd64\\Oscdimg\\etfsboot.com",
          "Size": 4096,
          "SHA256": "F425E135AAC26B55E2BAC655E62E2CE0B16255226C583D9AB43B2E93E8A6D932"
        }
      ],
      "SHA256": "E9CE2E5495FB51786E996CFC3F7361F8E51D7D366B18BCBD6BB9B46C57FA2538"
    },
    {
      "Name": "d2611745022d67cf9a7703eb131ca487.cab",
      "Url": "https://download.microsoft.com/download/615540bc-be0b-433a-b91b-1f2b0642bb24/adk/Installers/d2611745022d67cf9a7703eb131ca487.cab",
      "Size": 1096362,
      "SHA1": "20294416A5204533FAA01892196D62CF74B48AAD",
      "Files": [
        {
          "Source": "fil7d30d87b7ebcca3d7a4b95d331b210e6",
          "Path": "amd64\\DISM\\WimMountAdkSetupAmd64.exe",
          "Size": 95648,
          "SHA256": "3628CC6893EFE1FF0299A3019DE9CD8125196AE2ACCB643E0B74E5E56920B27D"
        },
        {
          "Source": "fil4927034346f01b02536bd958141846b2",
          "Path": "amd64\\DISM\\imagex.exe",
          "Size": 969120,
          "SHA256": "AC922A33B1E490276CA6902A6EE88D104D9B40B357C7BFEE20EA1DFE72D19527"
        },
        {
          "Source": "filbce32eb05faf5e2ec0537a0ccd32f04e",
          "Path": "amd64\\DISM\\wimgapi.dll",
          "Size": 936312,
          "SHA256": "144EF3081BFF0BB6C6BA528EECF3F21E80F49C114CB17EFC766251723A6970BF"
        },
        {
          "Source": "filfbc9b981ef7793429883c85df4117cd3",
          "Path": "amd64\\DISM\\wimmount.hiv",
          "Size": 8192,
          "SHA256": "26F1A49570DE66FADBCD9DFF211E0A7AF6353711782F484FADE6CE9BD728A816"
        },
        {
          "Source": "fil468e14f4b37636acb529da9d11b55362",
          "Path": "amd64\\DISM\\wimmount.sys",
          "Size": 75168,
          "SHA256": "18C9534E0FD01E16BD33DC993874E821D318689FFA3A0E3FCE205C3ABD84B024"
        },
        {
          "Source": "fil56c851945da6dfbb42939c1096ab33b5",
          "Path": "amd64\\DISM\\wimserv.exe",
          "Size": 670072,
          "SHA256": "6F7EAB2F7168BF8CF4D693D131A9D7666C5DEC442260E8C190AE9FC0A64EFA47"
        }
      ],
      "SHA256": "DFE132B8B0E077F2FE69243F0197F62C4FAF0E3E2CC50AF49326E2C208D805A0"
    },
    {
      "Name": "fdfb8cfc2e4d170431fb6b8c67210672.cab",
      "Url": "https://download.microsoft.com/download/615540bc-be0b-433a-b91b-1f2b0642bb24/adk/Installers/fdfb8cfc2e4d170431fb6b8c67210672.cab",
      "Size": 749820,
      "SHA1": "20D8D75FD858942212A2731BBA8B4548509DF4E6",
      "Files": [
        {
          "Source": "filed092e3a9af6ac961aa9e4df65fa6c78",
          "Path": "amd64\\DISM\\cimfs.dll",
          "Size": 415136,
          "SHA256": "782978F592AE62589E4FA840D138FA045C0F7865045993BE289A468F05C4E883"
        },
        {
          "Source": "fil1b11b206fc3964237f2c8bbef72bf0df",
          "Path": "amd64\\DISM\\cimfs.sys",
          "Size": 370080,
          "SHA256": "3DE9011BCD8F4AC472E83D56A5977EC66B9281299510DE80076D782565CBECA7"
        },
        {
          "Source": "fil9ebcea407d5d1a159e4b8fe0670fb393",
          "Path": "amd64\\DISM\\UnionFS.hiv",
          "Size": 8192,
          "SHA256": "27B14652E3434AE1DC27D53CE4D96F200A295BF869AB07EE38108ABE5E189A43"
        },
        {
          "Source": "fil58aebb32fdc35a3b4a2510b73ea2bde6",
          "Path": "amd64\\DISM\\UnionFS.sys",
          "Size": 673224,
          "SHA256": "F0618B3F177E455CBDA50E0266B3DED121BBC680F5FA91B324389260399124AA"
        },
        {
          "Source": "fil2be67719001d9c51be32af0b9979351f",
          "Path": "amd64\\DISM\\UnionFSApi.dll",
          "Size": 275872,
          "SHA256": "F94A4B66524EBA145B89B4AC93BF60FC165D243949F36E301AC43269D219CA82"
        },
        {
          "Source": "fil21b8e7f7d2e5d4646cff984fc1e6266e",
          "Path": "amd64\\DISM\\WofAdk.hiv",
          "Size": 8192,
          "SHA256": "D09B6ADDACABF0CCE7479C59963E95B470EE0B6385DB59ED637B98850B0A2502"
        },
        {
          "Source": "fil50d4af1a34c5b86a045ef5432a18a0d5",
          "Path": "amd64\\DISM\\wofadk.sys",
          "Size": 275872,
          "SHA256": "EA3947964F66D714774FFCDF815875D9D04823D5C13B3914E4BD1E983693D0F7"
        }
      ],
      "SHA256": "1D663E3059FB7B583ABE7F18A6E82BAED3C3EF094B761913DAC16B7DC440B037"
    }
  ]
}
'
        }
        'winpe-26100.json' {
'{
  "Version": "10.1.26100.2454",
  "Architecture": "amd64",
  "Build": 26100,
  "Source": "https://go.microsoft.com/fwlink/?linkid=2289981",
  "BaseUrl": "https://download.microsoft.com/download/5/5/6/556e01ec-9d78-417d-b1e1-d83a2eff20bc/ADKWinPEAddons/Installers/",
  "MsiSHA256": "F286C52FDF694C85F08F6EC0BA7702DE84F891040064B81163C8DA59A5C4DB4C",
  "Archives": [
    {
      "Name": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab",
      "Size": 320140822,
      "SHA1": "EF146291E09B6918CFA3150A37043D66DFF11440"
    },
    {
      "Name": "9722214af0ab8aa9dffb6cfdafd937b7.cab",
      "Size": 334507604,
      "SHA1": "E68D67F374897D07FBA3B5070134613AFC9F2454"
    }
  ],
  "Files": [
    {
      "Path": "WinPE-FontSupport-JA-JP.cab",
      "Member": "fil7a697abb44760f2de03561e0bf828d6c",
      "Size": 21064966,
      "Archive": "9722214af0ab8aa9dffb6cfdafd937b7.cab"
    },
    {
      "Path": "WinPE-FontSupport-KO-KR.cab",
      "Member": "filb4b33c996be46ae62c9cde6d150c0276",
      "Size": 10416931,
      "Archive": "9722214af0ab8aa9dffb6cfdafd937b7.cab"
    },
    {
      "Path": "WinPE-FontSupport-WinRE.cab",
      "Member": "filcace02ad6c796335521be691c3785f3b",
      "Size": 3620794,
      "Archive": "9722214af0ab8aa9dffb6cfdafd937b7.cab"
    },
    {
      "Path": "WinPE-FontSupport-ZH-CN.cab",
      "Member": "fil8ae025137d17d24d0d4e540f85dc70a5",
      "Size": 35764298,
      "Archive": "9722214af0ab8aa9dffb6cfdafd937b7.cab"
    },
    {
      "Path": "WinPE-FontSupport-ZH-HK.cab",
      "Member": "fil4574d6ffd7e1b54689291035a7d5c0ed",
      "Size": 30809917,
      "Archive": "9722214af0ab8aa9dffb6cfdafd937b7.cab"
    },
    {
      "Path": "WinPE-FontSupport-ZH-TW.cab",
      "Member": "fil86cfac3b224ca45fd77d09225ddbecae",
      "Size": 30810171,
      "Archive": "9722214af0ab8aa9dffb6cfdafd937b7.cab"
    },
    {
      "Path": "fr-ca/lp.cab",
      "Member": "fila8ee24835928d31effa473734b447fb4",
      "Size": 3655136,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-DismCmdlets_fr-ca.cab",
      "Member": "fil914ea0f56724f010e7d29c02752612bd",
      "Size": 12834,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-Dot3Svc_fr-ca.cab",
      "Member": "filff88bfe7fe8a19bdc0523e710f8ec94e",
      "Size": 93338,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-EnhancedStorage_fr-ca.cab",
      "Member": "fil1312499959f00add3165e6b89ed60ded",
      "Size": 12380,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-HTA_fr-ca.cab",
      "Member": "fil21516ef24c1f9089cf60797c5daee51f",
      "Size": 506183,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-LegacySetup_fr-ca.cab",
      "Member": "fil1772b213619fcc13a36e7f7b33f2e25a",
      "Size": 53882,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-MDAC_fr-ca.cab",
      "Member": "fil29d053120a61f23c5ffe7aa6da6c6f40",
      "Size": 432730,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-NetFx_fr-ca.cab",
      "Member": "fileb0f822f145f3c405e8b9a320dcfc72c",
      "Size": 4037958,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-PmemCmdlets_fr-ca.cab",
      "Member": "fil000f4403a970de146cc7c97a7edb0f44",
      "Size": 11457,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-PowerShell_fr-ca.cab",
      "Member": "fil4e3f7d20eb6fc1631c63a63e3402f625",
      "Size": 193550,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-PPPoE_fr-ca.cab",
      "Member": "file7fed00c63448bed21ba4898e2167916",
      "Size": 31904,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-Rejuv_fr-ca.cab",
      "Member": "fil029eebedaabb8d7589fae7b2d86ea967",
      "Size": 17111,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-RNDIS_fr-ca.cab",
      "Member": "fil6d072a51d4ef0b791bc2207b0b104e65",
      "Size": 9352,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-Scripting_fr-ca.cab",
      "Member": "filc9dc991f8d773f863c79b96c8d8f22a7",
      "Size": 37547,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-SecureStartup_fr-ca.cab",
      "Member": "fil6a17dd409e960202362e2b36931a5740",
      "Size": 37996,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-Setup_fr-ca.cab",
      "Member": "fil8530d91d0ae9224f834c979a126d8c0d",
      "Size": 105590,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-Setup-ASZ_fr-ca.cab",
      "Member": "fild79a7d85b482cb434f8acddaa7e8232a",
      "Size": 48954,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-Setup-Client_fr-ca.cab",
      "Member": "fil7c7a6aea5edf1fef714c6f6d6de0b663",
      "Size": 48402,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-Setup-Server_fr-ca.cab",
      "Member": "fil427b60effbf9fcb21758c175fa898d8d",
      "Size": 48520,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-SRT_fr-ca.cab",
      "Member": "filbe2a7adbe80224403b011776163d515e",
      "Size": 160336,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-StorageWMI_fr-ca.cab",
      "Member": "fila18d6a232a69377492b5389822b94c2b",
      "Size": 124403,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-WDS-Tools_fr-ca.cab",
      "Member": "fil5761441f2a285a4c510f51f494cab382",
      "Size": 29291,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-WinReCfg_fr-ca.cab",
      "Member": "file10b96425e76d83cfcfa94307e9e6671",
      "Size": 12899,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-ca/WinPE-WMI_fr-ca.cab",
      "Member": "filb56534d211f61fe2895773cc36107b30",
      "Size": 356617,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/lp.cab",
      "Member": "fil002e9696b2d9d1309652905419425429",
      "Size": 3657473,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-DismCmdlets_th-th.cab",
      "Member": "fil839145651004bb240006a324e57cf9e2",
      "Size": 12598,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-Dot3Svc_th-th.cab",
      "Member": "fila480bc7508a5d0ed3df3ce4e8d255b3d",
      "Size": 87848,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-EnhancedStorage_th-th.cab",
      "Member": "fil3971f171aa288d9ebe006bb95a47593a",
      "Size": 12278,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-HTA_th-th.cab",
      "Member": "filb0c52022f36d0b0bbd06486ebdef5e9a",
      "Size": 504205,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-LegacySetup_th-th.cab",
      "Member": "fil61ee1c5387c1dbd0d1cd1d9fc38144f5",
      "Size": 51532,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-MDAC_th-th.cab",
      "Member": "fil4215d18b025376ef082036b8214eda58",
      "Size": 434448,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-NetFx_th-th.cab",
      "Member": "fil84dcebae2d9e44c7b95c851d886db7a7",
      "Size": 126594,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-PmemCmdlets_th-th.cab",
      "Member": "fil5930fb7428e6e9b00269ad1f0b754c00",
      "Size": 10999,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-PowerShell_th-th.cab",
      "Member": "fil99dc81e143c60f633265825d09dc5366",
      "Size": 180086,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-PPPoE_th-th.cab",
      "Member": "filcb366a5fc3d1d658158e23e66c7e7597",
      "Size": 32236,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-Rejuv_th-th.cab",
      "Member": "fil67e80b081599de87bf9019a6825ade6a",
      "Size": 18035,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-RNDIS_th-th.cab",
      "Member": "fil7904f43a4f8694c9a7885e453e7641a3",
      "Size": 9328,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-Scripting_th-th.cab",
      "Member": "fil914cf10fbecd5c5d8292cf39882cf22d",
      "Size": 31651,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-SecureStartup_th-th.cab",
      "Member": "filfc4bce3d9d36d787cb9179b87e53f506",
      "Size": 38770,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-Setup_th-th.cab",
      "Member": "filbd90da4c5476826116b14b70fb1bcbde",
      "Size": 119316,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-Setup-ASZ_th-th.cab",
      "Member": "fil443375064726495e633f6bfe4632e253",
      "Size": 47578,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-Setup-Client_th-th.cab",
      "Member": "filc30c21e9bc5f0bddd0970bb155f3518e",
      "Size": 47756,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-Setup-Server_th-th.cab",
      "Member": "fil0cc6ea897910d49c39e1d2e63c477663",
      "Size": 47804,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-SRT_th-th.cab",
      "Member": "filaf7ce85197bcc1de71c1c68c28e57fd9",
      "Size": 151346,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-StorageWMI_th-th.cab",
      "Member": "fil8d13acab7362a664f2fe6b985442aa28",
      "Size": 127237,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-WDS-Tools_th-th.cab",
      "Member": "fil3f1c58fd2a6db193c927629ce2d9f244",
      "Size": 31243,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-WinReCfg_th-th.cab",
      "Member": "fil7ac6607b6fdf64e8996e571e9b07b519",
      "Size": 14971,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "th-th/WinPE-WMI_th-th.cab",
      "Member": "filc7e239b6a8f0d942cb5ce62ef38e5be6",
      "Size": 492967,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/lp.cab",
      "Member": "fil118f3ba8ff5298875262c6b880b05a99",
      "Size": 3698239,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-DismCmdlets_bg-bg.cab",
      "Member": "fil6dde24aa354920b481c50b0eb59249c6",
      "Size": 12466,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-Dot3Svc_bg-bg.cab",
      "Member": "fildeb961ba4afe23cd763b642b1090f2e8",
      "Size": 88318,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-EnhancedStorage_bg-bg.cab",
      "Member": "fild246d560a3ae7320d52b2d91ba1941d4",
      "Size": 12158,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-HTA_bg-bg.cab",
      "Member": "fil38b1112fd8f6b6c34c48ced69c9284c2",
      "Size": 510359,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-LegacySetup_bg-bg.cab",
      "Member": "fil92211a436100d7d15bc5da5300e8af3c",
      "Size": 53754,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-MDAC_bg-bg.cab",
      "Member": "fil793af856b12b06ccffbe6f583172944a",
      "Size": 431606,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-NetFx_bg-bg.cab",
      "Member": "filb82d6e4444bf70b2e653842138ae8c0d",
      "Size": 126590,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-PmemCmdlets_bg-bg.cab",
      "Member": "filba277ac6ab6fca3401501231959825f4",
      "Size": 10985,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-PowerShell_bg-bg.cab",
      "Member": "fil2fadf602421516509f029dde6194629c",
      "Size": 180024,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-PPPoE_bg-bg.cab",
      "Member": "fil61b7abd8322dd848a0345d983161fdad",
      "Size": 32770,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-Rejuv_bg-bg.cab",
      "Member": "filb1e6eb63ddd9d6624ec451f6ae96bab9",
      "Size": 18645,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-RNDIS_bg-bg.cab",
      "Member": "fil5ab1ff65661815ba73b1f9cfe451d77f",
      "Size": 9188,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-Scripting_bg-bg.cab",
      "Member": "file98bca5efe723f2d55a2fe5f67f27c28",
      "Size": 33105,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-SecureStartup_bg-bg.cab",
      "Member": "fil004b936c085d4f5bc49c3ac99d08d33d",
      "Size": 38806,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-Setup_bg-bg.cab",
      "Member": "fila31b2a3107a84cd6a157371ab05bbfe1",
      "Size": 122584,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-Setup-ASZ_bg-bg.cab",
      "Member": "fil89762c82cbc57cca83ec68cd0bf4ab66",
      "Size": 46910,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-Setup-Client_bg-bg.cab",
      "Member": "fil4a7715163d36c1d1f3e292b7334b6f74",
      "Size": 48230,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-Setup-Server_bg-bg.cab",
      "Member": "fil6a72409d34e1a685261b44541ab8de1f",
      "Size": 47290,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-SRT_bg-bg.cab",
      "Member": "filaab1f037f1dac63710ab73ac25b1e954",
      "Size": 155228,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-StorageWMI_bg-bg.cab",
      "Member": "fil0ef564a8a0eb8b492b0dcff1d73ae837",
      "Size": 127249,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-WDS-Tools_bg-bg.cab",
      "Member": "fil46c54c7d188853c927d3084adaea9336",
      "Size": 30667,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-WinReCfg_bg-bg.cab",
      "Member": "fil770e6ade61a786ec8e236e7c1df5faef",
      "Size": 15101,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "bg-bg/WinPE-WMI_bg-bg.cab",
      "Member": "fil81380359a70303ce629e18d813a50aa3",
      "Size": 497019,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/lp.cab",
      "Member": "fil3a2e538a7447ce278da456a055b11765",
      "Size": 3589888,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-DismCmdlets_tr-tr.cab",
      "Member": "fil8660f8d1c88eea051074c1b9d67efb88",
      "Size": 12596,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-Dot3Svc_tr-tr.cab",
      "Member": "filf4b7999a902a7742c371bb86d608c649",
      "Size": 86876,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-EnhancedStorage_tr-tr.cab",
      "Member": "fil38c5136f2fc220d2e6fa4949c8817ff3",
      "Size": 12362,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-HTA_tr-tr.cab",
      "Member": "fil1cf079ea0036f539dd8c1786efca4482",
      "Size": 507619,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-LegacySetup_tr-tr.cab",
      "Member": "fil2c6febc0ef88f669fc3a271b2a743b7f",
      "Size": 53048,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-MDAC_tr-tr.cab",
      "Member": "fil72e25b7387d0b8a89a06e9823c5c7ca5",
      "Size": 427690,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-NetFx_tr-tr.cab",
      "Member": "filc66e4f2b0afbd09576252c74af9a8f73",
      "Size": 4010786,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-PmemCmdlets_tr-tr.cab",
      "Member": "fil011f381d4aa195a5f13882a669cae28d",
      "Size": 11003,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-PowerShell_tr-tr.cab",
      "Member": "fil10dca2fce8b194ecea3eaff882a08560",
      "Size": 180546,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-PPPoE_tr-tr.cab",
      "Member": "fil6143306b49f34320238827169aef40cb",
      "Size": 32038,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-Rejuv_tr-tr.cab",
      "Member": "fil4e7f8c1d01b568d6158be96c74a52a6e",
      "Size": 17837,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-RNDIS_tr-tr.cab",
      "Member": "fil3402a298537f799d350b03d374c39d23",
      "Size": 9222,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-Scripting_tr-tr.cab",
      "Member": "fil0c09bf020e8d343d657b88ea0b26353d",
      "Size": 33723,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-SecureStartup_tr-tr.cab",
      "Member": "fil36de665e70071409685abf59fd83f34b",
      "Size": 35730,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-Setup_tr-tr.cab",
      "Member": "filc061b71090ec1de8feb74c43ea8112c0",
      "Size": 106056,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-Setup-ASZ_tr-tr.cab",
      "Member": "fil5783fba562df2f2041651560d255ee6f",
      "Size": 48126,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-Setup-Client_tr-tr.cab",
      "Member": "fil53574f41d3bcf1397ba089e5496f20fc",
      "Size": 48196,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-Setup-Server_tr-tr.cab",
      "Member": "fil1f8caf29bb21cf966397ce515f774a18",
      "Size": 48306,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-SRT_tr-tr.cab",
      "Member": "filcd67f6ae940654eda71ca0de7284087d",
      "Size": 151664,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-StorageWMI_tr-tr.cab",
      "Member": "fil78af100a80b86e3ee2dfd43ab239021a",
      "Size": 125741,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-WDS-Tools_tr-tr.cab",
      "Member": "fil9f95d9b0114e47a003e1f114083619f6",
      "Size": 28833,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-WinReCfg_tr-tr.cab",
      "Member": "fil2a4141838a6d6a7e489e3a4b0da844e5",
      "Size": 12351,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "tr-tr/WinPE-WMI_tr-tr.cab",
      "Member": "fil6ebec43794f59a76f7ccd03cc7ea25ee",
      "Size": 351979,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/lp.cab",
      "Member": "fil1c070eb5a17c806f84d27b83eb94ae7a",
      "Size": 3440088,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-DismCmdlets_en-gb.cab",
      "Member": "fila41b8d240b112342ca7c943a7b5f5684",
      "Size": 12582,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-Dot3Svc_en-gb.cab",
      "Member": "fild69fb69165bd0c1583ad296c8507ae6d",
      "Size": 83096,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-EnhancedStorage_en-gb.cab",
      "Member": "fil8004594d37902216ba0e56a3356913a1",
      "Size": 12298,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-HTA_en-gb.cab",
      "Member": "fil01324a52c2a0acca3bcef2ee6956745e",
      "Size": 497685,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-LegacySetup_en-gb.cab",
      "Member": "filf427cb16b398400fd7bfd5cdf14ac557",
      "Size": 48690,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-MDAC_en-gb.cab",
      "Member": "fil6294041be46def638a342ec72b64adf3",
      "Size": 421874,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-NetFx_en-gb.cab",
      "Member": "filbbf9c47ada0515d1abe3eef02a838d43",
      "Size": 126432,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-PmemCmdlets_en-gb.cab",
      "Member": "fila07813946670b2e472e391edcbaa6633",
      "Size": 11135,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-PowerShell_en-gb.cab",
      "Member": "fil90de7076f9ca684794d8b8fd6afe140d",
      "Size": 180086,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-PPPoE_en-gb.cab",
      "Member": "fil7a4c4a0cde101d49cc8bac7a5610d707",
      "Size": 31708,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-Rejuv_en-gb.cab",
      "Member": "filfbd062915b43760eb12f8da234ee19ee",
      "Size": 17649,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-RNDIS_en-gb.cab",
      "Member": "fil1704c224651eabb590e22aabbf431318",
      "Size": 9200,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-Scripting_en-gb.cab",
      "Member": "fil3fabb7bb4be18f0d8f1ebd8049c389eb",
      "Size": 33089,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-SecureStartup_en-gb.cab",
      "Member": "fil13c3949d2f1a9c2fd6fb3cc52017abf3",
      "Size": 33498,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-Setup_en-gb.cab",
      "Member": "fil1162514a1c5323a339184dc60209dcea",
      "Size": 99346,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-Setup-ASZ_en-gb.cab",
      "Member": "fil79baaf574f7e36f6124e55c18349d5b0",
      "Size": 47892,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-Setup-Client_en-gb.cab",
      "Member": "fildf1725717c9dc1aa2b0a4a550af78be5",
      "Size": 47626,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-Setup-Server_en-gb.cab",
      "Member": "fil92641cabfd5d6eb2d8a9f34a52486269",
      "Size": 48276,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-SRT_en-gb.cab",
      "Member": "fil7c483c4ed7a149b9ce90d4c7ae552d94",
      "Size": 143916,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-StorageWMI_en-gb.cab",
      "Member": "fil951631594e44f2c306ce823f254406a9",
      "Size": 124371,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-WDS-Tools_en-gb.cab",
      "Member": "filde24ed5f00c28e06c44996a86c873014",
      "Size": 27539,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-WinReCfg_en-gb.cab",
      "Member": "file477a48fa02945410f57d1d230ff9736",
      "Size": 12241,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-gb/WinPE-WMI_en-gb.cab",
      "Member": "fil60343a7806ef171f9001a827a2de189c",
      "Size": 349023,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/lp.cab",
      "Member": "fil9d91343d6469180f614a0fa3bbc15508",
      "Size": 3519740,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-DismCmdlets_hr-hr.cab",
      "Member": "fil6700d1702440ff99a0c4d451f1fd5d63",
      "Size": 12596,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-Dot3Svc_hr-hr.cab",
      "Member": "fil9e0cefc1d0a341c856b103b56abe9358",
      "Size": 87360,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-EnhancedStorage_hr-hr.cab",
      "Member": "fil24f662d4630e35710bca3ae3e39920f7",
      "Size": 12292,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-HTA_hr-hr.cab",
      "Member": "fil745e4aa89ccf5ef38c54e161230462a5",
      "Size": 506475,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-LegacySetup_hr-hr.cab",
      "Member": "fil03c538ab3e717a0cbedfee6ae6e56d9e",
      "Size": 51936,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-MDAC_hr-hr.cab",
      "Member": "fil81cf7501f710b18d519bff7bf0a09ed6",
      "Size": 425882,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-NetFx_hr-hr.cab",
      "Member": "fil3dd3651ef757640d8401f410bfca2373",
      "Size": 126586,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-PmemCmdlets_hr-hr.cab",
      "Member": "fil9f0cd4631a321ef2b487bfadb2f0a9f1",
      "Size": 11149,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-PowerShell_hr-hr.cab",
      "Member": "fil4c56d0f50ff3376ab962832c676a2da1",
      "Size": 180068,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-PPPoE_hr-hr.cab",
      "Member": "fil02b6a7ce3ae0eb7c6849c24ab783c8f4",
      "Size": 33122,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-Rejuv_hr-hr.cab",
      "Member": "filab39b748c67d0a5b3dfbf4f87c6d3adb",
      "Size": 18269,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-RNDIS_hr-hr.cab",
      "Member": "filcd6f0266961147ae3030cbdc66a15abc",
      "Size": 9306,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-Scripting_hr-hr.cab",
      "Member": "fil753c88c5cfde4160240ca136859dfb70",
      "Size": 31595,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-SecureStartup_hr-hr.cab",
      "Member": "fildc6a39e55187f29a8fa061c79ce0c6d8",
      "Size": 35804,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-Setup_hr-hr.cab",
      "Member": "fil3386ef56bd4a160031bef6dc47f8c640",
      "Size": 103870,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-Setup-ASZ_hr-hr.cab",
      "Member": "filbff4651981235c2eabb95bc98d45b320",
      "Size": 47060,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-Setup-Client_hr-hr.cab",
      "Member": "fil2099750531fffb790c395f4ac8bc290b",
      "Size": 48922,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-Setup-Server_hr-hr.cab",
      "Member": "fil2eb1f364143cc77cb3b9f9fd22946590",
      "Size": 47306,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-SRT_hr-hr.cab",
      "Member": "filbe423078d69ad8011783ad089942898c",
      "Size": 150346,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-StorageWMI_hr-hr.cab",
      "Member": "fil25f801b151699cd5d5a792d359365ef7",
      "Size": 124359,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-WDS-Tools_hr-hr.cab",
      "Member": "filb427c2813daf40db39026e19dbdc9a45",
      "Size": 27799,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-WinReCfg_hr-hr.cab",
      "Member": "fil0152f0ee18fce5f26364463510a3bcea",
      "Size": 12225,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hr-hr/WinPE-WMI_hr-hr.cab",
      "Member": "fil5355e7892d8a73ed68412b7df3777953",
      "Size": 345017,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/lp.cab",
      "Member": "fil7d21cdefce21077c3d719f1e43b6e5b0",
      "Size": 3668095,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-DismCmdlets_ar-sa.cab",
      "Member": "fil01992e9f03809d63ff3e8a6ef6ed0771",
      "Size": 12462,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-Dot3Svc_ar-sa.cab",
      "Member": "filff8d0f1dbc8a92bf5482a4812ca7a8b2",
      "Size": 89244,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-EnhancedStorage_ar-sa.cab",
      "Member": "filff823c7ebbc414d7763715afd447ed9f",
      "Size": 12166,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-HTA_ar-sa.cab",
      "Member": "fil80c15b74ebe7a3d90bac05aaf302ff52",
      "Size": 519835,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-LegacySetup_ar-sa.cab",
      "Member": "fil02c1b059d2b1c1ac025c7893f298dc7a",
      "Size": 49696,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-MDAC_ar-sa.cab",
      "Member": "fil97520d17f2e65aa092857e652c989bbf",
      "Size": 428396,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-NetFx_ar-sa.cab",
      "Member": "fil8a96f420a5c3c3f563788edfee42d7f9",
      "Size": 4045622,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-PmemCmdlets_ar-sa.cab",
      "Member": "fild61d5d0c916aa4e45c71a13c7da53f1b",
      "Size": 11127,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-PowerShell_ar-sa.cab",
      "Member": "fild3dcc282e0618371816c2e3d311b57af",
      "Size": 180114,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-PPPoE_ar-sa.cab",
      "Member": "filc9c522931bddf17a8ab37f6b538ef0c9",
      "Size": 32360,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-Rejuv_ar-sa.cab",
      "Member": "fil1d2bb2f93589fbab32324ef36bfbaebd",
      "Size": 17573,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-RNDIS_ar-sa.cab",
      "Member": "fil7f986fd8925306e0fb6c4733ed1e868a",
      "Size": 9318,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-Scripting_ar-sa.cab",
      "Member": "filf4fe438720603f046709f627e2c67c03",
      "Size": 33959,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-SecureStartup_ar-sa.cab",
      "Member": "fil4ab073e23d5e709bea52e68c4f9d5f14",
      "Size": 37902,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-Setup_ar-sa.cab",
      "Member": "fil750d5fb716941c5c96a85605d68f7c5d",
      "Size": 121188,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-Setup-ASZ_ar-sa.cab",
      "Member": "fil7d7270e8421a3f1f711899941a90c2cc",
      "Size": 47072,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-Setup-Client_ar-sa.cab",
      "Member": "fil416569d95363c8a2c23fb583c93709d8",
      "Size": 48542,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-Setup-Server_ar-sa.cab",
      "Member": "fil27c998083866213686af1e5ce9bc6bbb",
      "Size": 48302,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-SRT_ar-sa.cab",
      "Member": "fila4f379431a686070fae7669bc9578e88",
      "Size": 150958,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-StorageWMI_ar-sa.cab",
      "Member": "fil72319d4a0beb0b2768431955b7b7c720",
      "Size": 125439,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-WDS-Tools_ar-sa.cab",
      "Member": "filf2ee95681c2144dd57f8ca6091d62580",
      "Size": 31285,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-WinReCfg_ar-sa.cab",
      "Member": "filbf86f097def0c33ab01611ecd94efbe0",
      "Size": 14955,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ar-sa/WinPE-WMI_ar-sa.cab",
      "Member": "filf8a8266d6a678d6ce228b5ee70975efa",
      "Size": 495165,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/lp.cab",
      "Member": "filc0a070d4a9a8b5eea09d65a7cea1a094",
      "Size": 3510242,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-DismCmdlets_ro-ro.cab",
      "Member": "fil99e1d698e616e591eafe424d4b29c31b",
      "Size": 12596,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-Dot3Svc_ro-ro.cab",
      "Member": "fil4cbcb13a8fad6541350849f8db87efdf",
      "Size": 84530,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-EnhancedStorage_ro-ro.cab",
      "Member": "fil49831404f8f719f9eabe7b74090ba331",
      "Size": 12298,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-HTA_ro-ro.cab",
      "Member": "fil64a13201f72503523220f7934b0d09be",
      "Size": 509959,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-LegacySetup_ro-ro.cab",
      "Member": "filce6df774e49a7f2aaa44338ade759d2d",
      "Size": 50974,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-MDAC_ro-ro.cab",
      "Member": "fila2ee62344bd514dd6926030e2a1d00e1",
      "Size": 426776,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-NetFx_ro-ro.cab",
      "Member": "file345cf5da813756eaf9af3951065c6ba",
      "Size": 127830,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-PmemCmdlets_ro-ro.cab",
      "Member": "fil80debe9be3ac16d703b396cde914f9a7",
      "Size": 10991,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-PowerShell_ro-ro.cab",
      "Member": "fil040e333e27249fff29423ed1d0c50ca4",
      "Size": 180112,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-PPPoE_ro-ro.cab",
      "Member": "fil7ec8c75a92dd9e44b20c8ae95cf2a291",
      "Size": 33024,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-Rejuv_ro-ro.cab",
      "Member": "filefc39dad7867b0e37b2369a3d7ea7423",
      "Size": 17847,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-RNDIS_ro-ro.cab",
      "Member": "fila0083d54016a173e6a3d75433f250b01",
      "Size": 9206,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-Scripting_ro-ro.cab",
      "Member": "fild8b5179809ec5515074ffbc0dca5d66c",
      "Size": 31399,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-SecureStartup_ro-ro.cab",
      "Member": "fil43a246988ae580456e4a6fea6312f0ae",
      "Size": 33378,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-Setup_ro-ro.cab",
      "Member": "filc6f0879346bbacda656f01061dd9ab4d",
      "Size": 102708,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-Setup-ASZ_ro-ro.cab",
      "Member": "fil034e55f26bc92c91090b9f2099d1691d",
      "Size": 47594,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-Setup-Client_ro-ro.cab",
      "Member": "fil5b6a8ca82d3ffd1b5ca98634b4cc5c1f",
      "Size": 48540,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-Setup-Server_ro-ro.cab",
      "Member": "fil1c291d8904a6a304ee57fc2f1ec223d4",
      "Size": 48306,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-SRT_ro-ro.cab",
      "Member": "fil3ff885c42983f185aec9bbc016aaf280",
      "Size": 151406,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-StorageWMI_ro-ro.cab",
      "Member": "fil3c3caead67734d2f3231d87f51cab2e6",
      "Size": 124481,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-WDS-Tools_ro-ro.cab",
      "Member": "fil4e0a6fe1fac0ef67fcc6d4c71b3a9045",
      "Size": 27569,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-WinReCfg_ro-ro.cab",
      "Member": "fila1bc7a095106e247eb82ec09a41517c7",
      "Size": 12373,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ro-ro/WinPE-WMI_ro-ro.cab",
      "Member": "filcb765f666c482a872e761d1775201031",
      "Size": 349191,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/lp.cab",
      "Member": "fil25f9053c25dff58d755dd91d88142466",
      "Size": 3645548,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-DismCmdlets_cs-cz.cab",
      "Member": "fil037fbfcf4f46e424b4931ad993ed34b6",
      "Size": 12604,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-Dot3Svc_cs-cz.cab",
      "Member": "fil8cd382e95d1e9e5f8bea5aacad5bd095",
      "Size": 86382,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-EnhancedStorage_cs-cz.cab",
      "Member": "fild4eecb691fdd18e80b6feb28748687fe",
      "Size": 12294,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-HTA_cs-cz.cab",
      "Member": "fil260b55e1792a32458ec61325284ce3ba",
      "Size": 512617,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-LegacySetup_cs-cz.cab",
      "Member": "filbc2b8c6e7261df98757850a83ed638f2",
      "Size": 52454,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-MDAC_cs-cz.cab",
      "Member": "fil055f196da030c1395d978d4593077c84",
      "Size": 428984,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-NetFx_cs-cz.cab",
      "Member": "fil935bd63b63d33bf8dc8635e6b72eb5e1",
      "Size": 4064632,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-PmemCmdlets_cs-cz.cab",
      "Member": "fil9f8b7fc171d1accbde392c8470b96b0e",
      "Size": 11139,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-PowerShell_cs-cz.cab",
      "Member": "fila3510aa47b3e8d242209e9e53db0e9b0",
      "Size": 180590,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-PPPoE_cs-cz.cab",
      "Member": "fil57ae4c97a4ef8983c84493838c036c35",
      "Size": 33238,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-Rejuv_cs-cz.cab",
      "Member": "fil984f4aa99fcb7036827a1c56340d71eb",
      "Size": 17173,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-RNDIS_cs-cz.cab",
      "Member": "fil9cfeef84808c22880265a677332825e1",
      "Size": 9348,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-Scripting_cs-cz.cab",
      "Member": "fil42b219e3611aae004acb12aa0304e4d2",
      "Size": 34223,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-SecureStartup_cs-cz.cab",
      "Member": "fil4efdace8cbee9cd552aea9dc86a00dc5",
      "Size": 35634,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-Setup_cs-cz.cab",
      "Member": "fil6334086369999487c94033173804bfcf",
      "Size": 106402,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-Setup-ASZ_cs-cz.cab",
      "Member": "fil28c87d8b7b6197f4efd2f04e5d3a6c1c",
      "Size": 48294,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-Setup-Client_cs-cz.cab",
      "Member": "filaaa83e51e2978513155cd12b8e6641fc",
      "Size": 48370,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-Setup-Server_cs-cz.cab",
      "Member": "fil6120e350ce78aa14cccc72b1b47b71d4",
      "Size": 48408,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-SRT_cs-cz.cab",
      "Member": "fil73d599b71202d81576ce42a2713ce506",
      "Size": 154082,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-StorageWMI_cs-cz.cab",
      "Member": "fil4bf1b168a09d3db18973e690c4dd96f0",
      "Size": 125793,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-WDS-Tools_cs-cz.cab",
      "Member": "fild2c46d74dd103041ed3a4b76bfaaf46a",
      "Size": 29993,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-WinReCfg_cs-cz.cab",
      "Member": "fil971d3dc0ed584cfee3feed4b72efe41f",
      "Size": 12391,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "cs-cz/WinPE-WMI_cs-cz.cab",
      "Member": "filfdd5ce29e701c259b943d6141f1e57c9",
      "Size": 356363,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/lp.cab",
      "Member": "fil82f537c0ff6996508e928ad1936fe39c",
      "Size": 3593236,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-DismCmdlets_pt-br.cab",
      "Member": "fil0426176a8b240d00d7569acdd0a82b37",
      "Size": 12664,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-Dot3Svc_pt-br.cab",
      "Member": "fil0ee9f9adb123edc87362864a6b863b91",
      "Size": 89548,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-EnhancedStorage_pt-br.cab",
      "Member": "filc6617b131c4c9f1c4e0af2f3abc007ed",
      "Size": 12364,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-HTA_pt-br.cab",
      "Member": "fil790bbc8499be70e3484e404eca238ba5",
      "Size": 506845,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-LegacySetup_pt-br.cab",
      "Member": "filbb4caba1771dfa142d9d6ec1bfb8cdeb",
      "Size": 50430,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-MDAC_pt-br.cab",
      "Member": "fil69406de6a7fa648b259d7beee83cc70b",
      "Size": 429140,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-NetFx_pt-br.cab",
      "Member": "fil4ca3648817c6a5f1fef9bfb369d0ff97",
      "Size": 4016328,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-PmemCmdlets_pt-br.cab",
      "Member": "fil2ca729cdb7cc45269a6e77c16ae2bc7b",
      "Size": 11281,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-PowerShell_pt-br.cab",
      "Member": "fil072ea682985482b25d4c42f7226a0df6",
      "Size": 188410,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-PPPoE_pt-br.cab",
      "Member": "fil1f9965cf57399b58b8f7a5166e553224",
      "Size": 30780,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-Rejuv_pt-br.cab",
      "Member": "fil73e96bbefab89f79f07a0193ae3ad7d6",
      "Size": 18597,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-RNDIS_pt-br.cab",
      "Member": "fil5c5a0bcef60c3d9ae0a9b95d219594ac",
      "Size": 9230,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-Scripting_pt-br.cab",
      "Member": "fil4fe6007c6c13b8468ad678edaf1ff1a1",
      "Size": 33043,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-SecureStartup_pt-br.cab",
      "Member": "fild67e2d1e11f1fb2f8dbbeb82db543820",
      "Size": 37620,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-Setup_pt-br.cab",
      "Member": "fil11c513ec62c38b19ad5b420a4fb9e1a1",
      "Size": 104624,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-Setup-ASZ_pt-br.cab",
      "Member": "fil90c1eaabf516a4356f2926d8cdf7e9f9",
      "Size": 47780,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-Setup-Client_pt-br.cab",
      "Member": "filc188e50dccff1114a57b299db9a4205e",
      "Size": 48494,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-Setup-Server_pt-br.cab",
      "Member": "filcde41079859bc036b393e48062ace96a",
      "Size": 47936,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-SRT_pt-br.cab",
      "Member": "filee8f6f9df294af35c20640b07f18668b",
      "Size": 154380,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-StorageWMI_pt-br.cab",
      "Member": "fil135db13f28da28a0af156a34025e4038",
      "Size": 125199,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-WDS-Tools_pt-br.cab",
      "Member": "filfb882b2136ac65517850f5c98dc17996",
      "Size": 28995,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-WinReCfg_pt-br.cab",
      "Member": "filb4a3ae575cc4ec9db3f63d7a4d82df02",
      "Size": 12835,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-br/WinPE-WMI_pt-br.cab",
      "Member": "fil71c62a935ac12147e24821e2dc926ee8",
      "Size": 367245,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/lp.cab",
      "Member": "filda10657cf0e4bd1e663b25ca6abae769",
      "Size": 4684555,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-DismCmdlets_ru-ru.cab",
      "Member": "filf8b3fd253190f715d91c6dbb11b1731f",
      "Size": 13198,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-Dot3Svc_ru-ru.cab",
      "Member": "filb349fd7112e9ccdce28c818c03ed7290",
      "Size": 132745,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-EnhancedStorage_ru-ru.cab",
      "Member": "fil46024c55bc439071415e9ffc759af010",
      "Size": 12332,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-HTA_ru-ru.cab",
      "Member": "fild44fdaaa4bcb083c5602b8cf58ccbe7e",
      "Size": 511323,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-LegacySetup_ru-ru.cab",
      "Member": "fil04411dcc1b0dd2a45b4b2afb03a1957f",
      "Size": 54280,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-MDAC_ru-ru.cab",
      "Member": "filf90601a0706ef466700806c37a2465d6",
      "Size": 441682,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-NetFx_ru-ru.cab",
      "Member": "fil7f0d06ad24c1551ae77534ef31570417",
      "Size": 4221750,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-PmemCmdlets_ru-ru.cab",
      "Member": "fil1f2b52d4d3aff2a4450ab391dfa1045f",
      "Size": 11659,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-PowerShell_ru-ru.cab",
      "Member": "fil904be2c3455d7e57174a86411628ff66",
      "Size": 200614,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-PPPoE_ru-ru.cab",
      "Member": "fila05bf59ff0e3ed8b64fefb4b35403f2a",
      "Size": 32472,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-Rejuv_ru-ru.cab",
      "Member": "fil452f74810a89c2e6ffbd8762fbf144cc",
      "Size": 18813,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-RNDIS_ru-ru.cab",
      "Member": "fila89d959d4262d986aebb6dec836b104f",
      "Size": 9370,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-Scripting_ru-ru.cab",
      "Member": "fila781433d34264fddf7bad8b98ed0ec7c",
      "Size": 32527,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-SecureStartup_ru-ru.cab",
      "Member": "fil3b38e2b0733497de5326ed6d76c890ff",
      "Size": 55044,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-Setup_ru-ru.cab",
      "Member": "fil16a3d1d1229aec98797ce81005e449cf",
      "Size": 136544,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-Setup-ASZ_ru-ru.cab",
      "Member": "filf5cae1ab0f2c98b6ab3b3c9c9589ed03",
      "Size": 48526,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-Setup-Client_ru-ru.cab",
      "Member": "fild3bfbd14d99dcc1626512b5497bef1ad",
      "Size": 48806,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-Setup-Server_ru-ru.cab",
      "Member": "filbf9068df97bf616dc517cd07f1cd1548",
      "Size": 48952,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-SRT_ru-ru.cab",
      "Member": "fild16dd694b1dec559128346b2e82bd6b5",
      "Size": 195222,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-StorageWMI_ru-ru.cab",
      "Member": "fildd046e283d1bfba174e362898d6434b3",
      "Size": 134599,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-WDS-Tools_ru-ru.cab",
      "Member": "fil51a134dafa69f7c294b79f63d1e6f149",
      "Size": 34467,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-WinReCfg_ru-ru.cab",
      "Member": "fildb4c0219ad1ebf914a1784a8c0b7ac25",
      "Size": 18181,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ru-ru/WinPE-WMI_ru-ru.cab",
      "Member": "fil88160fc35c48eaec9f436fe231e876da",
      "Size": 563333,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/lp.cab",
      "Member": "filb2eff38578386dd475fb8187654d442b",
      "Size": 3507002,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-DismCmdlets_lv-lv.cab",
      "Member": "fil32db696d651273f18e07f09b925b2219",
      "Size": 12458,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-Dot3Svc_lv-lv.cab",
      "Member": "fil128a94a0eb32d3007c83c01cf91eda32",
      "Size": 86530,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-EnhancedStorage_lv-lv.cab",
      "Member": "fil6e114cec2746b0b1c10c2dce4e9ad6a7",
      "Size": 12292,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-HTA_lv-lv.cab",
      "Member": "filcd535ce34fd941b15093a9c0139c8c3d",
      "Size": 506343,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-LegacySetup_lv-lv.cab",
      "Member": "fil7328e4befba1938764a2551dd7c063cf",
      "Size": 48788,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-MDAC_lv-lv.cab",
      "Member": "fil4651c1b9405047d60394c3f10b354b25",
      "Size": 428842,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-NetFx_lv-lv.cab",
      "Member": "filfa75c7626673ef08f54309a29a7ae8e4",
      "Size": 128022,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-PmemCmdlets_lv-lv.cab",
      "Member": "fil96a0de851891b1634b8bb37a71de1459",
      "Size": 10997,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-PowerShell_lv-lv.cab",
      "Member": "fil81396bec6451aae47887f5f606803f82",
      "Size": 179868,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-PPPoE_lv-lv.cab",
      "Member": "fil92e4caa04b19c3bc415a765ac233e44d",
      "Size": 32472,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-Rejuv_lv-lv.cab",
      "Member": "fil26ec3b05811331882e006ffe8bac43e6",
      "Size": 18685,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-RNDIS_lv-lv.cab",
      "Member": "fil372d6d5532264e2162b71b01e386b305",
      "Size": 9334,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-Scripting_lv-lv.cab",
      "Member": "filc1104383e1408740ef726d7ddba99d61",
      "Size": 31587,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-SecureStartup_lv-lv.cab",
      "Member": "fil3bcc429b554f8f0709d11e785e0f3012",
      "Size": 35450,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-Setup_lv-lv.cab",
      "Member": "fil7075ed9038f98452f53213a61b461c0a",
      "Size": 104560,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-Setup-ASZ_lv-lv.cab",
      "Member": "fil9fe59f6207c7c8527ae4b24b66c8dbbf",
      "Size": 47922,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-Setup-Client_lv-lv.cab",
      "Member": "fil885aabb422182cb718d9bf667a112417",
      "Size": 48674,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-Setup-Server_lv-lv.cab",
      "Member": "fil51516762abd634c3e848284864a1a592",
      "Size": 48170,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-SRT_lv-lv.cab",
      "Member": "fil06a442d6751b644aee2129fc69ce305e",
      "Size": 151684,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-StorageWMI_lv-lv.cab",
      "Member": "filf3c68bd76c08b68afe18cf742ae6061d",
      "Size": 124321,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-WDS-Tools_lv-lv.cab",
      "Member": "fil04d3d7359e99ca6b07c28ed3619fc510",
      "Size": 27579,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-WinReCfg_lv-lv.cab",
      "Member": "fil27e900d28025f075cbd47153e17891c6",
      "Size": 12369,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lv-lv/WinPE-WMI_lv-lv.cab",
      "Member": "fil094e2c2ce1ad129a740831076464197d",
      "Size": 350635,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/lp.cab",
      "Member": "fil5b26cf1488a99ec7b27b47cd2c03bdf3",
      "Size": 3651396,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-DismCmdlets_hu-hu.cab",
      "Member": "filab3c6be45ac8c0c782558b03b0d2906e",
      "Size": 12460,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-Dot3Svc_hu-hu.cab",
      "Member": "fil90be9d7f22f5e9a3c1f8c2b97188205c",
      "Size": 87414,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-EnhancedStorage_hu-hu.cab",
      "Member": "fil4c41a1fe0fec0427bc81d71ff529660a",
      "Size": 12394,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-HTA_hu-hu.cab",
      "Member": "fil783942c93cd652283c6e78b63de18bfd",
      "Size": 510699,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-LegacySetup_hu-hu.cab",
      "Member": "fil83cabc649e7e79c9fd010a0234d183ac",
      "Size": 51062,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-MDAC_hu-hu.cab",
      "Member": "filcb7a2c085d187603ecaabd25b5fb5f0e",
      "Size": 435626,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-NetFx_hu-hu.cab",
      "Member": "fila58a881924078b26758cdba75d8eae0d",
      "Size": 4108876,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-PmemCmdlets_hu-hu.cab",
      "Member": "fil6168361d72c3b14bf38ea915e935ec55",
      "Size": 11135,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-PowerShell_hu-hu.cab",
      "Member": "fil4849f0d5db380332a1f56e2d246a2970",
      "Size": 180612,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-PPPoE_hu-hu.cab",
      "Member": "fild1ca8e56aac7c63321a74e123ca7c579",
      "Size": 32500,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-Rejuv_hu-hu.cab",
      "Member": "filc8f2c85588c3305d7332ad29b8f06f5a",
      "Size": 16925,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-RNDIS_hu-hu.cab",
      "Member": "fil3114b914e2d5b736b08b87fce5c4a08f",
      "Size": 9360,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-Scripting_hu-hu.cab",
      "Member": "fil45f625d6bf4a95b870d7267bc02c19a6",
      "Size": 33957,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-SecureStartup_hu-hu.cab",
      "Member": "file3affca36cff40347df657b56a9f81d8",
      "Size": 35890,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-Setup_hu-hu.cab",
      "Member": "fila309fe4a3311ee6a9e05bde6650dfef8",
      "Size": 105706,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-Setup-ASZ_hu-hu.cab",
      "Member": "fil34ea81045e22501056a862d1295bab58",
      "Size": 48604,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-Setup-Client_hu-hu.cab",
      "Member": "fil96432972d531df90aa0b0d45bd309adb",
      "Size": 48778,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-Setup-Server_hu-hu.cab",
      "Member": "fil6a67c4c9c1434fa11c9e89904f2a7f8b",
      "Size": 48844,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-SRT_hu-hu.cab",
      "Member": "fil1847097ec2500f6e8284864c059b908d",
      "Size": 158770,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-StorageWMI_hu-hu.cab",
      "Member": "filbea358afae49e0f38fc4f2e0b121ea63",
      "Size": 124787,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-WDS-Tools_hu-hu.cab",
      "Member": "fil9e2839250283298cc399068ac2b6ee5a",
      "Size": 29429,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-WinReCfg_hu-hu.cab",
      "Member": "fil0975c20fe3724e3616de54be49574de0",
      "Size": 12237,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "hu-hu/WinPE-WMI_hu-hu.cab",
      "Member": "filf51ae0f7da720ce384e7f80370f9112a",
      "Size": 357579,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/lp.cab",
      "Member": "fild4f09d51a21d31014ab35b718e63ec72",
      "Size": 3655860,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-DismCmdlets_fr-fr.cab",
      "Member": "fil5a5b4395c6f46f3600d5b1f7dd1de36f",
      "Size": 12970,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-Dot3Svc_fr-fr.cab",
      "Member": "filcfe7c09810d3862a15344fd2473bbb3f",
      "Size": 90808,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-EnhancedStorage_fr-fr.cab",
      "Member": "fil98d75ae65dd792a87b8226401901aac7",
      "Size": 12250,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-HTA_fr-fr.cab",
      "Member": "fil524070259bc52b4d06dada05dc78e519",
      "Size": 509429,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-LegacySetup_fr-fr.cab",
      "Member": "fila3921ea9cc5804425a3cd95400710686",
      "Size": 53806,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-MDAC_fr-fr.cab",
      "Member": "fil77cae24418f8bbaadfe180187c681148",
      "Size": 432680,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-NetFx_fr-fr.cab",
      "Member": "fil29e651eea84323229db350cfd7b1ae8d",
      "Size": 4033584,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-PmemCmdlets_fr-fr.cab",
      "Member": "fil90d8011c978ba33e384623fe39d26e62",
      "Size": 11443,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-PowerShell_fr-fr.cab",
      "Member": "filc3899166e518eb914b92dd75a6f19a8a",
      "Size": 193710,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-PPPoE_fr-fr.cab",
      "Member": "fil0df2a1aeb3afd4e2cdf6bfc4197d182c",
      "Size": 33466,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-Rejuv_fr-fr.cab",
      "Member": "file3ca7a55bc033c93676ab9de344d5a96",
      "Size": 18331,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-RNDIS_fr-fr.cab",
      "Member": "file1ed2b64ff91e00b84432285e08549eb",
      "Size": 9352,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-Scripting_fr-fr.cab",
      "Member": "fil14ac90c4f6d6ee414c1ba3a68f748931",
      "Size": 32917,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-SecureStartup_fr-fr.cab",
      "Member": "filb8fdce09b1f5e8d806b104f8d9ebaa4b",
      "Size": 37520,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-Setup_fr-fr.cab",
      "Member": "file10393d2ca71179465534274c16c42cc",
      "Size": 104592,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-Setup-ASZ_fr-fr.cab",
      "Member": "fil24850c910a6333a4720e62b6675af500",
      "Size": 48818,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-Setup-Client_fr-fr.cab",
      "Member": "fil4dc4658dafa11de95c6bc99b99c1e0ac",
      "Size": 48372,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-Setup-Server_fr-fr.cab",
      "Member": "fil4ccc3aa237305920fd19469f2421ea65",
      "Size": 49078,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-SRT_fr-fr.cab",
      "Member": "fil4cc0e7f64258155c142b8fb357981383",
      "Size": 155954,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-StorageWMI_fr-fr.cab",
      "Member": "fil1ce2677ac225851bee1a38a410a1c87c",
      "Size": 125369,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-WDS-Tools_fr-fr.cab",
      "Member": "fil2f9763b66e0f132ec8862b928a9c545e",
      "Size": 29061,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-WinReCfg_fr-fr.cab",
      "Member": "fil80c1195a5e7b082a11cb5816e05a36f7",
      "Size": 12895,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fr-fr/WinPE-WMI_fr-fr.cab",
      "Member": "fil0a1f5ab033014d5f3fd17af681f39d72",
      "Size": 376459,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/lp.cab",
      "Member": "fil7d9348dc1a3248b63e3e3ef65dadd5ba",
      "Size": 3659416,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-DismCmdlets_pl-pl.cab",
      "Member": "filbb4b7ee51cd3383e58e73465ac37f8c0",
      "Size": 12610,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-Dot3Svc_pl-pl.cab",
      "Member": "filfc92048d377ee31084501d59645a67b0",
      "Size": 88668,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-EnhancedStorage_pl-pl.cab",
      "Member": "fild902e3828acf319c4422d9b91c054bd5",
      "Size": 12252,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-HTA_pl-pl.cab",
      "Member": "fil2f9eb5e857251d158feb0d9849f5f84c",
      "Size": 509599,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-LegacySetup_pl-pl.cab",
      "Member": "fil9881dd050bd9b8a4101bbcf77ec82034",
      "Size": 52758,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-MDAC_pl-pl.cab",
      "Member": "fila4d831b4e5b150d48a048f5cfcb4dfe2",
      "Size": 431272,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-NetFx_pl-pl.cab",
      "Member": "fil371f147a4a91a06158832b77e1e50d0b",
      "Size": 4106562,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-PmemCmdlets_pl-pl.cab",
      "Member": "filc37cee3138a24c2b531ba0dff763fb38",
      "Size": 11125,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-PowerShell_pl-pl.cab",
      "Member": "file27e84c15c758a0d8632f6c44e911cb7",
      "Size": 180786,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-PPPoE_pl-pl.cab",
      "Member": "fil622166f42562ad85aeb537202b2c2708",
      "Size": 32880,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-Rejuv_pl-pl.cab",
      "Member": "fil757eeaecc1aa6c7851be43d91c582174",
      "Size": 17239,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-RNDIS_pl-pl.cab",
      "Member": "fil9a4a7e1f28b740b2b1cecfb30f57a5a9",
      "Size": 9372,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-Scripting_pl-pl.cab",
      "Member": "fild173d564719a638285ae44ecbea62b52",
      "Size": 33089,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-SecureStartup_pl-pl.cab",
      "Member": "filb55f5fc8199eed269cbad45359af4d18",
      "Size": 35856,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-Setup_pl-pl.cab",
      "Member": "fila3b09952185e785dd8f6a8df123c6c08",
      "Size": 108762,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-Setup-ASZ_pl-pl.cab",
      "Member": "fil0a28ca1fde646498181b7aba4fe9c916",
      "Size": 48382,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-Setup-Client_pl-pl.cab",
      "Member": "fil69a8eab64ee75f7b3b845cdba7af4e88",
      "Size": 48492,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-Setup-Server_pl-pl.cab",
      "Member": "fil0bfc9e40313e306115773f7bd20ca4b4",
      "Size": 48708,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-SRT_pl-pl.cab",
      "Member": "fil3a9e4171ec52b8430e4529d1bce44306",
      "Size": 155516,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-StorageWMI_pl-pl.cab",
      "Member": "file653f0042b960d4e64faaf9106558b0b",
      "Size": 125881,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-WDS-Tools_pl-pl.cab",
      "Member": "fil1c53984867b0126c7c87a056707fcea4",
      "Size": 29969,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-WinReCfg_pl-pl.cab",
      "Member": "fil5b55b6288a2b6ca20e8208ff6e2a29f0",
      "Size": 12361,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pl-pl/WinPE-WMI_pl-pl.cab",
      "Member": "fil14d48996508b0c819310fd6603b010a3",
      "Size": 353361,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/lp.cab",
      "Member": "filb1d2e8195c02e24588a922e0421e6106",
      "Size": 4082100,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-DismCmdlets_zh-cn.cab",
      "Member": "filaa7f7b32c7565ea7e67e043132c9169c",
      "Size": 12716,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-Dot3Svc_zh-cn.cab",
      "Member": "fil0ab12c6a58dacf023755e733ee1380c2",
      "Size": 120981,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-EnhancedStorage_zh-cn.cab",
      "Member": "fil1c2c2e897d0c2113e87263bb973b079a",
      "Size": 12318,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-HTA_zh-cn.cab",
      "Member": "fil1265679739d4455ad9a797aea5133b1a",
      "Size": 493627,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-LegacySetup_zh-cn.cab",
      "Member": "fil7fe3887efa1f820d44b123f360b87bf3",
      "Size": 48170,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-MDAC_zh-cn.cab",
      "Member": "fil9181583d92257153f4a8c2ae666a40cf",
      "Size": 429564,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-NetFx_zh-cn.cab",
      "Member": "fil6bfec522f3e8210ffbf8ae67ea637894",
      "Size": 3925626,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-PmemCmdlets_zh-cn.cab",
      "Member": "fild5381bb141653fb8dfbd1f171e201009",
      "Size": 11239,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-PowerShell_zh-cn.cab",
      "Member": "fil8e150721f846ba627191447daac74375",
      "Size": 180630,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-PPPoE_zh-cn.cab",
      "Member": "filc74763dda17040020227b9d7c20c37f7",
      "Size": 31110,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-Rejuv_zh-cn.cab",
      "Member": "fil6e6abbb2e9b6c4c5d6670c8e7addaffd",
      "Size": 17311,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-RNDIS_zh-cn.cab",
      "Member": "fildbcdb5dc89919dbcfde6256353ff80f2",
      "Size": 9324,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-Scripting_zh-cn.cab",
      "Member": "fil217f8ab16b6626b158bfda9923f92abe",
      "Size": 31431,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-SecureStartup_zh-cn.cab",
      "Member": "fil25d1931eac8b9783f91f737ad24f46b0",
      "Size": 50606,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-Setup_zh-cn.cab",
      "Member": "fil11ae4d3ec9053b954aabcbab3cb74bf5",
      "Size": 123838,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-Setup-ASZ_zh-cn.cab",
      "Member": "filbe8b7fbd9ca8fc1bdc960601470308f1",
      "Size": 46332,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-Setup-Client_zh-cn.cab",
      "Member": "fil164b390de15e1ea37562fdce611b9581",
      "Size": 46108,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-Setup-Server_zh-cn.cab",
      "Member": "fil58bc5f90d6b8b5c96503db7012054139",
      "Size": 46648,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-SRT_zh-cn.cab",
      "Member": "fila82f86d6febf3f03ef0de2cca2a064b5",
      "Size": 172076,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-StorageWMI_zh-cn.cab",
      "Member": "filbbeb0c9e1ddb1a50931b56903cd2fb28",
      "Size": 133217,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-WDS-Tools_zh-cn.cab",
      "Member": "fil8f29b264f64eaacb53d830a8d3682490",
      "Size": 31495,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-WinReCfg_zh-cn.cab",
      "Member": "fil9ad9846e9567f646489b780805c698e8",
      "Size": 17367,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-cn/WinPE-WMI_zh-cn.cab",
      "Member": "fil58ffed2b438c32d41f0802481d2b144f",
      "Size": 502053,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/lp.cab",
      "Member": "fil6db96ba6b10eae20358bd57933cf7f46",
      "Size": 3575260,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-DismCmdlets_it-it.cab",
      "Member": "fil943dad7cf8d9fa0afde927edc872b9e2",
      "Size": 12834,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-Dot3Svc_it-it.cab",
      "Member": "fil765db07d86c69342e711de3dde98908c",
      "Size": 87848,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-EnhancedStorage_it-it.cab",
      "Member": "fil395dfb6249acbf984c017b35e6ff6f07",
      "Size": 12196,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-HTA_it-it.cab",
      "Member": "filfcbb0173a1894cad087fba23be5ccf9b",
      "Size": 505145,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-LegacySetup_it-it.cab",
      "Member": "filcddd4fd121368f0a126b8a9bda3c10f3",
      "Size": 54102,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-MDAC_it-it.cab",
      "Member": "fil23e84737aad9187ab5a97a4d36339f2b",
      "Size": 430324,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-NetFx_it-it.cab",
      "Member": "fil2587a893f040f15f6b0c618f17ecb3d2",
      "Size": 4009992,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-PmemCmdlets_it-it.cab",
      "Member": "fila2143eb6fac20460a8c814f7390c31aa",
      "Size": 11209,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-PowerShell_it-it.cab",
      "Member": "fil108171ccfcef58149444a6dfe857bc2d",
      "Size": 185696,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-PPPoE_it-it.cab",
      "Member": "filc9c37265d92b6c7a0077067a2c472977",
      "Size": 32878,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-Rejuv_it-it.cab",
      "Member": "fila7c305b7b862ef90d9b611078c9f08f4",
      "Size": 18545,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-RNDIS_it-it.cab",
      "Member": "fild49c7a4c6bf47482bd10482c9b2bbb8a",
      "Size": 9224,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-Scripting_it-it.cab",
      "Member": "fil2921a6c81533ab49c56a09fdddaa93e0",
      "Size": 32149,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-SecureStartup_it-it.cab",
      "Member": "filf2d98a5f074ca7d8711659fab9b5189c",
      "Size": 35154,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-Setup_it-it.cab",
      "Member": "fild7f279de7780bea92f06f2c9ebf3b427",
      "Size": 103928,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-Setup-ASZ_it-it.cab",
      "Member": "fild247e63a980c551c9e2d15d3807b9d96",
      "Size": 48204,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-Setup-Client_it-it.cab",
      "Member": "file8bff7df9b21e935dd67874654981177",
      "Size": 47932,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-Setup-Server_it-it.cab",
      "Member": "fil8170ee8ebba3a08735e20151dcc98f1b",
      "Size": 48426,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-SRT_it-it.cab",
      "Member": "fil73772472dd7d9b991a6060d8d01c6b64",
      "Size": 148578,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-StorageWMI_it-it.cab",
      "Member": "fil65b7e67cba1c2d0ac34a0818b3a83b54",
      "Size": 126545,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-WDS-Tools_it-it.cab",
      "Member": "filc2c803a0fc9c92514a43c9fa16c36abe",
      "Size": 28375,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-WinReCfg_it-it.cab",
      "Member": "fil0ab895bb494c6ca029a4610deaeec3ad",
      "Size": 12611,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "it-it/WinPE-WMI_it-it.cab",
      "Member": "fil244c1234108a18bdb79d1ea3bad0c721",
      "Size": 366525,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/lp.cab",
      "Member": "fil25959a54ff0d7d1d75bf693da5853a25",
      "Size": 3525658,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-DismCmdlets_sk-sk.cab",
      "Member": "fil24fa49046c008f50611cc41c700d4244",
      "Size": 12462,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-Dot3Svc_sk-sk.cab",
      "Member": "fil89975c61da4429e16b81233c57fcb771",
      "Size": 83804,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-EnhancedStorage_sk-sk.cab",
      "Member": "fil59859c6ec89664e188963d4a672c61d0",
      "Size": 12296,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-HTA_sk-sk.cab",
      "Member": "fil48c8d6c470495e3e3b173c181d2b6be6",
      "Size": 509295,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-LegacySetup_sk-sk.cab",
      "Member": "fil74ab85b5f510f44929ab11957e57851a",
      "Size": 52044,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-MDAC_sk-sk.cab",
      "Member": "file36c95b94251ac9b23f8af995ed6f507",
      "Size": 425732,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-NetFx_sk-sk.cab",
      "Member": "fil487066539aad6ad9cc4c453c814b43a5",
      "Size": 125910,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-PmemCmdlets_sk-sk.cab",
      "Member": "filff842d9502fd5eab617a3322992a1aa1",
      "Size": 11003,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-PowerShell_sk-sk.cab",
      "Member": "fil7e2aa35169d039700419e2552e2d58f9",
      "Size": 179868,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-PPPoE_sk-sk.cab",
      "Member": "fil8cde1a2045687752acb7458fae7743e7",
      "Size": 33504,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-Rejuv_sk-sk.cab",
      "Member": "filb40cca80e2405b3bb929cf0e26b3fccb",
      "Size": 18081,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-RNDIS_sk-sk.cab",
      "Member": "fil2ee243ad774d2762dcc0e15d9bfd6c00",
      "Size": 9202,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-Scripting_sk-sk.cab",
      "Member": "file043fc68befdc9dd8c7e9e3688870113",
      "Size": 33811,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-SecureStartup_sk-sk.cab",
      "Member": "fil3f940fc3ebb00cba8f1886d7b0ff63b6",
      "Size": 34960,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-Setup_sk-sk.cab",
      "Member": "fil194e679c3f4b732ef9d5d76a163bc8a0",
      "Size": 106408,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-Setup-ASZ_sk-sk.cab",
      "Member": "filb2e5eae149798dfb080d26d38e54af51",
      "Size": 47070,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-Setup-Client_sk-sk.cab",
      "Member": "filb9b316baacc6cf19ae64f2eacf02b312",
      "Size": 48500,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-Setup-Server_sk-sk.cab",
      "Member": "fil1716326c0002be414cb434660c2f6678",
      "Size": 47326,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-SRT_sk-sk.cab",
      "Member": "filacc182b733bd815c3653ab1b7709a717",
      "Size": 151314,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-StorageWMI_sk-sk.cab",
      "Member": "fil174d17339c3f93b6b340f63eb6a30b7c",
      "Size": 122819,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-WDS-Tools_sk-sk.cab",
      "Member": "fil9528f7ed1bdcac0421eb3fcc1737809f",
      "Size": 28423,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-WinReCfg_sk-sk.cab",
      "Member": "fil0ae5f55bb349515e270559a3b119d46d",
      "Size": 12241,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sk-sk/WinPE-WMI_sk-sk.cab",
      "Member": "fil9e611934602a8bf88cba335764ce5957",
      "Size": 347709,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/lp.cab",
      "Member": "fil732cda039a715582a9a21ec85ec62127",
      "Size": 3520418,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-DismCmdlets_lt-lt.cab",
      "Member": "filc63c723dc575c183896f772a7c5b55ae",
      "Size": 12472,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-Dot3Svc_lt-lt.cab",
      "Member": "filb3abd2811a3fc02e8c9148d56e30ac34",
      "Size": 86486,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-EnhancedStorage_lt-lt.cab",
      "Member": "fil2b93d6331760211003b30d6a05cd4f1f",
      "Size": 12150,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-HTA_lt-lt.cab",
      "Member": "fileed4affb35a4d8d8191e8a9685a212f4",
      "Size": 510205,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-LegacySetup_lt-lt.cab",
      "Member": "fil114e8646f04390219e856b34d6258c13",
      "Size": 51780,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-MDAC_lt-lt.cab",
      "Member": "fil0baa31fb69d74d3c8b9471e97be151a3",
      "Size": 425980,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-NetFx_lt-lt.cab",
      "Member": "filfc928e3d902085fdf81a4d90e4b66e3d",
      "Size": 126602,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-PmemCmdlets_lt-lt.cab",
      "Member": "filf93594485f64c8b45bae001f908e008f",
      "Size": 10995,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-PowerShell_lt-lt.cab",
      "Member": "file09ac05a1bd195c259f296acd24d6cf7",
      "Size": 180216,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-PPPoE_lt-lt.cab",
      "Member": "fil8b38561f59d1ea7be9c92cb3131bb078",
      "Size": 33376,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-Rejuv_lt-lt.cab",
      "Member": "filaacbdf99e8519e7a279b80ee5091919c",
      "Size": 18031,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-RNDIS_lt-lt.cab",
      "Member": "filf611eb3b0b4a714b1105ac933d7b81e9",
      "Size": 9330,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-Scripting_lt-lt.cab",
      "Member": "fil15079bf176ba461ff91b15e73459161e",
      "Size": 33131,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-SecureStartup_lt-lt.cab",
      "Member": "filfb8cf32830e5330e915fc6680663017c",
      "Size": 35800,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-Setup_lt-lt.cab",
      "Member": "fil213e8bd5291c14a98d676881bcae6245",
      "Size": 106238,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-Setup-ASZ_lt-lt.cab",
      "Member": "file01b2cd8efd27f74d7bb6a6373fa0720",
      "Size": 46924,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-Setup-Client_lt-lt.cab",
      "Member": "fil6fd7a20fca3fabf46c124db98de2422f",
      "Size": 48074,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-Setup-Server_lt-lt.cab",
      "Member": "filf43e5c3fd88e5c44e97f8ac9bf23d721",
      "Size": 48284,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-SRT_lt-lt.cab",
      "Member": "fil40881f614d6c9436b3e804af9f5e5147",
      "Size": 153708,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-StorageWMI_lt-lt.cab",
      "Member": "filc16cdb91a76b8f86dc9570870681ccf4",
      "Size": 124139,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-WDS-Tools_lt-lt.cab",
      "Member": "fil2dc170788adf9f4b00173813d0bfd2da",
      "Size": 27789,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-WinReCfg_lt-lt.cab",
      "Member": "fil81b49f1a35485facc2701465ffd29720",
      "Size": 12367,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "lt-lt/WinPE-WMI_lt-lt.cab",
      "Member": "fil8702292d159c384473212c49bec3e3d1",
      "Size": 353057,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/lp.cab",
      "Member": "fil0bbd8e8942a2b1d4e72491805a9b6bf3",
      "Size": 3605304,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-DismCmdlets_fi-fi.cab",
      "Member": "filfc183d13a1ddb52d7a1556d3e0586efd",
      "Size": 12592,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-Dot3Svc_fi-fi.cab",
      "Member": "filf1c738c92c3e64138035302e9f37f22a",
      "Size": 86862,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-EnhancedStorage_fi-fi.cab",
      "Member": "fil9b9b3fe20bd4357210619a2ef4416030",
      "Size": 12356,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-HTA_fi-fi.cab",
      "Member": "fil14df669313468070b52fd4231cde29f0",
      "Size": 505529,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-LegacySetup_fi-fi.cab",
      "Member": "fil131df5d8b6bdcfca4057b3b6a5972fd0",
      "Size": 50090,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-MDAC_fi-fi.cab",
      "Member": "fileabc2d21831f615ad2f3b59c0e6b62cb",
      "Size": 433286,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-NetFx_fi-fi.cab",
      "Member": "fil896ade753c1003c8dfc72e275e717406",
      "Size": 4052798,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-PmemCmdlets_fi-fi.cab",
      "Member": "filbce5cf39a29598fbfca313e9d2cbcb05",
      "Size": 11005,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-PowerShell_fi-fi.cab",
      "Member": "filf92cf365d5268a9a1fa415d9e4623c5c",
      "Size": 180524,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-PPPoE_fi-fi.cab",
      "Member": "filc9aa6be9689b11a6f33e08de898c5e3f",
      "Size": 31978,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-Rejuv_fi-fi.cab",
      "Member": "fil286402bd7d2d138c85336e11935b5ef7",
      "Size": 18435,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-RNDIS_fi-fi.cab",
      "Member": "fil24cc79ab4c112f6b9b514accda1b00f5",
      "Size": 9218,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-Scripting_fi-fi.cab",
      "Member": "fil28c2d3f267a2cfd8f6411b5d7ae969ca",
      "Size": 33791,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-SecureStartup_fi-fi.cab",
      "Member": "fil37e4f6a6cce8bbf56b75ec98a0566ad6",
      "Size": 35710,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-Setup_fi-fi.cab",
      "Member": "filfbcfbf33721e46c5d16e6f19fbd8e1a7",
      "Size": 104308,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-Setup-ASZ_fi-fi.cab",
      "Member": "fil2aa3783724c41ac6814d21a6b7d3ed9c",
      "Size": 48028,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-Setup-Client_fi-fi.cab",
      "Member": "filab888a0c13907e04200544be975b9dd8",
      "Size": 47618,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-Setup-Server_fi-fi.cab",
      "Member": "fil2b96142dae7e5feffdbe98cbe4f8029e",
      "Size": 48276,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-SRT_fi-fi.cab",
      "Member": "fil9eb08ab2428769d91ce922cea1e644dc",
      "Size": 153688,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-StorageWMI_fi-fi.cab",
      "Member": "fil7fd59f58195c47efeb5c6f32300e0eb0",
      "Size": 125775,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-WDS-Tools_fi-fi.cab",
      "Member": "fil5becb0312af3a0c7afab6caf333137b7",
      "Size": 26869,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-WinReCfg_fi-fi.cab",
      "Member": "filb208dc7d4cdf1f5ae2e00dfff3cf6bc7",
      "Size": 12233,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "fi-fi/WinPE-WMI_fi-fi.cab",
      "Member": "file1b979dd22ba2b1d254b011d29098df7",
      "Size": 356293,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/lp.cab",
      "Member": "fil7bc4be13ea800870c26fe31f8c79c60a",
      "Size": 3505214,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-DismCmdlets_et-ee.cab",
      "Member": "fil837bef44d96227a50d27fd845c047a12",
      "Size": 12596,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-Dot3Svc_et-ee.cab",
      "Member": "fil3e90076c63509d0998ffe90951207d20",
      "Size": 84776,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-EnhancedStorage_et-ee.cab",
      "Member": "fil87420a99fd45c8f4e5b7622c95eee7c2",
      "Size": 12152,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-HTA_et-ee.cab",
      "Member": "fil790b6b23e7fcb5c955bdd79d6f62092a",
      "Size": 507191,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-LegacySetup_et-ee.cab",
      "Member": "fil79cea3895e607d3e0db5d932fed99585",
      "Size": 51208,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-MDAC_et-ee.cab",
      "Member": "filf4b8f7ff7b7953b99fa66c5f1fd56d2c",
      "Size": 424090,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-NetFx_et-ee.cab",
      "Member": "fil8357c9bc56fb8f2f498a87926fc736d9",
      "Size": 128456,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-PmemCmdlets_et-ee.cab",
      "Member": "fil9c6ff664ce963e9954422528d58ba70d",
      "Size": 10993,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-PowerShell_et-ee.cab",
      "Member": "filbad3a362db2537b980f70d82891d0d6c",
      "Size": 180038,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-PPPoE_et-ee.cab",
      "Member": "fil60a06be874319464ff85990b57410383",
      "Size": 32192,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-Rejuv_et-ee.cab",
      "Member": "fil0f74df5739ec0f8cdd4934df4fd24fa7",
      "Size": 16775,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-RNDIS_et-ee.cab",
      "Member": "filfe3fedc0d9f8ad64a0004b3bbacc5ccd",
      "Size": 9198,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-Scripting_et-ee.cab",
      "Member": "fil36c8513a40d8ed8fd93933614f522fc2",
      "Size": 33093,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-SecureStartup_et-ee.cab",
      "Member": "fil0bcb650ddf14cd430515258909324227",
      "Size": 34994,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-Setup_et-ee.cab",
      "Member": "filf4d3cbee210ec5c6796dbb7247e29925",
      "Size": 102516,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-Setup-ASZ_et-ee.cab",
      "Member": "fil1b02ac3451075c6fdbf5fd756400dd78",
      "Size": 47086,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-Setup-Client_et-ee.cab",
      "Member": "fil296370a6b9b6b60817bdd59f152dc887",
      "Size": 48276,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-Setup-Server_et-ee.cab",
      "Member": "fil3db7727033a3bbc16c89a2f978cf846f",
      "Size": 48282,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-SRT_et-ee.cab",
      "Member": "fil4a87fc3422f4aad199a51eedf9e70ee3",
      "Size": 151312,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-StorageWMI_et-ee.cab",
      "Member": "filcd492c082cdc5886d410e89660e06a9a",
      "Size": 123767,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-WDS-Tools_et-ee.cab",
      "Member": "filbc890a99276315c264b2732408ab3160",
      "Size": 27541,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-WinReCfg_et-ee.cab",
      "Member": "filf916228e732a5cc285eda5a7abeebbee",
      "Size": 12353,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "et-ee/WinPE-WMI_et-ee.cab",
      "Member": "fil7929163c4261370165dd08f0e24a59f1",
      "Size": 349265,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/lp.cab",
      "Member": "fild1fa85c5620d81036948d4a2f5831e90",
      "Size": 3565312,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-DismCmdlets_nb-no.cab",
      "Member": "filc22f5be914802045d3c77fe890e577e1",
      "Size": 12586,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-Dot3Svc_nb-no.cab",
      "Member": "fil989e3352385991f54a0459dff390d0ed",
      "Size": 83518,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-EnhancedStorage_nb-no.cab",
      "Member": "filbcdaf87e3038eeb1afd750d9c90bd3a0",
      "Size": 12190,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-HTA_nb-no.cab",
      "Member": "fil263779f1924a6bc6a2af1059145d8269",
      "Size": 501037,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-LegacySetup_nb-no.cab",
      "Member": "fil704bf8680861696b55f6a257687048a9",
      "Size": 50088,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-MDAC_nb-no.cab",
      "Member": "fil2d88e2d9b21a0eb7cb79b378bdbd998e",
      "Size": 427772,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-NetFx_nb-no.cab",
      "Member": "fil0d7802d6e4f4095165bebf1532bc9dd6",
      "Size": 3977302,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-PmemCmdlets_nb-no.cab",
      "Member": "filf7cec3381685fef9851dfbf43d5d008f",
      "Size": 11143,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-PowerShell_nb-no.cab",
      "Member": "fil193ba464860677b9516be74bafa9b961",
      "Size": 180428,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-PPPoE_nb-no.cab",
      "Member": "fila6503525536a251e2df0d77170aa02fd",
      "Size": 32312,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-Rejuv_nb-no.cab",
      "Member": "fil70c284127737493d192b7b21081b303d",
      "Size": 18309,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-RNDIS_nb-no.cab",
      "Member": "fil2e4399c071c706d26dca085eaae5ea0e",
      "Size": 9332,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-Scripting_nb-no.cab",
      "Member": "fil72b43d8b300accb79a23a7b968fb7246",
      "Size": 31599,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-SecureStartup_nb-no.cab",
      "Member": "fil0c0507fc221d9971883b8938b9a1ce4f",
      "Size": 35574,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-Setup_nb-no.cab",
      "Member": "fil28ae971901912d6f31d4d006c29d0cb5",
      "Size": 104352,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-Setup-ASZ_nb-no.cab",
      "Member": "fil461b39ce0904b6ada21c4e54e51e5641",
      "Size": 47058,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-Setup-Client_nb-no.cab",
      "Member": "fil6e8c35fa50b66b34a8755afe19b98b79",
      "Size": 48514,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-Setup-Server_nb-no.cab",
      "Member": "fil3ca00794cfdaecad9f478d02de8207a4",
      "Size": 47684,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-SRT_nb-no.cab",
      "Member": "fil292a5607b9b310002e7238332475bb82",
      "Size": 148318,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-StorageWMI_nb-no.cab",
      "Member": "filf03180e533be4eafd81f165e6576f6c2",
      "Size": 124975,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-WDS-Tools_nb-no.cab",
      "Member": "fil8981210e4878536acf64a875c002345a",
      "Size": 28951,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-WinReCfg_nb-no.cab",
      "Member": "fil59b738b97693d48a69e29aa86d9e7f3b",
      "Size": 12229,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nb-no/WinPE-WMI_nb-no.cab",
      "Member": "fildc0b4df5d465ce34b1052b464b4e7b02",
      "Size": 350831,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/lp.cab",
      "Member": "fil9db274dc2cd1aada7dbec11b00bdb196",
      "Size": 3619440,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-DismCmdlets_pt-pt.cab",
      "Member": "fil2d115c0fec62bb609a15a480db48ba93",
      "Size": 12600,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-Dot3Svc_pt-pt.cab",
      "Member": "fil1662394afacaa5d0f55f9e534e15a9c7",
      "Size": 85406,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-EnhancedStorage_pt-pt.cab",
      "Member": "fila2cfed8880e9d7250f5dc95f381d27fb",
      "Size": 12378,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-HTA_pt-pt.cab",
      "Member": "fil7932fc15d3e350f4c82cbf2dfc8f567c",
      "Size": 505627,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-LegacySetup_pt-pt.cab",
      "Member": "fil17d42d4646db0d7f8f3ac5ffbbe547f6",
      "Size": 52630,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-MDAC_pt-pt.cab",
      "Member": "fila5b727e452eab93aabde4c5a8c8c461e",
      "Size": 272416,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-NetFx_pt-pt.cab",
      "Member": "fil26762a3b72fbaef5071cf2c1bc6674b6",
      "Size": 4026496,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-PmemCmdlets_pt-pt.cab",
      "Member": "fil9238aaac9571611891d27928a78521d7",
      "Size": 11145,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-PowerShell_pt-pt.cab",
      "Member": "fil2d5e2190ee02070dbbb5443948958b05",
      "Size": 180404,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-PPPoE_pt-pt.cab",
      "Member": "fil0c6801d069ed854ee91a792afc1cc6f7",
      "Size": 30980,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-Rejuv_pt-pt.cab",
      "Member": "fila3fdc7072b13d9652c6138b0cb72914a",
      "Size": 17077,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-RNDIS_pt-pt.cab",
      "Member": "fil4ef100cd520eb24fc2794f27ebdc5136",
      "Size": 9350,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-Scripting_pt-pt.cab",
      "Member": "fil9e3dc88c2fb15d3159a9ad8317061010",
      "Size": 32087,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-SecureStartup_pt-pt.cab",
      "Member": "filecc84732876fe3c432bcf3adc1a2871e",
      "Size": 35656,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-Setup_pt-pt.cab",
      "Member": "filf47d539a8631c5a4aba8366b7818ef8d",
      "Size": 104826,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-Setup-ASZ_pt-pt.cab",
      "Member": "fila6030fc9b71d5db1f35f940d47074921",
      "Size": 48648,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-Setup-Client_pt-pt.cab",
      "Member": "fil728a19c4cd9b120fec4a6f834c6550b5",
      "Size": 48490,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-Setup-Server_pt-pt.cab",
      "Member": "fil2320d8c5adf00c0ceac090037bc0a040",
      "Size": 48518,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-SRT_pt-pt.cab",
      "Member": "filbc0cea25312cec4fc6acc48f24647df6",
      "Size": 152882,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-StorageWMI_pt-pt.cab",
      "Member": "fil33babb054ff0bd6eaeb8d0553ed6fa4a",
      "Size": 124823,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-WDS-Tools_pt-pt.cab",
      "Member": "file452da6f1bf746edeb80e5bcc4da5294",
      "Size": 29307,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-WinReCfg_pt-pt.cab",
      "Member": "fil722a170d26994eec36e5f094118a68d6",
      "Size": 12357,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "pt-pt/WinPE-WMI_pt-pt.cab",
      "Member": "filbb13606e20ccd1d7158e41740a824d38",
      "Size": 356639,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/lp.cab",
      "Member": "fil790a46950bdb4f2bdf1a6bad34d193ea",
      "Size": 4262934,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-DismCmdlets_ja-jp.cab",
      "Member": "fil7e3ba958a69aae27dc32e9b4bc97086b",
      "Size": 12830,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-Dot3Svc_ja-jp.cab",
      "Member": "fil81732c86bb31d5081d4085cebd3826a6",
      "Size": 121655,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-EnhancedStorage_ja-jp.cab",
      "Member": "filc9dc209e443f8fa743a140e635996428",
      "Size": 12356,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-HTA_ja-jp.cab",
      "Member": "filf460d01adfc0951eaaa87f390e9e0e29",
      "Size": 498295,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-LegacySetup_ja-jp.cab",
      "Member": "filcec3b3eb2401afd7035d05abb4a1f421",
      "Size": 49088,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-MDAC_ja-jp.cab",
      "Member": "filfd7cb8b7ef615d31fdd0b8d762d82174",
      "Size": 446688,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-NetFx_ja-jp.cab",
      "Member": "filc732514433097072edb1d227c328e084",
      "Size": 3999970,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-PmemCmdlets_ja-jp.cab",
      "Member": "fil0c898df8de5b1cdc31771bacaac87b73",
      "Size": 11379,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-PowerShell_ja-jp.cab",
      "Member": "fil867b92f1bcff3e625e24edde39d847fb",
      "Size": 186734,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-PPPoE_ja-jp.cab",
      "Member": "file01a72b2e830c084764bf6776ef2ff69",
      "Size": 30718,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-Rejuv_ja-jp.cab",
      "Member": "fil6add77a1893a490fbbaea6d4201ab0f2",
      "Size": 18285,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-RNDIS_ja-jp.cab",
      "Member": "fil16a3258b156dbae20328710703a4e79e",
      "Size": 9190,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-Scripting_ja-jp.cab",
      "Member": "fil1a0c66a8d2d6da10259f0b815320e836",
      "Size": 32397,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-SecureStartup_ja-jp.cab",
      "Member": "fil3eb98ddf8b13258651e52cb5aea252a6",
      "Size": 51586,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-Setup_ja-jp.cab",
      "Member": "fil6f796deba3a5f8ea1fbda171faf882d4",
      "Size": 126638,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-Setup-ASZ_ja-jp.cab",
      "Member": "filb7c4f0dafa9657c286843a839eaa9080",
      "Size": 46612,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-Setup-Client_ja-jp.cab",
      "Member": "fil2419846a87b1118ed894e541a5cca529",
      "Size": 46774,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-Setup-Server_ja-jp.cab",
      "Member": "fil44d05d277fc9f9a2bfcad8a84a499f70",
      "Size": 47028,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-SRT_ja-jp.cab",
      "Member": "fil5fc45b881ce886f0b0d54cd2c668b8c8",
      "Size": 174042,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-StorageWMI_ja-jp.cab",
      "Member": "fil463f5f329725e4d963d302dfc57bf6a2",
      "Size": 134845,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-WDS-Tools_ja-jp.cab",
      "Member": "file7d3ab122819c642a224df92827c9b04",
      "Size": 33749,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-WinReCfg_ja-jp.cab",
      "Member": "fil98decf6f6c54542a36108276adde5bad",
      "Size": 17733,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ja-jp/WinPE-WMI_ja-jp.cab",
      "Member": "fil1b6f739d2af5fdd1a4ce0aa5ae86e608",
      "Size": 511381,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/lp.cab",
      "Member": "fil4219ed8711ae77371df5445f1a434849",
      "Size": 3653710,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-DismCmdlets_de-de.cab",
      "Member": "fil44abe87572e41d02d9fb866e95591f61",
      "Size": 12854,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-Dot3Svc_de-de.cab",
      "Member": "fila9c43efc712b2fca588f3c701ef2ba23",
      "Size": 92566,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-EnhancedStorage_de-de.cab",
      "Member": "fild916cb402fb531d1cce605de282df48e",
      "Size": 12384,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-HTA_de-de.cab",
      "Member": "filbe9f3a4bf5e4e195d77b04fd8f45686f",
      "Size": 507867,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-LegacySetup_de-de.cab",
      "Member": "filca2496c345cdee9cb806f71002f3a520",
      "Size": 52788,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-MDAC_de-de.cab",
      "Member": "fil9a8bd034c602dd504f7172dca155d383",
      "Size": 431596,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-NetFx_de-de.cab",
      "Member": "fil2ceb2ba51f9a1efde14714502c30fe48",
      "Size": 4086112,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-PmemCmdlets_de-de.cab",
      "Member": "filab86a34d581b863de6fb4eecbfc96ce0",
      "Size": 11503,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-PowerShell_de-de.cab",
      "Member": "filf78791f560a715ac1b14d124bfaa8496",
      "Size": 194692,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-PPPoE_de-de.cab",
      "Member": "fil4d5b1dc01590d4b3218f28fa46e3a075",
      "Size": 32456,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-Rejuv_de-de.cab",
      "Member": "fil5c4680961905536c1991e2913b86da10",
      "Size": 16437,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-RNDIS_de-de.cab",
      "Member": "fil2eb7444c7ed2e08cf5a370bd4f7444a7",
      "Size": 9210,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-Scripting_de-de.cab",
      "Member": "fild4907b3f62801050c5d02c0293f70176",
      "Size": 34429,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-SecureStartup_de-de.cab",
      "Member": "fil29f54bcc952c4eaf57488d27e661861f",
      "Size": 38324,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-Setup_de-de.cab",
      "Member": "fil107ce0ee69314a29b341ea66398a0bba",
      "Size": 108054,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-Setup-ASZ_de-de.cab",
      "Member": "fila1c00bf9ccc6d66e0d0bcc95becdd24e",
      "Size": 49130,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-Setup-Client_de-de.cab",
      "Member": "filc6ed2cc6ae1d91d287716f3e6aea28a5",
      "Size": 48664,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-Setup-Server_de-de.cab",
      "Member": "fila8587b9b034a133a89efb3e3169496df",
      "Size": 48526,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-SRT_de-de.cab",
      "Member": "fil89e281f133437e5b46ca58d944edd70a",
      "Size": 160448,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-StorageWMI_de-de.cab",
      "Member": "fil9cc7cc55f689f7fd8a3abc616a01fb6e",
      "Size": 125839,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-WDS-Tools_de-de.cab",
      "Member": "fil14c6140848852a551da46b248e509672",
      "Size": 30039,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-WinReCfg_de-de.cab",
      "Member": "fil374e6d5ece16c742954ff5cf206c8f86",
      "Size": 12883,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "de-de/WinPE-WMI_de-de.cab",
      "Member": "fil0cfe866c4cb0f389ad343c7a30ccadc3",
      "Size": 369125,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/lp.cab",
      "Member": "fild2f488d9d0254a496d05040fce7b51a8",
      "Size": 3627938,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-DismCmdlets_nl-nl.cab",
      "Member": "file356922ce0789aa90479452b14221757",
      "Size": 12592,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-Dot3Svc_nl-nl.cab",
      "Member": "filb2a2d2206bc63370a7f243804a9b4b50",
      "Size": 85476,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-EnhancedStorage_nl-nl.cab",
      "Member": "fil9b46b9b0cfa6f5f49e811cf4f93a53bc",
      "Size": 12366,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-HTA_nl-nl.cab",
      "Member": "fila342e8173ed06a2104653a31972cc13a",
      "Size": 505791,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-LegacySetup_nl-nl.cab",
      "Member": "fil0d57a47201d54fb8a294295d33151e4b",
      "Size": 48318,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-MDAC_nl-nl.cab",
      "Member": "filf3f15d2f06bc811b32b53ef824a103de",
      "Size": 432594,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-NetFx_nl-nl.cab",
      "Member": "fil68c9642eec5d6adae32c0a1ba36400f0",
      "Size": 4039402,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-PmemCmdlets_nl-nl.cab",
      "Member": "fil9303d6f51f200b1a3d43c3cc534de335",
      "Size": 11007,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-PowerShell_nl-nl.cab",
      "Member": "filde875c418a345a954fd07a45cb9d613d",
      "Size": 180514,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-PPPoE_nl-nl.cab",
      "Member": "filad474f2c4afaf36ef42c80095506df31",
      "Size": 33240,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-Rejuv_nl-nl.cab",
      "Member": "fil1167b3d4235fe5985133d302b07d3f31",
      "Size": 18535,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-RNDIS_nl-nl.cab",
      "Member": "fila5f420ae96d1ffa6351d9bb41c751e1f",
      "Size": 9336,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-Scripting_nl-nl.cab",
      "Member": "fil193af151bdad35a293a8af4c3b0c2fa3",
      "Size": 33575,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-SecureStartup_nl-nl.cab",
      "Member": "filb5e072b8013f9dbcb1db6afbad49d6ce",
      "Size": 35026,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-Setup_nl-nl.cab",
      "Member": "fil57eea2e64ead9650b1dcf6b407aa3001",
      "Size": 103642,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-Setup-ASZ_nl-nl.cab",
      "Member": "fil62e7c963c35af3389bbbcaf2f44303ac",
      "Size": 48286,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-Setup-Client_nl-nl.cab",
      "Member": "fil1464a183c157cf406301a698248a8c67",
      "Size": 47832,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-Setup-Server_nl-nl.cab",
      "Member": "fila1bff7e03fca5deeed328b0b464240e4",
      "Size": 48710,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-SRT_nl-nl.cab",
      "Member": "fil1909cab04706fab7a08ff53fc9c6a27f",
      "Size": 150098,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-StorageWMI_nl-nl.cab",
      "Member": "fil3c95582f269fa26bf5defc7335f2a4ca",
      "Size": 125615,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-WDS-Tools_nl-nl.cab",
      "Member": "filcfbcf64d90f1c0c5df2d7940e99ba496",
      "Size": 29201,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-WinReCfg_nl-nl.cab",
      "Member": "fil8d6098f378894432a07d131d435e4f52",
      "Size": 12221,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "nl-nl/WinPE-WMI_nl-nl.cab",
      "Member": "filf869770aca792e8c5611868f9770d2cd",
      "Size": 352141,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/lp.cab",
      "Member": "filbde5e6d9603d1d2e77b82e977d2fc184",
      "Size": 3595542,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-DismCmdlets_es-mx.cab",
      "Member": "fil7d2f7d28e7ece8610a52f4e527a834f7",
      "Size": 12676,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-Dot3Svc_es-mx.cab",
      "Member": "fila6638e14bcf31c98394e5b8f69485f0f",
      "Size": 87566,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-EnhancedStorage_es-mx.cab",
      "Member": "file912bc92f896c2cc0c0aff50d61bab10",
      "Size": 12356,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-HTA_es-mx.cab",
      "Member": "fil240a71f96d7de924d7acde8080030b4b",
      "Size": 503205,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-LegacySetup_es-mx.cab",
      "Member": "fil5792af2d226aebc3b692a30068b0fbc2",
      "Size": 51946,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-MDAC_es-mx.cab",
      "Member": "fil40257f26d36d028f61b8ffaf0eac3ef9",
      "Size": 430702,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-NetFx_es-mx.cab",
      "Member": "fil0f8c79d7ce79bc8538f40960e7fcadf0",
      "Size": 4004104,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-PmemCmdlets_es-mx.cab",
      "Member": "fil6033ccc7bb6459ea4a92166114175f95",
      "Size": 11317,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-PowerShell_es-mx.cab",
      "Member": "fil485adedbf56bddd99c368b25e5bf48eb",
      "Size": 188364,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-PPPoE_es-mx.cab",
      "Member": "file981df080a2c7e2c77c81d6640061178",
      "Size": 32592,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-Rejuv_es-mx.cab",
      "Member": "fil4e509223c43350fb9fb0871e6fd248c8",
      "Size": 17997,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-RNDIS_es-mx.cab",
      "Member": "fila95751fe9df1399034cec15a34eab83b",
      "Size": 9348,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-Scripting_es-mx.cab",
      "Member": "fil5de95925ca92b91b1736402610dd129a",
      "Size": 37847,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-SecureStartup_es-mx.cab",
      "Member": "fileaf8b34991cde85331278e713cce8fa0",
      "Size": 36994,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-Setup_es-mx.cab",
      "Member": "filc7854e0f963917114e1eb7d8e082bea2",
      "Size": 106598,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-Setup-ASZ_es-mx.cab",
      "Member": "filac09b2ffd9f84f06436455290e012a06",
      "Size": 48270,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-Setup-Client_es-mx.cab",
      "Member": "fil20043620856459930acd3dcdb24b2d7e",
      "Size": 48904,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-Setup-Server_es-mx.cab",
      "Member": "file766fa4fecfb00aae3b7afb8cc4e0215",
      "Size": 48654,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-SRT_es-mx.cab",
      "Member": "fil0e6222b65eecd15af5b37dee048a4a75",
      "Size": 154746,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-StorageWMI_es-mx.cab",
      "Member": "fil886a0c1f650d780e67da43b1d0bea7e0",
      "Size": 124747,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-WDS-Tools_es-mx.cab",
      "Member": "fil9561262c5d4bca0be516667dd59db03f",
      "Size": 29307,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-WinReCfg_es-mx.cab",
      "Member": "fil28cdef784f54c0167e6b846fabf0bb6c",
      "Size": 12791,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-mx/WinPE-WMI_es-mx.cab",
      "Member": "fil8f4b6de8f1d54643551ba355d2125dbd",
      "Size": 359467,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/lp.cab",
      "Member": "fil482a676bc6d87cc561cdb51e78debf03",
      "Size": 3662117,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-DismCmdlets_he-il.cab",
      "Member": "fil97a8213d42b32969b334f36070141093",
      "Size": 12466,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-Dot3Svc_he-il.cab",
      "Member": "fil7a208285e8b59c237a2b7f607c3e18b6",
      "Size": 89242,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-EnhancedStorage_he-il.cab",
      "Member": "fila6db5a95cf14162ce1ceebd2d5f365fb",
      "Size": 12158,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-HTA_he-il.cab",
      "Member": "fil33dafc4f067a9a5c5081ec6d139e6b0e",
      "Size": 505089,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-LegacySetup_he-il.cab",
      "Member": "fil2e92a80344d00bfa0047afbd3de6e3f9",
      "Size": 51266,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-MDAC_he-il.cab",
      "Member": "fil2a732cbf7478a21893a1441aebeeae8d",
      "Size": 427062,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-NetFx_he-il.cab",
      "Member": "filbebf8ea7d95825f07e1aa888c1705217",
      "Size": 4000738,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-PmemCmdlets_he-il.cab",
      "Member": "fil729d4df28d27182d9cab2e389283a791",
      "Size": 11141,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-PowerShell_he-il.cab",
      "Member": "fil70a1085b9090f2a2cf4fe23dc10bdf19",
      "Size": 180056,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-PPPoE_he-il.cab",
      "Member": "filc8286ac4857d588b09556a75275d7bd5",
      "Size": 30930,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-Rejuv_he-il.cab",
      "Member": "fil2539fd315656d1ace82584fbcfc2467d",
      "Size": 18415,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-RNDIS_he-il.cab",
      "Member": "fild494d946a2f3f731c9e0120669be3d26",
      "Size": 9330,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-Scripting_he-il.cab",
      "Member": "filbf4a58b4999f3735546257cfb84f14f0",
      "Size": 33545,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-SecureStartup_he-il.cab",
      "Member": "fil0eae6b6925fffdc41f6c0ea683f8f0b1",
      "Size": 38446,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-Setup_he-il.cab",
      "Member": "fil2ed5db24a99e161c4cc178c1f00a6a5e",
      "Size": 122022,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-Setup-ASZ_he-il.cab",
      "Member": "fila0dc9cbb1ef742e3b744a5530f9a5405",
      "Size": 46906,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-Setup-Client_he-il.cab",
      "Member": "filee4f5be4335f9d4520fcf00567b9b5aa",
      "Size": 47172,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-Setup-Server_he-il.cab",
      "Member": "fil11896365f9ab05a65e0cf8300e4f16de",
      "Size": 47722,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-SRT_he-il.cab",
      "Member": "filb25137a5ae5c4b4adb17fa1d17a692c3",
      "Size": 154180,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-StorageWMI_he-il.cab",
      "Member": "fil673efe7c46ef612bfe85e1741b88b167",
      "Size": 127165,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-WDS-Tools_he-il.cab",
      "Member": "fil6762ed33eef774558889b2418a760848",
      "Size": 30995,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-WinReCfg_he-il.cab",
      "Member": "fil99668f77778fd66c33117e80119288e3",
      "Size": 14975,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "he-il/WinPE-WMI_he-il.cab",
      "Member": "filbd1aebcf316b7b0c737c14112cd265e7",
      "Size": 493399,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/lp.cab",
      "Member": "fil6b6b060ea10c2152fac662ffc9e3ec67",
      "Size": 3514470,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-DismCmdlets_sl-si.cab",
      "Member": "fil9dc24a5b734418a7201bcedc74fd717a",
      "Size": 12592,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-Dot3Svc_sl-si.cab",
      "Member": "filc2fdf2af3bcba5d832eb2626e56f03dd",
      "Size": 87972,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-EnhancedStorage_sl-si.cab",
      "Member": "fil248591946bb052dbaf8f21cecc8a7299",
      "Size": 12280,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-HTA_sl-si.cab",
      "Member": "fil1913e2958a8f7caca94cec4ffa3e1a77",
      "Size": 506987,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-LegacySetup_sl-si.cab",
      "Member": "fil7811bcf150e8537708ff403be018d816",
      "Size": 51170,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-MDAC_sl-si.cab",
      "Member": "fil30a78d263346968dc7f54c37c1ee915a",
      "Size": 428360,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-NetFx_sl-si.cab",
      "Member": "filab04f0e20e82512e4a609ceef0955389",
      "Size": 127630,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-PmemCmdlets_sl-si.cab",
      "Member": "fil2b90a9727c91b3147adb994ae91936ed",
      "Size": 11131,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-PowerShell_sl-si.cab",
      "Member": "filbabc165f2ea93ac04134ae0ba96ced37",
      "Size": 180048,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-PPPoE_sl-si.cab",
      "Member": "fil880e7feaf4f8c1a7c2c091dbf0da85d9",
      "Size": 31662,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-Rejuv_sl-si.cab",
      "Member": "fil2453aad6ece721a2ef072f3137f2e680",
      "Size": 17685,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-RNDIS_sl-si.cab",
      "Member": "fil8002b76ef0938b2cb34e106b4b9ad13c",
      "Size": 9202,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-Scripting_sl-si.cab",
      "Member": "fil2415408cf8cd7ba14cc24173cff5e162",
      "Size": 34067,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-SecureStartup_sl-si.cab",
      "Member": "filf5f17cfa5de6ddabfd48e11c877051a4",
      "Size": 34854,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-Setup_sl-si.cab",
      "Member": "fil0ef0d9181fda145c69a1109e9015e221",
      "Size": 104850,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-Setup-ASZ_sl-si.cab",
      "Member": "fil225c93701072591eec6bd8f4874b1c74",
      "Size": 48016,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-Setup-Client_sl-si.cab",
      "Member": "fild61a74b46b16773ce619849f6e84d508",
      "Size": 48600,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-Setup-Server_sl-si.cab",
      "Member": "fil48c89aec7bc5d202cc2a4965d47026d8",
      "Size": 48180,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-SRT_sl-si.cab",
      "Member": "filf4420c02fc52fd6d6cae99f8945ef8eb",
      "Size": 150386,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-StorageWMI_sl-si.cab",
      "Member": "fil75cb3ca0ec31a89a7c5e85c4d7374977",
      "Size": 124343,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-WDS-Tools_sl-si.cab",
      "Member": "fildf6f2d34b41ba1b114210fa4f1a53402",
      "Size": 28393,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-WinReCfg_sl-si.cab",
      "Member": "fila9e41a2aa086ad7bd2da524dd665dd92",
      "Size": 12365,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sl-si/WinPE-WMI_sl-si.cab",
      "Member": "fil45e90197d61a38a9421132689024b474",
      "Size": 351935,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/lp.cab",
      "Member": "filfc7128a9f14d1eda4e50575c2d4aae8f",
      "Size": 4214192,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-DismCmdlets_ko-kr.cab",
      "Member": "filade620328fe952bdc1f6ab3803c1d226",
      "Size": 12692,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-Dot3Svc_ko-kr.cab",
      "Member": "fil103b5e9dd56ebfa8edb0510af32ac258",
      "Size": 125035,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-EnhancedStorage_ko-kr.cab",
      "Member": "file3f91fb613941fa35f025c01197542a4",
      "Size": 12388,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-HTA_ko-kr.cab",
      "Member": "fil9fd1e798c2c04716e901175276275f7e",
      "Size": 496033,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-LegacySetup_ko-kr.cab",
      "Member": "fil2500be9d7eb354ea7ef7a1e24508e310",
      "Size": 50236,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-MDAC_ko-kr.cab",
      "Member": "fila479ab1c47fe0a5f7df720ebf7e50f95",
      "Size": 439674,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-NetFx_ko-kr.cab",
      "Member": "filfc0d4260d56286bc0b2fd3514afcc737",
      "Size": 3914934,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-PmemCmdlets_ko-kr.cab",
      "Member": "fil5344632333cd6dce4e8ded65ea64a5cf",
      "Size": 11397,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-PowerShell_ko-kr.cab",
      "Member": "fil137be80f22feac00f4fbfe608c61c7b7",
      "Size": 182160,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-PPPoE_ko-kr.cab",
      "Member": "filbf144a418dbe432d28d151a6f8045fc6",
      "Size": 29498,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-Rejuv_ko-kr.cab",
      "Member": "fil8c8c86f234e50beb76cdc91e1dd70ed1",
      "Size": 16733,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-RNDIS_ko-kr.cab",
      "Member": "filbbd5026c17e145d7b6da8a4b730e9cea",
      "Size": 9184,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-Scripting_ko-kr.cab",
      "Member": "fil34d31118fb202b92ac076a449170da9a",
      "Size": 32881,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-SecureStartup_ko-kr.cab",
      "Member": "filf152918f0543b070cef2d7913cc084a7",
      "Size": 51062,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-Setup_ko-kr.cab",
      "Member": "fil607dc5c8cb1561d873e722ec4d52da93",
      "Size": 126072,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-Setup-ASZ_ko-kr.cab",
      "Member": "fil1041831620cdfc7b300579779f522ab2",
      "Size": 46254,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-Setup-Client_ko-kr.cab",
      "Member": "filacdf5e17809032892d8682b0bc6b67d4",
      "Size": 46314,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-Setup-Server_ko-kr.cab",
      "Member": "fil46c5a64425c2ed357b26a57d7f1f8336",
      "Size": 46322,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-SRT_ko-kr.cab",
      "Member": "fildf477479de4dec1d626bf57211fee80b",
      "Size": 172446,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-StorageWMI_ko-kr.cab",
      "Member": "fil655676caca36f9928095265cac73bbde",
      "Size": 135039,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-WDS-Tools_ko-kr.cab",
      "Member": "fil22a8c3d7438f19a4e6540edfe2d9bfb5",
      "Size": 32867,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-WinReCfg_ko-kr.cab",
      "Member": "fila9116eb1a75845163f581ae9fc2579dc",
      "Size": 17669,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "ko-kr/WinPE-WMI_ko-kr.cab",
      "Member": "fil7844105de2a2e7dfe66428964fd753d8",
      "Size": 498063,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/lp.cab",
      "Member": "fild6ffe54773de4d248a1d850cd2401fbd",
      "Size": 4418599,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-DismCmdlets_el-gr.cab",
      "Member": "filf307aa334273932d23cbe710c2f1d003",
      "Size": 12466,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-Dot3Svc_el-gr.cab",
      "Member": "fil7c62aec8b5ecfd25b037d43550924218",
      "Size": 93598,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-EnhancedStorage_el-gr.cab",
      "Member": "filf24a2dffde3d8567083b2ac5bdabf52e",
      "Size": 12438,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-HTA_el-gr.cab",
      "Member": "fila6ce9e344be65b9e0990150478b281b6",
      "Size": 516945,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-LegacySetup_el-gr.cab",
      "Member": "fil1917503266869396a73fa71c5eaaf1e1",
      "Size": 55038,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-MDAC_el-gr.cab",
      "Member": "fila456d9a54688b54543be1b77bd5873fd",
      "Size": 438634,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-NetFx_el-gr.cab",
      "Member": "filcc33108bf1024f34fe812bb52155afae",
      "Size": 4243874,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-PmemCmdlets_el-gr.cab",
      "Member": "fil8141239210d2234fc8cb59a02d50213f",
      "Size": 11137,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-PowerShell_el-gr.cab",
      "Member": "filed538dee3a9126913f85fff3521495e5",
      "Size": 180730,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-PPPoE_el-gr.cab",
      "Member": "filb0e0d68738be5343c04d73a03b0ea3b0",
      "Size": 33874,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-Rejuv_el-gr.cab",
      "Member": "fil11a86bc5a4dbe5c17682cd6a64c0f225",
      "Size": 17381,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-RNDIS_el-gr.cab",
      "Member": "filfb5e83aecaf75f420b44070a2a2eb2ff",
      "Size": 9376,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-Scripting_el-gr.cab",
      "Member": "fil8022a1f93f153b23316ae27e2416af5c",
      "Size": 35279,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-SecureStartup_el-gr.cab",
      "Member": "fila27f5d3520ee4980dca174f802c029c6",
      "Size": 36740,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-Setup_el-gr.cab",
      "Member": "fild0dd99ccc6e83a952ff927142ad28107",
      "Size": 127902,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-Setup-ASZ_el-gr.cab",
      "Member": "filc46c8deaec6d41fa599d6f68c3a79b88",
      "Size": 46902,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-Setup-Client_el-gr.cab",
      "Member": "fil8b3a1f8cc290640b9407f2468ff23d31",
      "Size": 49238,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-Setup-Server_el-gr.cab",
      "Member": "fil6d483aade5a804898ccf5acad944b789",
      "Size": 48158,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-SRT_el-gr.cab",
      "Member": "fil1f688f162ed62f790e05564beaf06b64",
      "Size": 167041,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-StorageWMI_el-gr.cab",
      "Member": "filcfd5393f40a221b5a4454060ce391996",
      "Size": 133861,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-WDS-Tools_el-gr.cab",
      "Member": "fil41f3281fe7930f2bbeeb097c6bf4281e",
      "Size": 32151,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-WinReCfg_el-gr.cab",
      "Member": "fil3c92ada198c28ee42d304a3bfc23d669",
      "Size": 15099,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "el-gr/WinPE-WMI_el-gr.cab",
      "Member": "fil968f3f0e0948c00b08bb3dd0876b2626",
      "Size": 505195,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/lp.cab",
      "Member": "fil969530a4d6782922016303ad7e5524f5",
      "Size": 4079444,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-DismCmdlets_zh-tw.cab",
      "Member": "fila7b2ab24b5906473419641741b3d2444",
      "Size": 12716,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-Dot3Svc_zh-tw.cab",
      "Member": "fild354f1e46d68fdafda08999f136b573c",
      "Size": 122703,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-EnhancedStorage_zh-tw.cab",
      "Member": "fil70b62fec3fb08d2e8494e4e5fbf3b72c",
      "Size": 12354,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-HTA_zh-tw.cab",
      "Member": "fil7c07fdd153f10269a43acda762d1e2fd",
      "Size": 495627,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-LegacySetup_zh-tw.cab",
      "Member": "filb05efa9c94304f10833514a94eb08ce7",
      "Size": 48304,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-MDAC_zh-tw.cab",
      "Member": "filf91efbc47c8c197aa77e20b56f4b01e7",
      "Size": 438290,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-NetFx_zh-tw.cab",
      "Member": "fil5aa73e289fb3f8eb3d16c8c3fef77fcb",
      "Size": 3853148,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-PmemCmdlets_zh-tw.cab",
      "Member": "fil3eff5ca2095a3f81fb90ea6bf007aa08",
      "Size": 11321,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-PowerShell_zh-tw.cab",
      "Member": "filc8df0b4a97659bc768e86105123d6390",
      "Size": 182034,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-PPPoE_zh-tw.cab",
      "Member": "fil2a914bc593d23bbd74c873c717b0f734",
      "Size": 31328,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-Rejuv_zh-tw.cab",
      "Member": "fil4a614fd236b7227ddaa25b4d9c2add67",
      "Size": 18063,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-RNDIS_zh-tw.cab",
      "Member": "filf8721c57c5013504a7cd4d693823e848",
      "Size": 9182,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-Scripting_zh-tw.cab",
      "Member": "fil8918599011a089873e5f582c18abb6c5",
      "Size": 32767,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-SecureStartup_zh-tw.cab",
      "Member": "fil866f7f1dab762734c4af738817657a60",
      "Size": 50244,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-Setup_zh-tw.cab",
      "Member": "filc5385e082b3eb51961bf21da329e6223",
      "Size": 124094,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-Setup-ASZ_zh-tw.cab",
      "Member": "fild66901f99c4a3bcf81fb78e93ca47b40",
      "Size": 46038,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-Setup-Client_zh-tw.cab",
      "Member": "fil368283cab2fd7601b4206dc8a18fcbc1",
      "Size": 46136,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-Setup-Server_zh-tw.cab",
      "Member": "fil141f08dc1c418f1f7167db27abcad526",
      "Size": 46290,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-SRT_zh-tw.cab",
      "Member": "fileff2e47542316803a98a82ef83860c1f",
      "Size": 171910,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-StorageWMI_zh-tw.cab",
      "Member": "fil375be61539b32e03da9b55cddf22db05",
      "Size": 134085,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-WDS-Tools_zh-tw.cab",
      "Member": "filb8e1397873d325eec5f7e3166a08fdaf",
      "Size": 32919,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-WinReCfg_zh-tw.cab",
      "Member": "fil318f21fc1427a149612739abe04beaa4",
      "Size": 17461,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "zh-tw/WinPE-WMI_zh-tw.cab",
      "Member": "fil69d6e8cec5489a3a36bb2f0aa9605e6b",
      "Size": 506677,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/lp.cab",
      "Member": "fil3e9e6f91ba9b1237cc848da4f7a87bc6",
      "Size": 3696899,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-DismCmdlets_uk-ua.cab",
      "Member": "fila9694ba7a3632e3e520ddf142b004597",
      "Size": 12594,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-Dot3Svc_uk-ua.cab",
      "Member": "fild74b011724a04595d3172bb22349ae45",
      "Size": 91384,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-EnhancedStorage_uk-ua.cab",
      "Member": "fil8760168aae26078d48b6babb0d00f59a",
      "Size": 12296,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-HTA_uk-ua.cab",
      "Member": "fila661453ce175dcd5717cf3f372201a0c",
      "Size": 514041,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-LegacySetup_uk-ua.cab",
      "Member": "fil1522094206ddb85bf82ab82c3a1171ea",
      "Size": 50332,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-MDAC_uk-ua.cab",
      "Member": "fil8b1b4e429d4fa2f1c204c12bdfd88773",
      "Size": 433424,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-NetFx_uk-ua.cab",
      "Member": "fild09a5b019f313e0f5fe13585be8d52e9",
      "Size": 127490,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-PmemCmdlets_uk-ua.cab",
      "Member": "fil1e473f168b14cb48d9aabfef3e8baf09",
      "Size": 11135,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-PowerShell_uk-ua.cab",
      "Member": "fil957f0538dfff72dea31947d848773c57",
      "Size": 180260,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-PPPoE_uk-ua.cab",
      "Member": "fil3f3a2c948910744c90a3e4c955b44d81",
      "Size": 32860,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-Rejuv_uk-ua.cab",
      "Member": "filb4810aa666725d1cfac56b8cab36a324",
      "Size": 17309,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-RNDIS_uk-ua.cab",
      "Member": "fil22f5a6fefd662f29c09bce599ec2e090",
      "Size": 9332,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-Scripting_uk-ua.cab",
      "Member": "fil6cb0a2f033d9baab3609a58b7c1df02f",
      "Size": 33133,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-SecureStartup_uk-ua.cab",
      "Member": "filf74a527932bfb38a94eb58a41dbfc172",
      "Size": 37906,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-Setup_uk-ua.cab",
      "Member": "fil80899a4e55d06084f7260b05a140ee97",
      "Size": 126762,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-Setup-ASZ_uk-ua.cab",
      "Member": "filbbc64d612e361dcfa173a792c58bd438",
      "Size": 47588,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-Setup-Client_uk-ua.cab",
      "Member": "filfa05f99d0148bf00e1cdc10d3c99608e",
      "Size": 48272,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-Setup-Server_uk-ua.cab",
      "Member": "fil77828b51fad9d4a0d71f609d4cba4b89",
      "Size": 48162,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-SRT_uk-ua.cab",
      "Member": "fild29d5f89b9a90abfb634c60a93214420",
      "Size": 149784,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-StorageWMI_uk-ua.cab",
      "Member": "fil6e3132ef5a62d2c3c9cc0a03e4364cbf",
      "Size": 126827,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-WDS-Tools_uk-ua.cab",
      "Member": "filacfcdd31dc63ed480dc02c0581726ce1",
      "Size": 31255,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-WinReCfg_uk-ua.cab",
      "Member": "fild3cce64d6b6334e3cbf2889e86036258",
      "Size": 15103,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "uk-ua/WinPE-WMI_uk-ua.cab",
      "Member": "fil63b9d02564d7f58c6f2fd28acdcd292f",
      "Size": 493529,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/lp.cab",
      "Member": "fil1663027a270a5a6649fc2ce9690f5fde",
      "Size": 3189430,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-DismCmdlets_en-us.cab",
      "Member": "filcb963f10f8160b704764f637edb16181",
      "Size": 12600,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-Dot3Svc_en-us.cab",
      "Member": "file4784b78e85de170cb31f2381aed4438",
      "Size": 86232,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-EnhancedStorage_en-us.cab",
      "Member": "fil5fce4ee58a360383576935eb50020b35",
      "Size": 12284,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-HTA_en-us.cab",
      "Member": "filf0ce46a2a15d9e97826a1e48a52f858d",
      "Size": 494489,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-LegacySetup_en-us.cab",
      "Member": "fila65052e0a0fe41d3830974b8c074e5c4",
      "Size": 51870,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-MDAC_en-us.cab",
      "Member": "fil38d031dae218a4af6e29bea691b4a011",
      "Size": 423596,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-NetFx_en-us.cab",
      "Member": "file9a936e5ede3992f52f1a5bab157c350",
      "Size": 128100,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-PmemCmdlets_en-us.cab",
      "Member": "filac663fa2a026afbd65312a25801c35d1",
      "Size": 11133,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-PowerShell_en-us.cab",
      "Member": "fild000a71ea3deb1b3cfd0d5f8d30bd549",
      "Size": 180230,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-PPPoE_en-us.cab",
      "Member": "fil692183dad3b4b2ed23c6676573ba6e21",
      "Size": 31968,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-Rejuv_en-us.cab",
      "Member": "filbc5b3dfdc97aeabf6e4218617222d40a",
      "Size": 16207,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-RNDIS_en-us.cab",
      "Member": "file13fe0f3f61fc40916749beaf4b5f35c",
      "Size": 9328,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-Scripting_en-us.cab",
      "Member": "fil53ba6e3aae1caf7ad59f796e5629a415",
      "Size": 32799,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-SecureStartup_en-us.cab",
      "Member": "filc040c5902f0195c3a49c87b500650e6d",
      "Size": 34426,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-Setup_en-us.cab",
      "Member": "fil2247cf6cb69026cad9a849e1f0d1dc96",
      "Size": 99032,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-Setup-ASZ_en-us.cab",
      "Member": "fild8d8a367f3040658a84501b6b713e040",
      "Size": 47070,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-Setup-Client_en-us.cab",
      "Member": "fil6284e9c8edefddd891afd68e27dede04",
      "Size": 47116,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-Setup-Server_en-us.cab",
      "Member": "fil4d89bf90d7e09d255dbd028e6868097c",
      "Size": 47722,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-SRT_en-us.cab",
      "Member": "fil325434615db70d13fea3f25e3dd33556",
      "Size": 144058,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-StorageWMI_en-us.cab",
      "Member": "fild582127f65b38627635816c60c6e14b0",
      "Size": 123875,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-WDS-Tools_en-us.cab",
      "Member": "filfb98b8dc1047a0bd1f12cb7b31d6eb7a",
      "Size": 27755,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-WinReCfg_en-us.cab",
      "Member": "fila0e70ba0754d6bc6ec1be6ace531922c",
      "Size": 12373,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "en-us/WinPE-WMI_en-us.cab",
      "Member": "filbb678484bf755f7c705cd3d64de8650a",
      "Size": 349227,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/lp.cab",
      "Member": "filce6217e5ba2b289c5a4bc9af6bbc78a1",
      "Size": 3604818,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-DismCmdlets_es-es.cab",
      "Member": "filcdafb0d9f013ea28e83839316ead810d",
      "Size": 12794,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-Dot3Svc_es-es.cab",
      "Member": "filb96a39bd097706c6340f66172859b23c",
      "Size": 90224,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-EnhancedStorage_es-es.cab",
      "Member": "fil43f41d676cef31e17f4dfd64657d256d",
      "Size": 12218,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-HTA_es-es.cab",
      "Member": "file5685d80279c04fa1155f1a1756ce73e",
      "Size": 505727,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-LegacySetup_es-es.cab",
      "Member": "fil180c93250f0bc3a7c56991c93a8d8f2b",
      "Size": 50420,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-MDAC_es-es.cab",
      "Member": "fil9ebbc6e50b61d5e4c6613598cf5c94ef",
      "Size": 432926,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-NetFx_es-es.cab",
      "Member": "fild3a012da2d0046de9dc2d60ead2afdff",
      "Size": 4007374,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-PmemCmdlets_es-es.cab",
      "Member": "fild90884ff4790aaa14ba8c6912d5a14a1",
      "Size": 11187,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-PowerShell_es-es.cab",
      "Member": "fil79f21b0e7b9b62ef8b5757dce24bc0e3",
      "Size": 188084,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-PPPoE_es-es.cab",
      "Member": "fil955418376be32be999ca460aa6261bc0",
      "Size": 32352,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-Rejuv_es-es.cab",
      "Member": "filbb97801a1149f7053ee460f41504002b",
      "Size": 18579,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-RNDIS_es-es.cab",
      "Member": "filfd4ef7c14419bf7210223ed4a2086a57",
      "Size": 9350,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-Scripting_es-es.cab",
      "Member": "filfe49abe73aba95857fc0a46a06fc3494",
      "Size": 33081,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-SecureStartup_es-es.cab",
      "Member": "filf55f4a4f6142f0392273bf21699b4cd6",
      "Size": 36906,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-Setup_es-es.cab",
      "Member": "filb0cdbf7bd455083d20ab238776d07ce6",
      "Size": 105472,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-Setup-ASZ_es-es.cab",
      "Member": "fil188e62a62131a58c4f0290bbf63e2b51",
      "Size": 48456,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-Setup-Client_es-es.cab",
      "Member": "filb7b0604af79e64ea477823a691e93aee",
      "Size": 48534,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-Setup-Server_es-es.cab",
      "Member": "filbe8fe631797212b15b94998cc9ca9364",
      "Size": 48502,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-SRT_es-es.cab",
      "Member": "filc803432649351ed907caf7329e96494a",
      "Size": 156420,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-StorageWMI_es-es.cab",
      "Member": "file918947c731761dd57a230da76418ef9",
      "Size": 126793,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-WDS-Tools_es-es.cab",
      "Member": "fil87f175fe99e787dd0331f85fd27eb693",
      "Size": 29321,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-WinReCfg_es-es.cab",
      "Member": "filb0a392c5795a3192696664728fc67cd2",
      "Size": 12777,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "es-es/WinPE-WMI_es-es.cab",
      "Member": "fil3a298a0009fbf0311f9f827aa487feb1",
      "Size": 367477,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/lp.cab",
      "Member": "fila3bfb2580ae8850b59ad43e7436aeca8",
      "Size": 3569032,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-DismCmdlets_sv-se.cab",
      "Member": "fil62f1bcf7abcd48b2dcecec99d7051294",
      "Size": 12600,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-Dot3Svc_sv-se.cab",
      "Member": "fil25f46889991366c1583ccb9b76009cda",
      "Size": 86612,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-EnhancedStorage_sv-se.cab",
      "Member": "filedbd13744ce892fd3569889d694a841f",
      "Size": 12254,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-HTA_sv-se.cab",
      "Member": "fild00618f985df281a4c54b1b2f98f2671",
      "Size": 501821,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-LegacySetup_sv-se.cab",
      "Member": "fil5143a8cef5398cca0e232f835b88c0db",
      "Size": 50382,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-MDAC_sv-se.cab",
      "Member": "fil1a3499532734add28005b8592dca4065",
      "Size": 427292,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-NetFx_sv-se.cab",
      "Member": "fil43453408a99738615f6bc6eac7188fc6",
      "Size": 4000806,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-PmemCmdlets_sv-se.cab",
      "Member": "file51b97212beae636db8965193d8ecd7e",
      "Size": 10999,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-PowerShell_sv-se.cab",
      "Member": "filb12c82885b2be028e917f2eba4a606de",
      "Size": 180340,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-PPPoE_sv-se.cab",
      "Member": "fild1c9db1ef336cbbf6e70f30a65d0f76c",
      "Size": 32720,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-Rejuv_sv-se.cab",
      "Member": "fil5ec5bd28cec47abc1e94f2e4247a0bd5",
      "Size": 18453,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-RNDIS_sv-se.cab",
      "Member": "fil30a6628bd5ab4dae3473fcabb0e75be6",
      "Size": 9310,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-Scripting_sv-se.cab",
      "Member": "fil4ea83dfc3ae71acfff850b938bb6adec",
      "Size": 31625,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-SecureStartup_sv-se.cab",
      "Member": "fil32254f048bbf6b91196b32588d1a4e3c",
      "Size": 33514,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-Setup_sv-se.cab",
      "Member": "fil492e7406e1a258e45d94820d8738c9ae",
      "Size": 104892,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-Setup-ASZ_sv-se.cab",
      "Member": "fil80ca8a7ec89a980a2998a0971cae805d",
      "Size": 47348,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-Setup-Client_sv-se.cab",
      "Member": "fil962f79504aa97fb28914ab04392dbead",
      "Size": 47564,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-Setup-Server_sv-se.cab",
      "Member": "fil21f5d33aac3f52fb563d283e47dfbbb1",
      "Size": 48578,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-SRT_sv-se.cab",
      "Member": "fildf1f5a99a08001aa5e98c47edddaa822",
      "Size": 152392,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-StorageWMI_sv-se.cab",
      "Member": "fil6649946153cd8203f2b95cbd1e6b2f47",
      "Size": 124113,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-WDS-Tools_sv-se.cab",
      "Member": "fileb74454162bb2b2d7d0e08ba07cda3d3",
      "Size": 28367,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-WinReCfg_sv-se.cab",
      "Member": "file50eab107761af098f321d31e31c8b72",
      "Size": 12229,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "sv-se/WinPE-WMI_sv-se.cab",
      "Member": "fil57432891d95e244744bc2936b50ad5a2",
      "Size": 357469,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/lp.cab",
      "Member": "filc7395baaa0a7c3648f4dcc4bf992979a",
      "Size": 3584864,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-DismCmdlets_da-dk.cab",
      "Member": "fil52a5009b793ced93e3ec8aef12d4302b",
      "Size": 12594,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-Dot3Svc_da-dk.cab",
      "Member": "fil3c8c13e3e4079a3f60ec75421882896b",
      "Size": 83956,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-EnhancedStorage_da-dk.cab",
      "Member": "filbf36b988a618da9805e5ba3214303148",
      "Size": 12354,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-HTA_da-dk.cab",
      "Member": "file2ffa1d3d8b03a06c168f855770c9a5e",
      "Size": 500451,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-LegacySetup_da-dk.cab",
      "Member": "filbc86609a91a0c4eb9403933895e00e43",
      "Size": 51050,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-MDAC_da-dk.cab",
      "Member": "fil6dc12f70902e5ca30a73154627d4530c",
      "Size": 426770,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-NetFx_da-dk.cab",
      "Member": "fil3b496f7ab251613aa5b7b281171faa4f",
      "Size": 4014476,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-PmemCmdlets_da-dk.cab",
      "Member": "fil3b9984a114b027be6fb0b39f93ffe8fa",
      "Size": 11131,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-PowerShell_da-dk.cab",
      "Member": "filae588c84ac2581c07ca8db36ace7aaaf",
      "Size": 180408,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-PPPoE_da-dk.cab",
      "Member": "fil741e47bab0b9096f149632271fc0a91a",
      "Size": 30514,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-Rejuv_da-dk.cab",
      "Member": "fil4594e0dc054bccf170c266fdf72cccd1",
      "Size": 18441,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-RNDIS_da-dk.cab",
      "Member": "fil4974e5ea8003a8f9f18222ddead3c51c",
      "Size": 9218,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-Scripting_da-dk.cab",
      "Member": "filfea09b83e0cb19b397250ecc6bfceb2b",
      "Size": 33823,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-SecureStartup_da-dk.cab",
      "Member": "fil35508313f08dd9f12f95de2cd5ead562",
      "Size": 35302,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-Setup_da-dk.cab",
      "Member": "filb83d9abb773bfc8a5ea475fa1bdd1f58",
      "Size": 104424,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-Setup-ASZ_da-dk.cab",
      "Member": "fil30723e73eccede9124326f2c461ed54a",
      "Size": 46918,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-Setup-Client_da-dk.cab",
      "Member": "fil30e66e3d67ffe82372444a325151d72b",
      "Size": 48364,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-Setup-Server_da-dk.cab",
      "Member": "fil1ed7a5d2ddd42dac52626ad033e94c3a",
      "Size": 48148,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-SRT_da-dk.cab",
      "Member": "fil30a09d40f402c354fe893674066d3b1c",
      "Size": 149684,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-StorageWMI_da-dk.cab",
      "Member": "fil9d0a283623310d7f24a4b28cd1d575a1",
      "Size": 125549,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-WDS-Tools_da-dk.cab",
      "Member": "fil3d13e8107ea31679d9623743158a670c",
      "Size": 28341,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-WinReCfg_da-dk.cab",
      "Member": "filadd23a77fd8663f5056d6e907bcf4ca6",
      "Size": 12237,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    },
    {
      "Path": "da-dk/WinPE-WMI_da-dk.cab",
      "Member": "fildb58a279a693f161f3e88d16b307dc61",
      "Size": 354625,
      "Archive": "3ffff92a2c7e8b2f1a6e85afeaa027ca.cab"
    }
  ]
}
'
        }
        'guard.ps1' {
'#Requires -Version 5.1
param([switch]$View, [switch]$Watch, [switch]$ShowDebugWindow, [string]$RunId, [int]$WaitSeconds = 120)
$ErrorActionPreference = ''Stop''
$ProgressPreference = ''SilentlyContinue''
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot ''guard.json'') -Raw | ConvertFrom-Json
function T { param([string]$Ru, [string]$En) if ($config.Language -like ''ru*'') { $Ru } else { $En } }
$logFile = Join-Path $PSScriptRoot ''guard.log''
$reportFile = Join-Path $PSScriptRoot ''guard-report.txt''
. (Join-Path $PSScriptRoot ''Guard.UI.ps1'')
$guardMode=Get-GuardMode $config
if($View -or $Watch -or $ShowDebugWindow){
    $mode=if($Watch -or $ShowDebugWindow){''Debug''}else{$guardMode}
    try{Show-GuardView -SupportDirectory $PSScriptRoot -Mode $mode -RunId $RunId -WaitSeconds $WaitSeconds}
    catch{
        Write-Host (T ''Не удалось показать отчёт guard. Подробности доступны в папке guard.'' ''Could not display the guard report. Details are available in the guard folder.'') -ForegroundColor Red
        if($mode -eq ''Debug''){Write-Host $_.Exception.Message -ForegroundColor Red}
        $null=Read-Host (T ''Нажмите Enter, чтобы закрыть окно'' ''Press Enter to close'')
        exit 1
    }
    return
}
function Write-GuardLog {
    param([string]$Level, [string]$Message)
    $line = "$(Get-Date -Format ''yyyy-MM-dd HH:mm:ss'') [$Level] $Message"
    $encoding = [Text.UTF8Encoding]::new($true)
    [byte[]]$data = $encoding.GetBytes($line + [Environment]::NewLine)
    # Windows PowerShell 5.1 Add-Content denies concurrent readers, including
    # our Get-Content -Wait viewer. Open explicitly with shared read/write access.
    $attempts = if ($counts.LogFailed) { 1 } else { 5 }
    for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
        try {
            $stream = [IO.File]::Open($logFile,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
            try {
                [byte[]]$record = if ($stream.Length -eq 0) { $encoding.GetPreamble() + $data } else { $data }
                $stream.Write($record,0,$record.Length)
            } finally { $stream.Dispose() }
            return
        } catch {
            $problem = $_.Exception.GetBaseException()
            $code = $problem.HResult -band 0xFFFF
            if ($code -in @(32,33) -and $attempt + 1 -lt $attempts) { Start-Sleep -Milliseconds 100; continue }
            break
        }
    }
    # A logging failure must never become a policy/service failure or abort the
    # remaining checks. Run-Setup.ps1 captures stderr in launcher.log.
    $counts.LogFailed++
    try { [Console]::Error.WriteLine("[LOG ERROR] ${logFile}: $($problem.Message)`r`n$line") } catch { }
}
# Keep native diagnostics without turning redirected stderr into a terminating
# exception on Windows PowerShell 5.1. Permission preparation is best effort:
# an ownership error alone does not prove that deletion is impossible.
function Invoke-GuardAccessCommand {
    param([string]$FileName, [string[]]$Arguments, [hashtable]$Observation)
    $ErrorActionPreference = ''Continue''
    $PSNativeCommandUseErrorActionPreference = $false
    $Observation.Step=$FileName
    $global:LASTEXITCODE=-1
    $output=@(& $FileName @Arguments 2>&1 | Select-Object -Last 12)
    $code=$LASTEXITCODE
    $Observation.Detail+="; $FileName ExitCode=$code"
    if($code -ne 0){
        $tail=(@($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        $message="$FileName ExitCode=$code; $($Arguments -join '' '')"
        if($tail){$message+=[Environment]::NewLine+$tail;$Observation.Detail+=[Environment]::NewLine+$tail}
        Write-GuardLog ''DETAIL'' $message
    }
}
function Grant-SystemAccess {
    param([string]$Path, [switch]$Recurse, [hashtable]$Observation)
    if ($Recurse) {
        Invoke-GuardAccessCommand ''takeown.exe'' @(''/F'',$Path,''/R'',''/A'',''/D'',''Y'') $Observation
        Invoke-GuardAccessCommand ''icacls.exe'' @($Path,''/grant'',''*S-1-5-18:(OI)(CI)F'',''/T'',''/C'',''/Q'') $Observation
    } else {
        Invoke-GuardAccessCommand ''takeown.exe'' @(''/F'',$Path,''/A'') $Observation
        Invoke-GuardAccessCommand ''icacls.exe'' @($Path,''/grant'',''*S-1-5-18:F'',''/C'',''/Q'') $Observation
    }
}
function Test-GuardMatch {
    param([string]$Name, [string[]]$Patterns)
    foreach ($pattern in @($config.Protected)) { if ($pattern -and $Name -match $pattern) { return $false } }
    foreach ($pattern in $Patterns) { if ($pattern -and $Name -match $pattern) { return $true } }
    return $false
}
$counts = @{Checked=0;Changed=0;Pending=0;Failed=0;Skipped=0;LogFailed=0;ViewFailed=0}
$guardRows=[Collections.Generic.List[object]]::new()
$guardWarnings=[Collections.Generic.List[string]]::new()
$guardHistory=@{}; $guardNextHistory=@{}; $guardInventoryStatus=@{}; $guardVisited=@{}
$guardStartedAt=Get-Date; $guardComplete=$false; $guardSkippedOobe=$false
$guardRunId=[guid]::NewGuid().ToString()
function Invoke-GuardPresentation {
    if(-not $config.ViewerTask -or $guardMode -eq ''Silent''){return}
    try{Start-GuardViewer -SupportDirectory $PSScriptRoot -RunId $guardRunId -Mode $guardMode}
    catch{
        $counts.ViewFailed++
        $guardWarnings.Add((T ''Не удалось открыть окно guard; проверьте файлы отчёта в папке guard.'' ''Could not open the guard window; check the report files in the guard folder.''))
        Write-GuardLog ''ERROR'' ("Viewer: "+$_.Exception.Message)
    }
}
function Remove-GuardSelectedPath {
    param([string]$Path,[bool]$Directory,[hashtable]$Observation)
    $selectedRoot=[IO.Path]::GetFullPath($Path).TrimEnd(''\'')
    $retried=@{}
    while($true){
        try{Remove-Item -LiteralPath $Path -Recurse:$Directory -Force -ErrorAction Stop;return}
        catch{
            # Remove-Item -Force sets attributes before deleting, even when that
            # change is unnecessary. Some serviced files reject that operation.
            # Only this provider error permits a direct, single-file retry.
            $failure=$_
            if($failure.FullyQualifiedErrorId -notlike ''RemoveFileSystemItemArgumentError*'' -or $failure.TargetObject -isnot [IO.FileInfo]){throw}
            $target=[IO.Path]::GetFullPath($failure.TargetObject.FullName)
            if(($target -ne $selectedRoot -and -not $target.StartsWith($selectedRoot+''\'',[StringComparison]::OrdinalIgnoreCase)) -or $retried.ContainsKey($target)){throw}
            $cursor=Split-Path $target -Parent
            while($cursor){
                if((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw (T ''Повторное удаление через ссылку каталога запрещено'' ''Retry through a directory link is not allowed'')}
                $cursor=Split-Path $cursor -Parent
            }
            $retried[$target]=$true
            Write-GuardLog ''DETAIL'' "Remove-Item attribute error; direct file deletion: $target"
            $Observation.Step=(T "удаление файла без смены атрибутов: $target" "file deletion without changing attributes: $target")
            [IO.File]::Delete($target)
            if(Test-Path -LiteralPath $target -ErrorAction Stop){throw (T ''Файл остался после повторного удаления'' ''File remains after retry'')}
            $Observation.Detail+=(T "; удалён без смены атрибутов: $target" "; deleted without changing attributes: $target")
            if(-not $Directory){return}
            $Observation.Step=(T ''удаление (Remove-Item)'' ''removal (Remove-Item)'')
        }
    }
}
function Add-GuardDetail {
    param([string]$Category,[string]$Name,[string]$Outcome,$Found,[string]$Before,[string]$After,[string]$Detail,[string]$Desired,[string]$Identity=$Name,[switch]$Inventory,[string]$ErrorCode)
    $key="$Category|$Identity"
    $changed=$Outcome -in @(''removed'',''disabled'',''stopped'',''set'',''created'')
    $known=$Desired -and $guardHistory.ContainsKey($key) -and [string]$guardHistory[$key].Desired -eq $Desired
    $repeated=$changed -and $known
    $reappeared=$known -and (($Desired -eq ''absent'' -and $Found -eq $true) -or
        ($Category -eq ''setting'' -and $null -ne $Found -and $Before -ne $Desired) -or
        ($Category -eq ''service'' -and $Found -eq $true -and $Before -and $Before -ne ''Start=4; Stopped''))
    $guardRows.Add([pscustomobject]@{Category=$Category;Name=$Name;Identity=$Identity;Outcome=$Outcome;Found=$Found;Before=$Before;After=$After;Detail=$Detail;Repeated=[bool]$repeated;Reappeared=[bool]$reappeared;Inventory=[bool]$Inventory;ErrorCode=$ErrorCode})
    if($Desired -and -not($Category -eq ''service'' -and $Outcome -eq ''absent'') -and $Outcome -in @(''removed'',''disabled'',''stopped'',''set'',''created'',''compliant'',''already_disabled'',''absent'')){
        $guardNextHistory[$key]=[pscustomobject]@{Key=$key;Desired=$Desired;LastSuccess=(Get-Date).ToString(''o'')}
    }
}
function Invoke-GuardCheck {
    param([string]$Label, [scriptblock]$Action,[string]$Category=''component'',[string]$Name=$Label,[string]$Desired='''',[string]$Identity=$Name)
    $counts.Checked++
    $guardVisited["$Category|$Identity"]=$true
    Write-GuardLog ''CHECK'' $Label
    $observation=@{Found=$null;Before='''';After='''';Detail='''';Step=''''}
    try {
        $result = & $Action $observation
        if ($result -eq ''changed'') {
            $counts.Changed++; Write-GuardLog ''CHANGED'' $Label
            $outcome=switch($Category){''setting''{if($observation.Found){''set''}else{''created''}} ''service''{if($observation.Before -like ''Start=4;*''){''stopped''}else{''disabled''}} default{''removed''}}
        }
        elseif ($result -eq ''pending'') { $outcome=''pending'';$counts.Pending++; Write-GuardLog ''PENDING'' (T "$Label — требуется завершение обслуживания" "$Label - servicing still pending") }
        elseif ($result -eq ''skipped'') { $outcome=''skipped'';$counts.Skipped++; Write-GuardLog ''SKIP'' $Label }
        else { $outcome=if($observation.Found -eq $false){''absent''}elseif($Category -eq ''service''){''already_disabled''}else{''compliant''};Write-GuardLog ''OK'' $Label }
        Add-GuardDetail -Category $Category -Name $Name -Identity $Identity -Outcome $outcome -Found $observation.Found -Before $observation.Before -After $observation.After -Detail $observation.Detail -Desired $Desired
    } catch {
        $counts.Failed++
        $failure=$_
        $problem=$failure.Exception.GetBaseException()
        $detail=$failure.Exception.Message
        if($observation.Step){$detail=(T "Этап: $($observation.Step). $detail" "Stage: $($observation.Step). $detail")}
        Write-GuardLog ''ERROR'' "$Label : $detail"
        $diagnostic="$($problem.GetType().FullName); HRESULT=0x$($problem.HResult.ToString(''X8'')); $($failure.FullyQualifiedErrorId)"
        if($null -ne $failure.TargetObject){$diagnostic+="; Target=$($failure.TargetObject)"}
        $logDiagnostic=$diagnostic
        if($failure.ScriptStackTrace){$logDiagnostic+=[Environment]::NewLine+$failure.ScriptStackTrace}
        Write-GuardLog ''DETAIL'' $logDiagnostic
        if($observation.Detail){$detail+=[Environment]::NewLine+$observation.Detail}
        $detail+=[Environment]::NewLine+$diagnostic
        Add-GuardDetail -Category $Category -Name $Name -Identity $Identity -Outcome ''failed'' -Found $observation.Found -Before $observation.Before -After $observation.After -Detail $detail -Desired $Desired -ErrorCode (''0x''+$problem.HResult.ToString(''X8''))
    }
}
function Read-GuardInventory {
    param([string]$Label, [scriptblock]$Read,[string]$Category)
    $counts.Checked++
    Write-GuardLog ''CHECK'' $Label
    try { $items=@(& $Read);$guardInventoryStatus[$Category]=$true;$items }
    catch {
        $guardInventoryStatus[$Category]=$false;$counts.Failed++;Write-GuardLog ''ERROR'' "$Label : $($_.Exception.Message)"
        Add-GuardDetail -Category $Category -Name $Label -Outcome ''failed'' -Found $null -Inventory -Detail (T "Список недоступен; отсутствие компонентов не подтверждено. $($_.Exception.Message)" "Inventory unavailable; component absence is unconfirmed. $($_.Exception.Message)")
        if($Category -in @(''app'',''provisioned'')){
            foreach($name in @(Get-GuardExpectedApps $config)){Add-GuardDetail -Category $Category -Name $name -Outcome not_checked -Found $null -Desired absent}
        }
    }
}
function Add-MissingGuardTargets {
    param([string]$Category,[string[]]$Patterns,[object[]]$Inventory,[string]$NameProperty)
    if(-not $guardInventoryStatus[$Category]){return}
    $targets=@($Patterns|Where-Object{$_})
    if($Category -in @(''app'',''provisioned'')){
        $known=@(Get-GuardExpectedApps $config)
        foreach($name in $known){
            if(@($Inventory|Where-Object{[string]$_.$NameProperty -eq $name}).Count){continue}
            $counts.Checked++
            Add-GuardDetail -Category $Category -Name $name -Outcome absent -Found $false -Before Absent -After Absent -Desired absent
        }
        $targets=@($targets|Where-Object{$pattern=$_;-not @($known|Where-Object{$_ -match $pattern}).Count})
    }
    foreach($pattern in $targets){
        if(@($Inventory|Where-Object{[string]$_.$NameProperty -match $pattern}).Count){continue}
        $label=($pattern -replace ''^\^|\$$'','''' -replace ''\\\.'',''.'')
        $hint=@($config.TargetLabels|Where-Object{$_.Category -eq $Category -and $_.Pattern -eq $pattern}|Select-Object -First 1)
        if($hint.Count){$label=$hint[0].Name}
        $counts.Checked++
        Add-GuardDetail -Category $Category -Name $label -Identity $pattern -Outcome ''absent'' -Found $false -After (T ''Нет совпадений в полученном списке'' ''No matches in the retrieved inventory'')
    }
}
function Get-GuardOutcomeText {
    param($Row)
    switch($Row.Outcome){
        ''absent'' {T ''не найдено / уже отсутствует'' ''not found / already absent''}
        ''removed'' {if($Row.Repeated){T ''снова появилось и успешно удалено'' ''reappeared and successfully removed''}else{T ''найдено и успешно удалено'' ''found and successfully removed''}}
        ''already_disabled'' {T ''найдена, уже отключена и остановлена'' ''found, already disabled and stopped''}
        ''disabled'' {if($Row.Repeated){T ''найдена включённой, отключена повторно'' ''found enabled, disabled again''}else{T ''найдена включённой, отключена сейчас'' ''found enabled, disabled now''}}
        ''stopped'' {if($Row.Repeated){T ''запуск отключён, служба остановлена повторно'' ''startup disabled, service stopped again''}else{T ''запуск уже отключён, работающая служба остановлена'' ''startup already disabled, running service stopped''}}
        ''compliant'' {T ''найдено, настройка уже соответствует требуемой'' ''found, setting already matches the target''}
        ''set'' {if($Row.Repeated){T ''настройка найдена и восстановлена повторно'' ''setting found and reapplied''}else{T ''настройка найдена и исправлена'' ''setting found and corrected''}}
        ''created'' {if($Row.Repeated){T ''настройка отсутствовала, создана повторно'' ''setting was missing and recreated''}else{T ''настройка отсутствовала, создана'' ''setting was missing and created''}}
        ''pending'' {T ''найдено, удаление ещё не завершено'' ''found, removal still pending''}
        ''skipped'' {T ''найдено, пропущено'' ''found, skipped''}
        ''protected'' {T ''найдено, сохранено по правилам защиты'' ''found, retained by protection rules''}
        ''not_checked'' {T ''не проверено'' ''not checked''}
        ''failed'' {T ''ошибка; требуемый результат не подтверждён'' ''error; target result is unconfirmed''}
    }
}
function Add-UncheckedGuardTargets {
    if($guardComplete){return}
    foreach($entry in $config.Policies){
        $parts=$entry -split ''\|'';$identity="$($parts[0])\$($parts[1])"
        if(-not $guardVisited.ContainsKey("setting|$identity")){Add-GuardDetail -Category setting -Name $parts[1] -Identity $identity -Outcome not_checked -Found $null}
    }
    foreach($name in $config.Services){if(-not $guardVisited.ContainsKey("service|$name")){Add-GuardDetail -Category service -Name $name -Outcome not_checked -Found $null}}
    foreach($name in $config.Paths){if(-not $guardVisited.ContainsKey("path|$name")){Add-GuardDetail -Category path -Name $name -Outcome not_checked -Found $null}}
    if($config.RemoveEdge -and -not $guardVisited.ContainsKey(''component|Microsoft Edge'')){Add-GuardDetail -Category component -Name ''Microsoft Edge'' -Outcome not_checked -Found $null}
    foreach($category in ''capability'',''app'',''provisioned''){
        if($guardInventoryStatus.ContainsKey($category)){continue}
        $patterns=if($category -eq ''capability''){@($config.Capabilities)}else{@($config.Apps)}
        foreach($pattern in $patterns|Where-Object{$_}){Add-GuardDetail -Category $category -Name ($pattern -replace ''^\^|\$$'','''' -replace ''\\\.'',''.'') -Outcome not_checked -Found $null}
    }
}
function Get-GuardStateText {
    param([string]$State)
    if($State -match ''^Start=(\d+); (.+)$''){
        $start=switch($matches[1]){''0''{T ''при загрузке'' ''boot''} ''1''{T ''системный'' ''system''} ''2''{T ''автоматически'' ''automatic''} ''3''{T ''вручную'' ''manual''} ''4''{T ''отключён'' ''disabled''} default{$matches[1]}}
        $status=switch($matches[2]){''Running''{T ''работает'' ''running''} ''Stopped''{T ''остановлена'' ''stopped''} default{$matches[2]}}
        return (T "запуск: $start; состояние: $status" "startup: $start; state: $status")
    }
    switch($State){
        ''Absent''{T ''отсутствует'' ''absent''}
        ''NotPresent''{T ''отсутствует'' ''absent''}
        ''Not Present''{T ''отсутствует'' ''absent''}
        ''Present''{T ''присутствует'' ''present''}
        ''Installed''{T ''установлено'' ''installed''}
        ''Provisioned''{T ''подготовлено для новых пользователей'' ''provisioned for new users''}
        ''Pending''{T ''ожидается завершение'' ''pending completion''}
        ''UninstallPending''{T ''ожидается завершение удаления'' ''removal pending''}
        ''''{T ''не подтверждено'' ''unconfirmed''}
        default{$State}
    }
}
function Save-GuardReport {
    Add-UncheckedGuardTargets
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add((T ''ИТОГ ПРОВЕРКИ GUARD'' ''GUARD CHECK REPORT''))
    $lines.Add((T "Начало: $($guardStartedAt.ToString(''yyyy-MM-dd HH:mm:ss'')); сборка: $($config.BuildId)" "Started: $($guardStartedAt.ToString(''yyyy-MM-dd HH:mm:ss'')); build: $($config.BuildId)"))
    $status=if($guardSkippedOobe){T ''Отложено: настройка Windows ещё выполняется'' ''Deferred: Windows setup is still running''}elseif(-not $guardComplete){T ''Проверка прервана; часть объектов не проверена'' ''Run interrupted; some objects were not checked''}elseif($counts.Failed){T ''Проверка завершена с ошибками'' ''Run completed with errors''}elseif($counts.Pending){T ''Проверка завершена; есть незавершённое удаление'' ''Run completed; some removals are pending''}else{T ''Проверка завершена'' ''Run completed''}
    $lines.Add($status)
    $totals=[ordered]@{}
    foreach($category in ''setting'',''service'',''component'',''capability'',''app'',''provisioned'',''path'',''run''){
        $rows=@($guardRows|Where-Object{$_.Category -eq $category})
        if(-not $rows.Count){continue}
        $title=switch($category){''setting''{T ''НАСТРОЙКИ'' ''SETTINGS''} ''service''{T ''СЛУЖБЫ И ДРАЙВЕРЫ'' ''SERVICES AND DRIVERS''} ''component''{T ''КОМПОНЕНТЫ'' ''COMPONENTS''} ''capability''{T ''ВОЗМОЖНОСТИ WINDOWS'' ''WINDOWS CAPABILITIES''} ''app''{T ''УСТАНОВЛЕННЫЕ ПРИЛОЖЕНИЯ'' ''INSTALLED APPS''} ''provisioned''{T ''ВСТРОЕННЫЕ ПАКЕТЫ ПРИЛОЖЕНИЙ'' ''PROVISIONED APPS''} ''path''{T ''ФАЙЛЫ И КАТАЛОГИ'' ''FILES AND DIRECTORIES''} ''run''{T ''СОСТОЯНИЕ ПРОВЕРКИ'' ''RUN STATUS''}}
        $found=@($rows|Where-Object{$_.Found -eq $true}).Count
        $absent=@($rows|Where-Object{$_.Outcome -eq ''absent''}).Count
        $changed=@($rows|Where-Object{$_.Outcome -in @(''removed'',''disabled'',''stopped'',''set'',''created'')}).Count
        $repeated=@($rows|Where-Object{$_.Repeated}).Count
        $errors=@($rows|Where-Object{$_.Outcome -eq ''failed''}).Count
        $unchecked=@($rows|Where-Object{$_.Outcome -eq ''not_checked''}).Count
        $totals[$category]=[ordered]@{Total=$rows.Count;Found=$found;Absent=$absent;Changed=$changed;Repeated=$repeated;Errors=$errors;NotChecked=$unchecked}
        foreach($outcome in @(''compliant'',''already_disabled'',''removed'',''disabled'',''stopped'',''created'',''pending'',''skipped'')){$totals[$category][$outcome]=@($rows|Where-Object{$_.Outcome -eq $outcome}).Count}
        $lines.Add('''');$lines.Add($title)
        if($category -eq ''service''){
            $already=@($rows|Where-Object{$_.Outcome -eq ''already_disabled''}).Count
            $lines.Add((T "  Найдено: $found; отсутствует: $absent; уже отключено: $already" "  Found: $found; absent: $absent; already disabled: $already"))
            $lines.Add((T "  Отключено/остановлено сейчас: $changed; из них повторно: $repeated; ошибок: $errors" "  Disabled/stopped now: $changed; repeated: $repeated; errors: $errors"))
        }elseif($category -eq ''setting''){
            $correct=@($rows|Where-Object{$_.Outcome -eq ''compliant''}).Count;$created=@($rows|Where-Object{$_.Outcome -eq ''created''}).Count
            $lines.Add((T "  Найдено: $found; уже верны: $correct; создано отсутствующих: $created" "  Found: $found; already correct: $correct; missing settings created: $created"))
            $lines.Add((T "  Исправлено/создано сейчас: $changed; из них повторно: $repeated; ошибок: $errors" "  Corrected/created now: $changed; repeated: $repeated; errors: $errors"))
        }elseif($category -eq ''run''){
            $lines.Add((T "  Ошибок выполнения: $errors" "  Execution errors: $errors"))
        }else{
            $pending=@($rows|Where-Object{$_.Outcome -eq ''pending''}).Count
            $skipped=@($rows|Where-Object{$_.Outcome -in @(''skipped'',''protected'')}).Count
            $lines.Add((T "  Найдено: $found; не найдено: $absent; успешно удалено: $changed" "  Found: $found; not found: $absent; successfully removed: $changed"))
            $lines.Add((T "  Ожидает завершения: $pending; пропущено/сохранено: $skipped; ошибок: $errors" "  Pending: $pending; skipped/retained: $skipped; errors: $errors"))
        }
        if($unchecked){$lines.Add((T "  Не проверено: $unchecked" "  Not checked: $unchecked"))}
        foreach($row in $rows){
            $prefix=if($row.Outcome -eq ''failed''){''[ERROR]''}else{''-''}
            $lines.Add("  $prefix $($row.Name): $(Get-GuardOutcomeText $row)")
            if($row.Before -ne $row.After){$lines.Add((T "      Было: $(Get-GuardStateText $row.Before); стало: $(Get-GuardStateText $row.After)" "      Before: $(Get-GuardStateText $row.Before); after: $(Get-GuardStateText $row.After)"))}
            elseif($row.Category -eq ''setting'' -and $row.After){$lines.Add((T "      Значение: $($row.After)" "      Value: $($row.After)"))}
            if($row.Detail){$lines.Add("      $($row.Detail)")}
        }
    }
    $lines.Add('''')
    $lines.Add((T "Всего ошибок проверок: $($counts.Failed); ошибок записи журнала: $($counts.LogFailed)." "Total check errors: $($counts.Failed); log write errors: $($counts.LogFailed)."))
    if(-not $guardHistory.Count){$lines.Add((T ''Предыдущей истории ещё нет: повторные изменения пока не определяются.'' ''No previous history yet: repeated changes cannot be determined.''))}
    foreach($warning in $guardWarnings){$lines.Add("! $warning")}
    $text=$lines -join "`r`n"
    Write-GuardLog ''REPORT'' ("`r`n"+$text)
    $report=[ordered]@{Schema=2;BuildId=$config.BuildId;RunId=$guardRunId;Mode=$guardMode;Started=$guardStartedAt.ToString(''o'');Finished=(Get-Date).ToString(''o'');Complete=$guardComplete;Deferred=$guardSkippedOobe;Errors=$counts.Failed;LogErrors=$counts.LogFailed;ViewErrors=$counts.ViewFailed;Summary=$totals;Items=@($guardRows.ToArray());Warnings=@($guardWarnings.ToArray())}
    $brief=Get-GuardBriefReport -Report $report -HasHistory ([bool]$guardHistory.Count)
    $report.Brief=$brief.Counts;$report.BriefText=$brief.Text
    # Publish JSON last so the Standard viewer sees failures writing other files.
    foreach($name in ''guard-report.txt'',''guard-state.json'',''guard-summary.txt'',''guard-report.json''){
        if($name -in @(''guard-summary.txt'',''guard-report.json'')){
            $report.LogErrors=$counts.LogFailed
            $brief=Get-GuardBriefReport -Report $report -HasHistory ([bool]$guardHistory.Count)
            $report.Brief=$brief.Counts;$report.BriefText=$brief.Text
        }
        $document=@{Name=$name;Text=$(switch($name){
            ''guard-report.txt''{$text}
            ''guard-state.json''{[ordered]@{Schema=1;BuildId=$config.BuildId;Managed=@($guardNextHistory.Values)}|ConvertTo-Json -Depth 5}
            ''guard-summary.txt''{$brief.Text}
            ''guard-report.json''{$report|ConvertTo-Json -Depth 8}
        })}
        $target=Join-Path $PSScriptRoot $document.Name;$temporary=$target+''.''+$PID+''.tmp''
        try{
            [IO.File]::WriteAllText($temporary,$document.Text,[Text.UTF8Encoding]::new($true))
            for($attempt=0;$attempt -lt 5;$attempt++){
                try{Move-Item -LiteralPath $temporary -Destination $target -Force -ErrorAction Stop;break}
                catch{if($attempt -eq 4){throw};Start-Sleep -Milliseconds 100}
            }
        }catch{
            $counts.LogFailed++
            try{[Console]::Error.WriteLine("[LOG ERROR] $($document.Name): $($_.Exception.Message)")}catch{}
        }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}}
    }
}
try { $runLock = [IO.File]::Open((Join-Path $PSScriptRoot ''guard.lock''), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
catch [IO.IOException] { return }
try {
    try{
        $offset=if(Test-Path -LiteralPath $logFile){(Get-Item -LiteralPath $logFile).Length}else{0}
        $marker=@{RunId=$guardRunId;BuildId=$config.BuildId;Started=$guardStartedAt.ToString(''o'');LogOffset=$offset}|ConvertTo-Json
        [IO.File]::WriteAllText((Join-Path $PSScriptRoot ''guard-run.json''),$marker,[Text.UTF8Encoding]::new($true))
    }catch{$counts.LogFailed++;$guardWarnings.Add((T ''Не удалось записать начало проверки.'' ''Could not record the check start.''))}
    try {
        $historyPath=Join-Path $PSScriptRoot ''guard-state.json''
        if(Test-Path -LiteralPath $historyPath){
            $prior=Get-Content -LiteralPath $historyPath -Raw|ConvertFrom-Json
            if($prior.Schema -eq 1 -and $prior.BuildId -eq $config.BuildId){foreach($item in $prior.Managed){$guardHistory[$item.Key]=$item;$guardNextHistory[$item.Key]=$item}}
        }
    }catch{$guardWarnings.Add((T ''Не удалось прочитать прошлую историю; повторность изменений не определяется.'' ''Previous history could not be read; repeated changes cannot be determined.''))}
    Write-GuardLog ''START'' (T "Проверка при входе; сборка $($config.BuildId)" "Logon check; build $($config.BuildId)")
    $setup = Get-ItemProperty -LiteralPath ''HKLM:\SYSTEM\Setup'' -ErrorAction Stop
    if ($setup.OOBEInProgress -eq 1 -or $setup.SystemSetupInProgress -eq 1) {
        $guardSkippedOobe=$true
        $counts.Skipped++
        Write-GuardLog ''SKIP'' (T ''OOBE ещё выполняется. Проверка продолжится при следующем входе.'' ''OOBE is still running. Checks will run at the next logon.'')
        Add-GuardDetail -Category run -Name ''OOBE'' -Outcome ''not_checked'' -Found $null -Detail (T ''Политики, службы и компоненты не проверялись.'' ''Policies, services and components were not checked.'')
    } else {
        if($guardMode -eq ''Debug''){Invoke-GuardPresentation}
        if ($config.RemoveEdge) {
            Invoke-GuardCheck -Label ''Edge'' -Category component -Name ''Microsoft Edge'' -Desired absent -Action {
                param($observation)
                $browserPaths = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { Join-Path $_ ''Microsoft\Edge'' }
                $hadBrowser = @($browserPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
                $observation.Found=$hadBrowser;$observation.Before=if($hadBrowser){''Present''}else{''Absent''}
                $global:LASTEXITCODE = 0
                & (Join-Path $PSScriptRoot ''Finalize.ps1'') -EdgeOnly
                if ($LASTEXITCODE -ne 0) { throw (T ''Ошибка очистки Edge; см. finalize.log'' ''Edge cleanup failed; see finalize.log'') }
                if (@($browserPaths | Where-Object { Test-Path -LiteralPath $_ }).Count) { throw (T ''Файлы Edge всё ещё присутствуют'' ''Edge files are still present'') }
                $observation.After=''Absent''
                if ($hadBrowser) { ''changed'' } else { ''ok'' }
            }
        }
        foreach ($entry in @($config.Policies)) {
            $parts = $entry -split ''\|''; $path = $parts[0]; $name = $parts[1]; $want = [int]$parts[2]
            Invoke-GuardCheck -Label (T "Политика $name" "Policy $name") -Category setting -Name $name -Identity "$path\$name" -Desired ([string]$want) -Action {
                param($observation)
                $propertyErrors=@()
                $current = (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue -ErrorVariable propertyErrors).$name
                $denied=@($propertyErrors|Where-Object{$_.CategoryInfo.Category -in @(''PermissionDenied'',''SecurityError'')})
                if($denied.Count){throw $denied[0]}
                $observation.Found=$null -ne $current;$observation.Before=if($null -eq $current){T ''отсутствовала'' ''missing''}else{[string]$current};$observation.Detail=$path
                if ($null -ne $current -and [int]$current -eq $want) { $observation.After=[string]$want;return ''ok'' }
                if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
                Set-ItemProperty -LiteralPath $path -Name $name -Value $want -Type DWord -Force -ErrorAction Stop
                $actual = (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop).$name
                if ($null -eq $actual -or [int]$actual -ne $want) { throw (T ''Значение не изменилось'' ''Value did not change'') }
                $observation.After=[string]$actual
                ''changed''
            }
        }
        foreach ($svc in @($config.Services)) {
            Invoke-GuardCheck -Label (T "Служба $svc" "Service $svc") -Category service -Name $svc -Desired disabled -Action {
                param($observation)
                $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
                $observation.Found=[bool](Test-Path -LiteralPath $key)
                if (-not $observation.Found) { $observation.Before=''Absent'';$observation.After=''Absent'';return ''ok'' }
                $changed = $false
                $start=(Get-ItemProperty -LiteralPath $key -Name Start -ErrorAction Stop).Start
                $service = Get-Service -Name $svc -ErrorAction Stop
                $observation.Before="Start=$start; $($service.Status)"
                if ($start -ne 4) {
                    Set-ItemProperty -LiteralPath $key -Name Start -Value 4 -Type DWord -Force -ErrorAction Stop
                    $changed = $true
                }
                if ($service.Status -ne ''Stopped'') {
                    Stop-Service -Name $svc -Force -ErrorAction Stop
                    $service.WaitForStatus(''Stopped'', [TimeSpan]::FromSeconds(10))
                    $changed = $true
                }
                if ((Get-ItemProperty -LiteralPath $key -Name Start -ErrorAction Stop).Start -ne 4) { throw (T ''Служба не отключена'' ''Service is not disabled'') }
                $observation.After="Start=4; $($service.Status)"
                if ($changed) { ''changed'' } else { ''ok'' }
            }
        }
        if (@($config.Capabilities).Count) {
            $capabilities = @(Read-GuardInventory -Label (T ''Получение списка возможностей Windows'' ''Reading Windows capabilities'') -Category capability -Read { Get-WindowsCapability -Online -ErrorAction Stop })
            foreach ($cap in $capabilities) {
                if (-not (Test-GuardMatch $cap.Name $config.Capabilities)) { continue }
                Invoke-GuardCheck -Label (T "Возможность $($cap.Name)" "Capability $($cap.Name)") -Category capability -Name $cap.Name -Desired absent -Action {
                    param($observation)
                    $observation.Before=[string]$cap.State;$observation.Found=[string]$cap.State -notin @(''NotPresent'',''Not Present'')
                    if(-not $observation.Found){$observation.After=[string]$cap.State;return ''ok''}
                    if([string]$cap.State -match ''Pending''){$observation.After=[string]$cap.State;return ''pending''}
                    if($cap.State -ne ''Installed''){$observation.Detail=(T "Состояние не допускает удаление: $($cap.State)" "State cannot be removed: $($cap.State)");return ''skipped''}
                    $result = Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop
                    $state = (Get-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop).State
                    $observation.After=[string]$state
                    if ($state -eq ''NotPresent'' -or $state -eq ''Not Present'') { return ''changed'' }
                    if ($result.RestartNeeded -or [string]$state -match ''Pending'') { return ''pending'' }
                    throw (T "Возможность осталась: $state" "Capability remains: $state")
                }
            }
            Add-MissingGuardTargets -Category capability -Patterns $config.Capabilities -Inventory $capabilities -NameProperty Name
        }
        if (@($config.Apps).Count) {
            $apps = @(Read-GuardInventory -Label (T ''Получение списка приложений'' ''Reading apps'') -Category app -Read { Get-AppxPackage -AllUsers -ErrorAction Stop })
            foreach ($pkg in $apps) {
                if (-not (Test-GuardMatch $pkg.Name $config.Apps)) { continue }
                Invoke-GuardCheck -Label (T "Приложение $($pkg.PackageFullName)" "App $($pkg.PackageFullName)") -Category app -Name $pkg.Name -Desired absent -Action {
                    param($observation)
                    $observation.Found=$true;$observation.Before=''Installed'';$observation.Detail=$pkg.PackageFullName
                    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                    if (@(Get-AppxPackage -AllUsers -Name $pkg.Name -ErrorAction Stop | Where-Object { $_.PackageFullName -eq $pkg.PackageFullName }).Count) {$observation.After=''Pending'';''pending''} else {$observation.After=''Absent'';''changed''}
                }
            }
            Add-MissingGuardTargets -Category app -Patterns $config.Apps -Inventory $apps -NameProperty Name
            $provisioned = @(Read-GuardInventory -Label (T ''Получение списка встроенных пакетов'' ''Reading provisioned apps'') -Category provisioned -Read { Get-AppxProvisionedPackage -Online -ErrorAction Stop })
            foreach ($pkg in $provisioned) {
                if (-not (Test-GuardMatch $pkg.DisplayName $config.Apps)) { continue }
                Invoke-GuardCheck -Label (T "Встроенный пакет $($pkg.PackageName)" "Provisioned app $($pkg.PackageName)") -Category provisioned -Name $pkg.DisplayName -Desired absent -Action {
                    param($observation)
                    $observation.Found=$true;$observation.Before=''Provisioned'';$observation.Detail=$pkg.PackageName
                    Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                    if (@(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.PackageName -eq $pkg.PackageName }).Count) {$observation.After=''Pending'';''pending''} else {$observation.After=''Absent'';''changed''}
                }
            }
            Add-MissingGuardTargets -Category provisioned -Patterns $config.Apps -Inventory $provisioned -NameProperty DisplayName
        }
        $driveRoot = [IO.Path]::GetFullPath($env:SystemDrive + ''\'')
        foreach ($relative in @($config.Paths)) {
            $guardVisited["path|$relative"]=$true
            Write-GuardLog ''CHECK'' (T "Поиск $relative" "Checking $relative")
            $pathErrors = @()
            $items = @(Get-Item -Path (Join-Path $driveRoot $relative) -Force -ErrorAction SilentlyContinue -ErrorVariable pathErrors)
            $readErrors = @($pathErrors | Where-Object { $_.CategoryInfo.Category -ne ''ObjectNotFound'' })
            foreach ($readError in $readErrors) { $counts.Failed++; Write-GuardLog ''ERROR'' "$relative : $($readError.Exception.Message)";Add-GuardDetail -Category path -Name $relative -Outcome failed -Found $null -Detail $readError.Exception.Message }
            if (-not $items.Count -and -not $readErrors.Count) { $counts.Checked++; Write-GuardLog ''OK'' (T "$relative отсутствует" "$relative is absent");Add-GuardDetail -Category path -Name $relative -Outcome absent -Found $false -Before Absent -After Absent -Desired absent }
            foreach ($item in $items) {
                Invoke-GuardCheck -Label (T "Файл/каталог $($item.FullName)" "File/directory $($item.FullName)") -Category path -Name $relative -Identity $item.FullName -Desired absent -Action {
                    param($observation)
                    $observation.Found=$true;$observation.Before=''Present'';$observation.Detail=$item.FullName
                    $observation.Step=(T ''проверка границ пути'' ''path boundary validation'')
                    $full = [IO.Path]::GetFullPath($item.FullName)
                    if (-not $full.StartsWith($driveRoot, [StringComparison]::OrdinalIgnoreCase) -or $full.TrimEnd(''\'') -eq $driveRoot.TrimEnd(''\'')) { throw (T ''Путь вне системного диска'' ''Path is outside the system drive'') }
                    $cursor = $full
                    while ($cursor) {
                        $observation.Step=(T "проверка ссылки: $cursor" "link inspection: $cursor")
                        if ((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { $observation.Detail+=(T ''; ссылка файловой системы не удаляется'' ''; filesystem link is not removed'');return ''skipped'' }
                        $cursor = Split-Path $cursor -Parent
                    }
                    Grant-SystemAccess -Path $full -Recurse:$item.PSIsContainer -Observation $observation
                    $observation.Step=(T ''удаление (Remove-Item)'' ''removal (Remove-Item)'')
                    Remove-GuardSelectedPath -Path $full -Directory $item.PSIsContainer -Observation $observation
                    $observation.Step=(T ''проверка после удаления'' ''verification after removal'')
                    if (Test-Path -LiteralPath $full -ErrorAction Stop) { throw (T ''Объект остался после удаления'' ''Object remains after removal'') }
                    $observation.After=''Absent''
                    ''changed''
                }
            }
        }
        $guardComplete=$true
    }
} catch {
    $counts.Failed++
    Write-GuardLog ''ERROR'' $_.Exception.Message
    Add-GuardDetail -Category run -Name (T ''Прерывание проверки'' ''Interrupted check'') -Outcome failed -Found $null -Detail $_.Exception.Message
} finally {
    try {
        if($guardMode -eq ''Standard'' -and -not $guardSkippedOobe){Invoke-GuardPresentation}
        try { Save-GuardReport } catch {$counts.LogFailed++;try{[Console]::Error.WriteLine("[LOG ERROR] Report: $($_.Exception.Message)")}catch{}}
        Write-GuardLog ''END'' (T "Проверено $($counts.Checked); изменено $($counts.Changed); ожидают завершения $($counts.Pending); пропущено $($counts.Skipped); ошибок $($counts.Failed)" "Checked $($counts.Checked); changed $($counts.Changed); pending $($counts.Pending); skipped $($counts.Skipped); errors $($counts.Failed)")
    }
    finally { $runLock.Dispose() }
}
if ($counts.LogFailed) {
    try { [Console]::Error.WriteLine((T "[LOG ERROR] Не записано строк в guard.log: $($counts.LogFailed); строки переданы в stderr (launcher.log при штатном запуске)." "[LOG ERROR] Lines not written to guard.log: $($counts.LogFailed); forwarded to stderr (launcher.log during normal startup).")) } catch { }
}
if ($counts.Failed -or $counts.LogFailed -or $counts.ViewFailed) { exit 1 }
exit 0
'
        }
        'Guard.UI.ps1' {
'#Requires -Version 5.1
# Presentation and task helpers. Dot-sourcing this file does not run the guard.
function Get-GuardMode {
    param($Config)
    if($Config.Mode -in @(''Debug'',''Standard'',''Silent'')){return [string]$Config.Mode}
    ''Standard''
}

function Get-GuardExpectedApps {
    param($Config)
    $known=@(''Microsoft.SecHealthUI'',''Microsoft.Copilot'',''Microsoft.Windows.Ai.Copilot.Provider'',''Clipchamp.Clipchamp'',''Microsoft.BingNews'',''Microsoft.BingWeather'',''Microsoft.GetHelp'',''Microsoft.Getstarted'',''Microsoft.MicrosoftOfficeHub'',''Microsoft.MicrosoftSolitaireCollection'',''Microsoft.WindowsFeedbackHub'',''Microsoft.YourPhone'',''Microsoft.OutlookForWindows'',''MicrosoftTeams'',''MSTeams'')
    if($Config.ExpectedApps){$known=@($Config.ExpectedApps)}
    foreach($name in $known){
        if(@($Config.Protected|Where-Object{$_ -and $name -match $_}).Count){continue}
        if(@($Config.Apps|Where-Object{$_ -and $name -match $_}).Count){$name}
    }
}

function New-GuardViewerAction {
    param([string]$SupportDirectory)
    $powershell=Join-Path $env:SystemRoot ''System32\WindowsPowerShell\v1.0\powershell.exe''
    # Task Scheduler substitutes the worker''s GUID; no intermediate console.
    $arguments=''-NoLogo -NoProfile -ExecutionPolicy Bypass -File "''+(Join-Path $SupportDirectory ''guard.ps1'')+''" -View -RunId "$(Arg0)"''
    New-ScheduledTaskAction -Execute $powershell -Argument $arguments
}

function Register-GuardViewerTask {
    param([string]$SupportDirectory,[ValidateSet(''Debug'',''Standard'',''Silent'')][string]$Mode=''Standard'')
    if($Mode -eq ''Silent''){
        Unregister-ScheduledTask -TaskName ''win-11-lite guard report'' -Confirm:$false -ErrorAction SilentlyContinue
    }else{
        $action=New-GuardViewerAction $SupportDirectory
        $principal=New-ScheduledTaskPrincipal -GroupId ''S-1-5-32-545'' -RunLevel Limited
        $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances Parallel -ExecutionTimeLimit ([TimeSpan]::Zero)
        # Demand start only. The SYSTEM worker opens this task after the OOBE gate.
        Register-ScheduledTask -TaskName ''win-11-lite guard report'' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    }
    Unregister-ScheduledTask -TaskName ''win-11-lite guard debug'' -Confirm:$false -ErrorAction SilentlyContinue
}

function Test-GuardOobeComplete {
    $setup=Get-ItemProperty -LiteralPath ''HKLM:\SYSTEM\Setup'' -ErrorAction Stop
    if($env:USERNAME -eq ''defaultuser0'' -or $setup.OOBEInProgress -eq 1 -or $setup.SystemSetupInProgress -eq 1){return $false}
    if(-not (''Win11Lite.GuardOobe'' -as [type])){
        Add-Type @''
using System.Runtime.InteropServices;
namespace Win11Lite {
    public static class GuardOobe {
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool OOBEComplete([MarshalAs(UnmanagedType.Bool)] out bool complete);
    }
}
''@
    }
    $complete=$false
    [Win11Lite.GuardOobe]::OOBEComplete([ref]$complete) -and $complete
}

function Start-GuardViewer {
    param([string]$SupportDirectory,[guid]$RunId,[ValidateSet(''Debug'',''Standard'',''Silent'')][string]$Mode)
    if($Mode -eq ''Silent'' -or -not (Test-GuardOobeComplete)){return}
    $sessions=@(Get-Process -Name explorer -IncludeUserName -ErrorAction SilentlyContinue |
        Where-Object{$_.SessionId -gt 0 -and $_.UserName -and $_.UserName -notmatch ''\\defaultuser0$''} |
        Select-Object -ExpandProperty SessionId -Unique)
    if(-not $sessions.Count){return}
    $scheduler=New-Object -ComObject ''Schedule.Service''
    $scheduler.Connect()
    $task=$scheduler.GetFolder(''\'').GetTask(''win-11-lite guard report'')
    if(-not $task.Enabled){return}
    foreach($session in $sessions){
        # TASK_RUN_USE_SESSION_ID: run as the logged-on user, never as SYSTEM.
        $null=$task.RunEx($RunId.ToString(),4,[int]$session,$null)
    }
}

function Get-GuardBriefReport {
    param($Report,[bool]$HasHistory)
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add((T ''ИТОГ ПРОВЕРКИ GUARD'' ''GUARD SUMMARY''))
    $lines.Add((T "Проверка: $(([datetime]$Report.Started).ToString(''yyyy-MM-dd HH:mm:ss''))" "Check: $(([datetime]$Report.Started).ToString(''yyyy-MM-dd HH:mm:ss''))"))
    $programs=@($Report.Items|Where-Object{$_.Category -in @(''app'',''provisioned'',''component'') -and -not $_.Inventory -and $_.Outcome -ne ''protected''}|Group-Object Name)
    $programReturned=@($programs|Where-Object{@($_.Group|Where-Object{$_.Reappeared}).Count}).Count
    $programRemoved=@($programs|Where-Object{
        @($_.Group|Where-Object{$_.Reappeared}).Count -and -not @($_.Group|Where-Object{$_.Outcome -notin @(''removed'',''absent'')}).Count
    }).Count
    $settings=@($Report.Items|Where-Object{$_.Category -in @(''setting'',''service'')})
    $settingsReturned=@($settings|Where-Object{$_.Reappeared}).Count
    $settingsFixed=@($settings|Where-Object{$_.Repeated -and $_.Outcome -in @(''disabled'',''stopped'',''set'',''created'')}).Count
    $lines.Add('''')
    $lines.Add((T "Программ под контролем удаления: $($programs.Count)" "Programs monitored for removal: $($programs.Count)"))
    $lines.Add((T "Программы, появившиеся снова: $programReturned" "Programs that reappeared: $programReturned"))
    $lines.Add((T "Программы, успешно удалённые повторно: $programRemoved" "Programs successfully removed again: $programRemoved"))
    $lines.Add('''')
    $lines.Add((T "Настроек и служб под контролем отключения: $($settings.Count)" "Settings and services monitored for disabling: $($settings.Count)"))
    $lines.Add((T "Настройки и службы, сбившиеся или включившиеся снова: $settingsReturned" "Settings and services changed or enabled again: $settingsReturned"))
    $lines.Add((T "Настройки и службы, успешно восстановленные повторно: $settingsFixed" "Settings and services successfully restored again: $settingsFixed"))
    $present=@($programs|Where-Object{@($_.Group|Where-Object{$_.Found -eq $true}).Count}).Count
    $removed=@($programs|Where-Object{@($_.Group|Where-Object{$_.Outcome -eq ''removed''}).Count -and -not @($_.Group|Where-Object{$_.Outcome -notin @(''removed'',''absent'')}).Count}).Count
    $fixed=@($settings|Where-Object{$_.Outcome -in @(''disabled'',''stopped'',''set'',''created'')}).Count
    if($present -or $fixed){$lines.Add((T "Найдено сейчас программ: $present; удалено: $removed; исправлено настроек/служб: $fixed" "Programs found now: $present; removed: $removed; settings/services corrected: $fixed"))}
    foreach($category in ''capability'',''path''){
        $rows=@($Report.Items|Where-Object{$_.Category -eq $category -and -not $_.Inventory})
        $found=@($rows|Where-Object{$_.Found -eq $true}).Count
        $cleared=@($rows|Where-Object{$_.Outcome -eq ''removed''}).Count
        if($found){
            $label=if($category -eq ''path''){T ''Файлы и каталоги'' ''Files and directories''}else{T ''Компоненты Windows'' ''Windows capabilities''}
            $lines.Add((T "${label}: найдено $found; удалено $cleared" "${label}: found $found; removed $cleared"))
        }
    }
    $pending=@($Report.Items|Where-Object{$_.Outcome -eq ''pending''}).Count
    $unchecked=@($Report.Items|Where-Object{$_.Outcome -eq ''not_checked''}).Count
    if($pending){$lines.Add((T "Ожидают завершения удаления: $pending" "Removals still pending: $pending"))}
    if(-not $Report.Complete -or $Report.Deferred -or $unchecked){$lines.Add((T "Проверка не завершена; непроверенных пунктов: $unchecked" "Check is incomplete; unchecked items: $unchecked"))}
    if(-not $HasHistory){$lines.Add((T ''Первый запуск: повторность пока неизвестна; история начинается с этой проверки.'' ''First run: recurrence is not yet known; history starts with this check.''))}
    $lines.Add('''')
    $lines.Add((T "Ошибок проверки: $($Report.Errors); записи: $($Report.LogErrors); показа: $($Report.ViewErrors)." "Check errors: $($Report.Errors); writing errors: $($Report.LogErrors); display errors: $($Report.ViewErrors)."))
    foreach($row in $Report.Items|Where-Object{$_.Outcome -eq ''failed''}){
        $name=if($row.Category -eq ''path''){($row.Name -split ''[\\/]'')[-1]}else{$row.Name}
        if($row.Category -eq ''path'' -and $row.Detail -match ''(?:^|;)\s*Target=([^\r\n;]+)''){
            $leaf=($matches[1] -split ''[\\/]'')[-1]
            if($leaf -and $leaf -ne $name){$name+=" ($leaf)"}
        }
        $reason=switch($row.Category){''path''{T ''ошибка удаления/проверки'' ''removal/check error''} ''service''{T ''ошибка проверки службы'' ''service check error''} ''setting''{T ''ошибка проверки настройки'' ''setting check error''} default{T ''ошибка проверки'' ''check error''}}
        $code=if($row.ErrorCode){$row.ErrorCode}elseif($row.Detail -match ''HRESULT=(0x[0-9A-Fa-f]+)''){$matches[1]}else{''''}
        $lines.Add("  $name — $reason$(if($code){'' (''+$code+'')''})")
    }
    foreach($warning in $Report.Warnings){$lines.Add("! $warning")}
    [pscustomobject]@{
        Text=($lines -join "`r`n")
        Counts=[ordered]@{Programs=$programs.Count;ProgramsReappeared=$programReturned;ProgramsRemovedAgain=$programRemoved;Settings=$settings.Count;SettingsReappeared=$settingsReturned;SettingsRestoredAgain=$settingsFixed;HasHistory=$HasHistory}
    }
}

function Show-GuardView {
    param([string]$SupportDirectory,[ValidateSet(''Debug'',''Standard'',''Silent'')][string]$Mode,[string]$RunId,[int]$WaitSeconds=120)
    if($Mode -eq ''Silent'' -or -not (Test-GuardOobeComplete)){return}
    if($RunId -and $RunId -ne ''$(Arg0)''){$null=[guid]::Parse($RunId)}else{$RunId=''''}
    $Host.UI.RawUI.WindowTitle=''win-11-lite guard - ''+$Mode
    $deadline=(Get-Date).AddSeconds($WaitSeconds)
    $reportPath=Join-Path $SupportDirectory ''guard-report.json''
    if($Mode -eq ''Debug''){
        $marker=Get-Content -LiteralPath (Join-Path $SupportDirectory ''guard-run.json'') -Raw -Encoding UTF8|ConvertFrom-Json
        if($RunId -and $marker.RunId -ne $RunId){throw (T ''Этот запуск уже завершён; откройте последний отчёт из папки guard.'' ''This run has been superseded; open the latest report from the guard folder.'')}
        $log=Join-Path $SupportDirectory ''guard.log''
        $stream=[IO.File]::Open($log,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        try{
            $null=$stream.Seek([long]$marker.LogOffset,[IO.SeekOrigin]::Begin)
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
            try{
                $done=$false;$deadline=(Get-Date).AddMinutes(25)
                while(-not $done){
                    while($null -ne ($line=$reader.ReadLine())){
                        $color=if($line -match ''\[ERROR\]''){''Red''}elseif($line -match ''\[CHANGED\]|\[END\]''){''Green''}else{''Gray''}
                        Write-Host $line -ForegroundColor $color
                        if($line -match ''\[END\]''){$done=$true;break}
                    }
                    if(-not $done){if((Get-Date) -ge $deadline){throw (T ''Истекло время ожидания guard.'' ''Timed out waiting for guard.'')} ;Start-Sleep -Milliseconds 200}
                }
            }finally{$reader.Dispose()}
        }finally{$stream.Dispose()}
    }else{
        while($true){
            $report=$null
            try{if(Test-Path -LiteralPath $reportPath){$report=Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8|ConvertFrom-Json}}catch{}
            if($report -and (-not $RunId -or $report.RunId -eq $RunId)){
                if(-not $report.BriefText){throw (T ''Краткий отчёт ещё не создан. Дождитесь новой проверки guard.'' ''No summary is available yet. Wait for a new guard check.'')}
                Write-Host $report.BriefText
                break
            }
            if((Get-Date) -ge $deadline){throw (T ''Отчёт этого запуска не создан. Проверьте guard.log в папке guard.'' ''No report was created for this run. Check guard.log in the guard folder.'')}
            Start-Sleep -Milliseconds 200
        }
    }
    $null=Read-Host (T ''Нажмите Enter, чтобы закрыть окно'' ''Press Enter to close'')
}
'
        }
        'Run-Setup.ps1' {
'#Requires -Version 5.1
# Standard PowerShell entry point for Windows Setup and scheduled tasks.
param([string]$Mode, [Parameter(ValueFromRemainingArguments=$true)][string[]]$ExtraArguments)
$ErrorActionPreference=''Stop''
$ProgressPreference=''SilentlyContinue''
$logPath=Join-Path $PSScriptRoot ''launcher.log''
function Write-RunnerLog {
    param([string]$Message)
    for($attempt=0;$attempt -lt 5;$attempt++){
        try{[IO.File]::AppendAllText($logPath,"$(Get-Date -Format s) [$Mode] $Message`r`n",[Text.UTF8Encoding]::new($true));return}
        catch [IO.IOException]{Start-Sleep -Milliseconds 50}
        catch [UnauthorizedAccessException]{return} # Limited debug observer can read the support folder.
    }
}
function Test-SetupOobeComplete {
    if(-not (''Win11Lite.RunnerOobe'' -as [type])){
        Add-Type @''
using System.Runtime.InteropServices;
namespace Win11Lite {
    public static class RunnerOobe {
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool OOBEComplete([MarshalAs(UnmanagedType.Bool)] out bool complete);
    }
}
''@
    }
    $complete=$false
    if(-not [Win11Lite.RunnerOobe]::OOBEComplete([ref]$complete)){return $false}
    $complete
}
$entry=switch($Mode){
    ''prepare''          {@{File=''Prepare.ps1'';Arguments=''''}}
    ''prepare-register'' {@{File=''Prepare.ps1'';Arguments=''-RegisterOnly''}}
    ''finalize''         {@{File=''Finalize.ps1'';Arguments=''-FirstLogon''}}
    ''finalize-wait''    {@{File=''Finalize.ps1'';Arguments=''-WaitForOobe''}}
    ''guard''            {@{File=''guard.ps1'';Arguments=''''}}
    ''guard-debug''      {@{File=''guard.ps1'';Arguments=''-ShowDebugWindow''}}
}
if(-not $entry -or $ExtraArguments.Count){Write-RunnerLog ''Unsupported mode'';exit 87}
try{
    $scriptPath=Join-Path $PSScriptRoot $entry.File
    if(-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)){Write-RunnerLog "Script not found: $($entry.File)";exit 2}
    if($Mode -eq ''guard-debug''){
        $deadline=(Get-Date).AddHours(2);$waiting=$false
        while(-not (Test-SetupOobeComplete)){
            if(-not $waiting){Write-RunnerLog ''WAIT OOBE completion before opening the debug viewer'';$waiting=$true}
            if((Get-Date) -ge $deadline){Write-RunnerLog ''OOBE wait timed out'';exit 1460}
            Start-Sleep -Milliseconds 500
        }
    }
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=Join-Path $env:SystemRoot ''System32\WindowsPowerShell\v1.0\powershell.exe''
    $psi.Arguments=''-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "''+$scriptPath+''" ''+$entry.Arguments
    $psi.WorkingDirectory=$PSScriptRoot
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    # Windows PowerShell uses the system OEM code page when its output is redirected.
    $codePage=[int](Get-ItemProperty -LiteralPath ''HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage'' -Name OEMCP).OEMCP
    $psi.StandardOutputEncoding=[Text.Encoding]::GetEncoding($codePage)
    $psi.StandardErrorEncoding=$psi.StandardOutputEncoding
    $process=[Diagnostics.Process]::new();$process.StartInfo=$psi
    try{
        if(-not $process.Start()){throw ''PowerShell did not start''}
        Write-RunnerLog "START PID=$($process.Id)"
        $process.StandardInput.Close()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
        if($output.Trim()){Write-RunnerLog $output.Trim()}
        if($errorText.Trim()){Write-RunnerLog (''STDERR ''+$errorText.Trim())}
        $code=$process.ExitCode;Write-RunnerLog "END ExitCode=$code"
    }finally{$process.Dispose()}
    exit $code
}catch{Write-RunnerLog (''ERROR ''+($_|Out-String).Trim());exit 1}
'
        }
        default { throw (T "Нет встроенного ресурса: $Name" "Bundled resource not found: $Name") }
    }
    $text -replace '\r?\n', "`r`n"
}
#endregion Bundled resources

function Get-BundledResourceHash {
    param([string]$Name)
    $bytes=[Text.Encoding]::UTF8.GetBytes((Get-BundledResource -Name $Name))
    $sha=[Security.Cryptography.SHA256]::Create()
    try{[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}
    finally{$sha.Dispose()}
}

function Get-GuardScript { Get-BundledResource -Name 'guard.ps1' }

function Get-NativeToolVersion {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [version]'0.0' }
    $info = (Get-Item -LiteralPath $Path).VersionInfo
    [version]('{0}.{1}.{2}.{3}' -f $info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart,$info.FilePrivatePart)
}

function Save-DeploymentTools {
    param([string]$Directory, [int]$Build = 28000)
    $catalogHash = Get-BundledResourceHash -Name "deployment-tools-$Build.json"
    $catalog = Get-BundledResource -Name "deployment-tools-$Build.json" | ConvertFrom-Json
    if ($catalog.Schema -ne 1 -or $catalog.Build -ne $Build -or $catalog.Architecture -ne 'amd64') { throw (T 'Некорректный каталог инструментов DISM' 'Invalid DISM tool catalog') }
    $dir = Join-Path $Directory "deployment-tools-$Build"
    $cached = Read-PreparedCache -Directory $dir -Key 'tools'
    if (-not $cached -or $cached.Data.CatalogSHA256 -ne $catalogHash) {
        $downloadDir = Join-Path $dir 'downloads'
        $null = New-Item -ItemType Directory -Path $downloadDir -Force
        $files = @()
        foreach ($archive in $catalog.Archives) {
            $cab = Assert-ChildPath -Path (Join-Path $downloadDir $archive.Name) -Root $downloadDir
            if (Test-Path -LiteralPath $cab) {
                if ((Get-Item -LiteralPath $cab).Length -ne $archive.Size -or (Get-FileHash -LiteralPath $cab -Algorithm SHA256).Hash -ne $archive.SHA256) {
                    Remove-Item -LiteralPath $cab,"$cab.size","$cab.sha256" -Force -ErrorAction SilentlyContinue
                }
            }
            Save-Url -Url $archive.Url -Destination $cab
            if ((Get-Item -LiteralPath $cab).Length -ne $archive.Size -or (Get-FileHash -LiteralPath $cab -Algorithm SHA256).Hash -ne $archive.SHA256) { throw (T "Повреждён архив инструментов: $($archive.Name)" "Tool archive integrity failure: $($archive.Name)") }
            $expanded = Join-Path $downloadDir ($archive.Name + '.files')
            $null = New-Item -ItemType Directory -Path $expanded -Force
            if ((Invoke-NativeQuiet -FilePath "$env:SystemRoot\System32\expand.exe" -Arguments @('-R','-F:*',$cab,$expanded)) -ne 0) { throw (T 'Не удалось распаковать инструменты DISM' 'Could not extract DISM tools') }
            foreach ($entry in $archive.Files) {
                $source = Assert-ChildPath -Path (Join-Path $expanded $entry.Source) -Root $expanded
                $target = Assert-ChildPath -Path (Join-Path $dir $entry.Path) -Root $dir
                if ((Get-Item -LiteralPath $source).Length -ne $entry.Size -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $entry.SHA256) { throw (T "Повреждён файл инструмента: $($entry.Path)" "Tool file integrity failure: $($entry.Path)") }
                $null = New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
                Copy-Item -LiteralPath $source -Destination $target -Force
                $files += $target
            }
        }
        Write-PreparedCache -Directory $dir -Key 'tools' -Files $files -Data @{ CatalogSHA256=$catalogHash }
    }
    $dism = Join-Path $dir 'amd64\DISM\dism.exe'
    $oscdimg = Join-Path $dir 'amd64\Oscdimg\oscdimg.exe'
    if ((Get-NativeToolVersion $dism).Build -lt $Build -or -not (Test-Path -LiteralPath $oscdimg)) { throw (T 'Неполный комплект инструментов обслуживания' 'Incomplete servicing tool set') }
    [pscustomobject]@{ Dism=$dism; Oscdimg=$oscdimg }
}

function Initialize-DeploymentTools {
    param([int]$Build, [string]$Directory, [string]$ExplicitDism, [switch]$Install, [switch]$Preview)
    $minimum = if ($Build -eq 26200) { 26100 } else { $Build }
    $roots = @("${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools", "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools")
    $candidates = @($roots | ForEach-Object { Join-Path $_ 'amd64\DISM\dism.exe' }) + @("$env:SystemRoot\System32\dism.exe")
    $script:Oscdimg = $roots | ForEach-Object { Join-Path $_ 'amd64\Oscdimg\oscdimg.exe' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($ExplicitDism) {
        $script:Dism = (Resolve-Path -LiteralPath $ExplicitDism -ErrorAction Stop).Path
        if ((Get-NativeToolVersion $script:Dism).Build -lt $minimum) { throw (T "Указанный DISM слишком старый: нужен build $minimum или новее" "The specified DISM is too old: build $minimum or newer is required") }
    } else {
        $script:Dism = $candidates | Where-Object { (Get-NativeToolVersion $_).Build -ge $minimum } | Sort-Object { Get-NativeToolVersion $_ } -Descending | Select-Object -First 1
    }
    if ($Build -eq 28000 -and (-not $script:Dism -or (-not $script:Oscdimg -and -not $SkipIso))) {
        if ($Preview) {
            Write-Note (T 'Для 26H1 будет подготовлен отдельный DISM 28000 из ADK (~6.3 МиБ); установленный ADK сохраняется.' '26H1 will use a separate DISM 28000 from the ADK (about 6.3 MiB); the installed ADK is retained.')
            return
        }
        Write-Step (T 'Подготовка DISM 28000 и oscdimg для 26H1' 'Preparing DISM 28000 and oscdimg for 26H1')
        $tools = Save-DeploymentTools -Directory $Directory -Build 28000
        if (-not $script:Dism) { $script:Dism = $tools.Dism }
        if (-not $script:Oscdimg) { $script:Oscdimg = $tools.Oscdimg }
    }
    if ((-not $script:Dism -or (-not $script:Oscdimg -and -not $SkipIso)) -and $Install -and -not $Preview) {
        $setup = Join-Path $Directory 'adksetup-26100.exe'
        Save-Url -Url 'https://go.microsoft.com/fwlink/?linkid=2289980' -Destination $setup
        $code = Invoke-NativeQuiet -FilePath $setup -Arguments @('/quiet','/norestart','/features','OptionId.DeploymentTools')
        if (-not (Test-DismSuccess $code)) { throw (T "Установка ADK завершилась с кодом $code" "ADK installation exited with code $code") }
        Initialize-DeploymentTools -Build $Build -Directory $Directory -ExplicitDism $ExplicitDism
        return
    }
    if (-not $script:Dism -or (-not $script:Oscdimg -and -not $SkipIso)) {
        $message = T "Нужны DISM build $minimum или новее и oscdimg. Установите Deployment Tools из ADK или используйте -InstallAdk; путь к DISM можно задать через -DismPath." "DISM build $minimum or newer and oscdimg are required. Install ADK Deployment Tools or use -InstallAdk; specify a DISM path with -DismPath."
        if ($Preview) { Write-Note $message; return }
        throw $message
    }
    Write-Ok (T "DISM: $script:Dism ($(Get-NativeToolVersion $script:Dism))" "DISM: $script:Dism ($(Get-NativeToolVersion $script:Dism))")
}

function Ensure-WimMountDriver {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\WIMMount'
    if ((Test-Path $key) -and (Get-ItemProperty $key -Name ImagePath -ErrorAction SilentlyContinue).ImagePath) { return }
    $setup = Join-Path (Split-Path $script:Dism -Parent) 'WimMountAdkSetupAmd64.exe'
    if (-not (Test-Path -LiteralPath $setup)) { throw (T 'Не найден WIMMount. Установите Deployment Tools из Windows ADK.' 'WIMMount was not found. Install Windows ADK Deployment Tools.') }
    $code = Invoke-NativeQuiet -FilePath $setup -Arguments @('/Install')
    if (-not (Test-DismSuccess $code) -or -not (Test-Path $key)) { throw (T "Не удалось зарегистрировать WIMMount (код $code)" "Could not register WIMMount (exit code $code)") }
}

function Get-SetupRunnerScript {
    if($Guard){$null=Get-BundledResource 'guard.ps1';$null=Get-BundledResource 'Guard.UI.ps1'}
    Get-BundledResource -Name 'Run-Setup.ps1'
}
function Get-SetupSupportScripts {
    param([bool]$BlockNetwork, [bool]$RemoveEdge, [bool]$EnableGuard, [bool]$ManageOobe = $true, [string]$Language = 'en-US', [bool]$ShowGuardWindow = $true, [ValidateSet('Debug','Standard','Silent')][string]$GuardMode='Standard')
    if($PSBoundParameters.ContainsKey('ShowGuardWindow') -and -not $ShowGuardWindow){$GuardMode='Silent'}
    $prepare = @'
#Requires -Version 5.1
param([switch]$RegisterOnly)
$ErrorActionPreference = 'Stop'
function T { param([string]$Ru, [string]$En) if ('__LANG__' -like 'ru*') { $Ru } else { $En } }
$log = Join-Path $PSScriptRoot 'prepare.log'
function Write-PrepareLog {
    param([string]$Message)
    try { "$(Get-Date -Format s) $Message" | Add-Content -LiteralPath $log -Encoding UTF8 }
    catch { Write-Warning $Message }
}
Write-PrepareLog (T "START: RegisterOnly=$RegisterOnly; пользователь=$env:USERNAME" "START: RegisterOnly=$RegisterOnly; user=$env:USERNAME")
# The answer file calls Finalize.ps1 directly at the first real user logon.
# Scheduler availability during specialize must not prevent network blocking.
if (__NETWORK__ -and -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'oobe-complete'))) {
    # Блок действует и для интерфейсов, которые PnP добавит после specialize.
    # SetupComplete повторяет проверку: RegisterOnly больше не пропускает сеть.
    $firewallName = 'Win11Lite-OOBE-Temporary-Outbound-Block'
    $firewallReady = $false
    try {
        $rule = Get-NetFirewallRule -Name $firewallName -PolicyStore PersistentStore -ErrorAction SilentlyContinue
        if ($rule) {
            Set-NetFirewallRule -Name $firewallName -PolicyStore PersistentStore -Enabled True -Direction Outbound -Action Block -Profile Any | Out-Null
        } else {
            New-NetFirewallRule -Name $firewallName -DisplayName $firewallName -PolicyStore PersistentStore -Enabled True -Direction Outbound -Action Block -Profile Any | Out-Null
        }
        $firewallReady = $true
        Write-PrepareLog (T 'OOBE: временная блокировка исходящей сети включена' 'OOBE: temporary outbound network block enabled')
    } catch {
        Write-PrepareLog (T "OOBE: блокировка брандмауэра недоступна: $($_.Exception.Message); проверяю адаптеры" "OOBE: firewall block unavailable: $($_.Exception.Message); checking adapters")
    }
    $statePath = Join-Path $PSScriptRoot 'network-state.clixml'
    $saved = @()
    if (Test-Path -LiteralPath $statePath) { $saved = @(Import-Clixml -LiteralPath $statePath) }
    $allAdapters = @()
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        try { $allAdapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop) }
        catch {
            if ($attempt -eq 14) {
                Write-PrepareLog (T "OOBE: ошибка получения адаптеров: $($_.Exception.Message)" "OOBE: adapter enumeration failed: $($_.Exception.Message)")
                if ($firewallReady) { break }
                throw
            }
        }
        if ($allAdapters.Count) { break }
        if ($attempt -lt 14) { Start-Sleep -Seconds 1 }
    }
    $adapters = @($allAdapters | Where-Object { [string]$_.AdminStatus -in @('Up', '1') })
    $saved = @(@($saved) + @($adapters | Select-Object InterfaceGuid) | Sort-Object InterfaceGuid -Unique)
    Export-Clixml -LiteralPath $statePath -InputObject $saved
    foreach ($adapter in $adapters) { $adapter | Disable-NetAdapter -Confirm:$false }
    foreach ($adapter in $adapters) { Write-PrepareLog (T "OOBE: отключён $($adapter.Name), GUID=$($adapter.InterfaceGuid)" "OOBE: disabled $($adapter.Name), GUID=$($adapter.InterfaceGuid)") }
    $changedIds = @($adapters | ForEach-Object { [string]$_.InterfaceGuid })
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $remaining = @(Get-NetAdapter -IncludeHidden | Where-Object { [string]$_.InterfaceGuid -in $changedIds -and [string]$_.AdminStatus -in @('Up','1') })
        if (-not $remaining.Count) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($remaining.Count) {
        $message = T 'Не все адаптеры отключены для OOBE' 'Some adapters remain enabled for OOBE'
        Write-PrepareLog $message
        throw $message
    }
    Write-PrepareLog (T "OOBE: отключено адаптеров $($adapters.Count); сохранено для восстановления $($saved.Count)" "OOBE: $($adapters.Count) adapters disabled; $($saved.Count) saved for restoration")
    if (-not $allAdapters.Count) {
        if (-not $firewallReady) { throw (T 'OOBE: нет доступных адаптеров и не удалось установить сетевой блок; отключение сети не подтверждено' 'OOBE: no adapters are available and firewall blocking failed; network isolation is unconfirmed') }
        Write-PrepareLog (T 'OOBE: адаптеры пока не появились; остаётся временный сетевой блок, SetupComplete повторит проверку' 'OOBE: no adapters have appeared yet; temporary network block remains and SetupComplete will retry')
    }
}
try {
$taskName = 'win-11-lite finalize'
$exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$runnerArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}\Run-Setup.ps1" -Mode ' -f $PSScriptRoot
$action = New-ScheduledTaskAction -Execute $exe -Argument ($runnerArguments + 'finalize-wait')
$trigger = New-ScheduledTaskTrigger -AtLogOn
$trigger.Delay = 'PT30S'
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
$finalizeSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 3)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $finalizeSettings -Force | Out-Null
if (__GUARD__) {
    $guardAction = New-ScheduledTaskAction -Execute $exe -Argument ($runnerArguments + 'guard')
    Register-ScheduledTask -TaskName 'win-11-lite guard' -Action $guardAction -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    . (Join-Path $PSScriptRoot 'Guard.UI.ps1')
    $viewerMode='__GUARDMODE__'
    $guardConfigPath=Join-Path $PSScriptRoot 'guard.json'
    if(Test-Path -LiteralPath $guardConfigPath){$viewerMode=Get-GuardMode (Get-Content -LiteralPath $guardConfigPath -Raw|ConvertFrom-Json)}
    Register-GuardViewerTask -SupportDirectory $PSScriptRoot -Mode $viewerMode
}
Write-PrepareLog (T 'Задачи первого входа зарегистрированы' 'First-logon tasks registered')
} catch {
    Write-PrepareLog (T "Планировщик недоступен: $($_.Exception.Message)" "Task Scheduler unavailable: $($_.Exception.Message)")
    if (-not __OOBE__) { throw }
    Write-PrepareLog (T 'Завершение установки выполнит FirstLogonCommands' 'FirstLogonCommands will finalize setup')
}
'@
    $finalize = @'
#Requires -Version 5.1
param([switch]$EdgeOnly, [switch]$FirstLogon, [switch]$WaitForOobe, [ValidateRange(1,86400)][int]$WaitSeconds = 7200)
$ErrorActionPreference = 'Stop'
function T { param([string]$Ru, [string]$En) if ('__LANG__' -like 'ru*') { $Ru } else { $En } }
$log = Join-Path $PSScriptRoot 'finalize.log'
function Write-FinalizeLog {
    param([string]$Message)
    try { "$(Get-Date -Format s) $Message" | Add-Content -LiteralPath $log -Encoding UTF8 }
    catch { Write-Warning $Message }
}
function Test-OobeComplete {
    try {
    if (-not ('Win11Lite.OobeStatus' -as [type])) {
        Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
namespace Win11Lite {
    public static class OobeStatus {
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool OOBEComplete([MarshalAs(UnmanagedType.Bool)] out bool complete);
    }
}
"@
    }
    $complete = $false
    if (-not [Win11Lite.OobeStatus]::OOBEComplete([ref]$complete)) {
        throw (T "Не удалось проверить окончание OOBE: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" "Could not query OOBE completion: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())")
    }
    return $complete
    } catch {
        if ($script:OobeProbeError -ne $_.Exception.Message) {
            Write-FinalizeLog (T "WAIT: состояние OOBE недоступно: $($_.Exception.Message)" "WAIT: OOBE state unavailable: $($_.Exception.Message)")
        }
        $script:OobeProbeError = $_.Exception.Message
        return $false
    }
}
Write-FinalizeLog (T "START: FirstLogon=$FirstLogon; WaitForOobe=$WaitForOobe; EdgeOnly=$EdgeOnly; пользователь=$env:USERNAME" "START: FirstLogon=$FirstLogon; WaitForOobe=$WaitForOobe; EdgeOnly=$EdgeOnly; user=$env:USERNAME")
if (-not $EdgeOnly) {
    if ($env:USERNAME -match '^defaultuser\d+$') { Write-FinalizeLog (T 'SKIP: временный пользователь OOBE' 'SKIP: temporary OOBE user'); return }
    $complete = Test-OobeComplete
    if (-not $complete -and $WaitForOobe) {
        Write-FinalizeLog (T 'WAIT: OOBE ещё выполняется, сеть остаётся заблокирована' 'WAIT: OOBE is still running; network remains blocked')
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        while (-not (Test-OobeComplete)) {
            if ((Get-Date) -ge $deadline) { throw (T 'Истекло ожидание OOBE; задача сохранена для следующего входа' 'OOBE wait timed out; task retained for next logon') }
            Start-Sleep -Seconds 2
        }
    } elseif (-not $complete) {
        Write-FinalizeLog (T 'WAIT: первый вход ещё не подтверждает окончание OOBE' 'WAIT: first logon does not yet confirm OOBE completion')
        if ($FirstLogon) {
            # Не удерживаем FirstLogonCommands: это может задержать открытие рабочего стола.
            $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}\Run-Setup.ps1" -Mode finalize-wait' -f $PSScriptRoot) | Out-Null
        }
        return
    }
    Write-FinalizeLog 'OOBEComplete=True'
}
# The logon task and FirstLogonCommands may start together; allow one finalizer.
try { $finalizeLock = [IO.File]::Open((Join-Path $PSScriptRoot 'finalize.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
catch [IO.IOException] { return }
try {
$failed = $false
if (-not $EdgeOnly -and __OOBE__) {
    # Поздний SetupComplete не должен снова отключать сеть после завершения OOBE.
    try { Set-Content -LiteralPath (Join-Path $PSScriptRoot 'oobe-complete') -Value (Get-Date -Format o) -Encoding ascii }
    catch { $failed = $true; Write-FinalizeLog (T "Не удалось записать окончание OOBE: $($_.Exception.Message)" "Could not record OOBE completion: $($_.Exception.Message)") }
}
try {
    if (__EDGE__) {
        # EdgeUpdate/WebView2 and their shared EdgeCore files are preserved.
        foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Select-Object -Unique) {
            if (-not $programRoot) { continue }
            $browser = [IO.Path]::GetFullPath((Join-Path $programRoot 'Microsoft\Edge'))
            if (-not $browser.StartsWith(([IO.Path]::GetFullPath($programRoot).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw (T 'Неверный путь Edge' 'Invalid Edge path') }
            if (Test-Path -LiteralPath $browser) {
                $cursor = $browser
                while ($cursor) {
                    if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw (T "Обнаружена ссылка файловой системы: $cursor" "Reparse point: $cursor") }
                    $cursor = Split-Path $cursor -Parent
                }
                Get-Process -Name msedge -ErrorAction SilentlyContinue | Where-Object {
                    $_.Path -and $_.Path.StartsWith("$browser\", [StringComparison]::OrdinalIgnoreCase)
                } | Stop-Process -Force
                & {
                    # takeown/icacls write to stderr; under PowerShell 5.1 with Stop that would throw before Remove-Item.
                    $ErrorActionPreference = 'Continue'
                    & takeown.exe /F $browser /A /R /D Y *> $null
                    & icacls.exe $browser /grant '*S-1-5-18:(OI)(CI)F' /T /C /Q *> $null
                }
                Remove-Item -LiteralPath $browser -Recurse -Force
                if (Test-Path -LiteralPath $browser) { throw (T "Не удалось удалить Edge: $browser" "Edge removal failed: $browser") }
            }
        }
        $stable = '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
        foreach ($view in @('SOFTWARE', 'SOFTWARE\WOW6432Node')) {
            foreach ($suffix in @("Microsoft\EdgeUpdate\Clients\$stable", "Microsoft\EdgeUpdate\ClientState\$stable", "Microsoft\EdgeUpdate\ClientStateMedium\$stable", 'Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge', 'Microsoft\Windows\CurrentVersion\App Paths\msedge.exe', 'Clients\StartMenuInternet\Microsoft Edge')) {
                $key = "HKLM:\$view\$suffix"
                if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force }
            }
        }
        $shortcuts = @((Join-Path $env:PUBLIC 'Desktop\Microsoft Edge.lnk'), (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk'))
        foreach ($profile in Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath }) {
            $shortcuts += Join-Path $profile.LocalPath 'Desktop\Microsoft Edge.lnk'
        }
        foreach ($shortcut in $shortcuts) { if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force } }
    }
} catch {
    $failed = $true
    "$(Get-Date -Format s) $($_.Exception.Message)" | Add-Content -LiteralPath $log -Encoding UTF8
} finally {
    # Always restore connectivity, even if optional cleanup failed.
    if (-not $EdgeOnly -and __OOBE__) {
    try {
        $statePath = Join-Path $PSScriptRoot 'network-state.clixml'
        if (Test-Path -LiteralPath $statePath) {
            $saved = @(Import-Clixml -LiteralPath $statePath)
            foreach ($adapter in Get-NetAdapter -IncludeHidden) {
                if ([string]$adapter.InterfaceGuid -in @($saved | ForEach-Object { [string]$_.InterfaceGuid })) {
                    $adapter | Enable-NetAdapter -Confirm:$false
                    Write-FinalizeLog (T "Сеть: включён GUID=$($adapter.InterfaceGuid)" "Network: enabled GUID=$($adapter.InterfaceGuid)")
                }
            }
            Remove-Item -LiteralPath $statePath -Force
        }
    } catch {
        $failed = $true
        Write-FinalizeLog (T "Ошибка возврата адаптеров: $($_.Exception.Message)" "Adapter restoration failed: $($_.Exception.Message)")
    }
    # Независимо от отказа отдельного адаптера снимаем только собственный сетевой блок.
    if (__NETWORK__) {
    try {
        $firewallName = 'Win11Lite-OOBE-Temporary-Outbound-Block'
        # Не путать недоступность провайдера с отсутствием правила.
        $rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object { $_.Name -eq $firewallName })
        if ($rules.Count) {
            Remove-NetFirewallRule -Name $firewallName -PolicyStore PersistentStore -ErrorAction Stop
            Write-FinalizeLog (T 'Сеть: временная блокировка брандмауэра снята' 'Network: temporary firewall block removed')
        }
    } catch {
        $failed = $true
        Write-FinalizeLog (T "Ошибка снятия сетевого блока: $($_.Exception.Message)" "Network block removal failed: $($_.Exception.Message)")
    }
    }
    try {
        foreach ($entry in @(
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', 'NoAutoUpdate'),
            @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', 'DoNotConnectToWindowsUpdateInternetLocations'),
            @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE', 'DisableOOBEUpdate')
        )) {
            if (Get-ItemProperty -LiteralPath $entry[0] -Name $entry[1] -ErrorAction SilentlyContinue) {
                Remove-ItemProperty -LiteralPath $entry[0] -Name $entry[1]
            }
        }
    } catch {
        $failed = $true
        "$(Get-Date -Format s) $(T 'Ошибка восстановления' 'Restore failed'): $($_.Exception.Message)" | Add-Content -LiteralPath $log -Encoding UTF8
    }
    }
}
if (-not $failed -and -not $EdgeOnly) {
    "$(Get-Date -Format s) $(T 'Завершение установки выполнено' 'Finalization completed')" | Add-Content -LiteralPath $log -Encoding UTF8
    Unregister-ScheduledTask -TaskName 'win-11-lite finalize' -Confirm:$false -ErrorAction SilentlyContinue
}
} finally { $finalizeLock.Dispose() }
if ($failed) { exit 1 }
'@
    $prepare = $prepare.Replace('__NETWORK__', ('$' + $BlockNetwork.ToString().ToLowerInvariant())).Replace('__GUARD__', ('$' + $EnableGuard.ToString().ToLowerInvariant())).Replace('__GUARDMODE__', $GuardMode).Replace('__OOBE__', ('$' + $ManageOobe.ToString().ToLowerInvariant())).Replace('__LANG__', $Language)
    $finalize = $finalize.Replace('__EDGE__', ('$' + $RemoveEdge.ToString().ToLowerInvariant())).Replace('__NETWORK__', ('$' + $BlockNetwork.ToString().ToLowerInvariant())).Replace('__OOBE__', ('$' + $ManageOobe.ToString().ToLowerInvariant())).Replace('__LANG__', $Language)
    @{ Prepare = $prepare; Finalize = $finalize }
}

function Get-LanguageRepairUpdate {
    param([string]$Revision, [string]$Destination)
    # Verified against the release notes; do not guess KB numbers from file size.
    $known = @{ '26100.1742' = 'KB5043080' }
    $kb = $known[$Revision]
    if (-not $kb) {
        throw (T "Языковым ресурсам нужно повторное применение LCU ($Revision). Задайте -LanguageUpdatePath <MSU> или -WithUpdates, либо возьмите исходный ISO на нужном языке." "Language resources require the source LCU again ($Revision). Supply -LanguageUpdatePath <MSU> or -WithUpdates, or use a native language ISO.")
    }
    Save-CatalogPayload -Query "$kb x64" -Directory (Join-Path $Destination "language-repair-$Revision") -TitlePattern "Windows 11.*$kb.*x64|Windows 11.*x64.*$kb" -CacheFirst
}

# Скачивание языковых пакетов через каталог UUP. Сами файлы лежат на CDN
# Microsoft; uupdump.net используется только чтобы получить ссылки и хэши.
function Save-LanguageFromCatalog {
    param(
        [Parameter(Mandatory)][string[]]$Tags,
        [Parameter(Mandatory)][int]$Build,
        [Parameter(Mandatory)][string]$Destination,
        # Полная ревизия образа, например 26100.1742
        [string]$Revision
    )
    if ($script:DownloadsClosed) { throw (T 'Подготовка загрузок уже завершена' 'Download preparation is already complete') }
    $null = New-Item -ItemType Directory -Path $Destination -Force
    $Tags = @($Tags | Where-Object {
        $ready = Read-PreparedCache -Directory $Destination -Key "language-$_-$Revision"
        if ($ready) { Write-Ok (T "Язык $_ — полный комплект в кэше" "Language $_ - complete set cached") }
        -not $ready
    })
    if (-not $Tags.Count) { return }

    Write-Step (T "Ищу сборку $Build в каталоге обновлений" "Looking for build $Build in the update catalog")
    $list = Invoke-RestMethod -Uri "https://api.uupdump.net/listid.php?search=$Build" -TimeoutSec 60
    $candidates = @($list.response.builds.PSObject.Properties | ForEach-Object { $_.Value } |
                    Where-Object { $_.arch -eq 'amd64' -and $_.title -match 'Windows 11' -and $_.build -match "^$Build\." })
    if (-not $candidates) { throw (T "В каталоге нет клиентских сборок Windows 11 для $Build" "The catalog has no Windows 11 client builds for $Build") }

    # Ревизия каталога ограничивает выбор источника, но сам LP обычно baseline
    # (например 26100.1 даже в UUP 26100.1742). После LP повторно применяем LCU.
    $sorted = @($candidates | Sort-Object { [version]($_.build -replace '[^\d\.]', '') } -Descending)
    $target = $null
    if ($Revision) {
        $target = $sorted | Where-Object { $_.build -eq $Revision } | Select-Object -First 1
        if (-not $target) {
            $rv = [version]$Revision
            $target = $sorted | Where-Object { [version]($_.build -replace '[^\d\.]', '') -le $rv } | Select-Object -First 1
            if ($target) {
                Write-Note (T "Ревизии $Revision в каталоге нет — беру ближайшую младшую $($target.build)" `
                              "Revision $Revision is not in the catalog - taking the closest lower one, $($target.build)")
            }
        }
    }
    if (-not $target) {
        throw (T "Нет совместимого источника языка для $Revision. Задайте -LanguageSource с соответствующим ISO Languages and Optional Features." "No compatible language source for $Revision. Use -LanguageSource with matching Languages and Optional Features media.")
    }
    Write-Ok (T "Источник: $($target.title)" "Source: $($target.title)")

    # Только основной пакет и базовые возможности языка: рукописный ввод, OCR,
    # распознавание и синтез речи мы вырезаем и для исходного языка образа
    $kinds = @('Pack', 'Basic')

    foreach ($tag in $Tags) {
        $lang = $tag.ToLower()
        Write-Step (T "Запрашиваю файлы для $tag" "Requesting files for $tag")
        $info = Invoke-RestMethod -Uri "https://api.uupdump.net/get.php?id=$($target.uuid)&lang=$lang&edition=professional" -TimeoutSec 90
        if (-not $info.response.files) { throw (T "Нет файлов языка $tag" "No language files for $tag") }

        $entries = @($info.response.files.PSObject.Properties)
        $languageFiles = @()
        foreach ($kind in $kinds) {
            $pattern = Get-LanguagePattern -Tag $tag -Kind $kind
            $hit = $entries | Where-Object { $_.Name -match $pattern } | Select-Object -First 1
            if (-not $hit) {
                throw (T "Отсутствует обязательный пакет $kind для $tag" "Required language package $kind for $tag is missing")
            }
            if ([IO.Path]::GetFileName($hit.Name) -ne $hit.Name) { throw (T 'Неверное имя скачиваемого файла' 'Invalid download filename') }
            if (-not $hit.Value.sha256) { throw (T "Нет SHA256 для $($hit.Name)" "No SHA256 for $($hit.Name)") }
            $dest = Join-Path $Destination $hit.Name
            $languageFiles += $dest
            if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -eq $hit.Value.size -and
                (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -eq $hit.Value.sha256) {
                Write-Ok (T "  $($hit.Name) — уже в кэше" "  $($hit.Name) - already cached")
                continue
            }
            Write-Step (T "  Загрузка $($hit.Name) ($(Format-Size $hit.Value.size)) ..." "  Downloading $($hit.Name) ($(Format-Size $hit.Value.size)) ...")
            # Неверный файл не должен пройти проверку Save-Url по старой .size.
            Remove-Item -LiteralPath "$dest.size" -Force -ErrorAction SilentlyContinue
            Save-Url -Url $hit.Value.url -Destination $dest
            if ((Get-Item -LiteralPath $dest).Length -ne $hit.Value.size) {
                Remove-Item -LiteralPath $dest, "$dest.size" -Force
                throw (T "Размер $($hit.Name) не совпал" "Size mismatch for $($hit.Name)")
            }
            if ($hit.Value.sha256) {
                $actual = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
                if ($actual -ne $hit.Value.sha256.ToUpper()) {
                    Remove-Item -LiteralPath $dest, "$dest.size" -Force
                    throw (T "Контрольная сумма $($hit.Name) не совпала — файл удалён" "Checksum mismatch for $($hit.Name) - file deleted")
                }
            }
            Write-Ok (T "  $($hit.Name) — загружено, SHA-256 совпал" "  $($hit.Name) - downloaded, SHA-256 matches")
        }
        Write-PreparedCache -Directory $Destination -Key "language-$tag-$Revision" -Files $languageFiles -Data @{ Revision = $Revision; Tag = $tag }
    }
}

#endregion

#region ── Работа с offline-реестром ────────────────────────────────────────────

$script:LoadedHives = @()

function Invoke-RegCommand {
    param([string[]]$Arguments)
    # Windows PowerShell 5.1 превращает stderr в ErrorRecord. Захватываем его
    # вместе с stdout, а ошибку определяем по коду reg.exe в вызывающей функции.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $output = @(& reg.exe @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{
        ExitCode = $exitCode
        Output = (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
    }
}

function Mount-Hive {
    param([string]$Name, [string]$File)
    if (-not (Test-Path -LiteralPath $File)) { throw (T "Куст реестра не найден: $File" "Registry hive not found: $File") }
    $result = Invoke-RegCommand -Arguments @('load', "HKLM\$Name", $File)
    if ($result.ExitCode -ne 0) {
        throw (T "reg load HKLM\$Name не удался (код $($result.ExitCode)): $($result.Output)" "reg load HKLM\$Name failed (code $($result.ExitCode)): $($result.Output)")
    }
    $script:LoadedHives += $Name
}

function Dismount-Hives {
    if (-not $script:LoadedHives.Count) { return }
    # Открытые дескрипторы реестра мешают выгрузке — освобождаем их один раз до цикла
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    foreach ($name in @($script:LoadedHives)) {
        $result = Invoke-RegCommand -Arguments @('unload', "HKLM\$name")
        if ($result.ExitCode -eq 0) {
            $script:LoadedHives = @($script:LoadedHives | Where-Object { $_ -ne $name })
        } else {
            Write-Fail (T "Не удалось выгрузить куст HKLM\$name — образ может остаться заблокированным (код $($result.ExitCode)): $($result.Output)" "Failed to unload hive HKLM\$name - the image may stay locked (code $($result.ExitCode)): $($result.Output)")
        }
    }
}

function Set-Reg {
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    $regArgs = @('add', $Path, '/f')
    if ($Name) { $regArgs += @('/v', $Name) } else { $regArgs += '/ve' }
    $regArgs += @('/t', $Type, '/d', "$Value")
    $result = Invoke-RegCommand -Arguments $regArgs
    if ($result.ExitCode -ne 0) {
        throw (T "reg add $Path\$Name завершился ошибкой (код $($result.ExitCode)): $($result.Output)" "reg add $Path\$Name failed (code $($result.ExitCode)): $($result.Output)")
    }
}

# Отсутствующий ключ — штатная ситуация, поэтому код возврата не проверяется.
function Remove-Reg {
    param([string]$Path)
    $null = Invoke-RegCommand -Arguments @('delete', $Path, '/f')
}

#endregion

#region ── Стадия 0. Preflight ─────────────────────────────────────────────────

$script:FreedBytes = 0
$script:DownloadsClosed = $false
$script:SkippedDownloads = @()
$script:WorkPrepared = $false
$script:Mounted = $false
$script:BootMounted = $false
$script:IsoMounted = $null
$script:LangIso = $null
# --- права администратора ---
# Спрашиваем права до диалога: иначе человек ответит на вопросы, а окно закроется
if (-not $DryRun -and -not (Test-Admin)) {
    if ($Elevated) {
        Write-Host ''
        Write-Host (T '  Права администратора не получены даже после перезапуска.' '  Administrator rights were not granted even after restart.') -ForegroundColor Red
        Wait-BeforeExit
        exit 1
    }
    Restart-Elevated -Parameters $PSBoundParameters
    exit 0
}

# --- диалог настройки ---
if ($script:WizardMode) {
    if (-not (Test-CanPrompt)) {
        throw (T 'Скрипт запущен без параметров, но спросить ничего нельзя (ввод перенаправлен). Передайте параметры явно, см. Get-Help .\win-11-lite.ps1 -Full' 'The script was started without parameters but cannot ask anything (input is redirected). Pass parameters explicitly, see Get-Help .\win-11-lite.ps1 -Full')
    }

    Write-Host ''
    Write-Host '╔══════════════════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host (T '║                     win-11-lite — настройка сборки                       ║' '║                       win-11-lite — build settings                      ║') -ForegroundColor Cyan
    Write-Host '╚══════════════════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
    Write-Host (T '  Enter оставляет значение по умолчанию (отмечено звёздочкой).' '  Enter keeps the default value (marked with an asterisk).') -ForegroundColor DarkGray

    # 1. Исходный образ
    if (-not $InputIso) { $InputIso = Select-InputIso }
    if (-not (Test-Path -LiteralPath $InputIso)) { throw (T "Файл не найден: $InputIso" "File not found: $InputIso") }
    $InputIso = (Resolve-Path -LiteralPath $InputIso).Path

    # 2. Редакция внутри образа
    Write-Host ''
    Write-Host (T '  Читаю образ...' '  Reading the image...') -ForegroundColor DarkGray
    $editions = Get-IsoEditions -Path $InputIso
    $wizardLang = 'en-US'
    if ($editions.Count -gt 1) {
        $items = $editions | ForEach-Object { "{0,-46} {1}" -f $_.Name, $_.EditionId }
        $pick = Read-Option -Question (T 'Какую редакцию собирать' 'Which edition should I build') -Items $items -Values ($editions.Index) -Default ([Math]::Min(2, $editions.Count))
        $Index = [int]$pick
        $wizardLang = ($editions | Where-Object { $_.Index -eq $Index }).Languages -replace ',.*', ''
    } elseif ($editions.Count -eq 1) {
        $Index = [int]$editions[0].Index
        $wizardLang = $editions[0].Languages -replace ',.*', ''
        Write-Host (T "  В образе одна редакция: $($editions[0].Name) ($($editions[0].EditionId))" "  The image has a single edition: $($editions[0].Name) ($($editions[0].EditionId))") -ForegroundColor Gray
    }

    $wizardImage = $editions | Where-Object { [int]$_.Index -eq $Index } | Select-Object -First 1
    if ($wizardImage) {
        $account = Read-LocalAccountOptions -Build ([version]$wizardImage.Version).Build -EditionId $wizardImage.EditionId -Mode $AccountMode -Name $LocalUserName -Password $LocalUserPassword -Preview:$DryRun
        $AccountMode=$account.Mode; $LocalUserName=$account.Name; $LocalUserPassword=$account.Password
    }

    # 3. Рабочая папка
    Write-Host ''
    $defaultWork = $WorkDir
    $WorkDir = Read-PathOrDefault -Question (T 'Рабочая папка для сборки (нужно ~30 ГБ)' 'Work folder for the build (about 30 GB needed)') -Default $defaultWork
    $script:WorkDirExplicit = $true

    # 4. Глубина чистки
    $Preset = Read-Option -Question (T 'Насколько глубоко чистить' 'How aggressively should I clean') -Default 2 `
        -Items @(
            (T 'safe      — только Edge, телеметрия и реклама' 'safe      - Edge, telemetry and ads only'),
            (T 'balanced  — плюс Defender, речь, Media Player, AI-компоненты' 'balanced  - plus Defender, speech, Media Player, AI components'),
            (T 'max       — плюс WebView2, резервы компонентов и дополнительные FoD; возможна потеря совместимости' 'max       - plus WebView2, component backups and extra FoDs; compatibility may be lost')
        ) -Values @('safe', 'balanced', 'max')

    # 5. Сторож — идёт сразу за глубиной чистки: он существует ровно для того,
    # чтобы вырезанное не вернулось, и без него чистка постепенно откатывается
    Write-Host ''
    Write-Host (T '  Windows Update со временем возвращает часть удалённого — Edge, Defender,' '  Windows Update eventually restores some of what was removed - Edge, Defender,') -ForegroundColor DarkGray
    Write-Host (T '  AI-компоненты — и сбрасывает политики обратно. Сторож встраивается в образ' '  AI components - and resets the policies. The guard is embedded into the image') -ForegroundColor DarkGray
    Write-Host (T '  и при каждом входе в систему тихо удаляет их снова и возвращает настройки.' '  and at every logon quietly removes them again and restores the settings.') -ForegroundColor DarkGray
    $Guard = Read-YesNo -Question (T 'Встроить сторож в образ?' 'Embed the guard into the image?') -Default $true
    if($Guard){
        $GuardMode=Read-Option -Question (T 'Режим работы guard' 'Guard mode') -Items @(
            (T 'Стандарт — только итоговый отчёт и ошибки' 'Standard - summary and errors only'),
            (T 'Debug — полный живой журнал' 'Debug - full live log'),
            (T 'Тихий — без окна, отчёты в папке guard' 'Silent - no window, reports in the guard folder')
        ) -Values @('Standard','Debug','Silent') -Default ([array]::IndexOf(@('standard','debug','silent'),$GuardMode.ToLowerInvariant())+1)
    }

    # 6. Язык — спрашиваем, только если образ англоязычный
    if ($wizardLang -like 'en-*') {
        Write-Host ''
        Write-Host (T "  Образ на языке $wizardLang." "  The image language is $wizardLang.") -ForegroundColor Gray
        if (Read-YesNo -Question (T 'Добавить другой язык интерфейса?' 'Add another display language?') -Default $false) {
            $langNames = @(
                (T 'Русский (ru-RU)' 'Russian (ru-RU)'), (T 'Українська (uk-UA)' 'Ukrainian (uk-UA)'), 'Deutsch (de-DE)', 'Français (fr-FR)',
                'Español (es-ES)', 'Italiano (it-IT)', 'Polski (pl-PL)', 'Português do Brasil (pt-BR)',
                'Türkçe (tr-TR)', 'Қазақ (kk-KZ)', (T 'Другой — ввести код вручную' 'Other - enter the code manually')
            )
            $langCodes = @('ru-RU', 'uk-UA', 'de-DE', 'fr-FR', 'es-ES', 'it-IT', 'pl-PL', 'pt-BR', 'tr-TR', 'kk-KZ', 'other')
            $chosen = Read-Option -Question (T 'Какой язык' 'Which language') -Items $langNames -Values $langCodes -Default 1
            if ($chosen -eq 'other') {
                $chosen = (Read-Host (T '  Код языка (например sv-SE)' '  Language code (for example sv-SE)')).Trim()
            }
            if ($chosen) {
                $DownloadLanguage = @($chosen)
                Write-Host (T "  Пакет (~37 МБ) будет скачан с серверов Microsoft." "  The package (about 37 MB) will be downloaded from Microsoft servers.") -ForegroundColor Gray
            }
        }
    }

    # 7. Обновления
    Write-Host ''
    Write-Host (T '  Накопительное обновление весит около 4.9 ГБ и добавляет к сборке ~25 минут,' '  The cumulative update is about 4.9 GB and adds roughly 25 minutes to the build,') -ForegroundColor DarkGray
    Write-Host (T '  зато система ставится уже пропатченной. Иначе патчи придут через Windows Update.' '  but the system installs already patched. Otherwise patches arrive via Windows Update.') -ForegroundColor DarkGray
    if (Read-YesNo -Question (T 'Встроить последние обновления?' 'Embed the latest updates?') -Default $false) { $WithUpdates = $true }

    # 8. winget
    Write-Host ''
    if (Read-YesNo -Question (T 'Встроить winget (менеджер пакетов, ~300 МБ загрузки)?' 'Embed winget (package manager, about 300 MB download)?') -Default $false) { $WithWinget = $true }

    # 9. Уменьшение размера
    Write-Host ''
    Write-Host (T '  Классический установщик позволяет убрать лишние файлы установки и' '  The classic setup lets us drop extra setup files and the') -ForegroundColor DarkGray
    Write-Host (T '  среду восстановления — образ меньше примерно на 650 МБ. Ставится' '  recovery environment - roughly 650 MB smaller. It only installs') -ForegroundColor DarkGray
    Write-Host (T '  только загрузкой с носителя (запуск setup.exe из Windows не работает).' '  by booting from the media (running setup.exe from Windows will not work).') -ForegroundColor DarkGray
    if (Read-YesNo -Question (T 'Уменьшить образ по-максимуму?' 'Shrink the image as much as possible?') -Default $true) {
        $LegacySetup = $true; $TrimSources = $true
    }

    # Среда восстановления — отдельный вопрос, а не подпункт уменьшения размера.
    # Вопрос один: остаётся файл внутри готового ISO или нет. Отдельно про копию
    # не спрашиваем — при ответе «нет» файл всегда кладётся рядом с ISO, поэтому
    # выбор ничего не теряет и вернуть восстановление можно в любой момент.
    Write-Host ''
    Write-Host (T '  winre.wim (508 МБ) — среда восстановления Windows: откат при сбое' '  winre.wim (508 MB) is the Windows recovery environment: repair on boot') -ForegroundColor DarkGray
    Write-Host (T '  загрузки, «Особые варианты загрузки», сброс ПК.' '  failure, Advanced startup options, PC reset.') -ForegroundColor DarkGray
    Write-Host (T '    да  — остаётся внутри ISO, Windows пользуется им после установки' '    yes - stays inside the ISO, Windows uses it after installation') -ForegroundColor DarkGray
    Write-Host (T '    нет — вырезается из ISO и кладётся рядом отдельным файлом' '    no  - cut out of the ISO and saved next to it as a separate file') -ForegroundColor DarkGray
    if (-not $LegacySetup) {
        Write-Host (T '  Вырезать можно только с классическим установщиком — он включится сам.' '  Cutting it out requires the classic setup - it will be enabled automatically.') -ForegroundColor DarkGray
    }
    $RemoveWinRE = -not (Read-YesNo -Question (T 'Оставить winre.wim в готовом ISO?' 'Keep winre.wim inside the finished ISO?') -Default $false)
    # Вырезали — значит обязательно сохраняем рядом с ISO, иначе файл потеряется
    $SaveWinRE = $RemoveWinRE

    if ($RemoveWinRE -and -not $LegacySetup) {
        $LegacySetup = $true
        Write-Note (T 'Включён классический установщик: без него установка без winre.wim падает с 0x80070003' 'Classic setup enabled: without it, installing without winre.wim fails with 0x80070003')
    }

    # 10. Отладка
    Write-Host ''
    if (Read-YesNo -Question (T 'Вести подробный лог работы?' 'Write a detailed log?') -Default $false) {
        $script:DebugMode = $true
        $VerbosePreference = 'SilentlyContinue'
        $DebugPreference = 'SilentlyContinue'
    }

    # Итог
    if ($WithUpdates -and $UpdateMode -eq 'none') { $UpdateMode = 'download' }
    if ($DownloadLanguage -and -not $AddLanguage) { $AddLanguage = $DownloadLanguage }

    $cmd = ".\win-11-lite.ps1 -InputIso `"$InputIso`""
    if ($Index -gt 0)        { $cmd += " -Index $Index" }
    if ($AccountMode -ne 'auto') { $cmd += " -AccountMode $AccountMode" }
    if ($LocalUserName) { $cmd += " -LocalUserName '$($LocalUserName.Replace("'","''"))'" }
    if ($LocalUserPassword -and $LocalUserPassword.Length) { $cmd += ' -LocalUserPassword (Read-Host -AsSecureString)' }
    if ($DismPath) { $cmd += " -DismPath '$($DismPath.Replace("'","''"))'" }
    if ($Preset -ne 'balanced') { $cmd += " -Preset $Preset" }
    if ($WorkDir -ne $defaultWork) { $cmd += " -WorkDir `"$WorkDir`"" }
    if ($DownloadLanguage)   { $cmd += " -DownloadLanguage $($DownloadLanguage -join ',')" }
    if ($SetupLanguage -ne 'auto') { $cmd += " -SetupLanguage $SetupLanguage" }
    if ($SetupLanguageSource) { $cmd += " -SetupLanguageSource `"$SetupLanguageSource`"" }
    if ($SetupLanguageUpdatePath) { $cmd += " -SetupLanguageUpdatePath `"$SetupLanguageUpdatePath`"" }
    if ($WithUpdates)        { $cmd += ' -WithUpdates' }
    if ($WithWinget)         { $cmd += ' -WithWinget' }
    if ($LegacySetup)        { $cmd += ' -LegacySetup' }
    if ($TrimSources)        { $cmd += ' -TrimSources' }
    if ($RemoveWinRE)        { $cmd += ' -RemoveWinRE' }
    if ($SaveWinRE)          { $cmd += ' -SaveWinRE' }
    if ($Guard)              { $cmd += ' -Guard' }
    if ($Guard) { $cmd += " -GuardMode $GuardMode" }
    if ($script:DebugMode)   { $cmd += ' -Debug' }

    Write-Host ''
    Write-Host (T '  Эта же сборка одной командой:' '  The same build as a single command:') -ForegroundColor White
    Write-Host "  $cmd" -ForegroundColor Yellow
    Write-Host ''
    if (-not (Read-YesNo -Question (T 'Начинаем?' 'Start now?') -Default $true)) {
        Write-Host (T '  Отменено.' '  Cancelled.') -ForegroundColor Yellow
        Wait-BeforeExit
        exit 0
    }
}

# --- пути ---
if (-not $InputIso) { $InputIso = Select-InputIso }
if (-not (Test-Path -LiteralPath $InputIso)) { throw (T "Файл не найден: $InputIso" "File not found: $InputIso") }
$InputIso = (Resolve-Path -LiteralPath $InputIso).Path
$isoName = [IO.Path]::GetFileNameWithoutExtension($InputIso)
$outDir = Join-Path $script:ScriptRoot 'out'
if (-not $OutputIso) { $OutputIso = Join-Path $outDir "${isoName}_lite.iso" }
$OutputIso = [IO.Path]::GetFullPath($OutputIso)
$WorkDir = [IO.Path]::GetFullPath($WorkDir)
if ($InputIso -eq $OutputIso) { throw (T 'InputIso и OutputIso должны быть разными файлами' 'InputIso and OutputIso must be different files') }
if ($TrimSources -and -not $LegacySetup) { throw (T '-TrimSources требует -LegacySetup' '-TrimSources requires -LegacySetup') }
if ($RemoveWinRE -and -not $LegacySetup -and $Keep -notcontains 'WinRE') { throw (T '-RemoveWinRE требует -LegacySetup' '-RemoveWinRE requires -LegacySetup') }
if ($Index -gt 0 -and $Edition) { throw (T 'Укажите только один параметр: -Index или -Edition' 'Use either -Index or -Edition') }
if ($DriversDir -and -not (Test-Path -LiteralPath $DriversDir -PathType Container)) { throw (T "Папка драйверов не найдена: $DriversDir" "Drivers folder not found: $DriversDir") }
if ($Unattend -and $Unattend -ne 'none') {
    $Unattend = (Resolve-Path -LiteralPath $Unattend).Path
    $null = [xml](Get-Content -LiteralPath $Unattend -Raw)
}
if ($LanguageUpdatePath) { $LanguageUpdatePath = (Resolve-Path -LiteralPath $LanguageUpdatePath).Path }
if ($SetupLanguageUpdatePath) { $SetupLanguageUpdatePath = (Resolve-Path -LiteralPath $SetupLanguageUpdatePath).Path }
if ($SetupLanguageSource) { $SetupLanguageSource = (Resolve-Path -LiteralPath $SetupLanguageSource).Path }
if ($SetupLanguage -notin @('auto','original') -and $SetupLanguage -notmatch '^[a-z]{2}-[a-z]{2}$') { throw (T "Неверный язык установщика: $SetupLanguage" "Invalid Setup language: $SetupLanguage") }
foreach ($tag in @($AddLanguage) + @($DownloadLanguage)) {
    if ($tag -and $tag -notmatch '^[a-z]{2,3}(?:-[a-z0-9]{2,8})+$') { throw (T "Неверный код языка: $tag" "Invalid language tag: $tag") }
}
foreach ($pattern in $RemoveExtra) { $null = [regex]::new($pattern) }
# Без нашего specialize нельзя безопасно гарантировать возврат временных настроек.
$script:ManageOobe = -not $Unattend
# Лог пишем только по -Debug (рядом со скриптом) или если путь задан явно
if (-not $LogFile -and $script:DebugMode) {
    $LogFile = Join-Path $script:ScriptRoot ("log\{0}_{1:yyyyMMdd-HHmmss}.log" -f $isoName, (Get-Date))
}
if ($LogFile) { $LogFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogFile) }
if (-not $DryRun) {
    $null = New-Item -ItemType Directory -Path (Split-Path $OutputIso -Parent) -Force
    $script:ImageAuditPath = [IO.Path]::ChangeExtension($OutputIso, '.image-audit.json')
}

# --- выбор рабочего каталога ---
# Пиковое потребление: распакованный ISO + растущий install.wim + scratch.
# С интеграцией обновлений добавляются ещё и сами .msu.
$requiredGB = if ($UpdateMode -eq 'none') { 30 } else { 45 }

function Get-FreeGB {
    param([string]$Path)
    $qualifier = Split-Path $Path -Qualifier
    if (-not $qualifier) { return $null }   # UNC-путь — измерить не можем
    $drive = Get-PSDrive -Name $qualifier.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($drive) { [math]::Round($drive.Free / 1GB, 1) } else { $null }
}

$workFreeGB = Get-FreeGB $WorkDir
if ($null -ne $workFreeGB -and $workFreeGB -lt $requiredGB -and -not $script:WorkDirExplicit) {
    # Пользователь путь не задавал, а в системной temp тесно — берём локальный
    # диск с наибольшим свободным местом
    $best = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
            Sort-Object FreeSpace -Descending | Select-Object -First 1
    if ($best -and ($best.FreeSpace / 1GB) -gt $workFreeGB) {
        $WorkDir = Join-Path "$($best.DeviceID)\" 'win-11-lite-work'
        $script:WorkDirMoved = $true
    }
}

# Перед каждым прогоном рабочий каталог очищается целиком, поэтому работать
# прямо в указанной папке нельзя: -WorkDir D:\Temp снёс бы всё её содержимое.
# Всегда уходим в собственную подпапку и помечаем её файлом-меткой.
$script:WorkDirMarker = '.win-11-lite-workdir'
$script:WorkDirLeaf = 'win-11-lite-work'

# Последняя линия обороны: удалять можно только каталог, который создали мы сами.
# Проверка вызывается непосредственно перед каждым Remove-Item по рабочему пути.
function Test-SafeToWipe {
    param([string]$Path)

    if (-not $Path) { return $false }
    $full = try { [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }

    # корень диска — D:\, C:\ и подобное
    if ($full -match '^[A-Za-z]:$') { return $false }
    # путь должен вести в нашу подпапку, иначе это чужой каталог
    if ((Split-Path $full -Leaf) -ne $script:WorkDirLeaf) { return $false }

    # Системные деревья целиком под запретом. Временные папки Windows исключены
    # намеренно: %TEMP% администратора — это C:\Windows\Temp, и он наш путь
    # по умолчанию.
    $forbiddenTrees = @("$env:SystemRoot\System32", "$env:SystemRoot\SysWOW64",
                        "$env:SystemRoot\WinSxS", "$env:SystemRoot\assembly",
                        $env:ProgramFiles, ${env:ProgramFiles(x86)},
                        $env:ProgramData)
    foreach ($bad in $forbiddenTrees) {
        if (-not $bad) { continue }
        $b = [IO.Path]::GetFullPath($bad).TrimEnd('\')
        if ($full -eq $b -or $full.StartsWith("$b\", [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }

    # Сам каталог Windows — только точное совпадение, подпапки разрешены
    if ($full -eq [IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\')) { return $false }

    # каталог с исходным ISO и папка результатов тоже под запретом
    foreach ($protectedPath in @($InputIso, $OutputIso, $UpdatesDir, $script:ScriptRoot, $Unattend, $LanguageSource, $DriversDir, $LanguageUpdatePath, $SetupLanguageSource, $SetupLanguageUpdatePath, $LogFile, $DismPath)) {
        if (-not $protectedPath -or $protectedPath -eq 'none') { continue }
        $k = [IO.Path]::GetFullPath($protectedPath).TrimEnd('\')
        if ($full -eq $k -or $k.StartsWith("$full\", [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    try { $null = Assert-ChildPath -Path $full -Root (Split-Path $full -Parent) } catch { return $false }
    $true
}

if ((Split-Path $WorkDir -Leaf) -ne $script:WorkDirLeaf) {
    $WorkDir = Join-Path $WorkDir $script:WorkDirLeaf
}

if (-not $UpdatesDir) { $UpdatesDir = Join-Path (Split-Path $WorkDir -Parent) 'win-11-lite-updates' }
$UpdatesDir = [IO.Path]::GetFullPath($UpdatesDir)
if ($UpdatesDir -eq $WorkDir -or $UpdatesDir.StartsWith("$WorkDir\", [StringComparison]::OrdinalIgnoreCase)) {
    throw (T 'UpdatesDir должен находиться вне WorkDir' 'UpdatesDir must be outside WorkDir')
}
if (-not (Test-SafeToWipe $WorkDir)) { throw (T "Небезопасный рабочий каталог: $WorkDir" "Unsafe work directory: $WorkDir") }

$mountDir = Join-Path $WorkDir 'mount'
$isoDir = Join-Path $WorkDir 'iso'
$bootMountDir = Join-Path $WorkDir 'bootmount'
$wimPath = Join-Path $WorkDir 'install.wim'

#region ── Журналы сборки ────────────────────────────────────────────────────
$script:Transcribing = $false
$script:DismLogPath = $null
$script:DetailLogPath = $null
$script:DetailLogFailed = $false
if ($LogFile -and -not $DryRun) {
    $LogFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogFile)
    $null = New-Item -ItemType Directory -Path (Split-Path $LogFile -Parent) -Force
    $script:DetailLogPath = [IO.Path]::ChangeExtension($LogFile, '.details.log')
    $script:DismLogPath = [IO.Path]::ChangeExtension($LogFile, '.dism.log')
    [IO.File]::WriteAllText($script:DetailLogPath, '', [Text.UTF8Encoding]::new($true))
    try { Start-Transcript -Path $LogFile -Force | Out-Null; $script:Transcribing = $true }
    catch { Write-Warning (T "Не удалось открыть основной журнал: $($_.Exception.Message)" "Could not start the main log: $($_.Exception.Message)") }
}
#endregion

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║                          win-11-lite  ISO builder                        ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host (T "  Исходный ISO : $InputIso" "  Source ISO   : $InputIso")
Write-Host (T "  Результат    : $OutputIso" "  Result       : $OutputIso")
Write-Host (T "  Рабочий кат. : $WorkDir" "  Work folder  : $WorkDir")
Write-Host (T "  Кэш обновл.  : $UpdatesDir" "  Update cache : $UpdatesDir")
$keepNote = if ($Keep) { T "  (оставляем: $($Keep -join ', '))" "  (kept: $($Keep -join ', '))" } else { '' }
Write-Host (T "  Пресет       : $Preset$keepNote" "  Preset       : $Preset$keepNote")
if ($Preset -eq 'max') {
    Write-Note (T 'MAX: максимальное удаление. Некоторые приложения и функции Windows могут перестать работать; восстановлению компонентов может потребоваться исходный ISO.' 'MAX: maximum removal. Some applications and Windows features may stop working; component repair may require the original ISO.')
}
if ($LogFile) { Write-Host (T "  Лог          : $LogFile" "  Log          : $LogFile") }
else { Write-Host (T '  Лог          : не ведётся  (включить: -Debug)' '  Log          : disabled  (enable with -Debug)') }
if ($script:DetailLogPath) { Write-Host (T "  Подробный лог: $script:DetailLogPath" "  Details log  : $script:DetailLogPath") }
if ($DryRun) { Write-Host (T '  РЕЖИМ        : DryRun — ничего не изменяется' '  MODE         : DryRun - nothing will be changed') -ForegroundColor Yellow }
Write-Host ''

Write-Stage (T 'Preflight — проверка окружения' 'Preflight checks')

# --- права ---
# Настоящая проверка и перезапуск с UAC уже прошли выше; здесь только отметка
$isAdmin = Test-Admin
if ($isAdmin) {
    Write-Ok (T 'Права администратора есть' 'Administrator rights confirmed')
} else {
    Write-Note (T 'Прав администратора нет — в режиме DryRun это допустимо' 'No administrator rights - acceptable in DryRun mode')
}

# Инструменты выбираются после чтения версии образа, до любых изменений WIM.
$script:Dism = $null
$script:Oscdimg = $null

# --- место на диске ---
if ($script:WorkDirMoved) {
    Write-Note (T "Во временной папке Windows меньше $requiredGB ГБ — работаю в $WorkDir" "Less than $requiredGB GB in the Windows temp folder - working in $WorkDir")
}
$workDrive = Split-Path $WorkDir -Qualifier
$freeGB = Get-FreeGB $WorkDir
if ($null -eq $freeGB) {
    Write-Note (T "Не удалось определить свободное место для $WorkDir — нужно не менее $requiredGB ГБ" "Could not determine free space for $WorkDir - at least $requiredGB GB required")
} elseif ($freeGB -lt $requiredGB) {
    Write-Note (T "На $workDrive свободно $freeGB ГБ, нужно не менее $requiredGB ГБ. Укажите другой путь через -WorkDir" "Only $freeGB GB free on $workDrive, at least $requiredGB GB required. Use -WorkDir to pick another location")
} else {
    Write-Ok (T "Свободно на $workDrive : $freeGB ГБ (нужно ~$requiredGB ГБ)" "Free on $workDrive : $freeGB GB (about $requiredGB GB needed)")
}

# --- источник языков ---
# -DownloadLanguage сам подразумевает, какие языки встраивать
if ($DownloadLanguage -and -not $AddLanguage) { $AddLanguage = $DownloadLanguage }

if ($AddLanguage) {
    if (-not $DownloadLanguage -and -not $LanguageSource) {
        throw (T @'
Указан -AddLanguage, но не задан ни -LanguageSource, ни -DownloadLanguage.

Языковые пакеты не входят в установочный ISO. Для Windows 11 24H2 они лежат в
образе «Languages and Optional Features» (LoF) — там объединены language packs,
LIP и Features on Demand. Он доступен через VLSC, MSDN или Azure.

    -LanguageSource D:\...\LanguagesAndOptionalFeatures.iso
    -LanguageSource D:\lof\LanguagesAndOptionalFeatures    (распакованная папка)

Либо скачайте пакеты автоматически:

    -DownloadLanguage ru-RU
'@ @'
-AddLanguage was given, but neither -LanguageSource nor -DownloadLanguage was set.

Language packs are not part of the installation ISO. For Windows 11 24H2 they live
in the "Languages and Optional Features" (LoF) image, which combines language packs,
LIP and Features on Demand. It is available through VLSC, MSDN or Azure.

    -LanguageSource D:\...\LanguagesAndOptionalFeatures.iso
    -LanguageSource D:\lof\LanguagesAndOptionalFeatures    (extracted folder)

Or download the packages automatically:

    -DownloadLanguage ru-RU
'@)
    }
    if ($LanguageSource) {
        if (-not (Test-Path -LiteralPath $LanguageSource)) { throw (T "Источник языков не найден: $LanguageSource" "Language source not found: $LanguageSource") }
        Write-Ok (T "Источник языков: $LanguageSource" "Language source: $LanguageSource")
    }
}


#endregion

try {

#region ── Стадия 1. Распаковка ISO ────────────────────────────────────────────

Write-Stage (T 'Чтение исходного ISO' 'Reading the source ISO')

Write-Step (T "Монтирую $([IO.Path]::GetFileName($InputIso))" "Mounting $([IO.Path]::GetFileName($InputIso))")
$diskImage = Get-DiskImage -ImagePath $InputIso
if (-not $diskImage.Attached) {
    $diskImage = Mount-DiskImage -ImagePath $InputIso -PassThru -Access ReadOnly
    $script:IsoMounted = $InputIso
}
Start-Sleep -Seconds 2
$vol = $diskImage | Get-Volume
$srcDrive = "$($vol.DriveLetter):"
$isoLabel = $vol.FileSystemLabel
Write-Ok (T "Смонтирован как $srcDrive  (метка: $isoLabel)" "Mounted as $srcDrive  (label: $isoLabel)")

$srcSources = Join-Path $srcDrive 'sources'

#endregion

#region ── Стадия 2. Паспорт образа ────────────────────────────────────────────

Write-Stage (T 'Определение параметров образа' 'Reading image details')

$srcInstall = Join-Path $srcSources 'install.wim'
$srcIsEsd = $false
if (-not (Test-Path -LiteralPath $srcInstall)) {
    $srcInstall = Join-Path $srcSources 'install.esd'
    $srcIsEsd = $true
    if (-not (Test-Path -LiteralPath $srcInstall)) { throw (T "В образе нет sources\install.wim или install.esd" "The image has no sources\install.wim or install.esd") }
}
Write-Ok (T "Образ: $(Split-Path $srcInstall -Leaf)  ($(Format-Size (Get-Item -LiteralPath $srcInstall).Length))" "Image: $(Split-Path $srcInstall -Leaf)  ($(Format-Size (Get-Item -LiteralPath $srcInstall).Length))")

$images = @(Get-WimImageList -Path $srcInstall)

Write-Host ''
Write-Host (T '  Индексы в образе:' '  Editions in the image:') -ForegroundColor White
foreach ($img in $images) {
    Write-Host ("    [{0}] {1,-46} {2}" -f $img.Index, $img.Name, $img.EditionId)
}
Write-Host ''

# --- выбор индекса ---
$selected = $null
if ($Edition) {
    $selected = $images | Where-Object { $_.EditionId -eq $Edition } | Select-Object -First 1
    if (-not $selected) { throw (T "В образе нет редакции '$Edition'. Доступны: $(($images.EditionId | Sort-Object -Unique) -join ', ')" "The image has no '$Edition' edition. Available: $(($images.EditionId | Sort-Object -Unique) -join ', ')") }
} elseif ($Index -gt 0) {
    $selected = $images | Where-Object { [int]$_.Index -eq $Index } | Select-Object -First 1
    if (-not $selected) { throw (T "В образе нет индекса $Index. Доступны: $(($images.Index) -join ', ')" "The image has no index $Index. Available: $(($images.Index) -join ', ')") }
} elseif ($images.Count -eq 1) {
    # Выбирать не из чего
    $selected = $images[0]
} else {
    # Редакция определяет и лицензию, и срок поддержки — угадывать за пользователя
    # нельзя. Это не сбой, а требование ввода, поэтому выходим без трассировки.
    Write-Host ''
    Write-Fail (T "В образе $($images.Count) редакции Windows — укажите, с какой работать" "The image contains $($images.Count) Windows editions - choose which one to build")
    Write-Host ''
    Write-Host (T '  Добавьте к команде один из параметров:' '  Add one of these parameters to the command:') -ForegroundColor White
    foreach ($img in $images) {
        Write-Host ((T "    -Index {0,-3} или -Edition {1,-20} # {2}" "    -Index {0,-3} or -Edition {1,-20} # {2}") -f $img.Index, $img.EditionId, $img.Name) -ForegroundColor Yellow
    }
    Write-Host ''
    exit 2
}

$srcIndex = [int]$selected.Index
if ([string]$selected.Architecture -notin @('9', 'x64', 'amd64')) { throw (T 'Сборщик пока поддерживает только образы x64' 'This builder currently supports x64 images only') }

# Язык и версия: у dism поля называются иначе, чем в XML
$imgLang = if ($selected.PSObject.Properties['Languages']) { $selected.Languages } else { '' }
if ($imgLang -match '([a-z]{2}-[A-Z]{2})') { $imgLang = $matches[1] } else { $imgLang = 'en-US' }
$setupLang = $imgLang
$sourceImageLanguage = $imgLang
$setupPayload = $null
$setupRepair = $null
$script:ImageLanguages = @($selected.Languages -split ',')
$imgVersion = if ($selected.PSObject.Properties['Version']) { $selected.Version } else { '' }
if (-not $imgVersion -and $selected.PSObject.Properties['ServicePack Build']) { $imgVersion = $selected.'ServicePack Build' }
$buildNumber = 0
if ($imgVersion -match '10\.0\.(\d+)') { $buildNumber = [int]$matches[1] }
elseif ($imgVersion -match '^(\d{5})') { $buildNumber = [int]$matches[1] }

# Полная ревизия (26100.1742) — по ней подбирается языковой пакет
$imgRevision = ''
if ($imgVersion -match '(\d{5}\.\d+)') { $imgRevision = $matches[1] }

$winVersion = Get-WindowsRelease -Build $buildNumber

Write-Ok (T "Выбран индекс $srcIndex — $($selected.Name)" "Selected index $srcIndex - $($selected.Name)")
Write-Ok (T "Редакция: $($selected.EditionId)   Язык: $imgLang   Билд: $imgVersion   ($winVersion)" "Edition: $($selected.EditionId)   Language: $imgLang   Build: $imgVersion   ($winVersion)")
if ($DryRun) { Initialize-DeploymentTools -Build $buildNumber -Directory $UpdatesDir -ExplicitDism $DismPath -Install:$InstallAdk -Preview }
$account = Read-LocalAccountOptions -Build $buildNumber -EditionId $selected.EditionId -Mode $AccountMode -Name $LocalUserName -Password $LocalUserPassword -Preview:$DryRun
$AccountMode=$account.Mode; $LocalUserName=$account.Name; $LocalUserPassword=$account.Password

$mozLang = $script:MozillaLang[$imgLang]
if (-not $mozLang) { $mozLang = ($imgLang -split '-')[0] }
Write-Ok (T "Язык для загрузки Firefox: $mozLang" "Firefox download language: $mozLang")

#endregion

#region ── Подготовка загрузок до обработки образа ────────────────────────────
if (-not $DryRun) {
    Write-Stage (T 'Подготовка всех загрузок перед сборкой' 'Preparing all downloads before building')
    if ($ClearCache -and (Test-Path $UpdatesDir)) {
        if (-not (Test-Path -LiteralPath (Join-Path $UpdatesDir '.win-11-lite-cache'))) { throw (T 'Отказ от очистки кэша без метки принадлежности скрипту' 'Refusing to clear an unmarked cache directory') }
        $null = Assert-ChildPath -Path $UpdatesDir -Root (Split-Path $UpdatesDir -Parent)
        foreach ($protectedPath in @($InputIso, $OutputIso, $WorkDir, $script:ScriptRoot, $LanguageSource, $Unattend, $DriversDir, $LanguageUpdatePath, $SetupLanguageSource, $SetupLanguageUpdatePath, $DismPath)) {
            if (-not $protectedPath -or $protectedPath -eq 'none') { continue }
            $fullProtected = [IO.Path]::GetFullPath($protectedPath)
            if ($fullProtected -eq $UpdatesDir -or $fullProtected.StartsWith("$UpdatesDir\", [StringComparison]::OrdinalIgnoreCase)) {
                throw (T "В кэше находятся защищённые файлы: $fullProtected" "Cache contains protected files: $fullProtected")
            }
        }
        Write-Step (T 'Очищаю кэш обновлений' 'Clearing the update cache')
        Remove-Item -LiteralPath $UpdatesDir -Recurse -Force
    }
    $null = New-Item -ItemType Directory -Path $UpdatesDir -Force
    if (-not @(Get-ChildItem -LiteralPath $UpdatesDir -Force).Count) {
        Set-Content -LiteralPath (Join-Path $UpdatesDir '.win-11-lite-cache') -Value 'win-11-lite cache' -Encoding ascii
    }
    Initialize-DeploymentTools -Build $buildNumber -Directory $UpdatesDir -ExplicitDism $DismPath -Install:$InstallAdk
    $lcuDir = Join-Path $UpdatesDir "lcu-$winVersion"
    $netDir = Join-Path $UpdatesDir "dotnet-$winVersion"
    $requestedUpdateMode = $UpdateMode
    $lcuPayload = $null
    $dotNetPayload = $null
    $wingetPayload = $null
    $langIsoMounted = $null

    if ($UpdateMode -ne 'none') {
        try {
            if ($UpdateMode -eq 'download') {
                $target = Save-CatalogPayload -Query "Cumulative Update for Windows 11 version $winVersion x64" -Directory $lcuDir
                $LcuFile = Split-Path $target -Leaf
            } else {
                $target = Get-LocalUpdatePayload -Directory $lcuDir -FileName $LcuFile
                $LcuFile = $target.Name
            }
            $lcuPayload = Join-Path $lcuDir $LcuFile
        } catch {
            Confirm-SkipDownload -Component (T 'накопительное обновление Windows (LCU)' 'Windows cumulative update (LCU)') -Reason $_.Exception.Message
            $UpdateMode = 'none'
            $WithUpdates = $false
            $LcuFile = $null
        }
    }
    if ($requestedUpdateMode -ne 'none' -and $IncludeDotNetUpdate) {
        try {
            if ($requestedUpdateMode -eq 'download') {
                $target = Save-CatalogPayload -Query "Cumulative Update for .NET Framework Windows 11 version $winVersion x64" -Directory $netDir -TitlePattern '\.NET Framework'
                $DotNetUpdateFile = Split-Path $target -Leaf
            } else {
                $target = Get-LocalUpdatePayload -Directory $netDir -FileName $DotNetUpdateFile
                $DotNetUpdateFile = $target.Name
            }
            $dotNetPayload = Join-Path $netDir $DotNetUpdateFile
        } catch {
            Confirm-SkipDownload -Component (T 'обновление .NET Framework' '.NET Framework update') -Reason $_.Exception.Message
            $IncludeDotNetUpdate = $false
            $DotNetUpdateFile = $null
        }
    }

    if ($AddLanguage) {
        if ($DownloadLanguage) {
            $langCache = Join-Path $UpdatesDir "lang-$(if ($imgRevision) { $imgRevision } else { $buildNumber })"
            foreach ($tag in @($AddLanguage)) {
                try {
                    Save-LanguageFromCatalog -Tags @($tag) -Build $buildNumber -Revision $imgRevision -Destination $langCache
                } catch {
                    Confirm-SkipDownload -Component (T "язык $tag (Pack + Basic)" "language $tag (Pack + Basic)") -Reason $_.Exception.Message
                    $AddLanguage = @($AddLanguage | Where-Object { $_ -ne $tag })
                }
            }
            $DownloadLanguage = @($AddLanguage)
            $LanguageSource = $langCache
        }
        if ($AddLanguage) {
            $langRoot = $LanguageSource
            $langIsoMounted = $null
            if ($LanguageSource -match '\.iso$') {
                Write-Step (T "Монтирую источник языков: $(Split-Path $LanguageSource -Leaf)" "Mounting the language source: $(Split-Path $LanguageSource -Leaf)")
                $langImage = Get-DiskImage -ImagePath (Resolve-Path -LiteralPath $LanguageSource).Path
                if (-not $langImage.Attached) {
                    $langImage = Mount-DiskImage -ImagePath (Resolve-Path -LiteralPath $LanguageSource).Path -PassThru -Access ReadOnly
                    $langIsoMounted = (Resolve-Path -LiteralPath $LanguageSource).Path
                    $script:LangIso = $langIsoMounted
                }
                Start-Sleep -Seconds 2
                $langRoot = "$(($langImage | Get-Volume).DriveLetter):\"
                Write-Ok (T "Источник смонтирован как $langRoot" "Source mounted as $langRoot")
            }
                    foreach ($tag in @($AddLanguage)) {
                try {
                    foreach ($kind in @('Pack', 'Basic')) {
                        $package = Find-LanguagePackage -Root $langRoot -Tag $tag -Kind $kind
                        if (-not $package -or $package.Length -le 0) { throw (T "Нет обязательного пакета $kind в $langRoot" "Required package $kind missing from $langRoot") }
                    }
                } catch {
                    Confirm-SkipDownload -Component (T "язык $tag (Pack + Basic)" "language $tag (Pack + Basic)") -Reason $_.Exception.Message
                    $AddLanguage = @($AddLanguage | Where-Object { $_ -ne $tag })
                }
            }
        }
        # Полная ревизия читается с исходного ISO; до монтирования WIM выбираем
        # LCU для всех добавляемых языков. Неизвестная ревизия требует явного MSU.
        $needsLanguageRepair = -not $imgRevision -or ([version]$imgRevision).Minor -gt 1
        if ($AddLanguage -and $needsLanguageRepair -and $UpdateMode -eq 'none' -and -not $LanguageUpdatePath) {
            try {
                if (-not $DownloadLanguage) { throw (T 'Задайте -LanguageUpdatePath или -WithUpdates для обслуживания новых языков' 'Use -LanguageUpdatePath or -WithUpdates to service added languages') }
                $LanguageUpdatePath = Get-LanguageRepairUpdate -Revision $imgRevision -Destination $UpdatesDir
            } catch {
                Confirm-SkipDownload -Component (T "добавление языков $($AddLanguage -join ', ') — нет обязательного LCU" "added languages $($AddLanguage -join ', ') - required LCU unavailable") -Reason $_.Exception.Message
                $AddLanguage = @()
                $DownloadLanguage = @()
            }
        }
        $DownloadLanguage = @($DownloadLanguage | Where-Object { $_ -in $AddLanguage })
    }
    if ($WithWinget) {
        try { $wingetPayload = Save-WingetPayload -Directory (Join-Path $UpdatesDir 'winget') }
        catch {
            Confirm-SkipDownload -Component 'winget (App Installer)' -Reason $_.Exception.Message
            $WithWinget = $false
        }
    }
    $desiredSetupLang = if ($SetupLanguage -eq 'original') { $sourceImageLanguage }
        elseif ($SetupLanguage -and $SetupLanguage -ne 'auto') { $SetupLanguage }
        elseif ($AddLanguage) { $AddLanguage[0] } else { $sourceImageLanguage }
    if ($desiredSetupLang -ne $sourceImageLanguage) {
        try {
            $bootImage = @(Get-WimImageList -Path (Join-Path $srcSources 'boot.wim') | Where-Object { [int]$_.Index -eq 2 })
            if ($bootImage.Count -ne 1 -or [string]$bootImage[0].Architecture -notin @('9','x64','amd64')) { throw (T 'Не найден стандартный установщик x64 в boot.wim (индекс 2)' 'Standard x64 Setup image not found in boot.wim (index 2)') }
            $bootVersion = [version]$bootImage[0].Version
            $peSource = $SetupLanguageSource
            if (-not $peSource) {
                $candidates = @(
                    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs",
                    "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs"
                )
                if ($langRoot) { $candidates += @((Join-Path $langRoot 'Windows Preinstallation Environment\x64\WinPE_OCs'), $langRoot) }
                $peSource = $candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ "$desiredSetupLang\lp.cab") } | Select-Object -First 1
            }
            try {
                $setupPayload = Save-SetupLanguagePayload -Tag $desiredSetupLang -Build $bootVersion.Build -Directory $UpdatesDir -Source $peSource
            } catch {
                if (-not $peSource -or $SetupLanguageSource) { throw }
                Write-Note (T "Локальный WinPE не подошёл: $($_.Exception.Message). Загружаю совместимый комплект." "Local WinPE was unsuitable: $($_.Exception.Message). Downloading a matching set.")
                $setupPayload = Save-SetupLanguagePayload -Tag $desiredSetupLang -Build $bootVersion.Build -Directory $UpdatesDir
            }
            if ($SetupLanguageUpdatePath) { $setupRepair = $SetupLanguageUpdatePath }
            elseif ($bootVersion.Revision -gt 1) {
                $bootRevision = "$($bootVersion.Build).$($bootVersion.Revision)"
                if ($LanguageUpdatePath -and $bootRevision -eq $imgRevision) { $setupRepair = $LanguageUpdatePath }
                elseif ($bootRevision -eq '26100.1742') { $setupRepair = Get-LanguageRepairUpdate -Revision $bootRevision -Destination $UpdatesDir }
                elseif ($lcuPayload -and $bootVersion.Build -eq $buildNumber) { $setupRepair = $lcuPayload }
                else { throw (T "Для языка boot.wim $bootRevision нужен -SetupLanguageUpdatePath <MSU> или совместимый -WithUpdates" "Language resources for boot.wim $bootRevision need -SetupLanguageUpdatePath <MSU> or matching -WithUpdates") }
            }
            if ($setupRepair) {
                $repairFile = Get-Item -LiteralPath $setupRepair
                if ($repairFile.PSIsContainer -or $repairFile.Length -le 0 -or $repairFile.Extension -ne '.msu') { throw (T 'Неверный LCU для boot.wim' 'Invalid boot.wim LCU') }
            }
            $setupLang = $desiredSetupLang
        } catch {
            Confirm-SkipDownload -Component (T "перевод установщика на $desiredSetupLang (останется $sourceImageLanguage)" "Setup translation to $desiredSetupLang (keeping $sourceImageLanguage)") -Reason $_.Exception.Message
            $setupPayload = $null
            $setupRepair = $null
            $setupLang = $sourceImageLanguage
        }
    }
    # Обязательный локальный помощник готовится до любых изменений образа.
    $setupRunner = Get-SetupRunnerScript
    $script:DownloadsClosed = $true
    Write-Ok (T 'Все компоненты подготовлены. Дальнейшая сборка не требует интернета.' 'All components are prepared. The remaining build requires no internet connection.')
    if ($script:SkippedDownloads.Count) { Write-Note (T "Исключено по вашему выбору: $($script:SkippedDownloads -join '; ')" "Skipped by your choice: $($script:SkippedDownloads -join '; ')") }
}
#endregion
# ── План работ (и точка выхода для DryRun) ──────────────────────────────────
Write-Stage (T 'План удаления при текущем пресете' 'Removal plan for the selected preset')

$activeGroups = @()
foreach ($rule in ($script:CapabilityRules + $script:PackageRules + $script:AppxRules + $script:FolderRules + $script:FileRules)) {
    if (Test-GroupActive -RulePreset $rule.Preset -Group $rule.Group) {
        $activeGroups += [PSCustomObject]@{ Group = $rule.Group; Desc = $rule.Desc }
    }
}
foreach ($g in ($activeGroups | Group-Object Group | Sort-Object Name)) {
    Write-Host ("  {0,-10} {1}" -f $g.Name, (($g.Group.Desc | Select-Object -Unique) -join '; ')) -ForegroundColor Gray
}
# Часть удалений идёт не пакетами, а файлами — показываем их в плане отдельно
if (Test-GroupActive -RulePreset 'balanced' -Group 'Fonts') {
    Write-Host ("  {0,-10} {1}" -f 'Fonts', (T 'CJK-шрифты — файлами (~254 МБ)' 'CJK fonts - by file (about 254 MB)')) -ForegroundColor Gray
}
if (Test-GroupActive -RulePreset 'balanced' -Group 'AI') {
    Write-Host ("  {0,-10} {1}" -f 'AI', (T 'Recall, Copilot, AI Fabric, AIX, AugLoop — файлами и политиками' 'Recall, Copilot, AI Fabric, AIX, AugLoop - by file and policy')) -ForegroundColor Gray
    if ($Preset -eq 'balanced') {
        Write-Host (T '             Recall также удаляется как optional feature через DISM' '             Recall is also removed as an optional feature through DISM') -ForegroundColor Gray
    }
}

# WinRE показан отдельной строкой ниже (зависит от -RemoveWinRE, а не от пресета)
$allGroups = @('Defender', 'Edge', 'Fonts', 'Speech', 'WMP', 'IE', 'AI')
$skipped = $allGroups | Where-Object { -not (Test-GroupActive -RulePreset 'balanced' -Group $_) }
if ($skipped) { Write-Host ''; Write-Note (T "Не трогаем: $($skipped -join ', ')" "Kept as is: $($skipped -join ', ')") }
Write-Host ''
$vLang = if ($AddLanguage) {
    $src = if ($DownloadLanguage -and $DryRun) { T ' — скачать' ' - download' } else { (T ' — из ' ' - from ') + (Split-Path $LanguageSource -Leaf) }
    (T 'добавить ' 'add ') + ($AddLanguage -join ', ') + $src
} else { T "только $imgLang  (добавить: -DownloadLanguage ru-RU)" "$imgLang only  (add with -DownloadLanguage ru-RU)" }
$vSetup = if ($LegacySetup) { T 'классический (winpeshl.ini /legacy)' 'classic (winpeshl.ini /legacy)' } else { T "штатный для $winVersion (ConX)" "stock $winVersion (ConX)" }
$vWinRE = if ($RemoveWinRE) {
    $copyNote = if ($SaveWinRE) { T ', копия рядом с ISO' ', copy saved next to the ISO' } else { T ', без копии' ', no copy kept' }
    if ($LegacySetup) { (T 'удалить' 'remove') + $copyNote }
    else { T 'УДАЛИТЬ — без -LegacySetup установка упадёт!' 'REMOVE - without -LegacySetup the install will fail!' }
} else { T 'оставить' 'keep' }
$vSources = if ($TrimSources) { T 'урезать до boot.wim + install + EI.CFG' 'trim to boot.wim + install + EI.CFG' } else { T 'как в оригинале' 'as in the original' }
$vCleanup = if ($Preset -eq 'safe') { T 'нет' 'none' } elseif ($ResetBase) { 'StartComponentCleanup + ResetBase' } else { 'StartComponentCleanup' }
$vBypass = if (-not $NoBypass) { T 'да' 'yes' } else { T 'нет' 'no' }
$vWinget = if ($WithWinget) { T 'встроить' 'embed' } else { T 'из исходного образа, если есть  (добавить: -WithWinget)' 'keep the source version if present  (add with -WithWinget)' }
$vUpd = "$UpdateMode" + $(if ($UpdateMode -eq 'none') { T '  (встроить последние: -WithUpdates)' '  (embed latest with -WithUpdates)' })

Write-Host (T "  Языки          : $vLang" "  Languages      : $vLang")
if ($AddLanguage -and $UpdateMode -eq 'none') {
    Write-Note (T "Добавление языка в обновлённый ISO требует повторного LCU исходного билда.`r`n  Для 26100.1742 с -DownloadLanguage автоматически скачивается KB5043080 (~509 МБ загрузки)." "Adding a language to updated media requires reapplying the source LCU.`r`n  For 26100.1742, -DownloadLanguage automatically downloads KB5043080 (about 509 MB download).")
}
Write-Host (T "  Установщик     : $vSetup" "  Setup          : $vSetup")
$plannedSetupLang = if ($DryRun -and $SetupLanguage -ne 'original') {
    if ($SetupLanguage -ne 'auto') { $SetupLanguage } elseif ($AddLanguage) { $AddLanguage[0] } else { $setupLang }
} else { $setupLang }
Write-Host (T "  Язык установки : $plannedSetupLang" "  Setup language : $plannedSetupLang")
$accountPlan = if ($AccountMode -eq 'image') {
    if ($LocalUserName) { $LocalUserName } else { T 'задать перед сборкой ISO' 'configure before building the ISO' }
} else { T 'ввод при установке Windows' 'enter during Windows Setup' }
Write-Host (T "  Пользователь   : $accountPlan" "  User account   : $accountPlan")
Write-Host (T "  WinRE          : $vWinRE" "  WinRE          : $vWinRE")
Write-Host (T "  sources        : $vSources" "  sources        : $vSources")
Write-Host (T "  Очистка склада : $vCleanup" "  Store cleanup  : $vCleanup")
Write-Host (T "  Обход TPM/SB   : $vBypass" "  TPM/SB bypass  : $vBypass")
$vGuard = if ($Guard) { T 'встроить (проверка при каждом входе)' 'embed (checks at every logon)' } else { T 'нет  (включить: -Guard)' 'no  (enable with -Guard)' }
Write-Host (T "  winget         : $vWinget" "  winget         : $vWinget")
if ($Preset -ne 'max') { Write-Host (T '  Store / MSIX   : сохранить имеющиеся Store, App Installer и зависимости' '  Store / MSIX   : preserve existing Store, App Installer and dependencies') }
Write-Host (T "  Сторож         : $vGuard" "  Guard          : $vGuard")
if ($Guard) { Write-Host (T "  Режим guard    : $GuardMode" "  Guard mode     : $GuardMode") }
Write-Host (T "  Обновления     : $vUpd" "  Updates        : $vUpd")
if (-not $DryRun -and $dotNetPayload) { Write-Host (T "  .NET           : $DotNetUpdateFile" "  .NET           : $DotNetUpdateFile") }
$vOobeNet = if ($NoOobeNetworkBlock) { T 'сеть включена  (OOBE скачает обновления)' 'network on  (OOBE will download updates)' }
            else { T 'сеть выключена, вернётся при первом входе' 'network off, restored at first logon' }
Write-Host (T "  OOBE           : $vOobeNet" "  OOBE           : $vOobeNet")
Write-Host (T "  Сжатие         : $Compression" "  Compression    : $Compression")

if ($DryRun) {
    Write-Host ''
    Write-Ok (T 'DryRun завершён — ничего не изменено' 'DryRun finished - nothing was changed')
    return
}

#region ── Распаковка ISO после подготовки загрузок ──────────────────────────
Ensure-WimMountDriver
Write-Stage (T 'Распаковка исходного ISO' 'Extracting the source ISO')
# --- висящие точки монтирования ---
if ($isAdmin -and -not $DryRun) {
    $mountInfo = Invoke-Dism -Arguments @('/Get-MountedImageInfo') -AllowFail -Quiet
    $stale = @($mountInfo.Output | Select-String -Pattern '^\s*Mount Dir\s*:\s*(.+?)\s*$' |
               ForEach-Object { $_.Matches[0].Groups[1].Value })
    foreach ($dir in $stale) {
        if ($dir -notin @($mountDir, $bootMountDir)) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $WorkDir $script:WorkDirMarker))) { throw (T "Чужая точка монтирования: $dir" "Unowned mount: $dir") }
        Write-Note (T "Отцепляю оставшийся с прошлого раза образ: $dir" "Discarding image left over from a previous run: $dir")
        Invoke-Dism -Arguments @('/Unmount-Image', "/MountDir:$dir", '/Discard') -Quiet | Out-Null
    }
    Write-Ok (T 'Проверены точки монтирования этой сборки' 'Checked mount points belonging to this build')
}

if (-not $DryRun) {
    if (Test-Path $WorkDir) {
        # Три независимые проверки, и все должны пройти: путь ведёт в нашу
        # подпапку, это не системный каталог, и внутри лежит наша метка.
        if (-not (Test-SafeToWipe $WorkDir)) {
            throw (T "Отказываюсь очищать $WorkDir — путь не похож на рабочий каталог скрипта. Укажите другой через -WorkDir." `
                     "Refusing to wipe $WorkDir - the path does not look like this script's work folder. Pick another one with -WorkDir.")
        }
        $markerPath = Join-Path $WorkDir $script:WorkDirMarker
        $hasContent = @(Get-ChildItem -LiteralPath $WorkDir -Force -ErrorAction SilentlyContinue).Count -gt 0
        if ($hasContent -and -not (Test-Path -LiteralPath $markerPath)) {
            throw (T @"
Рабочий каталог $WorkDir не пуст и не помечен как созданный этим скриптом.

Перед сборкой он очищается целиком, поэтому удалять чужие файлы скрипт не станет.
Укажите пустую или несуществующую папку через -WorkDir, либо удалите содержимое вручную.
"@ @"
The work folder $WorkDir is not empty and was not created by this script.

It is wiped before every build, so the script refuses to delete files it does not own.
Point -WorkDir at an empty or non-existent folder, or clear it manually.
"@)
        }
        Write-Step (T 'Очищаю рабочий каталог от предыдущего прогона' 'Clearing the work folder from a previous run')
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }
    $null = New-Item -ItemType Directory -Path $isoDir, $mountDir, $bootMountDir -Force
    $script:WorkPrepared = $true
    # Метка: по ней следующий прогон поймёт, что каталог наш и его можно чистить
    Set-Content -LiteralPath (Join-Path $WorkDir $script:WorkDirMarker) `
                -Value "win-11-lite work folder, safe to delete`r`n$(Get-Date -Format s)" -Encoding ascii
}
Write-Step (T 'Копирую содержимое ISO в рабочий каталог ...' 'Copying ISO contents to the work folder ...')
# Знаменатель для полосы: объём тома ISO, при отказе — размер самого файла.
$script:CopyTotal = if ($vol.Size -gt 0) { [int64]$vol.Size } else { (Get-Item -LiteralPath $InputIso).Length }
$copyRun = Invoke-ProgressProcess -Exe 'robocopy.exe' -Activity (T 'Копирование файлов ISO' 'Copying ISO files') `
    -Arguments @("$srcDrive\", $isoDir, '/E', '/R:2', '/W:2', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') `
    -SuccessCodes (0..7) -GetPercent { Get-CopyPercent -Path $isoDir -TotalBytes $script:CopyTotal }
if ($copyRun.ExitCode -ge 8) { throw (T "robocopy завершился с кодом $($copyRun.ExitCode)" "robocopy exited with code $($copyRun.ExitCode)") }
# Один проход по дереву: снимаем «только чтение» с носителя и считаем объём
$copied = 0
Get-ChildItem -LiteralPath $isoDir -Recurse -Force -File | ForEach-Object { $_.IsReadOnly = $false; $copied += $_.Length }
Write-Ok (T "Скопировано $(Format-Size $copied)" "Copied $(Format-Size $copied)")
$srcSources = Join-Path $isoDir 'sources'
$srcInstall = Join-Path $srcSources $(if ($srcIsEsd) { 'install.esd' } else { 'install.wim' })
#endregion
#region ── Стадия 3. Экспорт выбранного индекса ────────────────────────────────

Write-Stage (T 'Экспорт выбранного индекса в отдельный WIM' 'Exporting the selected index to a separate WIM')

Invoke-Dism -Arguments @(
    '/Export-Image'
    "/SourceImageFile:$srcInstall"
    "/SourceIndex:$srcIndex"
    "/DestinationImageFile:$wimPath"
    '/Compress:max'
    '/CheckIntegrity'
) -Activity (T "Экспорт индекса $srcIndex" "Exporting index $srcIndex") | Out-Null

Remove-Item -LiteralPath $srcInstall -Force
Write-Ok (T "install.wim: $(Format-Size (Get-Item -LiteralPath $wimPath).Length)" "install.wim: $(Format-Size (Get-Item -LiteralPath $wimPath).Length)")

#endregion

#region ── Стадия 5. Монтирование образа ───────────────────────────────────────

Write-Stage (T 'Монтирование образа' 'Mounting the image')

Invoke-Dism -Arguments @('/Mount-Image', "/ImageFile:$wimPath", '/Index:1', "/MountDir:$mountDir") -Activity (T 'Монтирование образа' 'Mounting the image') | Out-Null
$script:Mounted = $true
Write-Ok (T "Образ смонтирован в $mountDir" "Image mounted at $mountDir")
if ($Preset -eq 'balanced') { Write-ComponentStoreReport -Image $mountDir -Phase 'source' }
# Запоминаем, где WebView2 лежал до обслуживания: финальная проверка сравнит
$script:PreservedWebView = @()
if ($Preset -ne 'max') { $script:PreservedWebView = @(Get-WebViewRuntimeRoots -Image $mountDir) }

#endregion

#region ── Интеграция языков ───────────────────────────────────────────────────

# Языки ставятся строго до накопительных обновлений: LCU дополняет ресурсы
# уже установленных языков, а добавленный после него пакет останется без правок
# и потребует повторного применения LCU.
if ($AddLanguage) {
    Write-Stage (T "Интеграция языков: $($AddLanguage -join ', ')" "Adding languages: $($AddLanguage -join ', ')")

    $kinds = @('Pack', 'Basic')

    # FoD lookup requires CBS identity filenames, not UUP download filenames.
    # Keep aliases in our work directory; a read-only LoF ISO is never modified.
    $fodSource = Join-Path $WorkDir 'language-fod'
    $null = New-Item -ItemType Directory -Path $fodSource -Force
    $sourcePackages = Invoke-Dism -Arguments @("/Image:$mountDir", '/Get-Packages') -Quiet
    $needsLanguageRepair = @($sourcePackages.Output | Where-Object { $_ -match 'Package_for_RollupFix' }).Count -gt 0
    if ($needsLanguageRepair -and $UpdateMode -eq 'none' -and -not $LanguageUpdatePath) {
        throw (T 'Для языков не подготовлен обязательный LCU. Повторите подготовку с -LanguageUpdatePath или -WithUpdates.' 'Required language LCU was not prepared. Run preparation with -LanguageUpdatePath or -WithUpdates.')
    }
    $addedLangs = @()
    foreach ($tag in $AddLanguage) {
        Write-Step (T "Язык $tag" "Language $tag")
        # Pack и Basic обязательны: любой отказ DISM здесь останавливает сборку
        # (Invoke-Dism без -AllowFail бросает исключение сам).
        foreach ($kind in $kinds) {
            $pkg = Find-LanguagePackage -Root $langRoot -Tag $tag -Kind $kind
            if (-not $pkg) {
                throw (T "Обязательный пакет $kind для $tag не найден в $langRoot" "Required language package $kind for $tag not found in $langRoot")
            }

            # Основной языковой пакет ставится как пакет, а LanguageFeatures —
            # это Features on Demand: через Add-Package они дают 0x800F081F,
            # нужен Add-Capability с указанием папки-источника
            if ($kind -eq 'Pack') {
                $packageInfo = Invoke-Dism -Arguments @("/Image:$mountDir", '/Get-PackageInfo', "/PackagePath:$($pkg.FullName)") -Quiet
                $identity = @($packageInfo.Output | Where-Object { $_ -match '^\s*Package Identity\s*:' }) -join ' '
                if ($identity -notmatch ('~amd64~' + [regex]::Escape($tag) + '~10\.0\.(\d+)\.\d+')) {
                    throw (T "Неожиданный идентификатор языкового пакета: $identity" "Unexpected language package identity: $identity")
                }
                $lpBuild = [int]$matches[1]
                if ($lpBuild -ne $buildNumber -and -not ($buildNumber -eq 26200 -and $lpBuild -eq 26100)) { throw (T "Несовместимый языковой пакет: $identity" "Incompatible language package: $identity") }
                Invoke-Dism -Arguments @("/Image:$mountDir", '/Add-Package', "/PackagePath:$($pkg.FullName)") -Quiet `
                            -Activity (T "Языковой пакет $tag" "Language pack $tag") | Out-Null
            } else {
                $capSource = $pkg.DirectoryName
                if ($pkg.Extension -eq '.cab') {
                    $aliasPath = Join-Path $fodSource (Get-FodSourceName -Tag $tag -Kind $kind)
                    Copy-Item -LiteralPath $pkg.FullName -Destination $aliasPath -Force
                    $capSource = $fodSource
                }
                $capName = "Language.$kind~~~$tag~0.0.1.0"
                Invoke-Dism -Arguments @(
                    "/Image:$mountDir", '/Add-Capability', "/CapabilityName:$capName",
                    "/Source:$capSource", "/Source:$langRoot", '/LimitAccess'
                ) -Quiet -Activity (T "Языковой компонент $kind для $tag" "Language capability $kind for $tag") | Out-Null
            }
            Write-Ok "  $kind — $($pkg.Name) ($(Format-Size $pkg.Length))"
        }

        # Local Experience Pack локализует интерфейс современных приложений.
        # В LTSC нет Store, поэтому ставим его как provisioned-пакет.
        $lxp = Find-LanguagePackage -Root $langRoot -Tag $tag -Kind 'LXP'
        if ($lxp) {
            $lic = Get-ChildItem -LiteralPath $lxp.DirectoryName -Filter '*.xml' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            $lxpArgs = @("/Image:$mountDir", '/Add-ProvisionedAppxPackage', "/PackagePath:$($lxp.FullName)")
            if ($lic) { $lxpArgs += "/LicensePath:$($lic.FullName)" } else { $lxpArgs += '/SkipLicense' }
            Invoke-Dism -Arguments $lxpArgs -Quiet -Activity (T "Local Experience Pack $tag" "Local Experience Pack $tag") | Out-Null
            Write-Ok "  LXP — $($lxp.Name)"
        }
        $addedLangs += $tag
    }

    if ($addedLangs) {
        # Первый язык из списка становится языком интерфейса, локалью и раскладкой.
        # Отказ DISM здесь фатален: иначе answer-файл и система разойдутся в языке.
        $primary = $addedLangs[0]
        Write-Step (T "Делаю $primary языком по умолчанию" "Setting $primary as the default language")
        Invoke-Dism -Arguments @("/Image:$mountDir", "/Set-AllIntl:$primary") -Quiet | Out-Null
        Invoke-Dism -Arguments @("/Image:$mountDir", "/Set-SysUILang:$primary") -Quiet | Out-Null
        Write-Ok (T "Язык интерфейса, локаль и раскладка: $primary" "Display language, locale and keyboard layout: $primary")
        # autounattend и ярлык Firefox должны говорить на новом языке
        $imgLang = $primary
        $mozLang = $script:MozillaLang[$primary]
        if (-not $mozLang) { $mozLang = ($primary -split '-')[0] }
        Write-Ok (T "Язык для загрузки Firefox: $mozLang" "Firefox download language: $mozLang")
        Write-Ok (T "Язык установщика: $setupLang" "Setup language: $setupLang")
    } else {
        throw (T 'Ни один запрошенный язык не установлен' 'No requested language was installed')
    }

    if ($LanguageUpdatePath) {
        Invoke-Dism -Arguments @("/Image:$mountDir", '/Add-Package', "/PackagePath:$LanguageUpdatePath") -Activity (T 'Обслуживание языковых ресурсов с помощью LCU' 'Servicing language resources with LCU') | Out-Null
    }

    if ($langIsoMounted) {
        Dismount-DiskImage -ImagePath $langIsoMounted | Out-Null
        $script:LangIso = $null
    }
}

#endregion

#region ── Стадия 6. Интеграция обновлений ─────────────────────────────────────

if ($lcuPayload -or $dotNetPayload) {
    Write-Stage (T 'Интеграция обновлений (самая долгая стадия, 30–60 минут)' 'Applying updates (the longest stage, 30-60 minutes)')

    # Порядок принципиален: сначала обновления, потом удаления — LCU способен
    # вернуть в образ то, что мы вырежем раньше времени.
    if ($lcuPayload) {
        # Цель записана по номеру KB каталога или указана пользователем;
        # checkpoint-обновления DISM найдёт в этой же папке самостоятельно.
        $target = Get-Item -LiteralPath $lcuPayload
        Invoke-Dism -Arguments @("/Image:$mountDir", '/Add-Package', "/PackagePath:$($target.FullName)") -Activity (T "Интеграция $($target.Name)" "Applying $($target.Name)") | Out-Null
        Write-Ok (T 'Накопительное обновление интегрировано' 'Cumulative update applied')
    }

    if ($dotNetPayload) {
        $target = Get-Item -LiteralPath $dotNetPayload
        Invoke-Dism -Arguments @("/Image:$mountDir", '/Add-Package', "/PackagePath:$($target.FullName)") -Activity (T "Интеграция $($target.Name)" "Applying $($target.Name)") | Out-Null
        Write-Ok (T 'Обновление .NET интегрировано' '.NET update applied')
    }

    Write-Ok (T 'Образ обновлён' 'Image updated')
}

if ($DriversDir -and (Test-Path $DriversDir)) {
    Write-Step (T "Интегрирую драйверы из $DriversDir" "Adding drivers from $DriversDir")
    Invoke-Dism -Arguments @("/Image:$mountDir", '/Add-Driver', "/Driver:$DriversDir", '/Recurse') `
                -Activity (T 'Интеграция драйверов' 'Adding drivers') | Out-Null
    Write-Ok (T 'Драйверы интегрированы' 'Drivers added')
}

if ($Preset -eq 'balanced') {
    Write-ComponentStoreReport -Image $mountDir -Phase 'after-integration'
    Remove-OfflineRecall -Image $mountDir
}

#endregion

#region ── Стадия 7. Сохранение и удаление WinRE ───────────────────────────────

# Ключ задан явно, поэтому пресет роли не играет: удаление блокирует только -Keep WinRE
if ($RemoveWinRE -and (Test-GroupActive -RulePreset 'safe' -Group 'WinRE')) {
    Write-Stage (T 'Удаление среды восстановления' 'Removing the recovery environment')
    if (-not $LegacySetup) {
        Write-Note (T 'Без -LegacySetup установка упадёт с 0x80070003: новый установщик извлекает winre.wim в SafeOS' 'Without -LegacySetup the installation fails with 0x80070003: the new setup extracts winre.wim into SafeOS')
    }

    $winre = Join-Path $mountDir 'Windows\System32\Recovery\Winre.wim'
    if (Test-Path -LiteralPath $winre) {
        # Копия рядом с ISO нужна лишь тем, кто планирует вернуть WinRE
        # через reagentc. По умолчанию файл просто удаляется.
        if ($SaveWinRE) {
            $winreOut = Join-Path (Split-Path $OutputIso -Parent) ("{0}_winre.wim" -f [IO.Path]::GetFileNameWithoutExtension($OutputIso))
            Copy-Item -LiteralPath $winre -Destination $winreOut -Force
            Write-Ok (T "Winre.wim сохранён: $winreOut  ($(Format-Size (Get-Item $winreOut).Length))" "Winre.wim saved: $winreOut  ($(Format-Size (Get-Item $winreOut).Length))")
            Write-Note (T 'Вернуть среду восстановления: скопировать этот файл в C:\Windows\System32\Recovery\ и выполнить reagentc /setreimage /path C:\Windows\System32\Recovery && reagentc /enable' 'To restore the recovery environment: copy this file to C:\Windows\System32\Recovery\ and run reagentc /setreimage /path C:\Windows\System32\Recovery && reagentc /enable')
        }
        Remove-ImagePath -FullPath $winre -Description 'WinRE (Winre.wim)' | Out-Null
    } else {
        Write-Note (T 'Winre.wim в образе не найден' 'Winre.wim not found in the image')
    }
}

#endregion

#region ── Стадия 8. Удаление возможностей (capabilities) ──────────────────────

Write-Stage (T 'Удаление возможностей Windows' 'Removing Windows capabilities')

$capsRaw = Invoke-Dism -Arguments @("/Image:$mountDir", '/Get-Capabilities') -Quiet
# @(): у одиночного PSCustomObject в Windows PowerShell 5.1 нет свойства Count
$caps = @(ConvertFrom-DismList -Lines $capsRaw.Output -Key 'Capability Identity' |
        Where-Object { $_.State -eq 'Installed' -or ($Preset -eq 'balanced' -and $_.State -in @('Staged', 'Install Pending', 'Uninstall Pending')) })
Write-Step (T "Возможностей с файлами или ожидающими действиями: $($caps.Count)" "Capabilities with payload or pending actions: $($caps.Count)")

$patterns = @()
foreach ($rule in $script:CapabilityRules) {
    if (Test-GroupActive -RulePreset $rule.Preset -Group $rule.Group) { $patterns += $rule.Pattern }
}
$patterns += $RemoveExtra

$removedCaps = 0
foreach ($cap in $caps) {
    $name = $cap.'Capability Identity'
    if (Test-Protected $name) { continue }
    foreach ($pattern in $patterns) {
        if ($name -match $pattern) {
            if ($cap.State -match 'Pending') {
                Write-Note (T "$name — $($cap.State), удаление offline отложено до завершения обслуживания при загрузке Windows" "$name - $($cap.State), offline removal deferred until servicing completes when Windows boots")
                break
            }
            Write-Step (T "Удаляю возможность $name" "Removing capability $name")
            $r = Invoke-Dism -Arguments @("/Image:$mountDir", '/Remove-Capability', "/CapabilityName:$name") -AllowFail -Quiet
            if (Test-DismSuccess $r.ExitCode) { $removedCaps++; Write-Ok $name }
            else { Write-ServicingRemovalFailure -Kind 'Capability' -Name $name -Result $r }
            break
        }
    }
}
Write-Ok (T "Удалено возможностей: $removedCaps" "Capabilities removed: $removedCaps")

#endregion

#region ── Стадия 9. Удаление пакетов компонентов ──────────────────────────────

Write-Stage (T 'Удаление пакетов компонентов' 'Removing component packages')

$pkgRaw = Invoke-Dism -Arguments @("/Image:$mountDir", '/Get-Packages') -Quiet
$pkgs = @(ConvertFrom-DismList -Lines $pkgRaw.Output -Key 'Package Identity' |
        Where-Object { $_.State -eq 'Installed' -or ($Preset -eq 'balanced' -and $_.State -in @('Staged', 'Install Pending', 'Uninstall Pending')) })
Write-Step (T "Пакетов с файлами или ожидающими действиями: $($pkgs.Count)" "Packages with payload or pending actions: $($pkgs.Count)")

$patterns = @()
foreach ($rule in $script:PackageRules) {
    if (Test-GroupActive -RulePreset $rule.Preset -Group $rule.Group) { $patterns += $rule.Pattern }
}
$patterns += $RemoveExtra

$removedPkgs = 0; $failedPkgs = 0; $skippedPkgs = 0
foreach ($pkg in $pkgs) {
    $name = $pkg.'Package Identity'
    if (Test-Protected $name) { continue }
    foreach ($pattern in $patterns) {
        if ($name -match $pattern) {
            if ($pkg.State -match 'Pending') {
                Write-Note (T "$name — $($pkg.State), удаление offline отложено до завершения обслуживания при загрузке Windows" "$name - $($pkg.State), offline removal deferred until servicing completes when Windows boots")
                break
            }
            $skipReason = Get-PackageRemovalSkipReason -PackageName $name
            if ($skipReason) {
                $skippedPkgs++
                if (-not $script:ImageAudit.Contains('SkippedRemovals')) { $script:ImageAudit['SkippedRemovals'] = @() }
                $script:ImageAudit.SkippedRemovals += [pscustomobject]@{Kind='Package';Name=$name;Reason=$skipReason}
                Write-Note (T "$name оставлен: удаление Sense через capability уже отклонено CBS; пакетный повтор пропущен" "$name retained: CBS already rejected Sense capability removal; duplicate package attempt skipped")
                Save-ImageAudit
                break
            }
            $r = Invoke-Dism -Arguments @("/Image:$mountDir", '/Remove-Package', "/PackageName:$name") -AllowFail -Quiet
            if (Test-DismSuccess $r.ExitCode) { $removedPkgs++; Write-Ok ($name -replace '~.*', '') }
            else { $failedPkgs++; Write-ServicingRemovalFailure -Kind 'Package' -Name $name -Result $r }
            break
        }
    }
}
Write-Ok (T "Удалено пакетов: $removedPkgs; не удалось удалить: $failedPkgs; повторных попыток пропущено: $skippedPkgs" "Packages removed: $removedPkgs; failed removals: $failedPkgs; duplicate attempts skipped: $skippedPkgs")

#endregion

#region ── Стадия 10. Удаление provisioned Appx ────────────────────────────────

Write-Stage (T 'Удаление встроенных приложений' 'Removing provisioned apps')

$appxRaw = Invoke-Dism -Arguments @("/Image:$mountDir", '/Get-ProvisionedAppxPackages') -Quiet
$appx = @(ConvertFrom-DismList -Lines $appxRaw.Output -Key 'DisplayName')
Write-Step (T "Встроенных приложений: $($appx.Count)" "Provisioned apps: $($appx.Count)")

$patterns = @()
foreach ($rule in $script:AppxRules) {
    if (Test-GroupActive -RulePreset $rule.Preset -Group $rule.Group) { $patterns += $rule.Pattern }
}

$removedAppx = 0
foreach ($app in $appx) {
    if (Test-Protected $app.DisplayName) { continue }
    foreach ($pattern in $patterns) {
        if ($app.DisplayName -match $pattern) {
            $r = Invoke-Dism -Arguments @("/Image:$mountDir", '/Remove-ProvisionedAppxPackage', "/PackageName:$($app.PackageName)") -AllowFail -Quiet
            if (Test-DismSuccess $r.ExitCode) { $removedAppx++; Write-Ok $app.DisplayName }
            else { Write-ServicingRemovalFailure -Kind 'Appx' -Name $app.DisplayName -Result $r }
            break
        }
    }
}
Write-Ok (T "Удалено приложений: $removedAppx" "Apps removed: $removedAppx")

#endregion

#region ── Стадия 11. Удаление файлов Edge и Defender ──────────────────────────

function Remove-SelectedImageFiles {
foreach ($rule in $script:FolderRules) {
    if (-not (Test-GroupActive -RulePreset $rule.Preset -Group $rule.Group)) { continue }
    Remove-ImagePath -FullPath (Join-Path $mountDir $rule.Path) -Description $rule.Desc | Out-Null
}
foreach ($rule in $script:FileRules) {
    if (-not (Test-GroupActive -RulePreset $rule.Preset -Group $rule.Group)) { continue }
    $p = Join-Path $mountDir $rule.Path
    if (Test-Path -LiteralPath $p) { Remove-ImagePath -FullPath $p -Description $rule.Desc | Out-Null }
}

# Задания планировщика телеметрии
$tasksRemoved = 0
foreach ($rule in $script:TaskFiles) {
    if (-not (Test-GroupActive -RulePreset $rule.Preset -Group $rule.Group)) { continue }
    $p = Join-Path $mountDir $rule.Path
    if (Test-Path -LiteralPath $p) {
        Grant-ImagePathAccess -Path $p
        try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop; $tasksRemoved++ } catch { }
    }
}
if ($tasksRemoved) { Write-Ok (T "Заданий телеметрии удалено: $tasksRemoved" "Telemetry tasks removed: $tasksRemoved") }

# CJK-шрифты: удаляются только файлами, пакетов для них в /Get-Packages нет
if (Test-GroupActive -RulePreset 'balanced' -Group 'Fonts') {
    $fontsDir = Join-Path $mountDir 'Windows\Fonts'
    $bootFontsDir = Join-Path $mountDir 'Windows\Boot\Fonts'
    $fontFiles = @()
    foreach ($mask in $script:FontPatterns) {
        $fontFiles += @(Get-ChildItem -LiteralPath $fontsDir -Filter $mask -Force -ErrorAction SilentlyContinue)
    }
    foreach ($mask in $script:BootFontPatterns) {
        $fontFiles += @(Get-ChildItem -LiteralPath $bootFontsDir -Filter $mask -Force -ErrorAction SilentlyContinue)
    }
    $fontFiles = $fontFiles | Sort-Object FullName -Unique
    if ($fontFiles) {
        $removed = 0
        $freed = 0
        $script:RemovedFonts = @()
        foreach ($f in $fontFiles) {
            # Владение берём на каждый файл: takeown на папку без /R прав на
            # содержимое не даёт, и удаление падает с «Access denied»
            Grant-ImagePathAccess -Path $f.FullName
            try {
                $size = $f.Length
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $removed++
                $freed += $size
                $script:RemovedFonts += $f.Name
            } catch {
                Write-DiagnosticLog (T "Шрифт $($f.Name): $($_.Exception.Message)" "Font $($f.Name): $($_.Exception.Message)")
            }
        }
        $script:FreedBytes += $freed
        if ($removed -eq $fontFiles.Count) {
            Write-Ok (T "CJK-шрифты — удалено файлов: $removed ($(Format-Size $freed))" "CJK fonts - files removed: $removed ($(Format-Size $freed))")
        } else {
            Write-Note (T "CJK-шрифты — удалено $removed из $($fontFiles.Count) ($(Format-Size $freed))" "CJK fonts - removed $removed of $($fontFiles.Count) ($(Format-Size $freed))")
        }
    }
}

# AI-компоненты: имена папок зависят от билда, поэтому ищем по маске
if (Test-GroupActive -RulePreset 'balanced' -Group 'AI') {
    foreach ($rule in $script:AiFolderPatterns) {
        $parent = Join-Path $mountDir $rule.Parent
        if (-not (Test-Path -LiteralPath $parent)) { continue }
        foreach ($hit in @(Get-ChildItem -LiteralPath $parent -Filter $rule.Mask -Force -ErrorAction SilentlyContinue)) {
            Remove-ImagePath -FullPath $hit.FullName -Description "$($rule.Desc): $($hit.Name)" | Out-Null
        }
    }
}
}

Write-Stage (T 'Удаление файлов Edge и Defender' 'Removing Edge and Defender files')
Remove-SelectedImageFiles

if (Test-GroupActive -RulePreset 'safe' -Group 'Edge') {
    if ($Preset -ne 'max') {
        Write-Note (T 'WebView2 и EdgeUpdate оставлены — они нужны обычным приложениям' 'WebView2 and EdgeUpdate are kept - regular applications depend on them')
    }
}
if (Test-GroupActive -RulePreset 'balanced' -Group 'Defender') {
    Write-Note (T 'Бинарники Defender защищены CBS: sfc /scannow или следующий LCU могут их вернуть. Службы останутся отключёнными.' 'Defender binaries are CBS-protected: sfc /scannow or the next LCU may restore them. The services stay disabled.')
}

#endregion

#region ── Стадия 12. Offline-реестр ───────────────────────────────────────────

Write-Stage (T 'Настройка offline-реестра' 'Configuring the offline registry')

Mount-Hive -Name 'LITE_SOFTWARE' -File (Join-Path $mountDir 'Windows\System32\config\SOFTWARE')
Mount-Hive -Name 'LITE_SYSTEM'   -File (Join-Path $mountDir 'Windows\System32\config\SYSTEM')
Mount-Hive -Name 'LITE_DEFAULT'  -File (Join-Path $mountDir 'Users\Default\NTUSER.DAT')
Write-Ok (T 'Кусты реестра смонтированы' 'Registry hives mounted')

# --- службы ---
$svcCount = 0
foreach ($group in $script:DisableServices) {
    if ($group.Group -eq 'Defender' -and -not (Test-GroupActive -RulePreset 'balanced' -Group 'Defender')) { continue }
    foreach ($svc in $group.Names) {
        $key = "HKLM\LITE_SYSTEM\ControlSet001\Services\$svc"
        # Службы нет в образе — reg query возвращает 1, и это не ошибка
        if ((Invoke-RegCommand -Arguments @('query', $key)).ExitCode -eq 0) {
            Set-Reg -Path $key -Name 'Start' -Type REG_DWORD -Value 4
            $svcCount++
        }
    }
}
Write-Ok (T "Отключено служб: $svcCount" "Services disabled: $svcCount")

# --- Defender: политики ---
if (Test-GroupActive -RulePreset 'balanced' -Group 'Defender') {
    $p = 'HKLM\LITE_SOFTWARE\Policies\Microsoft\Windows Defender'
    Set-Reg -Path $p -Name 'DisableAntiSpyware' -Type REG_DWORD -Value 1
    Set-Reg -Path $p -Name 'DisableAntiVirus'   -Type REG_DWORD -Value 1
    Set-Reg -Path "$p\Real-Time Protection" -Name 'DisableRealtimeMonitoring' -Type REG_DWORD -Value 1
    Set-Reg -Path "$p\Real-Time Protection" -Name 'DisableBehaviorMonitoring' -Type REG_DWORD -Value 1
    Set-Reg -Path 'HKLM\LITE_SOFTWARE\Policies\Microsoft\Windows\System' -Name 'EnableSmartScreen' -Type REG_DWORD -Value 0
    Write-Ok (T 'Defender отключён политиками' 'Defender disabled by policy')
}

# --- телеметрия ---
Set-Reg -Path 'HKLM\LITE_SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Type REG_DWORD -Value 0
Set-Reg -Path 'HKLM\LITE_SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' -Name 'AllowTelemetry' -Type REG_DWORD -Value 0
Set-Reg -Path 'HKLM\LITE_SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'DoNotShowFeedbackNotifications' -Type REG_DWORD -Value 1

# --- реклама и «рекомендации» ---
$cc = 'HKLM\LITE_SOFTWARE\Policies\Microsoft\Windows\CloudContent'
Set-Reg -Path $cc -Name 'DisableWindowsConsumerFeatures'  -Type REG_DWORD -Value 1
Set-Reg -Path $cc -Name 'DisableSoftLanding'              -Type REG_DWORD -Value 1
Set-Reg -Path $cc -Name 'DisableCloudOptimizedContent'    -Type REG_DWORD -Value 1
Set-Reg -Path $cc -Name 'DisableConsumerAccountStateContent' -Type REG_DWORD -Value 1

# --- виджеты ---
# Запись TaskbarDa в NTUSER.DAT может блокироваться защитой Windows хоста.
# Документированная политика действует на все профили, включая IoT LTSC.
# https://learn.microsoft.com/windows/client-management/mdm/policy-csp-newsandinterests#allownewsandinterests
Set-Reg -Path 'HKLM\LITE_SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Type REG_DWORD -Value 0
Write-Ok (T 'Виджеты отключены политикой' 'Widgets disabled by policy')

# --- Recall, Click to Do, Copilot ---
# AllowRecallEnablement=0 не просто прячет Recall: по документации Microsoft
# «the bits for Recall will be removed from the device», то есть компонент
# выгружается с устройства, а сохранённые снимки удаляются.
if (Test-GroupActive -RulePreset 'balanced' -Group 'AI') {
$ai = 'HKLM\LITE_SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
Set-Reg -Path $ai -Name 'AllowRecallEnablement'   -Type REG_DWORD -Value 0   # по умолчанию 1 — Recall доступен
Set-Reg -Path $ai -Name 'DisableAIDataAnalysis'   -Type REG_DWORD -Value 1   # снимки экрана не сохраняются
Set-Reg -Path $ai -Name 'AllowRecallExport'       -Type REG_DWORD -Value 0
Set-Reg -Path $ai -Name 'DisableClickToDo'        -Type REG_DWORD -Value 1   # по умолчанию 0 — включён
Set-Reg -Path $ai -Name 'DisableSettingsAgent'    -Type REG_DWORD -Value 1
Set-Reg -Path $ai -Name 'DisableRecallDataProviders' -Type REG_DWORD -Value 1
Set-Reg -Path $ai -Name 'RemoveMicrosoftCopilotApp'  -Type REG_DWORD -Value 1
Set-Reg -Path 'HKLM\LITE_SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Type REG_DWORD -Value 1

# AI в Paint
$paint = 'HKLM\LITE_SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'
Set-Reg -Path $paint -Name 'DisableCocreator'     -Type REG_DWORD -Value 1
Set-Reg -Path $paint -Name 'DisableGenerativeFill' -Type REG_DWORD -Value 1
Set-Reg -Path $paint -Name 'DisableImageCreator'  -Type REG_DWORD -Value 1
Write-Ok (T 'Recall, Click to Do, Copilot и AI в Paint отключены политиками' 'Recall, Click to Do, Copilot and Paint AI disabled by policy')
}

# --- Edge: запрет переустановки, WebView2 разрешён ---
if (Test-GroupActive -RulePreset 'safe' -Group 'Edge') {
    # EdgeUpdate остаётся в образе ради WebView2 — но его прямая работа в том,
    # чтобы ставить Edge. Одного Install{Stable}=0 мало: запрещаем установку всем
    # каналам по умолчанию (InstallDefault) и точечно разрешаем только WebView2.
    $eu = 'HKLM\LITE_SOFTWARE\Policies\Microsoft\EdgeUpdate'
    Set-Reg -Path $eu -Name 'InstallDefault' -Type REG_DWORD -Value 0        # по умолчанию не ставить ничего
    Set-Reg -Path $eu -Name 'UpdateDefault'  -Type REG_DWORD -Value 0        # и не обновлять
    Set-Reg -Path $eu -Name 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' -Type REG_DWORD -Value 0  # Edge Stable
    Set-Reg -Path $eu -Name 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'  -Type REG_DWORD -Value 0
    Set-Reg -Path $eu -Name 'Install{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}' -Type REG_DWORD -Value 0  # Edge Beta
    Set-Reg -Path $eu -Name 'Install{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}' -Type REG_DWORD -Value 0  # Edge Dev
    Set-Reg -Path $eu -Name 'Install{65C35B14-6C1D-4122-AC46-7148CC9D6497}' -Type REG_DWORD -Value 0  # Edge Canary
    Set-Reg -Path $eu -Name 'Install{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -Type REG_DWORD -Value 1  # WebView2 — разрешён
    Set-Reg -Path $eu -Name 'Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'  -Type REG_DWORD -Value 1
    Set-Reg -Path $eu -Name 'DoNotUpdateToEdgeWithChromium' -Type REG_DWORD -Value 1
    # Тот же набор ключей, что чистит Finalize.ps1 после OOBE
    $stableGuid = '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
    foreach ($view in @('', '\WOW6432Node')) {
        foreach ($suffix in @("Microsoft\EdgeUpdate\Clients\$stableGuid", "Microsoft\EdgeUpdate\ClientState\$stableGuid",
                              "Microsoft\EdgeUpdate\ClientStateMedium\$stableGuid",
                              'Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
                              'Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
                              'Clients\StartMenuInternet\Microsoft Edge')) {
            Remove-Reg -Path "HKLM\LITE_SOFTWARE$view\$suffix"
        }
    }
    Write-Ok (T 'Регистрация браузера Edge удалена; политики дополнены очисткой после OOBE' 'Edge browser registration removed; policies supplemented by post-OOBE cleanup')
}

# --- записи об удалённых шрифтах ---
if ($script:RemovedFonts) {
    $fontKey = 'HKLM\LITE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $raw = (Invoke-RegCommand -Arguments @('query', $fontKey)).Output -split '\r?\n'
    foreach ($line in $raw) {
        if ($line -match '^\s{4}(.+?)\s{4}REG_SZ\s{4}(.+?)\s*$') {
            if ($script:RemovedFonts -contains $matches[2].Trim()) {
                $null = Invoke-RegCommand -Arguments @('delete', $fontKey, '/v', $matches[1].Trim(), '/f')
            }
        }
    }
    Write-Ok (T 'Записи об удалённых шрифтах убраны из реестра' 'Registry entries for removed fonts cleaned up')
}

# --- локальный аккаунт в OOBE ---
Set-Reg -Path 'HKLM\LITE_SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' -Name 'BypassNRO' -Type REG_DWORD -Value 1

# --- обновления во время установки ---
# Временные настройки снимает SYSTEM-задача при первом входе, после OOBE.
# Пользовательский answer-файл сам управляет установкой, временные блоки ему не навязываем.
if ($script:ManageOobe) {
    Set-Reg -Path 'HKLM\LITE_SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoUpdate' -Type REG_DWORD -Value 1
    Set-Reg -Path 'HKLM\LITE_SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name 'DoNotConnectToWindowsUpdateInternetLocations' -Type REG_DWORD -Value 1
    Set-Reg -Path 'HKLM\LITE_SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' -Name 'DisableOOBEUpdate' -Type REG_DWORD -Value 1
}
if (Test-GroupActive -RulePreset 'balanced' -Group 'OneDrive') {
    $null = Invoke-RegCommand -Arguments @('delete', 'HKLM\LITE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Run', '/v', 'OneDriveSetup', '/f')
}

# --- зарезервированное хранилище: до 7 ГБ на системном диске ---
Set-Reg -Path 'HKLM\LITE_SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' -Name 'ShippedWithReserves' -Type REG_DWORD -Value 0

# --- не шифровать диск автоматически при первом входе ---
# Иначе BitLocker включается молча, а ключ уходит в аккаунт Microsoft, которого у нас нет
Set-Reg -Path 'HKLM\LITE_SYSTEM\ControlSet001\Control\BitLocker' -Name 'PreventDeviceEncryption' -Type REG_DWORD -Value 1

# --- обход требований TPM / Secure Boot ---
if (-not $NoBypass) {
    $lab = 'HKLM\LITE_SYSTEM\Setup\LabConfig'
    foreach ($n in 'BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassStorageCheck', 'BypassCPUCheck') {
        Set-Reg -Path $lab -Name $n -Type REG_DWORD -Value 1
    }
    Set-Reg -Path 'HKLM\LITE_SYSTEM\Setup\MoSetup' -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Type REG_DWORD -Value 1
    Write-Ok (T 'Обход проверок TPM 2.0 / Secure Boot встроен' 'TPM 2.0 / Secure Boot checks bypassed')
}

# --- профиль по умолчанию: интерфейс без рекламы ---
$cdm = 'HKLM\LITE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach ($n in 'SubscribedContent-310093Enabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
               'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled',
               'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled',
               'RotatingLockScreenOverlayEnabled', 'PreInstalledAppsEnabled') {
    Set-Reg -Path $cdm -Name $n -Type REG_DWORD -Value 0
}
$adv = 'HKLM\LITE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-Reg -Path $adv -Name 'TaskbarMn'              -Type REG_DWORD -Value 0   # чат
if (Test-GroupActive -RulePreset 'balanced' -Group 'AI') { Set-Reg -Path $adv -Name 'ShowCopilotButton' -Type REG_DWORD -Value 0 }
Set-Reg -Path $adv -Name 'Start_IrisRecommendations' -Type REG_DWORD -Value 0
Set-Reg -Path 'HKLM\LITE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Type REG_DWORD -Value 0
Set-Reg -Path 'HKLM\LITE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -Type REG_DWORD -Value 0
Set-Reg -Path 'HKLM\LITE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type REG_DWORD -Value 1

# Часть AI-политик действует и на уровне пользователя — дублируем в профиль
if (Test-GroupActive -RulePreset 'balanced' -Group 'AI') {
$aiUser = 'HKLM\LITE_DEFAULT\Software\Policies\Microsoft\Windows\WindowsAI'
Set-Reg -Path $aiUser -Name 'DisableAIDataAnalysis'       -Type REG_DWORD -Value 1
Set-Reg -Path $aiUser -Name 'DisableClickToDo'            -Type REG_DWORD -Value 1
Set-Reg -Path $aiUser -Name 'DisableRecallDataProviders'  -Type REG_DWORD -Value 1
Set-Reg -Path 'HKLM\LITE_DEFAULT\Software\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Type REG_DWORD -Value 1
}
Write-Ok (T 'Профиль по умолчанию настроен' 'Default user profile configured')

Dismount-Hives
if ($script:LoadedHives.Count) { throw (T 'Не все кусты реестра выгружены' 'Some registry hives remain loaded') }
Write-Ok (T 'Кусты реестра выгружены' 'Registry hives unloaded')

#endregion

#region ── Стадия 13. winget и ярлык Install-Firefox ───────────────────────────

Write-Stage (T "Добавление ярлыка Install-Firefox$(if ($WithWinget) { ' и winget' })" "Adding Install-Firefox$(if ($WithWinget) { ' and winget' })")

if ($WithWinget) {
    try {
        $wingetArgs = @("/Image:$mountDir", '/Add-ProvisionedAppxPackage', "/PackagePath:$($wingetPayload.Bundle)")
        foreach ($dep in $wingetPayload.Dependencies) { $wingetArgs += "/DependencyPackagePath:$dep" }
        $wingetArgs += "/LicensePath:$($wingetPayload.License)"
        Invoke-Dism -Arguments $wingetArgs -Quiet | Out-Null
        Write-Ok (T "winget встроен (зависимостей: $($wingetPayload.Dependencies.Count))" "winget added (dependencies: $($wingetPayload.Dependencies.Count))")
    } catch {
        throw (T "Не удалось встроить запрошенный winget: $($_.Exception.Message)" "Failed to add requested winget: $($_.Exception.Message)")
    }
}
# --- ярлык Install-Firefox ---
# Тексты внутри ярлыка — на языке, который получит установленная система
$firefoxCmd = Get-FirefoxInstallerCommand -Language $imgLang -MozillaLanguage $mozLang
# --- сторож: возвращает систему в нужное состояние после обновлений ---
# Накопительные обновления умеют восстанавливать Defender, Edge и AI-компоненты
# и сбрасывать политики. Скрипт запускается при каждом входе и правит это.
$guardDir = Join-Path $mountDir 'Windows\Setup\Scripts\Win11Lite'
if ($Guard) {
    $null = New-Item -ItemType Directory -Path $guardDir -Force

    # Списки собираем из той же конфигурации, по которой чистился образ,
    # чтобы сторож не трогал то, что решено оставить
    $guardFolders = @()
    foreach ($rule in $script:FolderRules) {
        if ($rule.Group -ne 'NativeImages' -and $rule.Path -notmatch '\\Edge(Core)?$' -and (Test-GroupActive -RulePreset $rule.Preset -Group $rule.Group)) { $guardFolders += $rule.Path }
    }
    foreach ($rule in $script:FileRules) {
        if (Test-GroupActive -RulePreset $rule.Preset -Group $rule.Group) { $guardFolders += $rule.Path }
    }
    if (Test-GroupActive -RulePreset 'balanced' -Group 'AI') {
        foreach ($rule in $script:AiFolderPatterns) { $guardFolders += (Join-Path $rule.Parent $rule.Mask) }
    }

    $guardServices = @()
    foreach ($group in $script:DisableServices) {
        if ($group.Group -eq 'Defender' -and -not (Test-GroupActive -RulePreset 'balanced' -Group 'Defender')) { continue }
        $guardServices += $group.Names
    }

    $guardAppx = @($script:AppxRules | Where-Object { Test-GroupActive -RulePreset $_.Preset -Group $_.Group } | ForEach-Object { $_.Pattern })
    $guardCaps = @($script:CapabilityRules | Where-Object { Test-GroupActive -RulePreset $_.Preset -Group $_.Group } | ForEach-Object { $_.Pattern }) + @($RemoveExtra)
    if (Test-GroupActive -RulePreset 'balanced' -Group 'AI') { $guardCaps += '^Hello\.Face\.' }
    $guardProtected = @(Get-ProtectedPatterns) + @($script:CapabilityRules + $script:PackageRules | Where-Object { $Keep -contains $_.Group } | ForEach-Object { $_.Pattern })
    # Sense сохраняет Permanent-пакет CBS; его службы и файлы проверяются отдельно.
    $guardProtected += '^Microsoft\.Windows\.Sense\.Client~'

    # Политики, которые должны оставаться выставленными
    $guardPolicies = @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI|AllowRecallEnablement|0'
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI|DisableAIDataAnalysis|1'
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI|DisableClickToDo|1'
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI|DisableSettingsAgent|1'
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI|RemoveMicrosoftCopilotApp|1'
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot|TurnOffWindowsCopilot|1'
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection|AllowTelemetry|0'
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent|DisableWindowsConsumerFeatures|1'
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent|DisableCloudOptimizedContent|1'
        'HKLM:\SOFTWARE\Policies\Microsoft\Dsh|AllowNewsAndInterests|0'
    )
    if (-not (Test-GroupActive -RulePreset 'balanced' -Group 'AI')) {
        $guardPolicies = @($guardPolicies | Where-Object { $_ -notmatch 'WindowsAI|WindowsCopilot' })
    }
    if (Test-GroupActive -RulePreset 'balanced' -Group 'Defender') {
        $guardPolicies += @(
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender|DisableAntiSpyware|1'
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender|DisableAntiVirus|1'
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection|DisableRealtimeMonitoring|1'
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System|EnableSmartScreen|0'
        )
    }
    if (Test-GroupActive -RulePreset 'safe' -Group 'Edge') {
        $guardPolicies += @(
            'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate|InstallDefault|0'
            'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate|Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}|0'
            'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate|Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}|0'
        )
    }

    $guardConfig = [ordered]@{
        Mode = $GuardMode
        ViewerTask = $GuardMode -ne 'Silent'
        Language = $imgLang
        BuildId = $script:StartedAt.ToString('yyyyMMdd-HHmmss')
        RemoveEdge = (Test-GroupActive -RulePreset 'safe' -Group 'Edge')
        Policies = @($guardPolicies | Sort-Object -Unique)
        Services = @($guardServices | Sort-Object -Unique)
        Capabilities = @($guardCaps | Where-Object { $_ } | Sort-Object -Unique)
        Apps = @($guardAppx | Sort-Object -Unique)
        Protected = @($guardProtected | Sort-Object -Unique)
        Paths = @($guardFolders | Sort-Object -Unique)
        TargetLabels = @($script:CapabilityRules | Where-Object { Test-GroupActive -RulePreset $_.Preset -Group $_.Group } | ForEach-Object { [ordered]@{Category='capability';Pattern=$_.Pattern;Name=$_.Desc} })
    }
    [IO.File]::WriteAllText((Join-Path $guardDir 'guard.json'), ($guardConfig | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($true))
    $guardScript = Get-GuardScript
    [IO.File]::WriteAllText((Join-Path $guardDir 'Guard.UI.ps1'),(Get-BundledResource 'Guard.UI.ps1'),[Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $guardDir 'guard.ps1'), $guardScript, [Text.UTF8Encoding]::new($true))
    Write-Ok (T "Сторож встроен: проверяет систему при каждом входе ($(($guardFolders + $guardServices + $guardAppx + $guardCaps).Count) объектов, $($guardPolicies.Count) политик)" "Guard embedded: checks the system at every logon ($(($guardFolders + $guardServices + $guardAppx + $guardCaps).Count) objects, $($guardPolicies.Count) policies)")
}

# Подготовка в specialize отключает сеть; FirstLogonCommands завершает установку.
# Задача служит повторным запуском при ошибке и поддерживает свой answer-файл.
# SetupComplete — дополнительная регистрация для установок со своим answer-файлом.
# Он не включает сеть: этот этап может предшествовать OOBE.
$scriptsDir = Join-Path $mountDir 'Windows\Setup\Scripts'
$supportDir = Join-Path $scriptsDir 'Win11Lite'
$null = New-Item -ItemType Directory -Path $supportDir -Force
[IO.File]::WriteAllText((Join-Path $supportDir 'Run-Setup.ps1'),$setupRunner,[Text.UTF8Encoding]::new($true))
Remove-Item -LiteralPath (Join-Path $supportDir 'Win11Lite.Run.exe') -Force -ErrorAction SilentlyContinue
$support = Get-SetupSupportScripts -BlockNetwork ($script:ManageOobe -and -not $NoOobeNetworkBlock) `
    -RemoveEdge (Test-GroupActive -RulePreset 'safe' -Group 'Edge') -EnableGuard ([bool]$Guard) `
    -ManageOobe $script:ManageOobe -Language $imgLang -GuardMode $GuardMode
foreach ($name in @('Prepare', 'Finalize')) {
    [IO.File]::WriteAllText((Join-Path $supportDir "$name.ps1"), $support[$name], [Text.UTF8Encoding]::new($true))
}
$buildInfo = [ordered]@{
    BuildId = $script:StartedAt.ToString('yyyyMMdd-HHmmss')
    StartedAt = $script:StartedAt.ToString('o')
    SourceIso = $InputIso
    OutputIso = $OutputIso
    Preset = $Preset
    Language = $imgLang
    SetupLanguage = $setupLang
    SetupLanguageUpdate = $(if ($setupRepair) { Split-Path $setupRepair -Leaf } else { $null })
    UpdateMode = $UpdateMode
    WithWinget = [bool]$WithWinget
    AddedLanguages = @($AddLanguage)
    IncludeDotNetUpdate = [bool]$dotNetPayload
    LcuFile = $LcuFile
    DotNetUpdateFile = $(if ($dotNetPayload) { $DotNetUpdateFile } else { $null })
    SkippedDownloads = @($script:SkippedDownloads)
    Guard = [bool]$Guard
    GuardMode = $GuardMode
    GuardDebug = [bool]($Guard -and $GuardMode -eq 'Debug')
    OobeNetworkBlock = [bool]($script:ManageOobe -and -not $NoOobeNetworkBlock)
    OobeCompletionCheck = 'OOBEComplete'
    SetupScriptLauncher = 'PowerShell / Run-Setup.ps1'
    ServicingDismVersion = [string](Get-NativeToolVersion $script:Dism)
    AccountMode = $AccountMode
} | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $supportDir 'build-info.json'), $buildInfo, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $isoDir 'win11-lite-build.json'), $buildInfo, [Text.UTF8Encoding]::new($false))
Write-Ok (T "ID сборки: $($script:StartedAt.ToString('yyyyMMdd-HHmmss')) — записан в ISO и установленную Windows" "Build ID: $($script:StartedAt.ToString('yyyyMMdd-HHmmss')) - recorded in the ISO and installed Windows")
$setupComplete = @"
@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SystemRoot%\Setup\Scripts\Win11Lite\Run-Setup.ps1" -Mode prepare-register >> "%SystemRoot%\Setup\Scripts\Win11Lite\setupcomplete.log" 2>&1
exit /b %errorlevel%
"@
Write-WindowsBatchFile -Path (Join-Path $scriptsDir 'SetupComplete.cmd') -Content $setupComplete
Write-Ok (T 'Очистка Edge и возврат сети/обновлений запланированы на первый вход' 'Edge cleanup and network/update restoration scheduled for first logon')

$publicDesktop = Join-Path $mountDir 'Users\Public\Desktop'
$null = New-Item -ItemType Directory -Path $publicDesktop -Force
$firefoxPath = Join-Path $publicDesktop 'Install-Firefox.cmd'
# CMD переключает кодовую страницу на UTF-8 до вывода локализованного текста.
Write-FirefoxInstallerFile -Path $firefoxPath -Content $firefoxCmd
Write-Ok (T "Install-Firefox.cmd на общем рабочем столе (язык: $mozLang)" "Install-Firefox.cmd placed on the public desktop (language: $mozLang)")

#endregion

#region ── Стадия 14. Очистка хранилища и фиксация ─────────────────────────────

Write-Stage (T 'Очистка хранилища компонентов и фиксация образа' 'Cleaning the component store and committing the image')

if ($AddLanguage) {
    Assert-ImageLanguages -Image $mountDir -Languages $AddLanguage -SourceLanguage $sourceImageLanguage
    Write-Ok (T 'Базовые языковые возможности и ресурсы Параметров проверены' 'Basic language capabilities and Settings resources verified')
}
if ($Preset -ne 'balanced') { Assert-ImageFileState -Image $mountDir }
if ($Preset -ne 'safe') {
    # Документированная процедура для checkpoint-медиа использует
    # StartComponentCleanup. ResetBase оставляем явным выбором пользователя.
    $cleanupArgs = @("/Image:$mountDir", '/Cleanup-Image', '/StartComponentCleanup')
    if ($ResetBase) {
        if ($buildNumber -ge 26100) {
            Write-Note (T 'ResetBase включён вручную: установленные обновления нельзя будет удалить; дальнейшее обслуживание этого образа требует проверки' 'ResetBase enabled manually: installed updates cannot be uninstalled; further servicing of this image requires validation')
        }
        $cleanupArgs += '/ResetBase'
    } else {
        Write-Step (T 'StartComponentCleanup без /ResetBase: сохраняем возможность удаления установленных обновлений' 'StartComponentCleanup without /ResetBase: preserving uninstall support for installed updates')
    }
    Invoke-Dism -Arguments $cleanupArgs -Activity (T 'Очистка хранилища компонентов' 'Cleaning the component store') | Out-Null
    Write-Ok (T 'Хранилище компонентов очищено' 'Component store cleaned')
}

if ($Preset -eq 'balanced') {
    Write-ComponentStoreReport -Image $mountDir -Phase 'after-cleanup'
    Write-RemainingRemovalReport -Image $mountDir
    Write-Step (T 'Повторная файловая очистка после последнего обслуживания DISM' 'Repeating file cleanup after the final DISM servicing operation')
    Remove-SelectedImageFiles
    if ($RemoveWinRE -and (Test-GroupActive -RulePreset 'safe' -Group 'WinRE')) {
        Remove-ImagePath -FullPath (Join-Path $mountDir 'Windows\System32\Recovery\Winre.wim') -Description 'WinRE (final)' | Out-Null
    }
}

# В balanced проверяем файлы после всех действий DISM, которые могли их восстановить.
if ($Preset -eq 'balanced') { Assert-ImageFileState -Image $mountDir }

# --- boot.wim: обход требований и выбор установщика ---
if (-not $NoBypass -or $LegacySetup -or $setupPayload) {
    $bootWim = Join-Path $isoDir 'sources\boot.wim'
    if (Test-Path -LiteralPath $bootWim) {
        $bootInfo = Invoke-Dism -Arguments @('/Get-ImageInfo', "/ImageFile:$bootWim") -Quiet
        $bootImages = ConvertFrom-DismList -Lines $bootInfo.Output -Key 'Index'
        foreach ($bi in $bootImages) {
            $idx = [int]$bi.Index
            Write-Step (T "boot.wim индекс $idx — правлю" "boot.wim index $idx - patching")
            Invoke-Dism -Arguments @('/Mount-Image', "/ImageFile:$bootWim", "/Index:$idx", "/MountDir:$bootMountDir") `
                        -Activity (T "Монтирование boot.wim (индекс $idx)" "Mounting boot.wim (index $idx)") | Out-Null
            $script:BootMounted = $true
            try {
                if ($setupPayload -and $idx -eq 2) {
                    Add-SetupLanguage -Image $bootMountDir -WindowsImage $mountDir -Distribution $isoDir -Payload $setupPayload -RepairUpdate $setupRepair -Legacy:$LegacySetup
                }
                if (-not $NoBypass) {
                    Mount-Hive -Name 'LITE_BOOT' -File (Join-Path $bootMountDir 'Windows\System32\config\SYSTEM')
                    foreach ($n in 'BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassStorageCheck', 'BypassCPUCheck') {
                        Set-Reg -Path 'HKLM\LITE_BOOT\Setup\LabConfig' -Name $n -Type REG_DWORD -Value 1
                    }
                    Dismount-Hives
                }
                if ($LegacySetup) {
                    # winpeshl.ini перехватывает запуск оболочки WinPE и стартует
                    # классический установщик напрямую, минуя SetupHost/SetupPrep.
                    # Только он умеет ставить систему без winre.wim.
                    # Других ключей не добавляем: при загрузке с носителя установщик
                    # принимает лишь /legacy, а на /DynamicUpdate отвечает
                    # «An unknown command-line option was specified». Обновления на
                    # время установки глушатся политиками в реестре образа.
                    $peLaunch = "[LaunchApps]`r`n%SystemDrive%\sources\setup.exe, /legacy`r`n"
                    [IO.File]::WriteAllText((Join-Path $bootMountDir 'Windows\System32\winpeshl.ini'), $peLaunch, [Text.Encoding]::ASCII)
                }
                Invoke-Dism -Arguments @('/Unmount-Image', "/MountDir:$bootMountDir", '/Commit') `
                            -Activity (T "Сохранение boot.wim (индекс $idx)" "Committing boot.wim (index $idx)") | Out-Null
                $script:BootMounted = $false
            } catch {
                Dismount-Hives
                $discardResult = Invoke-Dism -Arguments @('/Unmount-Image', "/MountDir:$bootMountDir", '/Discard') -AllowFail -Quiet
                if (Test-DismSuccess $discardResult.ExitCode) { $script:BootMounted = $false }
                throw
            }
        }
        Write-Ok (T "boot.wim обработан$(if ($LegacySetup) { ' — установщик переключён на классический' })" "boot.wim processed$(if ($LegacySetup) { ' — classic setup enabled' })")
    }
}

Invoke-Dism -Arguments @('/Unmount-Image', "/MountDir:$mountDir", '/Commit') -Activity (T 'Сохранение изменений в образе' 'Committing changes to the image') | Out-Null
$script:Mounted = $false
Write-Ok (T "install.wim после фиксации: $(Format-Size (Get-Item -LiteralPath $wimPath).Length)" "install.wim after commit: $(Format-Size (Get-Item -LiteralPath $wimPath).Length)")


#endregion

#region ── Стадия 15. Экспорт итогового образа ─────────────────────────────────

Write-Stage (T 'Экспорт итогового образа' 'Exporting the final image')

$destName = if ($Compression -eq 'recovery') { 'install.esd' } else { 'install.wim' }
$destPath = Join-Path $isoDir "sources\$destName"
$compressArg = if ($Compression -eq 'recovery') { '/Compress:recovery' } else { '/Compress:max' }

Invoke-Dism -Arguments @(
    '/Export-Image'
    "/SourceImageFile:$wimPath"
    '/SourceIndex:1'
    "/DestinationImageFile:$destPath"
    $compressArg
    '/CheckIntegrity'
) -Activity (T "Сжатие образа ($Compression)" "Compressing the image ($Compression)") | Out-Null
Remove-Item -LiteralPath $wimPath -Force
Write-Ok "$destName : $(Format-Size (Get-Item -LiteralPath $destPath).Length)"

# --- урезание sources ---
if ($TrimSources) {
    $srcDir = Join-Path $isoDir 'sources'
    # Имя $keep занято параметром -Keep с ValidateSet — присваивание в него падает
    $keepFiles = @($destName, 'boot.wim', 'EI.CFG', 'ei.cfg', 'setup.exe')
    if ($setupPayload) { $keepFiles += @('lang.ini', $setupLang, $sourceImageLanguage) }
    $trimmed = 0; $trimmedBytes = 0
    foreach ($item in (Get-ChildItem -LiteralPath $srcDir -Force)) {
        if ($item.Name -in $keepFiles) { continue }
        try {
            $null = Assert-ChildPath -Path $item.FullName -Root $srcDir
            if (-not $item.PSIsContainer) { $trimmedBytes += $item.Length }
            else { $trimmedBytes += (Get-ChildItem -LiteralPath $item.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum }
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $trimmed++
        } catch { }
    }
    Write-Ok (T "sources урезан: удалено объектов $trimmed ($(Format-Size $trimmedBytes))" "sources trimmed: $trimmed items removed ($(Format-Size $trimmedBytes))")
    Write-Note (T 'Запуск setup.exe из работающей Windows больше не поддерживается — только загрузка с носителя' 'Running setup.exe from a running Windows is no longer supported - boot from the media instead')
}

# --- EI.CFG: редакция и канал ---
# Без него установщик спрашивает ключ продукта, чтобы понять, что ставить.
# Файл задаёт выбранную редакцию; запрос ключа управляется answer-файлом.
$eiCfgPath = Join-Path $isoDir 'sources\EI.CFG'
if (-not (Test-Path -LiteralPath $eiCfgPath)) {
    $eiCfg = Get-EditionConfig -EditionId $selected.EditionId
    [IO.File]::WriteAllText($eiCfgPath, $eiCfg, [Text.Encoding]::ASCII)
    Write-Ok (T "EI.CFG создан для редакции $($selected.EditionId)" "EI.CFG created for edition $($selected.EditionId)")
} else {
    Write-Ok (T 'EI.CFG уже есть в образе — оставляю как есть' 'EI.CFG already present in the image - left as is')
}

# --- autounattend.xml ---
if ($Unattend -eq 'none') {
    Write-Note (T 'autounattend.xml не добавляется (-Unattend none)' 'autounattend.xml is not added (-Unattend none)')
} elseif ($Unattend) {
    Copy-Item -LiteralPath $Unattend -Destination (Join-Path $isoDir 'autounattend.xml') -Force
    Write-Ok (T "Использован свой autounattend.xml: $Unattend" "Using custom autounattend.xml: $Unattend")
} else {
    # RunSynchronous с LabConfig здесь не нужен: те же ключи уже прописаны в
    # реестр обоих индексов boot.wim. Лишний блок только усложняет файл и должен
    # идти строго до UserData по схеме unattend, иначе setup ругается на XML.
    # ImageInstall идёт до UserData — порядок элементов в схеме строгий.
    # Блок ProductKey обязателен: классический установщик, встретив UserData без
    # него, останавливается с «Windows cannot read the ProductKey setting».
    # Пустой Key вместе с WillShowUI=Never пропускает запрос ключа — для
    # корпоративных редакций это штатный сценарий.
    $setupInputLocale = if ($imgLang -eq 'ru-RU') { '0419:00000419;0409:00000409' } else { $imgLang }
    $compactBlock = Get-ImageInstallXml -Compact ([bool]$CompactOS)
    $localAccountXml = Get-LocalAccountXml -Name $LocalUserName -Password $LocalUserPassword
    $productKeyUi = Get-ProductKeyUiMode -EditionId $selected.EditionId
    $escapedProductKey = [Security.SecurityElement]::Escape($ProductKey)
    $productKeyValue = if ($ProductKey -or $selected.EditionId -notmatch '^(Core|Professional)') { "<Key>$escapedProductKey</Key>" } else { '' }

    # В specialize сохраняются и отключаются активные адаптеры, затем
    # регистрируется дополнительная задача завершения установки.
    $oobeNetBlock = @"

    <settings pass="specialize">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <InputLocale>$setupInputLocale</InputLocale>
            <SystemLocale>$imgLang</SystemLocale>
            <UILanguage>$imgLang</UILanguage>
            <UserLocale>$imgLang</UserLocale>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>Prepare first logon and OOBE</Description>
                    <Path>"%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%WINDIR%\Setup\Scripts\Win11Lite\Run-Setup.ps1" -Mode prepare</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
"@

    $unattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <SetupUILanguage>
                <UILanguage>$setupLang</UILanguage>
            </SetupUILanguage>
            <InputLocale>$setupInputLocale</InputLocale>
            <SystemLocale>$imgLang</SystemLocale>
            <UILanguage>$imgLang</UILanguage>
            <UserLocale>$imgLang</UserLocale>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">$compactBlock
            <UserData>
                <AcceptEula>true</AcceptEula>
                <ProductKey>
                    $productKeyValue
                    <WillShowUI>$productKeyUi</WillShowUI>
                </ProductKey>
            </UserData>
        </component>
    </settings>$oobeNetBlock
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <InputLocale>$setupInputLocale</InputLocale>
            <SystemLocale>$imgLang</SystemLocale>
            <UILanguage>$imgLang</UILanguage>
            <UILanguageFallback>en-US</UILanguageFallback>
            <UserLocale>$imgLang</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>Finish installation</Description>
                    <CommandLine>"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SystemRoot%\Setup\Scripts\Win11Lite\Run-Setup.ps1" -Mode finalize</CommandLine>
                </SynchronousCommand>
            </FirstLogonCommands>$localAccountXml
        </component>
    </settings>
</unattend>
"@
    [IO.File]::WriteAllText((Join-Path $isoDir 'autounattend.xml'), $unattendXml, (New-Object Text.UTF8Encoding $false))
    Write-Ok (T 'autounattend.xml создан (локальный аккаунт, обход проверок, язык образа)' 'autounattend.xml created (local account, requirement bypass, image language)')
}

#endregion

#region ── Стадия 16. Сборка ISO ───────────────────────────────────────────────

if ($SkipIso) {
    Write-Stage (T 'Сборка ISO пропущена (-SkipIso)' 'ISO build skipped (-SkipIso)')
    Write-Ok (T "Готовые файлы образа: $isoDir" "Prepared image files: $isoDir")
} else {
    Write-Stage (T 'Сборка загрузочного ISO' 'Building the bootable ISO')

    $etfsboot = Join-Path $isoDir 'boot\etfsboot.com'
    $efisys = Join-Path $isoDir 'efi\microsoft\boot\efisys.bin'
    if (-not (Test-Path $etfsboot)) { throw (T "Не найден загрузчик BIOS: $etfsboot" "BIOS boot loader not found: $etfsboot") }
    if (-not (Test-Path $efisys)) { throw (T "Не найден загрузчик UEFI: $efisys" "UEFI boot loader not found: $efisys") }

    $label = "${isoLabel}_LITE"
    if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }

    $buildingIso = "$OutputIso.building"
    if (Test-Path -LiteralPath $buildingIso) { Remove-Item -LiteralPath $buildingIso -Force }

    # Пути к загрузчикам передаём относительными и без кавычек: кавычки вокруг
    # аргумента без пробелов oscdimg получил бы как часть значения.
    # Каталог-источник '.' задаётся рабочим каталогом процесса: Push-Location
    # оболочки на запущенный процесс не влияет.
    $bootData = '2#p0,e,bboot\etfsboot.com#pEF,e,befi\microsoft\boot\efisys.bin'
    Write-Step (T "oscdimg → $OutputIso" "oscdimg -> $OutputIso")
    $isoRun = Invoke-ProgressProcess -Exe $script:Oscdimg -WorkingDirectory $isoDir -ProgressOnStdErr `
        -Activity (T 'Запись ISO' 'Writing the ISO') `
        -Arguments @('-m', '-o', '-u2', '-udfver102', "-l$label", "-bootdata:$bootData", '.', $buildingIso)
    if ($isoRun.ExitCode -ne 0) {
        $tail = ($isoRun.Output | Select-Object -Last 12) -join "`n"
        throw (T "oscdimg завершился с кодом $($isoRun.ExitCode)`n$tail" "oscdimg exited with code $($isoRun.ExitCode)`n$tail")
    }
    # Полоса заменила живой вывод oscdimg; его отчёт сохраняем в подробном логе.
    Write-DiagnosticLog (($isoRun.Output -join "`n").Trim())
    if (Test-Path -LiteralPath $OutputIso) { [IO.File]::Replace($buildingIso, $OutputIso, $null) }
    else { [IO.File]::Move($buildingIso, $OutputIso) }

    $isoSize = (Get-Item -LiteralPath $OutputIso).Length
    Write-Ok (T "ISO собран: $(Format-Size $isoSize)" "ISO built: $(Format-Size $isoSize)")

    Write-Step (T 'Считаю SHA256 ...' 'Computing SHA256 ...')
    $hash = (Get-FileHash -LiteralPath $OutputIso -Algorithm SHA256).Hash
    $hashFile = [IO.Path]::ChangeExtension($OutputIso, '.sha256')
    Set-Content -LiteralPath $hashFile -Value "$hash *$(Split-Path $OutputIso -Leaf)" -Encoding ascii
    Write-Ok (T "SHA256: $hash" "SHA256: $hash")
}

#endregion

#region ── Итоговый отчёт ──────────────────────────────────────────────────────

if ($script:StageStart) {
    $last = @($script:StageTimes.Keys)[-1]
    $script:StageTimes[$last] = (Get-Date) - $script:StageStart
}

$srcSize = (Get-Item -LiteralPath $InputIso).Length
$dstSize = if (-not $SkipIso -and (Test-Path -LiteralPath $OutputIso)) { (Get-Item -LiteralPath $OutputIso).Length } else { 0 }

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════════════════╗' -ForegroundColor Green
Write-Host ('║' + (T '                              ГОТОВО                                      ' '                               DONE                                       ') + '║') -ForegroundColor Green
Write-Host '╚══════════════════════════════════════════════════════════════════════════╝' -ForegroundColor Green
Write-Host ''
Write-Host (T "  Исходный ISO   : $(Format-Size $srcSize)" "  Source ISO     : $(Format-Size $srcSize)")
if ($dstSize) {
    $pct = [math]::Round((1 - $dstSize / $srcSize) * 100, 1)
    Write-Host (T "  Готовый ISO    : $(Format-Size $dstSize)   (−$pct%)" "  Result ISO     : $(Format-Size $dstSize)   (-$pct%)") -ForegroundColor Green
    Write-Host (T "  Путь           : $OutputIso" "  Path           : $OutputIso")
}
Write-Host (T "  Редакция       : $($selected.EditionId)   Язык: $imgLang" "  Edition        : $($selected.EditionId)   Language: $imgLang")
Write-Host (T "  Удалено: возможностей $removedCaps, пакетов $removedPkgs, приложений $removedAppx" "  Removed: capabilities $removedCaps, packages $removedPkgs, apps $removedAppx")
if ($Preset -eq 'balanced' -and $script:ImageAudit.RemainingRemovals.Count) {
    Write-Note (T "  После проверки DISM осталось выбранных компонентов: $($script:ImageAudit.RemainingRemovals.Count); состояния и причины — в отчёте образа" "  Selected components still present after DISM verification: $($script:ImageAudit.RemainingRemovals.Count); see the image audit for states and failures")
}
Write-Host (T "  Объём удалённых файлов до сжатия: $(Format-Size $script:FreedBytes) (не экономия ISO; возможен повторный учёт hard links)" "  Deleted file lengths before compression: $(Format-Size $script:FreedBytes) (not ISO savings; hard links may be counted more than once)")
if ($script:SkippedDownloads.Count) { Write-Note (T "  Сборка выполнена без: $($script:SkippedDownloads -join '; ')" "  Built without: $($script:SkippedDownloads -join '; ')") }
if ($script:ImageAuditPath -and (Test-Path -LiteralPath $script:ImageAuditPath)) {
    $script:ImageAudit['SourceIsoBytes'] = $srcSize
    $script:ImageAudit['ResultIsoBytes'] = $dstSize
    Save-ImageAudit
    Write-Host (T "  Анализ размера и оставшихся компонентов: $script:ImageAuditPath" "  Size and remaining-component audit: $script:ImageAuditPath")
}
Write-Host ''
Write-Host (T '  Время по стадиям:' '  Time per stage:') -ForegroundColor White
foreach ($k in $script:StageTimes.Keys) {
    Write-Host ("    {0,-52} {1:hh\:mm\:ss}" -f $k, $script:StageTimes[$k]) -ForegroundColor Gray
}
Write-Host ("  {0,-54} {1:hh\:mm\:ss}" -f (T 'ИТОГО' 'TOTAL'), ((Get-Date) - $script:StartedAt)) -ForegroundColor White
Write-Host ''
if ($LogFile) { Write-Host (T "  Лог: $LogFile" "  Log: $LogFile") }

#endregion

} catch {
    Write-Host ''
    Write-Fail (T "ОШИБКА на стадии $($script:StageNo): $($_.Exception.Message)" "ERROR at stage $($script:StageNo): $($_.Exception.Message)")
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    throw
} finally {
    #region ── Уборка ──────────────────────────────────────────────────────────
    Write-Host ''
    Write-Host (T 'Уборка...' 'Cleaning up...') -ForegroundColor DarkCyan

    Dismount-Hives

    if ($script:Dism -and (Test-Path $script:Dism)) {
        if ($script:Mounted) {
            Write-Note (T 'Отцепляю образ без сохранения изменений' 'Discarding the image without saving changes')
            $discardResult = Invoke-Dism -Arguments @('/Unmount-Image', "/MountDir:$mountDir", '/Discard') -AllowFail -Quiet
            if (Test-DismSuccess $discardResult.ExitCode) { $script:Mounted = $false }
        }
        if ($script:BootMounted) {
            $discardResult = Invoke-Dism -Arguments @('/Unmount-Image', "/MountDir:$bootMountDir", '/Discard') -AllowFail -Quiet
            if (Test-DismSuccess $discardResult.ExitCode) { $script:BootMounted = $false }
        }
    }

    if ($script:IsoMounted) {
        try { Dismount-DiskImage -ImagePath $script:IsoMounted | Out-Null } catch { }
    }
    if ($script:LangIso) {
        try { Dismount-DiskImage -ImagePath $script:LangIso | Out-Null } catch { }
    }

    if (-not $DryRun -and $script:WorkPrepared) {
        if ($KeepWorkDir -or $SkipIso -or $script:Mounted -or $script:BootMounted -or $script:LoadedHives.Count) {
            Write-Note (T "Рабочий каталог сохранён: $WorkDir" "Work folder kept: $WorkDir")
        } elseif ((Test-Path -LiteralPath $WorkDir) -and (Test-SafeToWipe $WorkDir) -and
                  (Test-Path -LiteralPath (Join-Path $WorkDir $script:WorkDirMarker))) {
            # Удаляем только каталог с нашей меткой — чужие данные не трогаем
            try {
                Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction Stop
                Write-Ok (T 'Рабочий каталог удалён' 'Work folder removed')
            } catch {
                Write-Note (T "Не удалось полностью удалить $WorkDir : $($_.Exception.Message)" "Could not fully remove $WorkDir : $($_.Exception.Message)")
            }
        }
    }

    if ($script:Transcribing) {
        try { Stop-Transcript | Out-Null } catch { }
        Write-Host (T "Лог сохранён: $LogFile" "Log saved: $LogFile") -ForegroundColor DarkCyan
    }

    Wait-BeforeExit
    #endregion
}
