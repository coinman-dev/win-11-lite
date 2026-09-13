#Requires -Version 5.1
# No network, real DISM, registry changes or mounted images.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
$script:checks=0
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw "FAIL: $Message"};$script:checks++}
function Assert-Throws([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed $Message}
foreach($name in @('T','Get-BundledResource','Assert-ChildPath','Read-PreparedCache','Write-PreparedCache','Get-SetupFontPackage','Get-CabIdentity',
    'Save-SetupLanguagePayload','Add-SetupLanguage','ConvertFrom-DismList','Confirm-SkipDownload')){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    if(-not $node){throw "Missing function $name"}
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:Lang='en';$script:ScriptRoot=$repo;$script:DownloadsClosed=$false
function Write-Ok {param($Message)}
function Write-Step {param($Message)}
function Write-Stage {param($Message)}
function Write-Note {param($Message)}
function Save-Url {throw 'NETWORK DISABLED BY TEST'}
function Invoke-RestMethod {throw 'NETWORK DISABLED BY TEST'}
function Invoke-WebRequest {throw 'NETWORK DISABLED BY TEST'}
function Invoke-NativeQuiet {throw 'NATIVE PROCESS DISABLED BY TEST'}
function Invoke-Dism {throw 'DISM DISABLED BY TEST'}
function Get-SetupRunnerScript {'# fixture runner'}
function Initialize-DeploymentTools {param($Build,$Directory,$ExplicitDism,[switch]$Install)}
$root=Join-Path $repo ('tmp\setup-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
try{
    $catalog=Get-BundledResource 'winpe-26100.json'|ConvertFrom-Json
    Assert ($catalog.Build -eq 26100 -and $catalog.Architecture -eq 'amd64') 'Catalog matches target WinPE build and architecture'
    Assert ($catalog.BaseUrl -match '^https://download\.microsoft\.com/') 'Packages come directly from Microsoft'
    Assert ($catalog.Files.Count -eq 894) 'Authenticated ADK catalog includes 37 languages and 6 font packages'
    Assert (@($catalog.Files.Path | Sort-Object -Unique).Count -eq $catalog.Files.Count) 'Catalog output paths are unique'
    foreach($archive in $catalog.Archives){Assert ($archive.SHA1 -match '^[A-F0-9]{40}$' -and $archive.Size -gt 0) 'Download archives have signed-bootstrapper hashes and sizes'}
    Assert (@($catalog.Files|Where-Object{$_.Archive -notin $catalog.Archives.Name -or $_.Member -notmatch '^fil[a-f0-9]{32}$' -or $_.Size -le 0}).Count -eq 0) 'Every package maps to a verified archive member'
    Assert (-not (Get-SetupFontPackage ru-RU)) 'Russian setup needs no extra font component'
    Assert ((Get-SetupFontPackage ja-JP) -eq 'WinPE-FontSupport-JA-JP.cab') 'Japanese setup retains required fonts'
    Assert ((Get-SetupFontPackage th-TH) -eq 'WinPE-FontSupport-WinRE.cab') 'Thai setup uses WinRE font support'

    & {
        $source=Join-Path $root 'source';$locale=Join-Path $source 'ru-ru'
        $null=New-Item -ItemType Directory -Path $locale
        foreach($name in @('lp.cab','WinPE-Setup_ru-ru.cab','WinPE-Setup-Client_ru-ru.cab','WinPE-LegacySetup_ru-ru.cab','WinPE-WMI_ru-ru.cab')){[IO.File]::WriteAllText((Join-Path $locale $name),"fixture $name")}
        $fixture=@{Build=26100;Arch='amd64';Tag='ru-RU';Calls=0}
        function Get-CabIdentity {
            param($Path,$Scratch)
            $fixture.Calls++
            $name=Split-Path $Path -Leaf
            [pscustomobject]@{name=if($name -eq 'lp.cab'){'Microsoft-Windows-WinPE-LanguagePack-Package'}else{($name -split '_')[0]+'-Package'};version="10.0.$($fixture.Build).1";processorArchitecture=$fixture.Arch;language=$fixture.Tag;OuterXml='fixture'}
        }
        $payload=Save-SetupLanguagePayload -Tag ru-RU -Build 26100 -Directory (Join-Path $root 'cache') -Source $source
        Assert ($fixture.Calls -eq 3) 'LP, Setup and Setup Client identities verified before servicing'
        Assert ((Get-ChildItem -LiteralPath $payload.LocaleDirectory -File).Count -eq 5) 'All localized optional components retained in the cache'
        $calls=$fixture.Calls
        $cached=Save-SetupLanguagePayload -Tag ru-RU -Build 26100 -Directory (Join-Path $root 'cache')
        Assert ($cached.LocaleDirectory -eq $payload.LocaleDirectory -and $fixture.Calls -eq $calls) 'Complete cache works without source or network'
        $fixture.Arch='arm64'
        Assert-Throws {Save-SetupLanguagePayload -Tag ru-RU -Build 26100 -Directory (Join-Path $root 'wrong-arch') -Source $source} 'Wrong architecture rejected before WIM mounting'
        $fixture.Arch='amd64';$fixture.Build=28000
        Assert-Throws {Save-SetupLanguagePayload -Tag ru-RU -Build 26100 -Directory (Join-Path $root 'wrong-build') -Source $source} 'Wrong WinPE build rejected'
        $fixture.Build=26100;$fixture.Tag='en-US'
        Assert-Throws {Save-SetupLanguagePayload -Tag ru-RU -Build 26100 -Directory (Join-Path $root 'wrong-language') -Source $source} 'Wrong language rejected'
        $fixture.Tag='ru-RU'
        Remove-Item -LiteralPath (Join-Path $payload.LocaleDirectory 'WinPE-LegacySetup_ru-ru.cab') -Force
        Assert-Throws {Save-SetupLanguagePayload -Tag ru-RU -Build 26100 -Directory (Join-Path $root 'cache')} 'Incomplete cache is not accepted offline'
        Remove-Item -LiteralPath (Join-Path $locale 'WinPE-LegacySetup_ru-ru.cab') -Force
        $stock=Save-SetupLanguagePayload -Tag ru-RU -Build 26100 -Directory (Join-Path $root 'missing-legacy') -Source $source
        Assert ([bool]$stock) 'Stock Setup source does not require the unrelated optional LegacySetup component'
        Assert-Throws {Save-SetupLanguagePayload -Tag ru-RU -Build 22621 -Directory (Join-Path $root 'unknown')} 'Unsupported download build requires an explicit matching local source'
        Assert-Throws {Save-SetupLanguagePayload -Tag '../escape' -Build 26100 -Directory $root} 'Language cannot escape the cache directory'
        $script:DownloadsClosed=$true
        Assert-Throws {Save-SetupLanguagePayload -Tag ru-RU -Build 26100 -Directory $root} 'Setup downloads cannot run in the offline build phase'
        $script:DownloadsClosed=$false
    }

    # Actual integration function, DISM mocked; real small file tree for resource copying.
    foreach($legacy in @($true,$false)){
        & {
            $image=Join-Path $root "boot-$legacy";$distribution=Join-Path $root "media-$legacy";$windows=Join-Path $root 'windows'
            $resources=Join-Path $image 'sources\ru-RU';$packages=Join-Path $root "packages-$legacy"
            $null=New-Item -ItemType Directory -Path $resources,$packages,(Join-Path $distribution 'sources'),$windows -Force
            foreach($name in @('setup.exe.mui','spwizres.dll.mui','mediasetupuimgr.dll.mui')){[IO.File]::WriteAllText((Join-Path $resources $name),'localized resource')}
            foreach($name in @('setup.exe','setuphost.exe')){[IO.File]::WriteAllText((Join-Path $image "sources\$name"),'serviced Setup binary')}
            foreach($name in @('lp.cab','WinPE-Setup_ru-RU.cab','WinPE-Setup-Client_ru-RU.cab','WinPE-LegacySetup_ru-RU.cab','WinPE-WMI_ru-RU.cab','WinPE-NetFx_ru-RU.cab')){[IO.File]::WriteAllText((Join-Path $packages $name),'package')}
            $payload=[pscustomobject]@{Tag='ru-RU';Build=26100;LocaleDirectory=$packages;Directory=$packages;Font=$null}
            $events=[Collections.Generic.List[string]]::new();$state=@{Fail=$false;Intl='ru-RU';MissingLegacy=$false}
            function Invoke-Dism {
                param($Arguments,$Activity,[switch]$Quiet)
                $events.Add(($Arguments -join '|'))
                if($Arguments -contains '/Get-Packages'){
                    $names=@('WinPE-Setup','WinPE-Setup-Client','WinPE-WMI');if(-not $state.MissingLegacy){$names+='WinPE-LegacySetup'}
                    return [pscustomobject]@{Output=@($names|ForEach-Object{"Package Identity : $_-Package~31bf3856ad364e35~amd64~~10.0.26100.1";'State : Installed'})}
                }
                if($state.Fail -and $Arguments -contains '/Add-Package'){throw 'Package not applicable'}
                if($Arguments -contains '/Gen-LangINI'){[IO.File]::WriteAllText((Join-Path $distribution 'sources\lang.ini'),"[Available UI Languages]`r`nru-RU = 3`r`n[Fallback Languages]`r`nru-RU = en-US")}
                if($Arguments -contains '/Get-Intl'){return [pscustomobject]@{Output=@("Default system UI language : $($state.Intl)")}}
            }
            Add-SetupLanguage -Image $image -WindowsImage $windows -Distribution $distribution -Payload $payload -RepairUpdate 'repair.msu' -Legacy:$legacy
            $adds=@($events|Where-Object{$_ -match '/Add-Package'})
            Assert ($adds.Count -eq 6 -and $adds[0] -match 'lp.cab' -and $adds[-1] -match 'repair.msu') "LP first, installed OCs only, LCU last (legacy=$legacy)"
            Assert (-not @($adds|Where-Object{$_ -match 'NetFx'}).Count) 'Uninstalled optional component is not added merely because its language CAB exists'
            Assert ($events -contains "/Image:$image|/Set-AllIntl:ru-RU") 'WinPE display language is configured'
            Assert ($events -contains "/Image:$windows|/Gen-LangINI|/Distribution:$distribution") 'Language list is generated from the still-mounted Windows image'
            Assert ($events -contains "/Image:$image|/Set-SetupUILang:ru-RU|/Distribution:$distribution") 'Setup default language is configured'
            Assert ((Get-Content -LiteralPath (Join-Path $image 'sources\lang.ini') -Raw) -match 'ru-RU = 3') 'Updated lang.ini reaches boot.wim'
            Assert (Test-Path -LiteralPath (Join-Path $distribution 'sources\ru-RU\setup.exe.mui')) 'Serviced language resources reach the ISO sources folder'
            Assert ((Get-Content -LiteralPath (Join-Path $distribution 'sources\setuphost.exe') -Raw) -eq 'serviced Setup binary') 'Setup binaries stay synchronized between boot.wim and media'
            $state.Fail=$true
            Assert-Throws {Add-SetupLanguage -Image $image -WindowsImage $windows -Distribution $distribution -Payload $payload -Legacy:$legacy} 'Servicing failure remains fatal'
            $state.Fail=$false;$state.Intl='en-US'
            Assert-Throws {Add-SetupLanguage -Image $image -WindowsImage $windows -Distribution $distribution -Payload $payload -Legacy:$legacy} 'Wrong final WinPE language is detected'
            $state.Intl='ru-RU';$state.MissingLegacy=$true
            if($legacy){
                $events.Clear()
                Add-SetupLanguage -Image $image -WindowsImage $windows -Distribution $distribution -Payload $payload -Legacy
                Assert (-not @($events|Where-Object{$_ -match 'LegacySetup'}).Count) 'Classic installer works with stock WinPE inventory without adding an optional LegacySetup component'
            }
        }
    }

    $prep=[regex]::Match($ast.Extent.Text,'(?ms)^#region[^\r\n]*Подготовка загрузок до обработки образа.*?^#endregion').Value
    foreach($case in @('auto','original','explicit','skip','cancel','missing-repair','unupdated','dryrun')){
        & {
            $script:DownloadsClosed=$false;$script:SkippedDownloads=@();$script:Lang='en'
            $DryRun=$case -eq 'dryrun';$ClearCache=$false;$UpdateMode='none';$IncludeDotNetUpdate=$false;$WithWinget=$false
            $SetupLanguage=if($case -eq 'original'){'original'}elseif($case -eq 'explicit'){'de-DE'}else{'auto'}
            $sourceImageLanguage='en-US';$setupLang='en-US';$setupPayload=$null;$setupRepair=$null
            $AddLanguage=@('ru-RU');$DownloadLanguage=@('ru-RU');$SetupLanguageSource=Join-Path $root 'provided-source';$SetupLanguageUpdatePath=''
            $LanguageSource='';$LanguageUpdatePath=Join-Path $root 'source-lcu.msu'
            [IO.File]::WriteAllText($LanguageUpdatePath,'source LCU')
            $srcSources=Join-Path $root 'iso\sources';$imgRevision='26100.1742';$buildNumber=26100;$winVersion='24H2';$LegacySetup=$true
            $UpdatesDir=Join-Path $root "prep-$case";$events=[Collections.Generic.List[string]]::new()
            function Save-LanguageFromCatalog {param($Tags,$Build,$Revision,$Destination)}
            function Find-LanguagePackage {param($Root,$Tag,$Kind)[pscustomobject]@{Length=1}}
            function Test-CanPrompt {$true}
            function Read-YesNo {param($Question,$Default)$events.Add('prompt');$case -ne 'cancel'}
            function Get-WimImageList {param($Path)[pscustomobject]@{Index=2;Architecture='amd64';Version=if($case -eq 'missing-repair'){'10.0.26100.9999'}elseif($case -eq 'unupdated'){'10.0.26100.1'}else{'10.0.26100.1742'}}}
            function Save-SetupLanguagePayload {param($Tag,$Build,$Directory,$Source,[switch]$Legacy)$events.Add("prepare:$Tag");if($case -in @('skip','cancel')){throw 'DNS failure'};[pscustomobject]@{Tag=$Tag;Build=$Build}}
            function Get-LanguageRepairUpdate {throw 'Unexpected repair download'}
            $cancelled=$false
            try{. ([scriptblock]::Create($prep))}catch{if($case -ne 'cancel'){throw};$cancelled=$true}
            switch($case){
                'auto'{Assert ($setupLang -eq 'ru-RU' -and $setupRepair -eq $LanguageUpdatePath) 'Auto follows Windows language and reuses source LCU'}
                'explicit'{Assert ($setupLang -eq 'de-DE' -and $AddLanguage[0] -eq 'ru-RU') 'Explicit Setup language does not change selected Windows language'}
                'original'{Assert ($events.Count -eq 0 -and $setupLang -eq 'en-US') 'Original Setup language requires no download'}
                'skip'{Assert ($setupLang -eq 'en-US' -and -not $setupPayload -and $AddLanguage[0] -eq 'ru-RU' -and $script:SkippedDownloads.Count -eq 1) 'Download skip keeps original Setup and requested Windows language'}
                'cancel'{Assert ($cancelled -and -not $script:DownloadsClosed) 'Cancellation happens before offline image work'}
                'missing-repair'{Assert ($setupLang -eq 'en-US' -and -not $setupPayload -and $events -contains 'prompt') 'Unknown updated boot.wim requires a prepared LCU or explicit skip'}
                'unupdated'{Assert ($setupLang -eq 'ru-RU' -and -not $setupRepair) 'Baseline boot.wim does not request an unnecessary LCU'}
                'dryrun'{Assert ($events.Count -eq 0 -and -not (Test-Path $UpdatesDir)) 'DryRun never prepares Setup downloads'}
            }
        }
    }
    # Execute the actual trim stage on a disposable media tree.
    & {
        $isoDir=Join-Path $root 'trim-media';$srcDir=Join-Path $isoDir 'sources'
        $null=New-Item -ItemType Directory -Path (Join-Path $srcDir 'ru-RU'),(Join-Path $srcDir 'en-US'),(Join-Path $srcDir 'unused')
        foreach($name in @('install.esd','boot.wim','lang.ini','setup.exe','unused.txt')){[IO.File]::WriteAllText((Join-Path $srcDir $name),'fixture')}
        $TrimSources=$true;$destName='install.esd';$setupPayload=[pscustomobject]@{Tag='ru-RU'};$setupLang='ru-RU';$sourceImageLanguage='en-US'
        function Format-Size {param($Bytes)"$Bytes bytes"}
        $region=[regex]::Match($ast.Extent.Text,'(?ms)^# --- урезание sources ---.*?(?=^# --- EI.CFG)').Value
        . ([scriptblock]::Create($region))
        Assert ((Test-Path (Join-Path $srcDir 'ru-RU')) -and (Test-Path (Join-Path $srcDir 'en-US')) -and (Test-Path (Join-Path $srcDir 'lang.ini'))) 'TrimSources preserves selected and fallback Setup resources and lang.ini'
        Assert (-not (Test-Path (Join-Path $srcDir 'unused.txt')) -and -not (Test-Path (Join-Path $srcDir 'unused'))) 'TrimSources still removes unrelated media files'
    }
    $commit=$ast.Extent.Text.IndexOf('Invoke-Dism -Arguments @(''/Unmount-Image'', "/MountDir:$mountDir", ''/Commit'')')
    $setupCall=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-SetupLanguage'},$true))[0]
    Assert ($setupCall.Extent.StartOffset -lt $commit) 'Windows stays mounted until Setup language list generation completes'
    Assert ($ast.Extent.Text -match 'Assert-ImageLanguages -Image \$mountDir -Languages \$AddLanguage -SourceLanguage \$sourceImageLanguage') 'Windows MUI validation still compares with original Windows language'
    Write-Host "PASS: $script:checks setup language checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $allowed=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\setup-tests-'
    $full=[IO.Path]::GetFullPath($root)
    if($full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $full -Recurse -Force}
}
