#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'

function Convert-LegacySetupHook {
    param([string]$Text)
    $old='$exe = Join-Path $PSScriptRoot ''Win11Lite.Run.exe'''
    $new='$exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"'
    $Text=$Text.Replace($old,$new)
    foreach($mode in 'finalize-wait','guard','guard-debug'){
        $argument='(''-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}\Run-Setup.ps1" -Mode '+$mode+''' -f $PSScriptRoot)'
        $Text=$Text.Replace("-Argument '$mode'",'-Argument '+$argument)
        $Text=$Text.Replace("-ArgumentList '$mode'",'-ArgumentList '+$argument)
    }
    $Text=$Text.Replace('start "" /wait "%SystemRoot%\Setup\Scripts\Win11Lite\Win11Lite.Run.exe" prepare-register','"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SystemRoot%\Setup\Scripts\Win11Lite\Run-Setup.ps1" -Mode prepare-register')
    if($Text -match 'Win11Lite\.Run\.exe'){throw 'Неизвестный старый способ запуска. Обновление остановлено до замены файлов.'}
    $Text
}

function Update-Win11LiteRuntime {
    param([string]$SupportDirectory,[string]$SourceDirectory)
    $infoPath=Join-Path $SupportDirectory 'build-info.json'
    if(-not(Test-Path -LiteralPath $infoPath) -or -not(Test-Path -LiteralPath (Join-Path $SupportDirectory 'oobe-complete'))){
        throw 'Не найдена завершённая установка win-11-lite. Запускайте обновление внутри готовой тестовой VM.'
    }
    $info=Get-Content -LiteralPath $infoPath -Raw|ConvertFrom-Json
    if(-not $info.BuildId){throw 'В build-info.json нет ID сборки.'}
    $replacements=@{}
    foreach($name in 'guard.ps1','Run-Setup.ps1'){
        $file=Join-Path $SourceDirectory $name
        $text=[IO.File]::ReadAllText($file)
        $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
        if($errors.Count){throw "Ошибка синтаксиса $name"}
        $replacements[(Join-Path $SupportDirectory $name)]=$text
    }
    foreach($name in 'Prepare.ps1','Finalize.ps1'){
        $file=Join-Path $SupportDirectory $name
        if(Test-Path -LiteralPath $file){
            $text=Convert-LegacySetupHook ([IO.File]::ReadAllText($file))
            $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
            if($errors.Count){throw "Не удалось обновить синтаксис $name"}
            $replacements[$file]=$text
        }
    }
    $batch=Join-Path (Split-Path $SupportDirectory -Parent) 'SetupComplete.cmd'
    if(Test-Path -LiteralPath $batch){$replacements[$batch]=Convert-LegacySetupHook ([IO.File]::ReadAllText($batch))}
    $modes=@{'win-11-lite guard'='guard';'win-11-lite guard debug'='guard-debug';'win-11-lite finalize'='finalize-wait'}
    $tasks=@(Get-ScheduledTask -ErrorAction Stop|Where-Object{$modes.ContainsKey($_.TaskName)})
    if(@($tasks|Where-Object{$_.TaskPath -ne '\'}).Count){throw 'Задача win-11-lite перемещена из корня планировщика; требуется ручная проверка пути.'}
    if(@($tasks|Where-Object{$_.State -eq 'Running'}).Count){throw 'Задача win-11-lite сейчас выполняется. Дождитесь её окончания и повторите обновление.'}
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $ownedExe=Join-Path $SupportDirectory 'Win11Lite.Run.exe'
    foreach($task in $tasks){
        $actions=@($task.Actions)
        if($actions.Count -ne 1){throw "Неизвестные действия задачи $($task.TaskName)"}
        $action=$actions[0]
        $known=$action.Execute -eq $ownedExe -and $action.Arguments -eq $modes[$task.TaskName]
        if($action.Execute -eq $powershell){$known=$action.Arguments -match ('-File\s+"'+[regex]::Escape($SupportDirectory)+'\\(guard|Finalize|Run-Setup)\.ps1"')}
        if(-not $known){throw "Неизвестное действие задачи $($task.TaskName)"}
    }
    $backup=Join-Path $SupportDirectory ('backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    $null=New-Item -ItemType Directory -Path $backup
    Copy-Item -LiteralPath $infoPath -Destination (Join-Path $backup 'build-info.json')
    foreach($task in $tasks){
        $xml=Export-ScheduledTask -TaskName $task.TaskName
        [IO.File]::WriteAllText((Join-Path $backup ($task.TaskName+'.xml')),$xml,[Text.UTF8Encoding]::new($true))
    }
    foreach($file in $replacements.Keys){
        if(Test-Path -LiteralPath $file){Copy-Item -LiteralPath $file -Destination (Join-Path $backup (Split-Path $file -Leaf))}
        $encoding=[Text.UTF8Encoding]::new(([IO.Path]::GetExtension($file) -ne '.cmd'))
        [IO.File]::WriteAllText($file,($replacements[$file] -replace '\r?\n',"`r`n"),$encoding)
    }
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach($task in $tasks){
        $arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $SupportDirectory 'Run-Setup.ps1')+'" -Mode '+$modes[$task.TaskName]
        $action=New-ScheduledTaskAction -Execute $powershell -Argument $arguments
        Set-ScheduledTask -TaskName $task.TaskName -Action $action -ErrorAction Stop|Out-Null
    }
    $info|Add-Member -NotePropertyName SetupScriptLauncher -NotePropertyValue 'PowerShell / Run-Setup.ps1' -Force
    $info|Add-Member -NotePropertyName RuntimeUpdatedAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
    $info|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $infoPath -Encoding utf8
    $oldExe=Join-Path $SupportDirectory 'Win11Lite.Run.exe'
    if(Test-Path -LiteralPath $oldExe){
        try{Remove-Item -LiteralPath $oldExe -Force -ErrorAction Stop}
        catch{Write-Warning "Задачи уже переведены на PowerShell, но старый EXE пока занят: $oldExe"}
    }
    [pscustomobject]@{Backup=$backup;TasksUpdated=$tasks.Count;Report=(Join-Path $SupportDirectory 'guard-report.txt')}
}

$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Откройте PowerShell от администратора внутри тестовой VM.'}
$result=Update-Win11LiteRuntime -SupportDirectory (Join-Path $env:SystemRoot 'Setup\Scripts\Win11Lite') -SourceDirectory (Join-Path $PSScriptRoot '..\data')
Write-Host "Готово. Обновлено задач: $($result.TasksUpdated). Резервные копии: $($result.Backup)"
Write-Host "Подробный отчёт появится при следующем запуске guard: $($result.Report)"
