#Requires -Version 5.1
# No elevation, real network calls, image servicing or host configuration changes.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'win-11-lite.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$script:checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Assert $thrown $Message
}
foreach ($name in @('T','Assert-ChildPath','Test-SavedUrl','Save-Url','Read-PreparedCache','Write-PreparedCache',
    'Confirm-SkipDownload','Remove-ForeignUpdateFiles','Save-CatalogPayload','Save-WingetPayload',
    'Save-LanguageFromCatalog','Get-LanguagePattern','Find-LanguagePackage','Get-LanguageRepairUpdate',
    'Get-UpdateTarget','Get-LocalUpdatePayload','Search-Catalog','Get-CatalogLinks','Read-YesNo')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $false)
    if (-not $node) { throw "Missing function: $name" }
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:Lang = 'en'; $script:DownloadsClosed = $false; $script:SkippedDownloads = @()
$notes = [Collections.Generic.List[string]]::new()
function Write-Ok { param($Message) $notes.Add($Message) }
function Write-Note { param($Message) $notes.Add($Message) }
function Write-Step { param($Message) }
function Write-Stage { param($Message) }
function Format-Size { param($Size) "$Size bytes" }
# A forgotten mock can never reach the internet or service an image.
function Invoke-WebRequest { throw 'NETWORK DISABLED BY TEST' }
function Invoke-RestMethod { throw 'NETWORK DISABLED BY TEST' }
function Invoke-Dism { throw 'IMAGE SERVICING DISABLED BY TEST' }
function Get-DiskImage { throw 'DISK API DISABLED BY TEST' }
function Mount-DiskImage { throw 'DISK API DISABLED BY TEST' }
function curl.exe { throw 'NETWORK DISABLED BY TEST' }
function Get-GuestScript { '# fixture guest script' }
function Initialize-DeploymentTools { param($Build,$Directory,$ExplicitDism,[switch]$Install) }

