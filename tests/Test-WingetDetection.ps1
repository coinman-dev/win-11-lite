#Requires -Version 5.1
# Native command fixtures and mocked ISO APIs only; no image servicing or downloads.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in 'T','Get-WimWingetState','Get-IsoWingetState','Read-WingetOption','Write-WindowsBatchFile'){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    if(-not $node){throw "Missing function: $name"}
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:Lang='en';$script:checks=0
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
$root=Join-Path $repo ('tmp\winget-detection-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
try{
    $native=Join-Path $root 'fake dism.cmd'
    Write-WindowsBatchFile -Path $native -Content @'
@echo off
if not "%~1"=="/English" exit /b 87
if not "%~2"=="/List-Image" exit /b 87
if not "%~3"=="/ImageFile:C:\fixture image\install.wim" exit /b 87
if "%~4"=="/Index:4" exit /b 0
if "%~4"=="/Index:5" (
    echo Elevated permissions are required. 1>&2
    exit /b 740
)
echo Deployment Image Servicing and Management tool
echo \Windows
echo \Windows\System32
if "%~4"=="/Index:2" (
    echo \Windows\System32\winget.exe
    echo \Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.0.0.0_x64__8wekyb3d8bbwe\Assets\winget.exe
    exit /b 0
)
echo \Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.24.25199.0_x64__8wekyb3d8bbwe\winget.exe
if "%~4"=="/Index:3" exit /b 50
exit /b 0
'@
    foreach($case in @(@{Index=1;State='Present'},@{Index=2;State='Absent'},@{Index=3;State='Unknown'},@{Index=4;State='Unknown'},@{Index=5;State='Unknown'})){
        $result=Get-WimWingetState -Path 'C:\fixture image\install.wim' -Index $case.Index -Dism $native
        Assert ($result.State -eq $case.State) "Index $($case.Index): expected $($case.State), got $($result.State): $($result.Reason)"
        Assert ([bool]$result.Reason -eq ($case.State -eq 'Unknown')) 'A failed query explains why instead of claiming winget is absent'
    }

    # A found package must skip Read-Host entirely in both UI languages.
    $script:questions=[Collections.Generic.List[string]]::new()
    $script:notes=[Collections.Generic.List[string]]::new()
    $script:answer=$true
    function Read-YesNo {param($Question,$Default);$script:questions.Add($Question);Assert (-not $Default) 'Downloads default to No';$script:answer}
    function Write-Note {param($Message);$script:notes.Add($Message)}
    foreach($script:Lang in 'ru','en'){
        $script:questions.Clear();$script:notes.Clear()
        Assert (-not (Read-WingetOption -SourceState ([pscustomobject]@{State='Present';Reason=''}))) 'Existing winget needs no additional payload'
        Assert ($script:questions.Count -eq 0 -and $script:notes.Count -eq 0) 'Existing winget produces no download/removal question'
        Assert (Read-WingetOption -SourceState ([pscustomobject]@{State='Absent';Reason=''})) 'A missing winget can be added'
        Assert ($script:questions.Count -eq 1) 'Missing winget produces one question'
        $script:answer=$false
        Assert (-not (Read-WingetOption -SourceState ([pscustomobject]@{State='Unknown';Reason='fixture failure'}))) 'An unreadable inventory still permits keeping the source unchanged'
        Assert ($script:notes.Count -eq 1 -and $script:notes[0] -match 'fixture failure') 'An unreadable inventory is reported honestly'
        $script:answer=$true
    }

    # ISO ownership and selected WIM/ESD index; no real disk API may run.
    $script:diskState=@{Attached=$false;Mounts=0;Unmounts=0;Wim=$true;Fail=$false;Queried=$null}
    function Get-DiskImage {param($ImagePath);[pscustomobject]@{Attached=$script:diskState.Attached}}
    function Mount-DiskImage {param($ImagePath,[switch]$PassThru,$Access);Assert ($Access -eq 'ReadOnly') 'Source ISO is mounted read-only';$script:diskState.Mounts++;[pscustomobject]@{Attached=$true}}
    function Dismount-DiskImage {param($ImagePath);$script:diskState.Unmounts++}
    function Get-Volume {param([Parameter(ValueFromPipeline)]$Disk);process{[pscustomobject]@{DriveLetter='C'}}}
    function Start-Sleep {param($Seconds)}
    function Test-Path {param($LiteralPath);if($LiteralPath -like '*.wim'){$script:diskState.Wim}else{$true}}
    function Get-WimWingetState {param($Path,$Index,$Dism);$script:diskState.Queried=@($Path,$Index,$Dism);if($script:diskState.Fail){throw 'fixture read failure'};[pscustomobject]@{State='Present';Reason=''}}
    $result=Get-IsoWingetState -Path 'C:\fixture.iso' -Index 2 -Dism $native
    Assert ($result.State -eq 'Present' -and $script:diskState.Mounts -eq 1 -and $script:diskState.Unmounts -eq 1) 'The detector releases its own ISO mount'
    Assert ($script:diskState.Queried[0] -eq 'C:\sources\install.wim' -and $script:diskState.Queried[1] -eq 2 -and $script:diskState.Queried[2] -eq $native) 'The selected index and explicit DISM are passed to the image query'
    $script:diskState.Attached=$true;$script:diskState.Wim=$false
    $result=Get-IsoWingetState -Path 'C:\fixture.iso' -Index 1
    Assert ($result.State -eq 'Present' -and $script:diskState.Queried[0] -eq 'C:\sources\install.esd') 'ESD sources are checked as well'
    Assert ($script:diskState.Mounts -eq 1 -and $script:diskState.Unmounts -eq 1) 'An ISO already attached by the user remains attached'
    $script:diskState.Attached=$false;$script:diskState.Fail=$true
    $result=Get-IsoWingetState -Path 'C:\fixture.iso' -Index 1
    Assert ($result.State -eq 'Unknown' -and $result.Reason -eq 'fixture read failure' -and $script:diskState.Unmounts -eq 2) 'A failed query releases its own ISO and preserves the reason'
    Write-Host "PASS: $script:checks winget detection checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $allowed=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\winget-detection-'
    $resolved=[IO.Path]::GetFullPath($root)
    if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
