#Requires -Version 5.1
# Pure rules and generated files; DISM and guest system operations are mocked.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in 'T','Get-WindowsRelease','Get-EditionConfig','Get-ProtectedPatterns','Test-Protected','Test-GroupActive','ConvertFrom-DismList','Test-DismSuccess','Get-RequestedRemovalItems','Remove-OfflineFeatures'){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:Lang='en'; $script:checks=0; $Keep=@(); $AddLanguage=@(); $DownloadLanguage=@(); $script:ImageLanguages=@('ru-RU')
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
foreach($name in 'CapabilityRules','PackageRules','AppxRules','NeverRemove','AppPlatformProtected','DisableServices','FolderRules','FileRules','FeatureRules'){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$script:'+$name)},$false)
    . ([scriptblock]::Create($node.Extent.Text))
}

foreach($entry in @{22000='21H2';22621='22H2';22631='23H2';26100='24H2';26200='25H2';28000='26H1'}.GetEnumerator()){
    Assert ((Get-WindowsRelease $entry.Key) -eq $entry.Value) "Build $($entry.Key) selects its own Windows release and update cache"
}
foreach($build in 0,26300,29531){
    $failed=$false;try{Get-WindowsRelease $build|Out-Null}catch{$failed=$true}
    Assert $failed "Unknown branch $build cannot select another release's updates"
}
$node=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$winVersion'},$false)
$buildNumber=28000
. ([scriptblock]::Create($node.Extent.Text))
Assert ($winVersion -eq '26H1') 'The actual build pipeline uses the release resolver'
$selected=[pscustomobject]@{EditionId='IoTEnterpriseS'};$buildNumber=19041
. ([scriptblock]::Create($node.Extent.Text))
Assert ($winVersion -eq '21H2') 'The build pipeline passes the edition, so LTSC 2021 media (XML build 19041) resolves to 21H2'

# Windows 10: XML носителя 2004–22H2 хранит базовый build 19041.
foreach($case in @(
    @{Build=19041;Edition='IoTEnterpriseS';Release='21H2'},@{Build=19041;Edition='EnterpriseS';Release='21H2'},
    @{Build=19041;Edition='EnterpriseSN';Release='21H2'},@{Build=19041;Edition='Professional';Release='22H2'},
    @{Build=19041;Edition='Core';Release='22H2'},@{Build=19044;Edition='Professional';Release='21H2'},@{Build=19045;Edition='Core';Release='22H2'})){
    Assert ((Get-WindowsRelease $case.Build $case.Edition) -eq $case.Release) "Windows 10 $($case.Build) $($case.Edition) selects $($case.Release) updates"
}
foreach($build in 17763,19042,19043){
    $failed=$false;try{Get-WindowsRelease $build 'EnterpriseS'|Out-Null}catch{$failed=$true}
    Assert $failed "Unsupported Windows 10 branch $build is rejected instead of borrowing 19041 updates"
}

