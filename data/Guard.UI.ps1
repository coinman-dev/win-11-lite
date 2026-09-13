#Requires -Version 5.1
# Presentation and task helpers. Dot-sourcing this file does not run the guard.
function Get-GuardMode {
    param($Config)
    if($Config.Mode -in @('Debug','Standard','Silent')){return [string]$Config.Mode}
    'Standard'
}

function Get-GuardExpectedApps {
    param($Config)
    $known=@('Microsoft.SecHealthUI','Microsoft.Copilot','Microsoft.Windows.Ai.Copilot.Provider','Clipchamp.Clipchamp','Microsoft.BingNews','Microsoft.BingWeather','Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.MicrosoftOfficeHub','Microsoft.MicrosoftSolitaireCollection','Microsoft.WindowsFeedbackHub','Microsoft.YourPhone','Microsoft.OutlookForWindows','MicrosoftTeams','MSTeams')
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
    $arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $SupportDirectory 'guard.ps1')+'" -View -RunId "$(Arg0)"'
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
    Unregister-ScheduledTask -TaskName 'win-11-lite guard debug' -Confirm:$false -ErrorAction SilentlyContinue
}

function Test-GuardOobeComplete {
    $setup=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
    if($env:USERNAME -eq 'defaultuser0' -or $setup.OOBEInProgress -eq 1 -or $setup.SystemSetupInProgress -eq 1){return $false}
    if(-not ('Win11Lite.GuardOobe' -as [type])){
        Add-Type @'
using System.Runtime.InteropServices;
namespace Win11Lite {
    public static class GuardOobe {
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool OOBEComplete([MarshalAs(UnmanagedType.Bool)] out bool complete);
    }
}
'@
    }
    $complete=$false
    [Win11Lite.GuardOobe]::OOBEComplete([ref]$complete) -and $complete
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
        $found=@($rows|Where-Object{$_.Found -eq $true}).Count
        $cleared=@($rows|Where-Object{$_.Outcome -eq 'removed'}).Count
        if($found){
            $label=if($category -eq 'path'){T 'Файлы и каталоги' 'Files and directories'}else{T 'Компоненты Windows' 'Windows capabilities'}
            $lines.Add((T "${label}: найдено $found; удалено $cleared" "${label}: found $found; removed $cleared"))
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
    $null=Read-Host (T 'Нажмите Enter, чтобы закрыть окно' 'Press Enter to close')
}
