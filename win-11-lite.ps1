<#
.SYNOPSIS
    Собирает облегчённый (lite) ISO из оригинального образа Windows 11.

.DESCRIPTION
    Универсальный сборщик: работает с любым оригинальным ISO Windows 11 — редакция,
    язык и версия определяются из самого образа.

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

    Только по явным ключам: обновления (-WithUpdates), winget (-WithWinget),
    языки (-DownloadLanguage), классический установщик (-LegacySetup),
    удаление WinRE (-RemoveWinRE), урезание sources (-TrimSources).

    Запуск без параметров открывает диалог с вопросами и сам запрашивает права
    администратора. Подробности — в .ai\04-plan-raboty.md

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

    # Оставить в sources только boot.wim, install.* и EI.CFG (~-210 МБ).
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

    # Временно включено для проверки guard: видимое окно живого журнала при входе.
    # Отключить для следующего ISO: -GuardDebug:$false (сам guard продолжит работу).
    [switch]$GuardDebug = $true,

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

    # Файл лога. Если не задан, лог пишется только при -Debug — в подпапку log
    # рядом со скриптом, с именем <имя исходного ISO>_<дата-время>.log
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

# -Debug — стандартный параметр PowerShell. Включает запись полного лога работы
# в папку скрипта и подробный вывод (в том числе команд DISM).
$script:DebugMode = $PSBoundParameters.ContainsKey('Debug')
if ($script:DebugMode) {
    $DebugPreference = 'Continue'      # иначе PowerShell спрашивает подтверждение
    $VerbosePreference = 'Continue'
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

# Читает список изданий из ISO, чтобы спросить о редакции до начала работы
function Get-IsoEditions {
    param([string]$Path)
    $result = @()
    $mounted = $null
    try {
        $mounted = Mount-DiskImage -ImagePath $Path -PassThru -Access ReadOnly -ErrorAction Stop
        Start-Sleep -Seconds 2
        $drive = "$(($mounted | Get-Volume).DriveLetter):"
        $wim = Join-Path $drive 'sources\install.wim'
        if (-not (Test-Path -LiteralPath $wim)) { $wim = Join-Path $drive 'sources\install.esd' }
        if (-not (Test-Path -LiteralPath $wim)) { return @() }
        Import-Module Dism -ErrorAction Stop -Verbose:$false
        foreach ($b in (Get-WindowsImage -ImagePath $wim)) {
            $d = Get-WindowsImage -ImagePath $wim -Index $b.ImageIndex
            $result += [PSCustomObject]@{
                Index     = $d.ImageIndex
                Name      = $d.ImageName
                EditionId = $d.EditionId
                Languages = ($d.Languages -join ',')
            }
        }
    } catch {
        Write-Host (T "  Не удалось прочитать образ: $($_.Exception.Message)" "  Could not read the image: $($_.Exception.Message)") -ForegroundColor Yellow
    } finally {
        if ($mounted) { try { Dismount-DiskImage -ImagePath $Path | Out-Null } catch { } }
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

function Get-ProgressLine {
    param([string]$Activity, [int]$Percent, [int]$Phase = 1, [TimeSpan]$Elapsed,
          [int]$Width = 80, [switch]$Done, [switch]$Failed)
    $limit = [Math]::Max(1, $Width - 1) # Последний столбец вызывает перенос строки.
    $percent = [Math]::Max(0, [Math]::Min(100, $Percent))
    $status = if ($Done) { if ($Failed) { T 'ОШИБКА' 'FAILED' } else { T 'Готово' 'Done' } }
              else { (T 'Этап DISM' 'DISM phase') + " $Phase" }
    $time = '{0:00}:{1:00}' -f [Math]::Floor($Elapsed.TotalMinutes), $Elapsed.Seconds
    $prefix = "  $status | $percent% | $time | "
    $activityText = ($Activity -replace '[\r\n\t]', ' ')
    # Идентификатор KB полезнее длинного имени MSU с хэшем.
    $activityText = [regex]::Replace($activityText, '(?i)windows[^\s]*?-(kb\d+)[^\s]*\.msu', { param($m) $m.Groups[1].Value.ToUpperInvariant() })
    $barWidth = [Math]::Min(20, $limit - $prefix.Length - $activityText.Length - 3)
    $bar = ''
    if ($barWidth -ge 6) {
        $filled = [int][Math]::Round($barWidth * $percent / 100)
        $bar = '[' + ('#' * $filled) + ('-' * ($barWidth - $filled)) + '] '
    }
    $line = $prefix + $bar + $activityText
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
    [Console]::Write("`r" + $line.PadRight($width - 1))
    if ($Done) { [Console]::WriteLine() }
}

function Update-DismProgressState {
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
function Invoke-Dism {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFail,
        [switch]$Quiet,
        [string]$Activity          # задан — показываем полосу вместо вывода DISM
    )
    $all = @('/English') + $Arguments
    # В режиме -Debug просим DISM вести собственный подробный лог рядом с нашим
    if ($script:DebugMode -and $script:DismLogPath) {
        $all += @("/LogPath:$script:DismLogPath", '/LogLevel:4')
    }
    Write-Verbose "dism $($all -join ' ')"

    if ($Activity -and $script:CanDrawProgress) {
        $output = Invoke-DismProgress -Exe $script:Dism -Arguments $all -Activity $Activity
        $code = $script:LastDismExit
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

# DISM перерисовывает свою полосу возвратом каретки, поэтому читаем поток
# посимвольно: ждать перевода строки бессмысленно, его может не быть минутами
function Invoke-DismProgress {
    param([string]$Exe, [string[]]$Arguments, [string]$Activity)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding(437)

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $script:ProgressStarted = Get-Date
    $lines = [System.Collections.Generic.List[string]]::new()
    $buffer = New-Object System.Text.StringBuilder
    $state = @{ Percent = -1; Phase = 1; Lines = $lines }
    try {
        $null = $proc.Start()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        Write-ProgressBar -Activity $Activity -Percent 0
        $reader = $proc.StandardOutput
        $chars = New-Object char[] 2048
        $readTask = $reader.ReadAsync($chars, 0, $chars.Length)
        $lastDraw = [DateTime]::MinValue
        while ($true) {
            if ($readTask.IsCompleted) {
                $count = $readTask.GetAwaiter().GetResult()
                if ($count -eq 0) { break }
                for ($i = 0; $i -lt $count; $i++) {
                    $c = $chars[$i]
                    if ($c -eq "`r" -or $c -eq "`n" -or $c -eq [char]8) {
                        Update-DismProgressState -State $state -Text $buffer.ToString()
                        $null = $buffer.Clear()
                    } else { $null = $buffer.Append($c) }
                }
                $readTask = $reader.ReadAsync($chars, 0, $chars.Length)
            }
            if (((Get-Date) - $lastDraw).TotalMilliseconds -ge 500) {
                Write-ProgressBar -Activity $Activity -Percent ([Math]::Max(0, $state.Percent)) -Phase $state.Phase
                $lastDraw = Get-Date
            }
            if (-not $readTask.IsCompleted) { Start-Sleep -Milliseconds 100 }
        }
        Update-DismProgressState -State $state -Text $buffer.ToString()
        $errText = $stderrTask.GetAwaiter().GetResult()
        $proc.WaitForExit()
        $script:LastDismExit = $proc.ExitCode
        if ($errText.Trim()) { $lines.Add($errText.Trim()) }
        $failed = -not (Test-DismSuccess $proc.ExitCode)
        Write-ProgressBar -Activity $Activity -Percent $(if ($failed) { [Math]::Max(0, $state.Percent) } else { 100 }) -Phase $state.Phase -Done -Failed:$failed
        Write-Verbose (T "DISM завершился: этапов $($state.Phase), код $($proc.ExitCode), операция: $Activity" "DISM finished: $($state.Phase) phases, code $($proc.ExitCode), operation: $Activity")
    } finally { $proc.Dispose() }
    $lines.ToArray()
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

function Test-Protected {
    param([string]$Name)
    foreach ($rule in ($script:CapabilityRules + $script:PackageRules)) {
        if ($Keep -contains $rule.Group -and $Name -match $rule.Pattern) { return $true }
    }
    foreach ($p in $script:NeverRemove) {
        if ($Name -match $p) { return $true }
    }
    $false
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
        $result = Invoke-Dism -Arguments @("/Image:$Image", '/Cleanup-Image', '/AnalyzeComponentStore') -AllowFail -Quiet
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
        $result = Invoke-Dism -Arguments @("/Image:$Image", '/Disable-Feature', '/FeatureName:Recall', '/Remove') -AllowFail -Quiet
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

function Assert-ImageFileState {
    param([string]$Image)
    foreach ($root in $script:PreservedWebView) {
        # LCU может заменить каталог версии WebView2. Проверяем наличие runtime,
        # а не прежний номер версии, записанный до интеграции обновлений.
        $runtime = @(Get-ChildItem -LiteralPath $root -Recurse -Filter 'msedgewebview2.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if (-not $runtime.Count) { throw (T "Удалён защищённый компонент WebView2: $root" "A protected WebView2 component was removed: $root") }
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

    # S-1-5-32-544 = Administrators, не зависит от языка системы.
    # Ключи /R и /T применимы только к каталогам — для файла они игнорируются
    # и владение не меняется, из-за чего удаление падает с «Access denied».
    $isLeafReparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if ($isLeafReparse -and $item.PSIsContainer) {
        # Remove-Item -Recurse для junction/symlink каталога может затронуть цель.
        # Таких объектов скрипт не удаляет автоматически.
        Write-Note (T "$Description — ссылка-каталог пропущена" "$Description - directory reparse point skipped")
        return $false
    }
    if ($item.PSIsContainer) {
        & takeown.exe /F $FullPath /R /A /D Y *>&1 | Out-Null
        & icacls.exe $FullPath /grant '*S-1-5-32-544:(F)' /T /C /Q *>&1 | Out-Null
    } else {
        & takeown.exe /F $FullPath /A *>&1 | Out-Null
        & icacls.exe $FullPath /grant '*S-1-5-32-544:(F)' /C /Q *>&1 | Out-Null
    }
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
    $payload = '[{"size":0,"languages":"","uidInfo":"' + $UpdateId + '","updateID":"' + $UpdateId + '"}]'
    $resp = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' `
                              -Method Post -Body @{ updateIDs = $payload } -UseBasicParsing -TimeoutSec 60
    [regex]::Matches($resp.Content, "(?<=downloadInformation\[\d+\]\.files\[\d+\]\.url = ')[^']+") |
        ForEach-Object { $_.Value }
}

function Save-Url {
    param([string]$Url, [string]$Destination)
    $name = Split-Path $Destination -Leaf
    $marker = "$Destination.size"
    if ((Test-Path -LiteralPath $Destination) -and (Test-Path -LiteralPath $marker)) {
        $expected = [int64](Get-Content -LiteralPath $marker -Raw).Trim()
        $actual = (Get-Item -LiteralPath $Destination).Length
        if ($expected -eq $actual -and $actual -gt 0) {
            Write-Ok (T "$name — уже в кэше ($(Format-Size $actual))" "$name - already cached ($(Format-Size $actual))")
            return
        }
    }
    Write-Step (T "Загрузка $name ..." "Downloading $name ...")
    # curl.exe надёжнее и заметно быстрее Invoke-WebRequest на файлах в гигабайты
    & curl.exe -L --fail --retry 3 --retry-delay 5 -o $Destination $Url
    if ($LASTEXITCODE -ne 0) { throw (T "Не удалось скачать $Url (curl код $LASTEXITCODE)" "Failed to download $Url (curl code $LASTEXITCODE)") }
    $size = (Get-Item -LiteralPath $Destination).Length
    Set-Content -LiteralPath $marker -Value $size -Encoding ascii
    Write-Ok (T "$name — загружено ($(Format-Size $size))" "$name - downloaded ($(Format-Size $size))")
}

#endregion

#region ── Языковые пакеты ──────────────────────────────────────────────────────

# Имена отличаются между источниками:
#   LoF ISO : Microsoft-Windows-Client-Language-Pack_x64_ru-ru.cab
#   UUP     : Microsoft-Windows-Client-LanguagePack-Package-amd64-ru-RU.esd
# Поэтому подбираем регулярным выражением, а не точным именем.
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
setlocal
chcp 65001 >nul
title Install Firefox
echo.
echo  $title
echo.
where winget >nul 2>&1
if not errorlevel 1 (
    echo  $tryWinget
    winget install --id Mozilla.Firefox -e --accept-package-agreements --accept-source-agreements
    if not errorlevel 1 goto :done
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
exit /b 0
"@
}

function Get-GuardScript {
    @'
#Requires -Version 5.1
param([switch]$Watch, [switch]$ShowDebugWindow, [int]$WaitSeconds = 120)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'guard.json') -Raw | ConvertFrom-Json
function T { param([string]$Ru, [string]$En) if ($config.Language -like 'ru*') { $Ru } else { $En } }
$logFile = Join-Path $PSScriptRoot 'guard.log'
if ($ShowDebugWindow) {
    $setup = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
    if ($env:USERNAME -eq 'defaultuser0' -or $setup.OOBEInProgress -eq 1 -or $setup.SystemSetupInProgress -eq 1) { return }
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    Start-Process -FilePath $exe -WindowStyle Normal -ArgumentList ('-NoExit -NoProfile -ExecutionPolicy Bypass -File "{0}\guard.ps1" -Watch' -f $PSScriptRoot)
    return
}
if ($Watch) {
    $Host.UI.RawUI.WindowTitle = 'win-11-lite guard - debug'
    Write-Host (T 'Живой журнал guard. Проверки выполняются от SYSTEM.' 'Live guard log. Checks run as SYSTEM.') -ForegroundColor Cyan
    Write-Host (T 'Это окно можно закрыть: работа guard продолжится.' 'Closing this window does not stop the guard.')
    Write-Host $logFile
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while (-not (Test-Path -LiteralPath $logFile)) {
        if ((Get-Date) -ge $deadline) { Write-Host (T 'Журнал ещё не создан. Проверьте задачу win-11-lite guard.' 'No log was created. Check the win-11-lite guard task.') -ForegroundColor Yellow; return }
        Start-Sleep -Seconds 1
    }
    Write-Host (T 'Последние записи и дальнейшие действия:' 'Recent records and subsequent activity:')
    Get-Content -LiteralPath $logFile -Encoding UTF8 -Tail 60 -Wait | ForEach-Object {
        $color = if ($_ -match '\[ERROR\]') { 'Red' } elseif ($_ -match '\[CHANGED\]|\[END\]') { 'Green' } elseif ($_ -match '\[SKIP\]|\[PENDING\]') { 'Yellow' } else { 'Gray' }
        Write-Host $_ -ForegroundColor $color
    }
    return
}
function Write-GuardLog {
    param([string]$Level, [string]$Message)
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message" | Add-Content -LiteralPath $logFile -Encoding UTF8
}
function Test-GuardMatch {
    param([string]$Name, [string[]]$Patterns)
    foreach ($pattern in @($config.Protected)) { if ($pattern -and $Name -match $pattern) { return $false } }
    foreach ($pattern in $Patterns) { if ($pattern -and $Name -match $pattern) { return $true } }
    return $false
}
$counts = @{Checked=0;Changed=0;Pending=0;Failed=0;Skipped=0}
function Invoke-GuardCheck {
    param([string]$Label, [scriptblock]$Action)
    $counts.Checked++
    Write-GuardLog 'CHECK' $Label
    try {
        $result = & $Action
        if ($result -eq 'changed') { $counts.Changed++; Write-GuardLog 'CHANGED' $Label }
        elseif ($result -eq 'pending') { $counts.Pending++; Write-GuardLog 'PENDING' (T "$Label — требуется завершение обслуживания" "$Label - servicing still pending") }
        elseif ($result -eq 'skipped') { $counts.Skipped++; Write-GuardLog 'SKIP' $Label }
        else { Write-GuardLog 'OK' $Label }
    } catch {
        $counts.Failed++
        Write-GuardLog 'ERROR' "$Label : $($_.Exception.Message)"
    }
}
function Read-GuardInventory {
    param([string]$Label, [scriptblock]$Read)
    $counts.Checked++
    Write-GuardLog 'CHECK' $Label
    try { & $Read }
    catch { $counts.Failed++; Write-GuardLog 'ERROR' "$Label : $($_.Exception.Message)" }
}
try { $runLock = [IO.File]::Open((Join-Path $PSScriptRoot 'guard.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
catch [IO.IOException] { return }
try {
    Write-GuardLog 'START' (T "Проверка при входе; сборка $($config.BuildId)" "Logon check; build $($config.BuildId)")
    $setup = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
    if ($setup.OOBEInProgress -eq 1 -or $setup.SystemSetupInProgress -eq 1) {
        $counts.Skipped++
        Write-GuardLog 'SKIP' (T 'OOBE ещё выполняется. Проверка продолжится при следующем входе.' 'OOBE is still running. Checks will run at the next logon.')
    } else {
        if ($config.RemoveEdge) {
            Invoke-GuardCheck 'Edge' {
                $browserPaths = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { Join-Path $_ 'Microsoft\Edge' }
                $hadBrowser = @($browserPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
                $global:LASTEXITCODE = 0
                & (Join-Path $PSScriptRoot 'Finalize.ps1') -EdgeOnly
                if ($LASTEXITCODE -ne 0) { throw (T 'Ошибка очистки Edge; см. finalize.log' 'Edge cleanup failed; see finalize.log') }
                if (@($browserPaths | Where-Object { Test-Path -LiteralPath $_ }).Count) { throw (T 'Файлы Edge всё ещё присутствуют' 'Edge files are still present') }
                if ($hadBrowser) { 'changed' } else { 'ok' }
            }
        }
        foreach ($entry in @($config.Policies)) {
            $parts = $entry -split '\|'; $path = $parts[0]; $name = $parts[1]; $want = [int]$parts[2]
            Invoke-GuardCheck (T "Политика $name" "Policy $name") {
                $current = (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue).$name
                if ($null -ne $current -and [int]$current -eq $want) { return 'ok' }
                if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
                Set-ItemProperty -LiteralPath $path -Name $name -Value $want -Type DWord -Force -ErrorAction Stop
                $actual = (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop).$name
                if ($null -eq $actual -or [int]$actual -ne $want) { throw (T 'Значение не изменилось' 'Value did not change') }
                'changed'
            }
        }
        foreach ($svc in @($config.Services)) {
            Invoke-GuardCheck (T "Служба $svc" "Service $svc") {
                $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
                if (-not (Test-Path -LiteralPath $key)) { return 'ok' }
                $changed = $false
                if ((Get-ItemProperty -LiteralPath $key -Name Start -ErrorAction Stop).Start -ne 4) {
                    Set-ItemProperty -LiteralPath $key -Name Start -Value 4 -Type DWord -Force -ErrorAction Stop
                    $changed = $true
                }
                $service = Get-Service -Name $svc -ErrorAction Stop
                if ($service.Status -ne 'Stopped') {
                    Stop-Service -Name $svc -Force -ErrorAction Stop
                    $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(10))
                    $changed = $true
                }
                if ((Get-ItemProperty -LiteralPath $key -Name Start -ErrorAction Stop).Start -ne 4) { throw (T 'Служба не отключена' 'Service is not disabled') }
                if ($changed) { 'changed' } else { 'ok' }
            }
        }
        if (@($config.Capabilities).Count) {
            $capabilities = @(Read-GuardInventory (T 'Получение списка возможностей Windows' 'Reading Windows capabilities') { Get-WindowsCapability -Online -ErrorAction Stop })
            foreach ($cap in @($capabilities | Where-Object { $_.State -eq 'Installed' })) {
                if (-not (Test-GuardMatch $cap.Name $config.Capabilities)) { continue }
                Invoke-GuardCheck (T "Возможность $($cap.Name)" "Capability $($cap.Name)") {
                    $result = Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop
                    $state = (Get-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop).State
                    if ($state -eq 'NotPresent' -or $state -eq 'Not Present') { return 'changed' }
                    if ($result.RestartNeeded -or [string]$state -match 'Pending') { return 'pending' }
                    throw (T "Возможность осталась: $state" "Capability remains: $state")
                }
            }
        }
        if (@($config.Apps).Count) {
            $apps = @(Read-GuardInventory (T 'Получение списка приложений' 'Reading apps') { Get-AppxPackage -AllUsers -ErrorAction Stop })
            foreach ($pkg in $apps) {
                if (-not (Test-GuardMatch $pkg.Name $config.Apps)) { continue }
                Invoke-GuardCheck (T "Приложение $($pkg.PackageFullName)" "App $($pkg.PackageFullName)") {
                    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                    if (@(Get-AppxPackage -AllUsers -Name $pkg.Name -ErrorAction Stop | Where-Object { $_.PackageFullName -eq $pkg.PackageFullName }).Count) { 'pending' } else { 'changed' }
                }
            }
            $provisioned = @(Read-GuardInventory (T 'Получение списка встроенных пакетов' 'Reading provisioned apps') { Get-AppxProvisionedPackage -Online -ErrorAction Stop })
            foreach ($pkg in $provisioned) {
                if (-not (Test-GuardMatch $pkg.DisplayName $config.Apps)) { continue }
                Invoke-GuardCheck (T "Встроенный пакет $($pkg.PackageName)" "Provisioned app $($pkg.PackageName)") {
                    Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                    if (@(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.PackageName -eq $pkg.PackageName }).Count) { 'pending' } else { 'changed' }
                }
            }
        }
        $driveRoot = [IO.Path]::GetFullPath($env:SystemDrive + '\')
        foreach ($relative in @($config.Paths)) {
            Write-GuardLog 'CHECK' (T "Поиск $relative" "Checking $relative")
            $pathErrors = @()
            $items = @(Get-Item -Path (Join-Path $driveRoot $relative) -Force -ErrorAction SilentlyContinue -ErrorVariable pathErrors)
            $readErrors = @($pathErrors | Where-Object { $_.CategoryInfo.Category -ne 'ObjectNotFound' })
            foreach ($readError in $readErrors) { $counts.Failed++; Write-GuardLog 'ERROR' "$relative : $($readError.Exception.Message)" }
            if (-not $items.Count -and -not $readErrors.Count) { $counts.Checked++; Write-GuardLog 'OK' (T "$relative отсутствует" "$relative is absent") }
            foreach ($item in $items) {
                Invoke-GuardCheck (T "Файл/каталог $($item.FullName)" "File/directory $($item.FullName)") {
                    $full = [IO.Path]::GetFullPath($item.FullName)
                    if (-not $full.StartsWith($driveRoot, [StringComparison]::OrdinalIgnoreCase) -or $full.TrimEnd('\') -eq $driveRoot.TrimEnd('\')) { throw (T 'Путь вне системного диска' 'Path is outside the system drive') }
                    $cursor = $full
                    while ($cursor) {
                        if ((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { return 'skipped' }
                        $cursor = Split-Path $cursor -Parent
                    }
                    if ($item.PSIsContainer) {
                        & takeown.exe /F $full /R /A /D Y *> $null
                        & icacls.exe $full /grant '*S-1-5-18:(OI)(CI)F' /T /C /Q *> $null
                        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
                    } else {
                        & takeown.exe /F $full /A *> $null
                        & icacls.exe $full /grant '*S-1-5-18:F' /C /Q *> $null
                        Remove-Item -LiteralPath $full -Force -ErrorAction Stop
                    }
                    if (Test-Path -LiteralPath $full) { throw (T 'Объект остался после удаления' 'Object remains after removal') }
                    'changed'
                }
            }
        }
    }
} catch {
    $counts.Failed++
    Write-GuardLog 'ERROR' $_.Exception.Message
} finally {
    Write-GuardLog 'END' (T "Проверено $($counts.Checked); изменено $($counts.Changed); ожидают завершения $($counts.Pending); пропущено $($counts.Skipped); ошибок $($counts.Failed)" "Checked $($counts.Checked); changed $($counts.Changed); pending $($counts.Pending); skipped $($counts.Skipped); errors $($counts.Failed)")
    $runLock.Dispose()
}
if ($counts.Failed) { exit 1 }
exit 0
'@
}

function Get-SetupSupportScripts {
    param([bool]$BlockNetwork, [bool]$RemoveEdge, [bool]$EnableGuard, [bool]$ManageOobe = $true, [string]$Language = 'en-US', [bool]$ShowGuardWindow = $true)
    $prepare = @'
#Requires -Version 5.1
param([switch]$RegisterOnly)
$ErrorActionPreference = 'Stop'
function T { param([string]$Ru, [string]$En) if ('__LANG__' -like 'ru*') { $Ru } else { $En } }
$log = Join-Path $PSScriptRoot 'prepare.log'
function Write-PrepareLog { param([string]$Message) "$(Get-Date -Format s) $Message" | Add-Content -LiteralPath $log -Encoding UTF8 }
# The answer file calls Finalize.ps1 directly at the first real user logon.
# Scheduler availability during specialize must not prevent network blocking.
if (-not $RegisterOnly -and __NETWORK__) {
    $statePath = Join-Path $PSScriptRoot 'network-state.clixml'
    $saved = @()
    if (Test-Path -LiteralPath $statePath) { $saved = @(Import-Clixml -LiteralPath $statePath) }
    $adapters = @(Get-NetAdapter -IncludeHidden | Where-Object { [string]$_.AdminStatus -in @('Up', '1') })
    $saved = @(@($saved) + @($adapters | Select-Object InterfaceGuid) | Sort-Object InterfaceGuid -Unique)
    Export-Clixml -LiteralPath $statePath -InputObject $saved
    foreach ($adapter in $adapters) { $adapter | Disable-NetAdapter -Confirm:$false }
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
}
try {
$taskName = 'win-11-lite finalize'
$exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$action = New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}\Finalize.ps1"' -f $PSScriptRoot)
$trigger = New-ScheduledTaskTrigger -AtLogOn
$trigger.Delay = 'PT30S'
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
if (__GUARD__) {
    $guardAction = New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}\guard.ps1"' -f $PSScriptRoot)
    Register-ScheduledTask -TaskName 'win-11-lite guard' -Action $guardAction -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    if (__GUARDDEBUG__) {
        $viewerAction = New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}\guard.ps1" -ShowDebugWindow' -f $PSScriptRoot)
        $viewerPrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
        $viewerTrigger = New-ScheduledTaskTrigger -AtLogOn
        $viewerTrigger.Delay = 'PT30S'
        $viewerSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances Parallel -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName 'win-11-lite guard debug' -Action $viewerAction -Trigger $viewerTrigger -Principal $viewerPrincipal -Settings $viewerSettings -Force | Out-Null
    } else {
        Unregister-ScheduledTask -TaskName 'win-11-lite guard debug' -Confirm:$false -ErrorAction SilentlyContinue
    }
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
param([switch]$EdgeOnly, [switch]$FirstLogon)
$ErrorActionPreference = 'Stop'
function T { param([string]$Ru, [string]$En) if ('__LANG__' -like 'ru*') { $Ru } else { $En } }
$log = Join-Path $PSScriptRoot 'finalize.log'
if ($FirstLogon -and $env:USERNAME -eq 'defaultuser0') { return }
if (-not $EdgeOnly -and -not $FirstLogon) {
    # defaultuser0 can log on during OOBE. Keep the task for the real user logon.
    $setupState = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
    if ($setupState.OOBEInProgress -eq 1 -or $setupState.SystemSetupInProgress -eq 1) { return }
}
# The logon task and FirstLogonCommands may start together; allow one finalizer.
try { $finalizeLock = [IO.File]::Open((Join-Path $PSScriptRoot 'finalize.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
catch [IO.IOException] { return }
try {
$failed = $false
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
                & takeown.exe /F $browser /A /R /D Y *> $null
                & icacls.exe $browser /grant '*S-1-5-18:(OI)(CI)F' /T /C /Q *> $null
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
    "$(Get-Date -Format s) $($_.Exception.Message)" | Add-Content -LiteralPath $log
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
                }
            }
            Remove-Item -LiteralPath $statePath -Force
        }
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
        "$(Get-Date -Format s) $(T 'Ошибка восстановления' 'Restore failed'): $($_.Exception.Message)" | Add-Content -LiteralPath $log
    }
    }
}
if (-not $failed -and -not $EdgeOnly) {
    "$(Get-Date -Format s) $(T 'Завершение установки выполнено' 'Finalization completed')" | Add-Content -LiteralPath $log
    Unregister-ScheduledTask -TaskName 'win-11-lite finalize' -Confirm:$false -ErrorAction SilentlyContinue
}
} finally { $finalizeLock.Dispose() }
if ($failed) { exit 1 }
'@
    $prepare = $prepare.Replace('__NETWORK__', ('$' + $BlockNetwork.ToString().ToLowerInvariant())).Replace('__GUARD__', ('$' + $EnableGuard.ToString().ToLowerInvariant())).Replace('__GUARDDEBUG__', ('$' + $ShowGuardWindow.ToString().ToLowerInvariant())).Replace('__OOBE__', ('$' + $ManageOobe.ToString().ToLowerInvariant())).Replace('__LANG__', $Language)
    $finalize = $finalize.Replace('__EDGE__', ('$' + $RemoveEdge.ToString().ToLowerInvariant())).Replace('__OOBE__', ('$' + $ManageOobe.ToString().ToLowerInvariant())).Replace('__LANG__', $Language)
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
    $update = Search-Catalog -Query "$kb x64" | Where-Object {
        $_.Title -match 'Windows 11' -and $_.Title -match 'x64' -and $_.Title -match $kb -and
        $_.Title -notmatch 'Dynamic|Preview|\.NET'
    } | Sort-Object Date -Descending | Select-Object -First 1
    if (-not $update) { throw (T "Обновление $kb для обслуживания языка не найдено" "Language repair update $kb was not found") }
    $dir = Join-Path $Destination "language-repair-$Revision"
    $null = New-Item -ItemType Directory -Path $dir -Force
    $files = @()
    foreach ($url in @(Get-CatalogLinks -UpdateId $update.Id)) {
        $name = [IO.Path]::GetFileName(([uri]$url).LocalPath)
        if ($name -notmatch '\.msu$') { continue }
        $file = Join-Path $dir $name
        Save-Url -Url $url -Destination $file
        if ($name -match $kb) { $files += $file }
    }
    if ($files.Count -ne 1) { throw (T "Нельзя однозначно определить MSU для $kb" "Cannot identify the target MSU for $kb") }
    $files[0]
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
    $null = New-Item -ItemType Directory -Path $Destination -Force

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
        foreach ($kind in $kinds) {
            $pattern = Get-LanguagePattern -Tag $tag -Kind $kind
            $hit = $entries | Where-Object { $_.Name -match $pattern } | Select-Object -First 1
            if (-not $hit) {
                throw (T "Отсутствует обязательный пакет $kind для $tag" "Required language package $kind for $tag is missing")
            }
            if ([IO.Path]::GetFileName($hit.Name) -ne $hit.Name) { throw (T 'Неверное имя скачиваемого файла' 'Invalid download filename') }
            if (-not $hit.Value.sha256) { throw (T "Нет SHA256 для $($hit.Name)" "No SHA256 for $($hit.Name)") }
            $dest = Join-Path $Destination $hit.Name
            if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -eq $hit.Value.size -and
                (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -eq $hit.Value.sha256) {
                Write-Ok (T "  $($hit.Name) — уже в кэше" "  $($hit.Name) - already cached")
                continue
            }
            Write-Step (T "  Загрузка $($hit.Name) ($(Format-Size $hit.Value.size)) ..." "  Downloading $($hit.Name) ($(Format-Size $hit.Value.size)) ...")
            & curl.exe -L --fail --retry 3 --retry-delay 5 -o $dest $hit.Value.url
            if ($LASTEXITCODE -ne 0) { throw (T "Ошибка загрузки: $($hit.Name)" "Download failed: $($hit.Name)") }
            if ($hit.Value.sha256) {
                $actual = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
                if ($actual -ne $hit.Value.sha256.ToUpper()) {
                    Remove-Item -LiteralPath $dest -Force
                    throw (T "Контрольная сумма $($hit.Name) не совпала — файл удалён" "Checksum mismatch for $($hit.Name) - file deleted")
                }
            }
            Write-Ok (T "  $($hit.Name) — загружено, SHA-256 совпал" "  $($hit.Name) - downloaded, SHA-256 matches")
        }
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
    foreach ($name in @($script:LoadedHives)) {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
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

function Remove-Reg {
    param([string]$Path)
    & reg.exe delete $Path /f *>&1 | Out-Null
}

#endregion

#region ── Стадия 0. Preflight ─────────────────────────────────────────────────

$script:FreedBytes = 0
$script:Mounted = $false
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

    # 3. Рабочая папка
    Write-Host ''
    $defaultWork = Join-Path ([IO.Path]::GetTempPath()) 'win-11-lite-work'
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
        $VerbosePreference = 'Continue'
    }

    # Итог
    if ($WithUpdates -and $UpdateMode -eq 'none') { $UpdateMode = 'download' }
    if ($DownloadLanguage -and -not $AddLanguage) { $AddLanguage = $DownloadLanguage }

    $cmd = ".\win-11-lite.ps1 -InputIso `"$InputIso`""
    if ($Index -gt 0)        { $cmd += " -Index $Index" }
    if ($Preset -ne 'balanced') { $cmd += " -Preset $Preset" }
    if ($WorkDir -ne $defaultWork) { $cmd += " -WorkDir `"$WorkDir`"" }
    if ($DownloadLanguage)   { $cmd += " -DownloadLanguage $($DownloadLanguage -join ',')" }
    if ($WithUpdates)        { $cmd += ' -WithUpdates' }
    if ($WithWinget)         { $cmd += ' -WithWinget' }
    if ($LegacySetup)        { $cmd += ' -LegacySetup' }
    if ($TrimSources)        { $cmd += ' -TrimSources' }
    if ($RemoveWinRE)        { $cmd += ' -RemoveWinRE' }
    if ($SaveWinRE)          { $cmd += ' -SaveWinRE' }
    if ($Guard)              { $cmd += ' -Guard' }
    if ($Guard -and -not $GuardDebug) { $cmd += ' -GuardDebug:$false' }
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
    foreach ($protectedPath in @($InputIso, $OutputIso, $UpdatesDir, $script:ScriptRoot, $Unattend, $LanguageSource, $DriversDir, $LanguageUpdatePath, $LogFile)) {
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

$script:Transcribing = $false
$script:DismLogPath = $null
if ($LogFile -and -not $DryRun) {
    $null = New-Item -ItemType Directory -Path (Split-Path $LogFile -Parent) -Force
    try { Start-Transcript -Path $LogFile -Force | Out-Null; $script:Transcribing = $true } catch { }
    if ($script:DebugMode) {
        $script:DismLogPath = [IO.Path]::ChangeExtension($LogFile, '.dism.log')
    }
}

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

# --- Windows ADK ---
$adkCandidates = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools",
    "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools"
)
$script:Dism = $null
$script:Oscdimg = $null
foreach ($root in $adkCandidates) {
    $d = Join-Path $root 'amd64\DISM\dism.exe'
    $o = Join-Path $root 'amd64\Oscdimg\oscdimg.exe'
    if ((Test-Path $d) -and -not $script:Dism) { $script:Dism = $d }
    if ((Test-Path $o) -and -not $script:Oscdimg) { $script:Oscdimg = $o }
}

if ((-not $script:Dism -or -not $script:Oscdimg) -and $InstallAdk -and -not $DryRun) {
    Write-Step (T 'Windows ADK не найден — устанавливаю Deployment Tools ...' 'Windows ADK not found - installing Deployment Tools ...')
    $adkSetup = Join-Path $env:TEMP 'adksetup.exe'
    # ADK 10.1.26100.2454 (декабрь 2024) — поддерживает Windows 11 24H2 и 25H2
    Save-Url -Url 'https://go.microsoft.com/fwlink/?linkid=2289980' -Destination $adkSetup
    & $adkSetup /quiet /norestart /features OptionId.DeploymentTools | Out-Null
    foreach ($root in $adkCandidates) {
        $d = Join-Path $root 'amd64\DISM\dism.exe'
        $o = Join-Path $root 'amd64\Oscdimg\oscdimg.exe'
        if ((Test-Path $d) -and -not $script:Dism) { $script:Dism = $d }
        if ((Test-Path $o) -and -not $script:Oscdimg) { $script:Oscdimg = $o }
    }
}

if ($script:Dism) {
    $v = (Get-Item $script:Dism).VersionInfo.ProductVersion
    Write-Ok (T "DISM из ADK: $script:Dism  (версия $v)" "DISM from ADK: $script:Dism  (version $v)")
} else {
    $msg = T @'
Не найден DISM из Windows ADK.

Хостовый C:\Windows\System32\Dism.exe (версия 10.0.19041.x) не подходит для
обслуживания образов Windows 11 24H2 — нужен DISM 10.1.26100.x из ADK.

Установите Windows ADK 10.1.26100.2454 (декабрь 2024), только Deployment Tools:
    https://go.microsoft.com/fwlink/?linkid=2289980
    adksetup.exe /quiet /norestart /features OptionId.DeploymentTools

Или запустите скрипт с ключом -InstallAdk, чтобы он поставил ADK сам.
'@ @'
DISM from the Windows ADK was not found.

The host C:\Windows\System32\Dism.exe (version 10.0.19041.x) cannot service
Windows 11 24H2 images - DISM 10.1.26100.x from the ADK is required.

Install Windows ADK 10.1.26100.2454 (December 2024), Deployment Tools only:
    https://go.microsoft.com/fwlink/?linkid=2289980
    adksetup.exe /quiet /norestart /features OptionId.DeploymentTools

Or run the script with -InstallAdk to let it install the ADK itself.
'@
    if ($DryRun) { Write-Note (T 'DISM из ADK не найден (для DryRun не критично)' 'DISM from ADK not found (not critical for DryRun)'); $script:Dism = "$env:SystemRoot\System32\Dism.exe" }
    else { throw $msg }
}

# --- драйвер монтирования WIM ---
# Тихая установка ADK не всегда регистрирует WIMMount. Без него /Mount-Image
# падает с кодом 1243 «The specified service does not exist».
if ($isAdmin -and -not $DryRun -and $script:Dism) {
    $wimMountKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\WIMMount'
    $wimMountOk = (Test-Path $wimMountKey) -and (Get-ItemProperty $wimMountKey -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
    if ($wimMountOk) {
        Write-Ok (T 'Драйвер монтирования WIMMount зарегистрирован' 'WIMMount driver is registered')
    } else {
        $wimSetup = Join-Path (Split-Path $script:Dism -Parent) 'WimMountAdkSetupAmd64.exe'
        if (Test-Path $wimSetup) {
            Write-Step (T 'Регистрирую драйвер монтирования WIMMount из ADK ...' 'Registering WIMMount driver from ADK ...')
            & $wimSetup /Install *>&1 | Out-Null
            Start-Sleep -Seconds 2
            if (Test-Path $wimMountKey) { Write-Ok (T 'Драйвер WIMMount зарегистрирован' 'WIMMount driver registered') }
            else { Write-Note (T 'Не удалось зарегистрировать WIMMount — монтирование образа может не сработать' 'Failed to register WIMMount - mounting the image may fail') }
        } else {
            Write-Note (T 'WimMountAdkSetupAmd64.exe не найден — если монтирование упадёт с кодом 1243, зарегистрируйте драйвер вручную' 'WimMountAdkSetupAmd64.exe not found - if mounting fails with code 1243, register the driver manually')
        }
    }
}

if ($script:Oscdimg) {
    Write-Ok (T "oscdimg: $script:Oscdimg" "oscdimg: $script:Oscdimg")
} elseif (-not $SkipIso) {
    if ($DryRun) { Write-Note (T 'oscdimg не найден (для DryRun не критично)' 'oscdimg not found (not critical for DryRun)') }
    else { throw (T 'Не найден oscdimg.exe — он ставится вместе с Deployment Tools из Windows ADK (см. выше).' 'oscdimg.exe not found - it comes with Deployment Tools from the Windows ADK (see above).') }
}

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
    if ($DownloadLanguage) {
        if (-not $DryRun) {
            try {
                $null = Invoke-WebRequest -Uri 'https://api.uupdump.net/' -UseBasicParsing -TimeoutSec 30 -Method Head
                Write-Ok (T 'Каталог языковых пакетов доступен' 'Language package catalog is reachable')
            } catch {
                throw (T "Нет доступа к каталогу языковых пакетов: $($_.Exception.Message)`nИспользуйте -LanguageSource с локальным LoF-образом." "No access to the language package catalog: $($_.Exception.Message)`nUse -LanguageSource with a local LoF image.")
            }
        }
    } elseif (-not $LanguageSource) {
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

# --- сеть ---
if ($UpdateMode -eq 'download' -and -not $DryRun) {
    try {
        $null = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/' -UseBasicParsing -TimeoutSec 30 -Method Head
        Write-Ok (T 'Microsoft Update Catalog доступен' 'Microsoft Update Catalog is reachable')
    } catch {
        throw (T "Нет доступа к Microsoft Update Catalog: $($_.Exception.Message)`nЗапустите с -UpdateMode local или -UpdateMode none." "No access to Microsoft Update Catalog: $($_.Exception.Message)`nRun with -UpdateMode local or -UpdateMode none.")
    }
}

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

#endregion

try {

#region ── Стадия 1. Распаковка ISO ────────────────────────────────────────────

Write-Stage (T 'Распаковка исходного ISO' 'Extracting the source ISO')

if (-not $DryRun) {
    if ($ClearCache -and (Test-Path $UpdatesDir)) {
        if (-not (Test-Path -LiteralPath (Join-Path $UpdatesDir '.win-11-lite-cache'))) { throw (T 'Отказ от очистки кэша без метки принадлежности скрипту' 'Refusing to clear an unmarked cache directory') }
        $null = Assert-ChildPath -Path $UpdatesDir -Root (Split-Path $UpdatesDir -Parent)
        foreach ($protectedPath in @($InputIso, $OutputIso, $WorkDir, $script:ScriptRoot, $LanguageSource, $Unattend, $DriversDir, $LanguageUpdatePath)) {
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
    # Метка: по ней следующий прогон поймёт, что каталог наш и его можно чистить
    Set-Content -LiteralPath (Join-Path $WorkDir $script:WorkDirMarker) `
                -Value "win-11-lite work folder, safe to delete`r`n$(Get-Date -Format s)" -Encoding ascii
}

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

if ($DryRun) {
    $srcSources = Join-Path $srcDrive 'sources'
} else {
    Write-Step (T 'Копирую содержимое ISO в рабочий каталог ...' 'Copying ISO contents to the work folder ...')
    & robocopy.exe "$srcDrive\" $isoDir /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw (T "robocopy завершился с кодом $LASTEXITCODE" "robocopy exited with code $LASTEXITCODE") }
    Get-ChildItem -LiteralPath $isoDir -Recurse -Force -File | ForEach-Object { $_.IsReadOnly = $false }
    $copied = (Get-ChildItem -LiteralPath $isoDir -Recurse -Force -File | Measure-Object -Property Length -Sum).Sum
    Write-Ok (T "Скопировано $(Format-Size $copied)" "Copied $(Format-Size $copied)")
    $srcSources = Join-Path $isoDir 'sources'
}

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

$images = @()
if ($isAdmin) {
    # Метаданные читаем через модуль Dism, а не dism.exe: тот печатает имена в
    # OEM-кодировке (кириллица превращается в мусор), а поле Languages выводит
    # на отдельной строке, что ломает разбор. Обслуживание образа всё равно
    # идёт через dism.exe из ADK — здесь только чтение.
    Import-Module Dism -ErrorAction Stop -Verbose:$false
    foreach ($b in (Get-WindowsImage -ImagePath $srcInstall)) {
        $d = Get-WindowsImage -ImagePath $srcInstall -Index $b.ImageIndex
        $images += [PSCustomObject]@{
            Index     = $d.ImageIndex
            Name      = $d.ImageName
            EditionId = $d.EditionId
            Architecture = $d.Architecture
            Languages = ($d.Languages -join ',')
            Version   = $d.Version
            Size      = $d.ImageSize
        }
    }
} else {
    # DryRun без прав: читаем XML-заголовок образа через 7-Zip
    $sevenZip = "$env:ProgramFiles\7-Zip\7z.exe"
    if (Test-Path $sevenZip) {
        # Имя уникально для процесса: каталог от прошлого запуска мог остаться
        # с правами администратора и оказаться недоступным
        $tmpXml = Join-Path $env:TEMP "win11lite-meta-$PID"
        & $sevenZip e $srcInstall '[1].xml' "-o$tmpXml" -y *>&1 | Out-Null
        $xmlFile = Join-Path $tmpXml '[1].xml'
        if (Test-Path -LiteralPath $xmlFile) {
            $xml = [xml](Get-Content -LiteralPath $xmlFile -Raw -Encoding Unicode)
            $images = $xml.WIM.IMAGE | ForEach-Object {
                [PSCustomObject]@{
                    Index     = $_.INDEX
                    Name      = $_.NAME
                    EditionId = $_.WINDOWS.EDITIONID
                    Architecture = $_.WINDOWS.ARCH
                    Languages = $_.WINDOWS.LANGUAGES.DEFAULT
                    Version   = "$($_.WINDOWS.VERSION.MAJOR).$($_.WINDOWS.VERSION.MINOR).$($_.WINDOWS.VERSION.BUILD).$($_.WINDOWS.VERSION.SPBUILD)"
                    Size      = $_.TOTALBYTES
                }
            }
            try {
                $null = Assert-ChildPath -Path $tmpXml -Root $env:TEMP
                Remove-Item -LiteralPath $tmpXml -Recurse -Force -ErrorAction Stop
            } catch { }
        }
    }
    if (-not $images) { throw (T 'Не удалось прочитать метаданные образа без прав администратора (нужен 7-Zip).' 'Could not read image metadata without administrator rights (7-Zip required).') }
}

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
$script:ImageLanguages = @($selected.Languages -split ',')
$imgVersion = if ($selected.PSObject.Properties['Version']) { $selected.Version } else { '' }
if (-not $imgVersion -and $selected.PSObject.Properties['ServicePack Build']) { $imgVersion = $selected.'ServicePack Build' }
$buildNumber = 0
if ($imgVersion -match '10\.0\.(\d+)') { $buildNumber = [int]$matches[1] }
elseif ($imgVersion -match '^(\d{5})') { $buildNumber = [int]$matches[1] }

# Полная ревизия (26100.1742) — по ней подбирается языковой пакет
$imgRevision = ''
if ($imgVersion -match '(\d{5}\.\d+)') { $imgRevision = $matches[1] }

$winVersion = switch ($buildNumber) {
    { $_ -ge 26200 } { '25H2'; break }
    { $_ -ge 26100 } { '24H2'; break }
    { $_ -ge 22631 } { '23H2'; break }
    { $_ -ge 22621 } { '22H2'; break }
    { $_ -ge 22000 } { '21H2'; break }
    default          { '24H2' }
}

Write-Ok (T "Выбран индекс $srcIndex — $($selected.Name)" "Selected index $srcIndex - $($selected.Name)")
Write-Ok (T "Редакция: $($selected.EditionId)   Язык: $imgLang   Билд: $imgVersion   ($winVersion)" "Edition: $($selected.EditionId)   Language: $imgLang   Build: $imgVersion   ($winVersion)")

$mozLang = $script:MozillaLang[$imgLang]
if (-not $mozLang) { $mozLang = ($imgLang -split '-')[0] }
Write-Ok (T "Язык для загрузки Firefox: $mozLang" "Firefox download language: $mozLang")

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

$allGroups = @('Defender', 'WinRE', 'Edge', 'Fonts', 'Speech', 'WMP', 'IE', 'Sandbox', 'AI')
$skipped = $allGroups | Where-Object { -not (Test-GroupActive -RulePreset 'balanced' -Group $_) }
if ($skipped) { Write-Host ''; Write-Note (T "Не трогаем: $($skipped -join ', ')" "Kept as is: $($skipped -join ', ')") }
Write-Host ''
$vLang = if ($AddLanguage) {
    $src = if ($DownloadLanguage) { T ' — скачать' ' - download' } else { (T ' — из ' ' - from ') + (Split-Path $LanguageSource -Leaf) }
    (T 'добавить ' 'add ') + ($AddLanguage -join ', ') + $src
} else { T "только $imgLang  (добавить: -DownloadLanguage ru-RU)" "$imgLang only  (add with -DownloadLanguage ru-RU)" }
$vSetup = if ($LegacySetup) { T 'классический (winpeshl.ini /legacy)' 'classic (winpeshl.ini /legacy)' } else { T 'штатный для 24H2 (ConX)' 'stock 24H2 (ConX)' }
$vWinRE = if ($RemoveWinRE) {
    $copyNote = if ($SaveWinRE) { T ', копия рядом с ISO' ', copy saved next to the ISO' } else { T ', без копии' ', no copy kept' }
    if ($LegacySetup) { (T 'удалить' 'remove') + $copyNote }
    else { T 'УДАЛИТЬ — без -LegacySetup установка упадёт!' 'REMOVE - without -LegacySetup the install will fail!' }
} else { T 'оставить' 'keep' }
$vSources = if ($TrimSources) { T 'урезать до boot.wim + install + EI.CFG' 'trim to boot.wim + install + EI.CFG' } else { T 'как в оригинале' 'as in the original' }
$vCleanup = if ($Preset -eq 'safe') { T 'нет' 'none' } elseif ($ResetBase) { 'StartComponentCleanup + ResetBase' } else { 'StartComponentCleanup' }
$vBypass = if (-not $NoBypass) { T 'да' 'yes' } else { T 'нет' 'no' }
$vWinget = if ($WithWinget) { T 'встроить' 'embed' } else { T 'нет  (включить: -WithWinget)' 'no  (enable with -WithWinget)' }
$vUpd = "$UpdateMode" + $(if ($UpdateMode -eq 'none') { T '  (встроить последние: -WithUpdates)' '  (embed latest with -WithUpdates)' })

Write-Host (T "  Языки          : $vLang" "  Languages      : $vLang")
if ($AddLanguage -and $UpdateMode -eq 'none') {
    Write-Note (T 'Добавление языка в обновлённый ISO требует повторного LCU исходного билда. Для 26100.1742 с -DownloadLanguage автоматически скачивается KB5043080 (~509 МБ загрузки).' 'Adding a language to updated media requires reapplying the source LCU. For 26100.1742, -DownloadLanguage automatically downloads KB5043080 (about 509 MB download).')
}
Write-Host (T "  Установщик     : $vSetup" "  Setup          : $vSetup")
Write-Host (T "  WinRE          : $vWinRE" "  WinRE          : $vWinRE")
Write-Host (T "  sources        : $vSources" "  sources        : $vSources")
Write-Host (T "  Очистка склада : $vCleanup" "  Store cleanup  : $vCleanup")
Write-Host (T "  Обход TPM/SB   : $vBypass" "  TPM/SB bypass  : $vBypass")
$vGuard = if ($Guard) { T 'встроить (проверка при каждом входе)' 'embed (checks at every logon)' } else { T 'нет  (включить: -Guard)' 'no  (enable with -Guard)' }
Write-Host (T "  winget         : $vWinget" "  winget         : $vWinget")
Write-Host (T "  Сторож         : $vGuard" "  Guard          : $vGuard")
if ($Guard) { Write-Host (T "  Окно guard     : $([bool]$GuardDebug) (выключить: -GuardDebug:`$false)" "  Guard window   : $([bool]$GuardDebug) (disable: -GuardDebug:`$false)") }
Write-Host (T "  Обновления     : $vUpd" "  Updates        : $vUpd")
$vOobeNet = if ($NoOobeNetworkBlock) { T 'сеть включена  (OOBE скачает обновления)' 'network on  (OOBE will download updates)' }
            else { T 'сеть выключена, вернётся при первом входе' 'network off, restored at first logon' }
Write-Host (T "  OOBE           : $vOobeNet" "  OOBE           : $vOobeNet")
Write-Host (T "  Сжатие         : $Compression" "  Compression    : $Compression")

if ($DryRun) {
    Write-Host ''
    Write-Ok (T 'DryRun завершён — ничего не изменено' 'DryRun finished - nothing was changed')
    return
}

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

#region ── Стадия 4. Загрузка обновлений ───────────────────────────────────────

$lcuDir = Join-Path $UpdatesDir "lcu-$winVersion"
$netDir = Join-Path $UpdatesDir "dotnet-$winVersion"

if ($UpdateMode -eq 'download') {
    Write-Stage (T 'Поиск и загрузка обновлений в Microsoft Update Catalog' 'Searching and downloading updates from Microsoft Update Catalog')

    # LCU. Отбрасываем Dynamic Update (это для установщика, не для образа) и Preview.
    Write-Step (T "Ищу накопительное обновление для Windows 11 $winVersion x64" "Looking for the cumulative update for Windows 11 $winVersion x64")
    $lcu = Search-Catalog -Query "Cumulative Update for Windows 11 version $winVersion x64" |
           Where-Object { $_.Title -notmatch 'Dynamic Update|Preview|\.NET Framework' -and $_.Title -match 'Cumulative Update' } |
           Sort-Object Date -Descending | Select-Object -First 1
    if (-not $lcu) { throw (T "В каталоге не найдено накопительное обновление для Windows 11 $winVersion" "No cumulative update found for Windows 11 $winVersion in the catalog") }
    Write-Ok (T "$($lcu.Title)  [$($lcu.Date.ToString('yyyy-MM-dd')), $($lcu.SizeMB) МБ]" "$($lcu.Title)  [$($lcu.Date.ToString('yyyy-MM-dd')), $($lcu.SizeMB) MB]")

    $null = New-Item -ItemType Directory -Path $lcuDir -Force

    $links = Get-CatalogLinks -UpdateId $lcu.Id
    Write-Step (T "Каталог вернул файлов: $($links.Count) (целевой LCU + checkpoint-обновления)" "Catalog returned $($links.Count) files (target LCU plus checkpoint updates)")
    $expected = @()
    foreach ($link in $links) {
        $name = [IO.Path]::GetFileName(([uri]$link).LocalPath)
        $expected += $name
        Save-Url -Url $link -Destination (Join-Path $lcuDir $name)
    }
    if ($lcu.Title -notmatch '\((KB\d+)\)') { throw (T 'В названии LCU нет номера KB' 'LCU title has no KB identifier') }
    $lcuKb = $matches[1]
    $targets = @($expected | Where-Object { $_ -match $lcuKb -and $_ -match '\.msu$' })
    if ($targets.Count -ne 1) { throw (T "Не найден единственный MSU для $lcuKb" "Cannot identify a unique MSU for $lcuKb") }
    $LcuFile = $targets[0]
    Set-Content -LiteralPath (Join-Path $lcuDir 'target.txt') -Value $LcuFile -Encoding ascii

    # В папке с целевым LCU должны лежать только он и его чекпоинты — иначе DISM
    # может подхватить постороннее обновление. Кэш при этом не трогаем.
    foreach ($stale in (Get-ChildItem -LiteralPath $lcuDir -Filter *.msu | Where-Object { $_.Name -notin $expected })) {
        Write-Note (T "Убираю лишний файл из папки LCU: $($stale.Name)" "Removing a foreign file from the LCU folder: $($stale.Name)")
        Remove-Item -LiteralPath $stale.FullName -Force
        Remove-Item -LiteralPath "$($stale.FullName).size" -Force -ErrorAction SilentlyContinue
    }

    if ($IncludeDotNetUpdate) {
        Write-Step (T 'Ищу накопительное обновление для .NET Framework' 'Looking for the .NET Framework cumulative update')
        $net = Search-Catalog -Query "Cumulative Update for .NET Framework Windows 11 version $winVersion x64" |
               Where-Object { $_.Title -match '\.NET Framework' -and $_.Title -notmatch 'Preview' } |
               Sort-Object Date -Descending | Select-Object -First 1
        if ($net) {
            Write-Ok "$($net.Title)  [$($net.Date.ToString('yyyy-MM-dd'))]"
            $null = New-Item -ItemType Directory -Path $netDir -Force
            foreach ($link in (Get-CatalogLinks -UpdateId $net.Id)) {
                Save-Url -Url $link -Destination (Join-Path $netDir ([IO.Path]::GetFileName(([uri]$link).LocalPath)))
                if ($link -match '\.msu(?:\?|$)') { $DotNetUpdateFile = [IO.Path]::GetFileName(([uri]$link).LocalPath) }
            }
            if (-not $DotNetUpdateFile) { throw (T 'Каталог не вернул MSU для .NET' 'Catalog returned no .NET MSU') }
            Set-Content -LiteralPath (Join-Path $netDir 'target.txt') -Value $DotNetUpdateFile -Encoding ascii
        } else {
            Write-Note (T 'Обновление для .NET Framework не найдено — пропускаю' '.NET Framework update not found - skipping')
        }
    }
} elseif ($UpdateMode -eq 'local') {
    Write-Stage (T 'Обновления из локального кэша' 'Updates from the local cache')
    if (-not (Test-Path $lcuDir)) { throw (T "Нет папки $lcuDir. Положите туда .msu или используйте -UpdateMode download." "Folder $lcuDir is missing. Put .msu files there or use -UpdateMode download.") }
    Write-Ok (T "LCU: $((Get-ChildItem $lcuDir -Filter *.msu).Count) файлов" "LCU: $((Get-ChildItem $lcuDir -Filter *.msu).Count) files")
}

#endregion

#region ── Стадия 5. Монтирование образа ───────────────────────────────────────

Write-Stage (T 'Монтирование образа' 'Mounting the image')

Invoke-Dism -Arguments @('/Mount-Image', "/ImageFile:$wimPath", '/Index:1', "/MountDir:$mountDir") -Activity (T 'Монтирование образа' 'Mounting the image') | Out-Null
$script:Mounted = $true
Write-Ok (T "Образ смонтирован в $mountDir" "Image mounted at $mountDir")
if ($Preset -eq 'balanced') { Write-ComponentStoreReport -Image $mountDir -Phase 'source' }
$script:PreservedWebView = @()
if ($Preset -ne 'max') {
    foreach ($root in @('Program Files (x86)\Microsoft\EdgeWebView', 'Program Files\Microsoft\EdgeWebView', 'Windows\System32\Microsoft-Edge-WebView')) {
        $webRoot = Join-Path $mountDir $root
        if (Test-Path -LiteralPath $webRoot) {
            if (@(Get-ChildItem -LiteralPath $webRoot -Recurse -Filter 'msedgewebview2.exe' -File | Select-Object -First 1).Count) { $script:PreservedWebView += $webRoot }
        }
    }
}

#endregion

#region ── Интеграция языков ───────────────────────────────────────────────────

# Языки ставятся строго до накопительных обновлений: LCU дополняет ресурсы
# уже установленных языков, а добавленный после него пакет останется без правок
# и потребует повторного применения LCU.
if ($AddLanguage) {
    Write-Stage (T "Интеграция языков: $($AddLanguage -join ', ')" "Adding languages: $($AddLanguage -join ', ')")

    # Скачивание идёт в кэш рядом с обновлениями и переживает следующие прогоны
    if ($DownloadLanguage) {
        # Кэш разводим по полной ревизии: пакеты разных ревизий несовместимы,
        # и общая папка приводила бы к повторному использованию чужих файлов
        $langCache = Join-Path $UpdatesDir "lang-$(if ($imgRevision) { $imgRevision } else { $buildNumber })"
        Save-LanguageFromCatalog -Tags $DownloadLanguage -Build $buildNumber -Revision $imgRevision -Destination $langCache
        $LanguageSource = $langCache
    }

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

    $kinds = @('Pack', 'Basic')

    # FoD lookup requires CBS identity filenames, not UUP download filenames.
    # Keep aliases in our work directory; a read-only LoF ISO is never modified.
    $fodSource = Join-Path $WorkDir 'language-fod'
    $null = New-Item -ItemType Directory -Path $fodSource -Force
    $sourcePackages = Invoke-Dism -Arguments @("/Image:$mountDir", '/Get-Packages') -Quiet
    $needsLanguageRepair = @($sourcePackages.Output | Where-Object { $_ -match 'Package_for_RollupFix' }).Count -gt 0
    if ($needsLanguageRepair -and $UpdateMode -eq 'none' -and -not $LanguageUpdatePath) {
        if (-not $DownloadLanguage) { throw (T 'Повторно примените исходный LCU через -LanguageUpdatePath либо используйте -WithUpdates' 'Reapply the source LCU using -LanguageUpdatePath, or use -WithUpdates') }
        Write-Step (T "Загружаю LCU исходного билда $imgRevision для обслуживания новых языков" "Downloading the source LCU $imgRevision to service new languages")
        $LanguageUpdatePath = Get-LanguageRepairUpdate -Revision $imgRevision -Destination $UpdatesDir
    }

    $addedLangs = @()
    foreach ($tag in $AddLanguage) {
        Write-Step (T "Язык $tag" "Language $tag")
        $found = 0
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
                $r = Invoke-Dism -Arguments @("/Image:$mountDir", '/Add-Package', "/PackagePath:$($pkg.FullName)") -Quiet
            } else {
                $capSource = $pkg.DirectoryName
                if ($pkg.Extension -eq '.cab') {
                    $aliasPath = Join-Path $fodSource (Get-FodSourceName -Tag $tag -Kind $kind)
                    Copy-Item -LiteralPath $pkg.FullName -Destination $aliasPath -Force
                    $capSource = $fodSource
                }
                $capName = "Language.$kind~~~$tag~0.0.1.0"
                $r = Invoke-Dism -Arguments @(
                    "/Image:$mountDir", '/Add-Capability', "/CapabilityName:$capName",
                    "/Source:$capSource", "/Source:$langRoot", '/LimitAccess'
                ) -Quiet
            }

            if (Test-DismSuccess $r.ExitCode) { Write-Ok "  $kind — $($pkg.Name) ($(Format-Size $pkg.Length))"; $found++ }
            else { throw (T "Ошибка $kind для ${tag}: $($r.ExitCode)" "$kind for $tag failed: $($r.ExitCode)") }
        }

        # Local Experience Pack локализует интерфейс современных приложений.
        # В LTSC нет Store, поэтому ставим его как provisioned-пакет.
        $lxp = Find-LanguagePackage -Root $langRoot -Tag $tag -Kind 'LXP'
        if ($lxp) {
            $lic = Get-ChildItem -LiteralPath $lxp.DirectoryName -Filter '*.xml' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            $lxpArgs = @("/Image:$mountDir", '/Add-ProvisionedAppxPackage', "/PackagePath:$($lxp.FullName)")
            if ($lic) { $lxpArgs += "/LicensePath:$($lic.FullName)" } else { $lxpArgs += '/SkipLicense' }
            $r = Invoke-Dism -Arguments $lxpArgs -Quiet
            if (Test-DismSuccess $r.ExitCode) { Write-Ok "  LXP — $($lxp.Name)" }
        }

        if ($found -ne $kinds.Count) { throw (T "Язык $tag установлен не полностью" "Language $tag is incomplete") }
        $addedLangs += $tag
    }

    if ($addedLangs) {
        # Первый язык из списка становится языком интерфейса, локалью и раскладкой
        $primary = $addedLangs[0]
        Write-Step (T "Делаю $primary языком по умолчанию" "Setting $primary as the default language")
        $r = Invoke-Dism -Arguments @("/Image:$mountDir", "/Set-AllIntl:$primary") -Quiet
        Invoke-Dism -Arguments @("/Image:$mountDir", "/Set-SysUILang:$primary") -Quiet | Out-Null
        if (Test-DismSuccess $r.ExitCode) {
            Write-Ok (T "Язык интерфейса, локаль и раскладка: $primary" "Display language, locale and keyboard layout: $primary")
            # autounattend и ярлык Firefox должны говорить на новом языке
            $imgLang = $primary
            $mozLang = $script:MozillaLang[$primary]
            if (-not $mozLang) { $mozLang = ($primary -split '-')[0] }
            Write-Ok (T "Язык для загрузки Firefox: $mozLang" "Firefox download language: $mozLang")
        } else {
            Write-Note (T "Set-AllIntl вернул $($r.ExitCode) — язык добавлен, но по умолчанию остался $imgLang" "Set-AllIntl returned $($r.ExitCode) - the language was added but $imgLang remains the default")
        }
        Write-Note (T 'Языки установщика (boot.wim) не меняются — экраны установки останутся на языке исходного образа' 'Setup language (boot.wim) is left untouched - installation screens stay in the original image language')
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

if ($UpdateMode -ne 'none') {
    Write-Stage (T 'Интеграция обновлений (самая долгая стадия, 30–60 минут)' 'Applying updates (the longest stage, 30-60 minutes)')

    # Порядок принципиален: сначала обновления, потом удаления — LCU способен
    # вернуть в образ то, что мы вырежем раньше времени.
    $lcuFiles = @(Get-ChildItem -LiteralPath $lcuDir -Filter *.msu -ErrorAction SilentlyContinue)
    if ($lcuFiles) {
        # Цель записана по номеру KB каталога или указана пользователем;
        # checkpoint-обновления DISM найдёт в этой же папке самостоятельно.
        $target = Get-UpdateTarget -Directory $lcuDir -FileName $LcuFile
        Invoke-Dism -Arguments @("/Image:$mountDir", '/Add-Package', "/PackagePath:$($target.FullName)") -Activity (T "Интеграция $($target.Name)" "Applying $($target.Name)") | Out-Null
        Write-Ok (T 'Накопительное обновление интегрировано' 'Cumulative update applied')
    } else {
        throw (T "В $lcuDir нет файлов LCU" "No LCU files found in $lcuDir")
    }

    if ($IncludeDotNetUpdate -and (Test-Path $netDir)) {
        $netFiles = @(Get-ChildItem -LiteralPath $netDir -Filter *.msu -ErrorAction SilentlyContinue)
        if ($netFiles) {
            $target = Get-UpdateTarget -Directory $netDir -FileName $DotNetUpdateFile
            Invoke-Dism -Arguments @("/Image:$mountDir", '/Add-Package', "/PackagePath:$($target.FullName)") -Activity (T "Интеграция $($target.Name)" "Applying $($target.Name)") | Out-Null
            Write-Ok (T 'Обновление .NET интегрировано' '.NET update applied')
        }
    }

    Write-Ok (T 'Образ обновлён' 'Image updated')
}

if ($DriversDir -and (Test-Path $DriversDir)) {
    Write-Step (T "Интегрирую драйверы из $DriversDir" "Adding drivers from $DriversDir")
    Invoke-Dism -Arguments @("/Image:$mountDir", '/Add-Driver', "/Driver:$DriversDir", '/Recurse') | Out-Null
    Write-Ok (T 'Драйверы интегрированы' 'Drivers added')
}

if ($Preset -eq 'balanced') {
    Write-ComponentStoreReport -Image $mountDir -Phase 'after-integration'
    Remove-OfflineRecall -Image $mountDir
}

#endregion

#region ── Стадия 7. Сохранение и удаление WinRE ───────────────────────────────

if ($RemoveWinRE -and (Test-GroupActive -RulePreset 'balanced' -Group 'WinRE')) {
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
$caps = ConvertFrom-DismList -Lines $capsRaw.Output -Key 'Capability Identity' |
        Where-Object { $_.State -eq 'Installed' -or ($Preset -eq 'balanced' -and $_.State -in @('Staged', 'Install Pending', 'Uninstall Pending')) }
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
$pkgs = ConvertFrom-DismList -Lines $pkgRaw.Output -Key 'Package Identity' |
        Where-Object { $_.State -eq 'Installed' -or ($Preset -eq 'balanced' -and $_.State -in @('Staged', 'Install Pending', 'Uninstall Pending')) }
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
$appx = ConvertFrom-DismList -Lines $appxRaw.Output -Key 'DisplayName'
Write-Step (T "Встроенных приложений: $($appx.Count)" "Provisioned apps: $($appx.Count)")

$patterns = @()
foreach ($rule in $script:AppxRules) {
    if (Test-GroupActive -RulePreset $rule.Preset -Group $rule.Group) { $patterns += $rule.Pattern }
}

$removedAppx = 0
foreach ($app in $appx) {
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
        & takeown.exe /F $p /A *>&1 | Out-Null
        & icacls.exe $p /grant '*S-1-5-32-544:(F)' /C /Q *>&1 | Out-Null
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
            & takeown.exe /F $f.FullName /A *>&1 | Out-Null
            & icacls.exe $f.FullName /grant '*S-1-5-32-544:(F)' /C /Q *>&1 | Out-Null
            try {
                $size = $f.Length
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $removed++
                $freed += $size
                $script:RemovedFonts += $f.Name
            } catch {
                Write-Verbose (T "Шрифт $($f.Name): $($_.Exception.Message)" "Font $($f.Name): $($_.Exception.Message)")
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
        & reg.exe query $key *>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
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
    Remove-Reg -Path 'HKLM\LITE_SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'
    Remove-Reg -Path 'HKLM\LITE_SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    Remove-Reg -Path 'HKLM\LITE_SOFTWARE\Clients\StartMenuInternet\Microsoft Edge'
    $stableGuid = '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
    foreach ($view in @('', '\WOW6432Node')) {
        foreach ($key in @('Clients', 'ClientState', 'ClientStateMedium')) {
            Remove-Reg -Path "HKLM\LITE_SOFTWARE$view\Microsoft\EdgeUpdate\$key\$stableGuid"
        }
        Remove-Reg -Path "HKLM\LITE_SOFTWARE$view\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
        Remove-Reg -Path "HKLM\LITE_SOFTWARE$view\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe"
    }
    Write-Ok (T 'Регистрация браузера Edge удалена; политики дополнены очисткой после OOBE' 'Edge browser registration removed; policies supplemented by post-OOBE cleanup')
}

# --- записи об удалённых шрифтах ---
if ($script:RemovedFonts) {
    $fontKey = 'HKLM\LITE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $raw = & reg.exe query $fontKey 2>&1
    foreach ($line in $raw) {
        if ($line -match '^\s{4}(.+?)\s{4}REG_SZ\s{4}(.+?)\s*$') {
            if ($script:RemovedFonts -contains $matches[2].Trim()) {
                & reg.exe delete $fontKey /v $matches[1].Trim() /f *>&1 | Out-Null
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
    & reg.exe delete 'HKLM\LITE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Run' /v OneDriveSetup /f *>&1 | Out-Null
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
    $wingetDir = Join-Path $UpdatesDir 'winget'
    $null = New-Item -ItemType Directory -Path $wingetDir -Force
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' `
                                     -Headers @{ 'User-Agent' = 'win-11-lite' } -TimeoutSec 60
        Write-Ok "App Installer $($release.tag_name)"

        $bundleAsset = $release.assets | Where-Object { $_.name -like '*.msixbundle' } | Select-Object -First 1
        $licenseAsset = $release.assets | Where-Object { $_.name -like '*License1.xml' } | Select-Object -First 1
        $depsAsset = $release.assets | Where-Object { $_.name -eq 'DesktopAppInstaller_Dependencies.zip' } | Select-Object -First 1

        $bundle = Join-Path $wingetDir $bundleAsset.name
        $license = Join-Path $wingetDir $licenseAsset.name
        $deps = Join-Path $wingetDir $depsAsset.name
        Save-Url -Url $bundleAsset.browser_download_url  -Destination $bundle
        Save-Url -Url $licenseAsset.browser_download_url -Destination $license
        Save-Url -Url $depsAsset.browser_download_url    -Destination $deps

        $depsDir = Join-Path $wingetDir 'deps'
        if (Test-Path $depsDir) {
            $null = Assert-ChildPath -Path $depsDir -Root $wingetDir
            Remove-Item -LiteralPath $depsDir -Recurse -Force
        }
        Expand-Archive -LiteralPath $deps -DestinationPath $depsDir -Force
        $depFiles = @(Get-ChildItem -LiteralPath $depsDir -Recurse -File |
                      Where-Object { $_.Extension -in @('.appx', '.msix') -and $_.FullName -match '\\(x64|neutral)\\' })

        $wingetArgs = @("/Image:$mountDir", '/Add-ProvisionedAppxPackage', "/PackagePath:$bundle")
        foreach ($dep in $depFiles) { $wingetArgs += "/DependencyPackagePath:$($dep.FullName)" }
        $wingetArgs += "/LicensePath:$license"

        $r = Invoke-Dism -Arguments $wingetArgs -Quiet
        if (Test-DismSuccess $r.ExitCode) {
            Write-Ok (T "winget встроен (зависимостей: $($depFiles.Count))" "winget added (dependencies: $($depFiles.Count))")
        } else {
            Write-Note (T "Не удалось встроить winget (код $($r.ExitCode)). Ярлык Install-Firefox всё равно сработает через curl." "Failed to add winget (code $($r.ExitCode)). The Install-Firefox shortcut will still work via curl.")
        }
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
    $guardProtected = @($script:NeverRemove) + @($script:CapabilityRules + $script:PackageRules | Where-Object { $Keep -contains $_.Group } | ForEach-Object { $_.Pattern })
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
        Language = $imgLang
        BuildId = $script:StartedAt.ToString('yyyyMMdd-HHmmss')
        RemoveEdge = (Test-GroupActive -RulePreset 'safe' -Group 'Edge')
        Policies = @($guardPolicies | Sort-Object -Unique)
        Services = @($guardServices | Sort-Object -Unique)
        Capabilities = @($guardCaps | Where-Object { $_ } | Sort-Object -Unique)
        Apps = @($guardAppx | Sort-Object -Unique)
        Protected = @($guardProtected | Sort-Object -Unique)
        Paths = @($guardFolders | Sort-Object -Unique)
    }
    [IO.File]::WriteAllText((Join-Path $guardDir 'guard.json'), ($guardConfig | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($true))
    $guardScript = Get-GuardScript
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
$support = Get-SetupSupportScripts -BlockNetwork ($script:ManageOobe -and -not $NoOobeNetworkBlock) `
    -RemoveEdge (Test-GroupActive -RulePreset 'safe' -Group 'Edge') -EnableGuard ([bool]$Guard) `
    -ManageOobe $script:ManageOobe -Language $imgLang -ShowGuardWindow ([bool]$GuardDebug)
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
    UpdateMode = $UpdateMode
    Guard = [bool]$Guard
    GuardDebug = [bool]($Guard -and $GuardDebug)
} | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $supportDir 'build-info.json'), $buildInfo, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $isoDir 'win11-lite-build.json'), $buildInfo, [Text.UTF8Encoding]::new($false))
Write-Ok (T "ID сборки: $($script:StartedAt.ToString('yyyyMMdd-HHmmss')) — записан в ISO и установленную Windows" "Build ID: $($script:StartedAt.ToString('yyyyMMdd-HHmmss')) - recorded in the ISO and installed Windows")
$setupComplete = @"
@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\Win11Lite\Prepare.ps1" -RegisterOnly >> "%SystemRoot%\Setup\Scripts\Win11Lite\setupcomplete.log" 2>&1
exit /b %errorlevel%
"@
Write-WindowsBatchFile -Path (Join-Path $scriptsDir 'SetupComplete.cmd') -Content $setupComplete
Write-Ok (T 'Очистка Edge и возврат сети/обновлений запланированы на первый вход' 'Edge cleanup and network/update restoration scheduled for first logon')

$publicDesktop = Join-Path $mountDir 'Users\Public\Desktop'
$null = New-Item -ItemType Directory -Path $publicDesktop -Force
$firefoxPath = Join-Path $publicDesktop 'Install-Firefox.cmd'
# CMD переключает кодовую страницу на UTF-8 до вывода локализованного текста.
Write-WindowsBatchFile -Path $firefoxPath -Content $firefoxCmd
Write-Ok (T "Install-Firefox.cmd на общем рабочем столе (язык: $mozLang)" "Install-Firefox.cmd placed on the public desktop (language: $mozLang)")

#endregion

#region ── Стадия 14. Очистка хранилища и фиксация ─────────────────────────────

Write-Stage (T 'Очистка хранилища компонентов и фиксация образа' 'Cleaning the component store and committing the image')

if ($AddLanguage) {
    Assert-ImageLanguages -Image $mountDir -Languages $AddLanguage -SourceLanguage $setupLang
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
    if ($RemoveWinRE -and (Test-GroupActive -RulePreset 'balanced' -Group 'WinRE')) {
        Remove-ImagePath -FullPath (Join-Path $mountDir 'Windows\System32\Recovery\Winre.wim') -Description 'WinRE (final)' | Out-Null
    }
}

# В balanced проверяем файлы после всех действий DISM, которые могли их восстановить.
if ($Preset -eq 'balanced') { Assert-ImageFileState -Image $mountDir }

Invoke-Dism -Arguments @('/Unmount-Image', "/MountDir:$mountDir", '/Commit') -Activity (T 'Сохранение изменений в образе' 'Committing changes to the image') | Out-Null
$script:Mounted = $false
Write-Ok (T "install.wim после фиксации: $(Format-Size (Get-Item -LiteralPath $wimPath).Length)" "install.wim after commit: $(Format-Size (Get-Item -LiteralPath $wimPath).Length)")

# --- boot.wim: обход требований и выбор установщика ---
if (-not $NoBypass -or $LegacySetup) {
    $bootWim = Join-Path $isoDir 'sources\boot.wim'
    if (Test-Path -LiteralPath $bootWim) {
        $bootInfo = Invoke-Dism -Arguments @('/Get-ImageInfo', "/ImageFile:$bootWim") -Quiet
        $bootImages = ConvertFrom-DismList -Lines $bootInfo.Output -Key 'Index'
        foreach ($bi in $bootImages) {
            $idx = [int]$bi.Index
            Write-Step (T "boot.wim индекс $idx — правлю" "boot.wim index $idx - patching")
            Invoke-Dism -Arguments @('/Mount-Image', "/ImageFile:$bootWim", "/Index:$idx", "/MountDir:$bootMountDir") | Out-Null
            $script:BootMounted = $true
            try {
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
                Invoke-Dism -Arguments @('/Unmount-Image', "/MountDir:$bootMountDir", '/Commit') | Out-Null
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
# Файл сообщает: редакция такая-то, канал корпоративный — ключ не нужен.
$eiCfgPath = Join-Path $isoDir 'sources\EI.CFG'
if (-not (Test-Path -LiteralPath $eiCfgPath)) {
    $eiCfg = @"
[EditionID]
$($selected.EditionId)

[Channel]
Volume

[VL]
1
"@
    [IO.File]::WriteAllText($eiCfgPath, $eiCfg, [Text.Encoding]::ASCII)
    Write-Ok (T "EI.CFG создан: редакция $($selected.EditionId), канал Volume" "EI.CFG created: edition $($selected.EditionId), Volume channel")
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
    $compactBlock = if ($CompactOS) { @"

            <ImageInstall>
                <OSImage>
                    <Compact>true</Compact>
                </OSImage>
            </ImageInstall>
"@ } else { '' }

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
                    <Path>powershell.exe -WindowStyle Hidden -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\Win11Lite\Prepare.ps1"</Path>
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
                    <Key>$ProductKey</Key>
                    <WillShowUI>Never</WillShowUI>
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
                    <CommandLine>powershell.exe -WindowStyle Hidden -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\Win11Lite\Finalize.ps1" -FirstLogon</CommandLine>
                </SynchronousCommand>
            </FirstLogonCommands>
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

    # Пути к загрузчикам передаём относительными и без кавычек: PowerShell
    # добавляет к закавыченному аргументу свои кавычки, и oscdimg получает ""path""
    $bootData = '2#p0,e,bboot\etfsboot.com#pEF,e,befi\microsoft\boot\efisys.bin'
    Write-Step (T "oscdimg → $OutputIso" "oscdimg -> $OutputIso")
    Push-Location $isoDir
    try {
        & $script:Oscdimg -m -o -u2 -udfver102 "-l$label" "-bootdata:$bootData" '.' $buildingIso
        $isoExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($isoExitCode -ne 0) { throw (T "oscdimg завершился с кодом $isoExitCode" "oscdimg exited with code $isoExitCode") }
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

    if (-not $DryRun) {
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
