#Requires -Version 5.1
# Exercise the generated CMD with real cmd.exe; downloads/installers are stubs.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Write-WindowsBatchFile','Write-FirefoxInstallerFile','Get-FirefoxInstallerCommand')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $false)
    . ([scriptblock]::Create($node.Extent.Text))
}
$checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
$root = Join-Path $repo ('tmp\batch-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
try {
    $stubs = Join-Path $root 'stubs'
    $null = New-Item -ItemType Directory -Path $stubs
    Write-WindowsBatchFile -Path (Join-Path $stubs 'where.cmd') -Content "@echo off`nexit /b %TEST_WHERE_EXIT%"
    Write-WindowsBatchFile -Path (Join-Path $stubs 'winget.cmd') -Content "@echo off`n>>`"%TEST_TRACE%`" echo WINGET %*`nexit /b %TEST_WINGET_EXIT%"
    Write-WindowsBatchFile -Path (Join-Path $stubs 'curl.cmd') -Content "@echo off`n>>`"%TEST_TRACE%`" echo DOWNLOAD %*`n>`"%FFSETUP%`" echo dummy installer - never executed`nexit /b %TEST_CURL_EXIT%"
    Write-WindowsBatchFile -Path (Join-Path $stubs 'installer.cmd') -Content "@echo off`n>>`"%TEST_TRACE%`" echo INSTALL`nexit /b %TEST_INSTALLER_EXIT%"
    Write-WindowsBatchFile -Path (Join-Path $stubs 'timeout.cmd') -Content "@echo off`nexit /b 1"
    $scenarios = @(
        @{Name='winget-success';Where=0;Winget=0;Curl=0;Installer=0;Exit=0;Download=$false;Install=$false}
        @{Name='direct-download';Where=1;Winget=0;Curl=0;Installer=0;Exit=0;Download=$true;Install=$true}
        @{Name='winget-fallback';Where=0;Winget=7;Curl=0;Installer=0;Exit=0;Download=$true;Install=$true}
        @{Name='winget-hresult-fallback';Where=0;Winget=-1978335217;Curl=0;Installer=0;Exit=0;Download=$true;Install=$true}
        @{Name='winget-hresult-offline';Where=0;Winget=-1978335217;Curl=22;Installer=0;Exit=1;Download=$true;Install=$false}
        @{Name='download-error';Where=1;Winget=0;Curl=22;Installer=0;Exit=1;Download=$true;Install=$false}
        @{Name='installer-cancel';Where=1;Winget=0;Curl=0;Installer=1602;Exit=1602;Download=$true;Install=$true}
    )
    foreach ($language in @('ru-RU','en-US')) {
        $tag = if ($language -eq 'ru-RU') {'ru'} else {'en-US'}
        $command = Get-FirefoxInstallerCommand -Language $language -MozillaLanguage $tag
        # Normalize mixed source line endings, including an LF-only PS1 checkout.
        $original = Join-Path $root "$tag-original.cmd"
        Write-WindowsBatchFile -Path $original -Content ($command -replace "`r`n", "`n")
        $bytes = [IO.File]::ReadAllBytes($original)
        $raw = [Text.Encoding]::UTF8.GetString($bytes)
        Assert (-not $raw.StartsWith([string][char]0xFEFF, [StringComparison]::Ordinal) -and $raw -notmatch '(?<!\r)\n' -and $raw.EndsWith("`r`n")) "CMD encoding and CRLF ($tag)"
        $command = $command.Replace('where winget', 'call "%BATCH_STUBS%\where.cmd" winget')
        $command = $command.Replace('winget install ', 'call "%BATCH_STUBS%\winget.cmd" install ')
        $command = $command.Replace('curl.exe ', 'call "%BATCH_STUBS%\curl.cmd" ')
        $command = $command.Replace('start "" /wait "%FFSETUP%"', 'call "%BATCH_STUBS%\installer.cmd"')
        $command = $command.Replace('timeout /t 3 >nul 2>&1', 'call "%BATCH_STUBS%\timeout.cmd" >nul 2>&1')
        $command = $command.Replace('pause', 'rem pause skipped in test')
        Assert ($command -notmatch '(?im)^\s*(?:curl\.exe|winget install|start |where winget)') 'All external side effects replaced before execution'
        foreach ($case in $scenarios) {
            $caseDir = Join-Path $root ("$tag-$($case.Name) папка с пробелами & !")
            $null = New-Item -ItemType Directory -Path $caseDir
            $file = Join-Path $caseDir 'Install-Firefox.cmd'
            $trace = Join-Path $caseDir 'trace.txt'
            Write-FirefoxInstallerFile -Path $file -Content $command
            $rules = (Get-Acl -LiteralPath $file).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
            Assert (@($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' -and $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Delete) }).Count -gt 0) 'Standard users can remove the single-use launcher'
            $browserLink = Join-Path $caseDir 'Firefox.lnk'
            [IO.File]::WriteAllText($browserLink, 'browser shortcut fixture')
            $psi = [Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = "$env:SystemRoot\System32\cmd.exe"
            $psi.Arguments = '/d /s /c ""' + $file + '""'
            $psi.WorkingDirectory = $caseDir
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
            $psi.EnvironmentVariables['BATCH_STUBS'] = $stubs
            $psi.EnvironmentVariables['TEST_TRACE'] = $trace
            $psi.EnvironmentVariables['TEMP'] = $caseDir
            foreach ($name in @('Where','Winget','Curl','Installer')) { $psi.EnvironmentVariables['TEST_' + $name.ToUpperInvariant() + '_EXIT'] = [string]$case[$name] }
            $process = [Diagnostics.Process]::Start($psi)
            try {
                $process.StandardInput.Close()
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Mock batch did not finish' }
                $output = $stdout.GetAwaiter().GetResult()
                $errorText = $stderr.GetAwaiter().GetResult()
                $events = [IO.File]::ReadAllText($trace, [Text.Encoding]::UTF8)
                $label = "$tag/$($case.Name)"
                if ($case.Where -eq 0) {
                    Assert ($events -match 'WINGET install --id Mozilla\.Firefox -e --source winget --accept-package-agreements --accept-source-agreements') "Firefox selects the winget source without querying msstore ($label)"
                }
                Assert ($process.ExitCode -eq $case.Exit) "Exit code ($label): $($process.ExitCode); stdout=$output; stderr=$errorText"
                Assert ($errorText.Trim().Length -eq 0) "CMD parsing ($label): $errorText"
                Assert (($events -match 'DOWNLOAD') -eq $case.Download) "Download branch ($label)"
                Assert (($events -match '(?m)^INSTALL\r?$') -eq $case.Install) "Installer branch ($label)"
                Assert (@(Get-ChildItem -LiteralPath $caseDir -Filter 'Win11Lite-Firefox-*.exe').Count -eq 0) "Temporary installer cleanup ($label)"
                if ($case.Download) {
                    Assert ($events.Contains("https://download.mozilla.org/?product=firefox-latest&os=win64&lang=$tag")) "Mozilla URL remains a single argument ($label)"
                }
                $done = if ($tag -eq 'ru') {'Готово.'} else {'Done.'}
                Assert (($output.Contains($done)) -eq ($case.Exit -eq 0)) "Success message reflects installer result ($label)"
                Assert ((Test-Path -LiteralPath $file) -eq ($case.Exit -ne 0)) "Launcher deletes itself only after success ($label)"
                Assert (Test-Path -LiteralPath $browserLink) "Firefox shortcut remains ($label)"
            } finally { $process.Dispose() }
        }
    }
    Write-Host "PASS: $checks CMD checks; PowerShell $($PSVersionTable.PSVersion)"
} finally {
    $allowed = [IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\') + '\batch-tests-'
    $resolved = [IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
