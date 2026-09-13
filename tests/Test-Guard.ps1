#Requires -Version 5.1
# Generated guard and task registration run with mocked Windows APIs only.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$script:ScriptRoot=$repo
$t=$null; $e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
$script:checks=0
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw "FAIL: $Message"};$script:checks++}
foreach($name in @('T','Test-GroupActive','Get-ProtectedPatterns','Get-GuardScript','Get-SetupSupportScripts')){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:Lang='en'; $script:ImageLanguages=@('en-US'); $AddLanguage=@(); $DownloadLanguage=@(); $RemoveExtra=@(); $Keep=@(); $Preset='balanced'; $imgLang='en-US'; $script:StartedAt=Get-Date; $GuardMode='Standard'
foreach($name in @('CapabilityRules','PackageRules','FolderRules','FileRules','AppxRules','NeverRemove','AppPlatformProtected','DisableServices','AiFolderPatterns')){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$script:'+$name)},$false)
    . ([scriptblock]::Create($node.Extent.Text))
}
$root=Join-Path $repo ('tmp\guard-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
Copy-Item -LiteralPath (Join-Path $repo 'data\Guard.UI.ps1') -Destination (Join-Path $root 'Guard.UI.ps1')
try{
    & {
        # Only the native-output helper runs here, with a harmless child script.
        # No takeown/icacls or guard system operations are invoked on the host.
        $guardAst=[Management.Automation.Language.Parser]::ParseInput((Get-GuardScript),[ref]$t,[ref]$e)
        if($e.Count){throw ($e|Out-String)}
        $helper=$guardAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-GuardAccessCommand'},$false)
        . ([scriptblock]::Create($helper.Extent.Text))
        $diagnostics=[Collections.Generic.List[string]]::new()
        function Write-GuardLog {param($Level,$Message)$diagnostics.Add($Message)}
        $probe=Join-Path $root 'native-stderr.ps1'
        Set-Content -LiteralPath $probe -Value '[Console]::Error.WriteLine("native stderr probe"); exit 7' -Encoding UTF8
        $observation=@{Step='';Detail=''}
        $unexpected=@(Invoke-GuardAccessCommand -FileName "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Arguments @('-NoProfile','-NonInteractive','-File',$probe) -Observation $observation)
        Assert ($observation.Detail -match 'ExitCode=7' -and $observation.Detail -match 'native stderr probe') 'Real native stderr and exit status are captured on both PowerShell runtimes'
        Assert (-not $unexpected.Count -and $diagnostics.Count -eq 1 -and $ErrorActionPreference -eq 'Stop') 'Native diagnostics do not leak to stdout or change the caller error preference'
    }
    # Evaluate the actual embedding block: rules -> guard.json + guard.ps1.
    $mountDir=Join-Path $root 'image'; $guardDir=Join-Path $mountDir 'Windows\Setup\Scripts\Win11Lite'; $Guard=$true
    function Write-Ok {param($Message)}
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$Guard' -and $n.Extent.Text -match '\$guardConfig ='},$true)
    & ([scriptblock]::Create($node.Extent.Text))
    $cfg=Get-Content -LiteralPath (Join-Path $guardDir 'guard.json') -Raw | ConvertFrom-Json
    Assert (Test-Path -LiteralPath (Join-Path $guardDir 'guard.ps1')) 'Guard is embedded into the image'
    Assert (@($cfg.Apps | Where-Object {'Microsoft.BingWeather' -match $_}).Count -gt 0) 'Consumer app rules reach guard'
    Assert (@($cfg.Capabilities | Where-Object {'App.StepsRecorder~~~~0.0.1.0' -match $_}).Count -gt 0) 'Build capability rules reach guard'
    Assert (-not @($cfg.Paths | Where-Object {$_ -match 'EdgeWebView|NativeImages|WinSxS\\Backup'}).Count) 'Balanced guard preserves WebView2, NGEN and component backups'
    Assert (@($cfg.Protected | Where-Object {'Microsoft.Windows.Sense.Client~~~~' -match $_}).Count -gt 0) 'Guard does not repeatedly uninstall permanent Sense capability'
    foreach($name in 'Microsoft.WindowsStore','Microsoft.StorePurchaseApp','Microsoft.DesktopAppInstaller','Microsoft.UI.Xaml.2.8','Microsoft.VCLibs.140.00.UWPDesktop','Microsoft.NET.Native.Runtime.2.2','Microsoft.WindowsAppRuntime.1.7'){
        Assert (@($cfg.Protected | Where-Object {$name -match $_}).Count -gt 0) "Balanced app platform protection reaches guard: $name"
    }
    Assert (-not @($cfg.Services | Where-Object {$_ -in @('AppXSvc','ClipSVC','InstallService','LicenseManager','StateRepository','AppReadiness','TokenBroker','BITS','wuauserv','DoSvc','mpssvc')}).Count) 'Guard does not disable application deployment, licensing or Store download services'
    $Keep=@('Apps','Speech'); $RemoveExtra=@('^Language')
    & ([scriptblock]::Create($node.Extent.Text))
    $kept=Get-Content -LiteralPath (Join-Path $guardDir 'guard.json') -Raw | ConvertFrom-Json
    Assert (-not @($kept.Apps | Where-Object {'Microsoft.BingWeather' -match $_}).Count) 'Keep Apps also applies to guard'
    Assert (@($kept.Protected | Where-Object {'Language.Speech~~~en-US~0.0.1.0' -match $_}).Count -gt 0) 'Keep Speech is protected even from RemoveExtra'
    $Keep=@(); $RemoveExtra=@()

    & {
        $tasks=@{}
        function New-ScheduledTaskAction {param($Execute,$Argument)[pscustomobject]@{Execute=$Execute;Argument=$Argument}}
        function New-ScheduledTaskTrigger {param([switch]$AtLogOn)[pscustomobject]@{Delay='';AtLogOn=[bool]$AtLogOn}}
        function New-ScheduledTaskPrincipal {param($UserId,$GroupId,$LogonType,$RunLevel)[pscustomobject]@{UserId=$UserId;GroupId=$GroupId;LogonType=$LogonType;RunLevel=$RunLevel}}
        function New-ScheduledTaskSettingsSet {param([switch]$StartWhenAvailable,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$MultipleInstances,$ExecutionTimeLimit)[pscustomobject]@{MultipleInstances=$MultipleInstances;Limit=$ExecutionTimeLimit}}
        function Register-ScheduledTask {param($TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force)$tasks[$TaskName]=[pscustomobject]@{Action=$Action;Trigger=$Trigger;Principal=$Principal;Settings=$Settings}}
        function Unregister-ScheduledTask {[CmdletBinding(SupportsShouldProcess)]param($TaskName)$tasks.Remove($TaskName)}
        $scripts=Get-SetupSupportScripts -BlockNetwork $false -RemoveEdge $true -EnableGuard $true -ShowGuardWindow $true
        $prepare=Join-Path $root 'Prepare.ps1'
        [IO.File]::WriteAllText($prepare,$scripts.Prepare,[Text.UTF8Encoding]::new($true))
        & $prepare -RegisterOnly
        Assert ($tasks.ContainsKey('win-11-lite guard') -and $tasks.ContainsKey('win-11-lite guard report')) 'Worker and report observer are registered'
        $worker=$tasks['win-11-lite guard']; $viewer=$tasks['win-11-lite guard report']
        Assert ($worker.Principal.UserId -eq 'S-1-5-18' -and $worker.Principal.LogonType -eq 'ServiceAccount') 'Worker retains SYSTEM privileges'
        Assert ($worker.Trigger.AtLogOn -and $worker.Settings.MultipleInstances -eq 'IgnoreNew') 'Worker triggers on logon and prevents overlap'
        Assert ($viewer.Principal.GroupId -eq 'S-1-5-32-545' -and $viewer.Principal.RunLevel -eq 'Limited') 'Observer uses the interactive user group without elevation'
        Assert ($viewer.Action.Argument -match 'guard\.ps1" -View -RunId' -and $viewer.Action.Execute -like '*\powershell.exe' -and -not $viewer.Trigger) 'Report task runs the viewer directly on demand without an intermediate logon process'
        $scripts=Get-SetupSupportScripts -BlockNetwork $false -RemoveEdge $true -EnableGuard $true -ShowGuardWindow $false
        [IO.File]::WriteAllText($prepare,$scripts.Prepare,[Text.UTF8Encoding]::new($true))
        & $prepare -RegisterOnly
        Assert ($tasks.ContainsKey('win-11-lite guard') -and -not $tasks.ContainsKey('win-11-lite guard report')) 'Silent mode removes only the observer'
    }

    & {
        $calls=[Collections.Generic.List[string]]::new()
        $fixture=@{Oobe=0;SetupReadFails=$false;Policy=1;MissingPolicy=$null;ServiceStart=4;DenyPolicy=$false;Cap='Installed';DenyCap=$false;PendingCap=$false;InventoryFails=$false;App=$true;Provisioned=$true;WatchReads=0;Launched=$false}
        $service=[pscustomobject]@{Status='Running'}
        $service | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {param($Want,$Timeout)if($this.Status -ne $Want){throw 'Service did not stop'}}
        $oldDrive=$env:SystemDrive; $oldPf=$env:ProgramFiles; $oldPf86=${env:ProgramFiles(x86)}
        try{
            $env:SystemDrive=Join-Path $root 'os'; $env:ProgramFiles=Join-Path $env:SystemDrive 'Program Files'; ${env:ProgramFiles(x86)}=Join-Path $env:SystemDrive 'Program Files (x86)'
            $browser=Join-Path $env:ProgramFiles 'Microsoft\Edge'; $webview=Join-Path $env:ProgramFiles 'Microsoft\EdgeWebView'; $remove=Join-Path $env:SystemDrive 'remove-me'
            $null=New-Item -ItemType Directory -Path $browser,$webview,$remove -Force
            $guard=Join-Path $root 'guard.ps1'; $configFile=Join-Path $root 'guard.json'; $log=Join-Path $root 'guard.log'
            [IO.File]::WriteAllText($guard,(Get-GuardScript),[Text.UTF8Encoding]::new($true))
            [IO.File]::WriteAllText((Join-Path $root 'Finalize.ps1'),'param([switch]$EdgeOnly) Invoke-FakeEdgeCleanup',[Text.UTF8Encoding]::new($true))
            $testConfig=@{Language='en-US';BuildId='test';RemoveEdge=$true;Policies=@('HKLM:\SOFTWARE\TestGuard|AllowTelemetry|0');Services=@('TestSvc');Capabilities=@('^TestCapability$','^Language\.', '');Apps=@('^Microsoft\.BingWeather$');Protected=@('^Language\.Basic~');Paths=@('remove-me')}
            $testConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configFile -Encoding UTF8
            function Get-ItemProperty {
                param($LiteralPath,$Name,$ErrorAction)
                if($LiteralPath -eq 'HKLM:\SYSTEM\Setup'){if($fixture.SetupReadFails){throw 'Setup state unavailable'};return [pscustomobject]@{OOBEInProgress=$fixture.Oobe;SystemSetupInProgress=0}}
                if($LiteralPath -eq 'HKLM:\SOFTWARE\TestGuard'){return [pscustomobject]@{AllowTelemetry=$fixture.Policy;MissingSetting=$fixture.MissingPolicy}}
                if($LiteralPath -like '*\Services\TestSvc'){return [pscustomobject]@{Start=$fixture.ServiceStart}}
                throw "Unexpected registry read: $LiteralPath"
            }
            function Set-ItemProperty {param($LiteralPath,$Name,$Value,$Type,[switch]$Force,$ErrorAction)if($fixture.DenyPolicy){throw 'Policy denied'};if($LiteralPath -like '*\Services\TestSvc'){$fixture.ServiceStart=$Value}elseif($Name -eq 'MissingSetting'){$fixture.MissingPolicy=$Value}else{$fixture.Policy=$Value};$calls.Add('policy')}
            function Test-Path {
                [CmdletBinding()]param($LiteralPath,$Path)
                $p=if($LiteralPath){$LiteralPath}else{$Path}
                if($p -eq $remove -and $fixture.DenyVerify){Write-Error 'Mock verification denied' -Category PermissionDenied;return $false}
                if($p -like '*\Services\MissingSvc'){return $false}
                if($p -like 'HKLM:*'){return $true}
                Microsoft.PowerShell.Management\Test-Path -LiteralPath $p
            }
            function Get-Item {
                [CmdletBinding()]param($LiteralPath,$Path,[switch]$Force)
                if($LiteralPath -eq $remove -and $fixture.DenyInspect){throw [UnauthorizedAccessException]::new('Mock inspection denied')}
                Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
            }
            function Get-Service {param($Name,$ErrorAction)$service}
            function Stop-Service {param($Name,[switch]$Force,$ErrorAction)$service.Status='Stopped';$calls.Add('stop-service')}
            function Get-WindowsCapability {param([switch]$Online,$Name,$ErrorAction)
                if($fixture.InventoryFails){throw 'CBS is busy'}
                if($Name){return [pscustomobject]@{Name=$Name;State=$fixture.Cap}}
                @([pscustomobject]@{Name='TestCapability';State=$fixture.Cap},[pscustomobject]@{Name='Language.Basic~~~en-US~0.0.1.0';State='Installed'},[pscustomobject]@{Name='UnselectedCapability';State='Installed'})
            }
            function Remove-WindowsCapability {param([switch]$Online,$Name,$ErrorAction)$calls.Add('cap:'+ $Name);if($fixture.DenyCap){throw 'Capability denied'};$fixture.Cap=if($fixture.PendingCap){'UninstallPending'}else{'NotPresent'};[pscustomobject]@{RestartNeeded=$fixture.PendingCap}}
            function Get-AppxPackage {param([switch]$AllUsers,$Name,$ErrorAction)if($fixture.App){[pscustomobject]@{Name='Microsoft.BingWeather';PackageFullName='Microsoft.BingWeather_test'}}}
            function Remove-AppxPackage {param($Package,[switch]$AllUsers,$ErrorAction)$calls.Add('app');$fixture.App=$false}
            function Get-AppxProvisionedPackage {param([switch]$Online,$ErrorAction)if($fixture.Provisioned){[pscustomobject]@{DisplayName='Microsoft.BingWeather';PackageName='Microsoft.BingWeather_test'}}}
            function Remove-AppxProvisionedPackage {param([switch]$Online,$PackageName,$ErrorAction)$calls.Add('provisioned');$fixture.Provisioned=$false}
            function Get-ScheduledTask {param($TaskName,$ErrorAction)[pscustomobject]@{TaskName='win-11-lite finalize'}}
            function takeown.exe {$calls.Add('takeown');if($fixture.DenyAccess){Write-Error 'Mock takeown denied';$global:LASTEXITCODE=1}else{$global:LASTEXITCODE=0}}
            function icacls.exe {$calls.Add('icacls');if($fixture.DenyAccess){Write-Error 'Mock icacls denied';$global:LASTEXITCODE=5}else{$global:LASTEXITCODE=0}}
            function Remove-Item {
                [CmdletBinding()]param($LiteralPath,[switch]$Recurse,[switch]$Force)
                $full=[IO.Path]::GetFullPath($LiteralPath)
                if(-not $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe test deletion: $full"}
                if($full -eq $remove -and $fixture.DenyRemove){Write-Error 'Mock removal denied' -TargetObject (Join-Path $full 'locked.dll') -Category PermissionDenied -ErrorAction Stop}
                Microsoft.PowerShell.Management\Remove-Item -LiteralPath $full -Recurse:$Recurse -Force:$Force -ErrorAction Stop
            }
            function Invoke-FakeEdgeCleanup {if(Test-Path -LiteralPath $browser){Remove-Item -LiteralPath $browser -Recurse -Force;$calls.Add('edge')};$global:LASTEXITCODE=0}
            & $guard
            if($LASTEXITCODE -ne 0){throw ((Get-Content -LiteralPath $log -Tail 30)-join "`n")}
            Assert ($LASTEXITCODE -eq 0 -and $fixture.Policy -eq 0) 'Guard checks run even while the finalization task still exists'
            Assert ($calls -contains 'stop-service') 'A running service is stopped even when Start is already 4'
            Assert ($calls -contains 'cap:TestCapability' -and $calls -notcontains 'cap:UnselectedCapability') 'Selected capability removed; empty regex never matches everything'
            Assert ($calls -notcontains 'cap:Language.Basic~~~en-US~0.0.1.0') 'Protected language survives guard'
            Assert ($calls -contains 'app' -and $calls -contains 'provisioned') 'Installed and provisioned consumer apps are checked'
            Assert (-not (Test-Path -LiteralPath $browser) -and (Test-Path -LiteralPath $webview)) 'Edge is removed while WebView2 survives'
            Assert (-not (Test-Path -LiteralPath $remove)) 'Selected directory is removed'
            $text=Get-Content -LiteralPath $log -Raw
            Assert ($text -match '\[START\]' -and $text -match '\[END\]' -and $text -notmatch '\[ERROR\]') 'A successful run always records start and summary'
            $report=Get-Content -LiteralPath (Join-Path $root 'guard-report.json') -Raw|ConvertFrom-Json
            Assert ($report.Complete -and -not $report.Errors -and $report.Summary.service.stopped -eq 1) 'Structured report distinguishes stopping an already disabled service'
            Assert (@($report.Items|Where-Object{$_.Category -eq 'app' -and $_.Name -eq 'Microsoft.BingWeather' -and $_.Found -and $_.Outcome -eq 'removed'}).Count -eq 1) 'Report names apps that were found and successfully removed'
            Assert (@($report.Items|Where-Object{$_.Repeated}).Count -eq 0) 'First report does not invent repeated changes'
            $human=Get-Content -LiteralPath (Join-Path $root 'guard-report.txt') -Raw
            Assert ($human -match 'SERVICES AND DRIVERS' -and $human -match 'Before: startup: disabled; state: running' -and $human -match 'successfully removed') 'Human report contains categories, names, previous state and actual outcomes'
            $fixture.Policy=1;$fixture.ServiceStart=2;$service.Status='Running';$calls.Clear()
            & $guard
            Assert ($fixture.Policy -eq 0 -and $calls -contains 'policy') 'A second logon rechecks and repairs restored values'
            Assert ([regex]::Matches((Get-Content -LiteralPath $log -Raw),'\[START\]').Count -eq 2) 'Guard runs repeatedly rather than only once'
            $report=Get-Content -LiteralPath (Join-Path $root 'guard-report.json') -Raw|ConvertFrom-Json
            Assert ($report.Summary.setting.Repeated -eq 1 -and $report.Summary.service.Repeated -eq 1 -and $report.Summary.service.disabled -eq 1) 'Prior successful observations prove repeated policy repair and service disabling'
            Assert (@($report.Items|Where-Object{$_.Category -eq 'app' -and $_.Name -eq 'Microsoft.BingWeather' -and $_.Outcome -eq 'absent'}).Count -eq 1) 'Missing apps have explicit names and are not counted as removals'

            # Real shared reader: the old PS 5.1 Add-Content writer fails while
            # this handle is open, even though the reader permits writes.
            $fixture.Policy=1;$fixture.App=$true;$fixture.Provisioned=$true;$calls.Clear()
            $reader=[IO.File]::Open($log,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            try { & $guard; $sharedExit=$LASTEXITCODE } finally { $reader.Dispose() }
            Assert ($sharedExit -eq 0 -and $fixture.Policy -eq 0) 'A live reader does not block logging or policy checks'
            Assert ($calls -contains 'app' -and $calls -contains 'provisioned') 'Checks continue through app inventory and removal while a reader holds the log'
            Assert ((Get-Content -LiteralPath $log -Raw) -notmatch '\[ERROR\]') 'Shared logging does not produce false component failures'

            $lockedReport=Join-Path $root 'guard-report.txt'
            $reportLock=[IO.File]::Open($lockedReport,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
            $oldError=[Console]::Error;$captured=[IO.StringWriter]::new()
            try{[Console]::SetError($captured); & $guard; $reportExit=$LASTEXITCODE}
            finally{[Console]::SetError($oldError);$reportLock.Dispose();$captured.Dispose()}
            $report=Get-Content -LiteralPath (Join-Path $root 'guard-report.json') -Raw|ConvertFrom-Json
            Assert ($reportExit -eq 1 -and $report.LogErrors -gt 0 -and $report.Errors -eq 0) 'Standard JSON records a failure writing the full report separately from check errors'
            Assert ($report.BriefText -match 'writing errors: 1') 'The concise display includes report-write failures'

            Clear-Content -LiteralPath $log
            $fixture.Policy=1;$fixture.DenyPolicy=$true;$fixture.Cap='Installed';$fixture.DenyCap=$true
            & $guard
            $text=Get-Content -LiteralPath $log -Raw
            Assert ($LASTEXITCODE -eq 1 -and $text -match 'Policy denied' -and $text -match 'Capability denied') 'Failures remain visible and produce a nonzero task result'
            Assert ($text -notmatch '\[CHANGED\].*(AllowTelemetry|TestCapability)') 'Failed changes cannot be logged as successful'
            $fixture.DenyPolicy=$false;$fixture.DenyCap=$false;$fixture.InventoryFails=$true;$fixture.App=$true
            & $guard
            Assert (-not $fixture.App -and $LASTEXITCODE -eq 1) 'Capability inventory failure does not prevent independent app checks'
            $report=Get-Content -LiteralPath (Join-Path $root 'guard-report.json') -Raw|ConvertFrom-Json
            Assert (@($report.Items|Where-Object{$_.Category -eq 'capability' -and $_.Outcome -eq 'failed' -and $null -eq $_.Found}).Count -eq 1 -and @($report.Items|Where-Object{$_.Category -eq 'capability' -and $_.Outcome -eq 'absent'}).Count -eq 0) 'Unreadable inventory is reported as unknown rather than not found'
            Clear-Content -LiteralPath $log
            $fixture.InventoryFails=$false;$fixture.Cap='Installed';$fixture.PendingCap=$true
            & $guard
            Assert ($LASTEXITCODE -eq 0 -and (Get-Content -LiteralPath $log -Raw) -match '\[PENDING\].*TestCapability') 'Pending removals are distinguished from completed removals'
            $fixture.Oobe=1;$fixture.Policy=1;$calls.Clear()
            & $guard
            Assert ($calls.Count -eq 0 -and $fixture.Policy -eq 1) 'OOBE logon performs no cleanup'
            $report=Get-Content -LiteralPath (Join-Path $root 'guard-report.json') -Raw|ConvertFrom-Json
            Assert ($report.Deferred -and -not $report.Complete -and $report.Summary.setting.NotChecked -eq 1 -and $report.Summary.service.NotChecked -eq 1) 'Deferred reports list unexamined settings and services'
            $fixture.Oobe=0

            $null=New-Item -ItemType Directory -Path $remove -Force
            $fixture.DenyAccess=$true;$fixture.DenyRemove=$true;$calls.Clear()
            & $guard
            $report=Get-Content -LiteralPath (Join-Path $root 'guard-report.json') -Raw|ConvertFrom-Json
            $row=@($report.Items|Where-Object{$_.Category -eq 'path'})[0]
            Assert ($LASTEXITCODE -eq 1 -and $row.Outcome -eq 'failed' -and $row.Found -and (Test-Path -LiteralPath $remove)) 'Denied removal is reported as found but not removed'
            Assert ($row.Detail -match 'removal \(Remove-Item\)' -and $row.Detail -match 'HRESULT=0x' -and $row.Detail -match 'locked.dll') 'Failure identifies the stage, exception code and failing child path'
            Assert ($row.Detail -match 'takeown.exe ExitCode=1' -and $row.Detail -match 'icacls.exe ExitCode=5' -and $row.Detail -match 'Mock takeown denied' -and $row.Detail -match 'Mock icacls denied') 'Native exit codes and stderr survive in the final failure report'
            $fixture.DenyRemove=$false
            & $guard
            $report=Get-Content -LiteralPath (Join-Path $root 'guard-report.json') -Raw|ConvertFrom-Json
            Assert ($LASTEXITCODE -eq 0 -and -not(Test-Path -LiteralPath $remove) -and $report.Summary.path.removed -eq 1) 'Permission preparation errors do not prevent deletion when existing access suffices'
            $fixture.DenyAccess=$false;$fixture.DenyInspect=$true;$calls.Clear()
            $null=New-Item -ItemType Directory -Path $remove -Force
            & $guard
            $report=Get-Content -LiteralPath (Join-Path $root 'guard-report.json') -Raw|ConvertFrom-Json
            $row=@($report.Items|Where-Object{$_.Category -eq 'path'})[0]
            Assert ($LASTEXITCODE -eq 1 -and $row.Detail -match 'link inspection:' -and $row.Detail -match 'HRESULT=0x80070005' -and $calls -notcontains 'takeown') 'An access failure before permission preparation is distinguished from failed removal'
            $fixture.DenyInspect=$false;$fixture.DenyVerify=$true
            & $guard
            $report=Get-Content -LiteralPath (Join-Path $root 'guard-report.json') -Raw|ConvertFrom-Json
            $row=@($report.Items|Where-Object{$_.Category -eq 'path'})[0]
            Assert ($LASTEXITCODE -eq 1 -and $row.Outcome -eq 'failed' -and $row.Detail -match 'verification after removal' -and -not $row.After) 'An unreadable post-removal path cannot be reported as successfully absent'
            $fixture.DenyVerify=$false

            $outside=Join-Path $root 'outside-system'; $null=New-Item -ItemType Directory -Path $outside
            $marker=Join-Path $outside 'keep.txt'; Set-Content -LiteralPath $marker -Value 'must survive'
            $link=Join-Path $env:SystemDrive 'linked'
            $null=New-Item -ItemType Junction -Path $link -Target $outside
            $testConfig.Paths=@('linked')
            $testConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configFile -Encoding UTF8
            & $guard
            Assert ((Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $log -Raw) -match '\[SKIP\].*linked') 'Guard does not traverse a junction when removing files'
            $testConfig.Paths=@('..')
            $testConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configFile -Encoding UTF8
            & $guard
            Assert ($LASTEXITCODE -eq 1 -and (Test-Path -LiteralPath $marker)) 'A configured parent path cannot escape the system drive'
            $testConfig.Paths=@()
            $testConfig.Services=@('TestSvc','MissingSvc')
            $testConfig.Policies+=@('HKLM:\SOFTWARE\TestGuard|MissingSetting|0')
            $testConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configFile -Encoding UTF8

            & $guard
            $report=Get-Content -LiteralPath (Join-Path $root 'guard-report.json') -Raw|ConvertFrom-Json
            Assert ($report.Summary.setting.created -eq 1 -and @($report.Items|Where-Object{$_.Name -eq 'MissingSetting' -and $_.Found -eq $false -and $_.After -eq '0'}).Count -eq 1) 'Missing settings are distinguished from existing settings and record creation'
            Assert (@($report.Items|Where-Object{$_.Name -eq 'MissingSvc' -and $_.Found -eq $false -and $_.Outcome -eq 'absent'}).Count -eq 1) 'Absent services are named explicitly'

            # A genuinely exclusive external lock cannot be bypassed. Logging
            # falls back to stderr while all mocked system checks still finish.
            $fixture.Policy=1;$fixture.App=$true;$fixture.Provisioned=$true;$calls.Clear()
            $exclusive=[IO.File]::Open($log,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $oldError=[Console]::Error;$captured=[IO.StringWriter]::new()
            try {
                [Console]::SetError($captured)
                & $guard
                $lockedExit=$LASTEXITCODE
            } finally { [Console]::SetError($oldError);$exclusive.Dispose() }
            $fallback=$captured.ToString();$captured.Dispose()
            Assert ($lockedExit -eq 1 -and $fixture.Policy -eq 0 -and $calls -contains 'app' -and $calls -contains 'provisioned') 'Exclusive log failure is reported without aborting independent checks'
            Assert ($fallback -match '\[END\].*errors 0' -and $fallback -notmatch '\[ERROR\]') 'Logging failure is not counted as a failed policy or service'
            Assert ($fallback -match '\[LOG ERROR\]' -and $fallback -match '\[START\]' -and $fallback -match 'Lines not written') 'Failed log records and a logging-specific summary are preserved on stderr'
            $lockProbe=[IO.File]::Open((Join-Path $root 'guard.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $lockProbe.Dispose()
            Assert $true 'Run lock is released after logging failures'
            & $guard
            Assert ($LASTEXITCODE -eq 0) 'The next run recovers after the external log lock is released'
            $fixture.SetupReadFails=$true;$calls.Clear()
            & $guard
            $report=Get-Content -LiteralPath (Join-Path $root 'guard-report.json') -Raw|ConvertFrom-Json
            Assert ($LASTEXITCODE -eq 1 -and -not $report.Complete -and $report.Summary.setting.NotChecked -eq 2 -and $report.Summary.service.NotChecked -eq 2 -and $calls.Count -eq 0) 'Interrupted runs explicitly name work that was not performed'
            $fixture.SetupReadFails=$false;$testConfig.Language='ru-RU'
            $testConfig|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $configFile -Encoding utf8
            & $guard
            $human=Get-Content -LiteralPath (Join-Path $root 'guard-report.txt') -Raw
            Assert ($LASTEXITCODE -eq 0 -and $human.Contains('ИТОГ ПРОВЕРКИ GUARD') -and $human.Contains('уже отключена и остановлена') -and $human.Contains('MissingSvc: не найдено')) 'Russian report is readable and keeps exact object names'

            # Replace only the native OOBE probe in the private helper fixture.
            $uiPath=Join-Path $root 'Guard.UI.ps1';$ui=[IO.File]::ReadAllText($uiPath)
            $uiAst=[Management.Automation.Language.Parser]::ParseInput($ui,[ref]$t,[ref]$e)
            $probe=$uiAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-GuardOobeComplete'},$false)
            $ui=$ui.Remove($probe.Extent.StartOffset,$probe.Extent.EndOffset-$probe.Extent.StartOffset).Insert($probe.Extent.StartOffset,'function Test-GuardOobeComplete { $fixture.Oobe -eq 0 }')
            [IO.File]::WriteAllText($uiPath,$ui,[Text.UTF8Encoding]::new($true))
            $viewLines=[Collections.Generic.List[string]]::new();$fixture.Launched=$false
            function Start-Process {param($FilePath,$WindowStyle,$ArgumentList)$fixture.Launched=$true;throw 'Unexpected intermediate process'}
            function Write-Host {param($Object,$ForegroundColor)$viewLines.Add([string]$Object)}
            function Read-Host {param($Prompt)''}
            $calls.Clear(); & $guard -ShowDebugWindow
            Assert (-not $fixture.Launched -and @($viewLines|Where-Object{$_ -match '\[END\]'}).Count -eq 1) 'Debug displays this run in the same process without launching another PowerShell'
            $viewLines.Clear();$fixture.Oobe=1
            & $guard -ShowDebugWindow
            Assert (-not $viewLines.Count -and -not $fixture.Launched) 'Observer performs no display during OOBE'
            $fixture.Oobe=0; & $guard -View
            Assert ($calls.Count -eq 0 -and $viewLines[0] -match 'ИТОГ ПРОВЕРКИ GUARD' -and $viewLines[0] -notmatch 'HKLM:|C:\\|\[CHECK\]') 'Standard viewer shows only the summary without privileged cleanup or full paths'
            $ui=[IO.File]::ReadAllText($uiPath);$uiAst=[Management.Automation.Language.Parser]::ParseInput($ui,[ref]$t,[ref]$e)
            $start=$uiAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-GuardViewer'},$false)
            $stub='function Start-GuardViewer { param($SupportDirectory,$RunId,$Mode) $fixture.ViewCalls.Add([pscustomobject]@{Mode=$Mode;RunId=$RunId;Capability=$fixture.Cap}) }'
            $ui=$ui.Remove($start.Extent.StartOffset,$start.Extent.EndOffset-$start.Extent.StartOffset).Insert($start.Extent.StartOffset,$stub)
            [IO.File]::WriteAllText($uiPath,$ui,[Text.UTF8Encoding]::new($true))
            $fixture.ViewCalls=[Collections.Generic.List[object]]::new();$fixture.PendingCap=$false;$testConfig.ViewerTask=$true
            foreach($mode in 'Debug','Standard','Silent'){
                $testConfig.Mode=$mode;$fixture.Cap='Installed';$fixture.ViewCalls.Clear()
                $testConfig|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $configFile -Encoding utf8
                & $guard
                $report=Get-Content -LiteralPath (Join-Path $root 'guard-report.json') -Raw|ConvertFrom-Json
                if($mode -eq 'Silent'){Assert (-not $fixture.ViewCalls.Count) 'Silent worker never requests a viewer'}
                else{Assert ($fixture.ViewCalls.Count -eq 1 -and $fixture.ViewCalls[0].RunId -eq $report.RunId -and $fixture.ViewCalls[0].Capability -eq $(if($mode -eq 'Debug'){'Installed'}else{'NotPresent'})) "Worker requests $mode at the correct stage and passes its report ID"}
                Assert ($report.Mode -eq $mode -and (Test-Path -LiteralPath (Join-Path $root 'guard-summary.txt')) -and $report.Brief.Programs -eq 2) "Full and concise reports are saved in $mode with deduplicated program counts"
            }
        }finally{$env:SystemDrive=$oldDrive;$env:ProgramFiles=$oldPf;${env:ProgramFiles(x86)}=$oldPf86}
    }
    Write-Host "PASS: $script:checks guard checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $expected=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\guard-tests-'
    if(-not ([IO.Path]::GetFullPath($root)).StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected guard test root'}
    Remove-Item -LiteralPath $root -Recurse -Force
}
