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
    # По умолчанию — временная папка Windows; нужно 30 ГБ, с обновлениями 45 ГБ.
    # При нехватке места выбирается подходящий диск или запрашивается новый путь.
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
    [ValidateSet('Defender', 'WinRE', 'Edge', 'Fonts', 'Speech', 'WMP', 'IE', 'Sandbox', 'AI', 'Apps', 'Family', 'ToDo', 'OneDrive', 'NativeImages')]
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

    # Дополнительно встроить winget (App Installer), ~300 МБ загрузки.
    # Без ключа имеющийся в исходном образе App Installer/winget сохраняется.
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

    # None: не встраивать guard; Standard: краткий итог; Debug: живой журнал;
    # Silent: проверка без окна, отчёты сохраняются в папке guard.
    [Alias('Watchdog')]
    [ValidateSet('None','Standard','Debug','Silent')]
    [string]$Guard = 'None',

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

    # auto: общий диалог для всех версий; по умолчанию ввод пользователя в Windows.
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
$Guard=switch($Guard.ToLowerInvariant()){'none'{'None'}'standard'{'Standard'}'debug'{'Debug'}'silent'{'Silent'}}

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

function Get-WimWingetState {
    param([string]$Path, [ValidateRange(1,65535)][int]$Index,
          [string]$Dism = (Join-Path $env:SystemRoot 'System32\dism.exe'))
    # List-Image читает только каталог выбранного индекса: WIM не монтируется
    # для обслуживания, файлы не распаковываются, winget хоста не используется.
    try {
        $nativePreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $PSNativeCommandUseErrorActionPreference = $false
            $lines = @(& $Dism /English /List-Image "/ImageFile:$Path" "/Index:$Index" 2>&1)
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $nativePreference }
        if ($null -eq $code -or $code -ne 0) {
            throw "DISM ($code): $(($lines | Select-Object -Last 6) -join ' ')"
        }
        $paths = @($lines | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\\' })
        if (-not $paths.Count) { throw (T 'DISM не вернул каталог файлов' 'DISM did not return a file listing') }
        $found = @($paths | Where-Object { $_ -match '^\\Program Files\\WindowsApps\\Microsoft\.DesktopAppInstaller_[^\\]+\\winget\.exe$' }).Count -gt 0
        [pscustomobject]@{ State = $(if ($found) { 'Present' } else { 'Absent' }); Reason = '' }
    } catch {
        # Неудачная проверка не означает, что winget отсутствует.
        [pscustomobject]@{ State = 'Unknown'; Reason = $_.Exception.Message }
    }
}

function Get-IsoWingetState {
    param([string]$Path, [ValidateRange(1,65535)][int]$Index, [string]$Dism)
    $owned = $false
    try {
        $disk = Get-DiskImage -ImagePath $Path -ErrorAction Stop
        if (-not $disk.Attached) {
            $disk = Mount-DiskImage -ImagePath $Path -PassThru -Access ReadOnly -ErrorAction Stop
            $owned = $true
            Start-Sleep -Seconds 2
        }
        $drive = "$(($disk | Get-Volume -ErrorAction Stop).DriveLetter):"
        $wim = Join-Path $drive 'sources\install.wim'
        if (-not (Test-Path -LiteralPath $wim)) { $wim = Join-Path $drive 'sources\install.esd' }
        if (-not (Test-Path -LiteralPath $wim)) { throw (T 'В ISO нет install.wim/install.esd' 'The ISO has no install.wim/install.esd') }
        $queryParams = @{ Path = $wim; Index = $Index }
        if ($Dism) { $queryParams.Dism = $Dism }
        Get-WimWingetState @queryParams
    } catch {
        [pscustomobject]@{ State = 'Unknown'; Reason = $_.Exception.Message }
    } finally {
        if ($owned) { Dismount-DiskImage -ImagePath $Path -ErrorAction Stop | Out-Null }
    }
}

function Read-WingetOption {
    param([Parameter(Mandatory)]$SourceState)
    if ($SourceState.State -eq 'Present') {
        Write-Host (T '  winget уже встроен в выбранную редакцию; App Installer и winget сохраняются.' '  winget is already included in the selected edition; keeping App Installer and winget.') -ForegroundColor Gray
        return $false
    }
    if ($SourceState.State -eq 'Unknown') {
        Write-Note (T "Наличие winget проверить не удалось: $($SourceState.Reason)" "Could not check for winget: $($SourceState.Reason)")
    }
    Read-YesNo -Question (T 'Встроить winget (менеджер пакетов, ~300 МБ загрузки)?' 'Embed winget (package manager, about 300 MB download)?') -Default $false
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
    @{ Preset = 'max';      Group = 'Misc';     Pattern = '^Microsoft-Windows-WMIC-FoD-Package';                       Desc = 'WMIC' }
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
    '^Microsoft-Windows-VBSCRIPT-FoD-Package(~|$)'                # VBS-запускатель установки, включая max
    '^(Microsoft\.Windows\.)?VBSCRIPT~'                           # тот же движок как capability; защита и для guard
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
    @{ Preset = 'balanced'; Group = 'Family'; Pattern = '^MicrosoftCorporationII\.MicrosoftFamily$'; Desc = 'Family' }
    @{ Preset = 'balanced'; Group = 'ToDo'; Pattern = '^Microsoft\.Todos$'; Desc = 'Microsoft To Do' }
    @{ Preset = 'balanced'; Group = 'WMP'; Pattern = '^Microsoft\.(ZuneMusic|ZuneVideo)$'; Desc = (T 'Медиаплеер, Музыка Groove и Кино и ТВ' 'Media Player, Groove Music and Movies & TV') }
    @{ Preset = 'balanced'; Group = 'Apps'; Pattern = '^Microsoft\.(GamingApp|XboxApp|XboxGamingOverlay|XboxGameOverlay|XboxSpeechToTextOverlay)$'; Desc = (T 'Xbox и Game Bar' 'Xbox and Game Bar') }
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
    if ($Mode -eq 'image' -or $Name) { return 'image' }
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
    if ($Mode -eq 'auto' -and -not $Name -and -not $Unattend -and -not $Preview -and (Test-CanPrompt)) {
        $resolved = Read-Option -Question (T 'Где задать локального пользователя' 'Where to configure the local user') -Items @((T 'При установке Windows' 'During Windows Setup'),(T 'Сейчас, до сборки ISO' 'Now, before building the ISO')) -Values @('setup','image') -Default 1
    }
    if ($resolved -eq 'image' -and -not $Name -and -not $Preview) {
        if (-not (Test-CanPrompt)) { throw (T 'Для создания аккаунта до сборки укажите -LocalUserName <имя> или выберите -AccountMode setup для ввода при установке Windows' 'To create an account before building, specify -LocalUserName <name>, or choose -AccountMode setup to enter it during Windows Setup') }
        $Name = (Read-Host (T '  Имя локального пользователя' '  Local user name')).Trim()
        Assert-LocalUserName $Name
        Write-Note (T 'Пароль попадёт в установочный answer-файл ISO; кодирование Windows не является шифрованием.' 'The password is stored in the ISO answer file; Windows encoding is not encryption.')
        if ($null -eq $Password) { $Password = Read-ConfirmedLocalAccountPassword }
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
    if ($Group -in @('Family','ToDo') -and $Keep -contains 'Apps') { return $false }
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
    if (-not (Read-YesNo -Question (T "Продолжить без «$Component»? Введите Да чтобы продолжить сборку" "Continue without '$Component'? Enter Yes to continue the build") -Default $false)) {
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
        $catalog = Get-AdkCatalog -Build $Build -Directory $Directory
        if ($catalog.Build -ne $Build -or $catalog.Architecture -ne 'amd64' -or -not @($catalog.Files).Count) { throw (T 'Несовместимый каталог WinPE' 'Incompatible WinPE catalog') }
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
    # The current winget catalog publishes en-US as Mozilla.Firefox and each
    # other installer language as a separate package, for example .ru or .de.
    $wingetId = if ($MozillaLanguage -eq 'en-US') { 'Mozilla.Firefox' } else { "Mozilla.Firefox.$MozillaLanguage" }
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
    winget install --id $wingetId -e --source winget --accept-package-agreements --accept-source-agreements
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

#region Guest script
function Get-SetupVbsScript {
    # Plain-text bootstrap. Run(..., 0, True) hides PowerShell at creation and
    # waits for its exit code; it never executes a command supplied by the user.
    $text = @'
Option Explicit
Dim files, shell, support, mode, guest, powershell, command, result, failure, reason
Set files = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
support = files.GetParentFolderName(WScript.ScriptFullName)
If WScript.Arguments.Count <> 1 Then Fail 87, "Expected exactly one background mode"
mode = LCase(WScript.Arguments(0))
Select Case mode
    Case "prepare", "prepare-register", "finalize", "finalize-wait", "guard"
    Case Else
        Fail 87, "Unsupported background mode"
End Select
guest = files.BuildPath(support, "Win11Lite.ps1")
powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not files.FileExists(guest) Then Fail 2, "Win11Lite.ps1 is missing"
If Not files.FileExists(powershell) Then Fail 2, "Windows PowerShell is missing"
command = Quote(powershell) & " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Quote(guest) & " -Mode " & mode
On Error Resume Next
shell.CurrentDirectory = support
If Err.Number <> 0 Then
    failure = Err.Number
    reason = Err.Description
    Fail failure, reason
End If
WriteLog "START mode=" & mode
Err.Clear
result = shell.Run(command, 0, True)
failure = Err.Number
reason = Err.Description
On Error GoTo 0
If failure <> 0 Then Fail failure, reason
WriteLog "END mode=" & mode & " ExitCode=" & result
WScript.Quit result

Function Quote(value)
    Quote = Chr(34) & value & Chr(34)
End Function

Sub WriteLog(message)
    On Error Resume Next
    Dim log
    Set log = files.OpenTextFile(files.BuildPath(support, "vbs-launcher.log"), 8, True, -1)
    If Err.Number = 0 Then
        log.WriteLine CStr(Now) & " " & message
        log.Close
    End If
    Err.Clear
End Sub

Sub Fail(code, message)
    WriteLog "ERROR " & CStr(code) & ": " & message
    WScript.Quit code
End Sub
'@
    ($text -replace '\r?\n', "`r`n").TrimEnd("`r", "`n") + "`r`n"
}

function Get-SetupEntryCommand {
    param([ValidateSet('prepare','prepare-register','finalize')][string]$Mode, [bool]$UseVbs)
    if ($UseVbs) {
        return '"%SystemRoot%\System32\wscript.exe" //B //NoLogo "%SystemRoot%\Setup\Scripts\Win11Lite\Run-Setup.vbs" ' + $Mode
    }
    '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SystemRoot%\Setup\Scripts\Win11Lite\Win11Lite.ps1" -Mode ' + $Mode
}

function Test-ImageVbsLauncher {
    param([string]$Image)
    (Test-Path -LiteralPath (Join-Path $Image 'Windows\System32\wscript.exe') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $Image 'Windows\System32\vbscript.dll') -PathType Leaf)
}

# The single guest runtime, written into the image as
# %SystemRoot%\Setup\Scripts\Win11Lite\Win11Lite.ps1. This literal is the only
# copy: edit it here. No separate file, archive or download is involved.
function Get-GuestScript {
    $text = @'
#Requires -Version 5.1
# win-11-lite guest runtime. One file covers the Windows Setup hooks, the first
# logon finalizer, the guard worker and the guard report window. The builder
# writes it into %SystemRoot%\Setup\Scripts\Win11Lite together with
# build-info.json, which carries every choice made at build time.
param(
    # Only the mode is positional, so a mangled task action cannot slip an
    # unexpected value into another parameter.
    [Parameter(Position=0)][ValidateSet('prepare','prepare-register','finalize','finalize-wait','guard','view')][string]$Mode,
    # Without -Direct the mode runs in a child process without a window, so its
    # output and exit code are kept in launcher.log.
    [switch]$Direct,
    [string]$RunId,
    [ValidateRange(0,86400)][int]$WaitSeconds = 0,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$ExtraArguments
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Support = $PSScriptRoot
$script:BuildInfo = $null
try { $script:BuildInfo = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'build-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
$logFile = Join-Path $PSScriptRoot 'guard.log'
function T { param([string]$Ru, [string]$En) if ([string]$script:BuildInfo.Language -like 'ru*') { $Ru } else { $En } }
# Build choices are required, never guessed: a missing value is a broken image.
function Get-BuildSetting {
    param([Parameter(Mandatory)][string]$Name)
    if ($null -eq $script:BuildInfo -or $null -eq $script:BuildInfo.$Name) {
        throw (T "В build-info.json нет значения $Name" "build-info.json has no $Name value")
    }
    $script:BuildInfo.$Name
}
function Get-GuestFlag { param([Parameter(Mandatory)][string]$Name) [bool](Get-BuildSetting -Name $Name) }
function Get-GuestGuardMode {
    $value=[string](Get-BuildSetting 'Guard')
    if($value -notin @('None','Standard','Debug','Silent')){throw (T "Недопустимый режим Guard в build-info.json: $value" "Invalid Guard mode in build-info.json: $value")}
    $value
}
function Write-GuestLog {
    param([string]$File, [string]$Message)
    $path = Join-Path $script:Support $File
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try { [IO.File]::AppendAllText($path, "$(Get-Date -Format s) [$Mode] $Message`r`n", [Text.UTF8Encoding]::new($true)); return }
        catch [IO.IOException] { Start-Sleep -Milliseconds 50 }
        catch [UnauthorizedAccessException] { return } # A limited report process can read this folder.
    }
}
function Write-RunnerLog   { param([string]$Message) Write-GuestLog 'launcher.log' $Message }
function Write-PrepareLog  { param([string]$Message) Write-GuestLog 'prepare.log' $Message }
function Write-FinalizeLog { param([string]$Message) Write-GuestLog 'finalize.log' $Message }
function Test-NativeOobeComplete {
    if (-not ('Win11Lite.Oobe' -as [type])) {
        Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
namespace Win11Lite {
    public static class Oobe {
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool OOBEComplete([MarshalAs(UnmanagedType.Bool)] out bool complete);
    }
}
"@
    }
    $complete = $false
    if (-not [Win11Lite.Oobe]::OOBEComplete([ref]$complete)) {
        throw (T "Не удалось проверить окончание OOBE: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" "Could not query OOBE completion: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())")
    }
    $complete
}
# Finalize keeps waiting rather than failing when the probe is unavailable.
function Test-OobeComplete {
    try { Test-NativeOobeComplete }
    catch {
        if ($script:OobeProbeError -ne $_.Exception.Message) {
            Write-FinalizeLog (T "WAIT: состояние OOBE недоступно: $($_.Exception.Message)" "WAIT: OOBE state unavailable: $($_.Exception.Message)")
        }
        $script:OobeProbeError = $_.Exception.Message
        $false
    }
}
# Runs the requested mode as a hidden child of this same file, keeping its
# output and exit code in launcher.log. Run-Setup.vbs hides the initial process
# too when VBScript is available; the PowerShell fallback can briefly flash.
function Start-GuestChild {
    param([Parameter(Mandatory)][string]$ChildMode)
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Mode ' + $ChildMode + ' -Direct'
    $psi.WorkingDirectory = $script:Support
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    # Windows PowerShell uses the system OEM code page when its output is redirected.
    $codePage = [int](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name OEMCP).OEMCP
    $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding($codePage)
    $psi.StandardErrorEncoding = $psi.StandardOutputEncoding
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw 'PowerShell did not start' }
        Write-RunnerLog "START PID=$($process.Id)"
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult(); $errorText = $stderr.GetAwaiter().GetResult()
        if ($output.Trim()) { Write-RunnerLog $output.Trim() }
        if ($errorText.Trim()) { Write-RunnerLog ('STDERR ' + $errorText.Trim()) }
        $code = $process.ExitCode; Write-RunnerLog "END ExitCode=$code"
        $code
    } finally { $process.Dispose() }
}

# ── Windows Setup: specialize and SetupComplete ────────────────────────────────

function Invoke-Prepare {
    param([switch]$RegisterOnly)
    Write-PrepareLog (T "START: RegisterOnly=$RegisterOnly; пользователь=$env:USERNAME" "START: RegisterOnly=$RegisterOnly; user=$env:USERNAME")
    # The answer file runs finalize directly at the first real user logon.
    # Scheduler availability during specialize must not prevent network blocking.
    if ((Get-GuestFlag 'OobeNetworkBlock') -and -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'oobe-complete'))) {
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
    $runnerArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}\Win11Lite.ps1" -Mode ' -f $PSScriptRoot
    $action = New-ScheduledTaskAction -Execute $exe -Argument ($runnerArguments + 'finalize-wait')
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Delay = 'PT30S'
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
    $finalizeSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $finalizeSettings -Force | Out-Null
    $configuredGuardMode=Get-GuestGuardMode
    if ($configuredGuardMode -ne 'None') {
        $guardAction = New-ScheduledTaskAction -Execute $exe -Argument ($runnerArguments + 'guard')
        Register-ScheduledTask -TaskName 'win-11-lite guard' -Action $guardAction -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        $viewerMode=$configuredGuardMode
        $guardConfigPath=Join-Path $PSScriptRoot 'guard.json'
        if(Test-Path -LiteralPath $guardConfigPath){$viewerMode=Get-GuardMode (Get-Content -LiteralPath $guardConfigPath -Raw|ConvertFrom-Json)}
        Register-GuardViewerTask -SupportDirectory $PSScriptRoot -Mode $viewerMode
    }
    Write-PrepareLog (T 'Задачи первого входа зарегистрированы' 'First-logon tasks registered')
    } catch {
        Write-PrepareLog (T "Планировщик недоступен: $($_.Exception.Message)" "Task Scheduler unavailable: $($_.Exception.Message)")
        if (-not (Get-GuestFlag 'ManageOobe')) { throw }
        Write-PrepareLog (T 'Завершение установки выполнит FirstLogonCommands' 'FirstLogonCommands will finalize setup')
    }
}

