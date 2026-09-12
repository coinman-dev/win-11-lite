#Requires -Version 5.1
# No elevation, DISM servicing, registry changes or real network operations.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
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
# Load declarations and pure configuration only, never execute the build pipeline.
foreach ($name in @('T','Test-DismSuccess','ConvertFrom-DismList','Test-GroupActive','Test-Protected','Assert-ChildPath','Test-SafeToWipe','Get-FodSourceName','Get-UpdateTarget','Get-SetupSupportScripts','Get-GuardScript','Get-ElevationCommand','Invoke-RegCommand','Invoke-NativeQuiet','Set-Reg','Mount-Hive','Dismount-Hives','Remove-Reg','Save-ImageAudit','Write-ComponentStoreReport','Write-ServicingRemovalFailure','Get-PackageRemovalSkipReason','Get-RequestedRemovalItems','Remove-OfflineRecall','Write-RemainingRemovalReport','Get-WebViewRuntimeRoots','Assert-ImageFileState','Get-ProgressLine','Update-ProgressState','Invoke-ProgressProcess','Get-CopyPercent','Assert-ImageLanguages','Write-WindowsBatchFile','Write-DiagnosticLog','Invoke-Dism')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $false)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:Lang = 'en'
foreach ($name in @('CapabilityRules','PackageRules','FolderRules','AppxRules','NeverRemove','FileRules','DisableServices')) {
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
        $frames = [Collections.Generic.List[object]]::new()
        function Write-ProgressBar {
            param($Activity,$Percent,$Phase=1,[switch]$Done,[switch]$Failed)
            $elapsed=(Get-Date)-$script:ProgressStarted
            $rendered=Get-ProgressLine -Activity $Activity -Percent $Percent -Phase $Phase -Elapsed $elapsed -Width 132 -Done:$Done -Failed:$Failed
            $frames.Add([pscustomobject]@{Percent=$Percent;Phase=$Phase;Done=[bool]$Done;Failed=[bool]$Failed;Elapsed=$elapsed;Line=$rendered})
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
    $updateDir = Join-Path $testRoot 'updates'; $null = New-Item -ItemType Directory -Path $updateDir
    Set-Content -LiteralPath (Join-Path $updateDir 'checkpoint.msu') -Value ('x' * 100)
    Set-Content -LiteralPath (Join-Path $updateDir 'target.msu') -Value 'x'
    Assert-Throws { Get-UpdateTarget $updateDir } 'Ambiguous MSUs cannot be selected by size'
    Set-Content -LiteralPath (Join-Path $updateDir 'target.txt') -Value 'target.msu'
    Assert ((Get-UpdateTarget $updateDir).Name -eq 'target.msu') 'Explicit target wins over larger checkpoint'
    Assert-Throws { Get-UpdateTarget $updateDir '..\outside.msu' } 'Update target traversal rejected'
    $receiver = Join-Path $testRoot "parameter receiver's.ps1"
    [IO.File]::WriteAllText($receiver, 'param([string[]]$Keep,[bool]$IncludeDotNetUpdate,[switch]$Guard,[switch]$Elevated,[switch]$GuardDebug=$true) [pscustomobject]@{Keep=$Keep;DotNet=$IncludeDotNetUpdate;Guard=[bool]$Guard;Elevated=[bool]$Elevated;GuardDebug=[bool]$GuardDebug}')
    $encoded = Get-ElevationCommand -ScriptPath $receiver -Parameters @{Keep=@('Edge','Fonts');IncludeDotNetUpdate=$false;Guard=[switch]$false;GuardDebug=[switch]$false}
    $received = & ([scriptblock]::Create([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))))
    Assert ($received.Keep.Count -eq 2 -and $received.Keep[1] -eq 'Fonts') 'Elevation preserves array parameters and quoted paths'
    Assert (-not $received.DotNet -and -not $received.Guard -and $received.Elevated) 'Elevation preserves false bool/switch values'
    Assert (-not $received.GuardDebug) 'Elevation preserves an explicit GuardDebug false value'

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

    foreach ($lang in @('ru-RU','en-US')) {
        foreach ($block in @($true,$false)) {
            $support = Get-SetupSupportScripts -BlockNetwork $block -RemoveEdge $true -EnableGuard $true -Language $lang
            foreach ($name in @('Prepare','Finalize')) {
                $t = $null; $e = $null
                $null = [Management.Automation.Language.Parser]::ParseInput($support[$name], [ref]$t, [ref]$e)
                Assert ($e.Count -eq 0) "Generated $name parses ($lang, network=$block): $e"
                Assert ($support[$name] -notmatch '__[A-Z]+__') "No unresolved placeholders in $name"
            }
        }
    }
    # Evaluate the actual answer-file expressions, then parse the resulting XML.
    $imgLang = 'ru-RU'; $setupLang = 'en-US'; $ProductKey = ''; $CompactOS = $false; $NoOobeNetworkBlock = $false
    foreach ($name in @('setupInputLocale','compactBlock','oobeNetBlock','unattendXml')) {
        $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$' + $name) }, $true)
        . ([scriptblock]::Create($node.Extent.Text))
    }
    $xml = [xml]$unattendXml
    $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable); $ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
    Assert ($xml.SelectSingleNode('//u:SetupUILanguage/u:UILanguage',$ns).InnerText -eq 'en-US') 'WinPE uses a language actually present in boot.wim'
    Assert (@($xml.SelectNodes('//u:InputLocale',$ns) | Where-Object { $_.InnerText -ne '0419:00000419;0409:00000409' }).Count -eq 0) 'Windows Setup configures both Russian and English keyboards without a logon language script'
    Assert ($xml.SelectSingleNode('//u:settings[@pass="windowsPE"]/u:component[@name="Microsoft-Windows-International-Core-WinPE"]/u:UILanguage',$ns).InnerText -eq 'ru-RU') 'Windows default language is not overwritten by English Setup UI'
    $firstCommand = $xml.SelectSingleNode('//u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine',$ns).InnerText
    Assert ($firstCommand -match 'Win11Lite\.Run\.exe" finalize$' -and $firstCommand -notmatch '(powershell|cmd)\.exe') 'Answer file starts finalization without a console-subsystem executable'
    Assert ($xml.SelectSingleNode('//u:RunSynchronousCommand/u:Path',$ns).InnerText -match 'Win11Lite\.Run\.exe" prepare$') 'Specialize uses the windowless launcher'
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$setupComplete'}, $true)
    . ([scriptblock]::Create($node.Extent.Text))
    Assert ($setupComplete -match 'start "" /wait .*Win11Lite\.Run\.exe" prepare-register' -and $setupComplete -match 'setupcomplete.log' -and $setupComplete -notmatch '>>[^\r\n]*prepare.log') 'SetupComplete waits for the windowless launcher without locking the preparation log'
    Assert ($xml.SelectSingleNode('//u:settings[@pass="specialize"]/u:component[@name="Microsoft-Windows-International-Core"]/u:UILanguage',$ns).InnerText -eq 'ru-RU') 'System language applied before OOBE'
    Assert ($xml.SelectSingleNode('//u:RunSynchronousCommand/u:Path',$ns).InnerText -match 'Win11Lite\.Run\.exe" prepare$') 'Specialize registers finalization through the preparation mode'
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
    $guardScript = Get-GuardScript
    $t=$null; $e=$null
    $null=[Management.Automation.Language.Parser]::ParseInput($guardScript,[ref]$t,[ref]$e)
    Assert ($e.Count -eq 0) 'Generated guard parses'

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
        if (-not ('Win11Lite.OobeStatus' -as [type])) {
            $compileTemp=$env:TEMP; $compileTmp=$env:TMP
            try {
                $env:TEMP=$testRoot; $env:TMP=$testRoot
                Add-Type 'namespace Win11Lite { public static class OobeStatus { public static bool Complete = true; public static bool OOBEComplete(out bool complete) { complete = Complete; return true; } } }'
            } finally { $env:TEMP=$compileTemp; $env:TMP=$compileTmp }
        }
        try {
            $env:ProgramFiles=Join-Path $testRoot 'pf'; ${env:ProgramFiles(x86)}=Join-Path $testRoot 'pf86'; $env:PUBLIC=Join-Path $testRoot 'public'; $env:ProgramData=Join-Path $testRoot 'data'
            $browser=Join-Path $env:ProgramFiles 'Microsoft\Edge'
            $webview=Join-Path $env:ProgramFiles 'Microsoft\EdgeWebView'
            $null=New-Item -ItemType Directory -Path $browser,$webview
            Set-Content -LiteralPath (Join-Path $browser 'msedge.exe') -Value 'browser'
            Set-Content -LiteralPath (Join-Path $webview 'msedgewebview2.exe') -Value 'runtime'
            $support=Get-SetupSupportScripts -BlockNetwork $true -RemoveEdge $true -EnableGuard $false -Language 'en-US'
            foreach($name in @('Prepare','Finalize')) { [IO.File]::WriteAllText((Join-Path $testRoot "$name.ps1"),$support[$name],[Text.UTF8Encoding]::new($true)) }
            & (Join-Path $testRoot 'Prepare.ps1')
            Assert ($testEvents[0] -eq 'disable:adapter-enabled') 'Specialize blocks network independently of Task Scheduler availability'
            Assert (@($testEvents | Where-Object {$_ -like 'disable:*'}).Count -eq 1) 'Only enabled adapters are disabled'
            & (Join-Path $testRoot 'Finalize.ps1')
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
            & (Join-Path $testRoot 'Prepare.ps1')
            & (Join-Path $testRoot 'Finalize.ps1')
            Assert ($LASTEXITCODE -eq 1) 'Cleanup failure returns nonzero status'
            Assert ($testEvents -contains 'enable:adapter-enabled') 'Network restored despite Edge cleanup failure'
            Assert ($testEvents -notcontains 'unregister') 'Failed finalizer retains its retry task'
            $testEvents.Clear()
            Remove-Item -LiteralPath (Join-Path $testRoot 'oobe-complete') -Force
            [Win11Lite.OobeStatus]::Complete = $false
            function Get-ItemProperty { param($LiteralPath,$Name,$ErrorAction) if($LiteralPath -eq 'HKLM:\SYSTEM\Setup') { [pscustomobject]@{OOBEInProgress=1;SystemSetupInProgress=0} } }
            & (Join-Path $testRoot 'Prepare.ps1')
            & (Join-Path $testRoot 'Finalize.ps1')
            Assert ($testEvents -notcontains 'enable:adapter-enabled') 'OOBE defaultuser0 logon does not restore network early'
            Assert ($testEvents -notcontains 'unregister') 'OOBE logon retains the task for the real user'
            & (Join-Path $testRoot 'Finalize.ps1') -FirstLogon
            Assert ($testEvents -notcontains 'enable:adapter-enabled' -and $testEvents -contains 'wait-oobe') 'FirstLogon cannot restore connectivity until Windows confirms OOBE completion'
            [Win11Lite.OobeStatus]::Complete = $true
            & (Join-Path $testRoot 'Finalize.ps1') -FirstLogon
            Assert ($testEvents -contains 'enable:adapter-enabled') 'Native OOBE completion permits restoration even if registry flags lag behind'

            $support=Get-SetupSupportScripts -BlockNetwork $true -RemoveEdge $true -EnableGuard $false -Language 'ru-RU'
            Assert ($support.Count -eq 2) 'Only preparation and finalization scripts are generated'
            foreach($name in @('Prepare','Finalize')) { [IO.File]::WriteAllText((Join-Path $testRoot "$name.ps1"),$support[$name],[Text.UTF8Encoding]::new($true)) }
            $taskFailure.Enabled = $true
            $testEvents.Clear()
            Remove-Item -LiteralPath (Join-Path $testRoot 'oobe-complete') -Force
            & (Join-Path $testRoot 'Prepare.ps1')
            Assert ($testAdapters[0].AdminStatus -eq 'Down' -and $testEvents -notcontains 'register') 'Unavailable scheduler cannot leave OOBE online'
            & (Join-Path $testRoot 'Finalize.ps1') -FirstLogon
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
