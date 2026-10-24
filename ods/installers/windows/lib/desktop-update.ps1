# ============================================================================
# ODS Windows Desktop -- verified update
# ============================================================================
# Part of: installers/windows/lib/
# Purpose: Update an installed ODS Desktop to the newest signed release. It
#          reads the installed version from the Apps & Features entry, applies
#          the same release gates as installers/verified-release.ps1 (immutable
#          stable release, annotated tag with a GitHub-verified signature),
#          downloads the release into a new folder, authenticates the source
#          and dashboard archives with `gh attestation verify` BEFORE anything
#          is extracted, refuses unsafe archive entries, and then reruns
#          windows-desktop.ps1 from the verified source. A rerun keeps the
#          owner's model, port and settings; this file never touches them.
#          Any failed check stops with nothing changed on this PC.
# Expects: desktop-uninstall.ps1 (Get-ODSDesktopUninstallKey,
#          $script:ODSDesktopUninstallRoot). No entry point yet: setup and a
#          shortcut call Invoke-ODSDesktopUpdate in a follow-up.
# Provides: Get-ODSDesktopInstalledVersion, Get-ODSDesktopLatestRelease,
#           New-ODSDesktopUpdateStage, Assert-ODSDesktopZipEntries,
#           Get-ODSDesktopUpdatePackage, Invoke-ODSDesktopUpdate
# Modder notes: the release gates, signer workflow and gh flags are copied from
#   verified-release.ps1 on purpose (that file is a pasted bootstrap and stays
#   self-contained); test-windows-desktop-update.ps1 fails if they drift.
#   Network, download, verification and the setup run are scriptblock
#   parameters so tests need no network, gh or setup. The dashboard archive
#   name below is the contract the release workflow must publish.
# ============================================================================

Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:ODSDesktopUpdateRepository = 'Osmantic/ODS'
$script:ODSDesktopUpdateSignerWorkflow = 'Osmantic/ODS/.github/workflows/release-provenance.yml'
$script:ODSDesktopUpdateTagPattern = '^v[0-9]+\.[0-9]+\.[0-9]+$'
$script:ODSDesktopUpdateVersionPattern = '^[0-9]+\.[0-9]+\.[0-9]+$'

function Get-ODSDesktopInstalledVersion([string]$UninstallRoot = $script:ODSDesktopUninstallRoot) {
    $key = Get-ODSDesktopUninstallKey $UninstallRoot
    if (-not (Test-Path -LiteralPath $key)) {
        throw 'ODS Desktop is not installed on this Windows account, so there is nothing to update. Run ODS Desktop setup first.'
    }
    $text = [string](Get-ItemProperty -LiteralPath $key).DisplayVersion
    if ($text -cnotmatch $script:ODSDesktopUpdateVersionPattern) {
        throw "The installed ODS Desktop version '$text' is not a plain number like 3.0.0. Run ODS Desktop setup again to repair it."
    }
    return [version]$text
}

function Invoke-ODSDesktopUpdateGet([string]$Uri) {
    return (Invoke-RestMethod -Uri $Uri -TimeoutSec 60)
}

function Get-ODSDesktopLatestRelease([scriptblock]$Get = ${function:Invoke-ODSDesktopUpdateGet}) {
    $api = "https://api.github.com/repos/$($script:ODSDesktopUpdateRepository)"
    $release = & $Get "$api/releases/latest"
    $tag = [string]$release.tag_name
    if ($release.immutable -ne $true -or $release.draft -ne $false -or $release.prerelease -ne $false -or $tag -cnotmatch $script:ODSDesktopUpdateTagPattern) {
        throw 'No immutable signed stable release is available. Nothing was changed.'
    }
    $ref = & $Get "$api/git/ref/tags/$tag"
    $tagObject = [string]$ref.object.sha
    if ($ref.object.type -ne 'tag' -or $tagObject -cnotmatch '^[0-9a-f]{40}$') {
        throw 'The newest release tag is not an annotated, signed tag. Nothing was changed.'
    }
    $annotation = & $Get "$api/git/tags/$tagObject"
    $commit = [string]$annotation.object.sha
    if ($annotation.verification.verified -ne $true -or $annotation.verification.reason -ne 'valid' -or
        $annotation.object.type -ne 'commit' -or $commit -cnotmatch '^[0-9a-f]{40}$') {
        throw 'The newest release tag signature was not verified. Nothing was changed.'
    }
    return [pscustomobject]@{ Tag = $tag; Version = [version]$tag.Substring(1); Commit = $commit }
}