$testRoot = Join-Path $repo ('tmp\downloads-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
try {
    & {
        $dest = Join-Path $testRoot 'payload.msu'
        $state = @{ Fail = $true; Calls = 0 }
        function curl.exe {
            $state.Calls++
            $outputPath = $args[[array]::IndexOf($args, '-o') + 1]
            [IO.File]::WriteAllText($outputPath, 'payload')
            $global:LASTEXITCODE = if ($state.Fail) { 6 } else { 0 }
        }
        Assert-Throws { Save-Url -Url 'https://fixture/payload.msu' -Destination $dest } 'Interrupted download fails'
        Assert (-not (Test-Path $dest) -and -not (Test-Path "$dest.part") -and -not (Test-Path "$dest.size")) 'Interrupted bytes never become a cached file'
        $state.Fail = $false
        Save-Url -Url 'https://fixture/payload.msu' -Destination $dest
        Assert (Test-SavedUrl $dest) 'Successful payload is reusable'
        Save-Url -Url 'https://fixture/payload.msu' -Destination $dest
        Assert ($state.Calls -eq 2) 'Valid size marker avoids another download'
        Set-Content -LiteralPath "$dest.size" -Value 'invalid'
        Assert (-not (Test-SavedUrl $dest)) 'Malformed size marker is not a fatal parser error'
        $state.Fail = $true
        Assert-Throws { Save-Url -Url 'https://fixture/payload.msu' -Destination $dest } 'Failed refresh reports failure'
        Assert ((Get-Content $dest -Raw) -eq 'payload') 'Failed refresh preserves previous complete file'
        $state.Fail = $false
        Save-Url -Url 'https://fixture/payload.msu' -Destination $dest
        Write-PreparedCache -Directory $testRoot -Key 'test' -Files @($dest) -Data @{ Target = 'payload.msu' }
        Assert ([bool](Read-PreparedCache -Directory $testRoot -Key 'test')) 'Complete manifest validates offline'
        [IO.File]::WriteAllText($dest, 'changed')
        Assert (-not (Read-PreparedCache -Directory $testRoot -Key 'test')) 'Same-length corruption is rejected by SHA256'
        Assert (-not (Test-SavedUrl $dest)) 'Corrupt payload cannot be resealed through a matching size marker'
        $calls = $state.Calls
        Save-Url -Url 'https://fixture/payload.msu' -Destination $dest
        Assert ($state.Calls -eq $calls + 1 -and (Get-Content $dest -Raw) -eq 'payload') 'Corruption forces an actual replacement download'
    }

    & {
        $dir = Join-Path $testRoot 'updates'
        $catalog = @{ Fail = $false; MissingCheckpoint = $false; Calls = 0; Kb = 'KB1234567' }
        function Search-Catalog {
            param($Query)
            $catalog.Calls++
            if ($catalog.Fail) { throw 'DNS: catalog unavailable' }
            [pscustomobject]@{ Id = 'fixture'; Title = "Cumulative Update for Windows 11 (24H2) for x64-based Systems ($($catalog.Kb))"; Date = [datetime]'2026-09-12' }
        }
        function Get-CatalogLinks { param($UpdateId) @("https://fixture/windows11-$($catalog.Kb)_x64.msu", 'https://fixture/checkpoint.msu') }
        function Save-Url {
            param($Url,$Destination)
            if ($catalog.MissingCheckpoint -and $Destination -match 'checkpoint') { throw 'Checkpoint download interrupted' }
            [IO.File]::WriteAllText($Destination, "complete $Url")
        }
        $target = Save-CatalogPayload -Query 'fixture' -Directory $dir
        Assert ((Split-Path $target -Leaf) -eq 'windows11-KB1234567_x64.msu') 'KB selects target, not checkpoint'
        $manifest = Read-PreparedCache -Directory $dir -Key 'update'
        Assert ($manifest.Files.Count -eq 2) 'Ready manifest includes all checkpoints'
        Assert ((Get-LocalUpdatePayload -Directory $dir).FullName -eq $target) 'Local mode uses the selected cached target without network'
        $catalog.Fail = $true
        [IO.File]::WriteAllText((Join-Path $dir 'foreign.msu'), 'stale')
        $offlineTarget = Save-CatalogPayload -Query 'fixture' -Directory $dir
        Assert ($offlineTarget -eq $target) 'No internet reuses the complete previous update set'
        Assert (-not (Test-Path (Join-Path $dir 'foreign.msu'))) 'Unselected MSU cannot contaminate the DISM source'
        Remove-Item -LiteralPath (Join-Path $dir 'checkpoint.msu') -Force
        Assert-Throws { Save-CatalogPayload -Query 'fixture' -Directory $dir } 'Missing checkpoint prevents cache fallback'
        Assert-Throws { Get-LocalUpdatePayload -Directory $dir } 'Local mode also rejects a missing checkpoint from a prepared set'
        $catalog.Fail = $false; $catalog.MissingCheckpoint = $true
        $newDir = Join-Path $testRoot 'incomplete-updates'
        Assert-Throws { Save-CatalogPayload -Query 'fixture' -Directory $newDir } 'Interrupted multi-file update is not success'
        Assert (-not (Read-PreparedCache -Directory $newDir -Key 'update')) 'No ready manifest is written for a partial set'
        $catalog.MissingCheckpoint = $false; $catalog.Kb = 'KB5043080'
        $repair = Get-LanguageRepairUpdate -Revision '26100.1742' -Destination $testRoot
        $calls = $catalog.Calls; $catalog.Fail = $true
        Assert ((Get-LanguageRepairUpdate -Revision '26100.1742' -Destination $testRoot) -eq $repair -and $catalog.Calls -eq $calls) 'Cached language repair LCU requires no catalog request'
        Assert-Throws { Get-LanguageRepairUpdate -Revision '26100.9999' -Destination $testRoot } 'Unknown language repair revision never guesses an LCU'
    }
    & {
        $dir = Join-Path $testRoot 'manual-updates'
        $null = New-Item -ItemType Directory -Path $dir
        $path = Join-Path $dir 'manual.msu'
        [IO.File]::WriteAllText($path, 'manual fixture')
        Assert ((Get-LocalUpdatePayload -Directory $dir -FileName 'manual.msu').FullName -eq $path) 'Manually supplied local MSU remains supported without a generated manifest'
        Set-Content -LiteralPath "$path.size" -Value 1000
        Assert-Throws { Get-LocalUpdatePayload -Directory $dir } 'Partial legacy download is rejected in local mode'
        Remove-Item -LiteralPath "$path.size" -Force
        [IO.File]::WriteAllText($path, '')
        Assert-Throws { Get-LocalUpdatePayload -Directory $dir } 'Empty manually supplied MSU is rejected before image processing'
    }

    & {
        $dir = Join-Path $testRoot 'winget'
        $zipRoot = Join-Path $testRoot 'deps-source'
        $null = New-Item -ItemType Directory -Path (Join-Path $zipRoot 'x64'), (Join-Path $zipRoot 'x86')
        [IO.File]::WriteAllText((Join-Path $zipRoot 'x64\dependency.appx'), 'x64 fixture')
        [IO.File]::WriteAllText((Join-Path $zipRoot 'x86\dependency.appx'), 'x86 fixture')
        $zip = Join-Path $testRoot 'dependencies.zip'
        Compress-Archive -Path (Join-Path $zipRoot '*') -DestinationPath $zip
        $network = @{ Offline = $false; Requests = 0; Downloads = 0 }
        function Invoke-RestMethod {
            param($Uri,$Headers,$TimeoutSec)
            $network.Requests++
            if ($network.Offline) { throw 'DNS: api.github.com unavailable' }
            [pscustomobject]@{ tag_name = 'v-test'; assets = @(
                [pscustomobject]@{name='AppInstaller.msixbundle';browser_download_url='https://fixture/bundle'},
                [pscustomobject]@{name='AppInstaller_License1.xml';browser_download_url='https://fixture/license'},
                [pscustomobject]@{name='DesktopAppInstaller_Dependencies.zip';browser_download_url='https://fixture/deps'}
            ) }
        }
        function Save-Url {
            param($Url,$Destination)
            $network.Downloads++
            if ($network.Offline) { throw 'Unexpected offline download' }
            if ($Url -match '/deps$') { Copy-Item -LiteralPath $zip -Destination $Destination }
            elseif ($Url -match '/license$') { [IO.File]::WriteAllText($Destination, '<License/>') }
            else { [IO.File]::WriteAllText($Destination, 'bundle fixture') }
        }
        $payload = Save-WingetPayload -Directory $dir
        Assert ($payload.Dependencies.Count -eq 1 -and $payload.Dependencies[0] -match '\\x64\\') 'Preparation extracts only applicable winget dependencies'
        Assert ($network.Requests -eq 1 -and $network.Downloads -eq 3) 'Winget downloads bundle, license and dependency archive upfront'
        $network.Offline = $true
        $payload = Save-WingetPayload -Directory $dir
        Assert ($network.Requests -eq 1 -and $network.Downloads -eq 3) 'Complete winget cache works without any GitHub call'
        Assert (Test-Path -LiteralPath $payload.Dependencies[0]) 'Dependencies are ready before mounting Windows'
        Remove-Item -LiteralPath $payload.License -Force
        Assert-Throws { Save-WingetPayload -Directory $dir } 'Missing winget license cannot be treated as ready offline'
    }

    & {
        $dir = Join-Path $testRoot 'languages'
        $api = @{ Offline = $false; Calls = 0; HashMismatch = $false }
        $bytes = [Text.Encoding]::UTF8.GetBytes('language fixture')
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') } finally { $sha.Dispose() }
        function Invoke-RestMethod {
            param($Uri,$TimeoutSec)
            $api.Calls++
            if ($api.Offline) { throw 'DNS: UUP unavailable' }
            if ($Uri -match 'listid') { return [pscustomobject]@{ response = [pscustomobject]@{ builds = [pscustomobject]@{test=[pscustomobject]@{ arch='amd64';title='Windows 11';build='26100.1742';uuid='fixture' } } } } }
            [pscustomobject]@{ response = [pscustomobject]@{ files = [pscustomobject]@{
                'Microsoft-Windows-Client-LanguagePack-Package-amd64-ru-RU.esd' = [pscustomobject]@{size=$bytes.Length;sha256=$hash;url='https://fixture/pack'}
                'Microsoft-Windows-LanguageFeatures-Basic-ru-RU-Package.cab' = [pscustomobject]@{size=$bytes.Length;sha256=$hash;url='https://fixture/basic'}
            } } }
        }
        function Save-Url { param($Url,$Destination) [IO.File]::WriteAllBytes($Destination, $bytes) }
        Save-LanguageFromCatalog -Tags ru-RU -Build 26100 -Revision '26100.1742' -Destination $dir
        Assert ([bool](Read-PreparedCache -Directory $dir -Key 'language-ru-RU-26100.1742')) 'Pack and Basic verified against UUP hashes before sealing cache'
        $api.Offline = $true; $calls = $api.Calls
        Save-LanguageFromCatalog -Tags ru-RU -Build 26100 -Revision '26100.1742' -Destination $dir
        Assert ($api.Calls -eq $calls) 'Cached language needs no UUP request'
        Assert-Throws { Save-LanguageFromCatalog -Tags ru-RU -Build 26100 -Revision '26100.9999' -Destination $dir } 'Different revision cannot reuse the language manifest'
        $basic = Find-LanguagePackage -Root $dir -Tag ru-RU -Kind Basic
        Remove-Item -LiteralPath $basic.FullName -Force
        Assert-Throws { Save-LanguageFromCatalog -Tags ru-RU -Build 26100 -Revision '26100.1742' -Destination $dir } 'Missing Basic fails before servicing'
    }

    & {
        $prompt = @{ Can = $true; Answer = $true; Calls = 0; Question = '' }
        function Test-CanPrompt { $prompt.Can }
        function Read-YesNo { param($Question,$Default) $prompt.Calls++; $prompt.Question=$Question; Assert (-not $Default) 'Cancellation is default'; $prompt.Answer }
        foreach ($lang in @('ru','en')) {
            $script:Lang = $lang; $notes.Clear(); $script:SkippedDownloads = @()
            Confirm-SkipDownload -Component 'winget' -Reason 'api.github.com DNS failure'
            Assert ($script:SkippedDownloads -contains 'winget' -and $notes[0] -match 'api.github.com') "Accepted skip keeps component and cause ($lang)"
            Assert ($notes[0] -match $(if ($lang -eq 'ru') { 'Не удалось подготовить' } else { 'Could not prepare' })) "Failure warning is localized ($lang)"
            Assert ($prompt.Question -match $(if ($lang -eq 'ru') {'Продолжить без «winget»\? Введите Да чтобы продолжить сборку'} else {"Continue without 'winget'\? Enter Yes to continue the build"})) "Skip prompt explicitly says that Yes continues the build ($lang)"
        }
        $script:SkippedDownloads = @(); $prompt.Answer = $false
        Assert-Throws { Confirm-SkipDownload -Component 'winget' -Reason 'DNS' } 'User cancellation stops preparation'
        Assert ($script:SkippedDownloads.Count -eq 0) 'Cancellation is not recorded as consent to skip'
        $prompt.Can = $false; $calls = $prompt.Calls
        Assert-Throws { Confirm-SkipDownload -Component 'winget' -Reason 'DNS' } 'Noninteractive failure cancels instead of silently omitting a requested component'
        Assert ($prompt.Calls -eq $calls) 'No impossible prompt in noninteractive mode'
    }

    # Execute the actual preparation stage with selected download failures.
    $region = [regex]::Match($ast.Extent.Text, '(?ms)^#region[^\r\n]*Подготовка загрузок до обработки образа.*?^#endregion').Value
    Assert ([bool]$region) 'Preparation stage can be exercised independently'
    foreach ($case in @('success','winget-skip','winget-cancel','language-skip','repair-skip','lcu-skip','net-skip','dryrun')) {
        & {
            $script:Lang = 'en'; $script:DownloadsClosed = $false; $script:SkippedDownloads = @(); $script:WorkPrepared = $false
            $events = [Collections.Generic.List[string]]::new()
            $DryRun = $case -eq 'dryrun'; $ClearCache = $false
            $UpdatesDir = Join-Path $testRoot "stage-$case"
            $WorkDir = Join-Path $testRoot 'previous-work'
            $null = New-Item -ItemType Directory -Path $WorkDir -Force
            $sentinel = Join-Path $WorkDir 'previous-build.txt'
            [IO.File]::WriteAllText($sentinel, 'preserve')
            $WithWinget = $true; $WithUpdates = $true; $IncludeDotNetUpdate = $true
            $UpdateMode = if ($case -eq 'repair-skip') { 'none' } else { 'download' }
            $AddLanguage = @('ru-RU','de-DE'); $DownloadLanguage = $AddLanguage; $LanguageSource = ''; $LanguageUpdatePath = ''
            $winVersion = '24H2'; $imgRevision = '26100.1742'; $buildNumber = 26100
            $SetupLanguage = 'original'; $sourceImageLanguage = 'en-US'
            function Test-CanPrompt { $true }
            function Read-YesNo { param($Question,$Default) $events.Add('prompt'); $case -ne 'winget-cancel' }
            function Save-CatalogPayload {
                param($Query,$Directory,$TitlePattern)
                $events.Add("update:$Query")
                if (($case -eq 'lcu-skip' -and $Query -notmatch '\.NET') -or ($case -eq 'net-skip' -and $Query -match '\.NET')) { throw 'DNS failure' }
                Join-Path $Directory 'target.msu'
            }
            function Save-LanguageFromCatalog {
                param($Tags,$Build,$Revision,$Destination)
                $events.Add("language:$($Tags[0])")
                if ($case -eq 'language-skip' -and $Tags[0] -eq 'ru-RU') { throw 'DNS failure' }
            }
            function Find-LanguagePackage { param($Root,$Tag,$Kind) [pscustomobject]@{Length=10} }
            function Get-LanguageRepairUpdate { param($Revision,$Destination) $events.Add('repair'); if($case -eq 'repair-skip'){throw 'DNS failure'}; Join-Path $Destination 'repair.msu' }
            function Save-WingetPayload { param($Directory) $events.Add('winget'); if($case -like 'winget-*'){throw 'api.github.com DNS failure'}; [pscustomobject]@{Bundle='local.bundle';License='local.xml';Dependencies=@('local.appx')} }
            $cancelled = $false
            try { . ([scriptblock]::Create($region)) } catch { if($case -ne 'winget-cancel'){throw}; $cancelled = $true }
            Assert ((Get-Content -LiteralPath $sentinel -Raw) -eq 'preserve' -and -not $script:WorkPrepared) "Preparation never clears previous work ($case)"
            if ($case -eq 'dryrun') { Assert ($events.Count -eq 0 -and -not (Test-Path $UpdatesDir)) 'DryRun performs no downloads, prompts or cache writes'; return }
            if ($case -eq 'winget-cancel') { Assert ($cancelled -and -not $script:DownloadsClosed) 'Cancellation cannot cross into image processing'; return }
            Assert $script:DownloadsClosed "Preparation completes before offline phase ($case)"
            switch ($case) {
                'success' { Assert ($WithWinget -and $AddLanguage.Count -eq 2 -and $lcuPayload -and $dotNetPayload -and -not $script:SkippedDownloads.Count) 'All prepared selections survive' }
                'winget-skip' { Assert (-not $WithWinget -and -not $wingetPayload -and $lcuPayload -and $AddLanguage.Count -eq 2) 'Skipping winget preserves languages and updates' }
                'language-skip' { Assert ($AddLanguage.Count -eq 1 -and $AddLanguage[0] -eq 'de-DE' -and $DownloadLanguage.Count -eq 1 -and $WithWinget) 'Only failed language removed; next language becomes primary' }
                'repair-skip' { Assert (-not $AddLanguage.Count -and -not $DownloadLanguage.Count -and $WithWinget) 'Missing mandatory language LCU skips language integration as a whole' }
                'lcu-skip' { Assert (-not $lcuPayload -and $UpdateMode -eq 'none' -and $dotNetPayload -and $LanguageUpdatePath -and $WithWinget) 'LCU failure preserves .NET and prepares repair LCU for languages' }
                'net-skip' { Assert ($lcuPayload -and -not $dotNetPayload -and -not $IncludeDotNetUpdate -and $WithWinget) '.NET failure preserves LCU and winget' }
            }
        }
    }
    $script:DownloadsClosed = $true
    & {
        $mountDir = Join-Path $testRoot 'fake-image'
        $WithWinget = $true
        $wingetPayload = [pscustomobject]@{Bundle='prepared.msixbundle';License='prepared.xml';Dependencies=@('x64.appx','neutral.msix')}
        $state = @{Fail=$false;Arguments=@()}
        function Invoke-Dism { param($Arguments,[switch]$Quiet) $state.Arguments=$Arguments; if($state.Fail){throw 'DISM provisioning failed'} }
        $start = $ast.Extent.Text.IndexOf('#region ── Стадия 13. winget')
        $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and
            $n.Extent.StartOffset -gt $start -and $n.Extent.Text -match '^if \(\$WithWinget\) \{\r?\n    try' }, $true)
        if (-not $node) { throw 'Winget integration block missing' }
        . ([scriptblock]::Create($node.Extent.Text))
        Assert ($state.Arguments -contains '/PackagePath:prepared.msixbundle' -and $state.Arguments -contains '/LicensePath:prepared.xml' -and $state.Arguments -contains '/DependencyPackagePath:x64.appx' -and $state.Arguments -contains '/DependencyPackagePath:neutral.msix') 'Offline winget stage consumes all prepared files'
        $state.Fail = $true
        Assert-Throws { . ([scriptblock]::Create($node.Extent.Text)) } 'Actual provisioning errors remain fatal instead of pretending to skip a download'
    }
    & {
        $dotNetPayload = Join-Path $testRoot 'payload.msu'; $lcuPayload = $null
        $Preset = 'safe'; $DriversDir = ''; $mountDir = Join-Path $testRoot 'fake-image'
        $calls = [Collections.Generic.List[string]]::new()
        function Invoke-Dism { param($Arguments,$Activity) $calls.Add(($Arguments -join '|')) }
        $updatesRegion = [regex]::Match($ast.Extent.Text, '(?ms)^#region[^\r\n]*Стадия 6\. Интеграция обновлений.*?^#endregion').Value
        . ([scriptblock]::Create($updatesRegion))
        Assert ($calls.Count -eq 1 -and $calls[0].Contains("/PackagePath:$dotNetPayload")) 'Offline update stage can apply prepared .NET after LCU was skipped'
    }
    & {
        $WorkDir = Join-Path $testRoot 'cancelled-work'
        $null = New-Item -ItemType Directory -Path $WorkDir
        $sentinel = Join-Path $WorkDir 'previous-build.txt'
        [IO.File]::WriteAllText($sentinel, 'previous work')
        $DryRun = $false; $script:WorkPrepared = $false; $script:Dism = $null
        $script:Mounted = $false; $script:BootMounted = $false; $script:IsoMounted = $null
        $script:LangIso = $null; $script:Transcribing = $false
        function Dismount-Hives { }
        function Wait-BeforeExit { }
        function Test-SafeToWipe { throw 'Cancellation must not reach work cleanup' }
        $mainTry = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] -and $_.Finally } | Select-Object -Last 1
        $cleanup = $mainTry.Finally.Extent.Text
        . ([scriptblock]::Create($cleanup.Substring(1, $cleanup.Length - 2)))
        Assert (Test-Path -LiteralPath $sentinel) 'Actual final cleanup preserves previous work when downloads were cancelled'
    }
    foreach ($action in @(
        { Save-Url -Url 'https://fixture' -Destination (Join-Path $testRoot 'closed') },
        { Save-WingetPayload -Directory $testRoot },
        { Save-LanguageFromCatalog -Tags ru-RU -Build 26100 -Revision '26100.1742' -Destination $testRoot },
        { Search-Catalog -Query 'closed' },
        { Get-CatalogLinks -UpdateId 'closed' }
        { Save-CatalogPayload -Query 'closed' -Directory $testRoot -CacheFirst }
    )) { Assert-Throws $action 'Download entry point rejects use after preparation' }
    $boundary = $ast.Extent.Text.IndexOf('#region ── Распаковка ISO после подготовки загрузок')
    $lateCalls = @($ast.FindAll({ param($n)
        $n -is [Management.Automation.Language.CommandAst] -and $n.Extent.StartOffset -gt $boundary -and
        $n.GetCommandName() -in @('Invoke-WebRequest','Invoke-RestMethod','curl.exe','Save-Url','Save-CatalogPayload','Save-WingetPayload','Save-LanguageFromCatalog','Save-SetupLanguagePayload','Get-LanguageRepairUpdate','Search-Catalog','Get-CatalogLinks')
    }, $true))
    Assert ($lateCalls.Count -eq 0) 'No build-time network calls exist after source copy begins'
    Assert ($ast.Extent.Text.IndexOf('if (-not $DryRun -and $script:WorkPrepared)') -gt $boundary) 'Final cleanup only owns work created after preparation'
    Write-Host "PASS: $script:checks download checks; PowerShell $($PSVersionTable.PSVersion)"
} finally {
    $safeRoot = [IO.Path]::GetFullPath((Join-Path $repo 'tmp')).TrimEnd('\')
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith("$safeRoot\downloads-", [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
