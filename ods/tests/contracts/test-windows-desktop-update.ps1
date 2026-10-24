# Windows Desktop verified update: the installed version comes from the Apps &
# Features entry, the release gates match installers/verified-release.ps1, both
# archives are verified before anything is extracted, unsafe archive entries
# extract nothing, and setup runs once from the verified source with the
# verified dashboard. Network, download, gh and setup are fixtures; the
# registry entry goes under a throwaway HKCU key. Windows only (registry).
# The Apps & Features key is built here as ODSDesktop under the given root, the same
# name ODS Desktop setup writes; this test does not load the Desktop uninstall file.
# Runs under Windows PowerShell 5.1 and PowerShell 7.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$lib = Join-Path $root 'installers/windows/lib'
foreach ($name in 'desktop-update.ps1') { . (Join-Path $lib $name) }
Add-Type -AssemblyName System.IO.Compression
$script:checks = 0
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
    Microsoft.PowerShell.Utility\Write-Host "PASS $Message"
}
function Get-Failure([scriptblock]$Action) {
    try { & $Action; return '' } catch { return $_.Exception.Message }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("ods-update-contract-$([guid]::NewGuid().ToString('N'))")
$registry = 'HKCU:\Software\ODS-Contract-' + [guid]::NewGuid().ToString('N') + '\Uninstall'
$tagObject = 'a' * 40
$commit = 'b' * 40

function New-Zip([string]$Path, [string[]]$Entries) {
    $stream = [IO.File]::Create($Path)
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entries) {
            $entry = $zip.CreateEntry($name)
            $writer = [IO.StreamWriter]::new($entry.Open())
            $writer.Write('x')
            $writer.Dispose()
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
}

function Set-Installed([string]$Version) {
    $key = Join-Path $registry 'ODSDesktop'
    $null = New-Item -Path $key -Force
    $null = New-ItemProperty -LiteralPath $key -Name DisplayVersion -Value $Version -PropertyType String -Force
}

# Fake GitHub API: one scenario name picks which gate is broken.
$script:scenario = 'valid'
$script:latest = 'v3.1.0'
$script:getCalls = @()
$fakeGet = {
    param($Uri)
    $script:getCalls += $Uri
    $s = $script:scenario
    if ($Uri.EndsWith('/releases/latest')) {
        return [pscustomobject]@{ tag_name = $(if ($s -eq 'bad-tag') { '../untrusted' } else { $script:latest })
            immutable = ($s -ne 'mutable'); draft = ($s -eq 'draft'); prerelease = ($s -eq 'prerelease') }
    }
    if ($Uri -like '*/git/ref/tags/*') {
        return [pscustomobject]@{ object = [pscustomobject]@{ type = $(if ($s -eq 'lightweight') { 'commit' } else { 'tag' }); sha = $tagObject } }
    }
    return [pscustomobject]@{ object = [pscustomobject]@{ type = 'commit'; sha = $commit }
        verification = [pscustomobject]@{ verified = ($s -ne 'unsigned'); reason = 'valid' } }
}

# Fake download: writes a prebuilt zip (or text) per file name and records it.
$script:downloads = @()
$script:sourceEntries = @('ods/installers/windows-desktop.ps1', 'ods/manifest.json')
$script:distEntries = @('index.html', 'assets/app.js')
$fakeDownload = {
    param($Uri, $OutFile)
    $script:downloads += $Uri
    if ($OutFile -like '*-source.zip') { New-Zip $OutFile $script:sourceEntries }
    elseif ($OutFile -like '*-desktop-dist.zip') { New-Zip $OutFile $script:distEntries }
    else { [IO.File]::WriteAllText($OutFile, '{}') }
}

# Fake verifier: records archive and tag; one scenario fails it.
$script:verified = @()
$script:verifyMode = 'pass'
$fakeVerify = {
    param($Archive, $Bundle, $Tag, $Commit)
    $script:verified += [pscustomobject]@{ Archive = (Split-Path -Leaf $Archive); Tag = $Tag; Commit = $Commit
        BundleSeen = (Test-Path -LiteralPath $Bundle -PathType Leaf); Extracted = (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $Archive) 'source')) }
    if ($script:verifyMode -eq 'fail') { throw "GitHub release verification failed for $(Split-Path -Leaf $Archive). Nothing was changed." }
}

