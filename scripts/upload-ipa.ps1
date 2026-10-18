# Uploads a decrypted Spotify IPA from this PC to your fork and runs "Build IPA from your own Spotify IPA" on it,
# so the workflow needs no download link. The IPA goes on a draft release named ipa-input: drafts are visible only
# to you, even in a public fork. Needs the GitHub CLI (winget install GitHub.cli) signed in with gh auth login.
#
#   .\scripts\upload-ipa.ps1 C:\path\to\Spotify.ipa
#   .\scripts\upload-ipa.ps1 C:\path\to\Spotify.ipa -UploadMethod both -Ref main -NoWatch

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Ipa,
    [ValidateSet('artifacts', 'filebin', 'both')]
    [string]$UploadMethod = 'artifacts',
    # The branch whose build-ipa.yml runs; defaults to the one checked out.
    [string]$Ref,
    [switch]$NoWatch
)

$ErrorActionPreference = 'Stop'
$Tag = 'ipa-input'

function Invoke-Gh {
    & gh @args
    if ($LASTEXITCODE -ne 0) { throw "gh $($args -join ' ') failed" }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'The GitHub CLI is not installed: winget install GitHub.cli, then gh auth login'
}
$Ipa = (Resolve-Path $Ipa).Path
if ([IO.Path]::GetExtension($Ipa) -ne '.ipa') { throw "$Ipa is not an .ipa" }
if (-not $Ref) { $Ref = (git -C $PSScriptRoot rev-parse --abbrev-ref HEAD).Trim() }

Push-Location $PSScriptRoot
try {
    # Windows PowerShell turns redirected native stderr into errors, so look the release up without Stop.
    $ErrorActionPreference = 'Continue'
    & gh release view $Tag --json tagName *> $null
    $exists = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    if (-not $exists) {
        Write-Host "Creating the private draft release $Tag"
        Invoke-Gh release create $Tag --draft --title 'IPA input (private draft)' `
            --notes 'Holds the decrypted IPA that build-ipa.yml builds when it is given no link. Filled by scripts/upload-ipa.ps1. Do not publish.'
    }

    # One IPA at a time, so the workflow never picks up an older one.
    $old = (Invoke-Gh release view $Tag --json assets --jq '.assets[].name') -split "`n" | Where-Object { $_ }
    foreach ($name in $old) { Invoke-Gh release delete-asset $Tag $name --yes }

    $mb = [math]::Round((Get-Item $Ipa).Length / 1MB)
    Write-Host "Uploading $(Split-Path $Ipa -Leaf) ($mb MB)"
    Invoke-Gh release upload $Tag $Ipa

    Write-Host "Starting the build on $Ref"
    Invoke-Gh workflow run build-ipa.yml --ref $Ref -f upload_method=$UploadMethod
    if ($NoWatch) { return }

    # The new run takes a few seconds to show up.
    Start-Sleep -Seconds 5
    $run = Invoke-Gh run list --workflow build-ipa.yml --branch $Ref --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId'
    gh run watch $run --exit-status
    if ($LASTEXITCODE -ne 0) { throw "The build failed: gh run view $run --log-failed" }
    Write-Host "Done. Download the IPA: gh run download $run   (or from the run's page under Artifacts)"
} finally {
    Pop-Location
}
