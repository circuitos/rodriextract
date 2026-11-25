<#
.SYNOPSIS
    Extracts every embedded image above a minimum size from one PDF or a whole folder of PDFs,
    at the best quality the PDF allows.

.DESCRIPTION
    Uses poppler's `pdfimages` to pull images out of the PDF *as they are stored* (no re-rendering,
    no re-compression):
      - JPEG images are saved as the original .jpg bytes (bit-identical to what is in the PDF)
      - JPEG 2000 images are saved as the original .jp2 bytes (or lossless PNG with -JpxAsPng)
      - everything else (Flate/LZW/raw) is saved as lossless PNG (or TIFF for CMYK)
      - JBIG2 / CCITT fax images, which have no standalone file format, are saved as lossless PNG

    Images are saved to a subfolder next to each PDF:   <pdf folder>\<pdf name>_images\
    named  p<page>_img<number>.<ext>   (e.g. p003_img012.jpg).

    An image is kept when Width >= MinWidth AND Height >= MinHeight (pixels).

    Run with no arguments to get a menu that asks for a single file or a whole folder.

.PARAMETER Path
    A PDF file or a folder containing PDFs. Omit to be prompted (file / folder picker dialogs).

.PARAMETER MinWidth
    Minimum image width in pixels. Default 300.

.PARAMETER MinHeight
    Minimum image height in pixels. Default 300.

.PARAMETER Recurse
    When Path is a folder, also process PDFs in its subfolders.

.PARAMETER IncludeMasks
    Also save soft-masks / explicit masks (the separate alpha channel of an image). Off by default
    because they are just grey-scale helper images, not pictures. 1-bit "stencil" images (typical in
    scanned documents) are always treated as normal images.

.PARAMETER RemoveDuplicates
    Skip byte-identical images within the same PDF (logos or backgrounds repeated on every page).

.PARAMETER JpxAsPng
    Convert JPEG 2000 images to lossless PNG instead of keeping the .jp2 file (Windows cannot open .jp2 natively).

.PARAMETER PdfImagesPath
    Full path to pdfimages.exe if it is not on PATH.

.EXAMPLE
    .\Extract-PdfImages.ps1
    Interactive: choose file or folder, then the minimum size.

.EXAMPLE
    .\Extract-PdfImages.ps1 -Path 'C:\Docs\catalog.pdf' -MinWidth 800 -MinHeight 600

.EXAMPLE
    .\Extract-PdfImages.ps1 -Path 'C:\Docs' -Recurse -MinWidth 500 -MinHeight 500 -RemoveDuplicates
#>
[CmdletBinding()]
param(
    [string]$Path,
    [ValidateRange(0, 100000)][int]$MinWidth = 300,
    [ValidateRange(0, 100000)][int]$MinHeight = 300,
    [switch]$Recurse,
    [switch]$IncludeMasks,
    [switch]$RemoveDuplicates,
    [switch]$JpxAsPng,
    [string]$PdfImagesPath
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

function Find-PdfImagesExe {
    param([string]$Explicit)

    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit -PathType Leaf) { return (Resolve-Path -LiteralPath $Explicit).Path }
        throw "pdfimages not found at '$Explicit'."
    }

    $cmd = Get-Command pdfimages -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Common install locations: winget, scoop, chocolatey
    $found = @()
    $wingetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wingetRoot) {
        $found += Get-ChildItem -LiteralPath $wingetRoot -Filter 'oschwartz10612.Poppler*' -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter 'pdfimages.exe' -ErrorAction SilentlyContinue }
    }
    foreach ($p in @(
            (Join-Path $env:USERPROFILE 'scoop\apps\poppler\current\bin\pdfimages.exe'),
            (Join-Path $env:ProgramData 'chocolatey\bin\pdfimages.exe'))) {
        if (Test-Path -LiteralPath $p) { $found += Get-Item -LiteralPath $p }
    }
    if ($found.Count -gt 0) { return $found[0].FullName }
    return $null
}

function Get-PdfImagesExe {
    param([string]$Explicit)

    $exe = Find-PdfImagesExe -Explicit $Explicit
    if ($exe) { return $exe }

    Write-Host ''
    Write-Host 'pdfimages (part of Poppler) is required but was not found.' -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $answer = Read-Host 'Install Poppler now with winget? [Y/n]'
        if ($answer -notmatch '^\s*n') {
            & winget install --id oschwartz10612.Poppler -e --accept-source-agreements --accept-package-agreements
            $exe = Find-PdfImagesExe
            if ($exe) { return $exe }
        }
    }
    throw 'pdfimages.exe not found. Install Poppler for Windows (https://github.com/oschwartz10612/poppler-windows/releases) and either add its bin folder to PATH or pass -PdfImagesPath.'
}

