<#
    Builds the single download .\dist\rodriextract.zip : the app, the bundled Poppler tools,
    and the troubleshooting tool in the diagnostic\ subfolder.
    Zip entries use forward slashes so every unzip tool (not just Windows Explorer) extracts them correctly.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# SHA-256 of rodriextract.ps1 / .cmd in versions that were already sent out
$legacy = @(
    'rodriextract.ps1|45527918C7ACB25007ABC44FAC9D66761867A209AA6910BFF923D5E5640E8FCC|v1.0'
    'rodriextract.cmd|B4F06404811306BFA42384BC6EAA2112AF4809BF9EA8634BC5C289C067342F88|v1.0'
    'rodriextract.cmd|3496B2086462C9EDC34EE45D8BE84186981684B54FF36A72A61DB9E3B5B640AA|v1.1 (no unblock step)'
    'rodriextract.ps1|5C20FFD02088A416A7B33D7B95DBACD03A3946B830BC563E4EE285A0CF9B8C2F|v1.1 (LF line endings)'
    'rodriextract.cmd|31C82F7B43312620EBD87A7689B0B9E4A05AD00C31BEF4C385278597C3E0F4A8|v1.1 (with unblock step, LF line endings)'
)

function New-ZipFromList {
    param([string]$ZipPath, [object[]]$Items)   # each item: @{ Source; Entry }
    if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
    $fs = [System.IO.File]::Open($ZipPath, 'Create')
    $za = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($i in $Items) {
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $i.Source, $i.Entry, [System.IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally { $za.Dispose(); $fs.Dispose() }
}

# ---- manifest for the diagnostic tool ----------------------------------------------------------
$manifest = @()
$popplerFiles = Get-ChildItem (Join-Path $root 'poppler') -File
foreach ($f in $popplerFiles) {
    $manifest += 'file|poppler\{0}|{1}|{2}' -f $f.Name, $f.Length, (Get-FileHash $f.FullName -Algorithm SHA256).Hash
}
$ver = (Select-String -Path (Join-Path $root 'rodriextract.ps1') -Pattern "AppVersion\s*=\s*'([^']+)'" | Select-Object -First 1).Matches[0].Groups[1].Value
$manifest += $legacy | ForEach-Object { 'known|' + $_.Replace('|v', '|v') } | ForEach-Object { $_ }
foreach ($n in 'rodriextract.ps1', 'rodriextract.cmd') {
    $manifest += 'known|{0}|{1}|v{2} (current)' -f $n, (Get-FileHash (Join-Path $root $n) -Algorithm SHA256).Hash, $ver
}
$manifestPath = Join-Path $root 'diagnostic\diagnose-manifest.txt'
Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding ASCII

# ---- app zip -------------------------------------------------------------------------------------
$items = @()
foreach ($n in 'rodriextract.cmd', 'rodriextract-visible.cmd', 'rodriextract.ps1', 'README.txt') {
    $items += @{ Source = (Join-Path $root $n); Entry = "rodriextract/$n" }
}
foreach ($f in $popplerFiles) { $items += @{ Source = $f.FullName; Entry = "rodriextract/poppler/$($f.Name)" } }
# the troubleshooting tool lives in rodriextract\diagnostic\ (it looks for the app in its parent folder)
foreach ($f in Get-ChildItem (Join-Path $root 'diagnostic') -File | Where-Object { $_.Name -ne 'rodriextract-diagnostic.txt' }) {
    $items += @{ Source = $f.FullName; Entry = "rodriextract/diagnostic/$($f.Name)" }
}
Remove-Item (Join-Path $dist 'rodriextract-diagnostic.zip') -Force -ErrorAction SilentlyContinue
New-ZipFromList -ZipPath (Join-Path $dist 'rodriextract.zip') -Items $items

Get-ChildItem $dist -Filter *.zip | ForEach-Object { '{0}  {1:N1} MB' -f $_.Name, ($_.Length / 1MB) }
