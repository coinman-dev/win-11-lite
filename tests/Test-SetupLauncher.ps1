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
foreach($name in 'T','Get-GuestScript','Write-WindowsBatchFile'){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    if(-not $node){throw "Missing function: $name"}
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:ScriptRoot=$repo;$script:Lang='en';$Guard='Standard';$script:checks=0
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw "FAIL: $Message"};$script:checks++}
$root=Join-Path $repo ('tmp\runner-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function New-GuestProcess([string]$Guest,[string]$Arguments,[string]$Directory){
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$powershell
    $psi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Guest+'" '+$Arguments
    $psi.WorkingDirectory=$Directory;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
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
if (-not $Direct) { exit (Start-GuestChild -ChildMode $Mode) }
Add-Type 'using System; using System.Runtime.InteropServices; public static class ConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
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
        $psi=New-GuestProcess $guest ('-Mode '+$case.Mode) $directory;$psi.EnvironmentVariables['RUNNER_TEST_EXIT']=[string]$case.Exit
        $process=[Diagnostics.Process]::Start($psi)
        try{
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(30000)){$process.Kill();throw 'Runner fixture timed out'}
            Assert ($process.ExitCode -eq $case.Exit) "Child exit code reaches the caller: $($case.Mode)"
            Assert ($stdout.GetAwaiter().GetResult().Length -eq 0 -and $stderr.GetAwaiter().GetResult().Length -eq 0) 'Runner writes diagnostics to a file'
            $actual=Get-Content -LiteralPath (Join-Path $directory 'result.json') -Raw|ConvertFrom-Json
            Assert ($actual.ConsoleWindow -eq 0) 'Runner child has no console window'
            Assert ($actual.Mode -eq $case.Mode -and $actual.Direct) 'The child runs the same file with the requested mode and does its work in process'
            Assert ($actual.Directory -eq $directory -and $actual.WorkingDirectory -eq $directory) 'Quoted paths and the working directory reach the child'
            $log=Get-Content -LiteralPath (Join-Path $directory 'launcher.log') -Raw
            Assert ($log.Contains('Вывод для журнала') -and $log -match 'fixture stdout' -and $log -match 'fixture stderr') 'Russian output and stderr remain readable'
            Assert ($log -match "\[$($case.Mode)\] END ExitCode=$($case.Exit)") 'Completion status is logged against its mode'
            Assert (-not (Test-Path -LiteralPath (Join-Path $directory 'prepare.log'))) 'The runner keeps its own log separate from the work logs'
        }finally{$process.Dispose()}
    }

    # The answer file and SetupComplete start the same file by mode.
    $directory=Join-Path $root 'setupcomplete';$null=New-Item -ItemType Directory -Path $directory
    $guest=Join-Path $directory 'Win11Lite.ps1';[IO.File]::WriteAllText($guest,$fixtureGuest,[Text.UTF8Encoding]::new($true))
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$setupComplete'},$true)
    . ([scriptblock]::Create($node.Extent.Text))
    Assert ($setupComplete -match 'Win11Lite\\Win11Lite\.ps1" -Mode prepare-register') 'SetupComplete registers through the single guest file'
    $setupComplete=$setupComplete.Replace('%SystemRoot%\Setup\Scripts\Win11Lite\Win11Lite.ps1',$guest).Replace('%SystemRoot%\Setup\Scripts\Win11Lite\setupcomplete.log',(Join-Path $directory 'setupcomplete.log'))
    $batch=Join-Path $directory 'SetupComplete.cmd';Write-WindowsBatchFile -Path $batch -Content $setupComplete
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=Join-Path $env:SystemRoot 'System32\cmd.exe';$psi.Arguments='/d /s /c ""'+$batch+'""'
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    foreach($pair in @{RUNNER_TEST_EXIT='23';TEMP=$directory;TMP=$directory}.GetEnumerator()){$psi.EnvironmentVariables[$pair.Key]=$pair.Value}
    $process=[Diagnostics.Process]::Start($psi)
    try{
        if(-not $process.WaitForExit(30000)){$process.Kill();throw 'SetupComplete fixture timed out'}
        Assert ($process.ExitCode -eq 23) 'SetupComplete waits for PowerShell and retains the guest exit code'

    }finally{$process.Dispose()}
    foreach($template in @{oobeNetBlock='prepare';unattendXml='finalize'}.GetEnumerator()){
        $node=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$'+$template.Key)},$true)
        if(-not $node){throw "Missing answer-file template: $($template.Key)"}
        Assert ($node.Extent.Text -match ('Win11Lite\\Win11Lite\.ps1" -Mode '+$template.Value+'<')) "The answer file starts the same guest file for $($template.Value)"
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
    $rejected=Get-Content -LiteralPath (Join-Path $empty 'launcher.log') -Raw
    Assert ($rejected -match "Unsupported request: Mode=''; extra=''" -and $rejected -match "extra='extra'") 'Both a missing mode and an unexpected argument are recorded before exiting'
    Write-Host "PASS: $script:checks runner checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $full=[IO.Path]::GetFullPath($root);$base=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\runner-tests-'
    if($full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){for($attempt=0;$attempt -lt 5;$attempt++){try{Remove-Item -LiteralPath $full -Recurse -Force;break}catch{if($attempt -eq 4){throw};Start-Sleep -Milliseconds 250}}}
}
