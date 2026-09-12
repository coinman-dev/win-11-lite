#Requires -Version 5.1
# All network, firewall, task, process and OOBE APIs are mocked. No host changes.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
$node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SetupSupportScripts'},$false)
. ([scriptblock]::Create($node.Extent.Text))
$script:checks=0
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw "FAIL: $Message"};$script:checks++}
function Assert-Throws([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed $Message}
$root=Join-Path $repo ('tmp\oobe-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$oldUser=$env:USERNAME
try{
    $compileTemp=$env:TEMP;$compileTmp=$env:TMP
    try{
        $env:TEMP=$root;$env:TMP=$root
        Add-Type 'namespace Win11Lite { public static class OobeStatus { public static bool Complete = false; public static bool Success = true; public static bool OOBEComplete(out bool complete) { complete = Complete; return Success; } } }'
    }finally{$env:TEMP=$compileTemp;$env:TMP=$compileTmp}
    foreach($case in @('late-adapter','enumeration-retry','late-reenable','first-logon','wait-completion','timeout','api-failure','temporary-user','firewall-failure','firewall-query-failure','adapter-failure','edge-failure','edge-only','network-opt-out','custom-oobe','late-prepare')){
        & {
            $dir=Join-Path $root $case;$null=New-Item -ItemType Directory -Path $dir
            $state=@{Adapters=@();Calls=0;Firewall=$false;ForeignFirewall=$true;FirewallRemoveFails=$false;EnableFails=$false;EmptyCalls=0;QueryFailures=0;Tasks=@{};Events=[Collections.Generic.List[string]]::new();SleepSeconds=0;CompleteOnSleep=$false;Clock=0}
            $originallyDisabled=[pscustomobject]@{Name='User-disabled';InterfaceGuid='keep-disabled';AdminStatus='Down'}
            $nic=[pscustomobject]@{Name='Ethernet';InterfaceGuid='main-nic';AdminStatus='Up'}
            $state.Adapters=@($nic,$originallyDisabled)
            $env:USERNAME='real-user'
            [Win11Lite.OobeStatus]::Complete=$false;[Win11Lite.OobeStatus]::Success=$true
            function Get-Date {
                param($Format)
                $date=([datetime]'2026-09-12T19:00:00').AddSeconds($state.Clock)
                if($Format){$date.ToString($Format)}else{$date}
            }
            function Start-Sleep {
                param($Seconds,$Milliseconds)
                $state.SleepSeconds+=$Seconds;$state.Clock+=$Seconds
                if($state.CompleteOnSleep){
                    Assert ($state.Firewall -and $nic.AdminStatus -eq 'Down') 'Network remains blocked while the background worker waits'
                    [Win11Lite.OobeStatus]::Complete=$true
                }
            }
            function Get-NetAdapter {
                param([switch]$IncludeHidden,$ErrorAction)
                $state.Calls++
                if($state.Calls -le $state.QueryFailures){throw 'CIM provider not ready'}
                if($state.Calls -le $state.EmptyCalls){return @()}
                $state.Adapters
            }
            function Disable-NetAdapter {[CmdletBinding(SupportsShouldProcess)]param([Parameter(ValueFromPipeline)]$InputObject)process{$state.Events.Add('disable:'+$InputObject.InterfaceGuid);$InputObject.AdminStatus='Down'}}
            function Enable-NetAdapter {[CmdletBinding(SupportsShouldProcess)]param([Parameter(ValueFromPipeline)]$InputObject)process{if($state.EnableFails){throw 'Enable denied'};$state.Events.Add('enable:'+$InputObject.InterfaceGuid);$InputObject.AdminStatus='Up'}}
            function Get-NetFirewallRule {
                param($Name,$PolicyStore,$ErrorAction)
                if(($Name -and $Name -ne 'Win11Lite-OOBE-Temporary-Outbound-Block') -or $PolicyStore -ne 'PersistentStore'){throw 'Unexpected firewall access'}
                if($state.FirewallQueryFails){throw 'Firewall provider unavailable'}
                if($state.Firewall){[pscustomobject]@{Name='Win11Lite-OOBE-Temporary-Outbound-Block'}}
                if(-not $Name -and $state.ForeignFirewall){[pscustomobject]@{Name='Unrelated-user-rule'}}
            }
            function New-NetFirewallRule {
                param($Name,$DisplayName,$PolicyStore,$Enabled,$Direction,$Action,$Profile)
                Assert ($PolicyStore -eq 'PersistentStore' -and $Enabled -eq 'True' -and $Direction -eq 'Outbound' -and $Action -eq 'Block' -and $Profile -eq 'Any') 'Temporary rule covers current and future adapters on all profiles'
                $state.Firewall=$true;$state.Events.Add('firewall-add')
            }
            function Set-NetFirewallRule {param($Name,$PolicyStore,$Enabled,$Direction,$Action,$Profile)$state.Firewall=$true;$state.Events.Add('firewall-reset')}
            function Remove-NetFirewallRule {param($Name,$PolicyStore,$ErrorAction)if($state.FirewallRemoveFails){throw 'Firewall removal denied'};$state.Firewall=$false;$state.Events.Add('firewall-remove')}
            function New-ScheduledTaskAction {param($Execute,$Argument)[pscustomobject]@{Execute=$Execute;Argument=$Argument}}
            function New-ScheduledTaskTrigger {param([switch]$AtLogOn)[pscustomobject]@{Delay=''}}
            function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel)'principal'}
            function New-ScheduledTaskSettingsSet {param([switch]$StartWhenAvailable,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$MultipleInstances,$ExecutionTimeLimit)[pscustomobject]@{Limit=$ExecutionTimeLimit}}
            function Register-ScheduledTask {param($TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force)$state.Tasks[$TaskName]=[pscustomobject]@{Action=$Action;Settings=$Settings}}
            function Unregister-ScheduledTask {[CmdletBinding(SupportsShouldProcess)]param($TaskName)$state.Tasks.Remove($TaskName)}
            function Start-Process {param($FilePath,$WindowStyle,$ArgumentList)Assert ($WindowStyle -eq 'Hidden' -and $FilePath -like '*\powershell.exe' -and $ArgumentList -match 'Run-Setup\.ps1" -Mode finalize-wait$') 'FirstLogon starts a hidden PowerShell waiter without holding up desktop startup';$state.Events.Add('background-wait')}
            function Get-ItemProperty {param($LiteralPath,$Name,$ErrorAction)if($LiteralPath -eq 'HKLM:\SYSTEM\Setup'){[pscustomobject]@{OOBEInProgress=1;SystemSetupInProgress=1}}}
            function Remove-ItemProperty {param($LiteralPath,$Name,$ErrorAction)throw 'Unexpected registry mutation in fixture'}
            function Get-Process {param($Name,$ErrorAction)@()}
            function Get-CimInstance {param($ClassName)@()}
            function takeown.exe {$global:LASTEXITCODE=0}
            function icacls.exe {$global:LASTEXITCODE=0}
            $block=$case -notin @('network-opt-out','custom-oobe')
            $support=Get-SetupSupportScripts -BlockNetwork $block -RemoveEdge ($case -eq 'edge-failure') -EnableGuard $false -ManageOobe ($case -ne 'custom-oobe') -Language en-US
            foreach($name in @('Prepare','Finalize')){[IO.File]::WriteAllText((Join-Path $dir "$name.ps1"),$support[$name],[Text.UTF8Encoding]::new($true))}
            if($case -eq 'late-adapter'){$state.EmptyCalls=20}
            if($case -eq 'enumeration-retry'){$state.QueryFailures=2}
            & (Join-Path $dir 'Prepare.ps1')
            Assert ($state.Tasks['win-11-lite finalize'].Action.Argument -match 'Run-Setup\.ps1" -Mode finalize-wait$' -and $state.Tasks['win-11-lite finalize'].Action.Execute -like '*\powershell.exe') 'SYSTEM logon task waits for actual OOBE completion through the PowerShell runner'
            switch($case){
                'late-adapter'{
                    Assert ($state.Firewall -and $nic.AdminStatus -eq 'Up' -and $state.SleepSeconds -eq 14) 'No initial adapters leaves the persistent firewall block in place'
                    $state.EmptyCalls=0
                    & (Join-Path $dir 'Prepare.ps1') -RegisterOnly
                    Assert ($nic.AdminStatus -eq 'Down') 'SetupComplete catches an adapter absent during specialize'
                }
                'enumeration-retry'{Assert ($state.Calls -gt 2 -and $nic.AdminStatus -eq 'Down') 'Transient CIM failure is retried before OOBE'}
                'late-reenable'{
                    $nic.AdminStatus='Up'
                    & (Join-Path $dir 'Prepare.ps1') -RegisterOnly
                    Assert ($nic.AdminStatus -eq 'Down') 'SetupComplete disables an adapter reenabled by PnP'
                    Assert (@(Import-Clixml -LiteralPath (Join-Path $dir 'network-state.clixml')).Count -eq 1) 'Repeated preparation preserves one restoration record per changed adapter'
                }
                'first-logon'{
                    & (Join-Path $dir 'Finalize.ps1') -FirstLogon
                    Assert ($state.Firewall -and $nic.AdminStatus -eq 'Down' -and $state.Events -contains 'background-wait') 'FirstLogon alone cannot restore network during OOBE'
                    Assert ($state.Tasks.ContainsKey('win-11-lite finalize')) 'Early logon retains the recovery task'
                }
                'wait-completion'{
                    $state.CompleteOnSleep=$true
                    & (Join-Path $dir 'Finalize.ps1') -WaitForOobe
                    Assert ($nic.AdminStatus -eq 'Up' -and -not $state.Firewall) 'Background worker restores network after the native OOBE signal changes'
                    Assert ($originallyDisabled.AdminStatus -eq 'Down' -and $state.ForeignFirewall) 'Restoration preserves user-disabled adapters and unrelated firewall rules'
                    Assert (-not $state.Tasks.ContainsKey('win-11-lite finalize')) 'Completed finalization removes its retry task'
                }
                'timeout'{
                    Assert-Throws {& (Join-Path $dir 'Finalize.ps1') -WaitForOobe -WaitSeconds 1} 'Wait timeout reports a failure'
                    Assert ($state.Firewall -and $state.Tasks.ContainsKey('win-11-lite finalize')) 'Timeout does not reopen OOBE network or discard the retry task'
                }
                'api-failure'{
                    [Win11Lite.OobeStatus]::Success=$false
                    & (Join-Path $dir 'Finalize.ps1') -FirstLogon
                    Assert ($state.Events -contains 'background-wait') 'Transient OOBE query failure schedules another check instead of treating it as completion'
                    Assert ($state.Firewall -and $nic.AdminStatus -eq 'Down') 'Unknown OOBE state leaves network blocked'
                }
                'temporary-user'{
                    $env:USERNAME='defaultuser1';[Win11Lite.OobeStatus]::Complete=$true
                    & (Join-Path $dir 'Finalize.ps1') -FirstLogon
                    Assert ($state.Firewall -and $nic.AdminStatus -eq 'Down' -and $state.Events -notcontains 'background-wait') 'Temporary defaultuser accounts never restore network'
                }
                'firewall-failure'{
                    [Win11Lite.OobeStatus]::Complete=$true;$state.FirewallRemoveFails=$true
                    & (Join-Path $dir 'Finalize.ps1') -FirstLogon
                    Assert ($LASTEXITCODE -eq 1 -and $state.Tasks.ContainsKey('win-11-lite finalize')) 'Failed firewall restoration is recorded as failure and retains retry'
                    $state.FirewallRemoveFails=$false
                    & (Join-Path $dir 'Finalize.ps1')
                    Assert (-not $state.Firewall -and -not $state.Tasks.ContainsKey('win-11-lite finalize')) 'Later retry removes the remaining firewall block'
                }
                'adapter-failure'{
                    [Win11Lite.OobeStatus]::Complete=$true;$state.EnableFails=$true
                    & (Join-Path $dir 'Finalize.ps1') -FirstLogon
                    Assert ($LASTEXITCODE -eq 1 -and -not $state.Firewall -and (Test-Path -LiteralPath (Join-Path $dir 'network-state.clixml'))) 'Adapter failure cannot prevent firewall removal or lose saved adapter state'
                }
                'firewall-query-failure'{
                    [Win11Lite.OobeStatus]::Complete=$true;$state.FirewallQueryFails=$true
                    & (Join-Path $dir 'Finalize.ps1') -FirstLogon
                    Assert ($LASTEXITCODE -eq 1 -and $state.Firewall -and $state.Tasks.ContainsKey('win-11-lite finalize')) 'An unavailable firewall provider cannot be mistaken for a successfully removed block'
                }
                'edge-failure'{
                    $oldPf=$env:ProgramFiles;$oldX86=${env:ProgramFiles(x86)}
                    try{
                        $env:ProgramFiles=Join-Path $dir 'pf';${env:ProgramFiles(x86)}=$env:ProgramFiles
                        $browser=Join-Path $env:ProgramFiles 'Microsoft\Edge';$null=New-Item -ItemType Directory -Path $browser
                        function Remove-Item {[CmdletBinding()]param($LiteralPath,[switch]$Recurse,[switch]$Force)if($LiteralPath -eq $browser){throw 'Locked Edge fixture'};Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters}
                        [Win11Lite.OobeStatus]::Complete=$true
                        & (Join-Path $dir 'Finalize.ps1') -FirstLogon
                        Assert ($LASTEXITCODE -eq 1 -and $nic.AdminStatus -eq 'Up' -and -not $state.Firewall) 'Edge cleanup failure still restores adapters and removes firewall block'
                    }finally{$env:ProgramFiles=$oldPf;${env:ProgramFiles(x86)}=$oldX86}
                }
                'edge-only'{
                    & (Join-Path $dir 'Finalize.ps1') -EdgeOnly
                    Assert ($state.Firewall -and $nic.AdminStatus -eq 'Down') 'Guard Edge-only cleanup cannot restore OOBE networking'
                }
                'network-opt-out'{Assert (-not $state.Firewall -and $nic.AdminStatus -eq 'Up') 'NoOobeNetworkBlock leaves networking untouched'}
                'custom-oobe'{Assert (-not $state.Firewall -and $nic.AdminStatus -eq 'Up') 'Custom answer-file mode leaves networking untouched'}
                'late-prepare'{
                    [Win11Lite.OobeStatus]::Complete=$true
                    & (Join-Path $dir 'Finalize.ps1') -FirstLogon
                    & (Join-Path $dir 'Prepare.ps1') -RegisterOnly
                    Assert ($nic.AdminStatus -eq 'Up' -and -not $state.Firewall) 'Late SetupComplete cannot reblock networking after OOBE completion'
                }
            }
        }
    }
    Write-Host "PASS: $script:checks OOBE checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $env:USERNAME=$oldUser
    $expected=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\oobe-tests-'
    $full=[IO.Path]::GetFullPath($root)
    if($full.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $full -Recurse -Force}
}
