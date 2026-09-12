#Requires -Version 5.1
param([switch]$Watch, [switch]$ShowDebugWindow, [int]$WaitSeconds = 120)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'guard.json') -Raw | ConvertFrom-Json
function T { param([string]$Ru, [string]$En) if ($config.Language -like 'ru*') { $Ru } else { $En } }
$logFile = Join-Path $PSScriptRoot 'guard.log'
$reportFile = Join-Path $PSScriptRoot 'guard-report.txt'
if ($ShowDebugWindow) {
    $setup = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
    if ($env:USERNAME -eq 'defaultuser0' -or $setup.OOBEInProgress -eq 1 -or $setup.SystemSetupInProgress -eq 1) { return }
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    Start-Process -FilePath $exe -WindowStyle Normal -ArgumentList ('-NoLogo -NoExit -NoProfile -ExecutionPolicy Bypass -File "{0}\guard.ps1" -Watch' -f $PSScriptRoot)
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
    $tail = 60
    if (Test-Path -LiteralPath $reportFile) {
        Get-Content -LiteralPath $reportFile -Encoding UTF8 | ForEach-Object { Write-Host $_ }
        $tail = 0
    }
    Write-Host (T 'Последние записи и дальнейшие действия:' 'Recent records and subsequent activity:')
    Get-Content -LiteralPath $logFile -Encoding UTF8 -Tail $tail -Wait | ForEach-Object {
        $color = if ($_ -match '\[ERROR\]') { 'Red' } elseif ($_ -match '\[CHANGED\]|\[END\]') { 'Green' } elseif ($_ -match '\[SKIP\]|\[PENDING\]') { 'Yellow' } else { 'Gray' }
        Write-Host $_ -ForegroundColor $color
    }
    return
}
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
    # remaining checks. Run-Setup.ps1 captures stderr in launcher.log.
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
$counts = @{Checked=0;Changed=0;Pending=0;Failed=0;Skipped=0;LogFailed=0}
$guardRows=[Collections.Generic.List[object]]::new()
$guardWarnings=[Collections.Generic.List[string]]::new()
$guardHistory=@{}; $guardNextHistory=@{}; $guardInventoryStatus=@{}; $guardVisited=@{}
$guardStartedAt=Get-Date; $guardComplete=$false; $guardSkippedOobe=$false
function Add-GuardDetail {
    param([string]$Category,[string]$Name,[string]$Outcome,$Found,[string]$Before,[string]$After,[string]$Detail,[string]$Desired,[string]$Identity=$Name)
    $key="$Category|$Identity"
    $changed=$Outcome -in @('removed','disabled','stopped','set','created')
    $repeated=$changed -and $guardHistory.ContainsKey($key) -and [string]$guardHistory[$key].Desired -eq $Desired
    $guardRows.Add([pscustomobject]@{Category=$Category;Name=$Name;Identity=$Identity;Outcome=$Outcome;Found=$Found;Before=$Before;After=$After;Detail=$Detail;Repeated=[bool]$repeated})
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
        Add-GuardDetail -Category $Category -Name $Name -Identity $Identity -Outcome 'failed' -Found $observation.Found -Before $observation.Before -After $observation.After -Detail $detail
    }
}
function Read-GuardInventory {
    param([string]$Label, [scriptblock]$Read,[string]$Category)
    $counts.Checked++
    Write-GuardLog 'CHECK' $Label
    try { $items=@(& $Read);$guardInventoryStatus[$Category]=$true;$items }
    catch {
        $guardInventoryStatus[$Category]=$false;$counts.Failed++;Write-GuardLog 'ERROR' "$Label : $($_.Exception.Message)"
        Add-GuardDetail -Category $Category -Name $Label -Outcome 'failed' -Found $null -Detail (T "Список недоступен; отсутствие компонентов не подтверждено. $($_.Exception.Message)" "Inventory unavailable; component absence is unconfirmed. $($_.Exception.Message)")
    }
}
function Add-MissingGuardTargets {
    param([string]$Category,[string[]]$Patterns,[object[]]$Inventory,[string]$NameProperty)
    if(-not $guardInventoryStatus[$Category]){return}
    $targets=@($Patterns|Where-Object{$_})
    if($Category -in @('app','provisioned')){
        $known=@('Microsoft.SecHealthUI','Microsoft.Copilot','Microsoft.Windows.Ai.Copilot.Provider','Clipchamp.Clipchamp','Microsoft.BingNews','Microsoft.BingWeather','Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.MicrosoftOfficeHub','Microsoft.MicrosoftSolitaireCollection','Microsoft.WindowsFeedbackHub','Microsoft.YourPhone','Microsoft.OutlookForWindows','MicrosoftTeams','MSTeams')
        if($config.ExpectedApps){$known=@($config.ExpectedApps)}
        $known=@($known|Where-Object{Test-GuardMatch $_ $Patterns})
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
    $text=$lines -join "`r`n"
    Write-GuardLog 'REPORT' ("`r`n"+$text)
    $report=[ordered]@{Schema=1;BuildId=$config.BuildId;Started=$guardStartedAt.ToString('o');Finished=(Get-Date).ToString('o');Complete=$guardComplete;Deferred=$guardSkippedOobe;Errors=$counts.Failed;LogErrors=$counts.LogFailed;Summary=$totals;Items=@($guardRows.ToArray());Warnings=@($guardWarnings.ToArray())}
    foreach($document in @(
        @{Name='guard-report.txt';Text=$text},
        @{Name='guard-report.json';Text=($report|ConvertTo-Json -Depth 8)},
        @{Name='guard-state.json';Text=([ordered]@{Schema=1;BuildId=$config.BuildId;Managed=@($guardNextHistory.Values)}|ConvertTo-Json -Depth 5)}
    )){
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
try { $runLock = [IO.File]::Open((Join-Path $PSScriptRoot 'guard.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
catch [IO.IOException] { return }
try {
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
        if ($config.RemoveEdge) {
            Invoke-GuardCheck -Label 'Edge' -Category component -Name 'Microsoft Edge' -Desired absent -Action {
                param($observation)
                $browserPaths = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { Join-Path $_ 'Microsoft\Edge' }
                $hadBrowser = @($browserPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
                $observation.Found=$hadBrowser;$observation.Before=if($hadBrowser){'Present'}else{'Absent'}
                $global:LASTEXITCODE = 0
                & (Join-Path $PSScriptRoot 'Finalize.ps1') -EdgeOnly
                if ($LASTEXITCODE -ne 0) { throw (T 'Ошибка очистки Edge; см. finalize.log' 'Edge cleanup failed; see finalize.log') }
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
                    if ($item.PSIsContainer) {
                        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
                    } else {
                        Remove-Item -LiteralPath $full -Force -ErrorAction Stop
                    }
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
        try { Save-GuardReport } catch {$counts.LogFailed++;try{[Console]::Error.WriteLine("[LOG ERROR] Report: $($_.Exception.Message)")}catch{}}
        Write-GuardLog 'END' (T "Проверено $($counts.Checked); изменено $($counts.Changed); ожидают завершения $($counts.Pending); пропущено $($counts.Skipped); ошибок $($counts.Failed)" "Checked $($counts.Checked); changed $($counts.Changed); pending $($counts.Pending); skipped $($counts.Skipped); errors $($counts.Failed)")
    }
    finally { $runLock.Dispose() }
}
if ($counts.LogFailed) {
    try { [Console]::Error.WriteLine((T "[LOG ERROR] Не записано строк в guard.log: $($counts.LogFailed); строки переданы в stderr (launcher.log при штатном запуске)." "[LOG ERROR] Lines not written to guard.log: $($counts.LogFailed); forwarded to stderr (launcher.log during normal startup).")) } catch { }
}
if ($counts.Failed -or $counts.LogFailed) { exit 1 }
exit 0