function Select-Target {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.Application]::EnableVisualStyles()

    Write-Host ''
    Write-Host 'What do you want to process?'
    Write-Host '  [1] A single PDF file'
    Write-Host '  [2] A whole folder of PDFs'
    do { $choice = Read-Host 'Choose 1 or 2' } until ($choice -in '1', '2')

    # Hidden top-most owner so the dialog does not open behind the console window.
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    try {
        if ($choice -eq '1') {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title  = 'Select a PDF'
            $dlg.Filter = 'PDF files (*.pdf)|*.pdf|All files (*.*)|*.*'
        }
        else {
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Select a folder containing PDFs'
            $dlg.ShowNewFolderButton = $false
        }
        if ($dlg.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        if ($choice -eq '1') { return $dlg.FileName } else { return $dlg.SelectedPath }
    }
    finally { $owner.Dispose() }
}

function Invoke-Native {
    # Runs an exe capturing stdout/stderr separately (avoids PS 5.1 stderr-as-error behaviour).
    param([string]$Exe, [string[]]$Arguments)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Exe
    $psi.Arguments              = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc    = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $stdout  = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()

    [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $errTask.Result }
}

function Get-PdfImageList {
    # Parses `pdfimages -list`. Columns: page num type width height color comp bpc enc interp ...
    param([string]$Exe, [string]$PdfFile)

    $r = Invoke-Native -Exe $Exe -Arguments @('-list', $PdfFile)
    if ($r.ExitCode -ne 0) {
        $msg = $r.StdErr.Trim()
        if (-not $msg) { $msg = "exit code $($r.ExitCode)" }
        throw "pdfimages could not read the PDF: $msg"
    }

    $rows = @()
    foreach ($line in ($r.StdOut -split "`r?`n" | Select-Object -Skip 2)) {
        $t = $line.Trim() -split '\s+'
        if ($t.Count -ge 9 -and $t[0] -match '^\d+$') {
            $rows += [pscustomobject]@{
                Page   = [int]$t[0]
                Num    = [int]$t[1]
                Type   = $t[2]
                Width  = [int]$t[3]
                Height = [int]$t[4]
                Enc    = $t[8]
            }
        }
    }
    , $rows
}

