#Requires -Version 5.1
# An isolated copy of win-11-lite.ps1 is parsed; only the guest-script accessor,
# the pinned ADK table and the real image writer are executed. No guard, Windows
# servicing, network call or scheduled-task change runs on the host.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$script:checks=0
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw "FAIL: $Message"};$script:checks++}
function Assert-Throws([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed $Message}
$testRoot=Join-Path $repo ('tmp\single-file-'+[guid]::NewGuid().ToString('N'))
$standalone=Join-Path $testRoot 'portable';$null=New-Item -ItemType Directory -Path $standalone
$main=Join-Path $standalone 'win-11-lite.ps1'
Copy-Item -LiteralPath (Join-Path $repo 'win-11-lite.ps1') -Destination $main
# GitHub raw downloads keep the LF representation stored in Git.
[IO.File]::WriteAllText($main,[IO.File]::ReadAllText($main).Replace("`r`n","`n"),[Text.UTF8Encoding]::new($true))
try{
    Assert (@(Get-ChildItem -LiteralPath $standalone -Force).Count -eq 1) 'The standalone directory initially contains only win-11-lite.ps1'
    Assert (-not [IO.File]::ReadAllText($main).Contains("`r")) 'The standalone test uses GitHub-style LF source text'
    $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($main,[ref]$t,[ref]$e)
    Assert (-not $e.Count) 'The isolated script parses with the embedded guest script'
    foreach($name in 'T','Get-AdkSourceHash','Get-GuestScript'){
        $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
        if(-not $node){throw "Missing standalone function: $name"}
        . ([scriptblock]::Create($node.Extent.Text))
    }
    $script:ScriptRoot=$standalone;$script:Lang='en';$Guard='Standard'

    # The guest runtime is one embedded file, readable and edited in place.
    $guestScript=Get-GuestScript
    Assert ($guestScript.StartsWith('#Requires -Version 5.1')) 'The embedded guest script declares its PowerShell requirement first'
    Assert (-not ($guestScript -split "`n" | Where-Object { $_ -match '\r' -and $_ -notmatch '\r$' }).Count -and $guestScript.EndsWith("`r`n")) 'The guest script uses Windows newlines and ends with one'
    $gt=$null;$ge=$null;$guestAst=[Management.Automation.Language.Parser]::ParseInput($guestScript,[ref]$gt,[ref]$ge)
    Assert (-not $ge.Count) 'The embedded guest script is valid PowerShell on its own'
    Assert (-not ($guestScript -match '__[A-Z]+__')) 'No build-time placeholder is left in the guest script'
    foreach($retired in 'Run-Setup\.ps1','Guard\.UI\.ps1','Prepare\.ps1','Finalize\.ps1','guard\.ps1','Win11Lite\.Run\.exe'){
        Assert (-not ($guestScript -match $retired)) "The guest script no longer expects a companion file: $retired"
    }
    $functions=@($guestAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|ForEach-Object{$_.Name})
    foreach($required in 'Invoke-Prepare','Invoke-Finalize','Start-GuestChild','Show-GuardView','Register-GuardViewerTask','Save-GuardReport','Get-BuildSetting','Get-GuestGuardMode'){
        Assert ($required -in $functions) "The single guest file provides $required"
    }
    Assert (@($functions|Sort-Object -Unique).Count -eq $functions.Count) 'No guest function is defined twice after the merge'
    foreach($mode in 'prepare','prepare-register','finalize','finalize-wait','guard','view'){
        Assert ($guestScript -match ("(?m)^\s*if \(\`$Mode -eq '$mode'|'$mode',|,'$mode'")) "The guest script handles the $mode entry point"
    }
    # Build choices travel in build-info.json, not in generated source text.
    foreach($setting in 'OobeNetworkBlock','ManageOobe','RemoveEdge','Guard'){
        Assert ($guestScript -match ("(Get-GuestFlag|Get-BuildSetting) '$setting'")) "The guest script reads $setting from build-info.json"
    }

    # The package layout is read from Microsoft's installers, so nothing is bundled.
    $adkNode=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:AdkSources'},$true)
    if(-not $adkNode){throw 'Missing pinned ADK source table'}
    . ([scriptblock]::Create($adkNode.Extent.Text))
    $toolsIdentity=Get-AdkSourceHash -Build 28000
    Assert ($toolsIdentity -match '^[A-F0-9]{64}$' -and (Get-AdkSourceHash -Build 26100) -match '^[A-F0-9]{64}$') 'The isolated script derives both ADK cache identities offline'
    Assert ($adkNode.Extent.Text.Length -lt 8000) 'The pinned ADK table stays a short list instead of a bundled catalog'
    Assert (-not ($ast.Extent.Text -match 'Get-BundledResource')) 'No bundled-resource accessor remains'
    Assert (-not ($ast.Extent.Text -match "Join-Path \`$script:ScriptRoot 'data'")) 'The builder never reads a neighbouring data folder'

    # Run the real image writer against a fixture support directory.
    $supportDir=Join-Path $testRoot 'image\Windows\Setup\Scripts\Win11Lite'
    $null=New-Item -ItemType Directory -Path $supportDir
    $writers=@($ast.FindAll({param($n)
        $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Extent.Text -match "^\[IO.File\]::WriteAllText\(\(Join-Path \`$supportDir 'Win11Lite\.ps1'\)"
    },$true))
    Assert ($writers.Count -eq 1) 'Exactly one expression writes the guest runtime into the image'
    & ([scriptblock]::Create($writers[0].Extent.Text))
    $written=Join-Path $supportDir 'Win11Lite.ps1';$bytes=[IO.File]::ReadAllBytes($written)
    Assert (($bytes[0..2] -join ',') -eq '239,187,191') 'The guest file is written with the UTF-8 BOM that Windows PowerShell 5.1 needs'
    Assert ([IO.File]::ReadAllText($written) -ceq $guestScript) 'The written guest file matches the embedded copy exactly'
    Assert (@(Get-ChildItem -LiteralPath $supportDir -File).Count -eq 1) 'The image needs no companion runtime files'
    Assert (@(Get-ChildItem -LiteralPath $standalone -Force).Count -eq 1) 'Writing the guest runtime creates nothing beside the downloaded script'

    # A stale neighbouring data folder must not change anything.
    $neighbor=Join-Path $standalone 'data';$null=New-Item -ItemType Directory -Path $neighbor
    Set-Content -LiteralPath (Join-Path $neighbor 'guard.ps1') -Value 'throw "stale external guard must never run"'
    Set-Content -LiteralPath (Join-Path $neighbor 'deployment-tools-28000.json') -Value 'invalid stale catalog'
    Assert ((Get-GuestScript) -ceq $guestScript -and (Get-AdkSourceHash -Build 28000) -eq $toolsIdentity) 'Stale neighbouring files cannot override the embedded guest script or the pinned ADK sources'
    Write-Host "PASS: $script:checks single-file checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $full=[IO.Path]::GetFullPath($testRoot);$prefix=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\single-file-'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected standalone test directory'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
