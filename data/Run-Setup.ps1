#Requires -Version 5.1
# Standard PowerShell entry point for Windows Setup and scheduled tasks.
param([string]$Mode, [Parameter(ValueFromRemainingArguments=$true)][string[]]$ExtraArguments)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$logPath=Join-Path $PSScriptRoot 'launcher.log'
function Write-RunnerLog {
    param([string]$Message)
    for($attempt=0;$attempt -lt 5;$attempt++){
        try{[IO.File]::AppendAllText($logPath,"$(Get-Date -Format s) [$Mode] $Message`r`n",[Text.UTF8Encoding]::new($true));return}
        catch [IO.IOException]{Start-Sleep -Milliseconds 50}
        catch [UnauthorizedAccessException]{return} # Limited debug observer can read the support folder.
    }
}
function Test-SetupOobeComplete {
    if(-not ('Win11Lite.RunnerOobe' -as [type])){
        Add-Type @'
using System.Runtime.InteropServices;
namespace Win11Lite {
    public static class RunnerOobe {
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool OOBEComplete([MarshalAs(UnmanagedType.Bool)] out bool complete);
    }
}
'@
    }
    $complete=$false
    if(-not [Win11Lite.RunnerOobe]::OOBEComplete([ref]$complete)){return $false}
    $complete
}
$entry=switch($Mode){
    'prepare'          {@{File='Prepare.ps1';Arguments=''}}
    'prepare-register' {@{File='Prepare.ps1';Arguments='-RegisterOnly'}}
    'finalize'         {@{File='Finalize.ps1';Arguments='-FirstLogon'}}
    'finalize-wait'    {@{File='Finalize.ps1';Arguments='-WaitForOobe'}}
    'guard'            {@{File='guard.ps1';Arguments=''}}
    'guard-debug'      {@{File='guard.ps1';Arguments='-ShowDebugWindow'}}
}
if(-not $entry -or $ExtraArguments.Count){Write-RunnerLog 'Unsupported mode';exit 87}
try{
    $scriptPath=Join-Path $PSScriptRoot $entry.File
    if(-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)){Write-RunnerLog "Script not found: $($entry.File)";exit 2}
    if($Mode -eq 'guard-debug'){
        $deadline=(Get-Date).AddHours(2);$waiting=$false
        while(-not (Test-SetupOobeComplete)){
            if(-not $waiting){Write-RunnerLog 'WAIT OOBE completion before opening the debug viewer';$waiting=$true}
            if((Get-Date) -ge $deadline){Write-RunnerLog 'OOBE wait timed out';exit 1460}
            Start-Sleep -Milliseconds 500
        }
    }
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$scriptPath+'" '+$entry.Arguments
    $psi.WorkingDirectory=$PSScriptRoot
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    # Windows PowerShell uses the system OEM code page when its output is redirected.
    $codePage=[int](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name OEMCP).OEMCP
    $psi.StandardOutputEncoding=[Text.Encoding]::GetEncoding($codePage)
    $psi.StandardErrorEncoding=$psi.StandardOutputEncoding
    $process=[Diagnostics.Process]::new();$process.StartInfo=$psi
    try{
        if(-not $process.Start()){throw 'PowerShell did not start'}
        Write-RunnerLog "START PID=$($process.Id)"
        $process.StandardInput.Close()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
        if($output.Trim()){Write-RunnerLog $output.Trim()}
        if($errorText.Trim()){Write-RunnerLog ('STDERR '+$errorText.Trim())}
        $code=$process.ExitCode;Write-RunnerLog "END ExitCode=$code"
    }finally{$process.Dispose()}
    exit $code
}catch{Write-RunnerLog ('ERROR '+($_|Out-String).Trim());exit 1}
