#Requires -Version 5.1
# No real guard, registry changes, task registration, or system-file removal.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
# Load the report helpers straight out of the embedded guest runtime.
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
$accessor=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-GuestScript'},$false)
if(-not $accessor){throw 'Missing Get-GuestScript'}
. ([scriptblock]::Create($accessor.Extent.Text))
$guestAst=[Management.Automation.Language.Parser]::ParseInput((Get-GuestScript),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
foreach($name in 'Get-GuardMode','Get-GuardExpectedApps','Get-GuardBriefReport','Start-GuardViewer','Show-GuardView','New-GuardViewerAction','Register-GuardViewerTask','Remove-GuardSelectedPath'){
    $node=$guestAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    if(-not $node){throw "Missing guest function: $name"}
    . ([scriptblock]::Create($node.Extent.Text))
}
$config=@{Language='ru-RU'}
function T {param($Ru,$En)if($config.Language -like 'ru*'){$Ru}else{$En}}
$script:checks=0
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw "FAIL: $Message"};$script:checks++}
function Assert-Throws([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed $Message}
$testRoot=Join-Path $repo ('tmp\guard-modes-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
try{
    Assert ((Get-GuardMode @{}) -eq 'Standard') 'Missing legacy mode defaults to Standard'
    Assert ((Get-GuardMode @{Mode='Silent'}) -eq 'Silent') 'Silent mode is read from the installed configuration'
    $report=@{Started=(Get-Date).ToString('o');Complete=$true;Deferred=$false;Errors=3;LogErrors=0;ViewErrors=0;Warnings=@();Items=@(
        [pscustomobject]@{Category='app';Name='AppA';Outcome='removed';Found=$true;Repeated=$true;Reappeared=$true},
        [pscustomobject]@{Category='provisioned';Name='AppA';Outcome='pending';Found=$true;Reappeared=$true},
        [pscustomobject]@{Category='app';Name='AppB';Outcome='absent';Found=$false},
        [pscustomobject]@{Category='provisioned';Name='AppB';Outcome='absent';Found=$false},
        [pscustomobject]@{Category='component';Name='Microsoft Edge';Outcome='absent';Found=$false},
        [pscustomobject]@{Category='app';Name='Reading apps';Outcome='failed';Found=$null;Inventory=$true},
        [pscustomobject]@{Category='setting';Name='DisableSomething';Outcome='compliant';Found=$true},
        [pscustomobject]@{Category='setting';Name='AllowTelemetry';Outcome='created';Found=$false;Repeated=$false;Reappeared=$false},
        [pscustomobject]@{Category='service';Name='TestSvc';Outcome='failed';Found=$true;Repeated=$false;Reappeared=$true;ErrorCode='0x80070005'},
        [pscustomobject]@{Category='path';Name='Windows\diagnostics';Outcome='failed';Found=$true;Detail='C:\Windows\diagnostics; HRESULT=0x80070057; raw stack'}
    )}
    $brief=Get-GuardBriefReport $report $true
    Assert ($brief.Counts.Programs -eq 3) 'Programs are deduplicated across installed and provisioned packages; inventory errors are excluded'
    Assert ($brief.Counts.ProgramsReappeared -eq 1 -and $brief.Counts.ProgramsRemovedAgain -eq 0) 'An unfinished provisioned removal prevents claiming the whole app was removed'
    Assert ($brief.Counts.Settings -eq 3 -and $brief.Counts.SettingsReappeared -eq 1 -and $brief.Counts.SettingsRestoredAgain -eq 0) 'A re-enabled service is counted even if disabling it failed'
    Assert ($brief.Text -match 'diagnostics' -and $brief.Text -match '0x80070057' -and $brief.Text -notmatch 'Windows\\|C:\\|HKLM:|raw stack') 'Short errors retain object names and error codes without full paths or technical stacks'
    $report.Items[1].Outcome='removed'
    $brief=Get-GuardBriefReport $report $true
    Assert ($brief.Counts.ProgramsRemovedAgain -eq 1) 'Only confirmed removals from both app inventories count as successful repetition'
    $brief=Get-GuardBriefReport $report $false
    Assert ($brief.Text -match 'Первый запуск: повторность пока неизвестна') 'The first observation explicitly states the history limitation'
    $report.Complete=$false
    Assert ((Get-GuardBriefReport $report $true).Text -match 'Проверка не завершена') 'An interrupted check is never presented as complete'
    $report.Complete=$true

    & {
        $state=@{Oobe=$true;Connect=0;Launches=[Collections.Generic.List[object]]::new()}
        function Test-GuardOobeComplete {$state.Oobe}
        function Get-Process {param($Name,[switch]$IncludeUserName,$ErrorAction)@(
            [pscustomobject]@{SessionId=0;UserName='NT AUTHORITY\SYSTEM'},
            [pscustomobject]@{SessionId=1;UserName='PC\User'},
            [pscustomobject]@{SessionId=1;UserName='PC\User'},
            [pscustomobject]@{SessionId=2;UserName='PC\defaultuser0'}
        )}
        $fakeTask=[pscustomobject]@{Enabled=$true}
        $fakeTask|Add-Member ScriptMethod RunEx {param($Run,$Flags,$Session,$User)$state.Launches.Add(@{Run=$Run;Flags=$Flags;Session=$Session;User=$User})}
        $folder=[pscustomobject]@{};$folder|Add-Member ScriptMethod GetTask {param($Name)if($Name -ne 'win-11-lite guard report'){throw 'Unexpected task'};$fakeTask}
        $scheduler=[pscustomobject]@{};$scheduler|Add-Member ScriptMethod Connect {$state.Connect++};$scheduler|Add-Member ScriptMethod GetFolder {param($Path)$folder}
        function New-Object {param($ComObject)if($ComObject -ne 'Schedule.Service'){throw 'Unexpected COM activation'};$scheduler}
        $run=[guid]::NewGuid()
        Start-GuardViewer $testRoot $run Silent
        Assert ($state.Connect -eq 0 -and -not $state.Launches.Count) 'Silent mode does not connect to the scheduler or create a viewer process'
        $state.Oobe=$false;Start-GuardViewer $testRoot $run Standard
        Assert ($state.Connect -eq 0) 'OOBE prevents even demand-start viewer activation'
        $state.Oobe=$true;Start-GuardViewer $testRoot $run Standard
        Assert ($state.Launches.Count -eq 1 -and $state.Launches[0].Session -eq 1 -and $state.Launches[0].Flags -eq 4 -and $null -eq $state.Launches[0].User) 'Only real desktop sessions receive the report under their logged-on user token'
        Assert ($state.Launches[0].Run -eq $run.ToString()) 'The report task receives the exact worker run ID'
        $fakeTask.Enabled=$false;Start-GuardViewer $testRoot $run Debug
        Assert ($state.Launches.Count -eq 1) 'A manually disabled report task is respected'
    }
    & {
        function Test-GuardOobeComplete {$true}
        $shown=[Collections.Generic.List[string]]::new()
        function Write-Host {param($Object,$ForegroundColor)$shown.Add([string]$Object)}
        function Read-Host {param($Prompt)''}
        $current=[guid]::NewGuid().ToString();$old=[guid]::NewGuid().ToString()
        $reportPath=Join-Path $testRoot 'guard-report.json'
        @{RunId=$current;BriefText='only this summary'}|ConvertTo-Json|Set-Content -LiteralPath $reportPath -Encoding UTF8
        Show-GuardView $testRoot Standard $current 1
        Assert ($shown.Count -eq 1 -and $shown[0] -eq 'only this summary') 'Standard displays one completed summary without the live log'
        $shown.Clear()
        Assert-Throws {Show-GuardView $testRoot Standard $old 0} 'A mismatched prior report cannot be shown as the result of this run'
        Assert (-not $shown.Count) 'A stale report produces no successful summary'
        Show-GuardView $testRoot Silent $current 0
        Assert (-not $shown.Count) 'A manual Silent viewer call also produces no output'
    }
    # The deletion fallback runs only on our own test files.
    $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'data\guard.ps1'),[ref]$t,[ref]$e)
    $function=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-GuardSelectedPath'},$false)
    . ([scriptblock]::Create($function.Extent.Text))
    & {
        $selected=Join-Path $testRoot 'selected';$null=New-Item -ItemType Directory -Path $selected
        $victim=Join-Path $selected 'payload.dll';Set-Content -LiteralPath $victim -Value 'test payload'
        $outside=Join-Path $testRoot 'outside.dll';Set-Content -LiteralPath $outside -Value 'keep'
        $state=@{Target=$victim;Calls=0;PlainAccessError=$false}
        function Write-GuardLog {param($Level,$Message)}
        function Remove-Item {
            [CmdletBinding()]param($LiteralPath,[switch]$Recurse,[switch]$Force)
            if(-not ([IO.Path]::GetFullPath($LiteralPath)).StartsWith($testRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture path'}
            $state.Calls++
            if(Test-Path -LiteralPath $state.Target){
                if($state.PlainAccessError){throw [UnauthorizedAccessException]::new('mock denied')}
                $PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new([ArgumentException]::new('mock attribute failure'),'RemoveFileSystemItemArgumentError',[Management.Automation.ErrorCategory]::InvalidArgument,[IO.FileInfo]::new($state.Target)))
            }
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force -ErrorAction Stop
        }
        $observation=@{Detail='';Step=''}
        Remove-GuardSelectedPath $selected $true $observation
        Assert (-not(Test-Path -LiteralPath $selected) -and (Test-Path -LiteralPath $outside) -and $state.Calls -eq 2) 'The attribute-error fallback deletes the one failed file and resumes removal of the selected directory'
        $null=New-Item -ItemType Directory -Path $selected
        $state.Target=$outside
        Assert-Throws {Remove-GuardSelectedPath $selected $true $observation} 'A provider target outside the selected directory cannot be removed'
        Assert (Test-Path -LiteralPath $outside) 'An out-of-scope file survives the fallback'
        Set-Content -LiteralPath $victim -Value 'test payload';$state.Target=$victim;$state.PlainAccessError=$true
        Assert-Throws {Remove-GuardSelectedPath $selected $true $observation} 'An ordinary access-denied error does not trigger the attribute fallback'
        Assert (Test-Path -LiteralPath $victim) 'An ordinary permission failure leaves the protected fixture unchanged'
        $external=Join-Path $testRoot 'external';$null=New-Item -ItemType Directory -Path $external
        $survivor=Join-Path $external 'survivor.dll';Set-Content -LiteralPath $survivor -Value 'keep'
        $junction=Join-Path $selected 'linked';$null=New-Item -ItemType Junction -Path $junction -Target $external
        $state.Target=Join-Path $junction 'survivor.dll';$state.PlainAccessError=$false
        Assert-Throws {Remove-GuardSelectedPath $selected $true $observation} 'The retry cannot traverse a nested directory junction'
        Assert (Test-Path -LiteralPath $survivor) 'A file behind a nested junction survives the retry'
    }
    Write-Host "PASS: $script:checks guard mode checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $full=[IO.Path]::GetFullPath($testRoot);$base=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\guard-modes-'
    if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected test directory'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
