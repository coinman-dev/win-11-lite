#Requires -Version 5.1
# No elevation, DISM servicing, registry changes or real network operations.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$script:ScriptRoot=$repo
$sourcePath = Join-Path $repo 'win-11-lite.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$script:checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Assert $thrown $Message
}
$guardParameter=@($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath -eq 'Guard'})
Assert ($guardParameter.Count -eq 1 -and $guardParameter[0].StaticType -eq [string] -and $guardParameter[0].DefaultValue.Extent.Text -eq "'None'") 'Guard is one string parameter and defaults to None'
Assert ($guardParameter[0].Extent.Text -match "ValidateSet\('None','Standard','Debug','Silent'\)") 'Guard accepts exactly None, Standard, Debug and Silent'
Assert (-not @($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath -in @('GuardMode','GuardDebug')}).Count) 'Separate GuardMode and GuardDebug parameters are removed'
$wizardGuard=[regex]::Match($ast.Extent.Text,'(?ms)^    # 5\. Сторож.*?(?=^    # 6\.)').Value
Assert ($wizardGuard.Contains("-Values @('None','Standard','Debug','Silent') -Default `$guardDefault") -and $wizardGuard -notmatch 'Read-YesNo') 'The wizard uses one four-value Guard menu instead of separate enable and mode questions'
Assert ($wizardGuard -match "else\{2\}" -and $wizardGuard -match "'Standard —") 'The wizard defaults to Standard while the command-line parameter defaults to None'
$buildInfoNode=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$buildInfo'},$true)
Assert ($buildInfoNode.Extent.Text -match '(?m)^\s*Guard = \$Guard\s*$' -and $buildInfoNode.Extent.Text -notmatch 'GuardMode|GuardDebug') 'Build metadata stores the single Guard value without legacy duplicates'
# Load declarations and pure configuration only, never execute the build pipeline.
foreach ($name in @('T','Get-GuestScript','Test-DismSuccess','ConvertFrom-DismList','Test-GroupActive','Test-Protected','Get-ProtectedPatterns','Get-WindowsRelease','Get-EditionConfig','Assert-ChildPath','Test-SafeToWipe','Get-FodSourceName','Get-UpdateTarget','Get-ElevationCommand','Invoke-RegCommand','Invoke-NativeQuiet','Set-Reg','Mount-Hive','Dismount-Hives','Remove-Reg','Save-ImageAudit','Write-ComponentStoreReport','Write-ServicingRemovalFailure','Get-PackageRemovalSkipReason','Get-RequestedRemovalItems','Remove-OfflineRecall','Write-RemainingRemovalReport','Get-WebViewRuntimeRoots','Assert-ImageFileState','Get-ProgressLine','Update-ProgressState','Invoke-ProgressProcess','Get-CopyPercent','Assert-ImageLanguages','Write-WindowsBatchFile','Write-DiagnosticLog','Invoke-Dism')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $false)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:Lang = 'en'
foreach ($name in @('Get-FreeGB','Resolve-WorkDirectory','Set-ProgressValue')) {
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    . ([scriptblock]::Create($node.Extent.Text))
}
foreach ($name in @('Get-ImageInstallXml','Get-ProductKeyUiMode','Get-LocalAccountXml','Assert-LocalUserName','Get-SetupEntryCommand')) {
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    . ([scriptblock]::Create($node.Extent.Text))
}
foreach ($name in @('CapabilityRules','PackageRules','FolderRules','AppxRules','NeverRemove','AppPlatformProtected','FileRules','DisableServices')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$script:' + $name) }, $false)
    . ([scriptblock]::Create($node.Extent.Text))
}
$testRoot = Join-Path $repo ('tmp\tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
try {
    Assert (Test-DismSuccess 3010) 'DISM restart-required is success'
    Assert (-not (Test-DismSuccess 5)) 'DISM access denied is failure'
    & {
        $modeText = [regex]::Match($ast.Extent.Text, '(?ms)^\$script:DebugMode =.*?(?=^\$script:ScriptRoot)').Value
        $modeProbe = [scriptblock]::Create('[CmdletBinding()]param([string]$LogFile)' + "`n" + $modeText + "`n" + '[pscustomobject]@{Debug=$script:DebugMode;VerbosePreference=$VerbosePreference;DebugPreference=$DebugPreference}')
        $mode = & $modeProbe -Debug -Verbose
        Assert ($mode.Debug -and $mode.VerbosePreference -eq 'SilentlyContinue' -and $mode.DebugPreference -eq 'SilentlyContinue') 'Debug logging does not enable console verbose/debug streams'
        $mode = & $modeProbe -LogFile 'build.log' -Verbose
        Assert (-not $mode.Debug -and $mode.VerbosePreference -eq 'SilentlyContinue') 'Explicit LogFile also keeps technical console output quiet'
        $mode = & $modeProbe -Debug:$false
        Assert (-not $mode.Debug) 'Debug false does not activate logging'

        $setup = [regex]::Match($ast.Extent.Text, '(?ms)^#region[^\r\n]*Журналы сборки.*?^#endregion').Value
        Assert ([bool]$setup) 'Log initialization can be exercised without the build'
        $DryRun = $false; $LogFile = 'журнал сборки.log'; $script:DebugMode = $false
        $VerbosePreference = 'SilentlyContinue'
        Push-Location $testRoot
        try {
            . ([scriptblock]::Create($setup))
            Assert ($LogFile -eq (Join-Path $testRoot 'журнал сборки.log')) 'Relative LogFile follows the PowerShell working directory'
            Assert ($script:Transcribing -and $script:DetailLogPath -ne $LogFile -and $script:DismLogPath -ne $LogFile) 'Transcript and technical logs have separate writers'
            $VerbosePreference = 'Continue' # even an explicit caller preference must not print logged details
            $script:Dism = 'Invoke-FakeDism'; $script:CanDrawProgress = $false
            $fixture = @{Code=0}
            function Invoke-FakeDism { $global:LASTEXITCODE=$fixture.Code; 'Native diagnostic output' }
            $records = @(Invoke-Dism -Arguments @('/Image:C:\fake-mount','/Get-Features','/Format:List') -Quiet 4>&1)
            Assert ($records.Count -eq 1 -and $records[0].ExitCode -eq 0) 'Logging does not print verbose records or pollute the DISM result'
            $detail = Get-Content -LiteralPath $script:DetailLogPath -Raw -Encoding UTF8
            Assert ($detail.Contains('dism /English /Image:C:\fake-mount /Get-Features /Format:List') -and $detail.Contains('/LogLevel:4')) 'Exact DISM command is written to the technical file even without Debug'
            $fixture.Code=5
            Assert-Throws { Invoke-Dism -Arguments @('/Image:C:\fake-mount','/Get-Packages') -Quiet } 'Quiet console logging does not suppress DISM failures'
            $records = @(Write-DiagnosticLog 'Подробности oscdimg и шрифтов' 4>&1)
            Assert ($records.Count -eq 0 -and (Get-Content -LiteralPath $script:DetailLogPath -Raw).Contains('Подробности oscdimg и шрифтов')) 'Non-DISM technical messages are readable as UTF-8 in both runtimes without console output'
        } finally {
            if($script:Transcribing){Stop-Transcript|Out-Null;$script:Transcribing=$false}
            Pop-Location
        }
        $script:DetailLogPath=$null;$script:DismLogPath=$null;$script:DetailLogFailed=$false
        $records = @(Write-DiagnosticLog 'Explicit console diagnostic' 4>&1)
        Assert ($records.Count -eq 1 -and $records[0] -is [Management.Automation.VerboseRecord]) 'Explicit Verbose without logging remains available'
        $DryRun=$true;$LogFile=Join-Path $testRoot 'dryrun.log'
        . ([scriptblock]::Create($setup))
        Assert (-not (Test-Path -LiteralPath $LogFile) -and -not $script:DetailLogPath -and -not $script:DismLogPath) 'DryRun does not create log files or enable native logs'
        $script:DebugMode=$false;$global:LASTEXITCODE=0
    }
    & {
        $state = @{Percent=-1;Phase=1;Lines=[Collections.Generic.List[string]]::new()}
        foreach ($sample in @('36%','100%','1%','100%','The operation completed successfully.')) { Update-ProgressState -State $state -Text $sample }
        Assert ($state.Phase -eq 2 -and $state.Percent -eq 100 -and $state.Lines.Count -eq 1) 'Checkpoint percentage reset creates another DISM phase'
        foreach ($width in @(20,80,120)) {
            $line = Get-ProgressLine -Activity ('Applying windows11.0-kb5124008-x64_' + ('a' * 40) + '.msu') -Percent 36 -Phase 2 -Elapsed ([TimeSpan]::FromSeconds(4000)) -Width $width
            Assert ($line.Length -lt $width -and $line -notmatch '[\r\n]') "Progress never reaches the wrap column ($width)"
        }
        Assert ((Get-ProgressLine -Activity 'windows11.0-kb5124008-x64_longhash.msu' -Percent 1 -Phase 2 -Elapsed ([TimeSpan]::FromSeconds(1)) -Width 120) -match 'KB5124008') 'Progress retains KB while shortening update filenames'
        foreach ($lang in @('ru','en')) {
            $script:Lang=$lang
            $pending=Get-ProgressLine -Activity 'WinPE' -Percent 100 -Phase 2 -Elapsed ([TimeSpan]::FromSeconds(315)) -Width 132
            $next=Get-ProgressLine -Activity 'WinPE' -Percent 100 -Phase 2 -Elapsed ([TimeSpan]::FromSeconds(315.5)) -Width 132
            Assert ($pending -notmatch '100%|99%' -and $pending -match $(if($lang -eq 'ru'){'ожидание завершения'}else{'waiting for completion'})) "A live process at 100 percent has an honest waiting state ($lang)"
            Assert ($pending -ne $next) "Waiting indicator moves even before the elapsed second changes ($lang)"
            $finished=Get-ProgressLine -Activity 'WinPE' -Percent 100 -Elapsed ([TimeSpan]::FromSeconds(400)) -Width 132 -Done
            Assert ($finished -match '100%' -and $finished -match $(if($lang -eq 'ru'){'готово'}else{'done'})) "Only successful completion displays 100 percent ($lang)"
            $failed=Get-ProgressLine -Activity 'WinPE' -Percent 100 -Elapsed ([TimeSpan]::FromSeconds(400)) -Width 132 -Done -Failed
            Assert ($failed -notmatch '100%' -and $failed -match 'ERR') "Failure after reported 100 percent cannot look successful ($lang)"
            foreach($width in @(20,80,120)) {
                Assert ((Get-ProgressLine -Activity ('Long activity '+('x'*100)) -Percent 100 -Elapsed ([TimeSpan]::FromSeconds(315)) -Width $width).Length -lt $width) "Waiting line fits a narrow console ($lang/$width)"
            }
        }
        $script:Lang='en'
        & {
            $clock=@{Now=[datetime]'2026-09-14T12:00:00'}
            function Get-Date {$clock.Now}
            $state=@{Percent=-1;Phase=1;Lines=[Collections.Generic.List[string]]::new();LastProgressAt=$clock.Now}
            Update-ProgressState -State $state -Text '1%'
            $first=$state.LastProgressAt
            $clock.Now=$clock.Now.AddSeconds(299)
            Update-ProgressState -State $state -Text '1%'
            Update-ProgressState -State $state -Text 'Still servicing packages'
            Assert ($state.LastProgressAt -eq $first) 'Repeated percentage and ordinary output do not reset the inactivity timer'
            $clock.Now=$clock.Now.AddSeconds(1)
            $idle=$clock.Now-$state.LastProgressAt
            Assert ($idle.TotalSeconds -eq 300) 'Five-minute interval is measured from the last changed percentage'
            foreach($lang in @('ru','en')) {
                $script:Lang=$lang
                foreach($pct in @(0,1,50,99)) {
                    $active=Get-ProgressLine -Activity 'KB5129195' -Percent $pct -Phase 2 -Elapsed ([TimeSpan]::FromSeconds(1107)) -IdleFor ([TimeSpan]::FromMilliseconds(299999)) -Width 132
                    $idleLine=Get-ProgressLine -Activity 'KB5129195' -Percent $pct -Phase 2 -Elapsed ([TimeSpan]::FromSeconds(1107)) -IdleFor $idle -Width 132
                    $nextLine=Get-ProgressLine -Activity 'KB5129195' -Percent $pct -Phase 2 -Elapsed ([TimeSpan]::FromSeconds(1107.5)) -IdleFor ($idle+[TimeSpan]::FromMilliseconds(500)) -Width 132
                    Assert ($active -match ('\s'+$pct+'%') -and $active -notmatch '\.\.\.') "Percentage stays visible before five minutes ($lang/$pct)"
                    Assert ($idleLine -notmatch '%' -and $idleLine -match '\.\.\.\s+18:27' -and $idleLine -match '███' -and $idleLine -match 'KB5129195') "Five minutes changes any incomplete percentage into animation with the operation timer ($lang/$pct)"
                    Assert ($idleLine -ne $nextLine) "Stalled animation moves while keeping the same last percentage ($lang/$pct)"
                }
                $done=Get-ProgressLine -Activity 'KB5129195' -Percent 1 -Elapsed $idle -IdleFor $idle -Done -Width 132
                $failed=Get-ProgressLine -Activity 'KB5129195' -Percent 1 -Elapsed $idle -IdleFor $idle -Done -Failed -Width 132
                Assert ($done -match '100%' -and $done -notmatch '\.\.\.') "Success replaces stalled animation with completion ($lang)"
                Assert ($failed -match 'ERR' -and $failed -notmatch '100%|\.\.\.') "Failure replaces stalled animation with an error ($lang)"
                foreach($width in @(20,80,120)) {
                    Assert ((Get-ProgressLine -Activity ('Long activity '+('x'*100)) -Percent 1 -Elapsed $idle -IdleFor $idle -Width $width).Length -lt $width) "Stalled animation fits narrow consoles ($lang/$width)"
                }
            }
            $script:Lang='en'
            Update-ProgressState -State $state -Text '20%'
            Assert ($state.Percent -eq 20 -and $state.LastProgressAt -eq $clock.Now) 'New progress immediately ends the stalled interval'
            $clock.Now=$clock.Now.AddMinutes(5)
            Assert (($clock.Now-$state.LastProgressAt).TotalMinutes -eq 5) 'A second pause gets its own full five-minute interval'
            Update-ProgressState -State $state -Text '0%'
            Assert ($state.Phase -eq 2 -and $state.LastProgressAt -eq $clock.Now) 'A new phase resets inactivity even when its percentage decreases'
            $clock.Now=$clock.Now.AddMinutes(1)
            Update-ProgressState -State $state -Text '0,5%'
            Assert ($state.Percent -eq 0 -and $state.LastProgressAt -eq $clock.Now.AddMinutes(-1)) 'Fractional progress does not reset inactivity while the displayed integer stays unchanged'
            $clock.Now=$clock.Now.AddMinutes(1)
            Update-ProgressState -State $state -Text '0.5%'
            Assert ($state.LastProgressAt -eq $clock.Now.AddMinutes(-2)) 'Equivalent dot and comma percentages do not count as new progress'
            Update-ProgressState -State $state -Text '1%'
            $heldAt=$state.LastProgressAt
            foreach($fraction in @('1.1%','1.2%','1.3%','1,8%','1.9%')){
                $clock.Now=$clock.Now.AddMinutes(1)
                Update-ProgressState -State $state -Text $fraction
            }
            $stalled=Get-ProgressLine -Activity 'KB5129195' -Percent $state.Percent -IdleFor ($clock.Now-$state.LastProgressAt) -Elapsed ($clock.Now-$heldAt) -Width 132
            Assert ($state.LastProgressAt -eq $heldAt -and $stalled -match '\.\.\.' -and $stalled -notmatch '%') 'Five visible minutes at 1 percent animate despite regularly changing hidden fractions'
            Update-ProgressState -State $state -Text '2%'
            $resumed=Get-ProgressLine -Activity 'KB5129195' -Percent $state.Percent -IdleFor ($clock.Now-$state.LastProgressAt) -Elapsed ($clock.Now-$heldAt) -Width 132
            Assert ($state.LastProgressAt -eq $clock.Now -and $resumed -match '\s2%' -and $resumed -notmatch '\.\.\.') 'Reaching the next visible percentage immediately restores the bar'
        }
        $frames = [Collections.Generic.List[object]]::new()
        function Write-ProgressBar {
            param($Activity,$Percent,$Phase=1,[switch]$Done,[switch]$Failed,[TimeSpan]$IdleFor=[TimeSpan]::Zero)
            $elapsed=(Get-Date)-$script:ProgressStarted
            $rendered=Get-ProgressLine -Activity $Activity -Percent $Percent -Phase $Phase -Elapsed $elapsed -Width 132 -Done:$Done -Failed:$Failed -IdleFor $IdleFor
            $frames.Add([pscustomobject]@{Percent=$Percent;Phase=$Phase;Done=[bool]$Done;Failed=[bool]$Failed;Elapsed=$elapsed;IdleFor=$IdleFor;Line=$rendered})
        }
        $payload = '[Console]::Write("36%`r"); [Console]::Out.Flush(); Start-Sleep -Milliseconds 650; [Console]::Write("100%`r1%`r100%`r"); [Console]::Error.WriteLine("Simulated failure after progress reached 100%."); exit 5'
        $progressFixture = Join-Path $testRoot 'progress-simulation.ps1'
        [IO.File]::WriteAllText($progressFixture, $payload, [Text.UTF8Encoding]::new($true))
        $psExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $run = Invoke-ProgressProcess -Exe $psExe -Arguments @('-NoProfile','-NonInteractive','-File',$progressFixture) -Activity 'Native progress test'
        Assert ($run.ExitCode -eq 5 -and $run.Output -match 'Simulated failure') 'Native progress preserves stderr and failure status'
        Assert ($frames[-1].Done -and $frames[-1].Failed -and $frames[-1].Phase -eq 2) 'Reported 100 percent cannot turn a failed process into success'
        Assert (@($frames | Where-Object { $_.Percent -eq 36 -and -not $_.Done }).Count -gt 0) 'Native stream is processed before the child process exits'
        # oscdimg сообщает проценты в stderr, а сообщения печатает в stdout.
        $frames.Clear()
        $stderrPayload = '[Console]::Out.WriteLine("Writing files from " + $PWD.Path); [Console]::Error.WriteLine("7% complete"); [Console]::Error.Flush(); Start-Sleep -Milliseconds 650; [Console]::Error.WriteLine("100% complete"); exit 3'
        $stderrFixture = Join-Path $testRoot 'progress-stderr.ps1'
        [IO.File]::WriteAllText($stderrFixture, $stderrPayload, [Text.UTF8Encoding]::new($true))
        $run = Invoke-ProgressProcess -Exe $psExe -Arguments @('-NoProfile','-NonInteractive','-File',$stderrFixture) `
                                      -Activity 'StdErr progress test' -WorkingDirectory $testRoot -SuccessCodes @(0,3) -ProgressOnStdErr
        Assert ($run.ExitCode -eq 3 -and $frames[-1].Done -and -not $frames[-1].Failed) 'Success codes of the tool decide the outcome of the bar'
        Assert (@($run.Output | Where-Object { $_ -match [regex]::Escape($testRoot) }).Count -eq 1) 'Working directory reaches the process and its stdout is preserved'
        Assert (@($frames | Where-Object { $_.Percent -eq 7 -and -not $_.Done }).Count -gt 0) 'Percentages are read from stderr when the tool reports them there'
        # robocopy с /NP не печатает прогресс: процент приходит извне.
        $frames.Clear()
        $run = Invoke-ProgressProcess -Exe $psExe -Arguments @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Milliseconds 650') `
                                      -Activity 'External percentage test' -GetPercent { 42 }
        Assert ($run.ExitCode -eq 0 -and @($frames | Where-Object { $_.Percent -eq 42 -and -not $_.Done }).Count -gt 0) 'Silent tools take their percentage from -GetPercent'
        # A real child prints 100%, keeps running, then either succeeds or fails.
        foreach($resultCode in @(0,5)) {
            $frames.Clear()
            $fixture=Join-Path $testRoot "reported-100-$resultCode.ps1"
            $text='[Console]::Write("100%`r"); [Console]::Out.Flush(); Start-Sleep -Milliseconds 1400; exit '+$resultCode
            [IO.File]::WriteAllText($fixture,$text,[Text.UTF8Encoding]::new($true))
            $run=Invoke-ProgressProcess -Exe $psExe -Arguments @('-NoProfile','-NonInteractive','-File',$fixture) -Activity 'Reported 100 percent'
            $waiting=@($frames | Where-Object {$_.Percent -eq 100 -and -not $_.Done})
            Assert ($waiting.Count -ge 2 -and $waiting[-1].Elapsed -gt $waiting[0].Elapsed) "Timer updates while the child remains alive after 100 percent (exit $resultCode)"
            Assert (@($waiting | Where-Object {$_.Line -match '100%' -or $_.Line -notmatch 'waiting for completion'}).Count -eq 0) "Live native frames do not claim completion (exit $resultCode)"
            Assert ($run.ExitCode -eq $resultCode -and $frames[-1].Done -and $frames[-1].Failed -eq ($resultCode -ne 0)) "Exit status decides final state after the wait (exit $resultCode)"
        }
        & {
            # Both pipes can close before the process exits. Simulate EOF with
            # real TextReader tasks and a process whose lifetime is controlled.
            $frames.Clear()
            $fakeProcess=[pscustomobject]@{StartInfo=$null;StandardOutput=[IO.StringReader]::new("100%`r");StandardError=[IO.StringReader]::new('');ExitCode=0;Timer=[Diagnostics.Stopwatch]::new();EarlyWait=$false;Disposed=$false}
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name Start -Value {$this.Timer.Start();$true}
            $fakeProcess | Add-Member -MemberType ScriptProperty -Name HasExited -Value {$this.Timer.ElapsedMilliseconds -ge 1400}
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {$this.EarlyWait=-not $this.HasExited;while(-not $this.HasExited){[Threading.Thread]::Sleep(25)}}
            $fakeProcess | Add-Member -MemberType ScriptMethod -Name Dispose -Value {$this.Disposed=$true;$this.StandardOutput.Dispose();$this.StandardError.Dispose()}
            function New-Object {
                [CmdletBinding()]param([string]$TypeName,[object[]]$ArgumentList)
                if($TypeName -eq 'System.Diagnostics.Process'){$fakeProcess}else{Microsoft.PowerShell.Utility\New-Object @PSBoundParameters}
            }
            $run=Invoke-ProgressProcess -Exe 'never-executed.exe' -Activity 'Closed output streams'
            Assert (-not $fakeProcess.EarlyWait -and $fakeProcess.Disposed -and $run.ExitCode -eq 0) 'EOF does not cause a blocking wait before the process exits'
            Assert (@($frames | Where-Object {$_.Percent -eq 100 -and -not $_.Done}).Count -ge 2) 'Waiting indicator keeps refreshing after stdout/stderr close'
        }
        foreach($source in @('stdout','stderr','counter')) {
            & {
                # Real child processes with an accelerated parent clock exercise
                # repeated stalls and recovery without a five-minute test delay.
                $frames.Clear()
                $clock=[Diagnostics.Stopwatch]::StartNew()
                $epoch=[datetime]'2026-09-14T12:00:00'
                function Get-Date {$epoch.AddSeconds($clock.Elapsed.TotalSeconds*600)}
                $fixture=Join-Path $testRoot "stalled-$source.ps1"
                $writer=if($source -eq 'stderr'){'Error'}else{'Out'}
                $text=if($source -eq 'counter'){'Start-Sleep -Milliseconds 3600'}else{
                    'foreach($whole in 1,40){foreach($tenth in 0..7){[Console]::'+$writer+'.Write(([string]$whole+"."+$tenth+"%`r")); [Console]::'+$writer+'.Flush(); Start-Sleep -Milliseconds 175}}; [Console]::'+$writer+'.Write("75%`r"); [Console]::'+$writer+'.Flush(); Start-Sleep -Milliseconds 400'
                }
                [IO.File]::WriteAllText($fixture,$text,[Text.UTF8Encoding]::new($true))
                $options=@{Exe=$psExe;Arguments=@('-NoProfile','-NonInteractive','-File',$fixture);Activity="Stalled $source";ProgressOnStdErr=($source -eq 'stderr')}
                if($source -eq 'counter'){
                    $options.GetPercent={if($clock.Elapsed.TotalSeconds -lt 1.4){1+($clock.Elapsed.TotalSeconds%1)*0.8}elseif($clock.Elapsed.TotalSeconds -lt 2.8){40+($clock.Elapsed.TotalSeconds%1)*0.8}else{75}}
                }
                $run=Invoke-ProgressProcess @options
                foreach($pct in @(1,40)) {
                    Assert (@($frames | Where-Object {$_.Percent -eq $pct -and -not $_.Done -and $_.Line -match '\.\.\.' -and $_.IdleFor.TotalMinutes -ge 5}).Count -gt 0) "Real runner animates a five-minute pause ($source/$pct)"
                }
                foreach($pct in @(40,75)) {
                    Assert (@($frames | Where-Object {$_.Percent -eq $pct -and -not $_.Done -and $_.Line -match ('\s'+$pct+'%') -and $_.IdleFor.TotalMinutes -lt 5}).Count -gt 0) "Real runner resumes percentages after new data ($source/$pct)"
                }
                Assert ($run.ExitCode -eq 0 -and $frames[-1].Done -and $frames[-1].Line -match '100%') "Real runner still reports actual completion ($source)"
                Assert ($frames[0].Line -notmatch '\.\.\.') "Every new operation starts with a fresh inactivity timer ($source)"
            }
        }
        $copyRoot = Join-Path $testRoot 'copy-progress'
        $null = New-Item -ItemType Directory -Path $copyRoot
        [IO.File]::WriteAllBytes((Join-Path $copyRoot 'part.bin'), (New-Object byte[] 500))
        $script:CopyPercent = 0; $script:CopyPolled = $null
        Assert ((Get-CopyPercent -Path $copyRoot -TotalBytes 1000) -eq 50) 'Copy percentage is measured by bytes already on disk'
        [IO.File]::WriteAllBytes((Join-Path $copyRoot 'rest.bin'), (New-Object byte[] 500))
        Assert ((Get-CopyPercent -Path $copyRoot -TotalBytes 1000) -eq 50) 'The copied tree is not walked more often than every two seconds'
        $script:CopyPolled = (Get-Date).AddSeconds(-3)
        Assert ((Get-CopyPercent -Path $copyRoot -TotalBytes 1000) -eq 99) 'Only the finished process reports 100 percent'
    }
    $parsed = @(ConvertFrom-DismList -Key 'Capability Identity' -Lines @('Capability Identity : Language.Basic~~~ru-RU~0.0.1.0','State : Installed','Capability Identity : Test~~~~0.0.1.0','State : Not Present'))
    Assert ($parsed.Count -eq 2 -and $parsed[0].State -eq 'Installed') 'DISM multi-record parsing'
    $Keep = @('Speech'); $Preset = 'balanced'; $AddLanguage = @(); $DownloadLanguage = @(); $script:ImageLanguages = @('en-US')
    Assert (Test-Protected 'Language.Speech~~~ru-RU~0.0.1.0') 'Keep protects against RemoveExtra'
    Assert (-not (Test-GroupActive 'balanced' 'Speech')) 'Keep disables its removal group'
    $Keep = @(); $AddLanguage = @('ja-JP')
    Assert (-not (Test-GroupActive 'balanced' 'Fonts')) 'Japanese image keeps CJK input and fonts'
    $AddLanguage = @('ru-RU')
    Assert (Test-GroupActive 'balanced' 'Fonts') 'Russian image permits CJK cleanup'
    Assert ((Get-FodSourceName 'ru-RU') -eq 'Microsoft-Windows-LanguageFeatures-Basic-ru-ru-Package~31bf3856ad364e35~amd64~~.cab') 'Regression: CBS filename from the failing DISM log'
    $balanced = @($script:FolderRules | Where-Object { Test-GroupActive $_.Preset $_.Group })
    Assert (-not @($balanced | Where-Object { $_.Path -match 'EdgeWebView|EdgeUpdate|WinSxS\\Backup' }).Count) 'Balanced preserves WebView2 updater and component backups'
    $Preset = 'max'
    $maximum = @($script:FolderRules | Where-Object { Test-GroupActive $_.Preset $_.Group })
    Assert (@($maximum | Where-Object { $_.Path -match 'EdgeWebView|EdgeUpdate|WinSxS\\Backup' }).Count -eq 3) 'Max retains its original aggressive removals'
    $Keep = @('Edge')
    Assert (-not (Test-GroupActive 'max' 'Edge')) 'Keep Edge overrides max'
    Assert-Throws { Assert-ChildPath -Root $testRoot -Path (Split-Path $testRoot -Parent) } 'Parent deletion rejected'
    Assert-Throws { Assert-ChildPath -Root $testRoot -Path ($testRoot + '-other\file') } 'Sibling prefix collision rejected'
    Assert ((Assert-ChildPath -Root $testRoot -Path (Join-Path $testRoot 'child')) -eq (Join-Path $testRoot 'child')) 'Child path accepted'
    & {
        $leaf = Join-Path $testRoot 'wim-reparse-file'
        function Get-Item {
            param([string]$LiteralPath, [switch]$Force, $ErrorAction)
            if ($LiteralPath -eq $leaf) {
                [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint; PSIsContainer = $false }
            } else {
                Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
            }
        }
        Assert-Throws { Assert-ChildPath -Root $testRoot -Path $leaf } 'Leaf reparse point remains blocked by default'
        Assert ((Assert-ChildPath -Root $testRoot -Path $leaf -AllowLeafReparse) -eq $leaf) 'WIM leaf reparse point is allowed without traversing it'
    }
    $script:WorkDirLeaf = 'win-11-lite-work'; $script:ScriptRoot = $repo
    $InputIso = Join-Path $testRoot 'source.iso'; $OutputIso = Join-Path $testRoot 'out.iso'; $UpdatesDir = Join-Path $testRoot 'cache'
    $LanguageSource = ''; $Unattend = ''; $DriversDir = ''
    $work = Join-Path $testRoot 'win-11-lite-work'
    Assert (Test-SafeToWipe $work) 'Marked work layout in workspace is permitted'
    $InputIso = Join-Path $work 'iso\source.iso'
    Assert (-not (Test-SafeToWipe $work)) 'Work containing input ISO is protected'
    $InputIso = Join-Path $testRoot 'source.iso'
    & {
        # Read-only disk probe keeps full precision: 44.99 GB must not pass 45 GB.
        $probe=@{Free=44.99GB}
        function Get-PSDrive { param($Name,$ErrorAction) [pscustomobject]@{Free=$probe.Free} }
        Assert ((Get-FreeGB 'C:\fixture') -lt 45) 'Free-space comparison does not round a shortage up to the minimum'
        $probe.Free=$null
        Assert ($null -eq (Get-FreeGB 'C:\fixture')) 'Unavailable free-space measurement remains unknown'
    }
    & {
        $selection=[regex]::Match($ast.Extent.Text,'(?ms)^\$workFreeGB = Get-FreeGB.*?(?=^# Перед каждым прогоном)').Value
        if(-not $selection){throw 'Missing automatic disk selection'}
        $disk=@{Free=44.2GB;Calls=0}
        function Get-FreeGB {param($Path) 43.3}
        function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) $disk.Calls++;[pscustomobject]@{DeviceID='C:';FreeSpace=$disk.Free}}
        $defaultWork=Join-Path $testRoot 'default-work';$WorkDir=$defaultWork;$requiredGB=45
        $script:WorkDirExplicit=$false;$script:WorkDirMoved=$false
        . ([scriptblock]::Create($selection))
        Assert ($WorkDir -eq $defaultWork -and -not $script:WorkDirMoved) 'Automatic selection does not choose a larger disk that is still too small'
        $disk.Free=45GB
        . ([scriptblock]::Create($selection))
        Assert ($WorkDir -eq 'C:\win-11-lite-work' -and $script:WorkDirMoved) 'Automatic selection accepts a disk meeting the full requirement'
        $script:WorkDirExplicit=$true;$WorkDir=$defaultWork;$disk.Calls=0
        . ([scriptblock]::Create($selection))
        Assert ($WorkDir -eq $defaultWork -and $disk.Calls -eq 0) 'An explicit low-space path reaches the dialog instead of being silently replaced'
        $script:WorkDirExplicit=$false;$script:WorkDirMoved=$false
    }
    & {
        $low=Join-Path $testRoot 'low'
        $enough=Join-Path $testRoot 'enough space'
        $selected=Join-Path $enough 'win-11-lite-work'
        $file=Join-Path $testRoot 'not-a-directory.txt'
        [IO.File]::WriteAllText($file,'keep this file')
        $dialog=@{Can=$true;Free=43.3;Prompts=[Collections.Generic.List[string]]::new();Notes=[Collections.Generic.List[string]]::new();Answers=[Collections.Generic.Queue[string]]::new()}
        function Get-FreeGB {
            param($Path)
            if($Path -eq $selected){60}else{$dialog.Free}
        }
        function Test-CanPrompt {$dialog.Can}
        function Read-Host {
            param($Prompt)
            $dialog.Prompts.Add($Prompt)
            if(-not $dialog.Answers.Count){throw 'Unexpected prompt'}
            $dialog.Answers.Dequeue()
        }
        function Write-Note {param($Message) $dialog.Notes.Add($Message)}
        function Write-Ok {param($Message)}
        foreach($lang in @('ru','en')) {
            $script:Lang=$lang
            $dialog.Prompts.Clear();$dialog.Notes.Clear()
            # Blank, malformed, protected, file and still-low paths must all retry.
            foreach($answer in @(' ',('bad'+[char]0+'path'),$env:ProgramFiles,$file,$low,('"'+$enough+'"'))){$dialog.Answers.Enqueue($answer)}
            $result=Resolve-WorkDirectory -Path $low -RequiredGB 45
            Assert ($result -eq $selected -and $dialog.Prompts.Count -eq 6) "Space gate keeps asking until a safe directory has enough room ($lang)"
            Assert ($dialog.Notes[0] -match '43[.,]3' -and $dialog.Notes[0] -match '45') "Space gate explains actual and required capacity ($lang)"
            Assert ($dialog.Prompts[0] -match $(if($lang -eq 'ru'){'Введите другой рабочий каталог'}else{'Enter another work directory'})) "Replacement prompt follows the builder language ($lang)"
        }
        $script:Lang='en';$dialog.Prompts.Clear()
        $result=Resolve-WorkDirectory -Path ($selected+'\') -RequiredGB 45
        Assert ($result -eq $selected -and $dialog.Prompts.Count -eq 0) 'Valid existing work suffix is preserved without asking again'
        Push-Location $testRoot
        try {
            Assert ((Resolve-WorkDirectory -Path '.\enough space' -RequiredGB 45) -eq $selected) 'Relative replacement follows the PowerShell working directory'
        } finally {Pop-Location}
        $dialog.Free=30
        Assert ((Resolve-WorkDirectory -Path $low -RequiredGB 30) -eq (Join-Path $low 'win-11-lite-work')) 'The exact 30 GB threshold passes for a build without updates'
        $dialog.Free=45
        Assert ((Resolve-WorkDirectory -Path $low -RequiredGB 45) -eq (Join-Path $low 'win-11-lite-work')) 'The exact 45 GB threshold passes with updates'
        $dialog.Free=43.3;$dialog.Can=$false
        $failure=''
        try {Resolve-WorkDirectory -Path $low -RequiredGB 45 | Out-Null} catch {$failure=$_.Exception.Message}
        Assert ($failure -match 'Build stopped' -and $failure -match '-WorkDir') 'Non-interactive shortage is fatal and names the replacement parameter'
        $dialog.Free=44.99
        $failure=''
        try {Resolve-WorkDirectory -Path $low -RequiredGB 45 | Out-Null} catch {$failure=$_.Exception.Message}
        Assert ($failure -match '44[.,]9 GB' -and $failure -match 'Build stopped') 'A fractional shortage stops the build without rounding the display up to 45 GB'
        $dialog.Free=29.9
        Assert-Throws {Resolve-WorkDirectory -Path $low -RequiredGB 30} 'A build without updates also stops below its minimum'
        $dialog.Free=$null
        Assert-Throws {Resolve-WorkDirectory -Path $low -RequiredGB 45} 'An unmeasurable disk cannot silently start a real build'
        foreach($free in @(43.3,$null)) {
            $dialog.Free=$free
            Assert ((Resolve-WorkDirectory -Path $low -RequiredGB 45 -Preview) -eq (Join-Path $low 'win-11-lite-work')) 'DryRun can show a plan without sufficient or measurable space'
        }
        Assert ($dialog.Prompts.Count -eq 0) 'Non-interactive failures and DryRun never ask for input'
        $dialog.Can=$true;$dialog.Answers.Enqueue($enough)
        Assert ((Resolve-WorkDirectory -Path $low -RequiredGB 45) -eq $selected) 'Unknown capacity can be corrected through the same dialog'
        Assert ((Get-Content -LiteralPath $file -Raw) -eq 'keep this file' -and -not (Test-Path -LiteralPath $selected)) 'Validation does not create or remove work directories or input files'

        # Exercise actual path initialization, not a copy, so cache/mount paths follow the answer.
        $initialization=[regex]::Match($ast.Extent.Text,'(?ms)^\$WorkDir = Resolve-WorkDirectory.*?(?=^#region[^\r\n]*Журналы сборки)').Value
        if(-not $initialization){throw 'Missing work path initialization'}
        $DryRun=$false;$requiredGB=45;$UpdatesDir='';$WorkDir=$low
        $dialog.Free=43.3;$dialog.Answers.Enqueue($enough)
        . ([scriptblock]::Create($initialization))
        Assert ($WorkDir -eq $selected -and $mountDir -eq (Join-Path $selected 'mount') -and $isoDir -eq (Join-Path $selected 'iso') -and $bootMountDir -eq (Join-Path $selected 'bootmount') -and $wimPath -eq (Join-Path $selected 'install.wim')) 'All actual work paths use the accepted replacement'
        Assert ($UpdatesDir -eq (Join-Path $enough 'win-11-lite-updates')) 'Default cache moves beside the replacement work directory'
        $explicitCache=Join-Path $testRoot 'explicit-cache';$UpdatesDir=$explicitCache;$WorkDir=$low
        $dialog.Answers.Enqueue($enough)
        . ([scriptblock]::Create($initialization))
        Assert ($UpdatesDir -eq $explicitCache) 'An explicitly selected update cache is preserved'
        $dialog.Can=$false;$WorkDir=$low;$continued=$false
        try {. ([scriptblock]::Create($initialization));$continued=$true} catch {}
        Assert (-not $continued) 'Actual initialization cannot proceed after an uncorrected shortage'
    }
    $updateDir = Join-Path $testRoot 'updates'; $null = New-Item -ItemType Directory -Path $updateDir
    Set-Content -LiteralPath (Join-Path $updateDir 'checkpoint.msu') -Value ('x' * 100)
    Set-Content -LiteralPath (Join-Path $updateDir 'target.msu') -Value 'x'
    Assert-Throws { Get-UpdateTarget $updateDir } 'Ambiguous MSUs cannot be selected by size'
    Set-Content -LiteralPath (Join-Path $updateDir 'target.txt') -Value 'target.msu'
    Assert ((Get-UpdateTarget $updateDir).Name -eq 'target.msu') 'Explicit target wins over larger checkpoint'
    Assert-Throws { Get-UpdateTarget $updateDir '..\outside.msu' } 'Update target traversal rejected'
    $receiver = Join-Path $testRoot "parameter receiver's.ps1"
    [IO.File]::WriteAllText($receiver, 'param([string[]]$Keep,[bool]$IncludeDotNetUpdate,[string]$Guard,[switch]$Elevated) [pscustomobject]@{Keep=$Keep;DotNet=$IncludeDotNetUpdate;Guard=$Guard;Elevated=[bool]$Elevated}')
    $encoded = Get-ElevationCommand -ScriptPath $receiver -Parameters @{Keep=@('Edge','Fonts');IncludeDotNetUpdate=$false;Guard='Silent'}
    $received = & ([scriptblock]::Create([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))))
    Assert ($received.Keep.Count -eq 2 -and $received.Keep[1] -eq 'Fonts') 'Elevation preserves array parameters and quoted paths'
    Assert (-not $received.DotNet -and $received.Guard -eq 'Silent' -and $received.Elevated) 'Elevation preserves false booleans and the combined Guard mode'

    # Real native stderr/exit handling, read-only: PS 5.1 emits ErrorRecord objects.
    & {
        $PSNativeCommandUseErrorActionPreference = $true
        $native = Invoke-RegCommand -Arguments @('query', ('HKCU\win-11-lite-missing-' + [guid]::NewGuid().ToString('N')))
        Assert ($native.ExitCode -eq 1 -and $native.Output.Length -gt 0) 'Native registry failure preserves stderr and exit code'
        $native = Invoke-RegCommand -Arguments @('/?')
        Assert ($native.ExitCode -eq 0 -and $native.Output.Length -gt 0) 'Native registry success preserves stdout and exit code'
        Assert ($ErrorActionPreference -eq 'Stop' -and $PSNativeCommandUseErrorActionPreference) 'Native wrapper does not change caller error preferences'
    }
    # Native tools that write to stderr (takeown, icacls, reg delete on a missing
    # key) must not abort the build under Windows PowerShell 5.1 with Stop.
    & {
        $code = Invoke-NativeQuiet cmd.exe @('/c', 'echo simulated stderr 1>&2 & exit 3')
        Assert ($code -eq 3 -and $ErrorActionPreference -eq 'Stop') 'Quiet native wrapper returns the exit code despite stderr output'
        Remove-Reg -Path ('HKCU\win-11-lite-missing-' + [guid]::NewGuid().ToString('N'))
        Assert $true 'Deleting a missing registry key is not an error'
    }
    # Run the actual offline-registry stage. Reject the reported protected value
    # and record the replacement policy, without loading hives or writing HKLM.
    & {
        $regState = @{ Writes = @{}; FailName = 'TaskbarDa'; FailLoad = $false; FailUnload = $false }
        $regMessages = [Collections.Generic.List[string]]::new()
        function reg.exe {
            $global:LASTEXITCODE = 0
            $op = $args[0]
            if ($op -eq 'add') {
                $name = if ($args -contains '/v') { $args[[array]::IndexOf($args, '/v') + 1] } else { '' }
                if ($name -eq $regState.FailName) {
                    $global:LASTEXITCODE = 1
                    Write-Error 'SIMULATED: Access is denied.'
                    return
                }
                $regState.Writes[($args[1] + '|' + $name)] = $args[[array]::IndexOf($args, '/d') + 1]
            } elseif (($op -eq 'load' -and $regState.FailLoad) -or ($op -eq 'unload' -and $regState.FailUnload)) {
                $global:LASTEXITCODE = 1
                Write-Error 'SIMULATED: Hive is locked.'
                return
            }
            'The operation completed successfully.'
        }
        function Write-Stage { param($Message) }
        function Write-Ok { param($Message) }
        function Write-Fail { param($Message) $regMessages.Add($Message) }
        $mountDir = Join-Path $testRoot 'registry-mount'
        foreach ($relative in @('Windows\System32\config\SOFTWARE','Windows\System32\config\SYSTEM','Users\Default\NTUSER.DAT')) {
            $file = Join-Path $mountDir $relative
            $null = New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force
            $null = New-Item -ItemType File -Path $file
        }
        $script:LoadedHives = @(); $script:RemovedFonts = @(); $script:ManageOobe = $true
        $Preset = 'balanced'; $Keep = @(); $NoBypass = $false; $imgLang = 'ru-RU'
        $region = [regex]::Match($ast.Extent.Text, '(?ms)^#region[^\r\n]*Стадия 12\. Offline-реестр.*?^#endregion').Value
        if (-not $region) { throw 'Offline-registry stage not found' }
        & ([scriptblock]::Create($region))
        Assert ($regState.Writes['HKLM\LITE_SOFTWARE\Policies\Microsoft\Dsh|AllowNewsAndInterests'] -eq '0') 'Offline stage disables widgets without writing protected TaskbarDa'
        Assert ($regState.Writes['HKLM\LITE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|TaskbarMn'] -eq '0' -and
                $regState.Writes['HKLM\LITE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Start_IrisRecommendations'] -eq '0') 'Default profile settings after the former failure are applied'
        Assert ($script:LoadedHives.Count -eq 0) 'Offline-registry stage unloads all owned hives'
        Assert (-not $regState.Writes.ContainsKey('HKLM\LITE_DEFAULT\Control Panel\Desktop|PreferredUILanguages')) 'Language selection is left to Windows Setup instead of a registry override'
        Assert (-not $regState.Writes.ContainsKey('HKLM\LITE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\RunOnce|!Win11LiteFirstLogon')) 'No extra per-profile startup callback is installed'
        $successOutput = @(Set-Reg -Path 'HKLM\LITE_SOFTWARE\test' -Name '' -Type REG_DWORD -Value 0)
        Assert ($successOutput.Count -eq 0 -and $regState.Writes['HKLM\LITE_SOFTWARE\test|'] -eq '0') 'Set-Reg writes default values without emitting native output'
        foreach ($lang in @('ru','en')) {
            $script:Lang = $lang
            $failure = ''
            try { Set-Reg -Path 'HKLM\LITE_DEFAULT\test' -Name 'TaskbarDa' -Type REG_DWORD -Value 0 } catch { $failure = $_.Exception.Message }
            Assert ($failure -match 'HKLM\\LITE_DEFAULT\\test\\TaskbarDa' -and $failure -match 'SIMULATED: Access is denied\.' -and $failure -match '1') "Registry write failures remain fatal and preserve diagnostics ($lang)"
            Assert ($failure -match $(if ($lang -eq 'ru') { 'завершился ошибкой' } else { 'failed' })) "Registry failure summary is localized ($lang)"
        }
        $regState.FailName = 'AllowNewsAndInterests'
        Assert-Throws { & ([scriptblock]::Create($region)) } 'Failure of the replacement machine policy aborts the stage'
        Dismount-Hives
        $regState.FailLoad = $true
        $failure = ''
        try { Mount-Hive -Name 'LITE_DEFAULT' -File $file } catch { $failure = $_.Exception.Message }
        Assert ($failure -match 'SIMULATED: Hive is locked\.' -and $script:LoadedHives.Count -eq 0) 'Failed load retains diagnostics and does not register ownership'
        $regState.FailLoad = $false
        Mount-Hive -Name 'LITE_DEFAULT' -File $file
        $regState.FailUnload = $true
        Dismount-Hives
        Assert ($script:LoadedHives -contains 'LITE_DEFAULT' -and $regMessages[-1] -match 'SIMULATED: Hive is locked\.') 'Failed unload preserves ownership for cleanup and records diagnostics'
        $regState.FailUnload = $false
        Dismount-Hives
        Assert ($script:LoadedHives.Count -eq 0) 'Successful unload retry releases ownership'
    }

    & {
        $Preset = 'balanced'; $Keep = @(); $RemoveExtra = @('Language'); $AddLanguage = @()
        $servicing = @{
            Caps = [ordered]@{ 'Language.OCR~~~en-US~0.0.1.0' = 'Installed'; 'Language.Speech~~~en-US~0.0.1.0' = 'Staged'; 'Language.Handwriting~~~en-US~0.0.1.0' = 'Install Pending'; 'Language.Basic~~~ru-RU~0.0.1.0' = 'Installed' }
            Packages = [ordered]@{ 'Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~test' = 'Installed'; 'Microsoft-Windows-Hello-Face-Package~test' = 'Staged'; 'Microsoft-Windows-TabletPCMath-Package~test' = 'Install Pending' }
            Recall = 'Disabled'; AnalyzeFails = $false; AnalyzeThrows = $false; RestoreEdge = $false
        }
        $events = [Collections.Generic.List[string]]::new()
        $notes = [Collections.Generic.List[string]]::new()
        $mountDir = $testRoot
        $script:ImageAudit = [ordered]@{ ComponentStore = @(); RemovalFailures = @(); RemainingRemovals = @() }
        $script:ImageAuditPath = Join-Path $testRoot 'image-audit.json'
        function Write-Step { param($Message) $notes.Add($Message) }
        function Write-Note { param($Message) $notes.Add($Message) }
        function Write-Ok { param($Message) }
        function Write-Stage { param($Message) }
        function Format-Size { param($Bytes) "$Bytes bytes" }
        function Invoke-Dism {
            param($Arguments,[switch]$Quiet,[switch]$AllowFail,$Activity)
            $events.Add(($Arguments -join ' '))
            $code = 0; $lines = @()
            if ($Arguments -contains '/Get-Capabilities') {
                foreach ($entry in $servicing.Caps.GetEnumerator()) { $lines += "Capability Identity : $($entry.Key)", "State : $($entry.Value)" }
            } elseif ($Arguments -contains '/Get-Packages') {
                foreach ($entry in $servicing.Packages.GetEnumerator()) { $lines += "Package Identity : $($entry.Key)", "State : $($entry.Value)" }
            } elseif ($Arguments -contains '/Get-ProvisionedAppxPackages') {
                $lines = @('DisplayName : Microsoft.BingWeather', 'PackageName : Microsoft.BingWeather_test')
            } elseif ($Arguments -contains '/Get-Features') {
                $lines = @('Feature Name : Recall', "State : $($servicing.Recall)", 'Feature Name : NetFx3', 'State : Enabled')
            } elseif ($Arguments -contains '/Disable-Feature') {
                $servicing.Recall = 'Disabled with Payload Removed'
            } elseif ($Arguments -contains '/Remove-Capability') {
                $name = ($Arguments | Where-Object { $_ -like '/CapabilityName:*' }) -replace '^/CapabilityName:', ''
                if ($name -like 'Language.OCR*') { $code = -2146498523; $lines = @('Error: 0x800f0825', 'SIMULATED: Package cannot be uninstalled.') }
                else { $servicing.Caps[$name] = 'Not Present' }
            } elseif ($Arguments -contains '/Remove-Package') {
                $name = ($Arguments | Where-Object { $_ -like '/PackageName:*' }) -replace '^/PackageName:', ''
                $servicing.Packages[$name] = 'Not Present'
            } elseif ($Arguments -contains '/AnalyzeComponentStore') {
                if ($servicing.AnalyzeThrows) { throw 'SIMULATED: Native analysis could not start.' }
                if ($servicing.AnalyzeFails) { $code = 5; $lines = @('SIMULATED: Analysis unavailable.') }
                else { $lines = @('Actual Size of Component Store : 4.88 GB', '    Shared with Windows : 4.38 GB', '    Backups and Disabled Features : 506.90 MB', 'Number of Reclaimable Packages : 0') }
            } elseif ($Arguments -contains '/StartComponentCleanup' -and $servicing.RestoreEdge) {
                $null = New-Item -ItemType Directory -Path $browser -Force
                $null = New-Item -ItemType File -Path (Join-Path $browser 'msedge.exe') -Force
            }
            [pscustomobject]@{ ExitCode = $code; Output = $lines }
        }
        foreach ($regionName in @('Стадия 8\. Удаление возможностей', 'Стадия 9\. Удаление пакетов')) {
            $region = [regex]::Match($ast.Extent.Text, ('(?ms)^#region[^\r\n]*' + $regionName + '.*?^#endregion')).Value
            if (-not $region) { throw "Missing region: $regionName" }
            & ([scriptblock]::Create($region))
        }
        Assert ($servicing.Caps['Language.Speech~~~en-US~0.0.1.0'] -eq 'Not Present') 'Balanced removes selected staged capability payload'
        Assert ($servicing.Packages['Microsoft-Windows-Hello-Face-Package~test'] -eq 'Not Present') 'Balanced removes selected staged package payload'
        Assert (-not @($events | Where-Object { $_ -match '/Remove-.+(Handwriting|TabletPCMath)' }).Count) 'Pending packages are not forced through incomplete servicing'
        Assert ($servicing.Caps['Language.Basic~~~ru-RU~0.0.1.0'] -eq 'Installed') 'Update cleanup preserves required language even with RemoveExtra'
        Assert ($script:ImageAudit.RemovalFailures[0].HResult -eq '0x800F0825' -and $script:ImageAudit.RemovalFailures[0].Detail -match 'cannot be uninstalled') 'Removal failure retains HRESULT and actual DISM explanation'
        Assert (-not (Get-PackageRemovalSkipReason 'Microsoft-Windows-SenseClient-FoD-Package~neutral')) 'Sense package is not skipped merely because another component failed'
        Write-ServicingRemovalFailure -Kind Capability -Name 'Microsoft.Windows.Sense.Client~~~~' -Result ([pscustomobject]@{ExitCode=-2146498523;Output=@('Permanent package cannot be uninstalled.')})
        Assert ($script:ImageAudit.RemovalFailures[-1].Reason -eq 'PermanentPackage') 'CBS permanent-package refusal is identified from the actual error text'
        Assert ((Get-PackageRemovalSkipReason 'Microsoft-Windows-SenseClient-FoD-Package~31bf3856ad364e35~amd64~en-US~10.0.26100.9444') -match '0x800F0825') 'Language satellite is not retried after Sense capability refusal'
        $Preset='max'
        Assert (-not (Get-PackageRemovalSkipReason 'Microsoft-Windows-SenseClient-FoD-Package~neutral')) 'Sense retry policy in max remains unchanged'
        $Preset='balanced'
        Remove-OfflineRecall -Image $testRoot
        Assert ($servicing.Recall -eq 'Disabled with Payload Removed') 'Recall removal requested even when disabled but payload is present'
        $events.Clear(); $Preset = 'max'
        Remove-OfflineRecall -Image $testRoot
        Assert ($events.Count -eq 0) 'New Recall servicing does not alter max'
        $Preset = 'balanced'; $Keep = @('AI')
        Remove-OfflineRecall -Image $testRoot
        Assert ($events.Count -eq 0) 'Keep AI prevents Recall removal'
        $Keep = @(); $servicing.Recall = 'Disable Pending'
        Remove-OfflineRecall -Image $testRoot
        Assert (-not @($events | Where-Object { $_ -match '/Disable-Feature' }).Count) 'Pending Recall is reported without unsafe retry'
        Write-RemainingRemovalReport -Image $testRoot
        $left = @($script:ImageAudit.RemainingRemovals)
        Assert ($left.Count -eq 5 -and @($left | Where-Object { $_.State -match 'Pending' }).Count -eq 3) 'Final inventory exposes failed, pending and provisioned leftovers'
        Assert (-not @($left | Where-Object { $_.Name -match 'Basic|Hello|Speech' }).Count) 'Final inventory excludes protected and removed items'
        $Keep = @('Speech')
        Write-RemainingRemovalReport -Image $testRoot
        Assert (-not @($script:ImageAudit.RemainingRemovals | Where-Object { $_.Name -like 'Language.*' }).Count) 'Keep also protects pending items against RemoveExtra in the report'
        $Keep = @()
        Write-ComponentStoreReport -Image $testRoot -Phase 'source'
        Assert ($notes -contains 'Actual size : 4.88 GB') 'Size summary uses native hard-link-aware measurement'
        $servicing.AnalyzeFails = $true
        Write-ComponentStoreReport -Image $testRoot -Phase 'after-cleanup'
        $saved = Get-Content -LiteralPath $script:ImageAuditPath -Raw | ConvertFrom-Json
        Assert ($saved.ComponentStore.Count -eq 2 -and $saved.ComponentStore[1].ExitCode -eq 5) 'Unavailable analysis is recorded rather than presented as zero size'
        $servicing.AnalyzeThrows = $true
        Write-ComponentStoreReport -Image $testRoot -Phase 'probe-failure'
        Assert ($script:ImageAudit.ComponentStore[-1].ExitCode -eq -1) 'Failure to start optional size analysis does not abort the build'
        $servicing.AnalyzeThrows = $false

        # Simulate DISM recreating Edge after the first file-removal stage.
        $mountDir = Join-Path $testRoot 'serviced-mount'
        $browser = Join-Path $mountDir 'Program Files (x86)\Microsoft\Edge'
        $webRoot = Join-Path $mountDir 'Program Files (x86)\Microsoft\EdgeWebView'
        $newRuntime = Join-Path $webRoot 'Application\new-version\msedgewebview2.exe'
        $null = New-Item -ItemType Directory -Path (Split-Path $newRuntime -Parent) -Force
        $null = New-Item -ItemType File -Path $newRuntime
        $script:PreservedWebView = @($webRoot)
        $script:TaskFiles = @(); $Keep = @('Fonts'); $ResetBase = $false; $RemoveWinRE = $false
        $wimPath = Join-Path $testRoot 'serviced.wim'; $null = New-Item -ItemType File -Path $wimPath
        $servicing.RestoreEdge = $true
        function Remove-ImagePath {
            param($FullPath,$Description)
            $safe = Assert-ChildPath -Path $FullPath -Root $mountDir
            if (Test-Path -LiteralPath $safe) {
                $events.Add("delete-file:$safe")
                Remove-Item -LiteralPath $safe -Recurse -Force
            }
        }
        $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-SelectedImageFiles' }, $true)
        . ([scriptblock]::Create($node.Extent.Text))
        $commitStage = [regex]::Match($ast.Extent.Text, '(?ms)^Write-Stage \(T ''Очистка хранилища компонентов и фиксация образа''.*?(?=^#endregion)').Value
        if (-not $commitStage) { throw 'Final servicing stage not found' }
        $NoBypass = $true; $LegacySetup = $false; $setupPayload = $null
        $events.Clear()
        & ([scriptblock]::Create($commitStage))
        Assert (-not (Test-Path -LiteralPath $browser)) 'Final cleanup removes Edge restored by DISM'
        Assert (Test-Path -LiteralPath $newRuntime) 'Version replacement of WebView2 is accepted and the runtime survives'
        $deleteAt = $events.IndexOf("delete-file:$browser")
        $cleanupAt = $events.IndexOf(($events | Where-Object { $_ -match '/StartComponentCleanup' } | Select-Object -First 1))
        $commitAt = $events.IndexOf(($events | Where-Object { $_ -match '/Unmount-Image' } | Select-Object -First 1))
        Assert ($cleanupAt -lt $deleteAt -and $deleteAt -lt $commitAt) 'Restored files are removed after DISM cleanup and before commit'
        Remove-Item -LiteralPath $newRuntime -Force
        Assert-Throws { Assert-ImageFileState -Image $mountDir } 'Missing WebView2 still blocks commit'
        # Regression from the KB5124008 build: the LCU replaces the in-box WebView2
        # package, CBS unprojects the Program Files (x86) copy and the runtime
        # stays only in System32\Microsoft-Edge-WebView. That is not a removal.
        $stubDir = Join-Path $mountDir 'Windows\System32\Microsoft-Edge-WebView'
        $null = New-Item -ItemType Directory -Path $stubDir -Force
        $null = New-Item -ItemType File -Path (Join-Path $stubDir 'msedgewebview2.exe')
        Set-Content -LiteralPath (Join-Path $stubDir '151.0.4129.59.manifest') -Value 'x'
        $notesBefore = $notes.Count
        Assert-ImageFileState -Image $mountDir
        Assert ($notes.Count -eq $notesBefore + 1 -and $notes[-1] -match '151\.0\.4129\.59' -and $notes[-1] -match [regex]::Escape($webRoot)) 'Relocated in-box WebView2 after servicing is reported, not treated as a removal'
        Assert ($script:ImageAudit['WebView'].Present.Count -eq 1 -and $script:ImageAudit['WebView'].Versions -contains '151.0.4129.59') 'Image audit records where WebView2 remains and its version'
        Remove-Item -LiteralPath $stubDir -Recurse -Force
        Assert-Throws { Assert-ImageFileState -Image $mountDir } 'WebView2 missing from every known root still blocks commit'
        $script:ImageAuditPath = $null
    }

    $guestScript = Get-GuestScript
    $t = $null; $e = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($guestScript, [ref]$t, [ref]$e)
    Assert ($e.Count -eq 0) "The embedded guest runtime parses: $e"
    Assert ($guestScript -notmatch '__[A-Z]+__') 'The guest runtime carries no build-time placeholder'
    # Evaluate the actual answer-file expressions, then parse the resulting XML.
    $imgLang = 'ru-RU'; $setupLang = 'en-US'; $ProductKey = ''; $CompactOS = $false; $NoOobeNetworkBlock = $false
    $selected=[pscustomobject]@{EditionId='IoTEnterpriseS'}; $LocalUserName=''; $LocalUserPassword=$null
    $useVbsLauncher=$true
    foreach ($name in @('prepareCommand','registerCommand','finalizeCommand','setupInputLocale','compactBlock','localAccountXml','productKeyUi','escapedProductKey','productKeyValue','oobeNetBlock','unattendXml')) {
        $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$' + $name) }, $true)
        . ([scriptblock]::Create($node.Extent.Text))
    }
    $xml = [xml]$unattendXml
    $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable); $ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
    Assert ($xml.SelectSingleNode('//u:SetupUILanguage/u:UILanguage',$ns).InnerText -eq 'en-US') 'WinPE uses a language actually present in boot.wim'
    Assert (@($xml.SelectNodes('//u:InputLocale',$ns) | Where-Object { $_.InnerText -ne '0419:00000419;0409:00000409' }).Count -eq 0) 'Windows Setup configures both Russian and English keyboards without a logon language script'
    Assert ($xml.SelectSingleNode('//u:settings[@pass="windowsPE"]/u:component[@name="Microsoft-Windows-International-Core-WinPE"]/u:UILanguage',$ns).InnerText -eq 'ru-RU') 'Windows default language is not overwritten by English Setup UI'
    $firstCommand = $xml.SelectSingleNode('//u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine',$ns).InnerText
    Assert ($firstCommand -match 'Run-Setup\.vbs" finalize$' -and $firstCommand -match 'wscript\.exe') 'Answer file starts finalization through the windowless VBS launcher'
    Assert ($xml.SelectSingleNode('//u:RunSynchronousCommand/u:Path',$ns).InnerText -match 'Run-Setup\.vbs" prepare$') 'Specialize uses the windowless VBS launcher'
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$setupComplete'}, $true)
    . ([scriptblock]::Create($node.Extent.Text))
    Assert ($setupComplete -match 'wscript\.exe".*Run-Setup\.vbs" prepare-register' -and $setupComplete -match 'setupcomplete.log' -and $setupComplete -notmatch '>>[^\r\n]*prepare.log') 'SetupComplete waits for the hidden launcher without locking the preparation log'
    Assert ($xml.SelectSingleNode('//u:settings[@pass="specialize"]/u:component[@name="Microsoft-Windows-International-Core"]/u:UILanguage',$ns).InnerText -eq 'ru-RU') 'System language applied before OOBE'
    Assert ($xml.SelectSingleNode('//u:RunSynchronousCommand/u:Path',$ns).InnerText -match 'Run-Setup\.vbs" prepare$') 'Specialize registers finalization through the preparation mode'
    & {
        function Invoke-Dism { param($Arguments,[switch]$Quiet) [pscustomobject]@{ExitCode=0;Output=@('State : Installed')} }
        $image = Join-Path $testRoot 'language-image'
        $mui = Join-Path $image 'Windows\ImmersiveControlPanel\ru-RU\SystemSettings.exe.mui'
        $null = New-Item -ItemType Directory -Path (Split-Path $mui -Parent) -Force
        $null = New-Item -ItemType File -Path $mui
        Assert-Throws { Assert-ImageLanguages -Image $image -Languages 'ru-RU' -SourceLanguage 'en-US' } 'A Settings MUI alone is insufficient to validate Russian resources'
        foreach ($relative in @('Windows\ImmersiveControlPanel\pris\resources.ru-RU.pri','Windows\SystemResources\Windows.UI.SettingsAppThreshold\pris\Windows.UI.SettingsAppThreshold.ru-RU.pri')) {
            $path = Join-Path $image $relative
            $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force
            Set-Content -LiteralPath $path -Value 'nonempty fixture'
        }
        Assert-ImageLanguages -Image $image -Languages 'ru-RU' -SourceLanguage 'en-US'
        Assert $true 'Both Settings language resource locations are accepted'
        Clear-Content -LiteralPath $path
        Assert-Throws { Assert-ImageLanguages -Image $image -Languages 'ru-RU' -SourceLanguage 'en-US' } 'Empty Settings PRI is rejected'
    }

    # Execute generated scripts with mocked privileged APIs and a fake file tree.
    & {
        $testEvents = [Collections.Generic.List[string]]::new()
        $taskFailure = @{Enabled=$false}
        $testAdapters = @(
            [pscustomobject]@{InterfaceGuid='adapter-enabled'; AdminStatus='Up'},
            [pscustomobject]@{InterfaceGuid='adapter-disabled'; AdminStatus='Down'}
        )
        function New-ScheduledTaskAction { param($Execute,$Argument) [pscustomobject]@{Execute=$Execute;Argument=$Argument} }
        function New-ScheduledTaskTrigger { param([switch]$AtLogOn) [pscustomobject]@{Delay=''} }
        function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) Assert ($UserId -eq 'S-1-5-18') 'Finalizer uses SYSTEM'; 'principal' }
        function New-ScheduledTaskSettingsSet { param([switch]$StartWhenAvailable,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$MultipleInstances,$ExecutionTimeLimit) 'settings' }
        function Register-ScheduledTask { param($TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force) if($taskFailure.Enabled){throw 'Simulated unavailable scheduler'}; $testEvents.Add('register') }
        function Unregister-ScheduledTask { [CmdletBinding(SupportsShouldProcess)]param($TaskName) $testEvents.Add('unregister') }
        function Get-NetAdapter { param([switch]$IncludeHidden) $testAdapters }
        function Get-NetFirewallRule { param($Name,$PolicyStore,$ErrorAction) $null }
        function New-NetFirewallRule { param($Name,$DisplayName,$PolicyStore,$Enabled,$Direction,$Action,$Profile) }
        function Set-NetFirewallRule { param($Name,$PolicyStore,$Enabled,$Direction,$Action,$Profile) }
        function Remove-NetFirewallRule { param($Name,$PolicyStore,$ErrorAction) }
        function Start-Process { param($FilePath,$WindowStyle,$ArgumentList) $testEvents.Add('wait-oobe') }
        function Disable-NetAdapter { [CmdletBinding(SupportsShouldProcess)]param([Parameter(ValueFromPipeline)]$InputObject) process { $testEvents.Add('disable:'+$InputObject.InterfaceGuid); $InputObject.AdminStatus='Down' } }
        function Enable-NetAdapter { [CmdletBinding(SupportsShouldProcess)]param([Parameter(ValueFromPipeline)]$InputObject) process { $testEvents.Add('enable:'+$InputObject.InterfaceGuid); $InputObject.AdminStatus='Up' } }
        function Get-ItemProperty { param($LiteralPath,$Name,$ErrorAction) $null }
        function Get-Process { param($Name,$ErrorAction) @() }
        function Get-CimInstance { param($ClassName) @() }
        function takeown.exe { $global:LASTEXITCODE=0 }
        function icacls.exe { $global:LASTEXITCODE=0 }
        function Test-Path { [CmdletBinding()]param([Parameter(Position=0)]$Path,$LiteralPath) $p=if($LiteralPath){$LiteralPath}else{$Path}; if($p -like 'HKLM:*'){$false}else{Microsoft.PowerShell.Management\Test-Path -LiteralPath $p} }
        $oldProgramFiles=$env:ProgramFiles; $oldX86=${env:ProgramFiles(x86)}; $oldPublic=$env:PUBLIC; $oldData=$env:ProgramData
        if (-not ('Win11Lite.Oobe' -as [type])) {
            $compileTemp=$env:TEMP; $compileTmp=$env:TMP
            try {
                $env:TEMP=$testRoot; $env:TMP=$testRoot
                Add-Type 'namespace Win11Lite { public static class Oobe { public static bool Complete = true; public static bool OOBEComplete(out bool complete) { complete = Complete; return true; } } }'
            } finally { $env:TEMP=$compileTemp; $env:TMP=$compileTmp }
        }
        try {
            $env:ProgramFiles=Join-Path $testRoot 'pf'; ${env:ProgramFiles(x86)}=Join-Path $testRoot 'pf86'; $env:PUBLIC=Join-Path $testRoot 'public'; $env:ProgramData=Join-Path $testRoot 'data'
            $browser=Join-Path $env:ProgramFiles 'Microsoft\Edge'
            $webview=Join-Path $env:ProgramFiles 'Microsoft\EdgeWebView'
            $null=New-Item -ItemType Directory -Path $browser,$webview
            Set-Content -LiteralPath (Join-Path $browser 'msedge.exe') -Value 'browser'
            Set-Content -LiteralPath (Join-Path $webview 'msedgewebview2.exe') -Value 'runtime'
            $guest=Join-Path $testRoot 'Win11Lite.ps1'
            [IO.File]::WriteAllText($guest,(Get-GuestScript),[Text.UTF8Encoding]::new($true))
            $guestInfo=[ordered]@{BuildId='test';Language='en-US';Guard='None';OobeNetworkBlock=$true;ManageOobe=$true;RemoveEdge=$true}
            function Write-GuestInfo {$guestInfo|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $testRoot 'build-info.json') -Encoding UTF8}
            Write-GuestInfo
            & $guest -Mode prepare -Direct
            Assert ($testEvents[0] -eq 'disable:adapter-enabled') 'Specialize blocks network independently of Task Scheduler availability'
            Assert (@($testEvents | Where-Object {$_ -like 'disable:*'}).Count -eq 1) 'Only enabled adapters are disabled'
            & $guest -Mode finalize -Direct
            Assert (-not (Test-Path -LiteralPath $browser)) 'Restored Edge removed at first logon'
            Assert (Test-Path -LiteralPath (Join-Path $webview 'msedgewebview2.exe')) 'WebView2 survives finalization'
            Assert ($testEvents -contains 'enable:adapter-enabled') 'Changed adapter is restored'
            Assert ($testEvents -notcontains 'enable:adapter-disabled') 'Previously disabled adapter remains disabled'
            Assert (-not (Test-Path -LiteralPath (Join-Path $testRoot 'network-state.clixml'))) 'Network state removed after restoration'
            Assert ($testEvents -contains 'unregister') 'Successful finalizer removes its one-time task'
            # A cleanup failure must never leave the machine without connectivity.
            $testEvents.Clear()
            $null=New-Item -ItemType Directory -Path $browser
            Remove-Item -LiteralPath (Join-Path $testRoot 'oobe-complete') -Force
            function Remove-Item {
                [CmdletBinding()]param($LiteralPath,[switch]$Recurse,[switch]$Force)
                if ($LiteralPath -eq $browser) { throw 'Simulated locked browser' }
                Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force
            }
            & $guest -Mode prepare -Direct
            & $guest -Mode finalize -Direct
            Assert ($LASTEXITCODE -eq 1) 'Cleanup failure returns nonzero status'
            Assert ($testEvents -contains 'enable:adapter-enabled') 'Network restored despite Edge cleanup failure'
            Assert ($testEvents -notcontains 'unregister') 'Failed finalizer retains its retry task'
            $testEvents.Clear()
            Remove-Item -LiteralPath (Join-Path $testRoot 'oobe-complete') -Force
            [Win11Lite.Oobe]::Complete = $false
            function Get-ItemProperty { param($LiteralPath,$Name,$ErrorAction) if($LiteralPath -eq 'HKLM:\SYSTEM\Setup') { [pscustomobject]@{OOBEInProgress=1;SystemSetupInProgress=0} } }
            & $guest -Mode prepare -Direct
            & $guest -Mode finalize -Direct
            Assert ($testEvents -notcontains 'enable:adapter-enabled') 'OOBE defaultuser0 logon does not restore network early'
            Assert ($testEvents -notcontains 'unregister') 'OOBE logon retains the task for the real user'
            & $guest -Mode finalize -Direct
            Assert ($testEvents -notcontains 'enable:adapter-enabled' -and $testEvents -contains 'wait-oobe') 'FirstLogon cannot restore connectivity until Windows confirms OOBE completion'
            [Win11Lite.Oobe]::Complete = $true
            & $guest -Mode finalize -Direct
            Assert ($testEvents -contains 'enable:adapter-enabled') 'Native OOBE completion permits restoration even if registry flags lag behind'

            Assert (-not @('Prepare.ps1','Finalize.ps1','Run-Setup.ps1','Guard.UI.ps1','guard.ps1' | Where-Object { Test-Path -LiteralPath (Join-Path $testRoot $_) }).Count) 'One guest file serves preparation and finalization with no companion scripts'
            $guestInfo.Language='ru-RU';Write-GuestInfo
            $taskFailure.Enabled = $true
            $testEvents.Clear()
            Remove-Item -LiteralPath (Join-Path $testRoot 'oobe-complete') -Force
            & $guest -Mode prepare -Direct
            Assert ($testAdapters[0].AdminStatus -eq 'Down' -and $testEvents -notcontains 'register') 'Unavailable scheduler cannot leave OOBE online'
            & $guest -Mode finalize -Direct
            Assert ($testAdapters[0].AdminStatus -eq 'Up' -and $testAdapters[1].AdminStatus -eq 'Down') 'Direct first-logon callback restores only changed adapters without a registered task'
        } finally {
            $env:ProgramFiles=$oldProgramFiles; ${env:ProgramFiles(x86)}=$oldX86; $env:PUBLIC=$oldPublic; $env:ProgramData=$oldData
        }
    }
    Write-Host "PASS: $script:checks checks; PowerShell $($PSVersionTable.PSVersion)"
} finally {
    $safeRoot = [IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith("$safeRoot\tests-",[StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