# Решения по установщику, обходу TPM и языкам — настоящий блок сборщика.
$decision=$ast.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$isWindows10' -and $n.Extent.Text -match 'LegacySetup is unnecessary'},$true)
if(-not $decision){throw 'Windows 10 setup decision block not found'}
$runDecision={
    param([hashtable]$State)
    $notes=[Collections.Generic.List[string]]::new()
    function Write-Note {param($Message)$notes.Add($Message)}
    $isWindows10=$State.Windows10;$LegacySetup=[bool]$State.Legacy;$NoBypass=$false;$TrimSources=[bool]$State.Trim;$RemoveWinRE=[bool]$State.RemoveWinRE
    # Ключи не Add/Remove: у хеш-таблицы это методы, а не значения.
    $Keep=@($State.Keep);$AddLanguage=@($State.AddLanguage);$DownloadLanguage=@($State.DownloadLanguage)
    $SetupLanguage=if($State.Setup){$State.Setup}else{'auto'};$sourceImageLanguage='ru-RU'
    . ([scriptblock]::Create($decision.Extent.Text))
    [pscustomobject]@{Legacy=$LegacySetup;NoBypass=$NoBypass;Notes=@($notes)}
}
$r=& $runDecision @{Windows10=$true;Legacy=$true;Trim=$true;RemoveWinRE=$true}
Assert (-not $r.Legacy -and $r.NoBypass -and $r.Notes.Count -eq 1) 'Windows 10 ignores -LegacySetup (no /legacy winpeshl.ini) and skips the Windows 11 TPM bypass'
$r=& $runDecision @{Windows10=$true;Trim=$true;RemoveWinRE=$true}
Assert (-not $r.Legacy -and -not $r.Notes.Count) 'Windows 10 trims sources and removes WinRE without requiring -LegacySetup'
foreach($state in @(@{Windows10=$true;AddLanguage=@('en-US')},@{Windows10=$true;DownloadLanguage=@('en-US')},@{Windows10=$true;Setup='en-US'})){
    $failed=$false;try{& $runDecision $state|Out-Null}catch{$failed=$true}
    Assert $failed "Windows 10 rejects unsupported language work before downloads: $(($state.Keys|Sort-Object) -join ',')"
}
foreach($setup in 'original','ru-RU'){ Assert ((& $runDecision @{Windows10=$true;Setup=$setup}).NoBypass) "Windows 10 accepts the source Setup language ($setup)" }
foreach($state in @(@{Windows10=$false;Trim=$true},@{Windows10=$false;RemoveWinRE=$true})){
    $failed=$false;try{& $runDecision $state|Out-Null}catch{$failed=$true}
    Assert $failed "Windows 11 still requires -LegacySetup: $(($state.Keys|Sort-Object) -join ',')"
}
$r=& $runDecision @{Windows10=$false;RemoveWinRE=$true;Keep=@('WinRE')}
Assert (-not $r.NoBypass) 'Windows 11 keeps WinRE without -LegacySetup and keeps its TPM bypass'
$r=& $runDecision @{Windows10=$false;Legacy=$true;Trim=$true;RemoveWinRE=$true}
Assert ($r.Legacy -and -not $r.NoBypass -and -not $r.Notes.Count) 'Windows 11 keeps -LegacySetup and the TPM bypass unchanged'

# -AutoInstall: настоящие проверки основного потока.
$keyCheck=$ast.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -match 'needs -ProductKey'},$true)
$unattendCheck=$ast.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -match '-AutoInstall cannot be combined with -Unattend'},$true)
if(-not $keyCheck -or -not $unattendCheck){throw 'AutoInstall validation not found'}
foreach($edition in 'Core','CoreSingleLanguage','Professional','ProfessionalN'){
    $failed=$false;try{& {$AutoInstall=$true;$ProductKey='';$selected=[pscustomobject]@{EditionId=$edition};. ([scriptblock]::Create($keyCheck.Extent.Text))}}catch{$failed=$true}
    Assert $failed "AutoInstall of $edition without a key stops before downloads instead of at Setup's key prompt"
}
foreach($case in @(@{Auto=$true;Key='';Edition='IoTEnterpriseS'},@{Auto=$true;Key='AAAAA-BBBBB-CCCCC-DDDDD-EEEEE';Edition='Professional'},@{Auto=$false;Key='';Edition='Core'})){
    & {$AutoInstall=$case.Auto;$ProductKey=$case.Key;$selected=[pscustomobject]@{EditionId=$case.Edition};. ([scriptblock]::Create($keyCheck.Extent.Text))}
    Assert $true "No key is required for $($case.Edition) (AutoInstall=$($case.Auto), key given=$([bool]$case.Key))"
}
# Вопрос мастера о встроенном антивирусе — настоящий блок сборщика.
$defenderQuestion=$ast.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq "`$Preset -ne 'safe'" -and $n.Extent.Text -match 'Remove the built-in antivirus'},$true)
if(-not $defenderQuestion){throw 'Wizard antivirus question not found'}
$askDefender={
    param([string]$PresetName,[string[]]$KeepGroups,$Answer,[string]$Language='ru')
    $asked=[Collections.Generic.List[object]]::new();$shown=[Collections.Generic.List[string]]::new()
    function Read-YesNo {param($Question,[bool]$Default)$asked.Add([pscustomobject]@{Question=$Question;Default=$Default});if($null -eq $Answer){$Default}else{$Answer}}
    function Write-Host {param($Object,$ForegroundColor)$shown.Add([string]$Object)}
    $script:Lang=$Language;$Preset=$PresetName;$Keep=@($KeepGroups)
    . ([scriptblock]::Create($defenderQuestion.Extent.Text))
    $active=Test-GroupActive -RulePreset 'balanced' -Group 'Defender'
    $script:Lang='en'
    [pscustomobject]@{Asked=@($asked);Shown=($shown -join "`n");Keep=@($Keep);Active=$active}
}
$r=& $askDefender 'safe' @() $null
Assert (-not $r.Asked.Count -and -not $r.Keep.Count) 'The safe preset keeps Defender anyway, so the wizard does not ask'
$r=& $askDefender 'balanced' @() $null
Assert ($r.Asked.Count -eq 1 -and $r.Asked[0].Default -and $r.Active -and -not $r.Keep.Count) 'Enter removes the built-in antivirus by default'
Assert ($r.Asked[0].Question -eq 'Удалить встроенный антивирус?' -and $r.Shown -match 'только если будете устанавливать другой антивирус' -and $r.Shown -match 'без защиты') 'The Russian question warns to remove it only when another antivirus will be installed'
$r=& $askDefender 'balanced' @() $false
Assert (-not $r.Active -and ($r.Keep -join ',') -eq 'Defender') 'Answering no keeps Defender through -Keep Defender, so neither removal nor guard touches it'
$r=& $askDefender 'max' @('Defender','WinRE') $true
Assert (-not $r.Asked[0].Default -and ($r.Keep -join ',') -eq 'WinRE' -and $r.Active) 'An existing -Keep Defender becomes the default answer and yes removes only that group from -Keep'
$r=& $askDefender 'balanced' @() $null 'en'
Assert ($r.Asked[0].Question -eq 'Remove the built-in antivirus?' -and $r.Shown -match 'only if you are going to install another antivirus') 'The English wizard carries the same question and warning'

