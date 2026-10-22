# Download BlaziumHub only after the manifest clears the pinned host,
# a required sha256, a version floor, and an Authenticode publisher check.
param(
    [Parameter(Mandatory = $true)][string]$OutFile,
    [Parameter(Mandatory = $true)][string]$VersionFile,
    [string]$FloorFile = "",
    [string]$ManifestPath = ""
)

$ErrorActionPreference = "Stop"
$PinnedHost = "cdn.blazium.app"
$Publisher = 'CN="Divine Games, inc."'
$ManifestUrl = "https://cdn.blazium.app/hub/hub.json"

function Test-PinnedUrl([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    try { $parsed = [Uri]$Url } catch { return $false }
    if ($parsed.Scheme -ne "https") { return $false }
    if ($parsed.UserInfo) { return $false }
    if ($parsed.Host -ne $PinnedHost) { return $false }
    if (-not $parsed.IsDefaultPort) { return $false }
    return $true
}

function ConvertTo-VersionParts([string]$Text) {
    $raw = $Text.Trim()
    if ($raw.StartsWith("v") -and $raw.Length -gt 1 -and [char]::IsDigit($raw[1])) {
        $raw = $raw.Substring(1)
    }
    $core = ($raw -split "[-+]", 2)[0]
    if ($core -notmatch "^\d+(\.\d+)*$") { return $null }
    return @($core.Split(".") | ForEach-Object { [int]$_ })
}

function Test-Older([string]$Latest, [string]$Floor) {
    if ([string]::IsNullOrWhiteSpace($Floor)) { return $false }
    $left = ConvertTo-VersionParts $Latest
    $right = ConvertTo-VersionParts $Floor
    if ($null -eq $left -or $null -eq $right) { return $true }
    $width = [Math]::Max($left.Count, $right.Count)
    for ($i = 0; $i -lt $width; $i++) {
        $a = 0
        $b = 0
        if ($i -lt $left.Count) { $a = $left[$i] }
        if ($i -lt $right.Count) { $b = $right[$i] }
        if ($a -lt $b) { return $true }
        if ($a -gt $b) { return $false }
    }
    return $false
}

function Remove-Partial([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
}

if ($ManifestPath) {
    $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
} else {
    if (-not (Test-PinnedUrl $ManifestUrl)) { exit 1 }
    $manifest = Invoke-RestMethod -UseBasicParsing -Uri $ManifestUrl
}

$ver = [string]$manifest.latest
if (-not $ver) { exit 1 }
$prop = $manifest.versions.PSObject.Properties[$ver]
if (-not $prop) { exit 1 }
$entry = $prop.Value
$download = $entry.downloads | Where-Object {
    $_.platform -eq "windows" -and ($_.arch -eq "x86_64" -or $_.arch -eq "amd64")
} | Select-Object -First 1
if (-not $download) { exit 1 }

$floor = ""
if ($FloorFile -and (Test-Path -LiteralPath $FloorFile)) {
    $floor = (Get-Content -Raw -LiteralPath $FloorFile).Trim()
}
if (-not (ConvertTo-VersionParts $ver)) { exit 1 }
if (Test-Older $ver $floor) { exit 1 }

$sha = ([string]$download.sha256).Trim()
if ($sha -notmatch "^[0-9a-fA-F]{64}$") { exit 1 }
$url = [string]$download.download_url
if (-not (Test-PinnedUrl $url)) { exit 1 }

$ProgressPreference = "SilentlyContinue"
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $OutFile
$got = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutFile).Hash
if ($got.ToLower() -ne $sha.ToLower()) {
    Remove-Partial $OutFile
    exit 1
}

$sig = Get-AuthenticodeSignature -LiteralPath $OutFile
$subject = ""
if ($sig.SignerCertificate) { $subject = [string]$sig.SignerCertificate.Subject }
if ($sig.Status -ne "Valid" -or $subject -notlike "*$Publisher*") {
    Remove-Partial $OutFile
    exit 1
}

Set-Content -LiteralPath $VersionFile -Value $ver -Encoding ascii
exit 0
