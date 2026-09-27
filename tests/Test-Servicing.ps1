#Requires -Version 5.1
# WIM metadata, tool preparation and answer files only. No image servicing or guest operations.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
foreach($name in 'T','Get-AdkSourceHash','Confirm-MicrosoftSignature','Read-MsiTable','Get-MsiDirectoryPath','Get-MsiFileMap','Save-AdkInstallers','Get-AdkCatalog','Get-WimImageList','Get-IsoEditions','Get-NativeToolVersion','Save-DeploymentTools','Initialize-DeploymentTools','Ensure-WimMountDriver','Read-PreparedCache','Write-PreparedCache','Assert-ChildPath','Invoke-NativeQuiet','Test-DismSuccess','Resolve-AccountMode','Assert-LocalUserName','Test-SecureStringEqual','Read-ConfirmedLocalAccountPassword','Read-LocalAccountOptions','Get-LocalAccountXml','Get-ImageInstallXml','Get-ProductKeyUiMode','Get-ElevationCommand','Get-AutoLogonXml','Get-AutoInstallDiskXml','Get-AutoInstallDiskScripts','Write-AutoInstallMediaFiles','Resolve-InputIsoPath','Select-InputIso','Get-NormalizedDirectory','Get-IsoFilesInDirectory','Write-IsoList','Format-Size'){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    if(-not $node){throw "Missing function: $name"}
    . ([scriptblock]::Create($node.Extent.Text))
}
$adkNode=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:AdkSources'},$true)
if(-not $adkNode){throw 'Missing pinned ADK source table'}
. ([scriptblock]::Create($adkNode.Extent.Text))
$script:Lang='en';$script:checks=0;$Unattend='';$SkipIso=$false
$launchHelper=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SetupEntryCommand'},$false)
. ([scriptblock]::Create($launchHelper.Extent.Text))
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
        # Real sharing violation on a fixture; disk mounting itself is mocked.
        $iso=Join-Path $root 'locked source.iso';[IO.File]::WriteAllText($iso,'fixture')
        $testDrive=(Split-Path -Qualifier $root).TrimEnd(':')
        $state=@{Attached=$false;Mounts=0;Unmounts=0;Prompted=$false;Wim=$true;Esd=$false;Empty=$false;ReadError=$false;VolumeError=$false;DriveLetter=$testDrive;ReadPath=''}
        function Get-DiskImage {param($ImagePath,$ErrorAction)[pscustomobject]@{Attached=$state.Attached}}
        function Mount-DiskImage {
            param($ImagePath,[switch]$PassThru,$Access,$ErrorAction)
            $stream=[IO.File]::Open($ImagePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            $stream.Dispose();$state.Mounts++;[pscustomobject]@{Attached=$true}
        }
        function Dismount-DiskImage {param($ImagePath)$state.Unmounts++}
        function Get-Volume {
            [CmdletBinding()]param([Parameter(ValueFromPipeline)]$Disk)
            process{if($state.VolumeError){Write-Error 'fixture volume failure';return};[pscustomobject]@{DriveLetter=$state.DriveLetter}}
        }
        function Start-Sleep {param($Seconds)}
        function Test-Path {param($LiteralPath)if($LiteralPath -like '*\sources\install.wim'){$state.Wim}elseif($LiteralPath -like '*\sources\install.esd'){$state.Esd}else{Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath}}
        function Get-WimImageList {param($Path)$state.ReadPath=$Path;if($state.ReadError){throw 'fixture metadata failure'};if(-not $state.Empty){$images}}
        function Test-CanPrompt {$true}
        function Read-PathOrDefault {param($Question,$Default)$state.Prompted=$true;throw 'wizard incorrectly continued'}
        function Write-Host {param($Object,$ForegroundColor)}
        $wizard=$ast.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$script:WizardMode'},$false)
        if(-not $wizard){throw 'Wizard block not found'}
        $oldWizardMode=$script:WizardMode;$script:WizardMode=$true;$InputIso=$iso
        $lock=[IO.File]::Open($iso,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{
            foreach($lang in 'ru','en'){
                $script:Lang=$lang;$failure=$null
                try{& ([scriptblock]::Create($wizard.Extent.Text))}catch{$failure=$_}
                $expected=if($lang -eq 'ru'){'Сборка остановлена'}else{'Build stopped'}
                Assert ($null -ne $failure -and $failure.Exception.Message.Contains($iso) -and $failure.Exception.Message.Contains($expected)) "Locked ISO terminates the real wizard with its path and localized error ($lang)"
                Assert (-not $state.Prompted -and $state.Mounts -eq 0 -and $state.Unmounts -eq 0) "A sharing violation cannot reach the work-folder prompt or unmount an unowned image ($lang)"
            }
        }finally{$lock.Dispose();$script:WizardMode=$oldWizardMode;$script:Lang='en'}
        $found=@(Get-IsoEditions -Path $iso)
        Assert ($found.Count -eq 1 -and $found[0].EditionId -eq 'Core' -and $state.ReadPath -eq "${testDrive}:\sources\install.wim") 'Successful ISO reading still returns the actual edition metadata'
        Assert ($state.Mounts -eq 1 -and $state.Unmounts -eq 1) 'Successful reading releases the mount it created'
        $state.Attached=$true;$state.Wim=$false;$state.Esd=$true
        $found=@(Get-IsoEditions -Path $iso)
        Assert ($found.Count -eq 1 -and $state.ReadPath -eq "${testDrive}:\sources\install.esd" -and $state.Unmounts -eq 1) 'An already mounted ESD image is read without unmounting the user mount'
        $state.ReadError=$true
        Assert-Throws {Get-IsoEditions -Path $iso} 'A metadata read failure terminates instead of returning an empty edition list'
        Assert ($state.Unmounts -eq 1) 'A metadata failure also preserves a user-owned mount'
        $state.Attached=$false
        Assert-Throws {Get-IsoEditions -Path $iso} 'A metadata failure propagates from a newly mounted image'
        Assert ($state.Unmounts -eq 2) 'A metadata failure releases the mount created by the reader'
        $state.ReadError=$false;$state.Esd=$false
        Assert-Throws {Get-IsoEditions -Path $iso} 'Missing install.wim and install.esd is a fatal image error'
        $state.Esd=$true;$state.Empty=$true
        Assert-Throws {Get-IsoEditions -Path $iso} 'An image with no editions is a fatal image error'
        $state.Empty=$false;$state.DriveLetter=$null;$state.ReadPath=''
        Assert-Throws {Get-IsoEditions -Path $iso} 'A missing drive letter terminates before constructing an invalid path'
        Assert ($state.ReadPath -eq '') 'A missing drive letter cannot redirect reads to another drive'
        $state.DriveLetter=$testDrive;$state.VolumeError=$true
        Assert-Throws {Get-IsoEditions -Path $iso} 'Volume enumeration errors terminate ISO reading'
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
    # Хост без ADK: системный DISM подходит, oscdimg нет (случай пользователя с Windows 10 LTSC 2021).
    & {
        $state=@{Downloads=0;Builds=@();Notes=0;Installs=0}
        function Get-NativeToolVersion {param($Path)if($Path -like '*System32*'){[version]'10.0.26100.8875'}elseif($Path -like '*fresh*'){[version]'10.0.28000.1'}else{$null}}
        function Test-Path {param($LiteralPath,$Path,[switch]$PathType)$false}
        function Save-DeploymentTools {param($Directory,$Build)$state.Downloads++;$state.Builds+=$Build;[pscustomobject]@{Dism='C:\fresh\dism.exe';Oscdimg='C:\fresh\oscdimg.exe'}}
        function Write-Note {param($Message)$state.Notes++}
        function Save-Url {param($Url,$Destination)$state.Installs++;throw 'ADK installer path reached'}
        $script:Dism=$null;$script:Oscdimg=$null;$SkipIso=$false
        Initialize-DeploymentTools -Build 19041 -Directory $root
        Assert ($state.Downloads -eq 1 -and $state.Builds[0] -eq 28000 -and $script:Oscdimg -eq 'C:\fresh\oscdimg.exe' -and $script:Dism -like '*System32\dism.exe') 'A host without ADK gets only oscdimg from the pinned packages and keeps its own DISM'
        $state.Downloads=0;$script:Dism=$null;$script:Oscdimg=$null
        Initialize-DeploymentTools -Build 19041 -Directory $root -Preview
        Assert ($state.Downloads -eq 0 -and $state.Notes -eq 1) 'DryRun only announces the oscdimg preparation'
        $script:Dism=$null;$script:Oscdimg=$null
        Assert-Throws {Initialize-DeploymentTools -Build 19041 -Directory $root -Install} 'Explicit -InstallAdk still installs Deployment Tools instead of the light path'
        Assert ($state.Downloads -eq 0 -and $state.Installs -eq 1) 'With -InstallAdk the pinned oscdimg is not substituted'
        $script:Dism=$null;$script:Oscdimg=$null;$SkipIso=$true
        Initialize-DeploymentTools -Build 19041 -Directory $root
        Assert ($state.Downloads -eq 0 -and -not $script:Oscdimg) '-SkipIso needs no oscdimg at all'
        $SkipIso=$false
        function Save-DeploymentTools {param($Directory,$Build)throw 'catalog unavailable'}
        $script:Dism=$null;$script:Oscdimg=$null;$failure=''
        try{Initialize-DeploymentTools -Build 19041 -Directory $root}catch{$failure=$_.Exception.Message}
        Assert ($failure -match 'catalog unavailable' -and $failure -match '-InstallAdk') 'A failed oscdimg preparation keeps the reason and suggests -InstallAdk'
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
            Assert ($choice.Mode -eq 'setup' -and -not $choice.Name) "26H1 $edition preview defaults to account entry during Windows Setup"
            Assert ((Read-LocalAccountOptions -Build 28000 -EditionId $edition -Mode auto).Mode -eq 'setup') "26H1 $edition uses the same default without interactive input"
            Assert-Throws {Read-LocalAccountOptions -Build 28000 -EditionId $edition -Mode image} "Explicit account creation still requires a user name when noninteractive"
        }
        Assert ((Read-LocalAccountOptions -Build 26100 -EditionId IoTEnterpriseS -Mode auto).Mode -eq 'setup') 'Existing LTSC account setup stays unchanged'
        Assert ((Read-LocalAccountOptions -Build 28000 -EditionId Core -Mode setup).Mode -eq 'setup') 'Explicit Windows account-entry mode stays available'
        Assert ((Read-LocalAccountOptions -Build 28000 -EditionId Core -Mode auto -Name 'Тест & User').Name -eq 'Тест & User') 'Explicit local user enables account creation without prompting'
        foreach($name in 'Administrator','defaultuser0','bad/name','..','trailing.','a,b',('a'*21)) {Assert-Throws {Assert-LocalUserName $name} 'Invalid and built-in account names are rejected'}
        $Unattend='custom.xml'
        Assert-Throws {Read-LocalAccountOptions -Build 28000 -EditionId Core -Mode image -Name TestUser} 'Local account generation does not overwrite custom answer files'
    }
    & {
        # Exercise the real menu with Enter and option 2 across Windows branches.
        $menu=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-Option'},$false)
        . ([scriptblock]::Create($menu.Extent.Text))
        function Test-CanPrompt {$true}
        $shown=[Collections.Generic.List[string]]::new();$prompts=[Collections.Generic.List[string]]::new()
        $answers=[Collections.Queue]::new()
        function Write-Host {param($Object,$ForegroundColor)$shown.Add([string]$Object)}
        function Read-Host {param($Prompt,[switch]$AsSecureString)$prompts.Add($Prompt);$answers.Dequeue()}
        $Unattend='';$script:Lang='ru'
        foreach($source in @(@(22000,'Core'),@(22621,'Professional'),@(22631,'Enterprise'),@(26100,'IoTEnterpriseS'),@(26200,'Professional'),@(28000,'Core'),@(28000,'Professional'))){
            $shown.Clear();$prompts.Clear();$answers.Enqueue('')
            $choice=Read-LocalAccountOptions -Build $source[0] -EditionId $source[1] -Mode auto
            Assert ($choice.Mode -eq 'setup' -and -not $choice.Name -and $prompts.Count -eq 1) "Enter chooses Windows Setup for $($source -join '/') without asking for credentials"
            Assert ($shown[1] -match '\*\s*1\. При установке Windows' -and $shown[2] -match '2\. Сейчас, до сборки ISO' -and $prompts[0] -match 'Enter — 1') 'The displayed order and default match the requested menu'
        }
        $shown.Clear();$prompts.Clear();$answers.Enqueue('2');$answers.Enqueue('ImageUser');$answers.Enqueue([Security.SecureString]::new())
        $choice=Read-LocalAccountOptions -Build 26100 -EditionId IoTEnterpriseS -Mode auto
        Assert ($choice.Mode -eq 'image' -and $choice.Name -eq 'ImageUser' -and $prompts.Count -eq 3) 'Option 2 collects the account before the build on LTSC as well'
        $prompts.Clear()
        $null=Read-LocalAccountOptions -Build 26100 -EditionId IoTEnterpriseS -Mode $choice.Mode -Name $choice.Name -Password $choice.Password
        $null=Read-LocalAccountOptions -Build 28000 -EditionId Core -Mode setup
        $null=Read-LocalAccountOptions -Build 28000 -EditionId Core -Mode auto -Preview
        $Unattend='custom.xml';$null=Read-LocalAccountOptions -Build 28000 -EditionId Core -Mode auto
        Assert ($prompts.Count -eq 0) 'The resolved choice, explicit setup, preview and custom answer file do not trigger a second menu'
        $Unattend='';$script:Lang='en';$shown.Clear();$answers.Enqueue('')
        $choice=Read-LocalAccountOptions -Build 28000 -EditionId Core -Mode auto
        Assert ($choice.Mode -eq 'setup' -and $shown[1] -match '\*\s*1\. During Windows Setup' -and $shown[2] -match '2\. Now, before building the ISO') 'English has the same order and default'
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
        $useVbsLauncher=$edition -ne 'IoTEnterpriseS'
        $selected=[pscustomobject]@{EditionId=$edition};$LocalUserName='Тест & User';$LocalUserPassword=$password
        $CompactOS=$true;$imgLang='ru-RU';$setupLang='ru-RU';$ProductKey=''
        foreach($name in 'prepareCommand','registerCommand','finalizeCommand','setupInputLocale','compactBlock','localAccountXml','productKeyUi','escapedProductKey','productKeyValue','oobeNetBlock','unattendXml'){
            $node=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$'+$name)},$true)
            . ([scriptblock]::Create($node.Extent.Text))
        }
        [xml]$xml=$unattendXml;$ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
        Assert ($xml.SelectSingleNode('//u:RunSynchronousCommand/u:Path',$ns).InnerText -eq $prepareCommand -and $xml.SelectSingleNode('//u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine',$ns).InnerText -eq $finalizeCommand) 'The actual answer file retains the selected VBS or PowerShell launcher commands'
        Assert ($xml.SelectSingleNode('//u:LocalAccount/u:Name',$ns).InnerText -eq $LocalUserName) "Actual answer file safely carries the local account name ($edition)"
        $encoded=$xml.SelectSingleNode('//u:LocalAccount/u:Password/u:Value',$ns).InnerText
        Assert ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded)) -eq 'Fixture password & 7Password' -and $unattendXml -notmatch 'Fixture password') 'Password uses the documented Windows answer-file encoding'
        Assert ($xml.SelectSingleNode('//u:MetaData[u:Key="/IMAGE/INDEX"]/u:Value',$ns).InnerText -eq '1') 'Setup selects the exported index regardless of the source index'
        Assert ($xml.SelectSingleNode('//u:ProductKey/u:WillShowUI',$ns).InnerText -eq $(if($edition -eq 'IoTEnterpriseS'){'Never'}else{'OnError'})) "Consumer editions can recover from key-entry errors ($edition)"
        Assert ([bool]$xml.SelectSingleNode('//u:ProductKey/u:Key',$ns) -eq ($edition -eq 'IoTEnterpriseS')) 'Missing consumer product keys do not produce unsupported empty Key elements'
        Assert ($xml.SelectSingleNode('//u:OSImage/u:Compact',$ns).InnerText -eq 'true' -and -not $xml.SelectSingleNode('//u:AutoLogon',$ns)) 'CompactOS is preserved without adding automatic logon'
    }
    Assert ((Get-LocalAccountXml -Name '') -eq '' -and (Get-ImageInstallXml -Compact $false) -notmatch '<Compact>') 'Unrequested account creation and compression remain absent'
    Assert ($unattendXml -notmatch 'InstallToAvailablePartition|AdministratorPassword|win11lite\\disk\.cmd') 'Without -AutoInstall Setup still asks for the disk and no built-in Administrator is enabled'

    # Регрессия: ISO с одной редакцией (Windows 10 IoT LTSC 2021) мастер считал
    # en-US Windows 11 — одиночный PSCustomObject в PS 5.1 не имеет Count.
    & {
        $editionStep=[regex]::Match($ast.Extent.Text,'(?ms)^    # @\(\): одна редакция.*?^    \$wizardWindows10 = [^\r\n]+').Value
        if(-not $editionStep){throw 'Wizard edition step not found'}
        function Write-Host {param($Object,$ForegroundColor)}
        $InputIso='fixture.iso';$script:Lang='ru'
        function Get-IsoEditions {param($Path) [pscustomobject]@{Index=1;Name='Windows 10 Enterprise LTSC 2021';EditionId='IoTEnterpriseS';Languages='ru-RU';Version='10.0.19041.1288'}}
        $Index=0;. ([scriptblock]::Create($editionStep))
        Assert ($Index -eq 1 -and $wizardLang -eq 'ru-RU' -and $wizardWindows10 -and $wizardImage.EditionId -eq 'IoTEnterpriseS') 'A single-edition ISO selects its index, language and Windows 10 family instead of en-US Windows 11'
        function Get-IsoEditions {param($Path) @([pscustomobject]@{Index=1;Name='Enterprise LTSC';EditionId='EnterpriseS';Languages='en-US';Version='10.0.26100.1742'},[pscustomobject]@{Index=2;Name='IoT Enterprise LTSC';EditionId='IoTEnterpriseS';Languages='en-US';Version='10.0.26100.1742'})}
        function Read-Option {param($Question,$Items,$Values,$Default)$Values[$Default-1]}
        $Index=0;. ([scriptblock]::Create($editionStep))
        Assert ($Index -eq 2 -and $wizardLang -eq 'en-US' -and -not $wizardWindows10) 'Multi-edition ISOs keep the edition menu and Windows 11 detection'
        $script:Lang='en'
    }

    # Выбор ISO: папка вместо файла показывает все ISO из неё (случай пользователя:
    # «Указать свой файл» → «F:\OS\Windows\»).
    & {
        $isoRoot=Join-Path $root 'iso choice';$folder=Join-Path $isoRoot 'OS\Windows';$emptyFolder=Join-Path $isoRoot 'empty'
        $null=New-Item -ItemType Directory -Path $folder,$emptyFolder,(Join-Path $folder 'nested') -Force
        foreach($name in 'b-win10.iso','a-win11.ISO','notes.txt','nested\deep.iso'){[IO.File]::WriteAllText((Join-Path $folder $name),'fixture')}
        $shown=[Collections.Generic.List[string]]::new();$answers=[Collections.Queue]::new()
        function Write-Host {param($Object,$ForegroundColor)$shown.Add([string]$Object)}
        function Read-Host {param($Prompt)if(-not $answers.Count){throw 'Unexpected extra prompt'};$answers.Dequeue()}
        function Test-CanPrompt {$true}
        $savedRoot=$script:ScriptRoot;$script:ScriptRoot=$emptyFolder;$script:Lang='ru'
        Push-Location -LiteralPath $emptyFolder
        try{
            foreach($answer in '1',"$folder\",'2'){$answers.Enqueue($answer)}
            $picked=Select-InputIso
            $text=$shown -join "`n"
            Assert ($picked -eq (Join-Path $folder 'b-win10.iso') -and -not $answers.Count) 'A folder entered for "own file" lists its ISO files and the chosen number returns that ISO'
            Assert ($text -match 'Рядом со скриптом ISO-файлов не найдено' -and $text.Contains("ISO-файлы в папке ${folder}:") -and $text -match '1\. a-win11\.ISO' -and $text -match '2\. b-win10\.iso') 'The folder list is shown with numbers, sorted by name, including an upper-case .ISO'
            Assert ($text -notmatch 'notes\.txt|deep\.iso') 'Other files and ISO files in subfolders are not listed'
            Assert ((Get-NormalizedDirectory 'F:\OS\Windows\') -eq 'F:\OS\Windows' -and (Get-NormalizedDirectory 'F:\') -eq 'F:\') 'A trailing backslash is dropped except for a drive root'
            $shown.Clear();foreach($answer in "`"$folder`"",'1'){$answers.Enqueue($answer)}
            Assert ((Select-InputIso) -eq (Join-Path $folder 'a-win11.ISO')) 'A quoted folder path typed instead of a number also opens the folder list'
            $shown.Clear();foreach($answer in '1',$emptyFolder,(Join-Path $folder 'notes.txt'),'C:\no-such-folder\x.iso','7',(Join-Path $folder 'b-win10.iso')){$answers.Enqueue($answer)}
            $picked=Select-InputIso;$text=$shown -join "`n"
            Assert ($picked -eq (Join-Path $folder 'b-win10.iso') -and $text -match 'ISO-файлов нет' -and $text -match 'Это не ISO-файл' -and $text -match 'Путь не найден' -and $text -match 'Введите число от 1 до 1') 'An empty folder, a non-ISO file, a missing path and a wrong number are explained and asked again'
            $shown.Clear();$answers.Enqueue('2')
            Assert ((Resolve-InputIsoPath -Path $folder) -eq (Join-Path $folder 'b-win10.iso') -and ($shown -join "`n").Contains("ISO-файлы в папке ${folder}:")) '-InputIso with a folder opens the same folder list in the interactive wizard'
            Assert ((Resolve-InputIsoPath -Path (Join-Path $folder 'a-win11.ISO')) -eq (Join-Path $folder 'a-win11.ISO')) 'A direct ISO path is accepted as before'
            Assert-Throws {Resolve-InputIsoPath -Path (Join-Path $folder 'notes.txt')} 'A non-ISO file passed to -InputIso stops before mounting'
            function Test-CanPrompt {$false}
            $failure='';try{Resolve-InputIsoPath -Path $folder|Out-Null}catch{$failure=$_.Exception.Message}
            Assert ($failure -match 'указывает на папку' -and $failure.Contains($folder)) 'A folder without interactive input stops with a clear message naming the folder'
        }finally{Pop-Location;$script:ScriptRoot=$savedRoot;$script:Lang='en'}
    }

    # -AutoInstall: учётная запись без вопросов.
    & {
        function Test-CanPrompt {$true}
        function Read-Option {param($Question,$Items,$Values,$Default) throw 'AutoInstall must not ask where to configure the account'}
        function Read-Host {param($Prompt,[switch]$AsSecureString) throw 'AutoInstall must not prompt'}
        $Unattend=''
        $admin=Read-LocalAccountOptions -Build 19041 -EditionId IoTEnterpriseS -Mode auto -AutoInstall
        Assert (-not $admin.Name -and $admin.Mode -eq 'auto' -and $null -eq $admin.Password) 'AutoInstall without a name selects the built-in Administrator without any prompt'
        $named=Read-LocalAccountOptions -Build 26100 -EditionId IoTEnterpriseS -Mode auto -Name 'Tester' -AutoInstall
        Assert ($named.Mode -eq 'image' -and $named.Name -eq 'Tester') 'AutoInstall with -LocalUserName creates that account instead'
        Assert-Throws {Read-LocalAccountOptions -Build 26100 -EditionId IoTEnterpriseS -Mode setup -AutoInstall} 'AutoInstall rejects -AccountMode setup, which would ask in OOBE'
        Assert-Throws {Read-LocalAccountOptions -Build 26100 -EditionId IoTEnterpriseS -Mode auto -Password (ConvertTo-SecureString 'x' -AsPlainText -Force) -AutoInstall} 'A password without an account name is rejected'
    }
    # -AutoInstall: настоящие выражения answer-файла, затем разбор XML.
    $answerNames='prepareCommand','registerCommand','finalizeCommand','setupInputLocale','compactBlock','localAccountXml','autoInstallPeXml','autoLogonXml','productKeyUi','escapedProductKey','productKeyValue','oobeNetBlock','unattendXml'
    $buildAnswer={
        foreach($name in $answerNames){
            $node=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$'+$name)},$true)
            if(-not $node){throw "Missing answer-file assignment: $name"}
            . ([scriptblock]::Create($node.Extent.Text))
        }
        [xml]$doc=$unattendXml;$doc
    }
    $AutoInstall=$true;$useVbsLauncher=$true;$selected=[pscustomobject]@{EditionId='IoTEnterpriseS'};$LocalUserName='';$LocalUserPassword=$null;$CompactOS=$false;$ProductKey=''
    $xml=. $buildAnswer;$ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
    $peSetup=$xml.SelectSingleNode('//u:settings[@pass="windowsPE"]/u:component[@name="Microsoft-Windows-Setup"]',$ns)
    $order=@($peSetup.ChildNodes|Where-Object NodeType -eq 'Element'|ForEach-Object LocalName)
    Assert (($order -join ',') -eq 'ImageInstall,RunSynchronous,UserData') 'Disk partitioning sits between ImageInstall and UserData, as the strict schema order requires'
    Assert ($peSetup.SelectSingleNode('u:ImageInstall/u:OSImage/u:InstallToAvailablePartition',$ns).InnerText -eq 'true' -and -not $peSetup.SelectSingleNode('u:ImageInstall/u:OSImage/u:InstallTo',$ns)) 'Setup picks the Windows partition itself; InstallTo is never combined with it'
    $diskCommand=$peSetup.SelectSingleNode('u:RunSynchronous/u:RunSynchronousCommand/u:Path',$ns).InnerText
    Assert ($diskCommand -match '\\win11lite\\disk\.cmd' -and $diskCommand -match ' & exit /b\)$' -and $diskCommand -notmatch '\bX\b') 'WinPE searches every media letter except the X: RAM disk for the partitioning script'
    $shell=$xml.SelectSingleNode('//u:settings[@pass="oobeSystem"]/u:component[@name="Microsoft-Windows-Shell-Setup"]',$ns)
    $autoLogon=$shell.SelectSingleNode('u:AutoLogon',$ns)
    Assert ($autoLogon -and $shell.FirstChild.LocalName -eq 'AutoLogon' -and $autoLogon.Username -eq 'Administrator' -and $autoLogon.Enabled -eq 'true' -and [int]$autoLogon.LogonCount -ge 1000000) 'The English name Administrator enables the built-in account and signs in automatically'
    Assert ($autoLogon.Password.Value -eq '' -and $autoLogon.Password.PlainText -eq 'true') 'Automatic sign-in uses the documented empty password'
    Assert ($shell.SelectSingleNode('u:UserAccounts/u:AdministratorPassword/u:Value',$ns).InnerText -eq '' -and -not $shell.SelectSingleNode('u:UserAccounts/u:LocalAccounts',$ns)) 'The built-in Administrator gets a blank password and no extra account is created'
    Assert ($shell.SelectSingleNode('u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine',$ns).InnerText -eq $finalizeCommand -and $xml.SelectSingleNode('//u:settings[@pass="specialize"]//u:RunSynchronousCommand/u:Path',$ns).InnerText -eq $prepareCommand) 'Preparation and finalization still run with automatic installation'
    $LocalUserName='Tester';$LocalUserPassword=ConvertTo-SecureString 'Auto pw & 1' -AsPlainText -Force
    $xml=. $buildAnswer;$ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
    $autoLogon=$xml.SelectSingleNode('//u:AutoLogon',$ns)
    Assert ($autoLogon.Username -eq 'Tester' -and $autoLogon.Password.PlainText -eq 'false' -and [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($autoLogon.Password.Value)) -eq 'Auto pw & 1Password') 'A named account signs in with its own encoded password'
    Assert ($xml.SelectSingleNode('//u:LocalAccount/u:Name',$ns).InnerText -eq 'Tester' -and -not $xml.SelectSingleNode('//u:AdministratorPassword',$ns) -and $unattendXml -notmatch 'Auto pw') 'A named account replaces the built-in Administrator and its password stays encoded'
    $LocalUserName='';$LocalUserPassword=$null;$AutoInstall=$false

    # Сценарии разметки: содержимое и запуск настоящим cmd.exe той же командой,
    # что в answer-файле. reg/diskpart подменены, а на «носителе» — безвредные
    # сценарии-заглушки: случайный вызов настоящего diskpart ничего не сотрёт.
    $scripts=Get-AutoInstallDiskScripts
    foreach($layout in 'uefi','bios'){
        $lines=@($scripts["disk-$layout.txt"] -split "`r`n")
        Assert ($lines[0] -eq 'select disk 0' -and $lines[1] -eq 'clean' -and $lines[-1] -eq 'exit') "The $layout layout wipes only disk 0"
    }
    Assert ($scripts['disk-uefi.txt'] -match 'convert gpt' -and $scripts['disk-uefi.txt'] -match 'create partition efi' -and $scripts['disk-uefi.txt'] -match 'create partition msr size=16') 'UEFI gets the GPT layout with ESP and MSR'
    Assert ($scripts['disk-bios.txt'] -match 'convert mbr' -and $scripts['disk-bios.txt'] -match '(?m)^active\r?$') 'BIOS gets the MBR layout with an active system partition'
    $media=Join-Path $root 'autoinstall-media'
    Write-AutoInstallMediaFiles -Distribution $media
    $written=Join-Path $media 'win11lite'
    foreach($file in 'disk.cmd','disk-uefi.txt','disk-bios.txt'){
        $bytes=[IO.File]::ReadAllBytes((Join-Path $written $file))
        Assert ($bytes.Length -gt 0 -and $bytes[0] -ne 0xEF -and ([Text.Encoding]::ASCII.GetString($bytes) -replace "`r`n",'') -notmatch "`n") "$file is written as ASCII with CRLF"
    }
    foreach($layout in 'uefi','bios'){[IO.File]::WriteAllText((Join-Path $written "disk-$layout.txt"),"rem harmless $layout fixture`r`n",[Text.Encoding]::ASCII)}
    $fakeBin=Join-Path $root 'autoinstall-bin';$null=New-Item -ItemType Directory -Path $fakeBin
    $diskLog=Join-Path $root 'diskpart.log'
    [IO.File]::WriteAllText((Join-Path $fakeBin 'reg.cmd'),"@echo off`r`nif defined FIXTURE_FIRMWARE echo     PEFirmwareType    REG_DWORD    %FIXTURE_FIRMWARE%`r`n",[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $fakeBin 'diskpart.cmd'),"@echo off`r`n>>`"$diskLog`" echo %*`r`nexit /b 0`r`n",[Text.Encoding]::ASCII)
    $letter=@('W','V','U','T','S','R','Q','P')|Where-Object{-not (Test-Path "$($_):\")}|Select-Object -First 1
    if(-not $letter){throw 'No free drive letter for the subst fixture'}
    $savedPath=$env:PATH;$savedFirmware=$env:FIXTURE_FIRMWARE
    try{
        & subst.exe "$($letter):" $media
        if($LASTEXITCODE -ne 0){throw "subst failed with $LASTEXITCODE"}
        $env:PATH="$fakeBin;$savedPath"
        $resolved=@(& cmd.exe /d /c where diskpart)
        if($resolved[0] -ne (Join-Path $fakeBin 'diskpart.cmd')){throw "Unsafe fixture: diskpart resolves to $($resolved[0])"}
        foreach($case in @(@{Firmware='0x2';Layout='uefi'},@{Firmware='0x1';Layout='bios'},@{Firmware=$null;Layout='bios'})){
            Remove-Item -LiteralPath $diskLog -ErrorAction SilentlyContinue
            $env:FIXTURE_FIRMWARE=$case.Firmware
            # Setup запускает Path напрямую (CreateProcess), без внешнего cmd /c,
            # который разрезал бы строку по «&» раньше времени.
            $start=[Diagnostics.ProcessStartInfo]::new('cmd.exe',($diskCommand -replace '^cmd\.exe\s+',''))
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true
            $process=[Diagnostics.Process]::Start($start);$process.WaitForExit();$process.Dispose()
            $calls=@(Get-Content -LiteralPath $diskLog -ErrorAction SilentlyContinue)
            Assert ($calls.Count -eq 1 -and $calls[0] -match ('/s "?'+[regex]::Escape("$($letter):\win11lite\disk-$($case.Layout).txt"))) "The real command line finds the media, detects firmware $($case.Firmware) and runs diskpart once with the $($case.Layout) layout"
        }
    }finally{
        $env:PATH=$savedPath;$env:FIXTURE_FIRMWARE=$savedFirmware
        & subst.exe "$($letter):" /d | Out-Null
    }

    # Загрузочный образ UEFI без «Press any key» — только для -AutoInstall.
    $bootRegion=[regex]::Match($ast.Extent.Text,'(?ms)^\s*\$efiBootImage = .*?^\s*\$bootData = [^\r\n]+').Value
    if(-not $bootRegion){throw 'ISO boot-image selection not found'}
    $isoDir=Join-Path $root 'iso-boot';$null=New-Item -ItemType Directory -Path (Join-Path $isoDir 'efi\microsoft\boot') -Force
    $bootNotes=[Collections.Generic.List[string]]::new()
    function Write-Note {param($Message)$bootNotes.Add($Message)}
    $AutoInstall=$true;. ([scriptblock]::Create($bootRegion))
    Assert ($bootData -match 'efisys\.bin$' -and $bootNotes.Count -eq 1) 'Media without efisys_noprompt.bin keep the prompt and say so'
    [IO.File]::WriteAllBytes((Join-Path $isoDir 'efi\microsoft\boot\efisys_noprompt.bin'),[byte[]](1,2,3))
    . ([scriptblock]::Create($bootRegion))
    Assert ($bootData -eq '2#p0,e,bboot\etfsboot.com#pEF,e,befi\microsoft\boot\efisys_noprompt.bin') 'AutoInstall media boot UEFI without waiting for a key press'
    $AutoInstall=$false;. ([scriptblock]::Create($bootRegion))
    Assert ($bootData -eq '2#p0,e,bboot\etfsboot.com#pEF,e,befi\microsoft\boot\efisys.bin') 'Ordinary media keep the Press any key prompt'
    function Write-Note {param($Message)}
    Write-Host "PASS: $script:checks servicing checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $full=[IO.Path]::GetFullPath($root);$base=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\servicing-tests-'
    if($full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $full -Recurse -Force}
}