# Виртуализация: состав, пресеты, удаление и вопрос мастера.
$virtualNames='Microsoft-Hyper-V-All','Microsoft-Hyper-V','Microsoft-Hyper-V-Tools-All','Microsoft-Hyper-V-Management-PowerShell','Microsoft-Hyper-V-Hypervisor','Microsoft-Hyper-V-Services','Microsoft-Hyper-V-Management-Clients','Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform','HypervisorPlatform','Containers-DisposableClientVM','Containers','Windows-Defender-ApplicationGuard'
$otherNames='NetFx3','NetFx4-AdvSrvs','Recall','Printing-PrintToPDFServices-Features','SMB1Protocol','MicrosoftWindowsPowerShellV2Root','Client-ProjFS','TelnetClient','Containers-HNS-Legacy'
$virtualPatterns=@($script:FeatureRules|Where-Object Group -eq 'Virtualization'|ForEach-Object Pattern)
foreach($name in $virtualNames){Assert (@($virtualPatterns|Where-Object{$name -match $_}).Count -eq 1) "$name belongs to exactly one virtualization rule"}
foreach($name in $otherNames){Assert (-not @($script:FeatureRules|Where-Object{$name -match $_.Pattern}).Count) "$name is not treated as a virtualization feature"}
$virtualActive={param($PresetName,[string[]]$KeepGroups,[bool]$Switch)$Preset=$PresetName;$Keep=@($KeepGroups);$RemoveVirtualization=$Switch;Test-GroupActive -RulePreset 'max' -Group 'Virtualization'}
Assert (-not (& $virtualActive 'safe' @() $false) -and -not (& $virtualActive 'balanced' @() $false)) 'safe and balanced keep Hyper-V and WSL by default'
Assert (& $virtualActive 'max' @() $false) 'max removes virtualization by default'
Assert (-not (& $virtualActive 'max' @('Virtualization') $false)) '-Keep Virtualization keeps it in max'
Assert ((& $virtualActive 'balanced' @() $true) -and (& $virtualActive 'safe' @() $true)) '-RemoveVirtualization removes it in any preset'
& {
    $Preset='max';$Keep=@();$RemoveVirtualization=$false
    $calls=[Collections.Generic.List[string]]::new();$failures=[Collections.Generic.List[string]]::new()
    $list=@('Feature Name : Microsoft-Hyper-V-All','State : Disabled','','Feature Name : Microsoft-Windows-Subsystem-Linux','State : Enabled','','Feature Name : VirtualMachinePlatform','State : Disabled with Payload Removed','',
            'Feature Name : Containers-DisposableClientVM','State : Enable Pending','','Feature Name : HypervisorPlatform','State : Disabled','','Feature Name : NetFx3','State : Disabled','')
    function Invoke-Dism {param($Arguments,[switch]$AllowFail,[switch]$Quiet,$Activity)
        $calls.Add(($Arguments -join ' '))
        if($Arguments -contains '/Get-Features'){return [pscustomobject]@{ExitCode=0;Output=$list}}
        [pscustomobject]@{ExitCode=$(if($Arguments -contains '/FeatureName:HypervisorPlatform'){87}else{0});Output=@()}
    }
    function Write-ServicingRemovalFailure {param($Kind,$Name,$Result)$failures.Add("${Kind}:$Name")}
    function Write-Step {param($Message)};function Write-Ok {param($Message)};function Write-Note {param($Message)}
    Remove-OfflineFeatures -Image 'C:\mount'
    $disabled=@($calls|Where-Object{$_ -match '/Disable-Feature'})
    Assert ($disabled.Count -eq 3 -and @($disabled|Where-Object{$_ -match '/Remove$'}).Count -eq 3) 'Selected features are disabled together with their payload'
    Assert (($disabled -join ';') -match 'Microsoft-Hyper-V-All' -and ($disabled -join ';') -match 'Microsoft-Windows-Subsystem-Linux' -and ($disabled -join ';') -notmatch 'VirtualMachinePlatform|DisposableClientVM|NetFx3') 'Already removed, pending and unrelated features are left alone'
    Assert ($failures.Count -eq 1 -and $failures[0] -eq 'Feature:HypervisorPlatform') 'A DISM failure is recorded and the next feature is still processed'
    $calls.Clear();$Preset='balanced'
    Remove-OfflineFeatures -Image 'C:\mount'
    Assert (-not $calls.Count) 'balanced without -RemoveVirtualization does not even query the feature list'
}
$wizardText=[regex]::Match($ast.Extent.Text,'(?ms)^    # 4b\. Виртуализация.*?(?=^    # 5\. Сторож)').Value
if(-not $wizardText){throw 'Wizard virtualization question not found'}
$askVirtual={
    param([string]$PresetName,[string[]]$KeepGroups,[bool]$Switch,$Answer,[string]$Language='ru')
    $asked=[Collections.Generic.List[object]]::new();$shown=[Collections.Generic.List[string]]::new()
    function Read-YesNo {param($Question,[bool]$Default)$asked.Add([pscustomobject]@{Question=$Question;Default=$Default});if($null -eq $Answer){$Default}else{$Answer}}
    function Write-Host {param($Object,$ForegroundColor)$shown.Add([string]$Object)}
    $script:Lang=$Language;$Preset=$PresetName;$Keep=@($KeepGroups);$RemoveVirtualization=$Switch
    . ([scriptblock]::Create($wizardText))
    $active=Test-GroupActive -RulePreset 'max' -Group 'Virtualization'
    $script:Lang='en'
    [pscustomobject]@{Default=$asked[0].Default;Question=$asked[0].Question;Shown=($shown -join "`n");Keep=@($Keep);Switch=[bool]$RemoveVirtualization;Active=$active}
}
foreach($case in @(@{Preset='safe';Default=$false},@{Preset='balanced';Default=$false},@{Preset='max';Default=$true})){
    $r=& $askVirtual $case.Preset @() $false $null
    Assert ($r.Default -eq $case.Default -and $r.Active -eq $case.Default -and -not $r.Switch -and -not $r.Keep.Count) "Enter keeps the $($case.Preset) default: remove=$($case.Default)"
}
$r=& $askVirtual 'balanced' @() $false $null
Assert ($r.Question -eq 'Удалить компоненты виртуализации?' -and $r.Shown -match 'только если не будете пользоваться виртуализацией' -and $r.Shown -match 'Диспетчером Hyper-V' -and $r.Shown -match 'WSL2') 'The Russian question names Hyper-V Manager and WSL2 and warns to remove them only without virtualization'
$r=& $askVirtual 'balanced' @() $false $true
Assert ($r.Switch -and $r.Active -and -not $r.Keep.Count) 'Yes in balanced sets -RemoveVirtualization'
$r=& $askVirtual 'max' @() $false $false
Assert (-not $r.Active -and ($r.Keep -join ',') -eq 'Virtualization' -and -not $r.Switch) 'No in max keeps virtualization through -Keep Virtualization'
$r=& $askVirtual 'max' @('Virtualization','WinRE') $false $true
Assert (-not $r.Default -and $r.Active -and ($r.Keep -join ',') -eq 'WinRE' -and -not $r.Switch) 'An existing -Keep Virtualization is the max default, and yes drops only that group'
$r=& $askVirtual 'balanced' @() $false $null 'en'
Assert ($r.Question -eq 'Remove the virtualization features?' -and $r.Shown -match 'only if you will not use virtualization') 'The English wizard carries the same question and warning'
$conflict=$ast.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -match 'Use either -RemoveVirtualization or -Keep Virtualization'},$true)
$failed=$false;try{& {$RemoveVirtualization=$true;$Keep=@('Virtualization');. ([scriptblock]::Create($conflict.Extent.Text))}}catch{$failed=$true}
Assert $failed '-RemoveVirtualization together with -Keep Virtualization is rejected'

