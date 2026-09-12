#Requires -Version 5.1
# Pure rules and generated files; DISM and guest system operations are mocked.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in 'T','Get-WindowsRelease','Get-EditionConfig','Get-ProtectedPatterns','Test-Protected','Test-GroupActive','ConvertFrom-DismList','Test-DismSuccess'){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:Lang='en'; $script:checks=0; $Keep=@(); $AddLanguage=@(); $DownloadLanguage=@(); $script:ImageLanguages=@('ru-RU')
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
foreach($name in 'CapabilityRules','PackageRules','AppxRules','NeverRemove','AppPlatformProtected','DisableServices','FolderRules','FileRules'){
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
Assert (@(Get-ProtectedPatterns).Count -eq $script:NeverRemove.Count) 'Max keeps its previous protection set'

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

# Regression: an accidentally broadened rule must not remove the platform.
$script:AppxRules=@(@{Preset='balanced';Group='Apps';Pattern='^Microsoft\.'})
$state.Removed.Clear()
& ([scriptblock]::Create($stage))
Assert (@($state.Removed|Where-Object{$_ -in @($platform|ForEach-Object{"$($_)_fixture"})}).Count -eq 0) 'App platform protection is enforced by the real removal stage'
Assert ($state.Removed.Count -eq 3) 'Platform protection is not a blanket ban on app removal'
Write-Host "PASS: $script:checks compatibility checks; PowerShell $($PSVersionTable.PSVersion)"