function New-ODSDesktopUpdateStage([string]$Parent = [IO.Path]::GetTempPath()) {
    # A short name keeps extracted paths well under the Windows path limit.
    $stage = Join-Path $Parent ('ods-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $stage
    return $stage
}

function Assert-ODSDesktopZipEntries([string]$ZipPath) {
    # Checked before any file is written, so an unsafe archive extracts nothing.
    $name = Split-Path -Leaf $ZipPath
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $seen = @{}
        foreach ($entry in $archive.Entries) {
            $path = $entry.FullName
            if (-not $path -or $path.StartsWith('/') -or $path.Contains('\') -or $path.Contains(':') -or (($path -split '/') -contains '..')) {
                throw "$name contains an unsafe path '$path', so it was not extracted. Nothing was changed."
            }
            $key = $path.TrimEnd('/').ToLowerInvariant()
            if ($seen.ContainsKey($key)) {
                throw "$name contains paths that collide on Windows ('$path'), so it was not extracted. Nothing was changed."
            }
            $seen[$key] = $true
        }
    } finally {
        $archive.Dispose()
    }
}

function Invoke-ODSDesktopUpdateDownload([string]$Uri, [string]$OutFile) {
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile -TimeoutSec 600
}

function Invoke-ODSDesktopUpdateVerify([string]$Archive, [string]$Bundle, [string]$Tag, [string]$Commit) {
    if (-not (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'Install GitHub CLI from https://cli.github.com first, then run the update again. Nothing was changed.'
    }
    & gh attestation verify $Archive --bundle $Bundle --repo $script:ODSDesktopUpdateRepository --hostname github.com `
        --signer-workflow $script:ODSDesktopUpdateSignerWorkflow --source-ref "refs/tags/$Tag" --source-digest $Commit --deny-self-hosted-runners
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub release verification failed for $(Split-Path -Leaf $Archive). Nothing was changed."
    }
}

function Get-ODSDesktopUpdatePackage {
    <#
    .SYNOPSIS
        Download the release archives into $Stage, verify both, check their
        entries, then extract. Returns the setup script and dashboard folder.
    #>
    param(
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$Stage,
        [scriptblock]$Download = ${function:Invoke-ODSDesktopUpdateDownload},
        [scriptblock]$Verify = ${function:Invoke-ODSDesktopUpdateVerify}
    )
    $tag = [string]$Release.Tag
    $base = "https://github.com/$($script:ODSDesktopUpdateRepository)/releases/download/$tag"
    $sourceZip = Join-Path $Stage "ODS-$tag-source.zip"
    $distZip = Join-Path $Stage "ODS-$tag-desktop-dist.zip"
    $bundle = Join-Path $Stage 'provenance.sigstore.jsonl'
    & $Download "$base/$(Split-Path -Leaf $sourceZip)" $sourceZip
    & $Download "$base/$(Split-Path -Leaf $distZip)" $distZip
    & $Download "$base/provenance.sigstore.jsonl" $bundle
    foreach ($zip in @($sourceZip, $distZip)) { & $Verify $zip $bundle $tag ([string]$Release.Commit) }
    foreach ($zip in @($sourceZip, $distZip)) { Assert-ODSDesktopZipEntries $zip }
    $source = Join-Path $Stage 'source'
    $dist = Join-Path $Stage 'dist'
    [IO.Compression.ZipFile]::ExtractToDirectory($sourceZip, $source)
    [IO.Compression.ZipFile]::ExtractToDirectory($distZip, $dist)
    $setup = Join-Path $source 'ods\installers\windows-desktop.ps1'
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $dist 'index.html') -PathType Leaf)) {
        throw "The $tag download is incomplete (setup or the dashboard is missing), so it was not installed. Nothing was changed."
    }
    return [pscustomobject]@{ SetupScript = $setup; DashboardDist = $dist }
}

function Invoke-ODSDesktopUpdateSetup([string]$SetupScript, [string[]]$Arguments) {
    $shell = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
    $global:LASTEXITCODE = 0
    & (Join-Path $PSHOME $shell) -NoProfile -ExecutionPolicy Bypass -File $SetupScript @Arguments | Out-Host
    return [int]$global:LASTEXITCODE
}

function Invoke-ODSDesktopUpdate {
    <#
    .SYNOPSIS
        Update to the newest verified release. Returns $true when setup ran
        and $false when this PC is already current. The staging folder is
        deleted unless setup fails, then its path is printed for support.
    #>
    param(
        [string]$UninstallRoot = $script:ODSDesktopUninstallRoot,
        [string]$StageParent = [IO.Path]::GetTempPath(),
        [scriptblock]$Get = ${function:Invoke-ODSDesktopUpdateGet},
        [scriptblock]$Download = ${function:Invoke-ODSDesktopUpdateDownload},
        [scriptblock]$Verify = ${function:Invoke-ODSDesktopUpdateVerify},
        [scriptblock]$RunSetup = ${function:Invoke-ODSDesktopUpdateSetup}
    )
    $installed = Get-ODSDesktopInstalledVersion $UninstallRoot
    $release = Get-ODSDesktopLatestRelease $Get
    if ($release.Version -le $installed) {
        Write-Host "         ODS Desktop $installed is up to date."
        return $false
    }
    Write-Host "         Updating ODS Desktop $installed to $($release.Version). Checking the download before installing it."
    $stage = New-ODSDesktopUpdateStage $StageParent
    $keep = $false
    try {
        $package = Get-ODSDesktopUpdatePackage -Release $release -Stage $stage -Download $Download -Verify $Verify
        $exit = [int](& $RunSetup $package.SetupScript @('-NonInteractive', '-DashboardDist', $package.DashboardDist))
        if ($exit -ne 0) {
            $keep = $true
            throw "The update stopped: setup exited with code $exit. Your model and settings were not removed. The verified download is kept at $stage; run setup from there again, or share it with support."
        }
    } finally {
        if (-not $keep -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
    Write-Host "         ODS Desktop is now $($release.Version)."
    return $true
}
