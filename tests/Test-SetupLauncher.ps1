#Requires -Version 5.1
# Exercises the guest runner: the real Start-GuestChild starts a patched copy of
# the real guest file. No setup, guard or scheduled-task action is performed.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
foreach($name in 'T','Get-GuestScript','Get-SetupVbsScript','Get-SetupEntryCommand','Test-ImageVbsLauncher','Write-WindowsBatchFile'){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    if(-not $node){throw "Missing function: $name"}
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:ScriptRoot=$repo;$script:Lang='en';$Guard='Standard';$script:checks=0
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw "FAIL: $Message"};$script:checks++}
$root=Join-Path $repo ('tmp\runner-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Get-FixtureLogPath([string]$Directory){Join-Path $Directory ('Logs\'+(Get-Date -Format 'yyyy-MM-dd')+'.log')}
function New-GuestProcess([string]$Guest,[string]$Arguments,[string]$Directory){
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$powershell
    $psi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Guest+'" '+$Arguments
    $psi.WorkingDirectory=$Directory;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.EnvironmentVariables['TEMP']=$Directory;$psi.EnvironmentVariables['TMP']=$Directory
    $psi
}
function New-VbsProcess([string]$Launcher,[string]$Arguments,[string]$Directory){
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=Join-Path $env:SystemRoot 'System32\wscript.exe'
    $psi.Arguments='//B //NoLogo "'+$Launcher+'" '+$Arguments
    $psi.WorkingDirectory=$Directory;$psi.UseShellExecute=$false
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.EnvironmentVariables['TEMP']=$Directory;$psi.EnvironmentVariables['TMP']=$Directory
    $psi
}
try{
    # Keep the real parameters, logging and child launcher; replace only the work.
    $guestSource=Get-GuestScript
    $marker='# ── Requested mode ─'
    $split=$guestSource.IndexOf($marker,[StringComparison]::Ordinal)
    if($split -lt 0){throw 'Guest dispatcher marker not found'}
    $fixtureTail=@'
if (-not $Mode -or $ExtraArguments.Count) { Write-RunnerLog "Unsupported request: Mode='$Mode'; extra='$($ExtraArguments -join ' ')'"; exit 87 }
Add-Type 'using System; using System.Runtime.InteropServices; public static class ConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window); }'
if (-not $Direct) {
    [ordered]@{Visible=[ConsoleProbe]::IsWindowVisible([ConsoleProbe]::GetConsoleWindow())} | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $PSScriptRoot 'initial-window.json') -Encoding utf8
    exit (Start-GuestChild -ChildMode $Mode)
}
[ordered]@{Mode=$Mode;Direct=[bool]$Direct;Directory=$PSScriptRoot;WorkingDirectory=$PWD.Path;ConsoleWindow=[ConsoleProbe]::GetConsoleWindow().ToInt64()} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'result.json') -Encoding utf8
[Console]::WriteLine('fixture stdout');[Console]::WriteLine('Вывод для журнала');[Console]::Error.WriteLine('fixture stderr')
exit ([int]$env:RUNNER_TEST_EXIT)
'@
    $fixtureGuest=$guestSource.Substring(0,$split)+($fixtureTail -replace '\r?\n',"`r`n")
    $ft=$null;$fe=$null;$null=[Management.Automation.Language.Parser]::ParseInput($fixtureGuest,[ref]$ft,[ref]$fe)
    if($fe.Count){throw ($fe|Out-String)}
    Assert ($guestSource -match '\[Parameter\(Position=0\)\]\[ValidateSet\(''prepare'',''prepare-register'',''finalize'',''finalize-wait'',''guard'',''view''\)\]') 'The guest file accepts exactly the six documented modes'
    Assert (-not $ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Build-SetupLauncher'},$false)) 'Builder has no executable compilation stage'
    foreach($folder in 'data','tools'){
        Assert (-not (Test-Path -LiteralPath (Join-Path $repo $folder))) "The builder needs no $folder folder beside it"
    }
    Assert (-not @(Get-ChildItem -LiteralPath $repo -Filter *.cs -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike (Join-Path $repo '.ai*') }).Count) 'No custom launcher source remains in the repository'

    foreach($case in @(
        @{Mode='prepare';Exit=17},@{Mode='prepare-register';Exit=0},
        @{Mode='finalize';Exit=0},@{Mode='finalize-wait';Exit=5},@{Mode='guard';Exit=0})){
        $directory=Join-Path $root ("$($case.Mode) папка & ' !");$null=New-Item -ItemType Directory -Path $directory
        $guest=Join-Path $directory 'Win11Lite.ps1'
        [IO.File]::WriteAllText($guest,$fixtureGuest,[Text.UTF8Encoding]::new($true))
        $launcher=Join-Path $directory 'Run-Setup.vbs'
        [IO.File]::WriteAllText($launcher,(Get-SetupVbsScript),[Text.Encoding]::ASCII)
        $psi=New-VbsProcess $launcher $case.Mode $directory;$psi.EnvironmentVariables['RUNNER_TEST_EXIT']=[string]$case.Exit
        $process=[Diagnostics.Process]::Start($psi)
        try{
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(30000)){$process.Kill();throw 'Runner fixture timed out'}
            Assert ($process.ExitCode -eq $case.Exit) "Child exit code reaches the caller: $($case.Mode)"
            Assert ($stdout.GetAwaiter().GetResult().Length -eq 0 -and $stderr.GetAwaiter().GetResult().Length -eq 0) 'Runner writes diagnostics to a file'
            $actual=Get-Content -LiteralPath (Join-Path $directory 'result.json') -Raw|ConvertFrom-Json
            $initial=Get-Content -LiteralPath (Join-Path $directory 'initial-window.json') -Raw|ConvertFrom-Json
            Assert (-not $initial.Visible) 'VBS hides the initial PowerShell console before the worker is created'
            Assert ($actual.ConsoleWindow -eq 0) 'Runner child has no console window'
            Assert ($actual.Mode -eq $case.Mode -and $actual.Direct) 'The child runs the same file with the requested mode and does its work in process'
            Assert ($actual.Directory -eq $directory -and $actual.WorkingDirectory -eq $directory) 'Quoted paths and the working directory reach the child'
            $vbsLog=Get-Content -LiteralPath (Get-FixtureLogPath $directory) -Raw
            Assert ($vbsLog -match ('END mode='+$case.Mode+' ExitCode='+$case.Exit)) 'VBS records and returns the PowerShell exit code'
            $log=Get-Content -LiteralPath (Get-FixtureLogPath $directory) -Raw
            Assert ($log.Contains('Вывод для журнала') -and $log -match 'fixture stdout' -and $log -match 'fixture stderr') 'Russian output and stderr remain readable'
            Assert ($log -match "\[$($case.Mode)\] END ExitCode=$($case.Exit)") 'Completion status is logged against its mode'
            Assert ($log -match '\[vbs-launcher\]' -and $log -match '\[launcher\]' -and -not (Test-Path -LiteralPath (Join-Path $directory 'prepare.log'))) 'VBS and PowerShell use one daily file with identifiable sources'
        }finally{$process.Dispose()}
    }

    # The real SetupComplete template waits for each supported launcher.
    foreach($useVbsLauncher in $true,$false){
    $directory=Join-Path $root ('setupcomplete-'+$useVbsLauncher);$null=New-Item -ItemType Directory -Path $directory
    $guest=Join-Path $directory 'Win11Lite.ps1';[IO.File]::WriteAllText($guest,$fixtureGuest,[Text.UTF8Encoding]::new($true))
    $launcher=Join-Path $directory 'Run-Setup.vbs';[IO.File]::WriteAllText($launcher,(Get-SetupVbsScript),[Text.Encoding]::ASCII)
    $registerCommand=Get-SetupEntryCommand -Mode prepare-register -UseVbs $useVbsLauncher
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$setupComplete'},$true)
    . ([scriptblock]::Create($node.Extent.Text))
    Assert ($setupComplete.Contains($registerCommand)) 'SetupComplete uses the chosen setup launcher'
    $setupComplete=$setupComplete.Replace('%SystemRoot%\Setup\Scripts\Win11Lite\Run-Setup.vbs',$launcher).Replace('%SystemRoot%\Setup\Scripts\Win11Lite\Win11Lite.ps1',$guest).Replace('%SystemRoot%\Setup\Scripts\Win11Lite\setupcomplete.log',(Join-Path $directory 'setupcomplete.log'))
    $batch=Join-Path $directory 'SetupComplete.cmd';Write-WindowsBatchFile -Path $batch -Content $setupComplete
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=Join-Path $env:SystemRoot 'System32\cmd.exe';$psi.Arguments='/d /s /c ""'+$batch+'""'
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    foreach($pair in @{RUNNER_TEST_EXIT='23';TEMP=$directory;TMP=$directory}.GetEnumerator()){$psi.EnvironmentVariables[$pair.Key]=$pair.Value}
    $process=[Diagnostics.Process]::Start($psi)
    try{
        if(-not $process.WaitForExit(30000)){$process.Kill();throw 'SetupComplete fixture timed out'}
        Assert ($process.ExitCode -eq 23) 'SetupComplete waits for PowerShell and retains the guest exit code'

    }finally{$process.Dispose()}
    }
    foreach($template in @{oobeNetBlock='prepare';unattendXml='finalize'}.GetEnumerator()){
        $node=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$'+$template.Key)},$true)
        if(-not $node){throw "Missing answer-file template: $($template.Key)"}
        Assert ($node.Extent.Text.Contains('$'+$template.Value+'Command<')) "The answer file uses the chosen launcher for $($template.Value)"
    }

    $engineFixture=Join-Path $root 'engine\Windows\System32';$null=New-Item -ItemType Directory -Path $engineFixture
    foreach($file in 'wscript.exe','vbscript.dll'){[IO.File]::WriteAllText((Join-Path $engineFixture $file),'fixture')}
    Assert (Test-ImageVbsLauncher -Image (Join-Path $root 'engine')) 'Every preset uses VBS when the image contains its host and engine'
    $hostOnly=Join-Path $root 'host-only\Windows\System32';$null=New-Item -ItemType Directory -Path $hostOnly
    [IO.File]::WriteAllText((Join-Path $hostOnly 'wscript.exe'),'fixture')
    Assert (-not (Test-ImageVbsLauncher -Image (Join-Path $root 'host-only'))) 'The script host without its VBScript engine cannot select VBS'
    Assert (-not (Test-ImageVbsLauncher -Image (Join-Path $root 'absent-engine'))) 'An image without VBScript uses the working PowerShell fallback'
    foreach($mode in 'prepare','prepare-register','finalize'){
        Assert ((Get-SetupEntryCommand -Mode $mode -UseVbs $true) -match ('wscript\.exe" //B //NoLogo .*Run-Setup\.vbs" '+$mode+'$')) 'VBS entry points use the GUI host in batch mode'
        Assert ((Get-SetupEntryCommand -Mode $mode -UseVbs $false) -match ('powershell\.exe" .*Win11Lite\.ps1" -Mode '+$mode+'$')) 'Fallback entry points still use the same guest PowerShell file'
    }

    # Rejected requests must fail loudly instead of silently doing nothing.
    $empty=Join-Path $root 'empty';$null=New-Item -ItemType Directory -Path $empty
    $guest=Join-Path $empty 'Win11Lite.ps1';[IO.File]::WriteAllText($guest,$fixtureGuest,[Text.UTF8Encoding]::new($true))
    foreach($case in @(@{Arguments='';Exit=87},@{Arguments='-Mode unknown';Exit=1},@{Arguments='-Mode prepare extra';Exit=87})){
        $process=[Diagnostics.Process]::Start((New-GuestProcess $guest $case.Arguments $empty))
        try{
            if(-not $process.WaitForExit(20000)){$process.Kill();throw 'Mode fixture timed out'}
            Assert ($process.ExitCode -eq $case.Exit) "A rejected request fails: '$($case.Arguments)'"
        }finally{$process.Dispose()}
    }
    $rejected=Get-Content -LiteralPath (Get-FixtureLogPath $empty) -Raw
    Assert ($rejected -match "Unsupported request: Mode=''; extra=''" -and $rejected -match "extra='extra'") 'Both a missing mode and an unexpected argument are recorded before exiting'
    $launcher=Join-Path $empty 'Run-Setup.vbs';[IO.File]::WriteAllText($launcher,(Get-SetupVbsScript),[Text.Encoding]::ASCII)
    foreach($arguments in '', 'unknown', 'prepare extra', 'view'){
        $process=[Diagnostics.Process]::Start((New-VbsProcess $launcher $arguments $empty))
        try{
            if(-not $process.WaitForExit(20000)){$process.Kill();throw 'VBS rejection fixture timed out'}
            Assert ($process.ExitCode -eq 87) "VBS rejects unsupported arguments: '$arguments'"
        }finally{$process.Dispose()}
    }
    Assert (-not (Test-Path -LiteralPath (Join-Path $empty 'result.json'))) 'Rejected VBS requests never execute the guest worker'
    $missing=Join-Path $root 'missing-guest';$null=New-Item -ItemType Directory -Path $missing
    $logFolder=Join-Path $missing 'Logs';$null=New-Item -ItemType Directory -Path $logFolder
    $expiredLog=Join-Path $logFolder ((Get-Date).Date.AddDays(-30).ToString('yyyy-MM-dd')+'.log')
    $retainedLog=Join-Path $logFolder ((Get-Date).Date.AddDays(-29).ToString('yyyy-MM-dd')+'.log')
    $otherFile=Join-Path $logFolder '2000-01-01.txt'
    foreach($file in @($expiredLog,$retainedLog,$otherFile)){[IO.File]::WriteAllText($file,'fixture',[Text.Encoding]::Unicode)}
    $launcher=Join-Path $missing 'Run-Setup.vbs';[IO.File]::WriteAllText($launcher,(Get-SetupVbsScript),[Text.Encoding]::ASCII)
    $process=[Diagnostics.Process]::Start((New-VbsProcess $launcher 'prepare' $missing))
    try{
        if(-not $process.WaitForExit(20000)){$process.Kill();throw 'Missing guest fixture timed out'}
        Assert ($process.ExitCode -eq 2 -and (Get-Content -LiteralPath (Get-FixtureLogPath $missing)) -match 'Win11Lite.ps1 is missing') 'Missing PowerShell payload produces a logged error and nonzero exit'
        Assert (-not (Test-Path -LiteralPath $expiredLog) -and (Test-Path -LiteralPath $retainedLog)) 'Standalone VBS applies the same today-plus-29-days retention without the PS payload'
        Assert ([IO.File]::ReadAllText($otherFile) -eq 'fixture') 'Standalone VBS retention does not delete unrelated files'
    }finally{$process.Dispose()}
    Write-Host "PASS: $script:checks runner checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $full=[IO.Path]::GetFullPath($root);$base=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\runner-tests-'
    if($full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){for($attempt=0;$attempt -lt 5;$attempt++){try{Remove-Item -LiteralPath $full -Recurse -Force;break}catch{if($attempt -eq 4){throw};Start-Sleep -Milliseconds 250}}}
}