function Export-PdfImages {
    param([System.IO.FileInfo]$Pdf, [string]$Exe)

    $outDir = Join-Path $Pdf.DirectoryName ($Pdf.BaseName + '_images')
    $work   = Join-Path ([System.IO.Path]::GetTempPath()) ('pdfimg_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null

    $result = [pscustomobject]@{ Pdf = $Pdf.FullName; Total = 0; Saved = 0; TooSmall = 0; Duplicates = 0; Output = $null; Error = $null }

    try {
        # Poppler on Windows can choke on non-ASCII paths, so work from a copy with a plain name.
        $src = $Pdf.FullName
        if ($src -match '[^\u0000-\u007F]') {
            $src = Join-Path $work 'input.pdf'
            Copy-Item -LiteralPath $Pdf.FullName -Destination $src
        }

        $rows = Get-PdfImageList -Exe $Exe -PdfFile $src
        $result.Total = $rows.Count

        # Decide which listed images qualify (keyed by pdfimages' image number).
        $wanted = @{}
        foreach ($row in $rows) {
            if (-not $IncludeMasks -and $row.Type -in 'mask', 'smask') { continue }
            if ($row.Width -ge $MinWidth -and $row.Height -ge $MinHeight) { $wanted[$row.Num] = $row }
            else { $result.TooSmall++ }
        }
        if ($wanted.Count -eq 0) { return $result }

        # Pass 1: native streams (JPEG stays JPEG, everything else lossless).
        $r = Invoke-Native -Exe $Exe -Arguments @('-all', $src, (Join-Path $work 'img'))
        if ($r.ExitCode -ne 0) { throw "pdfimages extraction failed: $($r.StdErr.Trim())" }

        # Pass 2: formats with no usable standalone file (JBIG2/CCITT, optionally JPX) -> PNG.
        $pngEnc = @('jbig2', 'ccitt')
        if ($JpxAsPng) { $pngEnc += 'jpx' }
        $needPng = @($wanted.Values | Where-Object { $pngEnc -contains $_.Enc })
        if ($needPng.Count -gt 0) {
            $r2 = Invoke-Native -Exe $Exe -Arguments @('-png', $src, (Join-Path $work 'png'))
            if ($r2.ExitCode -ne 0) { throw "pdfimages PNG extraction failed: $($r2.StdErr.Trim())" }
        }

        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($num in ($wanted.Keys | Sort-Object)) {
            $row = $wanted[$num]
            $prefix = 'img'
            if ($pngEnc -contains $row.Enc) { $prefix = 'png' }

            # Files are named <prefix>-<NNN>.<ext>, NNN = image number (zero padded to at least 3)
            $file = Get-ChildItem -LiteralPath $work -File |
                Where-Object { $_.BaseName -match ('^' + $prefix + '-0*' + $num + '$') -and $_.Extension -notin '.jb2g' } |
                Select-Object -First 1
            if (-not $file) { continue }

            if ($RemoveDuplicates) {
                $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                if (-not $seen.Add($hash)) { $result.Duplicates++; continue }
            }

            if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
            $name = 'p{0:D3}_img{1:D3}{2}' -f $row.Page, $num, $file.Extension.ToLower()
            Move-Item -LiteralPath $file.FullName -Destination (Join-Path $outDir $name) -Force
            $result.Saved++
        }
        if ($result.Saved -gt 0) { $result.Output = $outDir }
    }
    catch { $result.Error = $_.Exception.Message }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

    return $result
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

$interactive = -not $Path

if ($interactive) {
    $Path = Select-Target
    if (-not $Path) { Write-Host 'Nothing selected, exiting.'; return }

    if (-not $PSBoundParameters.ContainsKey('MinWidth')) {
        $v = Read-Host "Minimum image width in pixels [$MinWidth]"
        if ($v -match '^\d+$') { $MinWidth = [int]$v }
    }
    if (-not $PSBoundParameters.ContainsKey('MinHeight')) {
        $v = Read-Host "Minimum image height in pixels [$MinHeight]"
        if ($v -match '^\d+$') { $MinHeight = [int]$v }
    }
    if ((Test-Path -LiteralPath $Path -PathType Container) -and -not $PSBoundParameters.ContainsKey('Recurse')) {
        $v = Read-Host 'Include PDFs in subfolders? [y/N]'
        if ($v -match '^\s*y') { $Recurse = $true }
    }
}

if (-not (Test-Path -LiteralPath $Path)) { throw "Path not found: $Path" }
$item = Get-Item -LiteralPath $Path

if ($item.PSIsContainer) {
    $pdfs = @(Get-ChildItem -LiteralPath $item.FullName -Filter '*.pdf' -File -Recurse:$Recurse |
            Where-Object { $_.Extension -ieq '.pdf' })
}
else {
    if ($item.Extension -ine '.pdf') { throw "Not a PDF file: $($item.FullName)" }
    $pdfs = @($item)
}
if ($pdfs.Count -eq 0) { Write-Host 'No PDF files found.' -ForegroundColor Yellow; return }

$exe = Get-PdfImagesExe -Explicit $PdfImagesPath

Write-Host ''
Write-Host ("Processing {0} PDF(s); keeping images >= {1} x {2} px" -f $pdfs.Count, $MinWidth, $MinHeight) -ForegroundColor Cyan

$totalSaved = 0
$i = 0
foreach ($pdf in $pdfs) {
    $i++
    Write-Progress -Activity 'Extracting images' -Status $pdf.Name -PercentComplete (($i - 1) / $pdfs.Count * 100)

    $res = Export-PdfImages -Pdf $pdf -Exe $exe
    $totalSaved += $res.Saved

    if ($res.Error) {
        Write-Host ("[{0}/{1}] {2}: FAILED - {3}" -f $i, $pdfs.Count, $pdf.Name, $res.Error) -ForegroundColor Red
    }
    elseif ($res.Saved -gt 0) {
        $extra = ''
        if ($res.Duplicates -gt 0) { $extra = ", $($res.Duplicates) duplicate(s) skipped" }
        Write-Host ("[{0}/{1}] {2}: saved {3} of {4} image(s) ({5} too small{6}) -> {7}" -f $i, $pdfs.Count, $pdf.Name, $res.Saved, $res.Total, $res.TooSmall, $extra, $res.Output) -ForegroundColor Green
    }
    else {
        Write-Host ("[{0}/{1}] {2}: no images >= {3} x {4} ({5} image(s) in PDF)" -f $i, $pdfs.Count, $pdf.Name, $MinWidth, $MinHeight, $res.Total) -ForegroundColor DarkGray
    }
}
Write-Progress -Activity 'Extracting images' -Completed

Write-Host ''
Write-Host ("Done. {0} image(s) saved." -f $totalSaved) -ForegroundColor Cyan

if ($interactive) { Read-Host 'Press Enter to close' | Out-Null }
