#Requires -Version 5.1
# Developer tool. The generated win-11-lite.ps1 does not need this script or data/.
[CmdletBinding()]
param([switch]$Check)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$mainPath=Join-Path $repo 'win-11-lite.ps1'
$source=[IO.File]::ReadAllText($mainPath) -replace '\r?\n',"`r`n"
$begin='#region Bundled resources'
$end='#endregion Bundled resources'
$start=$source.IndexOf($begin,[StringComparison]::Ordinal)
$finish=$source.IndexOf($end,[StringComparison]::Ordinal)
if($start -lt 0 -or $finish -lt $start -or $source.IndexOf($begin,$start+$begin.Length,[StringComparison]::Ordinal) -ge 0){throw 'Missing or duplicate bundled-resource markers'}
$finish+=$end.Length
$names=@('guard.ps1','Guard.UI.ps1','Run-Setup.ps1')
$lines=[Collections.Generic.List[string]]::new()
$lines.Add($begin)
$lines.Add('# Generated from data/ by tools/Update-BundledResources.ps1. No external files are read at runtime.')
$lines.Add('function Get-BundledResource {')
$lines.Add('    param([Parameter(Mandatory)][string]$Name)')
$lines.Add('    $text = switch ($Name) {')
foreach($name in $names){
    $text=[IO.File]::ReadAllText((Join-Path $repo ('data\'+$name))) -replace '\r?\n',"`r`n"
    if($name.EndsWith('.json')){$null=$text|ConvertFrom-Json}
    else{
        $tokens=$null;$errors=$null
        $null=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
        if($errors.Count){throw "Invalid PowerShell resource: $name"}
    }
    $lines.Add("        '$name' {")
    $lines.Add("'"+$text.Replace("'","''")+"'")
    $lines.Add('        }')
}
$lines.Add('        default { throw (T "Нет встроенного ресурса: $Name" "Bundled resource not found: $Name") }')
$lines.Add('    }')
# Canonical Windows newlines keep catalog/cache identity stable after a Git LF checkout.
$lines.Add('    $text -replace ''\r?\n'', "`r`n"')
$lines.Add('}')
$lines.Add($end)
$block=$lines -join "`r`n"
$updated=$source.Substring(0,$start)+$block+$source.Substring($finish)
if($Check){
    if($updated -cne $source){throw 'Bundled resources are stale. Run tools/Update-BundledResources.ps1 before testing or publishing.'}
    Write-Output "PASS: $($names.Count) bundled resources match data/"
    return
}
$tokens=$null;$errors=$null
$null=[Management.Automation.Language.Parser]::ParseInput($updated,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
if($updated -cne $source){[IO.File]::WriteAllText($mainPath,$updated,[Text.UTF8Encoding]::new($true))}
Write-Output "Bundled $($names.Count) resources into win-11-lite.ps1"
