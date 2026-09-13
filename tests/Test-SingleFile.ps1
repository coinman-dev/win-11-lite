#Requires -Version 5.1
# The standalone copy is parsed; only resource/writer functions are executed.
# No guard, Windows servicing, network calls, or task changes run on the host.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
& (Join-Path $repo 'tools\Update-BundledResources.ps1') -Check | Out-Null
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
    Assert (-not $e.Count) 'The isolated script parses with all embedded scripts and JSON literals'
    foreach($name in 'T','Get-BundledResource','Get-BundledResourceHash','Get-GuardScript','Get-SetupRunnerScript'){
        $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
        if(-not $node){throw "Missing standalone function: $name"}
        . ([scriptblock]::Create($node.Extent.Text))
    }
    $script:ScriptRoot=$standalone;$script:Lang='en';$Guard=$true
    $resourceNames=@('deployment-tools-28000.json','winpe-26100.json','guard.ps1','Guard.UI.ps1','Run-Setup.ps1')
    foreach($name in $resourceNames){
        $actual=Get-BundledResource $name
        $expected=[IO.File]::ReadAllText((Join-Path $repo ('data\'+$name))) -replace '\r?\n',"`r`n"
        Assert ($actual -ceq $expected) "The isolated resource matches its maintained source: $name"
        if($name.EndsWith('.ps1')){
            $null=[Management.Automation.Language.Parser]::ParseInput($actual,[ref]$t,[ref]$e)
            Assert (-not $e.Count -and $actual -match '#Requires -Version 5.1') "Embedded runtime script remains valid: $name"
        }else{
            $catalog=$actual|ConvertFrom-Json
            Assert ($catalog.Architecture -eq 'amd64' -and $catalog.Build -in @(26100,28000)) "Embedded catalog remains valid: $name"
        }
    }
    Assert ((Get-BundledResourceHash 'deployment-tools-28000.json') -eq 'FE04FF652C269BDBAF414814BDE94F61330FE047A42AEC80B778F3D27B9D68FB') 'Existing verified DISM cache keeps its catalog identity'
    Assert-Throws {Get-BundledResource '..\outside.ps1'} 'Unknown resources do not read arbitrary local files'
    $guardDir=Join-Path $testRoot 'image\Windows\Setup\Scripts\Win11Lite';$supportDir=$guardDir
    $null=New-Item -ItemType Directory -Path $guardDir
    $guardScript=Get-GuardScript;$setupRunner=Get-SetupRunnerScript
    # Execute the actual three image-writing expressions against our fixture.
    $writers=@($ast.FindAll({param($n)
        $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Extent.Text -match '^\[IO.File\]::WriteAllText\(\(Join-Path \$(guardDir|supportDir) ''(Guard.UI|guard|Run-Setup)\.ps1''\)'
    },$true))
    Assert ($writers.Count -eq 3) 'All runtime image writers are covered by the standalone test'
    foreach($writer in $writers){& ([scriptblock]::Create($writer.Extent.Text))}
    foreach($name in 'guard.ps1','Guard.UI.ps1','Run-Setup.ps1'){
        $file=Join-Path $guardDir $name;$bytes=[IO.File]::ReadAllBytes($file)
        Assert (($bytes[0..2] -join ',') -eq '239,187,191' -and [IO.File]::ReadAllText($file) -ceq (Get-BundledResource $name)) "Image helper has the correct text and PS 5.1 UTF-8 BOM: $name"
    }
    Assert (@(Get-ChildItem -LiteralPath $standalone -Force).Count -eq 1) 'Materializing image helpers does not require or create data beside the downloaded script'
    # A neighboring, stale data folder must not change the standalone behavior.
    $neighbor=Join-Path $standalone 'data';$null=New-Item -ItemType Directory -Path $neighbor
    Set-Content -LiteralPath (Join-Path $neighbor 'guard.ps1') -Value 'throw "stale external guard must never run"'
    Set-Content -LiteralPath (Join-Path $neighbor 'deployment-tools-28000.json') -Value 'invalid stale catalog'
    Assert ((Get-GuardScript) -ceq $guardScript -and (Get-BundledResourceHash 'deployment-tools-28000.json') -eq 'FE04FF652C269BDBAF414814BDE94F61330FE047A42AEC80B778F3D27B9D68FB') 'Stale neighboring files cannot override the bundled runtime or catalog'

    $checkRoot=Join-Path $testRoot 'developer-copy';$checkTools=Join-Path $checkRoot 'tools';$checkData=Join-Path $checkRoot 'data'
    $null=New-Item -ItemType Directory -Path $checkTools,$checkData
    Copy-Item -LiteralPath $main -Destination (Join-Path $checkRoot 'win-11-lite.ps1')
    $generator=Join-Path $checkTools 'Update-BundledResources.ps1'
    Copy-Item -LiteralPath (Join-Path $repo 'tools\Update-BundledResources.ps1') -Destination $generator
    foreach($name in $resourceNames){Copy-Item -LiteralPath (Join-Path $repo ('data\'+$name)) -Destination (Join-Path $checkData $name)}
    & $generator -Check | Out-Null
    $changed=Join-Path $checkData 'guard.ps1'
    Add-Content -LiteralPath $changed -Value '# fixture drift' -Encoding UTF8
    Assert-Throws {& $generator -Check} 'A changed source fails the publication check instead of leaving an outdated single-file build unnoticed'
    & $generator | Out-Null
    & $generator -Check | Out-Null
    Assert $true 'Regenerating the copied file resolves source drift'
    Write-Host "PASS: $script:checks single-file checks; PowerShell $($PSVersionTable.PSVersion)"
}finally{
    $full=[IO.Path]::GetFullPath($testRoot);$prefix=[IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')+'\single-file-'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected standalone test directory'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
