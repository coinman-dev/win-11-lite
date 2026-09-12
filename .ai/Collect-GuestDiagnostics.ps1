#Requires -Version 5.1
# Run inside the test VM. Reads configuration/logs; writes only the report folder.
[CmdletBinding()]
param([string]$Destination = (Join-Path ([Environment]::GetFolderPath('Desktop')) ('win11-lite-diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))))
$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Path $Destination -Force
$report = [ordered]@{ CollectedAt = (Get-Date -Format o); Errors = @() }
function Read-Diagnostic {
    param([string]$Name, [scriptblock]$Read)
    try { $report[$Name] = & $Read }
    catch { $report.Errors += "$Name : $($_.Exception.Message)" }
}
Read-Diagnostic 'Windows' { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object ProductName,EditionID,CurrentBuild,UBR }
Read-Diagnostic 'BuildInfo' { Get-Content -LiteralPath (Join-Path $env:WINDIR 'Setup\Scripts\Win11Lite\build-info.json') -Raw | ConvertFrom-Json }
Read-Diagnostic 'UserLanguages' { Get-WinUserLanguageList | Select-Object LanguageTag,InputMethodTips }
Read-Diagnostic 'UILanguageOverride' { (Get-WinUILanguageOverride).Name }
Read-Diagnostic 'Culture' { (Get-Culture).Name }
Read-Diagnostic 'SystemLocale' { (Get-WinSystemLocale).Name }
Read-Diagnostic 'ProfileLanguages' { Get-ItemProperty 'HKCU:\Control Panel\International\User Profile' | Select-Object Languages }
Read-Diagnostic 'DesktopLanguages' { Get-ItemProperty 'HKCU:\Control Panel\Desktop' | Select-Object PreferredUILanguages }
Read-Diagnostic 'SetupState' { Get-ItemProperty 'HKLM:\SYSTEM\Setup' | Select-Object OOBEInProgress,SystemSetupInProgress,SetupType }
Read-Diagnostic 'NetworkAdapters' { Get-NetAdapter -IncludeHidden | Select-Object Name,InterfaceGuid,AdminStatus,Status,InterfaceDescription }
Read-Diagnostic 'SavedNetworkAdapters' {
    $state = Join-Path $env:WINDIR 'Setup\Scripts\Win11Lite\network-state.clixml'
    if (Test-Path -LiteralPath $state) { Import-Clixml -LiteralPath $state | Select-Object InterfaceGuid }
}
Read-Diagnostic 'OobeCompletionMarker' { Test-Path -LiteralPath (Join-Path $env:WINDIR 'Setup\Scripts\Win11Lite\oobe-complete') }
Read-Diagnostic 'OobeFirewallRule' {
    Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop |
        Where-Object { $_.Name -eq 'Win11Lite-OOBE-Temporary-Outbound-Block' } |
        Select-Object Name,Enabled,Direction,Action,Profile
}
Read-Diagnostic 'UpdatePolicies' {
    foreach ($entry in @(
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU','NoAutoUpdate'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate','DoNotConnectToWindowsUpdateInternetLocations'),
        @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE','DisableOOBEUpdate')
    )) {
        $value=Get-ItemProperty -LiteralPath $entry[0] -Name $entry[1] -ErrorAction SilentlyContinue
        [pscustomobject]@{Path=$entry[0];Name=$entry[1];Value=$(if($value){$value.($entry[1])}else{$null})}
    }
}
Read-Diagnostic 'Tasks' {
    foreach ($name in @('win-11-lite finalize','win-11-lite guard','win-11-lite guard debug')) {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($task) {
            $info = $task | Get-ScheduledTaskInfo
            [pscustomobject]@{Name=$name;State=[string]$task.State;LastRun=$info.LastRunTime;LastResult=$info.LastTaskResult;UserId=$task.Principal.UserId;GroupId=$task.Principal.GroupId;LogonType=[string]$task.Principal.LogonType;Arguments=@($task.Actions.Arguments)}
        }
    }
}
Read-Diagnostic 'Edge' {
    foreach ($base in @($env:ProgramFiles,${env:ProgramFiles(x86)})) {
        Get-ChildItem -LiteralPath (Join-Path $base 'Microsoft\Edge') -Filter msedge.exe -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object FullName,@{n='Version';e={$_.VersionInfo.FileVersion}}
    }
}
Read-Diagnostic 'SettingsResources' {
    foreach ($relative in @(
        'ImmersiveControlPanel\SystemSettings.exe',
        'ImmersiveControlPanel\ru-RU\SystemSettings.exe.mui',
        'ImmersiveControlPanel\en-US\SystemSettings.exe.mui',
        'ImmersiveControlPanel\pris\resources.ru-RU.pri',
        'SystemResources\Windows.UI.SettingsAppThreshold\pris\Windows.UI.SettingsAppThreshold.ru-RU.pri',
        'SystemResources\Windows.UI.SettingsAppThreshold\pris\Windows.UI.SettingsAppThreshold.en-US.pri'
    )) {
        $path = Join-Path $env:WINDIR $relative
        $file = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        [pscustomobject]@{Path=$relative;Exists=[bool]$file;Bytes=$(if($file){$file.Length});Version=$(if($file){$file.VersionInfo.FileVersion})}
    }
}
# Extract only relevant answer-file fields; do not copy passwords/product keys.
Read-Diagnostic 'AnswerFileSettings' {
    foreach ($path in @((Join-Path $env:WINDIR 'Panther\unattend.xml'),(Join-Path $env:WINDIR 'Panther\Unattend\unattend.xml'))) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $xml = [xml](Get-Content -LiteralPath $path -Raw)
        foreach ($settings in $xml.SelectNodes('//*[local-name()="settings"]')) {
            foreach ($node in $settings.SelectNodes('.//*[local-name()="UILanguage" or local-name()="UserLocale" or local-name()="SystemLocale"]')) {
                [pscustomobject]@{File=$path;Pass=$settings.pass;Parent=$node.ParentNode.LocalName;Setting=$node.LocalName;Value=$node.InnerText}
            }
            foreach ($node in $settings.SelectNodes('.//*[local-name()="Path" or local-name()="CommandLine"]')) {
                if ($node.InnerText -match 'Win11Lite\\(Prepare|FirstLogon|Finalize)\.ps1') {
                    [pscustomobject]@{File=$path;Pass=$settings.pass;Setting=$node.LocalName;Value=$node.InnerText}
                }
            }
        }
    }
}
$sources = @(
    (Join-Path $env:WINDIR 'Setup\Scripts\Win11Lite\prepare.log'),
    (Join-Path $env:WINDIR 'Setup\Scripts\Win11Lite\finalize.log'),
    (Join-Path $env:WINDIR 'Setup\Scripts\Win11Lite\guard.log'),
    (Join-Path $env:WINDIR 'Setup\Scripts\Win11Lite\setupcomplete.log'),
    (Join-Path $env:WINDIR 'Panther\setuperr.log')
)
foreach ($source in $sources) {
    try {
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $Destination -Force }
    } catch { $report.Errors += "$source : $($_.Exception.Message)" }
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Destination 'diagnostics.json') -Encoding UTF8
Write-Host "Diagnostics saved: $Destination"
