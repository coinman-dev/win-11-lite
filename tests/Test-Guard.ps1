#Requires -Version 5.1
# Generated guard and task registration run with mocked Windows APIs only.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$t=$null; $e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
$script:checks=0
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw "FAIL: $Message"};$script:checks++}
foreach($name in @('T','Test-GroupActive','Get-GuardScript','Get-SetupSupportScripts')){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:Lang='en'; $script:ImageLanguages=@('en-US'); $AddLanguage=@(); $DownloadLanguage=@(); $RemoveExtra=@(); $Keep=@(); $Preset='balanced'; $imgLang='en-US'; $script:StartedAt=Get-Date
foreach($name in @('CapabilityRules','PackageRules','FolderRules','FileRules','AppxRules','NeverRemove','DisableServices','AiFolderPatterns')){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$script:'+$name)},$false)
    . ([scriptblock]::Create($node.Extent.Text))
}
$root=Join-Path $repo ('tmp\guard-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
try{
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
        Assert ($tasks.ContainsKey('win-11-lite guard') -and $tasks.ContainsKey('win-11-lite guard debug')) 'Worker and debug observer are registered'
        $worker=$tasks['win-11-lite guard']; $viewer=$tasks['win-11-lite guard debug']
        Assert ($worker.Principal.UserId -eq 'S-1-5-18' -and $worker.Principal.LogonType -eq 'ServiceAccount') 'Worker retains SYSTEM privileges'
        Assert ($worker.Trigger.AtLogOn -and $worker.Settings.MultipleInstances -eq 'IgnoreNew') 'Worker triggers on logon and prevents overlap'
        Assert ($viewer.Principal.GroupId -eq 'S-1-5-32-545' -and $viewer.Principal.RunLevel -eq 'Limited') 'Observer uses the interactive user group without elevation'
        Assert ($viewer.Action.Argument -match '-ShowDebugWindow' -and $viewer.Trigger.AtLogOn) 'Debug task opens observer through the OOBE check'
        $scripts=Get-SetupSupportScripts -BlockNetwork $false -RemoveEdge $true -EnableGuard $true -ShowGuardWindow $false
        [IO.File]::WriteAllText($prepare,$scripts.Prepare,[Text.UTF8Encoding]::new($true))
        & $prepare -RegisterOnly
        Assert ($tasks.ContainsKey('win-11-lite guard') -and -not $tasks.ContainsKey('win-11-lite guard debug')) 'Disabling debug removes only the observer'
    }

    & {
        $calls=[Collections.Generic.List[string]]::new()
        $fixture=@{Oobe=0;Policy=1;DenyPolicy=$false;Cap='Installed';DenyCap=$false;PendingCap=$false;InventoryFails=$false;App=$true;Provisioned=$true;WatchReads=0;Launched=$false}
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
                if($LiteralPath -eq 'HKLM:\SYSTEM\Setup'){return [pscustomobject]@{OOBEInProgress=$fixture.Oobe;SystemSetupInProgress=0}}
                if($LiteralPath -eq 'HKLM:\SOFTWARE\TestGuard'){return [pscustomobject]@{AllowTelemetry=$fixture.Policy}}
                if($LiteralPath -like '*\Services\TestSvc'){return [pscustomobject]@{Start=4}}
                throw "Unexpected registry read: $LiteralPath"
            }
            function Set-ItemProperty {param($LiteralPath,$Name,$Value,$Type,[switch]$Force,$ErrorAction)if($fixture.DenyPolicy){throw 'Policy denied'};$fixture.Policy=$Value;$calls.Add('policy')}
            function Test-Path {
                [CmdletBinding()]param($LiteralPath,$Path)
                $p=if($LiteralPath){$LiteralPath}else{$Path}
                if($p -like 'HKLM:*'){return $true}
                Microsoft.PowerShell.Management\Test-Path -LiteralPath $p
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
            function takeown.exe {$global:LASTEXITCODE=0}
            function icacls.exe {$global:LASTEXITCODE=0}
            function Remove-Item {
                [CmdletBinding()]param($LiteralPath,[switch]$Recurse,[switch]$Force)
                $full=[IO.Path]::GetFullPath($LiteralPath)
                if(-not $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe test deletion: $full"}
                Microsoft.PowerShell.Management\Remove-Item -LiteralPath $full -Recurse:$Recurse -Force:$Force -ErrorAction Stop
            }
            function Invoke-FakeEdgeCleanup {if(Test-Path -LiteralPath $browser){Remove-Item -LiteralPath $browser -Recurse -Force;$calls.Add('edge')};$global:LASTEXITCODE=0}
            & $guard
            Assert ($LASTEXITCODE -eq 0 -and $fixture.Policy -eq 0) 'Guard checks run even while the finalization task still exists'
            Assert ($calls -contains 'stop-service') 'A running service is stopped even when Start is already 4'
            Assert ($calls -contains 'cap:TestCapability' -and $calls -notcontains 'cap:UnselectedCapability') 'Selected capability removed; empty regex never matches everything'
            Assert ($calls -notcontains 'cap:Language.Basic~~~en-US~0.0.1.0') 'Protected language survives guard'
            Assert ($calls -contains 'app' -and $calls -contains 'provisioned') 'Installed and provisioned consumer apps are checked'
            Assert (-not (Test-Path -LiteralPath $browser) -and (Test-Path -LiteralPath $webview)) 'Edge is removed while WebView2 survives'
            Assert (-not (Test-Path -LiteralPath $remove)) 'Selected directory is removed'
            $text=Get-Content -LiteralPath $log -Raw
            Assert ($text -match '\[START\]' -and $text -match '\[END\]' -and $text -notmatch '\[ERROR\]') 'A successful run always records start and summary'
            $fixture.Policy=1; $calls.Clear()
            & $guard
            Assert ($fixture.Policy -eq 0 -and $calls -contains 'policy') 'A second logon rechecks and repairs restored values'
            Assert ([regex]::Matches((Get-Content -LiteralPath $log -Raw),'\[START\]').Count -eq 2) 'Guard runs repeatedly rather than only once'

            Clear-Content -LiteralPath $log
            $fixture.Policy=1;$fixture.DenyPolicy=$true;$fixture.Cap='Installed';$fixture.DenyCap=$true
            & $guard
            $text=Get-Content -LiteralPath $log -Raw
            Assert ($LASTEXITCODE -eq 1 -and $text -match 'Policy denied' -and $text -match 'Capability denied') 'Failures remain visible and produce a nonzero task result'
            Assert ($text -notmatch '\[CHANGED\].*(AllowTelemetry|TestCapability)') 'Failed changes cannot be logged as successful'
            $fixture.DenyPolicy=$false;$fixture.DenyCap=$false;$fixture.InventoryFails=$true;$fixture.App=$true
            & $guard
            Assert (-not $fixture.App -and $LASTEXITCODE -eq 1) 'Capability inventory failure does not prevent independent app checks'
            Clear-Content -LiteralPath $log
            $fixture.InventoryFails=$false;$fixture.Cap='Installed';$fixture.PendingCap=$true
            & $guard
            Assert ($LASTEXITCODE -eq 0 -and (Get-Content -LiteralPath $log -Raw) -match '\[PENDING\].*TestCapability') 'Pending removals are distinguished from completed removals'
            $fixture.Oobe=1;$fixture.Policy=1;$calls.Clear()
            & $guard
            Assert ($calls.Count -eq 0 -and $fixture.Policy -eq 1) 'OOBE logon performs no cleanup'
            $fixture.Oobe=0

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
            $testConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configFile -Encoding UTF8

            function Start-Process {param($FilePath,$WindowStyle,$ArgumentList)$fixture.Launched=$true;$fixture.WindowStyle=$WindowStyle;$fixture.Arguments=$ArgumentList}
            & $guard -ShowDebugWindow
            Assert ($fixture.Launched -and $fixture.WindowStyle -eq 'Normal' -and $fixture.Arguments -match '-NoExit.*-Watch') 'Interactive observer opens a visible PowerShell window'
            $fixture.Launched=$false;$fixture.Oobe=1
            & $guard -ShowDebugWindow
            Assert (-not $fixture.Launched) 'Debug observer does not open a window during OOBE'
            $fixture.Oobe=0;$calls.Clear()
            function Get-Content {
                [CmdletBinding()]param($LiteralPath,[switch]$Raw,$Encoding,[int]$Tail,[switch]$Wait)
                if($Wait){$fixture.WatchReads++; '2026-09-12 [START] test'; '2026-09-12 [END] test'}
                else {Microsoft.PowerShell.Management\Get-Content @PSBoundParameters}
            }
            function Write-Host {param($Object,$ForegroundColor)}
            & $guard -Watch
            Assert ($fixture.WatchReads -eq 1 -and $calls.Count -eq 0) 'Observer tails logs without running privileged cleanup'
        }finally{$env:SystemDrive=$oldDrive;$env:ProgramFiles=$oldPf;${env:ProgramFiles(x86)}=$oldPf86}
    }
    Write-Host "PASS: $script:checks guard checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $expected=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\guard-tests-'
    if(-not ([IO.Path]::GetFullPath($root)).StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected guard test root'}
    Remove-Item -LiteralPath $root -Recurse -Force
}
