#Requires -Version 5.1
# Exercises the PowerShell runner with inert fixture scripts, never real setup/guard actions.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
foreach($name in 'T','Get-BundledResource','Get-SetupRunnerScript','Write-WindowsBatchFile'){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:ScriptRoot=$repo;$script:Lang='en';$Guard=$true;$script:checks=0
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw "FAIL: $Message"};$script:checks++}
$root=Join-Path $repo ('tmp\runner-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function New-RunnerProcess([string]$Runner,[string]$Mode,[string]$Directory){
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$powershell
    $psi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Runner+'" -Mode '+$Mode
    $psi.WorkingDirectory=$Directory;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.EnvironmentVariables['TEMP']=$Directory;$psi.EnvironmentVariables['TMP']=$Directory
    $psi
}
try{
    $runnerSource=Join-Path $root 'Run-Setup.ps1'
    [IO.File]::WriteAllText($runnerSource,(Get-SetupRunnerScript),[Text.UTF8Encoding]::new($true))
    Assert ((Split-Path $runnerSource -Leaf) -eq 'Run-Setup.ps1') 'Setup runner is a PowerShell source file'
    Assert (-not $ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Build-SetupLauncher'},$false)) 'Builder has no executable compilation stage'
    Assert (-not(Test-Path (Join-Path $repo 'data\SetupLauncher.cs'))) 'No custom EXE source remains in data'
    $fixture=@'
param([switch]$RegisterOnly,[switch]$FirstLogon,[switch]$WaitForOobe,[switch]$ShowDebugWindow)
$ErrorActionPreference='Stop'
Add-Type 'using System; using System.Runtime.InteropServices; public static class ConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
[ordered]@{Script=$MyInvocation.MyCommand.Name;Directory=$PSScriptRoot;WorkingDirectory=$PWD.Path;ConsoleWindow=[ConsoleProbe]::GetConsoleWindow().ToInt64();RegisterOnly=[bool]$RegisterOnly;FirstLogon=[bool]$FirstLogon;WaitForOobe=[bool]$WaitForOobe;ShowDebugWindow=[bool]$ShowDebugWindow}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'result.json') -Encoding utf8
[Console]::WriteLine('fixture stdout');[Console]::WriteLine('Вывод для журнала');[Console]::Error.WriteLine('fixture stderr')
exit ([int]$env:RUNNER_TEST_EXIT)
'@
    foreach($case in @(@{Mode='prepare';Script='Prepare.ps1';Flag='';Exit=17},@{Mode='prepare-register';Script='Prepare.ps1';Flag='RegisterOnly';Exit=0},@{Mode='finalize';Script='Finalize.ps1';Flag='FirstLogon';Exit=0},@{Mode='finalize-wait';Script='Finalize.ps1';Flag='WaitForOobe';Exit=5},@{Mode='guard';Script='guard.ps1';Flag='';Exit=0},@{Mode='guard-debug';Script='guard.ps1';Flag='ShowDebugWindow';Exit=0})){
        $directory=Join-Path $root ("$($case.Mode) папка & ' !");$null=New-Item -ItemType Directory -Path $directory
        $runner=Join-Path $directory 'Run-Setup.ps1';Copy-Item -LiteralPath $runnerSource -Destination $runner
        [IO.File]::WriteAllText((Join-Path $directory $case.Script),$fixture,[Text.UTF8Encoding]::new($true))
        $psi=New-RunnerProcess $runner $case.Mode $directory;$psi.EnvironmentVariables['RUNNER_TEST_EXIT']=[string]$case.Exit
        $process=[Diagnostics.Process]::Start($psi)
        try{
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(30000)){$process.Kill();throw 'Runner fixture timed out'}
            Assert ($process.ExitCode -eq $case.Exit) "Child exit code reaches the caller: $($case.Mode)"
            Assert ($stdout.GetAwaiter().GetResult().Length -eq 0 -and $stderr.GetAwaiter().GetResult().Length -eq 0) 'Runner writes diagnostics to a file'
            $actual=Get-Content -LiteralPath (Join-Path $directory 'result.json') -Raw|ConvertFrom-Json
            Assert ($actual.ConsoleWindow -eq 0) 'Runner child has no console window'
            Assert ($actual.Script -eq $case.Script -and $actual.Directory -eq $directory -and $actual.WorkingDirectory -eq $directory) 'Quoted paths and working directory reach the intended fixture'
            Assert (@('RegisterOnly','FirstLogon','WaitForOobe','ShowDebugWindow'|Where-Object{[bool]$actual.$_ -ne ($_ -eq $case.Flag)}).Count -eq 0) 'Only the selected script switch is passed'
            $log=Get-Content -LiteralPath (Join-Path $directory 'launcher.log') -Raw
            Assert ($log.Contains('Вывод для журнала') -and $log -match 'fixture stdout' -and $log -match 'fixture stderr') 'Russian output and stderr remain readable'
            Assert ($log -match "END ExitCode=$($case.Exit)") 'Completion status is logged'
        }finally{$process.Dispose()}
    }
    $directory=Join-Path $root 'setupcomplete';$null=New-Item -ItemType Directory -Path $directory
    $runner=Join-Path $directory 'Run-Setup.ps1';Copy-Item -LiteralPath $runnerSource -Destination $runner
    [IO.File]::WriteAllText((Join-Path $directory 'Prepare.ps1'),'param([switch]$RegisterOnly) Start-Sleep -Milliseconds 400; exit 23',[Text.UTF8Encoding]::new($true))
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$setupComplete'},$true)
    . ([scriptblock]::Create($node.Extent.Text))
    $setupComplete=$setupComplete.Replace('%SystemRoot%\Setup\Scripts\Win11Lite\Run-Setup.ps1',$runner).Replace('%SystemRoot%\Setup\Scripts\Win11Lite\setupcomplete.log',(Join-Path $directory 'setupcomplete.log'))
    $batch=Join-Path $directory 'SetupComplete.cmd';Write-WindowsBatchFile -Path $batch -Content $setupComplete
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=Join-Path $env:SystemRoot 'System32\cmd.exe';$psi.Arguments='/d /s /c ""'+$batch+'""';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($psi)
    try{if(-not $process.WaitForExit(15000)){$process.Kill();throw 'SetupComplete fixture timed out'};Assert ($process.ExitCode -eq 23) 'SetupComplete waits for PowerShell and retains the script exit code'}finally{$process.Dispose()}
    $empty=Join-Path $root 'empty';$null=New-Item -ItemType Directory -Path $empty
    $runner=Join-Path $empty 'Run-Setup.ps1';Copy-Item -LiteralPath $runnerSource -Destination $runner
    foreach($mode in 'unknown','prepare extra','guard'){
        $process=[Diagnostics.Process]::Start((New-RunnerProcess $runner $mode $empty))
        try{if(-not $process.WaitForExit(10000)){$process.Kill();throw 'Mode fixture timed out'};Assert ($process.ExitCode -eq $(if($mode -eq 'guard'){2}else{87})) 'Unknown modes, extra arguments and missing scripts fail'}finally{$process.Dispose()}
    }
    $directory=Join-Path $root 'delayed-oobe';$null=New-Item -ItemType Directory -Path $directory
    $source=[IO.File]::ReadAllText($runnerSource);$rt=$null;$re=$null;$runnerAst=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$rt,[ref]$re)
    $probe=$runnerAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-SetupOobeComplete'},$false)
    $replacement='$script:ReadyAt=(Get-Date).AddSeconds(1); function Test-SetupOobeComplete { (Get-Date) -ge $script:ReadyAt }'
    $source=$source.Remove($probe.Extent.StartOffset,$probe.Extent.EndOffset-$probe.Extent.StartOffset).Insert($probe.Extent.StartOffset,$replacement)
    $runner=Join-Path $directory 'Run-Setup.ps1';[IO.File]::WriteAllText($runner,$source,[Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $directory 'guard.ps1'),'param([switch]$ShowDebugWindow) exit 0',[Text.UTF8Encoding]::new($true))
    $timer=[Diagnostics.Stopwatch]::StartNew();$process=[Diagnostics.Process]::Start((New-RunnerProcess $runner 'guard-debug' $directory))
    try{
        if(-not $process.WaitForExit(15000)){$process.Kill();throw 'OOBE fixture timed out'}
        Assert ($process.ExitCode -eq 0 -and $timer.ElapsedMilliseconds -ge 900) 'Visible debug observer waits for OOBE completion'
        $log=Get-Content -LiteralPath (Join-Path $directory 'launcher.log') -Raw
        Assert ($log.IndexOf('WAIT OOBE') -ge 0 -and $log.IndexOf('WAIT OOBE') -lt $log.IndexOf('START PID')) 'OOBE gate precedes observer startup'
    }finally{$process.Dispose()}
    & {
        $ut=$null;$ue=$null;$updateAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'tools\Update-InstalledGuard.ps1'),[ref]$ut,[ref]$ue)
        foreach($name in 'Convert-LegacySetupHook','Convert-GuardViewerRegistration','Update-Win11LiteRuntime'){
            $function=$updateAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
            . ([scriptblock]::Create($function.Extent.Text))
        }
        $support=Join-Path $root 'installed\Win11Lite';$null=New-Item -ItemType Directory -Path $support
        [IO.File]::WriteAllText((Join-Path $support 'build-info.json'),'{"BuildId":"fixture","Guard":true}')
        [IO.File]::WriteAllText((Join-Path $support 'oobe-complete'),'yes')
        [IO.File]::WriteAllText((Join-Path $support 'guard.ps1'),'# old guard')
        [IO.File]::WriteAllText((Join-Path $support 'guard.json'),'{"Language":"en-US","BuildId":"fixture","Policies":[],"Services":[],"Paths":[]}')
        $oldExe=Join-Path $support 'Win11Lite.Run.exe';[IO.File]::WriteAllText($oldExe,'inert fixture')
        $oldPrepare=@'
