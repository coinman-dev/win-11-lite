#Requires -Version 5.1
# Only AST-selected helpers run. HKLM is redirected to a disposable HKCU fixture;
# registry operations also run against real keys there. Power APIs are mocked.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$script:checks=0
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++}
function Assert-Throws([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed $Message}
foreach($name in 'T','Get-MemoryFilePolicy','Set-OfflineMemoryFilePolicy','Get-GuestScript'){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:Lang='en'
$guestAst=[Management.Automation.Language.Parser]::ParseInput((Get-GuestScript),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in 'Set-GuestMemoryFilePolicy','Write-MemoryFileReport'){
    $node=$guestAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
    . ([scriptblock]::Create($node.Extent.Text))
}
$policy=Get-MemoryFilePolicy
Assert ($policy.PageFileMode -eq 'custom' -and $policy.PageFileMinMB -eq 128 -and $policy.PageFileMaxMB -eq 4096) 'Default paging matches the requested 128 MB initial / 4096 MB maximum'
$pagingDefaults=@{};foreach($parameter in @($ast.ParamBlock.Parameters|Where-Object{$_.Name.VariablePath.UserPath -in @('PageFileMinMB','PageFileMaxMB')})){$pagingDefaults[$parameter.Name.VariablePath.UserPath]=$parameter.DefaultValue.Extent.Text}
Assert ($pagingDefaults.PageFileMinMB -eq '128' -and $pagingDefaults.PageFileMaxMB -eq '4096') 'Command-line and wizard defaults use the same 128-4096 MB range'
Assert ($policy.SwapFile -eq 'disabled' -and $policy.Hibernation -eq 'disabled' -and $policy.CrashDumps -eq 'disabled') 'Compact defaults explicitly disable swap, hibernation and dumps'
Assert-Throws {Get-MemoryFilePolicy -PageFileMinMB 1024 -PageFileMaxMB 128} 'An inverted custom range fails'
Assert-Throws {Get-MemoryFilePolicy -PageFileMinMB 0} 'Zero cannot accidentally request system-managed paging'
Assert-Throws {Get-MemoryFilePolicy -SwapFile minimum} 'An unsupported fixed swap size cannot be requested'
$fixed=Get-MemoryFilePolicy -PageFileMaxMB 128
Assert (($fixed.Registry|Where-Object Name -eq 'PagingFiles').Value[0] -eq '?:\pagefile.sys 128 128') 'A fixed 128 MB page file is an explicit supported selection'
$automatic=Get-MemoryFilePolicy -PageFileMode system -SwapFile system -Hibernation system -CrashDumps system
Assert ($automatic.Registry.Count -eq 2 -and ($automatic.Registry|Where-Object Name -eq 'PagingFiles').Value[0] -eq '?:\pagefile.sys 0 0') 'System mode requests Windows-managed paging and leaves source power/dump settings alone'
Assert (($automatic.Registry|Where-Object Name -eq 'SwapfileControl').Delete) 'System-managed swap removes the override instead of inventing a size'
# Execute the real metadata expression, with unrelated build decisions stubbed.
function Get-NativeToolVersion {param($Path)'10.0.26100.1'}
function Test-GroupActive {param($RulePreset,$Group)$true}
$script:StartedAt=[datetime]'2026-09-15T12:00:00';$memoryFilePolicy=$policy
$metadata=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$buildInfo'},$true)
. ([scriptblock]::Create($metadata.Extent.Text))
$savedMetadata=$buildInfo|ConvertFrom-Json
Assert ($savedMetadata.MemoryFiles.Registry.Count -eq 10 -and ($savedMetadata.MemoryFiles.Registry|Where-Object Name -eq 'PagingFiles').Value[0] -eq '?:\pagefile.sys 128 4096') 'The actual build manifest preserves nested registry entries and paging strings'
foreach($name in 'PageFileMode','PageFileMinMB','PageFileMaxMB','SwapFile','Hibernation','CrashDumps'){
    Assert ($name -in @($ast.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})) "Public parameter $name exists"
    foreach($readme in 'README.md','README.ru_RU.md'){
        Assert (([IO.File]::ReadAllText((Join-Path $repo $readme))).Contains('-'+$name)) "$readme documents $name"
    }
}
$script:writes=[Collections.Generic.List[object]]::new();$script:deletes=[Collections.Generic.List[string]]::new()
$script:existing=@{};$script:sets=@('ControlSet001','ControlSet002','Select');$script:powerCalls=0;$script:failWrite=$false;$script:failPower=$false
function Test-Path {param($LiteralPath,$ErrorAction)if($LiteralPath -notmatch '^HKLM:\\(LITE_SYSTEM\\ControlSet\d{3}|SYSTEM\\CurrentControlSet)\\Control\\'){throw "Unexpected key read: $LiteralPath"};$true}
function Get-ChildItem {param($LiteralPath,$ErrorAction)if($LiteralPath -ne 'HKLM:\LITE_SYSTEM'){throw 'Unexpected hive read'};foreach($name in $script:sets){[pscustomobject]@{PSChildName=$name}}}
function New-Item {param($Path,[switch]$Force,$ErrorAction)if($Path -notmatch '^HKLM:\\(LITE_SYSTEM\\ControlSet\d{3}|SYSTEM\\CurrentControlSet)\\Control\\'){throw "Unexpected write: $Path"}}
function New-ItemProperty {param($LiteralPath,$Name,$PropertyType,$Value,[switch]$Force,$ErrorAction)if($script:failWrite){throw 'Registry access denied'};$script:writes.Add([pscustomobject]@{Path=$LiteralPath;Name=$Name;Type=$PropertyType;Value=$Value})}
function Get-ItemProperty {param($LiteralPath,$Name,$ErrorAction)if($script:existing.ContainsKey($Name)){[pscustomobject]@{Present=1}}}
function Remove-ItemProperty {param($LiteralPath,$Name,$ErrorAction)$script:deletes.Add($LiteralPath+'\'+$Name)}
function Disable-GuestHibernation {$script:powerCalls++;if($script:failPower){throw 'powercfg failed'}}
function Write-FinalizeLog {param($Message)}
$script:existing=@{DedicatedDumpFile=1;DumpFileSize=1}
Set-OfflineMemoryFilePolicy -Policy $policy
Assert ($script:writes.Count -eq 16 -and $script:deletes.Count -eq 4) 'Both mounted control sets receive the policy and dedicated dump allocation is removed'
Assert (-not @($script:writes|Where-Object{$_.Path -notlike 'HKLM:\LITE_SYSTEM\*'}).Count -and $script:powerCalls -eq 0) 'Offline policy never targets the host or calls powercfg'
Assert (@($script:writes|Where-Object{$_.Name -eq 'PagingFiles' -and $_.Type -eq 'MultiString' -and $_.Value[0] -eq '?:\pagefile.sys 128 4096'}).Count -eq 2) 'Offline paging uses REG_MULTI_SZ and a target-drive placeholder'
Assert (@($script:writes|Where-Object{$_.Name -in @('CrashDumpEnabled','EnableLogFile','FullLiveReportsMax') -and $_.Value -eq 0}).Count -eq 6) 'Crash dumps, DumpStack logging and full live dumps are disabled in each control set'
$script:sets=@('Select')
Assert-Throws {Set-OfflineMemoryFilePolicy -Policy $policy} 'A missing image control set fails instead of reporting success'
$script:sets=@('ControlSet001');$script:failWrite=$true
Assert-Throws {Set-OfflineMemoryFilePolicy -Policy $policy} 'Registry write failures stop offline configuration'
try{Set-OfflineMemoryFilePolicy -Policy $policy}catch{$failure=$_}
Assert ($failure.Exception.Message -match 'LITE_SYSTEM\\ControlSet001.*PagingFiles' -and $null -ne $failure.Exception.InnerException) 'Offline failure identifies the exact value and preserves the original exception'
$script:failWrite=$false
$oldDrive=$env:SystemDrive
try{
    $env:SystemDrive='W:';$script:writes.Clear();$script:deletes.Clear()
    # Exercise the exact JSON round trip used by build-info.json.
    $script:BuildInfo=$savedMetadata
    Set-GuestMemoryFilePolicy
    Assert (($script:writes|Where-Object Name -eq 'PagingFiles').Value[0] -eq 'W:\pagefile.sys 128 4096') 'Guest paging uses the installed drive, not the builder C drive'
    Assert ($script:powerCalls -eq 1 -and @($script:writes|Where-Object{$_.Path -notlike 'HKLM:\SYSTEM\CurrentControlSet\*'}).Count -eq 0) 'Guest changes the active control set and disables hibernation through powercfg'
    Assert (($script:writes|Where-Object Name -eq 'SwapfileControl').Value -eq 0) 'Disabled swap writes its override independently of paging'
    $script:failWrite=$true
    try{Set-GuestMemoryFilePolicy}catch{$failure=$_}
    Assert ($failure.Exception.Message -match 'SYSTEM\\CurrentControlSet.*PagingFiles' -and $null -ne $failure.Exception.InnerException) 'Guest failure identifies the exact value and preserves the original exception'
    $script:failWrite=$false
    $script:failPower=$true
    Assert-Throws {Set-GuestMemoryFilePolicy} 'A failed powercfg command remains a failure'
    $script:failPower=$false;$script:writes.Clear();$script:existing=@{SwapfileControl=1}
    $script:BuildInfo.MemoryFiles=$automatic
    Set-GuestMemoryFilePolicy
    Assert ($script:writes.Count -eq 1 -and $script:deletes -contains 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\SwapfileControl') 'System selections leave hibernation and dumps untouched and restore automatic swap'
    $script:BuildInfo.MemoryFiles=$null;$script:writes.Clear();$calls=$script:powerCalls
    Set-GuestMemoryFilePolicy
    Assert ($script:writes.Count -eq 0 -and $calls -eq $script:powerCalls) 'A legacy manifest causes no implicit host or guest changes'
}finally{$env:SystemDrive=$oldDrive}
# Report tests use fake file metadata and capture output, without touching any file.
$script:BuildInfo.MemoryFiles=$policy;$script:report=$null
function Join-Path {param($Path,$ChildPath)if($ChildPath -eq 'memory-files-report.json'){'fixture\memory-files-report.json'}else{Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath}}
function Get-Item {param($LiteralPath,[switch]$Force,$ErrorAction)
    if($LiteralPath -like '*pagefile.sys'){return [pscustomobject]@{Length=134217728}}
    if($LiteralPath -like '*swapfile.sys'){throw [UnauthorizedAccessException]::new('denied')}
    throw [Management.Automation.ItemNotFoundException]::new('absent')
}
function Set-Content {[CmdletBinding()]param($LiteralPath,[Parameter(ValueFromPipeline)]$Value,$Encoding)process{$script:report=$Value|ConvertFrom-Json}}
Write-MemoryFileReport
Assert (($script:report.Files|Where-Object Path -like '*pagefile.sys').Bytes -eq 134217728) 'Report records observed file size, not a promised target'
Assert ($null -eq ($script:report.Files|Where-Object Path -like '*swapfile.sys').Exists -and ($script:report.Files|Where-Object Path -like '*swapfile.sys').Error) 'An unreadable file is unknown, not falsely absent'
Assert (-not ($script:report.Files|Where-Object Path -like '*hiberfil.sys').Exists) 'Missing files are reported as absent'
Assert ($script:report.Requested.PageFileMaxMB -eq 4096 -and $script:report.Note -match 'restart') 'Report retains requested limits and states the restart limitation'

& {
    # Production HKLM paths are translated only here; no host system settings are
    # accessible through these wrappers. The actual registry provider/ACLs run.
    $id=[guid]::NewGuid().ToString('N')
    $registryName='Software\Win11LiteMemoryTest_'+$id
    $registryRoot='HKCU:\'+$registryName
    $fixtureKey=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryName)
    try{$fixtureKey.SetValue('TestOwner',$id)}finally{$fixtureKey.Dispose()}
    $restoreAcls=[Collections.Generic.List[object]]::new()
    $oldDrive=$env:SystemDrive;$state=@{Created=0;PowerCalls=0}
    function Convert-TestRegistryPath([string]$Path){
        foreach($mapping in @(@('HKLM:\LITE_SYSTEM','Offline'),@('HKLM:\SYSTEM\CurrentControlSet','Guest'))){
            if($Path -eq $mapping[0] -or $Path.StartsWith($mapping[0]+'\',[StringComparison]::OrdinalIgnoreCase)){
                return $registryRoot+'\'+$mapping[1]+$Path.Substring($mapping[0].Length)
            }
        }
        throw "Registry fixture rejected path: $Path"
    }
    function Get-ChildItem {param($LiteralPath,$ErrorAction)Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath (Convert-TestRegistryPath $LiteralPath) -ErrorAction Stop}
    function Get-Item {[CmdletBinding()]param($LiteralPath,[switch]$Force)Microsoft.PowerShell.Management\Get-Item @PSBoundParameters}
    function Test-Path {param($LiteralPath,$ErrorAction)Microsoft.PowerShell.Management\Test-Path -LiteralPath (Convert-TestRegistryPath $LiteralPath) -ErrorAction Stop}
    function New-Item {param($Path,[switch]$Force,$ErrorAction)$state.Created++;Microsoft.PowerShell.Management\New-Item -Path (Convert-TestRegistryPath $Path) -Force:$Force -ErrorAction Stop}
    function New-ItemProperty {param($LiteralPath,$Name,$PropertyType,$Value,[switch]$Force,$ErrorAction)Microsoft.PowerShell.Management\New-ItemProperty -LiteralPath (Convert-TestRegistryPath $LiteralPath) -Name $Name -PropertyType $PropertyType -Value $Value -Force:$Force -ErrorAction Stop}
    function Get-ItemProperty {param($LiteralPath,$Name,$ErrorAction)Microsoft.PowerShell.Management\Get-ItemProperty -LiteralPath (Convert-TestRegistryPath $LiteralPath) -Name $Name -ErrorAction $ErrorAction}
    function Remove-ItemProperty {param($LiteralPath,$Name,$ErrorAction)Microsoft.PowerShell.Management\Remove-ItemProperty -LiteralPath (Convert-TestRegistryPath $LiteralPath) -Name $Name -ErrorAction Stop}
    function Disable-GuestHibernation {$state.PowerCalls++}
    function Read-FixtureValue([string]$Branch,[string]$Relative,[string]$Name){
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryName+'\'+$Branch+'\'+$Relative)
        if(-not $key){throw 'Missing fixture key'}
        try{$key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}finally{$key.Dispose()}
    }
    function Set-FixtureAcl([string]$Path,$Acl){
        if(-not $Path.StartsWith($registryRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected ACL target'}
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path.Substring(6),[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,[Security.AccessControl.RegistryRights]::ChangePermissions)
        if(-not $key){throw 'Missing ACL fixture key'}
        try{
            # A freshly read ACL has no modified flags; explicitly mark Access
            # when restoring it, otherwise SetAccessControl may be a no-op.
            $copy=[Security.AccessControl.RegistrySecurity]::new()
            $copy.SetSecurityDescriptorSddlForm($Acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access),[Security.AccessControl.AccessControlSections]::Access)
            if($key.PSObject.Methods['SetAccessControl']){$key.SetAccessControl($copy)}
            else{[Microsoft.Win32.RegistryAclExtensions]::SetAccessControl($key,$copy)}
        }finally{$key.Dispose()}
    }
    function Read-FixtureAcl([string]$Path){
        if(-not $Path.StartsWith($registryRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected ACL read target'}
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path.Substring(6))
        if(-not $key){throw 'Missing ACL fixture key'}
        try{
            if($key.PSObject.Methods['GetAccessControl']){$key.GetAccessControl()}
            else{[Microsoft.Win32.RegistryAclExtensions]::GetAccessControl($key)}
        }finally{$key.Dispose()}
    }
    try{
        $branches=@('Offline\ControlSet001','Offline\ControlSet002','Guest')
        $paths=@('Control\Session Manager\Memory Management','Control\Power','Control\Session Manager\Power','Control\CrashControl')
        foreach($branch in $branches){
            foreach($relative in $paths){
                $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryName+'\'+$branch+'\'+$relative)
                try{
                    $key.SetValue('UnrelatedValue','preserve-'+$relative)
                    $child=$key.CreateSubKey('UnrelatedChild')
                    try{$child.SetValue('Sentinel',17,[Microsoft.Win32.RegistryValueKind]::DWord)}finally{$child.Dispose()}
                    if($relative -eq 'Control\CrashControl'){
                        $key.SetValue('DedicatedDumpFile','fixture.dmp');$key.SetValue('DumpFileSize',4096)
                    }
                }finally{$key.Dispose()}
            }
            # Deny deletion while allowing value writes, as with protected keys.
            $protected=$registryRoot+'\'+$branch+'\Control\Session Manager\Memory Management'
            $before=Read-FixtureAcl $protected
            $deny=Read-FixtureAcl $protected
            $rule=[Security.AccessControl.RegistryAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.AccessControl.RegistryRights]::Delete,[Security.AccessControl.AccessControlType]::Deny)
            $deny.AddAccessRule($rule)
            $restoreAcls.Add([pscustomobject]@{Path=$protected;Acl=$before})
            Set-FixtureAcl $protected $deny
        }
        # Demonstrate the old failure on a separate disposable key, not policy data.
        $witness=$registryRoot+'\RecreateDenied'
        $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryName+'\RecreateDenied');$key.Dispose()
        $before=Read-FixtureAcl $witness
        $deny=Read-FixtureAcl $witness;$deny.AddAccessRule($rule)
        $restoreAcls.Add([pscustomobject]@{Path=$witness;Acl=$before})
        Set-FixtureAcl $witness $deny
        Assert-Throws {Microsoft.PowerShell.Management\New-Item -Path $witness -Force -ErrorAction Stop} 'The real registry provider reproduces the denied forced key recreation'

        Set-OfflineMemoryFilePolicy -Policy $policy
        $env:SystemDrive='W:';$script:BuildInfo.MemoryFiles=$policy
        Set-GuestMemoryFilePolicy
        Assert ($state.Created -eq 3 -and $state.PowerCalls -eq 1) 'Only three missing FullLiveKernelReports keys are created; powercfg remains mocked'
        foreach($branch in $branches){
            $expectedPage=if($branch -eq 'Guest'){'W:\pagefile.sys 128 4096'}else{'?:\pagefile.sys 128 4096'}
            Assert ((Read-FixtureValue $branch $paths[0] 'PagingFiles') -eq $expectedPage -and (Read-FixtureValue $branch $paths[0] 'SwapfileControl') -eq 0) "PagingFiles survives the subsequent swap write in $branch"
            Assert ((Read-FixtureValue $branch $paths[1] 'HibernateEnabled') -eq 0 -and (Read-FixtureValue $branch $paths[1] 'HibernateEnabledDefault') -eq 0) "Both power values survive in $branch"
            Assert ((Read-FixtureValue $branch $paths[3] 'CrashDumpEnabled') -eq 0 -and (Read-FixtureValue $branch $paths[3] 'EnableLogFile') -eq 0 -and $null -eq (Read-FixtureValue $branch $paths[3] 'DedicatedDumpFile')) "Dump writes and targeted deletion preserve each other in $branch"
            foreach($relative in $paths){
                Assert ((Read-FixtureValue $branch $relative 'UnrelatedValue') -eq ('preserve-'+$relative) -and (Read-FixtureValue $branch ($relative+'\UnrelatedChild') 'Sentinel') -eq 17) "Unrelated values and child keys survive in $branch\$relative"
            }
        }
        Set-OfflineMemoryFilePolicy -Policy $policy;Set-GuestMemoryFilePolicy
        Assert ($state.Created -eq 3) 'A repeated application creates or recreates no registry keys'
        Set-OfflineMemoryFilePolicy -Policy $automatic;$script:BuildInfo.MemoryFiles=$automatic;Set-GuestMemoryFilePolicy
        foreach($branch in $branches){
            Assert ($null -eq (Read-FixtureValue $branch $paths[0] 'SwapfileControl') -and (Read-FixtureValue $branch $paths[0] 'UnrelatedValue') -eq ('preserve-'+$paths[0])) "System swap removes only its own value in $branch"
        }
    }catch{
        [Console]::Error.WriteLine($_.ToString()+[Environment]::NewLine+$_.ScriptStackTrace)
        throw
    }finally{
        $env:SystemDrive=$oldDrive
        foreach($entry in $restoreAcls){
            if(Microsoft.PowerShell.Management\Test-Path -LiteralPath $entry.Path){Set-FixtureAcl $entry.Path $entry.Acl}
        }
        # Delete only this run's named registry fixture after restoring its ACLs.
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryName)
        try{$owner=$key.GetValue('TestOwner')}finally{$key.Dispose()}
        if($registryName -ne ('Software\Win11LiteMemoryTest_'+$id) -or $owner -ne $id){throw 'Unexpected registry cleanup target'}
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryName)
    }
}
Write-Host "PASS: $script:checks memory file checks; PowerShell $($PSVersionTable.PSVersion)"