# Fake setup: records what it was asked to run.
$script:setupCalls = @()
$script:setupExit = 0
$fakeSetup = {
    param($SetupScript, $Arguments)
    $script:setupCalls += [pscustomobject]@{ Script = $SetupScript; Arguments = @($Arguments); ScriptExists = (Test-Path -LiteralPath $SetupScript) }
    return $script:setupExit
}

function Reset-Fixtures {
    $script:scenario = 'valid'; $script:latest = 'v3.1.0'; $script:getCalls = @(); $script:downloads = @(); $script:verified = @()
    $script:verifyMode = 'pass'; $script:setupCalls = @(); $script:setupExit = 0
    $script:sourceEntries = @('ods/installers/windows-desktop.ps1', 'ods/manifest.json')
    $script:distEntries = @('index.html', 'assets/app.js')
}
function Invoke-Update([string]$Parent = $fixture) {
    return (Invoke-ODSDesktopUpdate -UninstallRoot $registry -StageParent $Parent -Get $fakeGet -Download $fakeDownload -Verify $fakeVerify -RunSetup $fakeSetup)
}
function Get-Stages([string]$Parent = $fixture) { return @(Get-ChildItem -LiteralPath $Parent -Directory -Filter 'ods-update-*' -ErrorAction SilentlyContinue) }

