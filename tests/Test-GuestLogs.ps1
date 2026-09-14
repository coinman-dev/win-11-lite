#Requires -Version 5.1
# Only guest logging helpers and fixture files run. No guard/system actions.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
$node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-GuestScript'},$false)
. ([scriptblock]::Create($node.Extent.Text))
$guest=[Management.Automation.Language.Parser]::ParseInput((Get-GuestScript),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
foreach($name in 'T','Assert-GuestLogPath','Remove-ExpiredGuestLogs','Get-GuestLogPath','Write-GuestLogRecord','Write-GuestLog','Write-RunnerLog','Write-PrepareLog','Write-FinalizeLog','Set-GuardLogPosition','Write-GuardLog','Read-GuardLiveLog'){
    $node=$guest.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    if(-not $node){throw "Missing helper: $name"}
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:checks=0
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw "FAIL: $Message"};$script:checks++}
function Assert-Throws([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed $Message}
$root=Join-Path $repo ('tmp\guest-logs-'+[guid]::NewGuid().ToString('N'))
$script:Support=Join-Path $root 'support'
$null=New-Item -ItemType Directory -Path $script:Support -Force
$script:BuildInfo=@{Language='ru-RU'};$script:LogCleanupDay='';$Mode='prepare'
$clock=@{Now=[datetime]'2026-09-14T12:00:00'}
function Get-Date {param($Format)if($Format){$clock.Now.ToString($Format)}else{$clock.Now}}
try{
    $today=$clock.Now
    foreach($age in 44..0){$clock.Now=$today.AddDays(-$age);Write-PrepareLog "day $age"}
    $logs=Join-Path $script:Support 'Logs'
    $files=@(Get-ChildItem -LiteralPath $logs -File|Sort-Object Name)
    Assert ($files.Count -eq 30) 'Only today and the previous 29 daily files survive 45 days of logging'
    Assert ($files[0].BaseName -eq $today.AddDays(-29).ToString('yyyy-MM-dd') -and $files[-1].BaseName -eq '2026-09-14') 'Retention includes the exact oldest allowed day'
    $path=Get-GuestLogPath
    Write-RunnerLog 'русский вывод и stderr'
    Write-FinalizeLog 'finalize message'
    Write-PrepareLog 'second invocation on the same day'
    $text=[IO.File]::ReadAllText($path)
    Assert ($text.Contains('русский вывод') -and $text -match '\[launcher\]' -and $text -match '\[finalize\]' -and $text -match '\[prepare\]') 'Sources share one readable daily log'
    Assert (@(Get-ChildItem -LiteralPath $logs -File).Count -eq 30) 'Repeated invocations append without creating another daily file'
    $bytes=[IO.File]::ReadAllBytes($path)
    Assert ($bytes[0] -eq 255 -and $bytes[1] -eq 254 -and ([Text.Encoding]::Unicode.GetString($bytes).ToCharArray()|Where-Object{$_ -eq [char]0xFEFF}).Count -eq 1) 'UTF-16 LE BOM is written once for interoperability with VBScript'
    $reader=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try{Write-PrepareLog 'append while viewer reads'}finally{$reader.Dispose()}
    Assert ([IO.File]::ReadAllText($path).Contains('append while viewer reads')) 'A live shared reader does not block append on PowerShell 5.1'

    & {
        # Two actual Windows PowerShell writers share the same day file. Only
        # the append helper is loaded in the children; no guest mode can run.
        $writer=Join-Path $root 'log-writer.ps1'
        $recordHelper=$guest.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-GuestLogRecord'},$false).Extent.Text
        $source='param([string]$LogPath,[string]$WriterId)'+"`r`n"+'$ErrorActionPreference="Stop"'+"`r`n"+$recordHelper+"`r`n"+'foreach($i in 1..40){Write-GuestLogRecord -Path $LogPath -Text ($WriterId+":"+$i+" проверка параллельной записи")} '
        [IO.File]::WriteAllText($writer,$source,[Text.UTF8Encoding]::new($true))
        $processes=@()
        try{
            foreach($id in @('writerA','writerB')){
                $psi=[Diagnostics.ProcessStartInfo]::new()
                $psi.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $psi.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$writer+'" -LogPath "'+$path+'" -WriterId '+$id
                $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
                $processes += [Diagnostics.Process]::Start($psi)
            }
            foreach($process in $processes){if(-not $process.WaitForExit(30000)){throw 'Concurrent writer timed out'}}
            Assert (@($processes|Where-Object{$_.ExitCode -ne 0}).Count -eq 0) 'Concurrent writers both finish successfully'
            $records=@([IO.File]::ReadAllLines($path)|Where-Object{$_ -match '^writer[AB]:\d+ проверка параллельной записи$'})
            Assert ($records.Count -eq 80 -and @($records|Sort-Object -Unique).Count -eq 80) 'Concurrent appends preserve every Unicode record without overwrites'
        }finally{foreach($process in $processes){if(-not $process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()}}
    }

    $sentinels=@('guard-state.json','guard.json','build-info.json','guard-report.txt','guard-summary.txt','guard-run.json','Win11Lite.ps1')
    foreach($name in $sentinels){$file=Join-Path $script:Support $name;[IO.File]::WriteAllText($file,'keep');[IO.File]::SetLastWriteTime($file,$today.AddDays(-90))}
    foreach($name in @('2026-02-31.log','2026-01-01.txt','notes.log')){[IO.File]::WriteAllText((Join-Path $logs $name),'keep')}
    $nested=Join-Path $logs '2026-01-01.log';$null=New-Item -ItemType Directory -Path $nested
    [IO.File]::WriteAllText((Join-Path $nested 'keep.txt'),'keep')
    foreach($name in 'guard.log','prepare.log','finalize.log','launcher.log','vbs-launcher.log'){
        $file=Join-Path $script:Support $name;[IO.File]::WriteAllText($file,'legacy');[IO.File]::SetLastWriteTime($file,$today.AddDays(-30))
    }
    [IO.File]::SetLastWriteTime((Join-Path $script:Support 'prepare.log'),$today.AddDays(-29))
    Remove-ExpiredGuestLogs $script:Support
    foreach($name in $sentinels){Assert ([IO.File]::ReadAllText((Join-Path $script:Support $name)) -eq 'keep') "Retention never deletes support/state/report files: $name"}
    Assert ((Test-Path -LiteralPath (Join-Path $script:Support 'prepare.log')) -and -not (Test-Path -LiteralPath (Join-Path $script:Support 'guard.log'))) 'Old-format logs expire by last write time with the same 30-day boundary'
    Assert ((Test-Path -LiteralPath (Join-Path $logs '2026-02-31.log')) -and (Test-Path -LiteralPath (Join-Path $logs '2026-01-01.txt')) -and (Test-Path -LiteralPath (Join-Path $nested 'keep.txt'))) 'Only valid daily log filenames are eligible; cleanup is nonrecursive'
    Assert-Throws {Assert-GuestLogPath $script:Support (Join-Path $root 'outside.log')} 'A log cannot escape the support directory'

    $expired=Join-Path $logs '2026-07-01.log';[IO.File]::WriteAllText($expired,'locked old log')
    $lock=[IO.File]::Open($expired,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    $oldError=[Console]::Error;$capture=[IO.StringWriter]::new();$script:LogCleanupDay=''
    try{[Console]::SetError($capture);Write-PrepareLog 'new logs survive a cleanup error'}finally{[Console]::SetError($oldError);$lock.Dispose()}
    Assert ($capture.ToString() -match '\[LOG CLEANUP\]' -and [IO.File]::ReadAllText($path).Contains('new logs survive a cleanup error')) 'A locked expired file is reported without breaking current logging'
    $capture.Dispose();$script:LogCleanupDay='';Write-PrepareLog 'retry cleanup'
    Assert (-not (Test-Path -LiteralPath $expired)) 'Cleanup retries on the next invocation after a locked file is released'

    # The viewer follows the same run across midnight using the worker marker.
    $clock.Now=$today.Date.AddHours(23).AddMinutes(59)
    $guardRunId=[guid]::NewGuid().ToString();$guardStartedAt=$clock.Now;$config=@{BuildId='fixture'};$counts=@{LogFailed=0};$script:GuardLogFile=$null
    Write-GuardLog 'START' 'before midnight'
    $marker=Get-Content -LiteralPath (Join-Path $script:Support 'guard-run.json') -Raw|ConvertFrom-Json
    Assert ($marker.LogFile -eq 'Logs\2026-09-14.log' -and $marker.LogOffset -gt 0) 'The marker records the daily file and byte offset after prior same-day records'
    Write-RunnerLog '[END] this is not the guard completion'
    $shown=[Collections.Generic.List[string]]::new();$wait=@{Count=0}
    & {
        function Write-Host {param($Object,$ForegroundColor)$shown.Add([string]$Object)}
        function Start-Sleep {
            param($Milliseconds)
            $wait.Count++
            if($wait.Count -gt 2){throw 'Viewer did not follow rotation'}
            $clock.Now=$today.Date.AddDays(1).AddSeconds(1)
            Write-GuardLog 'INFO' 'после полуночи'
            Write-GuardLog 'END' 'completed after midnight'
        }
        Read-GuardLiveLog -SupportDirectory $script:Support -RunId $guardRunId
    }
    Assert ($wait.Count -eq 1 -and $counts.LogFailed -eq 0) 'Viewer ignores another source END and waits for its own run through midnight'
    Assert (($shown -join "`n") -match 'before midnight' -and ($shown -join "`n") -match 'после полуночи' -and ($shown -join "`n") -match 'completed after midnight') 'Live viewer preserves old and new day records with correct encoding at nonzero offsets'
    Assert (($shown -join "`n") -notmatch 'second invocation on the same day') 'Live viewer starts at the selected run rather than replaying prior daily history'
    $nextPath=Get-GuestLogPath
    Assert ($nextPath -ne $path -and [IO.File]::ReadAllText($nextPath).Contains('после полуночи') -and -not [IO.File]::ReadAllText($path).Contains('после полуночи')) 'A process spanning midnight writes new events into the new daily file'

    # Root directory junctions must not let retention reach another tree.
    $other=Join-Path $root 'outside';$null=New-Item -ItemType Directory -Path $other
    $outsideLog=Join-Path $other '2020-01-01.log';[IO.File]::WriteAllText($outsideLog,'keep outside')
    $linked=Join-Path $root 'linked-support';$null=New-Item -ItemType Directory -Path $linked
    $junction=Join-Path $linked 'Logs';$null=New-Item -ItemType Junction -Path $junction -Target $other
    Assert-Throws {Remove-ExpiredGuestLogs $linked} 'Retention rejects a junction used as the Logs directory'
    Assert ([IO.File]::ReadAllText($outsideLog) -eq 'keep outside') 'A rejected log junction leaves its target intact'
    [IO.Directory]::Delete($junction)
    $ancestorLink=Join-Path $root 'linked-parent';$null=New-Item -ItemType Junction -Path $ancestorLink -Target $other
    Assert-Throws {Get-GuestLogPath -SupportDirectory (Join-Path $ancestorLink 'nested-support') -Create} 'A junction above the support directory cannot redirect log creation or cleanup'
    Assert (-not [IO.Directory]::Exists((Join-Path $other 'nested-support'))) 'Rejected ancestor junction does not create directories outside the selected support tree'
    [IO.Directory]::Delete($ancestorLink)
    Write-Host "PASS: $script:checks guest log checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $full=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\guest-logs-'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected test cleanup directory'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