$exe = Join-Path $PSScriptRoot 'Win11Lite.Run.exe'
$action=New-ScheduledTaskAction -Execute $exe -Argument 'finalize-wait'
$action=New-ScheduledTaskAction -Execute $exe -Argument 'guard'
$action=New-ScheduledTaskAction -Execute $exe -Argument 'guard-debug'
'@
        [IO.File]::WriteAllText((Join-Path $support 'Prepare.ps1'),$oldPrepare)
        [IO.File]::WriteAllText((Join-Path $support 'Finalize.ps1'),'$exe = Join-Path $PSScriptRoot ''Win11Lite.Run.exe'''+"`r`n"+'Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList ''finalize-wait''')
        $task=[pscustomobject]@{TaskName='win-11-lite guard';TaskPath='\';State='Disabled';Actions=@([pscustomobject]@{Execute=$oldExe;Arguments='guard'})}
        $state=@{Updates=0;Viewer=$null;Registrations=0}
        function Get-ScheduledTask {param($ErrorAction)$task;if($state.Viewer){$state.Viewer}}
        function Export-ScheduledTask {param($TaskName)'<Task />'}
        function New-ScheduledTaskAction {param($Execute,$Argument)[pscustomobject]@{Execute=$Execute;Arguments=$Argument}}
        function Set-ScheduledTask {param($TaskName,$Action,$ErrorAction)$task.Actions=@($Action);$state.Updates++}
        function New-ScheduledTaskPrincipal {param($GroupId,$RunLevel)[pscustomobject]@{GroupId=$GroupId;RunLevel=$RunLevel}}
        function New-ScheduledTaskSettingsSet {param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$MultipleInstances,$ExecutionTimeLimit)[pscustomobject]@{MultipleInstances=$MultipleInstances}}
        function Register-ScheduledTask {param($TaskName,$Action,$Principal,$Settings,[switch]$Force)$state.Registrations++;$state.Viewer=[pscustomobject]@{TaskName=$TaskName;TaskPath='\';State='Ready';Actions=@($Action);Principal=$Principal}}
        function Unregister-ScheduledTask {[CmdletBinding(SupportsShouldProcess)]param($TaskName)if($state.Viewer -and $state.Viewer.TaskName -eq $TaskName){$state.Viewer=$null}}
        function Disable-ScheduledTask {param($TaskName,$ErrorAction)$state.Viewer.State='Disabled'}
        $task.State='Running';$blocked=$false
        try{Update-Win11LiteRuntime -SupportDirectory $support -SourceDirectory (Join-Path $repo 'data')|Out-Null}catch{$blocked=$true}
        Assert ($blocked -and $state.Updates -eq 0 -and (Get-Content (Join-Path $support 'guard.ps1') -Raw) -eq '# old guard') 'VM updater waits for running tasks before making changes'
        $task.State='Disabled'
        $state.Viewer=[pscustomobject]@{TaskName='win-11-lite guard debug';TaskPath='\';State='Ready';Actions=@([pscustomobject]@{Execute=$oldExe;Arguments='guard-debug'})}
        $result=Update-Win11LiteRuntime -SupportDirectory $support -SourceDirectory (Join-Path $repo 'data')
        Assert ($state.Updates -eq 1 -and $task.State -eq 'Disabled' -and $task.Actions[0].Arguments -match 'Run-Setup\.ps1" -Mode guard$') 'VM updater changes the action while preserving task state'
        Assert ((Test-Path (Join-Path $result.Backup 'guard.ps1')) -and (Test-Path (Join-Path $result.Backup 'win-11-lite guard.xml'))) 'VM updater backs up scripts and task definitions'
        Assert (Test-Path (Join-Path $result.Backup 'win-11-lite guard debug.xml')) 'The removed legacy observer task is backed up before migration'
        Assert (-not(Test-Path $oldExe) -and (Test-Path (Join-Path $support 'Run-Setup.ps1'))) 'VM updater removes the obsolete EXE after installing its replacement'
        foreach($file in 'Prepare.ps1','Finalize.ps1'){
            $content=Get-Content (Join-Path $support $file) -Raw
            Assert ($content -notmatch 'Win11Lite\.Run\.exe' -and $content -match 'Run-Setup\.ps1') 'Legacy support scripts no longer refer to the removed EXE'
        }
        Assert ($result.Mode -eq 'Standard' -and $state.Viewer.Actions[0].Arguments -match 'guard\.ps1" -View -RunId' -and $state.Viewer.Principal.RunLevel -eq 'Limited') 'Default migration installs the direct limited report viewer'
        Assert ((Test-Path (Join-Path $result.Backup 'guard.json')) -and (Test-Path (Join-Path $support 'Guard.UI.ps1')) -and (Test-Path (Join-Path $support 'runtime-update.json'))) 'Mode configuration is backed up and installed runtime details are exported'
        $result=Update-Win11LiteRuntime -SupportDirectory $support -SourceDirectory (Join-Path $repo 'data') -Mode Silent
        Assert (-not $state.Viewer -and $result.Mode -eq 'Silent' -and $task.State -eq 'Disabled') 'Silent mode removes the viewer without enabling the worker'
        $result=Update-Win11LiteRuntime -SupportDirectory $support -SourceDirectory (Join-Path $repo 'data')
        Assert ($result.Mode -eq 'Silent' -and -not $state.Viewer) 'An update without a mode preserves a previous Silent choice'
        $result=Update-Win11LiteRuntime -SupportDirectory $support -SourceDirectory (Join-Path $repo 'data') -Mode Debug
        $afterConfig=Get-Content -LiteralPath (Join-Path $support 'guard.json') -Raw|ConvertFrom-Json
        Assert ($afterConfig.Mode -eq 'Debug' -and $afterConfig.ViewerTask -and $state.Viewer) 'Explicit Debug mode restores the demand-start viewer'
        $state.Viewer.State='Disabled'
        $null=Update-Win11LiteRuntime -SupportDirectory $support -SourceDirectory (Join-Path $repo 'data')
        Assert ($state.Viewer.State -eq 'Disabled') 'A manually disabled viewer stays disabled when updating without a new mode'
        $legacyRegistration=@'
if ($true) {
    Register-ScheduledTask -TaskName 'win-11-lite guard' -Action $guardAction
    if ($true) {
        $viewerAction=New-ScheduledTaskAction -Execute $exe -Argument ($runnerArguments + 'guard-debug')
        Register-ScheduledTask -TaskName 'win-11-lite guard debug' -Action $viewerAction
    } else {
        Unregister-ScheduledTask -TaskName 'win-11-lite guard debug' -Confirm:$false
    }
}
'@
        $converted=Convert-GuardViewerRegistration $legacyRegistration
        [void][Management.Automation.Language.Parser]::ParseInput($converted,[ref]$ut,[ref]$ue)
        Assert (-not $ue.Count -and $converted -match 'Register-GuardViewerTask' -and $converted -notmatch "Register-ScheduledTask -TaskName 'win-11-lite guard debug'") 'Legacy Prepare registration is migrated without leaving a recurring intermediate launcher'
        Assert ($converted -match "Register-ScheduledTask -TaskName 'win-11-lite guard'" -and (Convert-GuardViewerRegistration $converted) -eq $converted) 'Migration preserves worker registration and can be applied again'
    }
    Write-Host "PASS: $script:checks runner checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $full=[IO.Path]::GetFullPath($root);$base=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\runner-tests-'
    if($full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){for($attempt=0;$attempt -lt 5;$attempt++){try{Remove-Item -LiteralPath $full -Recurse -Force;break}catch{if($attempt -eq 4){throw};Start-Sleep -Milliseconds 250}}}
}
