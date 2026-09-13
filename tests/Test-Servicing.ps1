#Requires -Version 5.1
# WIM metadata, tool preparation and answer files only. No image servicing or guest operations.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
foreach($name in 'T','Get-WimImageList','Get-NativeToolVersion','Save-DeploymentTools','Initialize-DeploymentTools','Ensure-WimMountDriver','Read-PreparedCache','Write-PreparedCache','Assert-ChildPath','Invoke-NativeQuiet','Test-DismSuccess','Resolve-AccountMode','Assert-LocalUserName','Test-SecureStringEqual','Read-ConfirmedLocalAccountPassword','Read-LocalAccountOptions','Get-LocalAccountXml','Get-ImageInstallXml','Get-ProductKeyUiMode','Get-ElevationCommand'){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    if(-not $node){throw "Missing function: $name"}
    . ([scriptblock]::Create($node.Extent.Text))
}
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
        $script:ScriptRoot=Join-Path $root 'tool-source';$dataDir=Join-Path $script:ScriptRoot 'data';$null=New-Item -ItemType Directory -Path $dataDir
        $payload=Join-Path $root 'payload.bin';[IO.File]::WriteAllText($payload,'inert tool fixture')
        $cab=Join-Path $root 'fixture.cab'
        & "$env:SystemRoot\System32\makecab.exe" $payload $cab | Out-Null
        if($LASTEXITCODE -ne 0){throw 'Fixture cabinet creation failed'}
        $entry=[ordered]@{Source='payload.bin';Path='amd64\DISM\dism.exe';Size=(Get-Item $payload).Length;SHA256=(Get-FileHash $payload -Algorithm SHA256).Hash}
        $second=[ordered]@{Source='payload.bin';Path='amd64\Oscdimg\oscdimg.exe';Size=$entry.Size;SHA256=$entry.SHA256}
        $archive=[ordered]@{Name='fixture.cab';Url='https://fixture/fixture.cab';Size=(Get-Item $cab).Length;SHA256=(Get-FileHash $cab -Algorithm SHA256).Hash;Files=@($entry,$second)}
        $catalog=[ordered]@{Schema=1;Build=28000;Architecture='amd64';Archives=@($archive)}
        $catalog|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $dataDir 'deployment-tools-28000.json') -Encoding utf8
        $state=@{Copies=0;Corrupt=$false;SourceCab=$cab}
        function Get-NativeToolVersion {param($Path)[version]'10.0.28000.1'}
        function Save-Url {param($Url,$Destination)$state.Copies++;if($state.Corrupt){[IO.File]::WriteAllText($Destination,'broken')}else{Copy-Item -LiteralPath $state.SourceCab -Destination $Destination -Force}}
        $cache=Join-Path $root 'cache'
        $tools=Save-DeploymentTools -Directory $cache
        Assert ((Get-Content -LiteralPath $tools.Dism -Raw) -eq 'inert tool fixture' -and (Test-Path $tools.Oscdimg)) 'Verified CAB files are restored to their proper tool paths'
        Save-DeploymentTools -Directory $cache|Out-Null
        Assert ($state.Copies -eq 1) 'Complete tool cache works without another download'
        [IO.File]::WriteAllText($tools.Dism,'tampered')
        Save-DeploymentTools -Directory $cache|Out-Null
        Assert ((Get-Content -LiteralPath $tools.Dism -Raw) -eq 'inert tool fixture') 'Damaged extracted tools are rebuilt from verified archives'
        $state.Corrupt=$true
        Assert-Throws {Save-DeploymentTools -Directory (Join-Path $root 'bad-cache')} 'Wrong archive hash fails before any tool becomes ready'
        Assert (-not(Test-Path (Join-Path $root 'bad-cache\deployment-tools-28000\tools.ready.json'))) 'A failed tool preparation leaves no ready manifest'
        $archive.Name='..\outside.cab'
        $catalog|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $dataDir 'deployment-tools-28000.json') -Encoding utf8
        Assert-Throws {Save-DeploymentTools -Directory (Join-Path $root 'path-cache')} 'Archive paths cannot escape the tool cache'
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
