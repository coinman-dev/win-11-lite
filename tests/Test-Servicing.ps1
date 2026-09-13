#Requires -Version 5.1
# WIM metadata, tool preparation and answer files only. No image servicing or guest operations.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
foreach($name in 'T','Get-AdkSourceHash','Confirm-MicrosoftSignature','Read-MsiTable','Get-MsiDirectoryPath','Get-MsiFileMap','Save-AdkInstallers','Get-AdkCatalog','Get-WimImageList','Get-NativeToolVersion','Save-DeploymentTools','Initialize-DeploymentTools','Ensure-WimMountDriver','Read-PreparedCache','Write-PreparedCache','Assert-ChildPath','Invoke-NativeQuiet','Test-DismSuccess','Resolve-AccountMode','Assert-LocalUserName','Test-SecureStringEqual','Read-ConfirmedLocalAccountPassword','Read-LocalAccountOptions','Get-LocalAccountXml','Get-ImageInstallXml','Get-ProductKeyUiMode','Get-ElevationCommand'){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    if(-not $node){throw "Missing function: $name"}
    . ([scriptblock]::Create($node.Extent.Text))
}
$adkNode=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:AdkSources'},$true)
if(-not $adkNode){throw 'Missing pinned ADK source table'}
. ([scriptblock]::Create($adkNode.Extent.Text))
$script:Lang='en';$script:checks=0;$Unattend='';$SkipIso=$false
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw "FAIL: $Message"};$script:checks++}
function Assert-Throws([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed $Message}
function Write-Ok {param($Message)}
function Write-Step {param($Message)}
function Write-Note {param($Message)}
$root=Join-Path $repo ('tmp\servicing-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
try{
    $metadata='<WIM><IMAGE INDEX="1"><NAME>Windows 11 Домашняя</NAME><TOTALBYTES>1234</TOTALBYTES><WINDOWS><ARCH>9</ARCH><EDITIONID>Core</EDITIONID><LANGUAGES><LANGUAGE>en-US</LANGUAGE><LANGUAGE>ru-RU</LANGUAGE><DEFAULT>ru-RU</DEFAULT></LANGUAGES><VERSION><MAJOR>10</MAJOR><MINOR>0</MINOR><BUILD>28000</BUILD><SPBUILD>2704</SPBUILD></VERSION></WINDOWS></IMAGE></WIM>'
    function Write-WimFixture([string]$Path,[string]$Xml=$metadata){
        $body=[Text.Encoding]::Unicode.GetBytes([char]0xFEFF+$Xml)
        $bytes=New-Object byte[] (208+$body.Length)
        [Text.Encoding]::ASCII.GetBytes("MSWIM`0`0`0").CopyTo($bytes,0)
        [BitConverter]::GetBytes([uint32]208).CopyTo($bytes,8)
        [BitConverter]::GetBytes([uint32]1).CopyTo($bytes,44)
        [BitConverter]::GetBytes(([uint64]0x0200000000000000+[uint64]$body.Length)).CopyTo($bytes,72)
        [BitConverter]::GetBytes([uint64]208).CopyTo($bytes,80)
        [BitConverter]::GetBytes([uint64]$body.Length).CopyTo($bytes,88)
        $body.CopyTo($bytes,208)
        [IO.File]::WriteAllBytes($Path,$bytes)
    }
    $wim=Join-Path $root 'образ.esd';Write-WimFixture $wim
    $images=@(Get-WimImageList $wim)
    Assert ($images.Count -eq 1 -and $images[0].Name -eq 'Windows 11 Домашняя' -and $images[0].Version -eq '10.0.28000.2704') 'WIM XML preserves Unicode names and the complete build without DISM'
    Assert ($images[0].Languages -eq 'ru-RU,en-US' -and $images[0].Architecture -eq '9' -and $images[0].EditionId -eq 'Core') 'Default language precedes other languages and edition/architecture are retained'
    foreach($damage in 'signature','truncated','outside','compressed','count','dtd'){
        Write-WimFixture $wim
        $bytes=[IO.File]::ReadAllBytes($wim)
        switch($damage){
            signature {$bytes[0]=0}
            truncated {$bytes=$bytes[0..50]}
            outside {[BitConverter]::GetBytes([uint64]999999).CopyTo($bytes,80)}
            compressed {$bytes[79]=6}
            count {[BitConverter]::GetBytes([uint32]2).CopyTo($bytes,44)}
            dtd {Write-WimFixture $wim ('<!DOCTYPE WIM [<!ENTITY test SYSTEM "file:///must-not-be-read">]>'+$metadata);$bytes=[IO.File]::ReadAllBytes($wim)}
        }
        [IO.File]::WriteAllBytes($wim,$bytes)
        Assert-Throws {Get-WimImageList $wim} "Invalid metadata is rejected and handles close: $damage"
    }
    & {
        $state=@{Downloads=0}
        function Get-NativeToolVersion {param($Path)if($Path -like '*fresh*'){[version]'10.0.28000.1'}elseif($Path -like '*System32*'){[version]'10.0.19041.1'}else{[version]'10.0.26100.2454'}}
        function Test-Path {param($LiteralPath,$Path,[switch]$PathType)$true}
        function Save-DeploymentTools {param($Directory,$Build)$state.Downloads++;[pscustomobject]@{Dism='C:\fresh\dism.exe';Oscdimg='C:\fresh\oscdimg.exe'}}
        Initialize-DeploymentTools -Build 28000 -Directory $root
        Assert ($state.Downloads -eq 1 -and $script:Dism -eq 'C:\fresh\dism.exe') '26H1 uses prepared DISM 28000 instead of the installed 26100'
        $state.Downloads=0;Initialize-DeploymentTools -Build 26200 -Directory $root
        Assert ($state.Downloads -eq 0 -and $script:Dism -like '*Windows Kits*') '25H2 continues to use compatible DISM 26100'
        Initialize-DeploymentTools -Build 28000 -Directory $root -Preview
        Assert ($state.Downloads -eq 0) 'Preview does not download or install tools'
        $custom=Join-Path $root 'custom.exe';[IO.File]::WriteAllText($custom,'fixture')
        Assert-Throws {Initialize-DeploymentTools -Build 28000 -Directory $root -ExplicitDism $custom} 'An explicitly selected old DISM is rejected before servicing'
    }
    & {
        $payload=Join-Path $root 'payload.bin';[IO.File]::WriteAllText($payload,'inert tool fixture')
        $cab=Join-Path $root 'fixture.cab'
        & "$env:SystemRoot\System32\makecab.exe" $payload $cab | Out-Null
        if($LASTEXITCODE -ne 0){throw 'Fixture cabinet creation failed'}
        $entry=[pscustomobject]@{Member='payload.bin';Path='amd64\DISM\dism.exe';Size=(Get-Item $payload).Length}
        $second=[pscustomobject]@{Member='payload.bin';Path='amd64\Oscdimg\oscdimg.exe';Size=$entry.Size}
        $archive=[pscustomobject]@{Name='fixture.cab';Url='https://fixture/fixture.cab';Size=(Get-Item $cab).Length;SHA256=(Get-FileHash $cab -Algorithm SHA256).Hash;SHA1=$null;Files=@($entry,$second)}
        $catalog=[pscustomobject]@{Build=28000;Architecture='amd64';Version='fixture';BaseUrl='https://fixture/';Archives=@($archive);Files=@($entry,$second)}
        $state=@{Copies=0;Corrupt=$false;SourceCab=$cab;Catalogs=0}
        function Get-AdkCatalog {param($Build,$Directory)$state.Catalogs++;if($Build -ne 28000){throw 'Unexpected fixture build'};$catalog}
        function Get-NativeToolVersion {param($Path)[version]'10.0.28000.1'}
        function Save-Url {param($Url,$Destination)$state.Copies++;if($state.Corrupt){[IO.File]::WriteAllText($Destination,'broken')}else{Copy-Item -LiteralPath $state.SourceCab -Destination $Destination -Force}}
        $cache=Join-Path $root 'cache'
        $tools=Save-DeploymentTools -Directory $cache
        Assert ((Get-Content -LiteralPath $tools.Dism -Raw) -eq 'inert tool fixture' -and (Test-Path $tools.Oscdimg)) 'Verified CAB files are restored to their proper tool paths'
        Save-DeploymentTools -Directory $cache|Out-Null
        Assert ($state.Copies -eq 1) 'Complete tool cache works without another download'
        Assert ($state.Catalogs -eq 1) 'A valid tool cache does not read the ADK installers again'
        [IO.File]::WriteAllText($tools.Dism,'tampered')
        Save-DeploymentTools -Directory $cache|Out-Null
        Assert ((Get-Content -LiteralPath $tools.Dism -Raw) -eq 'inert tool fixture') 'Damaged extracted tools are rebuilt from verified archives'
        $state.Corrupt=$true
        Assert-Throws {Save-DeploymentTools -Directory (Join-Path $root 'bad-cache')} 'Wrong archive hash fails before any tool becomes ready'
        Assert (-not(Test-Path (Join-Path $root 'bad-cache\deployment-tools-28000\tools.ready.json'))) 'A failed tool preparation leaves no ready manifest'
        $archive.Name='..\outside.cab'
        Assert-Throws {Save-DeploymentTools -Directory (Join-Path $root 'path-cache')} 'Archive paths cannot escape the tool cache'
    }
    # Pinned ADK sources and the installer-table reader that replaced the embedded catalogs.
    & {
        Assert (@($script:AdkSources.Keys|Sort-Object) -join ',' -eq '26100,28000') 'Pinned ADK sources cover the WinPE and 26H1 tool kits'
        $tools=$script:AdkSources[28000];$winpe=$script:AdkSources[26100]
        Assert ($tools.Installers.Count -eq 4 -and $tools.Archives.Count -eq 9) 'The 26H1 tool kit pins four installers and nine archives'
        $totalBytes=0;foreach($archive in $tools.Archives){$totalBytes+=[int64]$archive.Size}
        Assert ($totalBytes -eq 6641932) 'Pinned tool archives keep the verified total download size'
        Assert ($winpe.Installers.Count -eq 1 -and $winpe.Archives.Count -eq 2) 'The WinPE kit pins one installer and two language archives'
        foreach($source in @($tools,$winpe)){
            Assert ($source.BaseUrl -match '^https://download\.microsoft\.com/') 'ADK files come directly from Microsoft'
            foreach($installer in $source.Installers){
                Assert ($installer.SHA256 -match '^[A-F0-9]{64}$' -and $installer.Size -gt 0 -and $installer.Name -match '\.msi$') 'Every pinned installer has a size and SHA256'
            }
            foreach($archive in $source.Archives){
                Assert (($archive.SHA256 -match '^[A-F0-9]{64}$' -or $archive.SHA1 -match '^[A-F0-9]{40}$') -and $archive.Size -gt 0) 'Every pinned archive has a size and a signed-bootstrapper hash'
            }
        }
        $hash=Get-AdkSourceHash -Build 28000
        Assert ($hash -match '^[A-F0-9]{64}$' -and $hash -eq (Get-AdkSourceHash -Build 28000)) 'The source identity is a stable SHA256'
        Assert ($hash -ne (Get-AdkSourceHash -Build 26100)) 'Each kit has its own cache identity'
        $saved=$tools.Archives[0].SHA256;$tools.Archives[0].SHA256='0'*64
        Assert ((Get-AdkSourceHash -Build 28000) -ne $hash) 'Changing any pinned value invalidates the prepared tool cache'
        $tools.Archives[0].SHA256=$saved
        Assert ((Get-AdkSourceHash -Build 28000) -eq $hash) 'Restoring the pinned value restores the cache identity'
        Assert-Throws {Get-AdkSourceHash -Build 12345} 'An unknown ADK build is rejected instead of silently skipped'

        $dirs=@{}
        foreach($row in @(
            [pscustomobject]@{Directory='TARGETDIR';Directory_Parent='';DefaultDir='SourceDir'}
            [pscustomobject]@{Directory='TOOLS';Directory_Parent='TARGETDIR';DefaultDir='deplo~1|Deployment Tools'}
            [pscustomobject]@{Directory='ARCH';Directory_Parent='TOOLS';DefaultDir='amd64:amd64src'}
            [pscustomobject]@{Directory='SAME';Directory_Parent='ARCH';DefaultDir='.:.'}
            [pscustomobject]@{Directory='LOOPA';Directory_Parent='LOOPB';DefaultDir='a'}
            [pscustomobject]@{Directory='LOOPB';Directory_Parent='LOOPA';DefaultDir='b'}
        )){$dirs[$row.Directory]=$row}
        Assert ((Get-MsiDirectoryPath -Directories $dirs -Id 'ARCH') -eq '\SourceDir\Deployment Tools\amd64') 'Long directory names and target names build the real path'
        Assert ((Get-MsiDirectoryPath -Directories $dirs -Id 'SAME') -eq (Get-MsiDirectoryPath -Directories $dirs -Id 'ARCH')) 'A dot directory stays in its parent'
        Assert-Throws {Get-MsiDirectoryPath -Directories $dirs -Id 'LOOPA'} 'A directory cycle is reported instead of hanging'
        Assert-Throws {Get-MsiDirectoryPath -Directories $dirs -Id 'MISSING'} 'A missing directory row stops the read'

        # A fake Windows Installer object exercises the real reader without an MSI.
        $script:MsiTables=@{}
        $msiState=@{Path='';Mode=-1;Queries=[Collections.Generic.List[string]]::new()}
        function New-Object {
            param([string]$ComObject)
            if($ComObject -ne 'WindowsInstaller.Installer'){throw "Unexpected COM object: $ComObject"}
            $installer=[pscustomobject]@{}
            $installer|Add-Member -MemberType ScriptMethod -Name OpenDatabase -Value {
                param($path,$mode)
                $msiState.Path=$path;$msiState.Mode=$mode
                $database=[pscustomobject]@{}
                $database|Add-Member -MemberType ScriptMethod -Name OpenView -Value {
                    param($sql)
                    $msiState.Queries.Add($sql)
                    if($sql -notmatch '^SELECT `(.+)` FROM `([^`]+)`$'){throw "Unsupported query: $sql"}
                    $view=[pscustomobject]@{Columns=@($matches[1] -split '`,`');Table=$matches[2];Index=0;Rows=@()}
                    if(-not $script:MsiTables.ContainsKey($view.Table)){throw "Missing table $($view.Table)"}
                    $view.Rows=@($script:MsiTables[$view.Table])
                    $view|Add-Member -MemberType ScriptMethod -Name Execute -Value {}
                    $view|Add-Member -MemberType ScriptMethod -Name Close -Value {}
                    $view|Add-Member -MemberType ScriptMethod -Name Fetch -Value {
                        if($this.Index -ge $this.Rows.Count){return $null}
                        $record=[pscustomobject]@{Row=$this.Rows[$this.Index];Columns=$this.Columns}
                        $this.Index++
                        $record|Add-Member -MemberType ScriptMethod -Name StringData -Value {param([int]$i)[string]$this.Row.($this.Columns[$i-1])} -PassThru
                    }
                    $view
                } -PassThru
            } -PassThru
        }
        $script:MsiTables['Directory']=@($dirs.Values|Where-Object{$_.Directory -notlike 'LOOP*'})
        $script:MsiTables['Component']=@([pscustomobject]@{Component='C_ARCH';Directory_='ARCH'})
        $script:MsiTables['Media']=@(
            [pscustomobject]@{DiskId='2';LastSequence='9';Cabinet='second.cab'}
            [pscustomobject]@{DiskId='1';LastSequence='4';Cabinet='first.cab'}
        )
        $script:MsiTables['File']=@(
            [pscustomobject]@{File='fil00000000000000000000000000000001';Component_='C_ARCH';FileName='dism~1.exe|dism.exe';FileSize='1234';Sequence='3'}
            [pscustomobject]@{File='fil00000000000000000000000000000002';Component_='C_ARCH';FileName='later.dll';FileSize='77';Sequence='7'}
        )
        $mapped=@(Get-MsiFileMap -Path 'C:\fixture.msi' -Pattern '\\Deployment Tools\\(amd64\\.+)$')
        Assert ($msiState.Mode -eq 0 -and $msiState.Path -eq 'C:\fixture.msi') 'The installer database is opened read-only'
        Assert ($msiState.Queries.Count -eq 4 -and @($msiState.Queries|Where-Object{$_ -match 'DELETE|INSERT|UPDATE'}).Count -eq 0) 'Only the four content tables are read and nothing is written'
        Assert ($mapped.Count -eq 2) 'Every matching installer file is mapped'
        Assert ($mapped[0].Path -eq 'amd64\dism.exe' -and $mapped[0].Size -eq 1234) 'The long file name and declared size are used'
        Assert ($mapped[0].Archive -eq 'first.cab' -and $mapped[1].Archive -eq 'second.cab') 'Each file maps to the cabinet that covers its sequence'
        $script:MsiTables['File']=@([pscustomobject]@{File='fil00000000000000000000000000000003';Component_='MISSING';FileName='x.dll';FileSize='1';Sequence='1'})
        Assert-Throws {Get-MsiFileMap -Path 'C:\fixture.msi' -Pattern '(.+)'} 'A file without a component directory stops the read'
        $script:MsiTables['File']=@([pscustomobject]@{File='fil00000000000000000000000000000004';Component_='C_ARCH';FileName='x.dll';FileSize='1';Sequence='99'})
        Assert-Throws {Get-MsiFileMap -Path 'C:\fixture.msi' -Pattern '(.+)'} 'A file outside every cabinet range is rejected'
        $script:MsiTables['Media']=@([pscustomobject]@{DiskId='1';LastSequence='9';Cabinet='#embedded.cab'})
        Assert-Throws {Get-MsiFileMap -Path 'C:\fixture.msi' -Pattern '(.+)'} 'A cabinet stored inside the installer is rejected'
        $script:MsiTables['Media']=@()
        Assert-Throws {Get-MsiFileMap -Path 'C:\fixture.msi' -Pattern '(.+)'} 'An installer without content tables is rejected'
    }
    # Pinned hashes gate the installers; the reader shapes the catalog.
    & {
        $fixtureDir=Join-Path $root 'installers';$null=New-Item -ItemType Directory -Path $fixtureDir
        $body='inert installer fixture'
        $script:AdkSources[99999]=@{
            Kind='tools';Version='fixture';BaseUrl='https://fixture/base/'
            Installers=@(@{Name='Fixture Tools (DesktopEditions)-x86_en-us.msi';Size=$body.Length;SHA256=(Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($body))) -Algorithm SHA256).Hash})
            Pattern='\\Fixture\\(amd64\\.+)$'
            Archives=@(@{Name='fixture.cab';Size=1;SHA256='0'*64})
        }
        try{
            $calls=[Collections.Generic.List[string]]::new()
            function Save-Url {param($Url,$Destination)$calls.Add($Url);[IO.File]::WriteAllText($Destination,$body)}
            function Get-AuthenticodeSignature {param($LiteralPath)[pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=Microsoft Corporation, O=Microsoft Corporation'}}}
            $paths=@(Save-AdkInstallers -Build 99999 -Directory $fixtureDir)
            Assert ($paths.Count -eq 1 -and (Test-Path -LiteralPath $paths[0])) 'A matching installer is accepted and reused'
            Assert ($calls[0] -eq 'https://fixture/base/Fixture%20Tools%20(DesktopEditions)-x86_en-us.msi') 'Spaces in installer names are encoded for the download'
            function Get-AuthenticodeSignature {param($LiteralPath)[pscustomobject]@{Status='NotSigned';SignerCertificate=$null}}
            Assert (@(Save-AdkInstallers -Build 99999 -Directory $fixtureDir).Count -eq 1) 'An unconfirmed signature warns without stopping a build whose hashes match'
            function Save-Url {param($Url,$Destination)$calls.Add($Url);[IO.File]::WriteAllText($Destination,'tampered installer')}
            Assert-Throws {Save-AdkInstallers -Build 99999 -Directory (Join-Path $root 'installers-bad')} 'An installer that does not match its pinned SHA256 stops the build'
            Assert (-not (Test-Path -LiteralPath (Join-Path $root 'installers-bad\adk-99999-installers\Fixture Tools (DesktopEditions)-x86_en-us.msi'))) 'A rejected installer is deleted instead of being cached'

            $script:AdkCatalogs=@{}
            function Save-AdkInstallers {param($Build,$Directory)@('C:\fixture.msi')}
            $mapped=@(
                [pscustomobject]@{Archive='fixture.cab';Member='fil00000000000000000000000000000001';Path='amd64\DISM\dism.exe';Size=5}
                [pscustomobject]@{Archive='fixture.cab';Member='fil00000000000000000000000000000002';Path='amd64\Oscdimg\oscdimg.exe';Size=6}
            )
            $reads=@{Count=0}
            function Get-MsiFileMap {param($Path,$Pattern)$reads.Count++;$mapped}
            $catalog=Get-AdkCatalog -Build 99999 -Directory $fixtureDir
            Assert ($catalog.Build -eq 99999 -and $catalog.Architecture -eq 'amd64' -and $catalog.Files.Count -eq 2) 'The catalog keeps the shape the builder already expects'
            Assert ($catalog.Archives[0].Url -eq 'https://fixture/base/fixture.cab' -and $catalog.Archives[0].Files.Count -eq 2) 'Archive addresses and members come from the pinned list and the installer'
            $null=Get-AdkCatalog -Build 99999 -Directory $fixtureDir
            Assert ($reads.Count -eq 1) 'The installers are read once per build, not once per language'
            $script:AdkCatalogs=@{};$mapped[0].Archive='unpinned.cab'
            Assert-Throws {Get-AdkCatalog -Build 99999 -Directory $fixtureDir} 'A file in an unpinned archive stops the build'
            $script:AdkCatalogs=@{};$mapped[0].Archive='fixture.cab';$mapped[0].Path='..\outside.exe'
            Assert-Throws {Get-AdkCatalog -Build 99999 -Directory $fixtureDir} 'A relative escape in the installer tables is rejected'
            $script:AdkCatalogs=@{};$mapped[0].Path='C:\absolute.exe'
            Assert-Throws {Get-AdkCatalog -Build 99999 -Directory $fixtureDir} 'An absolute path in the installer tables is rejected'
            $script:AdkCatalogs=@{};$mapped[0].Path='amd64\DISM\dism.exe';$mapped[0].Member='payload.bin'
            Assert-Throws {Get-AdkCatalog -Build 99999 -Directory $fixtureDir} 'A member name that is not a cabinet identifier is rejected'
            $script:AdkCatalogs=@{};$mapped[0].Member='fil00000000000000000000000000000001'
            $script:AdkSources[99999].Kind='winpe'
            $mapped[0].Path='ru-ru\lp.cab';$mapped[1].Path='WinPE-FontSupport-JA-JP.cab'
            $extra=[pscustomobject]@{Archive='fixture.cab';Member='fil00000000000000000000000000000003';Path='sr-latn-rs\lp.cab';Size=7}
            $mapped=@($mapped[0],$mapped[1],$extra)
            $catalog=Get-AdkCatalog -Build 99999 -Directory $fixtureDir
            Assert (@($catalog.Files.Path) -join ',' -eq 'ru-ru/lp.cab,WinPE-FontSupport-JA-JP.cab') 'WinPE keeps two-part language sets and font packages and drops the rest'
        }finally{$script:AdkSources.Remove(99999);$script:AdkCatalogs=@{}}
    }
    & {
        function Test-CanPrompt {$false}
        foreach($edition in 'Core','Professional'){
            $choice=Read-LocalAccountOptions -Build 28000 -EditionId $edition -Mode auto -Preview
            Assert ($choice.Mode -eq 'image' -and -not $choice.Name) "26H1 $edition preview plans an account without inventing a user"
            Assert-Throws {Read-LocalAccountOptions -Build 28000 -EditionId $edition -Mode auto} "26H1 $edition requires account input before downloads when noninteractive"
        }
        Assert ((Read-LocalAccountOptions -Build 26100 -EditionId IoTEnterpriseS -Mode auto).Mode -eq 'setup') 'Existing LTSC account setup stays unchanged'
        Assert ((Read-LocalAccountOptions -Build 28000 -EditionId Core -Mode setup).Mode -eq 'setup') 'Explicit Windows account-entry mode stays available'
        Assert ((Read-LocalAccountOptions -Build 28000 -EditionId Core -Mode auto -Name 'Тест & User').Name -eq 'Тест & User') 'Explicit local user enables account creation without prompting'
        foreach($name in 'Administrator','defaultuser0','bad/name','..','trailing.','a,b',('a'*21)) {Assert-Throws {Assert-LocalUserName $name} 'Invalid and built-in account names are rejected'}
        $Unattend='custom.xml'
        Assert-Throws {Read-LocalAccountOptions -Build 28000 -EditionId Core -Mode image -Name TestUser} 'Local account generation does not overwrite custom answer files'
    }
    & {
        function Test-CanPrompt {$true}
        function Read-Option {param($Question,$Items,$Values,$Default) 'image'}
        $responses=[Collections.Queue]::new()
        $responses.Enqueue('TestUser')
        $responses.Enqueue((ConvertTo-SecureString 'first attempt' -AsPlainText -Force))
        $responses.Enqueue((ConvertTo-SecureString 'different attempt' -AsPlainText -Force))
        $responses.Enqueue((ConvertTo-SecureString 'final password' -AsPlainText -Force))
        $responses.Enqueue((ConvertTo-SecureString 'final password' -AsPlainText -Force))
        $prompts=[Collections.Generic.List[string]]::new();$warnings=[Collections.Generic.List[string]]::new()
        function Read-Host {param($Prompt,[switch]$AsSecureString)$prompts.Add($Prompt);$responses.Dequeue()}
        function Write-Host {param($Object,$ForegroundColor)if($Object -match 'Passwords do not match'){$warnings.Add($Object)}}
        $Unattend=''
        $choice=Read-LocalAccountOptions -Build 28000 -EditionId Core -Mode auto
        $expected=ConvertTo-SecureString 'final password' -AsPlainText -Force
        Assert ($choice.Mode -eq 'image' -and $choice.Name -eq 'TestUser' -and (Test-SecureStringEqual $choice.Password $expected)) 'Interactive account creation keeps only the confirmed password'
        Assert ($prompts.Count -eq 5 -and $prompts[2] -match 'Confirm password' -and $prompts[4] -match 'Confirm password' -and $warnings.Count -eq 1) 'Mismatched passwords require entering and confirming the password again'
        $emptySecure=[Security.SecureString]::new()
        $blank=[Collections.Queue]::new();$blank.Enqueue('NoPassword');$blank.Enqueue($emptySecure)
        $prompts.Clear();$responses=$blank
        $empty=Read-LocalAccountOptions -Build 28000 -EditionId Core -Mode auto
        Assert ($empty.Password.Length -eq 0 -and $prompts.Count -eq 2) 'An empty password remains allowed and does not require confirmation'
        $provided=ConvertTo-SecureString 'command line password' -AsPlainText -Force
        $direct=Read-LocalAccountOptions -Build 28000 -EditionId Core -Mode image -Name ExplicitUser -Password $provided
        Assert ((Test-SecureStringEqual $direct.Password $provided) -and $prompts.Count -eq 2) 'Explicit SecureString parameters are retained without an interactive second prompt'
    }
    $password=ConvertTo-SecureString 'Fixture password & 7' -AsPlainText -Force
    $receiver=Join-Path $root 'account-parameters.ps1'
    [IO.File]::WriteAllText($receiver,'param([Security.SecureString]$LocalUserPassword,[switch]$Elevated) [pscustomobject]@{Password=[Net.NetworkCredential]::new("",$LocalUserPassword).Password;Elevated=[bool]$Elevated}',[Text.UTF8Encoding]::new($true))
    $encodedCommand=Get-ElevationCommand -ScriptPath $receiver -Parameters @{LocalUserPassword=$password}
    $forwarded=& ([scriptblock]::Create([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedCommand))))
    Assert ($forwarded.Password -eq 'Fixture password & 7' -and $forwarded.Elevated) 'SecureString account parameters survive the elevation serialization'
    & {
        $state=@{Registered=$true;Calls=0}
        function Test-Path {param($Path,$LiteralPath)if(($Path+$LiteralPath) -like '*WimMountAdkSetupAmd64.exe'){$true}else{$state.Registered}}
        function Get-ItemProperty {param($Path,$Name,$ErrorAction)[pscustomobject]@{ImagePath='existing-driver'}}
        function Invoke-NativeQuiet {param($FilePath,$Arguments)$state.Calls++;$state.Registered=$true;0}
        $script:Dism='C:\fixture\dism.exe'
        Ensure-WimMountDriver
        Assert ($state.Calls -eq 0) 'An existing WIMMount driver is retained'
        $state.Registered=$false;Ensure-WimMountDriver
        Assert ($state.Calls -eq 1 -and $state.Registered) 'Missing WIMMount is registered through the selected tool set'
    }
    foreach($edition in 'Core','Professional','IoTEnterpriseS'){
        $selected=[pscustomobject]@{EditionId=$edition};$LocalUserName='Тест & User';$LocalUserPassword=$password
        $CompactOS=$true;$imgLang='ru-RU';$setupLang='ru-RU';$ProductKey=''
        foreach($name in 'setupInputLocale','compactBlock','localAccountXml','productKeyUi','escapedProductKey','productKeyValue','oobeNetBlock','unattendXml'){
            $node=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$'+$name)},$true)
            . ([scriptblock]::Create($node.Extent.Text))
        }
        [xml]$xml=$unattendXml;$ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
        Assert ($xml.SelectSingleNode('//u:LocalAccount/u:Name',$ns).InnerText -eq $LocalUserName) "Actual answer file safely carries the local account name ($edition)"
        $encoded=$xml.SelectSingleNode('//u:LocalAccount/u:Password/u:Value',$ns).InnerText
        Assert ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded)) -eq 'Fixture password & 7Password' -and $unattendXml -notmatch 'Fixture password') 'Password uses the documented Windows answer-file encoding'
        Assert ($xml.SelectSingleNode('//u:MetaData[u:Key="/IMAGE/INDEX"]/u:Value',$ns).InnerText -eq '1') 'Setup selects the exported index regardless of the source index'
        Assert ($xml.SelectSingleNode('//u:ProductKey/u:WillShowUI',$ns).InnerText -eq $(if($edition -eq 'IoTEnterpriseS'){'Never'}else{'OnError'})) "Consumer editions can recover from key-entry errors ($edition)"
        Assert ([bool]$xml.SelectSingleNode('//u:ProductKey/u:Key',$ns) -eq ($edition -eq 'IoTEnterpriseS')) 'Missing consumer product keys do not produce unsupported empty Key elements'
        Assert ($xml.SelectSingleNode('//u:OSImage/u:Compact',$ns).InnerText -eq 'true' -and -not $xml.SelectSingleNode('//u:AutoLogon',$ns)) 'CompactOS is preserved without adding automatic logon'
    }
    Assert ((Get-LocalAccountXml -Name '') -eq '' -and (Get-ImageInstallXml -Compact $false) -notmatch '<Compact>') 'Unrequested account creation and compression remain absent'
    Write-Host "PASS: $script:checks servicing checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $full=[IO.Path]::GetFullPath($root);$base=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\servicing-tests-'
    if($full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $full -Recurse -Force}
}
