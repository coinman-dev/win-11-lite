#Requires -Version 5.1
# Compiles/runs the real GUI launcher with inert fixture scripts only.
# No Prepare/Finalize/guard operations, services, firewall or registry changes.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
foreach($name in @('T','Write-DiagnosticLog','Get-ProgressLine','Write-ProgressBar','Update-ProgressState','Invoke-ProgressProcess','Assert-ChildPath','Read-PreparedCache','Write-PreparedCache','Build-SetupLauncher','Write-WindowsBatchFile')){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:Lang='en';$script:ScriptRoot=$repo;$script:CanDrawProgress=$false
$script:checks=0
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
function Assert-Throws([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed $Message}
$root=Join-Path $repo ('tmp\launcher-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
try{
    $exe=Build-SetupLauncher -Directory $root
    $bytes=[IO.File]::ReadAllBytes($exe);$pe=[BitConverter]::ToInt32($bytes,0x3c)
    Assert ([BitConverter]::ToUInt16($bytes,$pe+4) -eq 0x8664) 'Launcher is built for x64 Windows'
    Assert ([BitConverter]::ToUInt16($bytes,$pe+24+68) -eq 2) 'Launcher has Windows GUI subsystem, so Windows does not allocate a startup console'
    & {
        function Invoke-ProgressProcess {throw 'Cached launcher must not recompile'}
        Assert ((Build-SetupLauncher -Directory $root) -eq $exe) 'Verified launcher cache avoids another compiler invocation'
    }
    $fixture=@'
param([switch]$RegisterOnly,[switch]$FirstLogon,[switch]$WaitForOobe,[switch]$ShowDebugWindow)
$ErrorActionPreference='Stop'
Add-Type 'using System; using System.Runtime.InteropServices; public static class ConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
$result=[ordered]@{
    Script=$MyInvocation.MyCommand.Name
    Directory=$PSScriptRoot
    WorkingDirectory=$PWD.Path
    ConsoleWindow=[ConsoleProbe]::GetConsoleWindow().ToInt64()
    OutputCodePage=[Console]::OutputEncoding.CodePage
    RegisterOnly=[bool]$RegisterOnly
    FirstLogon=[bool]$FirstLogon
    WaitForOobe=[bool]$WaitForOobe
    ShowDebugWindow=[bool]$ShowDebugWindow
}
$result|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'result.json') -Encoding UTF8
[Console]::WriteLine('fixture stdout')
[Console]::WriteLine('Вывод для журнала')
[Console]::Error.WriteLine('fixture stderr')
exit ([int]$env:LAUNCHER_TEST_EXIT)
'@
    $cases=@(
        @{Mode='prepare';Script='Prepare.ps1';Flag='';Exit=17},
        @{Mode='prepare-register';Script='Prepare.ps1';Flag='RegisterOnly';Exit=0},
        @{Mode='finalize';Script='Finalize.ps1';Flag='FirstLogon';Exit=0},
        @{Mode='finalize-wait';Script='Finalize.ps1';Flag='WaitForOobe';Exit=5},
        @{Mode='guard';Script='guard.ps1';Flag='';Exit=0},
        @{Mode='guard-debug';Script='guard.ps1';Flag='ShowDebugWindow';Exit=0}
    )
    foreach($case in $cases){
        $dir=Join-Path $root ("$($case.Mode) папка & ' !")
        $null=New-Item -ItemType Directory -Path $dir
        $localExe=Join-Path $dir 'Win11Lite.Run.exe'
        Copy-Item -LiteralPath $exe -Destination $localExe
        [IO.File]::WriteAllText((Join-Path $dir $case.Script),$fixture,[Text.UTF8Encoding]::new($true))
        $psi=[Diagnostics.ProcessStartInfo]::new()
        $psi.FileName=$localExe;$psi.Arguments=$case.Mode;$psi.WorkingDirectory=$root
        $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        $psi.EnvironmentVariables['TEMP']=$dir;$psi.EnvironmentVariables['TMP']=$dir
        $psi.EnvironmentVariables['LAUNCHER_TEST_EXIT']=[string]$case.Exit
        $process=[Diagnostics.Process]::Start($psi)
        try{
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(20000)){$process.Kill();throw 'Fixture launcher timed out'}
            Assert ($process.ExitCode -eq $case.Exit) "Child exit code reaches the caller ($($case.Mode))"
            Assert ($stdout.GetAwaiter().GetResult().Length -eq 0 -and $stderr.GetAwaiter().GetResult().Length -eq 0) "No console output escapes the launcher ($($case.Mode))"
            $actual=Get-Content -LiteralPath (Join-Path $dir 'result.json') -Raw|ConvertFrom-Json
            Assert ($actual.ConsoleWindow -eq 0) "Child PowerShell actually has no console window ($($case.Mode))"
            Assert ($actual.Script -eq $case.Script -and $actual.Directory -eq $dir -and $actual.WorkingDirectory -eq $dir) "Mode and quoted paths reach the intended fixture ($($case.Mode))"
            $flags=@('RegisterOnly','FirstLogon','WaitForOobe','ShowDebugWindow')
            Assert (@($flags|Where-Object{[bool]$actual.$_ -ne ($_ -eq $case.Flag)}).Count -eq 0) "Only the intended switch is passed ($($case.Mode))"
            $log=Get-Content -LiteralPath (Join-Path $dir 'launcher.log') -Raw
            Assert ($log -match 'fixture stdout' -and $log -match 'fixture stderr' -and $log -match "END ExitCode=$($case.Exit)") "Hidden output and completion remain in a file ($($case.Mode))"
            Assert ($log.Contains('Вывод для журнала')) "Russian output remains readable in the launcher log ($($case.Mode)); child encoding=$($actual.OutputCodePage); log=$log"
        }finally{$process.Dispose()}
    }
    # SetupComplete is a batch entry point: verify waiting and exit propagation.
    $setupDir=Join-Path $root 'setupcomplete'
    $null=New-Item -ItemType Directory -Path $setupDir
    $localExe=Join-Path $setupDir 'Win11Lite.Run.exe';Copy-Item -LiteralPath $exe -Destination $localExe
    [IO.File]::WriteAllText((Join-Path $setupDir 'Prepare.ps1'),'param([switch]$RegisterOnly) Start-Sleep -Milliseconds 400; exit 23',[Text.UTF8Encoding]::new($true))
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$setupComplete'},$true)
    . ([scriptblock]::Create($node.Extent.Text))
    $setupComplete=$setupComplete.Replace('%SystemRoot%\Setup\Scripts\Win11Lite\Win11Lite.Run.exe',$localExe).Replace('%SystemRoot%\Setup\Scripts\Win11Lite\setupcomplete.log',(Join-Path $setupDir 'setupcomplete.log'))
    $batch=Join-Path $setupDir 'SetupComplete.cmd';Write-WindowsBatchFile -Path $batch -Content $setupComplete
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName="$env:SystemRoot\System32\cmd.exe";$psi.Arguments='/d /s /c ""'+$batch+'""'
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($psi)
    try{if(-not $process.WaitForExit(15000)){$process.Kill();throw 'SetupComplete fixture timed out'};Assert ($process.ExitCode -eq 23) 'SetupComplete waits for the GUI process and preserves its exit code'}finally{$process.Dispose()}
    foreach($mode in @('unknown','prepare extra','guard')){
        $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$exe;$psi.Arguments=$mode;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        $process=[Diagnostics.Process]::Start($psi)
        try{if(-not $process.WaitForExit(5000)){$process.Kill();throw 'Invalid-mode fixture timed out'};Assert ($process.ExitCode -eq $(if($mode -eq 'guard'){2}else{87})) "Unsupported modes and missing scripts fail without a popup ($mode)"}finally{$process.Dispose()}
    }
    & {
        # Replace only the read-only OOBE API in a fixture build; production source is unchanged.
        $script:ScriptRoot=Join-Path $root 'delayed-oobe-source';$null=New-Item -ItemType Directory -Path (Join-Path $script:ScriptRoot 'data')
        $source=[IO.File]::ReadAllText((Join-Path $repo 'data\SetupLauncher.cs'))
        $pattern='(?s)\[DllImport\("kernel32\.dll", SetLastError = true\)\]\s*\[return: MarshalAs\(UnmanagedType\.Bool\)\]\s*private static extern bool OOBEComplete\(\[MarshalAs\(UnmanagedType\.Bool\)\] out bool complete\);'
        $substitute='private static readonly DateTime ReadyAt = DateTime.UtcNow.AddSeconds(1); private static bool OOBEComplete(out bool complete) { complete = DateTime.UtcNow >= ReadyAt; return true; }'
        $modified=[regex]::Replace($source,$pattern,$substitute)
        Assert ($modified -ne $source) 'Only the OOBE probe is replaced for the delayed-completion fixture'
        [IO.File]::WriteAllText((Join-Path $script:ScriptRoot 'data\SetupLauncher.cs'),$modified)
        $delayed=Build-SetupLauncher -Directory (Join-Path $root 'delayed-oobe-cache')
        $dir=Split-Path $delayed -Parent
        [IO.File]::WriteAllText((Join-Path $dir 'guard.ps1'),'param([switch]$ShowDebugWindow) exit 0',[Text.UTF8Encoding]::new($true))
        $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$delayed;$psi.Arguments='guard-debug';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        $timer=[Diagnostics.Stopwatch]::StartNew();$process=[Diagnostics.Process]::Start($psi)
        try{
            if(-not $process.WaitForExit(10000)){$process.Kill();throw 'Delayed OOBE fixture timed out'}
            Assert ($process.ExitCode -eq 0 -and $timer.ElapsedMilliseconds -ge 900) 'Debug observer waits for OOBE completion before launching'
            $log=Get-Content -LiteralPath (Join-Path $dir 'launcher.log') -Raw
            Assert ($log.IndexOf('WAIT OOBE') -ge 0 -and $log.IndexOf('WAIT OOBE') -lt $log.IndexOf('START PID')) 'OOBE gate runs before the observer PowerShell process exists'
        }finally{$process.Dispose()}
    }
    & {
        $script:ScriptRoot=Join-Path $root 'invalid-source';$null=New-Item -ItemType Directory -Path (Join-Path $script:ScriptRoot 'data')
        [IO.File]::WriteAllText((Join-Path $script:ScriptRoot 'data\SetupLauncher.cs'),'invalid C# source')
        Assert-Throws {Build-SetupLauncher -Directory (Join-Path $root 'invalid-cache')} 'Compiler failure is caught before image servicing'
        Assert (-not (Read-PreparedCache -Directory (Join-Path $root 'invalid-cache\setup-launcher') -Key 'launcher')) 'Failed compilation never creates a ready cache entry'
    }
    Write-Host "PASS: $script:checks launcher checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $safe=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\launcher-tests-'
    $full=[IO.Path]::GetFullPath($root)
    if($full.StartsWith($safe,[StringComparison]::OrdinalIgnoreCase)){
        for($attempt=0;$attempt -lt 5;$attempt++){
            try{Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop;break}
            catch{if($attempt -eq 4){throw};Start-Sleep -Milliseconds 250}
        }
    }
}