# ── First logon: network, updates and Edge ─────────────────────────────────────

# Reports through $script:FinalizeFailed so the guard worker can call it in
# process without an exit code ending the whole run.
function Invoke-Finalize {
    param([switch]$EdgeOnly, [switch]$FirstLogon, [switch]$WaitForOobe, [ValidateRange(1,86400)][int]$WaitSeconds = 7200)
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
                Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}\Win11Lite.ps1" -Mode finalize-wait' -f $PSScriptRoot) | Out-Null
            }
            return
        }
        Write-FinalizeLog 'OOBEComplete=True'
    }
    # The logon task and FirstLogonCommands may start together; allow one finalizer.
    try { $finalizeLock = [IO.File]::Open((Join-Path $PSScriptRoot 'finalize.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { return }
    try {
    $script:FinalizeFailed = $false
    if (-not $EdgeOnly -and (Get-GuestFlag 'ManageOobe')) {
        # Поздний SetupComplete не должен снова отключать сеть после завершения OOBE.
        try { Set-Content -LiteralPath (Join-Path $PSScriptRoot 'oobe-complete') -Value (Get-Date -Format o) -Encoding ascii }
        catch { $script:FinalizeFailed = $true; Write-FinalizeLog (T "Не удалось записать окончание OOBE: $($_.Exception.Message)" "Could not record OOBE completion: $($_.Exception.Message)") }
    }
    try {
        if ((Get-GuestFlag 'RemoveEdge')) {
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
        $script:FinalizeFailed = $true
        Write-FinalizeLog $_.Exception.Message
    } finally {
        # Always restore connectivity, even if optional cleanup failed.
        if (-not $EdgeOnly -and (Get-GuestFlag 'ManageOobe')) {
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
            $script:FinalizeFailed = $true
            Write-FinalizeLog (T "Ошибка возврата адаптеров: $($_.Exception.Message)" "Adapter restoration failed: $($_.Exception.Message)")
        }
        # Независимо от отказа отдельного адаптера снимаем только собственный сетевой блок.
        if ((Get-GuestFlag 'OobeNetworkBlock')) {
        try {
            $firewallName = 'Win11Lite-OOBE-Temporary-Outbound-Block'
            # Не путать недоступность провайдера с отсутствием правила.
            $rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object { $_.Name -eq $firewallName })
            if ($rules.Count) {
                Remove-NetFirewallRule -Name $firewallName -PolicyStore PersistentStore -ErrorAction Stop
                Write-FinalizeLog (T 'Сеть: временная блокировка брандмауэра снята' 'Network: temporary firewall block removed')
            }
        } catch {
            $script:FinalizeFailed = $true
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
            $script:FinalizeFailed = $true
            Write-FinalizeLog ((T 'Ошибка восстановления' 'Restore failed') + ": $($_.Exception.Message)")
        }
        }
    }
    if (-not $script:FinalizeFailed -and -not $EdgeOnly) {
        Write-FinalizeLog (T 'Завершение установки выполнено' 'Finalization completed')
        Unregister-ScheduledTask -TaskName 'win-11-lite finalize' -Confirm:$false -ErrorAction SilentlyContinue
    }
    } finally { $finalizeLock.Dispose() }
}

# ── Guard report window and its on-demand task ────────────────────────────────

# Guard presentation and report-task helpers.
function Get-GuardMode {
    param($Config)
    if($Config.Mode -in @('Debug','Standard','Silent')){return [string]$Config.Mode}
    'Standard'
}

function Get-GuardExpectedApps {
    param($Config)
    $known=@('Microsoft.SecHealthUI','Microsoft.Copilot','Microsoft.Windows.Ai.Copilot.Provider','Clipchamp.Clipchamp','Microsoft.BingNews','Microsoft.BingWeather','Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.MicrosoftOfficeHub','Microsoft.MicrosoftSolitaireCollection','Microsoft.WindowsFeedbackHub','Microsoft.YourPhone','Microsoft.OutlookForWindows','MicrosoftTeams','MSTeams')
    $known+=@('Microsoft.Todos','MicrosoftCorporationII.MicrosoftFamily','Microsoft.ZuneMusic','Microsoft.ZuneVideo','Microsoft.GamingApp','Microsoft.XboxApp','Microsoft.XboxGamingOverlay','Microsoft.XboxGameOverlay','Microsoft.XboxSpeechToTextOverlay')
    if($Config.ExpectedApps){$known=@($Config.ExpectedApps)}
    foreach($name in $known){
        if(@($Config.Protected|Where-Object{$_ -and $name -match $_}).Count){continue}
        if(@($Config.Apps|Where-Object{$_ -and $name -match $_}).Count){$name}
    }
}

function New-GuardViewerAction {
    param([string]$SupportDirectory)
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # Task Scheduler substitutes the worker's GUID; no intermediate console.
    $arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $SupportDirectory 'Win11Lite.ps1')+'" -Mode view -RunId "$(Arg0)"'
    New-ScheduledTaskAction -Execute $powershell -Argument $arguments
}

function Register-GuardViewerTask {
    param([string]$SupportDirectory,[ValidateSet('Debug','Standard','Silent')][string]$Mode='Standard')
    if($Mode -eq 'Silent'){
        Unregister-ScheduledTask -TaskName 'win-11-lite guard report' -Confirm:$false -ErrorAction SilentlyContinue
    }else{
        $action=New-GuardViewerAction $SupportDirectory
        $principal=New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
        $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances Parallel -ExecutionTimeLimit ([TimeSpan]::Zero)
        # Demand start only. The SYSTEM worker opens this task after the OOBE gate.
        Register-ScheduledTask -TaskName 'win-11-lite guard report' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    }
}

function Test-GuardOobeComplete {
    $setup=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
    if($env:USERNAME -eq 'defaultuser0' -or $setup.OOBEInProgress -eq 1 -or $setup.SystemSetupInProgress -eq 1){return $false}
    # An unavailable probe must not open a window, and must not fail the run.
    try{Test-NativeOobeComplete}catch{$false}
}
function Start-GuardViewer {
    param([string]$SupportDirectory,[guid]$RunId,[ValidateSet('Debug','Standard','Silent')][string]$Mode)
    if($Mode -eq 'Silent' -or -not (Test-GuardOobeComplete)){return}
    $sessions=@(Get-Process -Name explorer -IncludeUserName -ErrorAction SilentlyContinue |
        Where-Object{$_.SessionId -gt 0 -and $_.UserName -and $_.UserName -notmatch '\\defaultuser0$'} |
        Select-Object -ExpandProperty SessionId -Unique)
    if(-not $sessions.Count){return}
    $scheduler=New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $task=$scheduler.GetFolder('\').GetTask('win-11-lite guard report')
    if(-not $task.Enabled){return}
    foreach($session in $sessions){
        # TASK_RUN_USE_SESSION_ID: run as the logged-on user, never as SYSTEM.
        $null=$task.RunEx($RunId.ToString(),4,[int]$session,$null)
    }
}

function Get-GuardControlText {
    @(
        (T 'Управление Guard (Терминал от имени администратора):' 'Guard control (run Terminal as administrator):')
        (T 'Отключить:' 'Disable:')
        '  schtasks.exe /Change /TN "\win-11-lite guard" /Disable'
        (T 'Включить обратно:' 'Enable again:')
        '  schtasks.exe /Change /TN "\win-11-lite guard" /Enable'
        (T 'Отключение запрещает следующие запуски; текущая проверка завершится.' 'Disabling prevents future runs; the current check will finish.')
        (T 'После включения проверка выполнится при следующем входе в Windows.' 'After enabling, the check runs at the next Windows sign-in.')
    ) -join "`r`n"
}

function Get-GuardBriefReport {
    param($Report,[bool]$HasHistory)
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add((T 'ИТОГ ПРОВЕРКИ GUARD' 'GUARD SUMMARY'))
    $lines.Add((T "Проверка: $(([datetime]$Report.Started).ToString('yyyy-MM-dd HH:mm:ss'))" "Check: $(([datetime]$Report.Started).ToString('yyyy-MM-dd HH:mm:ss'))"))
    $programs=@($Report.Items|Where-Object{$_.Category -in @('app','provisioned','component') -and -not $_.Inventory -and $_.Outcome -ne 'protected'}|Group-Object Name)
    $programReturned=@($programs|Where-Object{@($_.Group|Where-Object{$_.Reappeared}).Count}).Count
    $programRemoved=@($programs|Where-Object{
        @($_.Group|Where-Object{$_.Reappeared}).Count -and -not @($_.Group|Where-Object{$_.Outcome -notin @('removed','absent')}).Count
    }).Count
    $settings=@($Report.Items|Where-Object{$_.Category -in @('setting','service')})
    $settingsReturned=@($settings|Where-Object{$_.Reappeared}).Count
    $settingsFixed=@($settings|Where-Object{$_.Repeated -and $_.Outcome -in @('disabled','stopped','set','created')}).Count
    $lines.Add('')
    $lines.Add((T "Программ под контролем удаления: $($programs.Count)" "Programs monitored for removal: $($programs.Count)"))
    $lines.Add((T "Программы, появившиеся снова: $programReturned" "Programs that reappeared: $programReturned"))
    $lines.Add((T "Программы, успешно удалённые повторно: $programRemoved" "Programs successfully removed again: $programRemoved"))
    $lines.Add('')
    $lines.Add((T "Настроек и служб под контролем отключения: $($settings.Count)" "Settings and services monitored for disabling: $($settings.Count)"))
    $lines.Add((T "Настройки и службы, сбившиеся или включившиеся снова: $settingsReturned" "Settings and services changed or enabled again: $settingsReturned"))
    $lines.Add((T "Настройки и службы, успешно восстановленные повторно: $settingsFixed" "Settings and services successfully restored again: $settingsFixed"))
    $present=@($programs|Where-Object{@($_.Group|Where-Object{$_.Found -eq $true}).Count}).Count
    $removed=@($programs|Where-Object{@($_.Group|Where-Object{$_.Outcome -eq 'removed'}).Count -and -not @($_.Group|Where-Object{$_.Outcome -notin @('removed','absent')}).Count}).Count
    $fixed=@($settings|Where-Object{$_.Outcome -in @('disabled','stopped','set','created')}).Count
    if($present -or $fixed){$lines.Add((T "Найдено сейчас программ: $present; удалено: $removed; исправлено настроек/служб: $fixed" "Programs found now: $present; removed: $removed; settings/services corrected: $fixed"))}
    foreach($category in 'capability','path'){
        $rows=@($Report.Items|Where-Object{$_.Category -eq $category -and -not $_.Inventory})
        $foundRows=@($rows|Where-Object{$_.Found -eq $true})
        $found=$foundRows.Count
        $cleared=@($rows|Where-Object{$_.Outcome -eq 'removed'}).Count
        if($found){
            $label=if($category -eq 'path'){T 'Файлы и каталоги' 'Files and directories'}else{T 'Компоненты Windows' 'Windows capabilities'}
            $lines.Add((T "${label}: найдено $found; удалено $cleared" "${label}: found $found; removed $cleared"))
            foreach($row in $foundRows){
                if($category -eq 'path'){
                    # Identity содержит конкретное совпадение, Name может быть маской.
                    $path=if($row.Identity){[string]$row.Identity}else{[string]$row.Name}
                    $parts=@($path -split '[\\/]+'|Where-Object{$_})
                    $name=$parts[-1]
                    $sameName=@($foundRows|Where-Object{
                        $other=if($_.Identity){[string]$_.Identity}else{[string]$_.Name}
                        ($other.TrimEnd('\','/') -split '[\\/]')[-1] -eq $name
                    })
                    if($sameName.Count -gt 1 -and $parts.Count -gt 1){$name+=" ($($parts[-2]))"}
                }else{
                    $baseName=([string]$row.Name -split '~')[0]
                    $name=switch($baseName){
                        'Media.WindowsMediaPlayer'{'Windows Media Player'}
                        'Language.Handwriting'{T 'Рукописный ввод' 'Handwriting'}
                        'Language.OCR'{T 'Распознавание текста (OCR)' 'Text recognition (OCR)'}
                        'Language.Speech'{T 'Распознавание речи' 'Speech recognition'}
                        'Language.TextToSpeech'{T 'Синтез речи' 'Text to speech'}
                        default{$baseName}
                    }
                    if($row.Name -match '~([a-z]{2,3}(?:-[a-z0-9]+)+)~'){$name+=" ($($matches[1]))"}
                }
                $outcome=switch($row.Outcome){
                    'removed'{T 'удалено' 'removed'}
                    'pending'{T 'ожидает завершения удаления' 'removal pending'}
                    'failed'{T 'ошибка' 'error'}
                    'skipped'{T 'пропущено' 'skipped'}
                    'protected'{T 'сохранено по правилам защиты' 'retained by protection rules'}
                    default{T 'результат не подтверждён' 'result unconfirmed'}
                }
                $lines.Add("  - $name — $outcome")
            }
        }
    }
    $pending=@($Report.Items|Where-Object{$_.Outcome -eq 'pending'}).Count
    $unchecked=@($Report.Items|Where-Object{$_.Outcome -eq 'not_checked'}).Count
    if($pending){$lines.Add((T "Ожидают завершения удаления: $pending" "Removals still pending: $pending"))}
    if(-not $Report.Complete -or $Report.Deferred -or $unchecked){$lines.Add((T "Проверка не завершена; непроверенных пунктов: $unchecked" "Check is incomplete; unchecked items: $unchecked"))}
    if(-not $HasHistory){$lines.Add((T 'Первый запуск: повторность пока неизвестна; история начинается с этой проверки.' 'First run: recurrence is not yet known; history starts with this check.'))}
    $lines.Add('')
    $lines.Add((T "Ошибок проверки: $($Report.Errors); записи: $($Report.LogErrors); показа: $($Report.ViewErrors)." "Check errors: $($Report.Errors); writing errors: $($Report.LogErrors); display errors: $($Report.ViewErrors)."))
    foreach($row in $Report.Items|Where-Object{$_.Outcome -eq 'failed'}){
        $name=if($row.Category -eq 'path'){($row.Name -split '[\\/]')[-1]}else{$row.Name}
        if($row.Category -eq 'path' -and $row.Detail -match '(?:^|;)\s*Target=([^\r\n;]+)'){
            $leaf=($matches[1] -split '[\\/]')[-1]
            if($leaf -and $leaf -ne $name){$name+=" ($leaf)"}
        }
        $reason=switch($row.Category){'path'{T 'ошибка удаления/проверки' 'removal/check error'} 'service'{T 'ошибка проверки службы' 'service check error'} 'setting'{T 'ошибка проверки настройки' 'setting check error'} default{T 'ошибка проверки' 'check error'}}
        $code=if($row.ErrorCode){$row.ErrorCode}elseif($row.Detail -match 'HRESULT=(0x[0-9A-Fa-f]+)'){$matches[1]}else{''}
        $lines.Add("  $name — $reason$(if($code){' ('+$code+')'})")
    }
    foreach($warning in $Report.Warnings){$lines.Add("! $warning")}
    $lines.Add('')
    $lines.Add((Get-GuardControlText))
    [pscustomobject]@{
        Text=($lines -join "`r`n")
        Counts=[ordered]@{Programs=$programs.Count;ProgramsReappeared=$programReturned;ProgramsRemovedAgain=$programRemoved;Settings=$settings.Count;SettingsReappeared=$settingsReturned;SettingsRestoredAgain=$settingsFixed;HasHistory=$HasHistory}
    }
}

function Show-GuardView {
    param([string]$SupportDirectory,[ValidateSet('Debug','Standard','Silent')][string]$Mode,[string]$RunId,[int]$WaitSeconds=120)
    if($Mode -eq 'Silent' -or -not (Test-GuardOobeComplete)){return}
    if($RunId -and $RunId -ne '$(Arg0)'){$null=[guid]::Parse($RunId)}else{$RunId=''}
    $Host.UI.RawUI.WindowTitle='win-11-lite guard - '+$Mode
    $deadline=(Get-Date).AddSeconds($WaitSeconds)
    $reportPath=Join-Path $SupportDirectory 'guard-report.json'
    if($Mode -eq 'Debug'){
        $marker=Get-Content -LiteralPath (Join-Path $SupportDirectory 'guard-run.json') -Raw -Encoding UTF8|ConvertFrom-Json
        if($RunId -and $marker.RunId -ne $RunId){throw (T 'Этот запуск уже завершён; откройте последний отчёт из папки guard.' 'This run has been superseded; open the latest report from the guard folder.')}
        $log=Join-Path $SupportDirectory 'guard.log'
        $stream=[IO.File]::Open($log,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        try{
            $null=$stream.Seek([long]$marker.LogOffset,[IO.SeekOrigin]::Begin)
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
            try{
                $done=$false;$deadline=(Get-Date).AddMinutes(25)
                while(-not $done){
                    while($null -ne ($line=$reader.ReadLine())){
                        $color=if($line -match '\[ERROR\]'){'Red'}elseif($line -match '\[CHANGED\]|\[END\]'){'Green'}else{'Gray'}
                        Write-Host $line -ForegroundColor $color
                        if($line -match '\[END\]'){$done=$true;break}
                    }
                    if(-not $done){if((Get-Date) -ge $deadline){throw (T 'Истекло время ожидания guard.' 'Timed out waiting for guard.')} ;Start-Sleep -Milliseconds 200}
                }
            }finally{$reader.Dispose()}
        }finally{$stream.Dispose()}
    }else{
        while($true){
            $report=$null
            try{if(Test-Path -LiteralPath $reportPath){$report=Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8|ConvertFrom-Json}}catch{}
            if($report -and (-not $RunId -or $report.RunId -eq $RunId)){
                if(-not $report.BriefText){throw (T 'Краткий отчёт ещё не создан. Дождитесь новой проверки guard.' 'No summary is available yet. Wait for a new guard check.')}
                Write-Host $report.BriefText
                break
            }
            if((Get-Date) -ge $deadline){throw (T 'Отчёт этого запуска не создан. Проверьте guard.log в папке guard.' 'No report was created for this run. Check guard.log in the guard folder.')}
            Start-Sleep -Milliseconds 200
        }
    }
    Write-Host ''
    $detailsPath=Join-Path $SupportDirectory 'guard-report.txt'
    Write-Host (T "Подробный отчёт: $detailsPath" "Detailed report: $detailsPath") -ForegroundColor Gray
    $null=Read-Host (T 'Нажмите Enter, чтобы закрыть окно' 'Press Enter to close')
}

# ── Guard worker helpers ──────────────────────────────────────────────────────

function Write-GuardLog {
    param([string]$Level, [string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
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
    # remaining checks. The runner captures stderr in launcher.log.
    $counts.LogFailed++
    try { [Console]::Error.WriteLine("[LOG ERROR] ${logFile}: $($problem.Message)`r`n$line") } catch { }
}
# Keep native diagnostics without turning redirected stderr into a terminating
# exception on Windows PowerShell 5.1. Permission preparation is best effort:
# an ownership error alone does not prove that deletion is impossible.
function Invoke-GuardAccessCommand {
    param([string]$FileName, [string[]]$Arguments, [hashtable]$Observation)
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $Observation.Step=$FileName
    $global:LASTEXITCODE=-1
    $output=@(& $FileName @Arguments 2>&1 | Select-Object -Last 12)
    $code=$LASTEXITCODE
    $Observation.Detail+="; $FileName ExitCode=$code"
    if($code -ne 0){
        $tail=(@($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        $message="$FileName ExitCode=$code; $($Arguments -join ' ')"
        if($tail){$message+=[Environment]::NewLine+$tail;$Observation.Detail+=[Environment]::NewLine+$tail}
        Write-GuardLog 'DETAIL' $message
    }
}
function Grant-SystemAccess {
    param([string]$Path, [switch]$Recurse, [hashtable]$Observation)
    if ($Recurse) {
        Invoke-GuardAccessCommand 'takeown.exe' @('/F',$Path,'/R','/A','/D','Y') $Observation
        Invoke-GuardAccessCommand 'icacls.exe' @($Path,'/grant','*S-1-5-18:(OI)(CI)F','/T','/C','/Q') $Observation
    } else {
        Invoke-GuardAccessCommand 'takeown.exe' @('/F',$Path,'/A') $Observation
        Invoke-GuardAccessCommand 'icacls.exe' @($Path,'/grant','*S-1-5-18:F','/C','/Q') $Observation
    }
}
function Test-GuardMatch {
    param([string]$Name, [string[]]$Patterns)
    foreach ($pattern in @($config.Protected)) { if ($pattern -and $Name -match $pattern) { return $false } }
    foreach ($pattern in $Patterns) { if ($pattern -and $Name -match $pattern) { return $true } }
    return $false
}

function Invoke-GuardPresentation {
    if(-not $config.ViewerTask -or $guardMode -eq 'Silent'){return}
    try{Start-GuardViewer -SupportDirectory $PSScriptRoot -RunId $guardRunId -Mode $guardMode}
    catch{
        $counts.ViewFailed++
        $guardWarnings.Add((T 'Не удалось открыть окно guard; проверьте файлы отчёта в папке guard.' 'Could not open the guard window; check the report files in the guard folder.'))
        Write-GuardLog 'ERROR' ("Viewer: "+$_.Exception.Message)
    }
}
function Remove-GuardSelectedPath {
    param([string]$Path,[bool]$Directory,[hashtable]$Observation)
    $selectedRoot=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    $retried=@{}
    while($true){
        try{Remove-Item -LiteralPath $Path -Recurse:$Directory -Force -ErrorAction Stop;return}
        catch{
            # Remove-Item -Force sets attributes before deleting, even when that
            # change is unnecessary. Some serviced files reject that operation.
            # Only this provider error permits a direct, single-file retry.
            $failure=$_
            if($failure.FullyQualifiedErrorId -notlike 'RemoveFileSystemItemArgumentError*' -or $failure.TargetObject -isnot [IO.FileInfo]){throw}
            $target=[IO.Path]::GetFullPath($failure.TargetObject.FullName)
            if(($target -ne $selectedRoot -and -not $target.StartsWith($selectedRoot+'\',[StringComparison]::OrdinalIgnoreCase)) -or $retried.ContainsKey($target)){throw}
            $cursor=Split-Path $target -Parent
            while($cursor){
                if((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw (T 'Повторное удаление через ссылку каталога запрещено' 'Retry through a directory link is not allowed')}
                $cursor=Split-Path $cursor -Parent
            }
            $retried[$target]=$true
            Write-GuardLog 'DETAIL' "Remove-Item attribute error; direct file deletion: $target"
            $Observation.Step=(T "удаление файла без смены атрибутов: $target" "file deletion without changing attributes: $target")
            [IO.File]::Delete($target)
            if(Test-Path -LiteralPath $target -ErrorAction Stop){throw (T 'Файл остался после повторного удаления' 'File remains after retry')}
            $Observation.Detail+=(T "; удалён без смены атрибутов: $target" "; deleted without changing attributes: $target")
            if(-not $Directory){return}
            $Observation.Step=(T 'удаление (Remove-Item)' 'removal (Remove-Item)')
        }
    }
}
function Add-GuardDetail {
    param([string]$Category,[string]$Name,[string]$Outcome,$Found,[string]$Before,[string]$After,[string]$Detail,[string]$Desired,[string]$Identity=$Name,[switch]$Inventory,[string]$ErrorCode)
    $key="$Category|$Identity"
    $changed=$Outcome -in @('removed','disabled','stopped','set','created')
    $known=$Desired -and $guardHistory.ContainsKey($key) -and [string]$guardHistory[$key].Desired -eq $Desired
    $repeated=$changed -and $known
    $reappeared=$known -and (($Desired -eq 'absent' -and $Found -eq $true) -or
        ($Category -eq 'setting' -and $null -ne $Found -and $Before -ne $Desired) -or
        ($Category -eq 'service' -and $Found -eq $true -and $Before -and $Before -ne 'Start=4; Stopped'))
    $guardRows.Add([pscustomobject]@{Category=$Category;Name=$Name;Identity=$Identity;Outcome=$Outcome;Found=$Found;Before=$Before;After=$After;Detail=$Detail;Repeated=[bool]$repeated;Reappeared=[bool]$reappeared;Inventory=[bool]$Inventory;ErrorCode=$ErrorCode})
    if($Desired -and -not($Category -eq 'service' -and $Outcome -eq 'absent') -and $Outcome -in @('removed','disabled','stopped','set','created','compliant','already_disabled','absent')){
        $guardNextHistory[$key]=[pscustomobject]@{Key=$key;Desired=$Desired;LastSuccess=(Get-Date).ToString('o')}
    }
}
function Invoke-GuardCheck {
    param([string]$Label, [scriptblock]$Action,[string]$Category='component',[string]$Name=$Label,[string]$Desired='',[string]$Identity=$Name)
    $counts.Checked++
    $guardVisited["$Category|$Identity"]=$true
    Write-GuardLog 'CHECK' $Label
    $observation=@{Found=$null;Before='';After='';Detail='';Step=''}
    try {
        $result = & $Action $observation
        if ($result -eq 'changed') {
            $counts.Changed++; Write-GuardLog 'CHANGED' $Label
            $outcome=switch($Category){'setting'{if($observation.Found){'set'}else{'created'}} 'service'{if($observation.Before -like 'Start=4;*'){'stopped'}else{'disabled'}} default{'removed'}}
        }
        elseif ($result -eq 'pending') { $outcome='pending';$counts.Pending++; Write-GuardLog 'PENDING' (T "$Label — требуется завершение обслуживания" "$Label - servicing still pending") }
        elseif ($result -eq 'skipped') { $outcome='skipped';$counts.Skipped++; Write-GuardLog 'SKIP' $Label }
        else { $outcome=if($observation.Found -eq $false){'absent'}elseif($Category -eq 'service'){'already_disabled'}else{'compliant'};Write-GuardLog 'OK' $Label }
        Add-GuardDetail -Category $Category -Name $Name -Identity $Identity -Outcome $outcome -Found $observation.Found -Before $observation.Before -After $observation.After -Detail $observation.Detail -Desired $Desired
    } catch {
        $counts.Failed++
        $failure=$_
        $problem=$failure.Exception.GetBaseException()
        $detail=$failure.Exception.Message
        if($observation.Step){$detail=(T "Этап: $($observation.Step). $detail" "Stage: $($observation.Step). $detail")}
        Write-GuardLog 'ERROR' "$Label : $detail"
        $diagnostic="$($problem.GetType().FullName); HRESULT=0x$($problem.HResult.ToString('X8')); $($failure.FullyQualifiedErrorId)"
        if($null -ne $failure.TargetObject){$diagnostic+="; Target=$($failure.TargetObject)"}
        $logDiagnostic=$diagnostic
        if($failure.ScriptStackTrace){$logDiagnostic+=[Environment]::NewLine+$failure.ScriptStackTrace}
        Write-GuardLog 'DETAIL' $logDiagnostic
        if($observation.Detail){$detail+=[Environment]::NewLine+$observation.Detail}
        $detail+=[Environment]::NewLine+$diagnostic
        Add-GuardDetail -Category $Category -Name $Name -Identity $Identity -Outcome 'failed' -Found $observation.Found -Before $observation.Before -After $observation.After -Detail $detail -Desired $Desired -ErrorCode ('0x'+$problem.HResult.ToString('X8'))
    }
}
function Read-GuardInventory {
    param([string]$Label, [scriptblock]$Read,[string]$Category)
    $counts.Checked++
    Write-GuardLog 'CHECK' $Label
    try { $items=@(& $Read);$guardInventoryStatus[$Category]=$true;$items }
    catch {
        $guardInventoryStatus[$Category]=$false;$counts.Failed++;Write-GuardLog 'ERROR' "$Label : $($_.Exception.Message)"
        Add-GuardDetail -Category $Category -Name $Label -Outcome 'failed' -Found $null -Inventory -Detail (T "Список недоступен; отсутствие компонентов не подтверждено. $($_.Exception.Message)" "Inventory unavailable; component absence is unconfirmed. $($_.Exception.Message)")
        if($Category -in @('app','provisioned')){
            foreach($name in @(Get-GuardExpectedApps $config)){Add-GuardDetail -Category $Category -Name $name -Outcome not_checked -Found $null -Desired absent}
        }
    }
}
function Add-MissingGuardTargets {
    param([string]$Category,[string[]]$Patterns,[object[]]$Inventory,[string]$NameProperty)
    if(-not $guardInventoryStatus[$Category]){return}
    $targets=@($Patterns|Where-Object{$_})
    if($Category -in @('app','provisioned')){
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
        $label=($pattern -replace '^\^|\$$','' -replace '\\\.','.')
        $hint=@($config.TargetLabels|Where-Object{$_.Category -eq $Category -and $_.Pattern -eq $pattern}|Select-Object -First 1)
        if($hint.Count){$label=$hint[0].Name}
        $counts.Checked++
        Add-GuardDetail -Category $Category -Name $label -Identity $pattern -Outcome 'absent' -Found $false -After (T 'Нет совпадений в полученном списке' 'No matches in the retrieved inventory')
    }
}
function Get-GuardOutcomeText {
    param($Row)
    switch($Row.Outcome){
        'absent' {T 'не найдено / уже отсутствует' 'not found / already absent'}
        'removed' {if($Row.Repeated){T 'снова появилось и успешно удалено' 'reappeared and successfully removed'}else{T 'найдено и успешно удалено' 'found and successfully removed'}}
        'already_disabled' {T 'найдена, уже отключена и остановлена' 'found, already disabled and stopped'}
        'disabled' {if($Row.Repeated){T 'найдена включённой, отключена повторно' 'found enabled, disabled again'}else{T 'найдена включённой, отключена сейчас' 'found enabled, disabled now'}}
        'stopped' {if($Row.Repeated){T 'запуск отключён, служба остановлена повторно' 'startup disabled, service stopped again'}else{T 'запуск уже отключён, работающая служба остановлена' 'startup already disabled, running service stopped'}}
        'compliant' {T 'найдено, настройка уже соответствует требуемой' 'found, setting already matches the target'}
        'set' {if($Row.Repeated){T 'настройка найдена и восстановлена повторно' 'setting found and reapplied'}else{T 'настройка найдена и исправлена' 'setting found and corrected'}}
        'created' {if($Row.Repeated){T 'настройка отсутствовала, создана повторно' 'setting was missing and recreated'}else{T 'настройка отсутствовала, создана' 'setting was missing and created'}}
        'pending' {T 'найдено, удаление ещё не завершено' 'found, removal still pending'}
        'skipped' {T 'найдено, пропущено' 'found, skipped'}
        'protected' {T 'найдено, сохранено по правилам защиты' 'found, retained by protection rules'}
        'not_checked' {T 'не проверено' 'not checked'}
        'failed' {T 'ошибка; требуемый результат не подтверждён' 'error; target result is unconfirmed'}
    }
}
function Add-UncheckedGuardTargets {
    if($guardComplete){return}
    foreach($entry in $config.Policies){
        $parts=$entry -split '\|';$identity="$($parts[0])\$($parts[1])"
        if(-not $guardVisited.ContainsKey("setting|$identity")){Add-GuardDetail -Category setting -Name $parts[1] -Identity $identity -Outcome not_checked -Found $null}
    }
    foreach($name in $config.Services){if(-not $guardVisited.ContainsKey("service|$name")){Add-GuardDetail -Category service -Name $name -Outcome not_checked -Found $null}}
    foreach($name in $config.Paths){if(-not $guardVisited.ContainsKey("path|$name")){Add-GuardDetail -Category path -Name $name -Outcome not_checked -Found $null}}
    if($config.RemoveEdge -and -not $guardVisited.ContainsKey('component|Microsoft Edge')){Add-GuardDetail -Category component -Name 'Microsoft Edge' -Outcome not_checked -Found $null}
    foreach($category in 'capability','app','provisioned'){
        if($guardInventoryStatus.ContainsKey($category)){continue}
        $patterns=if($category -eq 'capability'){@($config.Capabilities)}else{@($config.Apps)}
        foreach($pattern in $patterns|Where-Object{$_}){Add-GuardDetail -Category $category -Name ($pattern -replace '^\^|\$$','' -replace '\\\.','.') -Outcome not_checked -Found $null}
    }
}
function Get-GuardStateText {
    param([string]$State)
    if($State -match '^Start=(\d+); (.+)$'){
        $start=switch($matches[1]){'0'{T 'при загрузке' 'boot'} '1'{T 'системный' 'system'} '2'{T 'автоматически' 'automatic'} '3'{T 'вручную' 'manual'} '4'{T 'отключён' 'disabled'} default{$matches[1]}}
        $status=switch($matches[2]){'Running'{T 'работает' 'running'} 'Stopped'{T 'остановлена' 'stopped'} default{$matches[2]}}
        return (T "запуск: $start; состояние: $status" "startup: $start; state: $status")
    }
    switch($State){
        'Absent'{T 'отсутствует' 'absent'}
        'NotPresent'{T 'отсутствует' 'absent'}
        'Not Present'{T 'отсутствует' 'absent'}
        'Present'{T 'присутствует' 'present'}
        'Installed'{T 'установлено' 'installed'}
        'Provisioned'{T 'подготовлено для новых пользователей' 'provisioned for new users'}
        'Pending'{T 'ожидается завершение' 'pending completion'}
        'UninstallPending'{T 'ожидается завершение удаления' 'removal pending'}
        ''{T 'не подтверждено' 'unconfirmed'}
        default{$State}
    }
}
function Save-GuardReport {
    Add-UncheckedGuardTargets
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add((T 'ИТОГ ПРОВЕРКИ GUARD' 'GUARD CHECK REPORT'))
    $lines.Add((T "Начало: $($guardStartedAt.ToString('yyyy-MM-dd HH:mm:ss')); сборка: $($config.BuildId)" "Started: $($guardStartedAt.ToString('yyyy-MM-dd HH:mm:ss')); build: $($config.BuildId)"))
    $status=if($guardSkippedOobe){T 'Отложено: настройка Windows ещё выполняется' 'Deferred: Windows setup is still running'}elseif(-not $guardComplete){T 'Проверка прервана; часть объектов не проверена' 'Run interrupted; some objects were not checked'}elseif($counts.Failed){T 'Проверка завершена с ошибками' 'Run completed with errors'}elseif($counts.Pending){T 'Проверка завершена; есть незавершённое удаление' 'Run completed; some removals are pending'}else{T 'Проверка завершена' 'Run completed'}
    $lines.Add($status)
    $totals=[ordered]@{}
    foreach($category in 'setting','service','component','capability','app','provisioned','path','run'){
        $rows=@($guardRows|Where-Object{$_.Category -eq $category})
        if(-not $rows.Count){continue}
        $title=switch($category){'setting'{T 'НАСТРОЙКИ' 'SETTINGS'} 'service'{T 'СЛУЖБЫ И ДРАЙВЕРЫ' 'SERVICES AND DRIVERS'} 'component'{T 'КОМПОНЕНТЫ' 'COMPONENTS'} 'capability'{T 'ВОЗМОЖНОСТИ WINDOWS' 'WINDOWS CAPABILITIES'} 'app'{T 'УСТАНОВЛЕННЫЕ ПРИЛОЖЕНИЯ' 'INSTALLED APPS'} 'provisioned'{T 'ВСТРОЕННЫЕ ПАКЕТЫ ПРИЛОЖЕНИЙ' 'PROVISIONED APPS'} 'path'{T 'ФАЙЛЫ И КАТАЛОГИ' 'FILES AND DIRECTORIES'} 'run'{T 'СОСТОЯНИЕ ПРОВЕРКИ' 'RUN STATUS'}}
        $found=@($rows|Where-Object{$_.Found -eq $true}).Count
        $absent=@($rows|Where-Object{$_.Outcome -eq 'absent'}).Count
        $changed=@($rows|Where-Object{$_.Outcome -in @('removed','disabled','stopped','set','created')}).Count
        $repeated=@($rows|Where-Object{$_.Repeated}).Count
        $errors=@($rows|Where-Object{$_.Outcome -eq 'failed'}).Count
        $unchecked=@($rows|Where-Object{$_.Outcome -eq 'not_checked'}).Count
        $totals[$category]=[ordered]@{Total=$rows.Count;Found=$found;Absent=$absent;Changed=$changed;Repeated=$repeated;Errors=$errors;NotChecked=$unchecked}
        foreach($outcome in @('compliant','already_disabled','removed','disabled','stopped','created','pending','skipped')){$totals[$category][$outcome]=@($rows|Where-Object{$_.Outcome -eq $outcome}).Count}
        $lines.Add('');$lines.Add($title)
        if($category -eq 'service'){
            $already=@($rows|Where-Object{$_.Outcome -eq 'already_disabled'}).Count
            $lines.Add((T "  Найдено: $found; отсутствует: $absent; уже отключено: $already" "  Found: $found; absent: $absent; already disabled: $already"))
            $lines.Add((T "  Отключено/остановлено сейчас: $changed; из них повторно: $repeated; ошибок: $errors" "  Disabled/stopped now: $changed; repeated: $repeated; errors: $errors"))
        }elseif($category -eq 'setting'){
            $correct=@($rows|Where-Object{$_.Outcome -eq 'compliant'}).Count;$created=@($rows|Where-Object{$_.Outcome -eq 'created'}).Count
            $lines.Add((T "  Найдено: $found; уже верны: $correct; создано отсутствующих: $created" "  Found: $found; already correct: $correct; missing settings created: $created"))
            $lines.Add((T "  Исправлено/создано сейчас: $changed; из них повторно: $repeated; ошибок: $errors" "  Corrected/created now: $changed; repeated: $repeated; errors: $errors"))
        }elseif($category -eq 'run'){
            $lines.Add((T "  Ошибок выполнения: $errors" "  Execution errors: $errors"))
        }else{
            $pending=@($rows|Where-Object{$_.Outcome -eq 'pending'}).Count
            $skipped=@($rows|Where-Object{$_.Outcome -in @('skipped','protected')}).Count
            $lines.Add((T "  Найдено: $found; не найдено: $absent; успешно удалено: $changed" "  Found: $found; not found: $absent; successfully removed: $changed"))
            $lines.Add((T "  Ожидает завершения: $pending; пропущено/сохранено: $skipped; ошибок: $errors" "  Pending: $pending; skipped/retained: $skipped; errors: $errors"))
        }
        if($unchecked){$lines.Add((T "  Не проверено: $unchecked" "  Not checked: $unchecked"))}
        foreach($row in $rows){
            $prefix=if($row.Outcome -eq 'failed'){'[ERROR]'}else{'-'}
            $lines.Add("  $prefix $($row.Name): $(Get-GuardOutcomeText $row)")
            if($row.Before -ne $row.After){$lines.Add((T "      Было: $(Get-GuardStateText $row.Before); стало: $(Get-GuardStateText $row.After)" "      Before: $(Get-GuardStateText $row.Before); after: $(Get-GuardStateText $row.After)"))}
            elseif($row.Category -eq 'setting' -and $row.After){$lines.Add((T "      Значение: $($row.After)" "      Value: $($row.After)"))}
            if($row.Detail){$lines.Add("      $($row.Detail)")}
        }
    }
    $lines.Add('')
    $lines.Add((T "Всего ошибок проверок: $($counts.Failed); ошибок записи журнала: $($counts.LogFailed)." "Total check errors: $($counts.Failed); log write errors: $($counts.LogFailed)."))
    if(-not $guardHistory.Count){$lines.Add((T 'Предыдущей истории ещё нет: повторные изменения пока не определяются.' 'No previous history yet: repeated changes cannot be determined.'))}
    foreach($warning in $guardWarnings){$lines.Add("! $warning")}
    $lines.Add('')
    $lines.Add((Get-GuardControlText))
    $text=$lines -join "`r`n"
    Write-GuardLog 'REPORT' ("`r`n"+$text)
    $report=[ordered]@{Schema=2;BuildId=$config.BuildId;RunId=$guardRunId;Mode=$guardMode;Started=$guardStartedAt.ToString('o');Finished=(Get-Date).ToString('o');Complete=$guardComplete;Deferred=$guardSkippedOobe;Errors=$counts.Failed;LogErrors=$counts.LogFailed;ViewErrors=$counts.ViewFailed;Summary=$totals;Items=@($guardRows.ToArray());Warnings=@($guardWarnings.ToArray())}
    $brief=Get-GuardBriefReport -Report $report -HasHistory ([bool]$guardHistory.Count)
    $report.Brief=$brief.Counts;$report.BriefText=$brief.Text
    # Publish JSON last so the Standard viewer sees failures writing other files.
    foreach($name in 'guard-report.txt','guard-state.json','guard-summary.txt','guard-report.json'){
        if($name -in @('guard-summary.txt','guard-report.json')){
            $report.LogErrors=$counts.LogFailed
            $brief=Get-GuardBriefReport -Report $report -HasHistory ([bool]$guardHistory.Count)
            $report.Brief=$brief.Counts;$report.BriefText=$brief.Text
        }
        $document=@{Name=$name;Text=$(switch($name){
            'guard-report.txt'{$text}
            'guard-state.json'{[ordered]@{Schema=1;BuildId=$config.BuildId;Managed=@($guardNextHistory.Values)}|ConvertTo-Json -Depth 5}
            'guard-summary.txt'{$brief.Text}
            'guard-report.json'{$report|ConvertTo-Json -Depth 8}
        })}
        $target=Join-Path $PSScriptRoot $document.Name;$temporary=$target+'.'+$PID+'.tmp'
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

# ── Requested mode ─────────────────────────────────────────────────────────────
if (-not $Mode -or $ExtraArguments.Count) { Write-RunnerLog "Unsupported request: Mode='$Mode'; extra='$($ExtraArguments -join ' ')'"; exit 87 }
if ($Mode -eq 'view') {
    # Read-only report window. It never starts another process and never runs
    # as SYSTEM: the task that calls it is limited to the interactive user.
    $viewMode = 'Standard'
    try {
        $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'guard.json') -Raw | ConvertFrom-Json
        $viewMode = Get-GuardMode $config
        Show-GuardView -SupportDirectory $PSScriptRoot -Mode $viewMode -RunId $RunId -WaitSeconds $(if ($WaitSeconds) { $WaitSeconds } else { 120 })
    } catch {
        Write-Host (T 'Не удалось показать отчёт guard. Подробности доступны в папке guard.' 'Could not display the guard report. Details are available in the guard folder.') -ForegroundColor Red
        if ($viewMode -eq 'Debug') { Write-Host $_.Exception.Message -ForegroundColor Red }
        $null = Read-Host (T 'Нажмите Enter, чтобы закрыть окно' 'Press Enter to close')
        exit 1
    }
    exit 0
}
if (-not $Direct) { exit (Start-GuestChild -ChildMode $Mode) }
if ($Mode -eq 'prepare' -or $Mode -eq 'prepare-register') {
    Invoke-Prepare -RegisterOnly:($Mode -eq 'prepare-register')
    exit 0
}
if ($Mode -eq 'finalize' -or $Mode -eq 'finalize-wait') {
    Invoke-Finalize -FirstLogon:($Mode -eq 'finalize') -WaitForOobe:($Mode -eq 'finalize-wait') -WaitSeconds $(if ($WaitSeconds) { $WaitSeconds } else { 7200 })
    if ($script:FinalizeFailed) { exit 1 }
    exit 0
}
if ($Mode -eq 'guard') {
    # The worker keeps its state in script scope: helpers above read and update
    # these collections while the checks below run.
    $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'guard.json') -Raw | ConvertFrom-Json
    $counts = @{Checked=0;Changed=0;Pending=0;Failed=0;Skipped=0;LogFailed=0;ViewFailed=0}
    $guardRows=[Collections.Generic.List[object]]::new()
    $guardWarnings=[Collections.Generic.List[string]]::new()
    $guardHistory=@{}; $guardNextHistory=@{}; $guardInventoryStatus=@{}; $guardVisited=@{}
    $guardStartedAt=Get-Date; $guardComplete=$false; $guardSkippedOobe=$false
    $guardRunId=[guid]::NewGuid().ToString()
    $guardMode = Get-GuardMode $config
    try { $runLock = [IO.File]::Open((Join-Path $PSScriptRoot 'guard.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { return }
    try {
        try{
            $offset=if(Test-Path -LiteralPath $logFile){(Get-Item -LiteralPath $logFile).Length}else{0}
            $marker=@{RunId=$guardRunId;BuildId=$config.BuildId;Started=$guardStartedAt.ToString('o');LogOffset=$offset}|ConvertTo-Json
            [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'guard-run.json'),$marker,[Text.UTF8Encoding]::new($true))
        }catch{$counts.LogFailed++;$guardWarnings.Add((T 'Не удалось записать начало проверки.' 'Could not record the check start.'))}
        try {
            $historyPath=Join-Path $PSScriptRoot 'guard-state.json'
            if(Test-Path -LiteralPath $historyPath){
                $prior=Get-Content -LiteralPath $historyPath -Raw|ConvertFrom-Json
                if($prior.Schema -eq 1 -and $prior.BuildId -eq $config.BuildId){foreach($item in $prior.Managed){$guardHistory[$item.Key]=$item;$guardNextHistory[$item.Key]=$item}}
            }
        }catch{$guardWarnings.Add((T 'Не удалось прочитать прошлую историю; повторность изменений не определяется.' 'Previous history could not be read; repeated changes cannot be determined.'))}
        Write-GuardLog 'START' (T "Проверка при входе; сборка $($config.BuildId)" "Logon check; build $($config.BuildId)")
        $setup = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
        if ($setup.OOBEInProgress -eq 1 -or $setup.SystemSetupInProgress -eq 1) {
            $guardSkippedOobe=$true
            $counts.Skipped++
            Write-GuardLog 'SKIP' (T 'OOBE ещё выполняется. Проверка продолжится при следующем входе.' 'OOBE is still running. Checks will run at the next logon.')
            Add-GuardDetail -Category run -Name 'OOBE' -Outcome 'not_checked' -Found $null -Detail (T 'Политики, службы и компоненты не проверялись.' 'Policies, services and components were not checked.')
        } else {
            if($guardMode -eq 'Debug'){Invoke-GuardPresentation}
            if ($config.RemoveEdge) {
                Invoke-GuardCheck -Label 'Edge' -Category component -Name 'Microsoft Edge' -Desired absent -Action {
                    param($observation)
                    $browserPaths = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { Join-Path $_ 'Microsoft\Edge' }
                    $hadBrowser = @($browserPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
                    $observation.Found=$hadBrowser;$observation.Before=if($hadBrowser){'Present'}else{'Absent'}
                    Invoke-Finalize -EdgeOnly
                    if ($script:FinalizeFailed) { throw (T 'Ошибка очистки Edge; см. finalize.log' 'Edge cleanup failed; see finalize.log') }
                    if (@($browserPaths | Where-Object { Test-Path -LiteralPath $_ }).Count) { throw (T 'Файлы Edge всё ещё присутствуют' 'Edge files are still present') }
                    $observation.After='Absent'
                    if ($hadBrowser) { 'changed' } else { 'ok' }
                }
            }
            foreach ($entry in @($config.Policies)) {
                $parts = $entry -split '\|'; $path = $parts[0]; $name = $parts[1]; $want = [int]$parts[2]
                Invoke-GuardCheck -Label (T "Политика $name" "Policy $name") -Category setting -Name $name -Identity "$path\$name" -Desired ([string]$want) -Action {
                    param($observation)
                    $propertyErrors=@()
                    $current = (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue -ErrorVariable propertyErrors).$name
                    $denied=@($propertyErrors|Where-Object{$_.CategoryInfo.Category -in @('PermissionDenied','SecurityError')})
                    if($denied.Count){throw $denied[0]}
                    $observation.Found=$null -ne $current;$observation.Before=if($null -eq $current){T 'отсутствовала' 'missing'}else{[string]$current};$observation.Detail=$path
                    if ($null -ne $current -and [int]$current -eq $want) { $observation.After=[string]$want;return 'ok' }
                    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
                    Set-ItemProperty -LiteralPath $path -Name $name -Value $want -Type DWord -Force -ErrorAction Stop
                    $actual = (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop).$name
                    if ($null -eq $actual -or [int]$actual -ne $want) { throw (T 'Значение не изменилось' 'Value did not change') }
                    $observation.After=[string]$actual
                    'changed'
                }
            }
            foreach ($svc in @($config.Services)) {
                Invoke-GuardCheck -Label (T "Служба $svc" "Service $svc") -Category service -Name $svc -Desired disabled -Action {
                    param($observation)
                    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
                    $observation.Found=[bool](Test-Path -LiteralPath $key)
                    if (-not $observation.Found) { $observation.Before='Absent';$observation.After='Absent';return 'ok' }
                    $changed = $false
                    $start=(Get-ItemProperty -LiteralPath $key -Name Start -ErrorAction Stop).Start
                    $service = Get-Service -Name $svc -ErrorAction Stop
                    $observation.Before="Start=$start; $($service.Status)"
                    if ($start -ne 4) {
                        Set-ItemProperty -LiteralPath $key -Name Start -Value 4 -Type DWord -Force -ErrorAction Stop
                        $changed = $true
                    }
                    if ($service.Status -ne 'Stopped') {
                        Stop-Service -Name $svc -Force -ErrorAction Stop
                        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(10))
                        $changed = $true
                    }
                    if ((Get-ItemProperty -LiteralPath $key -Name Start -ErrorAction Stop).Start -ne 4) { throw (T 'Служба не отключена' 'Service is not disabled') }
                    $observation.After="Start=4; $($service.Status)"
                    if ($changed) { 'changed' } else { 'ok' }
                }
            }
            if (@($config.Capabilities).Count) {
                $capabilities = @(Read-GuardInventory -Label (T 'Получение списка возможностей Windows' 'Reading Windows capabilities') -Category capability -Read { Get-WindowsCapability -Online -ErrorAction Stop })
                foreach ($cap in $capabilities) {
                    if (-not (Test-GuardMatch $cap.Name $config.Capabilities)) { continue }
                    Invoke-GuardCheck -Label (T "Возможность $($cap.Name)" "Capability $($cap.Name)") -Category capability -Name $cap.Name -Desired absent -Action {
                        param($observation)
                        $observation.Before=[string]$cap.State;$observation.Found=[string]$cap.State -notin @('NotPresent','Not Present')
                        if(-not $observation.Found){$observation.After=[string]$cap.State;return 'ok'}
                        if([string]$cap.State -match 'Pending'){$observation.After=[string]$cap.State;return 'pending'}
                        if($cap.State -ne 'Installed'){$observation.Detail=(T "Состояние не допускает удаление: $($cap.State)" "State cannot be removed: $($cap.State)");return 'skipped'}
                        $result = Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop
                        $state = (Get-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop).State
                        $observation.After=[string]$state
                        if ($state -eq 'NotPresent' -or $state -eq 'Not Present') { return 'changed' }
                        if ($result.RestartNeeded -or [string]$state -match 'Pending') { return 'pending' }
                        throw (T "Возможность осталась: $state" "Capability remains: $state")
                    }
                }
                Add-MissingGuardTargets -Category capability -Patterns $config.Capabilities -Inventory $capabilities -NameProperty Name
            }
            if (@($config.Apps).Count) {
                $apps = @(Read-GuardInventory -Label (T 'Получение списка приложений' 'Reading apps') -Category app -Read { Get-AppxPackage -AllUsers -ErrorAction Stop })
                foreach ($pkg in $apps) {
                    if (-not (Test-GuardMatch $pkg.Name $config.Apps)) { continue }
                    Invoke-GuardCheck -Label (T "Приложение $($pkg.PackageFullName)" "App $($pkg.PackageFullName)") -Category app -Name $pkg.Name -Desired absent -Action {
                        param($observation)
                        $observation.Found=$true;$observation.Before='Installed';$observation.Detail=$pkg.PackageFullName
                        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                        if (@(Get-AppxPackage -AllUsers -Name $pkg.Name -ErrorAction Stop | Where-Object { $_.PackageFullName -eq $pkg.PackageFullName }).Count) {$observation.After='Pending';'pending'} else {$observation.After='Absent';'changed'}
                    }
                }
                Add-MissingGuardTargets -Category app -Patterns $config.Apps -Inventory $apps -NameProperty Name
                $provisioned = @(Read-GuardInventory -Label (T 'Получение списка встроенных пакетов' 'Reading provisioned apps') -Category provisioned -Read { Get-AppxProvisionedPackage -Online -ErrorAction Stop })
                foreach ($pkg in $provisioned) {
                    if (-not (Test-GuardMatch $pkg.DisplayName $config.Apps)) { continue }
                    Invoke-GuardCheck -Label (T "Встроенный пакет $($pkg.PackageName)" "Provisioned app $($pkg.PackageName)") -Category provisioned -Name $pkg.DisplayName -Desired absent -Action {
                        param($observation)
                        $observation.Found=$true;$observation.Before='Provisioned';$observation.Detail=$pkg.PackageName
                        Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                        if (@(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.PackageName -eq $pkg.PackageName }).Count) {$observation.After='Pending';'pending'} else {$observation.After='Absent';'changed'}
                    }
                }
                Add-MissingGuardTargets -Category provisioned -Patterns $config.Apps -Inventory $provisioned -NameProperty DisplayName
            }
            $driveRoot = [IO.Path]::GetFullPath($env:SystemDrive + '\')
            foreach ($relative in @($config.Paths)) {
                $guardVisited["path|$relative"]=$true
                Write-GuardLog 'CHECK' (T "Поиск $relative" "Checking $relative")
                $pathErrors = @()
                $items = @(Get-Item -Path (Join-Path $driveRoot $relative) -Force -ErrorAction SilentlyContinue -ErrorVariable pathErrors)
                $readErrors = @($pathErrors | Where-Object { $_.CategoryInfo.Category -ne 'ObjectNotFound' })
                foreach ($readError in $readErrors) { $counts.Failed++; Write-GuardLog 'ERROR' "$relative : $($readError.Exception.Message)";Add-GuardDetail -Category path -Name $relative -Outcome failed -Found $null -Detail $readError.Exception.Message }
                if (-not $items.Count -and -not $readErrors.Count) { $counts.Checked++; Write-GuardLog 'OK' (T "$relative отсутствует" "$relative is absent");Add-GuardDetail -Category path -Name $relative -Outcome absent -Found $false -Before Absent -After Absent -Desired absent }
                foreach ($item in $items) {
                    Invoke-GuardCheck -Label (T "Файл/каталог $($item.FullName)" "File/directory $($item.FullName)") -Category path -Name $relative -Identity $item.FullName -Desired absent -Action {
                        param($observation)
                        $observation.Found=$true;$observation.Before='Present';$observation.Detail=$item.FullName
                        $observation.Step=(T 'проверка границ пути' 'path boundary validation')
                        $full = [IO.Path]::GetFullPath($item.FullName)
                        if (-not $full.StartsWith($driveRoot, [StringComparison]::OrdinalIgnoreCase) -or $full.TrimEnd('\') -eq $driveRoot.TrimEnd('\')) { throw (T 'Путь вне системного диска' 'Path is outside the system drive') }
                        $cursor = $full
                        while ($cursor) {
                            $observation.Step=(T "проверка ссылки: $cursor" "link inspection: $cursor")
                            if ((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { $observation.Detail+=(T '; ссылка файловой системы не удаляется' '; filesystem link is not removed');return 'skipped' }
                            $cursor = Split-Path $cursor -Parent
                        }
                        Grant-SystemAccess -Path $full -Recurse:$item.PSIsContainer -Observation $observation
                        $observation.Step=(T 'удаление (Remove-Item)' 'removal (Remove-Item)')
                        Remove-GuardSelectedPath -Path $full -Directory $item.PSIsContainer -Observation $observation
                        $observation.Step=(T 'проверка после удаления' 'verification after removal')
                        if (Test-Path -LiteralPath $full -ErrorAction Stop) { throw (T 'Объект остался после удаления' 'Object remains after removal') }
                        $observation.After='Absent'
                        'changed'
                    }
                }
            }
            $guardComplete=$true
        }
    } catch {
        $counts.Failed++
        Write-GuardLog 'ERROR' $_.Exception.Message
        Add-GuardDetail -Category run -Name (T 'Прерывание проверки' 'Interrupted check') -Outcome failed -Found $null -Detail $_.Exception.Message
    } finally {
        try {
            if($guardMode -eq 'Standard' -and -not $guardSkippedOobe){Invoke-GuardPresentation}
            try { Save-GuardReport } catch {$counts.LogFailed++;try{[Console]::Error.WriteLine("[LOG ERROR] Report: $($_.Exception.Message)")}catch{}}
            Write-GuardLog 'END' (T "Проверено $($counts.Checked); изменено $($counts.Changed); ожидают завершения $($counts.Pending); пропущено $($counts.Skipped); ошибок $($counts.Failed)" "Checked $($counts.Checked); changed $($counts.Changed); pending $($counts.Pending); skipped $($counts.Skipped); errors $($counts.Failed)")
        }
        finally { $runLock.Dispose() }
    }
    if ($counts.LogFailed) {
        try { [Console]::Error.WriteLine((T "[LOG ERROR] Не записано строк в guard.log: $($counts.LogFailed); строки переданы в stderr (launcher.log при штатном запуске)." "[LOG ERROR] Lines not written to guard.log: $($counts.LogFailed); forwarded to stderr (launcher.log during normal startup).")) } catch { }
    }
    if ($counts.Failed -or $counts.LogFailed -or $counts.ViewFailed) { exit 1 }
    exit 0
}
exit 0
'@
    # Canonical Windows newlines and a final line break, so a Git LF checkout
    # still writes byte-identical content into the image.
    ($text -replace '\r?\n', "`r`n") + "`r`n"
}
#endregion Guest script

#region ── Каталоги ADK: чтение установщиков Microsoft ──────────────────────────

# Файлы внутри CAB-архивов ADK названы безымянными идентификаторами вида
# filXXXXXXXX; настоящие имена, размеры и распределение по архивам описаны только
# в таблицах установщиков MSI. Поэтому состав читается при сборке, а в скрипте
# закреплено лишь то, что из MSI не выводится: адреса и контрольные суммы.
# Размеры и хэши архивов взяты из манифеста подписанного Microsoft bootstrapper;
# SHA256 самих MSI проверены при подготовке каталогов 13.09.2026.
# Двоичные файлы Microsoft здесь не распространяются.
$script:AdkSources = @{
    26100 = @{
        Kind         = 'winpe'
        Version      = '10.1.26100.2454'
        Bootstrapper = 'https://go.microsoft.com/fwlink/?linkid=2289981'
        BaseUrl      = 'https://download.microsoft.com/download/5/5/6/556e01ec-9d78-417d-b1e1-d83a2eff20bc/ADKWinPEAddons/Installers/'
        # x86 в имени относится к установщику, а не к составу: MSI несёт и amd64,
        # и arm64. Берём только amd64.
        Installers   = @(
            @{ Name = 'Windows PE Optional Packages (DesktopEditions)-x86_en-us.msi'; Size = 1015808; SHA256 = 'F286C52FDF694C85F08F6EC0BA7702DE84F891040064B81163C8DA59A5C4DB4C' }
        )
        Pattern      = '\\amd64\\WinPE_OCs\\(.+)$'
        Archives     = @(
            @{ Name = '3ffff92a2c7e8b2f1a6e85afeaa027ca.cab'; Size = 320140822; SHA1 = 'EF146291E09B6918CFA3150A37043D66DFF11440' }
            @{ Name = '9722214af0ab8aa9dffb6cfdafd937b7.cab'; Size = 334507604; SHA1 = 'E68D67F374897D07FBA3B5070134613AFC9F2454' }
        )
    }
    28000 = @{
        Kind         = 'tools'
        Version      = '10.1.28000.1'
        Bootstrapper = 'https://go.microsoft.com/fwlink/?linkid=2337875'
        BaseUrl      = 'https://download.microsoft.com/download/615540bc-be0b-433a-b91b-1f2b0642bb24/adk/Installers/'
        # Два семейства пакетов в двух вариантах каждое. Imaging Tools Support не
        # нужен: DISM и oscdimg лежат в этих четырёх.
        Installers   = @(
            @{ Name = 'Windows Deployment Image Servicing and Management Tools (DesktopEditions)-x86_en-us.msi'; Size = 589824; SHA256 = 'A500CC62066CB603B45D076AA2BB01D6A07386AF25474B6188AA4F9F28C2E304' }
            @{ Name = 'Windows Deployment Image Servicing and Management Tools (OnecoreUAP)-x86_en-us.msi'; Size = 688128; SHA256 = 'DE671157E31793A4D2C35D50F8F28D064178B9A3FDE88DEB219F96902E6AB8BC' }
            @{ Name = 'Oscdimg (DesktopEditions)-x86_en-us.msi'; Size = 581632; SHA256 = 'F0AC4CE023E21A65B44C9DDD3D3683C7A3ED08A1BCF57914FE0CCE7DEE8F440C' }
            @{ Name = 'Oscdimg (OnecoreUAP)-x86_en-us.msi'; Size = 585728; SHA256 = '4B29E6893DD87DBA03D27B7AA0B0AE62D8AED893322E68CE9B53674E63C8A628' }
        )
        Pattern      = '\\Deployment Tools\\(amd64\\(?:DISM|Oscdimg)\\.+)$'
        Archives     = @(
            @{ Name = '7e6e508fe7702607bff0b24b764e4990.cab'; Size = 22144; SHA256 = '8FA5E667C61D9018A2D8EDD495DEDFDB05DE85E15E8B3E6E4A4DBCB7B5FD38AA' }
            @{ Name = '831d004a8f355684ab94810176e8d4ec.cab'; Size = 60160; SHA256 = '727ADAEBCB02FEA15341B973C110A5F82513FEBADD59D38030923989CB3229C8' }
            @{ Name = '8624feeaa6661d6216b5f27da0e30f65.cab'; Size = 47680; SHA256 = '4D88B3710347F9FF8B0876BED0E6740FC1FC551CE108A3A1E25E87FE68B2BFC6' }
            @{ Name = 'a7eb3390a15bcd2c80a978c75f2dcc4f.cab'; Size = 2241362; SHA256 = '2AA07C8458C645B0B7C414EAF11C6568DC2D4BC48DF29B1599C80C92319A655C' }
            @{ Name = 'abbeaf25720d61b6b6339ada72bdd038.cab'; Size = 150430; SHA256 = '9084EE165708AB99ED02796138643B81E143C985CBEB7D65CB9D38280775A175' }
            @{ Name = 'bbf55224a0290f00676ddc410f004498.cab'; Size = 77768; SHA256 = '13AD65CCC488CEBD8E5EF969A68C44DD0E2C64255460D26F1D560763F474DBCE' }
            @{ Name = 'bf7b6300431984daf850cc213043c7eb.cab'; Size = 2196206; SHA256 = 'E9CE2E5495FB51786E996CFC3F7361F8E51D7D366B18BCBD6BB9B46C57FA2538' }
            @{ Name = 'd2611745022d67cf9a7703eb131ca487.cab'; Size = 1096362; SHA256 = 'DFE132B8B0E077F2FE69243F0197F62C4FAF0E3E2CC50AF49326E2C208D805A0' }
            @{ Name = 'fdfb8cfc2e4d170431fb6b8c67210672.cab'; Size = 749820; SHA256 = '1D663E3059FB7B583ABE7F18A6E82BAED3C3EF094B761913DAC16B7DC440B037' }
        )
    }
}

# Идентичность источника для кэша: меняется вместе с любым закреплённым
# значением, поэтому подготовленный комплект не переиспользуется после
# обновления ADK. Сети не требует.
function Get-AdkSourceHash {
    param([Parameter(Mandatory)][int]$Build)
    $source = $script:AdkSources[$Build]
    if (-not $source) { throw (T "Нет описания ADK для билда $Build" "No ADK description for build $Build") }
    $lines = @($source.Version, $source.BaseUrl, $source.Pattern) +
        @($source.Installers | ForEach-Object { '{0}|{1}|{2}' -f $_.Name, $_.Size, $_.SHA256 }) +
        @($source.Archives | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.Name, $_.Size, $_.SHA256, $_.SHA1 })
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))).Replace('-','') }
    finally { $sha.Dispose() }
}

# Целостность гарантируют закреплённые SHA256 и размеры из таблиц MSI. Подпись —
# дополнительный признак: отсутствие нужного корневого сертификата на хосте не
# должно останавливать корректную сборку, поэтому это предупреждение.
function Confirm-MicrosoftSignature {
    param([Parameter(Mandatory)][string]$Path)
    $name = Split-Path $Path -Leaf
    try { $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop }
    catch {
        Write-Note (T "Не удалось проверить подпись ${name}: $($_.Exception.Message)" "Could not check the signature of ${name}: $($_.Exception.Message)")
        return $false
    }
    if ([string]$signature.Status -ne 'Valid' -or [string]$signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        Write-Note (T "Подпись Microsoft не подтверждена: $name ($($signature.Status))" "Microsoft signature not confirmed: $name ($($signature.Status))")
        return $false
    }
    $true
}

function Read-MsiTable {
    param([Parameter(Mandatory)]$Database, [Parameter(Mandatory)][string]$Table, [Parameter(Mandatory)][string[]]$Columns)
    $view = $Database.OpenView('SELECT `' + ($Columns -join '`,`') + '` FROM `' + $Table + '`')
    try {
        $null = $view.Execute()
        while ($record = $view.Fetch()) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $Columns.Count; $i++) { $row[$Columns[$i]] = [string]$record.StringData($i + 1) }
            [pscustomobject]$row
        }
    } finally { $null = $view.Close() }
}

# Путь собирается подъёмом по Directory_Parent. В DefaultDir целевое имя стоит до
# ':', длинное имя — после '|'; '.' означает тот же каталог, что у родителя.
function Get-MsiDirectoryPath {
    param([Parameter(Mandatory)][hashtable]$Directories, [string]$Id)
    $parts = [Collections.Generic.List[string]]::new()
    $seen = @{}
    $cursor = $Id
    while ($cursor) {
        if ($seen.ContainsKey($cursor)) { throw (T "Циклическая ссылка каталогов MSI: $cursor" "MSI directory cycle: $cursor") }
        $seen[$cursor] = $true
        $entry = $Directories[$cursor]
        if (-not $entry) { throw (T "В MSI нет каталога $cursor" "The MSI has no directory $cursor") }
        $leaf = (([string]$entry.DefaultDir -split ':')[0] -split '\|')[-1]
        if ($leaf -and $leaf -ne '.') { $parts.Insert(0, $leaf) }
        $cursor = [string]$entry.Directory_Parent
    }
    '\' + ($parts -join '\')
}

# Только чтение таблиц: установщик не запускается и ничего не устанавливает.
function Get-MsiFileMap {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Pattern)
    try { $installer = New-Object -ComObject WindowsInstaller.Installer }
    catch { throw (T "Недоступен Windows Installer для чтения состава ADK: $($_.Exception.Message)" "Windows Installer is unavailable for reading the ADK contents: $($_.Exception.Message)") }
    try {
        $database = $installer.OpenDatabase($Path, 0)
        try {
            $files = @(Read-MsiTable -Database $database -Table 'File' -Columns @('File','Component_','FileName','FileSize','Sequence'))
            $media = @(Read-MsiTable -Database $database -Table 'Media' -Columns @('DiskId','LastSequence','Cabinet'))
            $components = @{}
            foreach ($row in Read-MsiTable -Database $database -Table 'Component' -Columns @('Component','Directory_')) { $components[$row.Component] = $row.Directory_ }
            $directories = @{}
            foreach ($row in Read-MsiTable -Database $database -Table 'Directory' -Columns @('Directory','Directory_Parent','DefaultDir')) { $directories[$row.Directory] = $row }
        } finally { if ([Runtime.InteropServices.Marshal]::IsComObject($database)) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) } }
    } finally { if ([Runtime.InteropServices.Marshal]::IsComObject($installer)) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) } }
    if (-not $files.Count -or -not $media.Count) { throw (T "В установщике нет таблиц состава: $(Split-Path $Path -Leaf)" "The installer has no content tables: $(Split-Path $Path -Leaf)") }
    $ordered = @($media | Sort-Object { [int]$_.LastSequence })
    foreach ($file in $files) {
        $directory = $components[$file.Component_]
        if (-not $directory) { throw (T "Файл MSI без каталога: $($file.File)" "MSI file without a directory: $($file.File)") }
        $full = (Get-MsiDirectoryPath -Directories $directories -Id $directory) + '\' + (([string]$file.FileName -split '\|')[-1])
        if ($full -notmatch $Pattern) { continue }
        $relative = $matches[1]
        $medium = $ordered | Where-Object { [int]$_.LastSequence -ge [int]$file.Sequence } | Select-Object -First 1
        # Имя с '#' означает CAB внутри самого MSI; у пакетов ADK такого не бывает.
        if (-not $medium -or -not $medium.Cabinet -or $medium.Cabinet.StartsWith('#')) { throw (T "Неизвестный архив для $relative" "Unknown archive for $relative") }
        [pscustomobject]@{ Archive = [string]$medium.Cabinet; Member = [string]$file.File; Path = $relative; Size = [int64]$file.FileSize }
    }
}

function Save-AdkInstallers {
    param([Parameter(Mandatory)][int]$Build, [Parameter(Mandatory)][string]$Directory)
    $source = $script:AdkSources[$Build]
    $dir = Join-Path $Directory "adk-$Build-installers"
    $null = New-Item -ItemType Directory -Path $dir -Force
    @(foreach ($installer in $source.Installers) {
        if ([IO.Path]::GetFileName($installer.Name) -ne $installer.Name) { throw (T 'Неверное имя установщика ADK' 'Invalid ADK installer name') }
        $path = Assert-ChildPath -Path (Join-Path $dir $installer.Name) -Root $dir
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Length -ne $installer.Size -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $installer.SHA256)) {
            Remove-Item -LiteralPath $path,"$path.size","$path.sha256" -Force -ErrorAction SilentlyContinue
        }
        Save-Url -Url ($source.BaseUrl + $installer.Name.Replace(' ','%20')) -Destination $path
        if ((Get-Item -LiteralPath $path).Length -ne $installer.Size -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $installer.SHA256) {
            Remove-Item -LiteralPath $path,"$path.size","$path.sha256" -Force -ErrorAction SilentlyContinue
            throw (T "Установщик ADK не совпал с ожидаемым: $($installer.Name). Возможно, Microsoft обновил комплект; задайте -SetupLanguageSource или -DismPath." "The ADK installer does not match the expected copy: $($installer.Name). Microsoft may have refreshed the kit; supply -SetupLanguageSource or -DismPath.")
        }
        $null = Confirm-MicrosoftSignature -Path $path
        $path
    })
}

# Возвращает описание состава в том же виде, в каком его раньше давал встроенный
# JSON: закреплённые архивы плюс прочитанные из MSI файлы.
function Get-AdkCatalog {
    param([Parameter(Mandatory)][int]$Build, [Parameter(Mandatory)][string]$Directory)
    if (-not $script:AdkCatalogs) { $script:AdkCatalogs = @{} }
    if ($script:AdkCatalogs.ContainsKey($Build)) { return $script:AdkCatalogs[$Build] }
    $source = $script:AdkSources[$Build]
    if (-not $source) { throw (T "Нет описания ADK для билда $Build" "No ADK description for build $Build") }
    $installers = Save-AdkInstallers -Build $Build -Directory $Directory
    Write-Step (T "Читаю состав ADK $($source.Version) из установщиков Microsoft" "Reading the ADK $($source.Version) contents from the Microsoft installers")
    $files = @(foreach ($installer in $installers) { Get-MsiFileMap -Path $installer -Pattern $source.Pattern })
    if ($source.Kind -eq 'winpe') {
        # Каталог WinPE адресуется языковыми подкаталогами через '/'. Берём языки
        # вида xx-xx и шрифтовые наборы; прочие компоненты WinPE не нужны.
        $files = @($files | ForEach-Object { $_.Path = $_.Path -replace '\\','/'; $_ } |
            Where-Object { $_.Path -match '^[a-z]{2}-[a-z]{2}/[^/]+$' -or $_.Path -match '^WinPE-FontSupport-[A-Za-z-]+\.cab$' })
    }
    if (-not $files.Count) { throw (T "В установщиках ADK $Build нет ожидаемых файлов" "The ADK $Build installers have none of the expected files") }
    foreach ($file in $files) {
        if ($file.Path -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($file.Path)) { throw (T "Недопустимый путь в MSI: $($file.Path)" "Invalid path in the MSI: $($file.Path)") }
        if ($file.Member -notmatch '^fil[a-f0-9]{32}$') { throw (T "Недопустимое имя файла в MSI: $($file.Member)" "Invalid member name in the MSI: $($file.Member)") }
    }
    $pinned = @($source.Archives | ForEach-Object { $_.Name })
    foreach ($name in @($files.Archive | Sort-Object -Unique)) {
        if ($name -notin $pinned) { throw (T "MSI ссылается на незакреплённый архив: $name" "The MSI refers to an unpinned archive: $name") }
    }
    $archives = @(foreach ($archive in $source.Archives) {
        [pscustomobject]@{
            Name   = $archive.Name
            Url    = $source.BaseUrl + $archive.Name
            Size   = $archive.Size
            SHA256 = $archive.SHA256
            SHA1   = $archive.SHA1
            Files  = @($files | Where-Object { $_.Archive -eq $archive.Name } | Select-Object Member, Path, Size)
        }
    })
    $catalog = [pscustomobject]@{
        Build = $Build; Architecture = 'amd64'; Version = $source.Version
        BaseUrl = $source.BaseUrl; Archives = $archives; Files = $files
    }
    Write-Ok (T "ADK $($source.Version): описано файлов $($files.Count) в архивах $(@($archives | Where-Object { $_.Files.Count }).Count)" "ADK $($source.Version): $($files.Count) files described across $(@($archives | Where-Object { $_.Files.Count }).Count) archives")
    $script:AdkCatalogs[$Build] = $catalog
    $catalog
}

#endregion

function Get-NativeToolVersion {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [version]'0.0' }
    $info = (Get-Item -LiteralPath $Path).VersionInfo
    [version]('{0}.{1}.{2}.{3}' -f $info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart,$info.FilePrivatePart)
}

function Save-DeploymentTools {
    param([string]$Directory, [int]$Build = 28000)
    $sourceHash = Get-AdkSourceHash -Build $Build
    $dir = Join-Path $Directory "deployment-tools-$Build"
    $cached = Read-PreparedCache -Directory $dir -Key 'tools'
    if (-not $cached -or $cached.Data.SourceSHA256 -ne $sourceHash) {
        $catalog = Get-AdkCatalog -Build $Build -Directory $Directory
        if ($catalog.Build -ne $Build -or $catalog.Architecture -ne 'amd64' -or -not @($catalog.Files).Count) { throw (T 'Некорректный каталог инструментов DISM' 'Invalid DISM tool catalog') }
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
                $source = Assert-ChildPath -Path (Join-Path $expanded $entry.Member) -Root $expanded
                $target = Assert-ChildPath -Path (Join-Path $dir $entry.Path) -Root $dir
                # Содержимое подтверждено закреплённым SHA256 архива; размер из
                # таблицы MSI подтверждает, что распакован нужный файл целиком.
                if ((Get-Item -LiteralPath $source).Length -ne $entry.Size) { throw (T "Повреждён файл инструмента: $($entry.Path)" "Tool file integrity failure: $($entry.Path)") }
                $null = New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
                Copy-Item -LiteralPath $source -Destination $target -Force
                $files += $target
            }
        }
        Write-PreparedCache -Directory $dir -Key 'tools' -Files $files -Data @{ SourceSHA256=$sourceHash }
    }
    $dism = Join-Path $dir 'amd64\DISM\dism.exe'
    $oscdimg = Join-Path $dir 'amd64\Oscdimg\oscdimg.exe'
    if ((Get-NativeToolVersion $dism).Build -lt $Build -or -not (Test-Path -LiteralPath $oscdimg)) { throw (T 'Неполный комплект инструментов обслуживания' 'Incomplete servicing tool set') }
    foreach ($tool in @($dism, $oscdimg)) { $null = Confirm-MicrosoftSignature -Path $tool }
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
            Write-Note (T 'Для 26H1 будет подготовлен отдельный DISM 28000 из ADK: 4 установщика (~2.3 МиБ) и 9 архивов (~6.3 МиБ); установленный ADK сохраняется.' '26H1 will use a separate DISM 28000 from the ADK: 4 installers (about 2.3 MiB) and 9 archives (about 6.3 MiB); the installed ADK is retained.')
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
    $WorkDir = Read-PathOrDefault -Question (T 'Рабочая папка для сборки (30 ГБ, с обновлениями 45 ГБ)' 'Work folder for the build (30 GB, 45 GB with updates)') -Default $defaultWork
    $script:WorkDirExplicit = $true

    # 4. Глубина чистки
    $Preset = Read-Option -Question (T 'Насколько глубоко чистить' 'How aggressively should I clean') -Default 2 `
        -Items @(
            (T 'safe      — только Edge, телеметрия и реклама' 'safe      - Edge, telemetry and ads only'),
            (T 'balanced  — плюс Defender, речь, Media Player, Xbox/Game Bar, AI-компоненты' 'balanced  - plus Defender, speech, Media Player, Xbox/Game Bar, AI components'),
            (T 'max       — плюс WebView2, резервы компонентов и дополнительные FoD; возможна потеря совместимости' 'max       - plus WebView2, component backups and extra FoDs; compatibility may be lost')
        ) -Values @('safe', 'balanced', 'max')

    # 5. Сторож — идёт сразу за глубиной чистки: он существует ровно для того,
    # чтобы вырезанное не вернулось, и без него чистка постепенно откатывается
    Write-Host ''
    Write-Host (T '  Windows Update со временем возвращает часть удалённого — Edge, Defender,' '  Windows Update eventually restores some of what was removed - Edge, Defender,') -ForegroundColor DarkGray
    Write-Host (T '  AI-компоненты — и сбрасывает политики обратно. Сторож встраивается в образ' '  AI components - and resets the policies. The guard is embedded into the image') -ForegroundColor DarkGray
    Write-Host (T '  и при каждом входе в систему тихо удаляет их снова и возвращает настройки.' '  and at every logon quietly removes them again and restores the settings.') -ForegroundColor DarkGray
    $guardDefault=if($PSBoundParameters.ContainsKey('Guard')){[array]::IndexOf(@('none','standard','debug','silent'),$Guard.ToLowerInvariant())+1}else{2}
    $Guard=Read-Option -Question (T 'Режим работы guard' 'Guard mode') -Items @(
        (T 'None — не встраивать guard' 'None - do not embed guard'),
        (T 'Standard — только итоговый отчёт и ошибки' 'Standard - summary and errors only'),
        (T 'Debug — полный живой журнал' 'Debug - full live log'),
        (T 'Silent — без окна, отчёты в папке guard' 'Silent - no window, reports in the guard folder')
    ) -Values @('None','Standard','Debug','Silent') -Default $guardDefault

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
    Write-Host (T '  Проверяю наличие winget в выбранной редакции...' '  Checking for winget in the selected edition...') -ForegroundColor DarkGray
    $sourceWinget = if ($Index -gt 0) { Get-IsoWingetState -Path $InputIso -Index $Index -Dism $DismPath } else { [pscustomobject]@{State='Unknown';Reason=(T 'Не выбран индекс образа' 'No image index selected')} }
    $WithWinget = Read-WingetOption -SourceState $sourceWinget

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
    if ($Keep.Count) { $cmd += " -Keep $($Keep -join ',')" }
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
    $cmd += " -Guard $Guard"
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
# --- выбор рабочего каталога ---
# Пиковое потребление: распакованный ISO + растущий install.wim + scratch.
# С интеграцией обновлений добавляются ещё и сами .msu.
$requiredGB = if ($UpdateMode -eq 'none') { 30 } else { 45 }

function Get-FreeGB {
    param([string]$Path)
    $qualifier = Split-Path $Path -Qualifier
    if (-not $qualifier) { return $null }   # UNC-путь — измерить не можем
    $drive = Get-PSDrive -Name $qualifier.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($drive -and $null -ne $drive.Free) { $drive.Free / 1GB } else { $null }
}

$workFreeGB = Get-FreeGB $WorkDir
if ($null -ne $workFreeGB -and $workFreeGB -lt $requiredGB -and -not $script:WorkDirExplicit) {
    # Пользователь путь не задавал, а в системной temp тесно — берём локальный
    # диск с наибольшим свободным местом
    $best = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
            Sort-Object FreeSpace -Descending | Select-Object -First 1
    if ($best -and ($best.FreeSpace / 1GB) -ge $requiredGB) {
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

function Resolve-WorkDirectory {
    param([string]$Path, [int]$RequiredGB, [switch]$Preview)

    while ($true) {
        try {
            if ([string]::IsNullOrWhiteSpace($Path)) { throw (T 'Путь не может быть пустым.' 'The path cannot be empty.') }
            $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path.Trim().Trim('"'))
            $full = [IO.Path]::GetFullPath($full).TrimEnd('\', '/')
            if ($full -match '^[A-Za-z]:$') { $full += '\' }
            if ((Split-Path $full -Leaf) -ne $script:WorkDirLeaf) {
                $full = Join-Path $full $script:WorkDirLeaf
            }
            if (-not (Test-SafeToWipe $full)) { throw (T "Небезопасный рабочий каталог: $full" "Unsafe work directory: $full") }
            $cursor = $full
            while ($cursor) {
                if (Test-Path -LiteralPath $cursor -PathType Leaf) { throw (T "Вместо папки указан файл: $cursor" "A file was specified instead of a directory: $cursor") }
                $cursor = Split-Path $cursor -Parent
            }
            $free = Get-FreeGB $full
            if ($null -ne $free -and $free -ge $RequiredGB) {
                $displayFree = [math]::Round($free, 1)
                Write-Ok (T "Для $full свободно $displayFree ГБ (нужно не менее $RequiredGB ГБ)" "$displayFree GB free for $full (at least $RequiredGB GB required)")
                return $full
            }
            $problem = if ($null -eq $free) {
                T "Не удалось определить свободное место для $full — нужно не менее $RequiredGB ГБ." "Could not determine free space for $full - at least $RequiredGB GB required."
            } else {
                # Не показывать «45 ГБ, нужно 45 ГБ» при фактических 44.99 ГБ.
                $displayFree = [math]::Floor($free * 10) / 10
                T "Для $full свободно $displayFree ГБ, нужно не менее $RequiredGB ГБ." "Only $displayFree GB free for $full, at least $RequiredGB GB required."
            }
            if ($Preview) { Write-Note $problem; return $full }
        } catch {
            if ($Preview) { throw }
            $problem = $_.Exception.Message
        }
        if (-not (Test-CanPrompt)) {
            throw (T "$problem Сборка остановлена. Укажите другой путь через -WorkDir." "$problem Build stopped. Specify another path with -WorkDir.")
        }
        Write-Note $problem
        $Path = Read-Host (T '  Введите другой рабочий каталог (сборка ждёт подходящий путь)' '  Enter another work directory (build waits for a suitable path)')
    }
}

# Сначала принимаем подходящий путь, затем вычисляем кэш и все рабочие файлы.
$WorkDir = Resolve-WorkDirectory -Path $WorkDir -RequiredGB $requiredGB -Preview:$DryRun
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

if (-not $DryRun) {
    $null = New-Item -ItemType Directory -Path (Split-Path $OutputIso -Parent) -Force
    $script:ImageAuditPath = [IO.Path]::ChangeExtension($OutputIso, '.image-audit.json')
}

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
    # Обязательный гостевой сценарий готовится до любых изменений образа.
    $guestScript = Get-GuestScript
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
$vGuard = switch($Guard){
    'None'{T 'None — нет' 'None - disabled'}
    'Standard'{T 'Standard — краткий итог' 'Standard - concise summary'}
    'Debug'{T 'Debug — живой полный журнал' 'Debug - live full log'}
    'Silent'{T 'Silent — без окна' 'Silent - no window'}
}
Write-Host (T "  winget         : $vWinget" "  winget         : $vWinget")
if ($Preset -ne 'max') { Write-Host (T '  Store / MSIX   : сохранить имеющиеся Store, App Installer и зависимости' '  Store / MSIX   : preserve existing Store, App Installer and dependencies') }
Write-Host (T "  Сторож         : $vGuard" "  Guard          : $vGuard")
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
    # Тот же набор ключей, что гостевой сценарий чистит после OOBE
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
Write-Ok (T "Язык для загрузки Firefox: $mozLang" "Firefox download language: $mozLang")
# --- сторож: возвращает систему в нужное состояние после обновлений ---
# Накопительные обновления умеют восстанавливать Defender, Edge и AI-компоненты
# и сбрасывать политики. Скрипт запускается при каждом входе и правит это.
$guardDir = Join-Path $mountDir 'Windows\Setup\Scripts\Win11Lite'
$useVbsLauncher = Test-ImageVbsLauncher -Image $mountDir
if ($useVbsLauncher) {
    Write-Ok (T 'Запуск при установке: VBS без окна PowerShell' 'Setup launcher: VBS with hidden PowerShell')
} else {
    Write-Note (T 'Запуск при установке: PowerShell; в образе отсутствует Windows Script Host или VBScript, начальная консоль может появиться' 'Setup launcher: PowerShell; the image has no Windows Script Host or VBScript, so the initial console may appear')
}
if ($Guard -ne 'None') {
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
        Mode = $Guard
        ViewerTask = $Guard -ne 'Silent'
        # The language lives in build-info.json only: one source for the guest.
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

    Write-Ok (T "Сторож встроен: проверяет систему при каждом входе ($(($guardFolders + $guardServices + $guardAppx + $guardCaps).Count) объектов, $($guardPolicies.Count) политик)" "Guard embedded: checks the system at every logon ($(($guardFolders + $guardServices + $guardAppx + $guardCaps).Count) objects, $($guardPolicies.Count) policies)")
}

# Подготовка в specialize отключает сеть; FirstLogonCommands завершает установку.
# Задача служит повторным запуском при ошибке и поддерживает свой answer-файл.
# SetupComplete — дополнительная регистрация для установок со своим answer-файлом.
# Он не включает сеть: этот этап может предшествовать OOBE.
$scriptsDir = Join-Path $mountDir 'Windows\Setup\Scripts'
$supportDir = Join-Path $scriptsDir 'Win11Lite'
$null = New-Item -ItemType Directory -Path $supportDir -Force
# One guest file serves every entry point; build-info.json carries the choices.
[IO.File]::WriteAllText((Join-Path $supportDir 'Win11Lite.ps1'), $guestScript, [Text.UTF8Encoding]::new($true))
if ($useVbsLauncher) {
    [IO.File]::WriteAllText((Join-Path $supportDir 'Run-Setup.vbs'), (Get-SetupVbsScript), [Text.Encoding]::ASCII)
} elseif (Test-Path -LiteralPath (Join-Path $supportDir 'Run-Setup.vbs')) {
    Remove-Item -LiteralPath (Join-Path $supportDir 'Run-Setup.vbs') -Force
}
$prepareCommand = Get-SetupEntryCommand -Mode prepare -UseVbs $useVbsLauncher
$registerCommand = Get-SetupEntryCommand -Mode prepare-register -UseVbs $useVbsLauncher
$finalizeCommand = Get-SetupEntryCommand -Mode finalize -UseVbs $useVbsLauncher
$buildInfo = [ordered]@{
    BuildId = $script:StartedAt.ToString('yyyyMMdd-HHmmss')
    StartedAt = $script:StartedAt.ToString('o')
    SourceIso = $InputIso
    OutputIso = $OutputIso
    Preset = $Preset
    Keep = @($Keep)
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
    Guard = $Guard
    OobeNetworkBlock = [bool]($script:ManageOobe -and -not $NoOobeNetworkBlock)
    ManageOobe = [bool]$script:ManageOobe
    RemoveEdge = [bool](Test-GroupActive -RulePreset 'safe' -Group 'Edge')
    OobeCompletionCheck = 'OOBEComplete'
    SetupScriptLauncher = $(if ($useVbsLauncher) { 'VBScript / Run-Setup.vbs -> Win11Lite.ps1' } else { 'PowerShell / Win11Lite.ps1' })
    ServicingDismVersion = [string](Get-NativeToolVersion $script:Dism)
    AccountMode = $AccountMode
} | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $supportDir 'build-info.json'), $buildInfo, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $isoDir 'win11-lite-build.json'), $buildInfo, [Text.UTF8Encoding]::new($false))
Write-Ok (T "ID сборки: $($script:StartedAt.ToString('yyyyMMdd-HHmmss')) — записан в ISO и установленную Windows" "Build ID: $($script:StartedAt.ToString('yyyyMMdd-HHmmss')) - recorded in the ISO and installed Windows")
$setupComplete = @"
@echo off
$registerCommand >> "%SystemRoot%\Setup\Scripts\Win11Lite\setupcomplete.log" 2>&1
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
if ($useVbsLauncher -and -not (Test-ImageVbsLauncher -Image $mountDir)) {
    throw (T 'Средства VBScript исчезли после обслуживания образа; запуск установки не будет работать' 'VBScript host or engine disappeared after servicing; the setup launcher would not work')
}

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
                    <Path>$prepareCommand</Path>
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
                    <CommandLine>$finalizeCommand</CommandLine>
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