foreach($answer in 'none','custom.xml'){
    $failed=$false;try{& {$AutoInstall=$true;$Unattend=$answer;. ([scriptblock]::Create($unattendCheck.Extent.Text))}}catch{$failed=$true}
    Assert $failed "AutoInstall rejects -Unattend $answer, because the builder must generate the answer file"
}

foreach($edition in 'Core','CoreSingleLanguage','Professional','ProfessionalN','ProfessionalWorkstation'){
    $cfg=Get-EditionConfig $edition
    Assert ($cfg -match ('\[EditionID\]\r\n'+[regex]::Escape($edition)+'\r\n') -and $cfg -match '\[Channel\]\r\nRetail\r\n' -and $cfg -match '\[VL\]\r\n0\r\n') "$edition media uses Retail without the volume-license flag"
}
foreach($edition in 'Enterprise','EnterpriseS','IoTEnterpriseS'){
    Assert ((Get-EditionConfig $edition) -match '\[Channel\]\r\nRetail\r\n\r\n\[VL\]\r\n1\r\n') "$edition retains its separate volume-license flag with a documented channel"
}

# Names and framework versions from the inspected Home/Pro 28000.2704 media.
$platform=@('Microsoft.WindowsStore','Microsoft.StorePurchaseApp','Microsoft.DesktopAppInstaller',
    'Microsoft.VCLibs.140.00','Microsoft.VCLibs.140.00.UWPDesktop','Microsoft.UI.Xaml.2.8',
    'Microsoft.NET.Native.Framework.2.2','Microsoft.NET.Native.Runtime.2.2','Microsoft.WindowsAppRuntime.1.7',
    'Microsoft.Services.Store.Engagement','Microsoft.AAD.BrokerPlugin','Microsoft.AccountsControl')