try {
    $null = New-Item -ItemType Directory -Path $fixture

    # --- installed version
    $message = Get-Failure { $null = Get-ODSDesktopInstalledVersion $registry }
    Check ($message -match 'not installed on this Windows account') 'no Apps & Features entry: says ODS Desktop is not installed'
    Set-Installed 'preview'
    $message = Get-Failure { $null = Get-ODSDesktopInstalledVersion $registry }
    Check ($message -match "'preview' is not a plain number") 'a non-numeric DisplayVersion is refused with a repair step'
    Set-Installed '3.0.0'
    Check ((Get-ODSDesktopInstalledVersion $registry) -eq [version]'3.0.0') 'the installed version is read from DisplayVersion'

    # --- release gates
    foreach ($case in @(
        @{ Scenario = 'mutable'; Pattern = 'No immutable signed stable release' },
        @{ Scenario = 'draft'; Pattern = 'No immutable signed stable release' },
        @{ Scenario = 'prerelease'; Pattern = 'No immutable signed stable release' },
        @{ Scenario = 'bad-tag'; Pattern = 'No immutable signed stable release' },
        @{ Scenario = 'lightweight'; Pattern = 'not an annotated, signed tag' },
        @{ Scenario = 'unsigned'; Pattern = 'signature was not verified' })) {
        Reset-Fixtures
        $script:scenario = $case.Scenario
        $message = Get-Failure { $null = Invoke-Update }
        Check ($message -match $case.Pattern -and $message -match 'Nothing was changed') "release gate '$($case.Scenario)' refuses with 'Nothing was changed'"
        Check ($script:downloads.Count -eq 0 -and $script:setupCalls.Count -eq 0 -and (Get-Stages).Count -eq 0) "release gate '$($case.Scenario)' downloads nothing, runs no setup and leaves no staging folder"
    }

    # --- already current
    # The loop variable must not share a name with the script-scoped $latest that Reset-Fixtures writes.
    foreach ($candidateTag in 'v3.0.0', 'v2.9.0') {
        Reset-Fixtures
        $script:latest = $candidateTag
        $result = Invoke-Update
        Check ($result -eq $false -and $script:downloads.Count -eq 0 -and $script:setupCalls.Count -eq 0 -and (Get-Stages).Count -eq 0) "latest $candidateTag vs installed 3.0.0: up to date, nothing downloaded"
    }

    # --- the update itself, from a folder with spaces and non-ASCII characters
    Reset-Fixtures
    $unicodeParent = Join-Path $fixture ("O'Brien Jos$([char]0x00E9) M$([char]0x00FC)ller")
    $null = New-Item -ItemType Directory -Path $unicodeParent
    $result = Invoke-Update $unicodeParent
    Check ($result -eq $true) 'a newer signed release: the update runs'
    Check ($script:downloads.Count -eq 3 -and ($script:downloads | Where-Object { $_ -like 'https://github.com/Osmantic/ODS/releases/download/v3.1.0/*' }).Count -eq 3) 'it downloads the source, dashboard and attestation bundle from the release tag'
    Check ($script:verified.Count -eq 2 -and $script:verified[0].Archive -ceq 'ODS-v3.1.0-source.zip' -and $script:verified[1].Archive -ceq 'ODS-v3.1.0-desktop-dist.zip') 'both archives are verified'
    Check (($script:verified | Where-Object { $_.Tag -ceq 'v3.1.0' -and $_.Commit -ceq $commit }).Count -eq 2) 'verification is pinned to the release tag and its signed commit'
    Check (($script:verified | Where-Object { $_.Extracted }).Count -eq 0) 'nothing is extracted before verification finishes'
    Check (($script:verified | Where-Object { $_.BundleSeen }).Count -eq 2) 'the attestation bundle is on disk when each archive is verified'
    Check ($script:setupCalls.Count -eq 1 -and $script:setupCalls[0].ScriptExists) 'setup runs once, from a file that was extracted'
    $arguments = $script:setupCalls[0].Arguments
    Check ($arguments[0] -ceq '-NonInteractive' -and $arguments[1] -ceq '-DashboardDist' -and $arguments.Count -eq 3) 'setup is run non-interactively with the verified dashboard'
    Check ($arguments[2].StartsWith($unicodeParent) -and $script:setupCalls[0].Script.StartsWith($unicodeParent)) 'a staging folder with spaces and non-ASCII characters is passed through exactly'
    Check ((Get-Stages $unicodeParent).Count -eq 0) 'the staging folder is deleted after a successful update'

    # --- unsafe archives extract nothing
    foreach ($case in @(
        @{ Name = 'parent traversal'; Entries = @('ods/../../evil.ps1') },
        @{ Name = 'rooted path'; Entries = @('/evil.ps1') },
        @{ Name = 'drive path'; Entries = @('C:evil.ps1') },
        @{ Name = 'backslash'; Entries = @('ods\evil.ps1') },
        @{ Name = 'case collision'; Entries = @('ods/Readme.md', 'ods/README.md') })) {
        Reset-Fixtures
        $script:sourceEntries = $case.Entries
        $message = Get-Failure { $null = Invoke-Update }
        Check ($message -match 'was not extracted' -and $message -match 'Nothing was changed') "unsafe source archive ($($case.Name)) is refused before extraction"
        Check ($script:setupCalls.Count -eq 0 -and (Get-Stages).Count -eq 0) "unsafe source archive ($($case.Name)): no setup, no staging folder left"
    }
    Reset-Fixtures
    $script:distEntries = @('index.html', '../escape.js')
    $message = Get-Failure { $null = Invoke-Update }
    Check ($message -match 'desktop-dist.zip contains an unsafe path' -and $script:setupCalls.Count -eq 0) 'an unsafe dashboard archive is refused too'

    # --- incomplete downloads
    Reset-Fixtures
    $script:distEntries = @('assets/app.js')
    $message = Get-Failure { $null = Invoke-Update }
    Check ($message -match 'download is incomplete' -and $script:setupCalls.Count -eq 0 -and (Get-Stages).Count -eq 0) 'a dashboard without index.html is refused and cleaned up'
    Reset-Fixtures
    $script:sourceEntries = @('ods/manifest.json')
    $message = Get-Failure { $null = Invoke-Update }
    Check ($message -match 'download is incomplete' -and $script:setupCalls.Count -eq 0) 'a source archive without setup is refused'

    # --- verification failure and network failure
    Reset-Fixtures
    $script:verifyMode = 'fail'
    $message = Get-Failure { $null = Invoke-Update }
    Check ($message -match 'verification failed' -and $script:setupCalls.Count -eq 0 -and (Get-Stages).Count -eq 0) 'a failed verification runs no setup and leaves no staging folder'
    Reset-Fixtures
    $failingDownload = { param($Uri, $OutFile) throw "The remote name could not be resolved ($Uri -> $(Split-Path -Leaf $OutFile))" }
    $message = Get-Failure { $null = Invoke-ODSDesktopUpdate -UninstallRoot $registry -StageParent $fixture -Get $fakeGet -Download $failingDownload -Verify $fakeVerify -RunSetup $fakeSetup }
    Check ($message -match 'could not be resolved' -and $message -match 'ODS-v3.1.0-source.zip' -and (Get-Stages).Count -eq 0) 'a network error reaches the user unchanged and leaves no staging folder'

    # --- setup failure keeps the verified download
    Reset-Fixtures
    $script:setupExit = 7
    $message = Get-Failure { $null = Invoke-Update }
    $kept = @(Get-Stages)
    Check ($message -match 'setup exited with code 7' -and $message -match 'model and settings were not removed') 'a failing setup is reported with its exit code and reassurance about data'
    Check ($kept.Count -eq 1 -and $message.Contains($kept[0].FullName)) 'the staging folder is kept and its path is printed for support'
    Remove-Item -LiteralPath $kept[0].FullName -Recurse -Force

    # --- the real verifier refuses without gh, before anything runs
    $realVerifyMissing = Get-Failure {
        $savedPath = $env:PATH
        $env:PATH = $fixture
        try { Invoke-ODSDesktopUpdateVerify (Join-Path $fixture 'x.zip') (Join-Path $fixture 'b') 'v3.1.0' $commit } finally { $env:PATH = $savedPath }
    }
    Check ($realVerifyMissing -match 'Install GitHub CLI' -and $realVerifyMissing -match 'Nothing was changed') 'without GitHub CLI the real verifier stops with install guidance'

    # --- the gates have not drifted from the pasted bootstrap
    $bootstrap = [IO.File]::ReadAllText((Join-Path $root 'installers/verified-release.ps1'))
    Check ($bootstrap.Contains($script:ODSDesktopUpdateSignerWorkflow)) 'the signer workflow matches verified-release.ps1'
    Check ($bootstrap.Contains("'" + $script:ODSDesktopUpdateTagPattern + "'")) 'the tag pattern matches verified-release.ps1'
    Check ($bootstrap.Contains('--deny-self-hosted-runners') -and $bootstrap.Contains('--source-digest') -and $bootstrap.Contains("--repo $($script:ODSDesktopUpdateRepository)")) 'the gh attestation flags match verified-release.ps1'
    $update = [IO.File]::ReadAllText((Join-Path $lib 'desktop-update.ps1'))
    Check ($update.Contains('--deny-self-hosted-runners') -and $update.Contains('--source-digest') -and $update.Contains('--signer-workflow')) 'the update verifier passes every pinning flag'

    # --- native: no container or Linux layer anywhere in the update path
    Check ($update -notmatch '(?i)docker|wsl|bash') 'the update path references no Docker, WSL or Bash'
    Check ($update -match '-ExecutionPolicy Bypass' -and $update -notmatch 'Set-ExecutionPolicy') 'execution policy is bypassed only for the one verified setup process, never changed'
} finally {
    $testRoot = Split-Path -Parent $registry
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
Microsoft.PowerShell.Utility\Write-Host "All $script:checks Windows Desktop update checks passed."