foreach($Preset in 'safe','balanced'){
    foreach($name in $platform){Assert (Test-Protected $name) "$Preset protects $name"}
    Assert (-not (Test-Protected 'Microsoft.BingWeather')) "$Preset still permits selected consumer app removal"
}
$Preset='max'
Assert (@(Get-ProtectedPatterns).Count -eq $script:NeverRemove.Count) 'Max uses the shared protection set including the setup launcher dependency'
foreach($name in 'Microsoft-Windows-VBSCRIPT-FoD-Package~31bf3856ad364e35~amd64~~10.0.28000.1','Microsoft-Windows-VBSCRIPT-FoD-Package~31bf3856ad364e35~amd64~ru-RU~10.0.28000.1','VBSCRIPT~~~~0.0.1.0','Microsoft.Windows.VBSCRIPT~~~~0.0.1.0'){
    Assert (Test-Protected $name) "Max protects $name even from RemoveExtra"
}
$wmic='Microsoft-Windows-WMIC-FoD-Package~31bf3856ad364e35~amd64~~10.0.28000.1'
Assert (-not (Test-Protected $wmic) -and @($script:PackageRules|Where-Object{(Test-GroupActive -RulePreset $_.Preset -Group $_.Group) -and $wmic -match $_.Pattern}).Count -gt 0) 'The VBScript exception still permits WMIC removal in max'

foreach($name in 'AppXSvc','ClipSVC','InstallService','LicenseManager','StateRepository','AppReadiness','TokenBroker','BITS','wuauserv','DoSvc','mpssvc'){
    Assert ($name -notin @($script:DisableServices | ForEach-Object{$_.Names})) "Application and network service $name is not disabled"
}
Assert (-not @($script:FolderRules+$script:FileRules|Where-Object{$_.Preset -ne 'max' -and $_.Path -match 'WindowsApps|AppRepository|StateRepository|AppXDeployment|ClipSVC|InstallService'}).Count) 'Balanced does not delete app storage or deployment binaries'

$stage=[regex]::Match($ast.Extent.Text,'(?ms)^#region[^\r\n]*Удаление provisioned Appx.*?^#endregion').Value
Assert ([bool]$stage) 'Actual provisioned-app removal stage found'
function Write-Stage {param($Message)}
function Write-Step {param($Message)}
function Write-Ok {param($Message)}
function Write-ServicingRemovalFailure {throw 'Unexpected DISM failure in fixture'}
$inventory=@($platform)+@('Microsoft.BingWeather','Microsoft.Paint','Microsoft.WindowsCalculator')
$entertainment=@('Microsoft.ZuneMusic','Microsoft.ZuneVideo','Microsoft.GamingApp','Microsoft.XboxApp','Microsoft.XboxGamingOverlay','Microsoft.XboxGameOverlay','Microsoft.XboxSpeechToTextOverlay')
$consumerApps=@('Microsoft.Todos','MicrosoftCorporationII.MicrosoftFamily')
$state=@{Removed=[Collections.Generic.List[string]]::new()}
function Invoke-Dism {
    param($Arguments,[switch]$Quiet,[switch]$AllowFail)
    if($Arguments -contains '/Get-ProvisionedAppxPackages'){
        return [pscustomobject]@{ExitCode=0;Output=@(foreach($name in $inventory){"DisplayName : $name";"PackageName : $($name)_fixture";''})}
    }
    if($Arguments -contains '/Remove-ProvisionedAppxPackage'){
        $state.Removed.Add(($Arguments|Where-Object{$_ -like '/PackageName:*'}).Substring(13))
        return [pscustomobject]@{ExitCode=0;Output=@()}
    }
    throw 'Unexpected native operation'
}
$mountDir='C:\inert-image';$Preset='balanced'
& ([scriptblock]::Create($stage))
Assert ($state.Removed.Count -eq 1 -and $state.Removed[0] -eq 'Microsoft.BingWeather_fixture') 'Balanced preserves Store/MSIX and ordinary apps while removing selected consumer apps'

$inventory += $entertainment + $consumerApps + @('Microsoft.XboxIdentityProvider','Microsoft.Xbox.TCUI','Microsoft.HEVCVideoExtension')
foreach($Preset in 'safe','balanced','max'){
    $state.Removed.Clear()
    & ([scriptblock]::Create($stage))
    foreach($name in ($entertainment+$consumerApps)){
        Assert (($state.Removed -contains ($name+'_fixture')) -eq ($Preset -ne 'safe')) "$Preset handles the selected consumer app $name"
    }
    foreach($name in 'Microsoft.DesktopAppInstaller','Microsoft.WindowsStore','Microsoft.Paint','Microsoft.WindowsCalculator','Microsoft.XboxIdentityProvider','Microsoft.Xbox.TCUI','Microsoft.HEVCVideoExtension'){
        Assert (-not ($state.Removed -contains ($name+'_fixture'))) "$Preset keeps $name with the selected app rules"
    }
}
$Preset='balanced';$Keep=@('WMP','Apps');$state.Removed.Clear()
& ([scriptblock]::Create($stage))
Assert ($state.Removed.Count -eq 0) 'Keep WMP and Apps preserve modern media players, Xbox, Family and To Do'
foreach($Preset in 'balanced','max'){
    foreach($selection in @(@('Family'),@('ToDo'),@('Family','ToDo'))){
        $Keep=@($selection);$state.Removed.Clear()
        & ([scriptblock]::Create($stage))
        Assert (($state.Removed -contains 'MicrosoftCorporationII.MicrosoftFamily_fixture') -eq ($Keep -notcontains 'Family')) 'Keep Family selects only the Family app'
        Assert (($state.Removed -contains 'Microsoft.Todos_fixture') -eq ($Keep -notcontains 'ToDo')) 'Keep ToDo selects only Microsoft To Do'
        Assert ($state.Removed -contains 'Microsoft.ZuneMusic_fixture' -and $state.Removed -contains 'Microsoft.XboxGamingOverlay_fixture' -and $state.Removed -contains 'Microsoft.BingWeather_fixture') 'Targeted Keep choices preserve the rest of the preset removal rules'
    }
}
$Preset='balanced'
$Keep=@();$inventory=@($platform)+@('Microsoft.BingWeather','Microsoft.Paint','Microsoft.WindowsCalculator')

# Regression: an accidentally broadened rule must not remove the platform.
$script:AppxRules=@(@{Preset='balanced';Group='Apps';Pattern='^Microsoft\.'})
$state.Removed.Clear()
& ([scriptblock]::Create($stage))
Assert (@($state.Removed|Where-Object{$_ -in @($platform|ForEach-Object{"$($_)_fixture"})}).Count -eq 0) 'App platform protection is enforced by the real removal stage'
Assert ($state.Removed.Count -eq 3) 'Platform protection is not a blanket ban on app removal'
Write-Host "PASS: $script:checks compatibility checks; PowerShell $($PSVersionTable.PSVersion)"
