<#
    rodriextract - pulls the pictures out of PDF files, at the best quality the PDF allows.

    Normally started by double-clicking rodriextract.cmd (nothing to install, no admin rights).
    Uses the bundled Poppler tools in the "poppler" folder (pdfimages.exe / pdfinfo.exe).

    -LoadOnly is a developer/test switch: builds the window but does not show it.
#>
param([switch]$LoadOnly)

$ErrorActionPreference = 'Stop'

$script:AppName      = 'rodriextract'
$script:AppVersion   = '1.2'
$script:Root         = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ChunkPages   = 20          # pages processed per step (drives the progress bar)
$script:Cancel       = $false
$script:Running      = $false
$script:CloseWhenDone = $false
$script:CurrentProc  = $null
$script:Selection    = @()
$script:OutputDirs   = New-Object System.Collections.ArrayList
$script:Silent       = $false      # tests: no message boxes
$script:LogFile      = Join-Path $env:LOCALAPPDATA 'rodriextract\rodriextract.log'

function Write-LogFile {
    param([string]$Line)
    try {
        $dir = Split-Path -Parent $script:LogFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $script:LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Line)
    }
    catch { }
}

# Any error that escapes below is logged and shown to the user instead of vanishing silently.
# Exit code 2 = "already told the user"; 1 = could not even show a message.
trap {
    $fatal = $_.Exception.Message
    Write-LogFile ("FATAL: " + $fatal + " | " + $_.ScriptStackTrace)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            ("rodriextract could not start.`r`n`r`n" + $fatal + "`r`n`r`nA log was saved to:`r`n" + $script:LogFile +
            "`r`n`r`nPlease send that file (and the diagnostic report, if you have one) to whoever gave you this program."),
            'rodriextract - error', 'OK', 'Error')
        exit 2
    }
    catch { exit 1 }
}

# Keep the log small, then leave a breadcrumb trail so a failed start can be diagnosed afterwards.
try { if ((Test-Path -LiteralPath $script:LogFile) -and ((Get-Item -LiteralPath $script:LogFile).Length -gt 512KB)) { Remove-Item -LiteralPath $script:LogFile -Force } } catch { }
Write-LogFile ("---- start v{0}  PS {1}  mode {2}  root {3}" -f $script:AppVersion, $PSVersionTable.PSVersion, $ExecutionContext.SessionState.LanguageMode, $script:Root)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
Write-LogFile 'windows forms loaded'

# =============================================================================================
# Small helpers
# =============================================================================================

function Show-Message {
    param([string]$Text, [string]$Icon = 'Information')
    if ($script:Silent) { Write-Host "[$Icon] $Text"; return }
    [void][System.Windows.Forms.MessageBox]::Show($Text, $script:AppName, 'OK', $Icon)
}

function Invoke-Guarded {
    # Runs a button handler; a failure is logged and shown rather than silently swallowed.
    param([scriptblock]$Block)
    try { & $Block }
    catch {
        Write-LogFile ("ERROR in handler: " + $_.Exception.Message + " | " + $_.ScriptStackTrace)
        Show-Message ("Something went wrong:`r`n`r`n" + $_.Exception.Message + "`r`n`r`nDetails were saved to:`r`n" + $script:LogFile) 'Error'
    }
}

function Write-UiLog {
    param([string]$Line)
    Write-LogFile $Line
    if ($script:txtLog) { $script:txtLog.AppendText($Line + "`r`n") }
    if ($script:Silent) { Write-Host $Line }
}

function Update-Ui { [System.Windows.Forms.Application]::DoEvents() }

function Find-Tool {
    param([string]$Name)
    foreach ($d in @((Join-Path $script:Root 'poppler'), $script:Root)) {
        $p = Join-Path $d "$Name.exe"
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Invoke-Tool {
    # Runs a command-line tool without a console window, keeping the UI responsive (and cancellable).
    param([string]$Exe, [string[]]$Arguments)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Exe
    $psi.Arguments              = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch {
        throw ("Windows refused to run '" + (Split-Path -Leaf $Exe) + "' (" + $_.Exception.Message + "). " +
            "Security software may be blocking the files in the 'poppler' folder.")
    }
    $script:CurrentProc = $proc
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    while (-not $proc.HasExited) {
        Update-Ui
        if ($script:Cancel) { try { $proc.Kill() } catch { } ; break }
        Start-Sleep -Milliseconds 25
    }
    $proc.WaitForExit()
    $script:CurrentProc = $null
    if ($script:Cancel) { throw 'RODRI_CANCELLED' }

    [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $outTask.Result; StdErr = $errTask.Result }
}

function Get-PageCount {
    param([string]$Src)
    $r = Invoke-Tool -Exe $script:PdfInfo -Arguments @($Src)
    if ($r.ExitCode -ne 0) {
        if ($r.ExitCode -lt 0 -or $r.ExitCode -ge 3221225472) {
            throw ("The extraction component (pdfinfo.exe) could not run - Windows error {0}. A file in the 'poppler' folder is probably missing or blocked by security software." -f $r.ExitCode)
        }
        if ($r.StdErr -match 'assword') { throw 'This PDF is password-protected.' }
        throw 'This PDF could not be read (it may be damaged).'
    }
    if ($r.StdOut -match '(?m)^Pages:\s+(\d+)') { return [int]$Matches[1] }
    throw 'Could not work out how many pages this PDF has.'
}

function Get-ImageList {
    # Parses `pdfimages -list` for a page range.
    # Columns: page num type width height color comp bpc enc interp ...
    param([string]$Src, [int]$First, [int]$Last)

    $r = Invoke-Tool -Exe $script:PdfImages -Arguments @('-list', '-f', "$First", '-l', "$Last", $Src)
    if ($r.ExitCode -ne 0) { throw "Could not read images on pages $First-$Last." }

    $rows = @()
    foreach ($line in ($r.StdOut -split "`r?`n" | Select-Object -Skip 2)) {
        $t = $line.Trim() -split '\s+'
        if ($t.Count -ge 9 -and $t[0] -match '^\d+$') {
            $rows += [pscustomobject]@{
                Page = [int]$t[0]; Num = [int]$t[1]; Type = $t[2]
                Width = [int]$t[3]; Height = [int]$t[4]; Enc = $t[8]; Idx = 0
            }
        }
    }
    , $rows
}

function Get-FreeFolder {
    # <name>_images, or <name>_images_2, _3 ... so earlier results are never overwritten.
    param([string]$Dir, [string]$BaseName)
    $path = Join-Path $Dir ($BaseName + '_images')
    $n = 2
    while (Test-Path -LiteralPath $path) { $path = Join-Path $Dir ("{0}_images_{1}" -f $BaseName, $n); $n++ }
    $path
}

function Get-PdfFiles {
    param([string[]]$Items, [bool]$Recurse)
    $list = @()
    foreach ($i in $Items) {
        if (Test-Path -LiteralPath $i -PathType Container) {
            $list += @(Get-ChildItem -LiteralPath $i -Filter '*.pdf' -File -Recurse:$Recurse |
                    Where-Object { $_.Extension -ieq '.pdf' })
        }
        elseif (Test-Path -LiteralPath $i -PathType Leaf) {
            $f = Get-Item -LiteralPath $i
            if ($f.Extension -ieq '.pdf') { $list += $f }
        }
    }
    $list | Sort-Object FullName -Unique
}

# =============================================================================================
# The extraction engine
# =============================================================================================

function Convert-Pdf {
    param([System.IO.FileInfo]$Pdf, [int]$MinW, [int]$MinH, [bool]$Dedupe)

    $res  = [pscustomobject]@{ Saved = 0; Total = 0; Small = 0; Dups = 0; Out = $null }
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('rodriextract_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null

    try {
        # Poppler on Windows can choke on non-ASCII paths, so work from a plainly-named copy.
        $src = $Pdf.FullName
        if ($src -match '[^\u0000-\u007F]') {
            $src = Join-Path $work 'input.pdf'
            Copy-Item -LiteralPath $Pdf.FullName -Destination $src
        }

        $pages = Get-PageCount -Src $src
        $script:pbFile.Maximum = [Math]::Max($pages, 1)
        $script:pbFile.Value   = 0

        $outDir = $null
        $seen   = New-Object 'System.Collections.Generic.HashSet[string]'
        $pngEnc = @('jbig2', 'ccitt', 'jpx')   # formats with no usable standalone file -> lossless PNG

        for ($start = 1; $start -le $pages; $start += $script:ChunkPages) {
            $end = [Math]::Min($start + $script:ChunkPages - 1, $pages)
            $script:lblFile.Text = "This PDF: pages $start-$end of $pages"
            Update-Ui

            $rows = Get-ImageList -Src $src -First $start -Last $end
            $res.Total += $rows.Count

            $perPage = @{}
            $wanted  = @{}
            foreach ($row in $rows) {
                $perPage[$row.Page] = 1 + [int]$perPage[$row.Page]
                $row.Idx = $perPage[$row.Page]
                if ($row.Type -in 'mask', 'smask') { continue }          # helper channels, not pictures
                if ($row.Width -ge $MinW -and $row.Height -ge $MinH) { $wanted[$row.Num] = $row }
                else { $res.Small++ }
            }

            if ($wanted.Count -gt 0) {
                $chunk = Join-Path $work "c$start"
                New-Item -ItemType Directory -Path $chunk | Out-Null

                # Pass 1: original streams (JPEG stays JPEG, the rest lossless)
                $r = Invoke-Tool -Exe $script:PdfImages -Arguments @('-all', '-f', "$start", '-l', "$end", $src, (Join-Path $chunk 'img'))
                if ($r.ExitCode -ne 0) { throw 'Extraction failed (the PDF may be damaged or restricted).' }

                # Pass 2: JBIG2 / CCITT / JPEG 2000 -> PNG
                if (@($wanted.Values | Where-Object { $pngEnc -contains $_.Enc }).Count -gt 0) {
                    $r2 = Invoke-Tool -Exe $script:PdfImages -Arguments @('-png', '-f', "$start", '-l', "$end", $src, (Join-Path $chunk 'png'))
                    if ($r2.ExitCode -ne 0) { throw 'Extraction failed (the PDF may be damaged or restricted).' }
                }

                $files = @(Get-ChildItem -LiteralPath $chunk -File)
                foreach ($num in ($wanted.Keys | Sort-Object)) {
                    $row    = $wanted[$num]
                    $prefix = 'img'
                    if ($pngEnc -contains $row.Enc) { $prefix = 'png' }

                    $file = $files | Where-Object { $_.BaseName -match ('^' + $prefix + '-0*' + $num + '$') } | Select-Object -First 1
                    if (-not $file) { continue }

                    if ($Dedupe) {
                        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                        if (-not $seen.Add($hash)) { $res.Dups++; continue }
                    }

                    if (-not $outDir) {
                        $outDir = Get-FreeFolder -Dir $Pdf.DirectoryName -BaseName $Pdf.BaseName
                        New-Item -ItemType Directory -Path $outDir | Out-Null
                    }
                    $name = 'page{0:D3}_image{1:D2}{2}' -f $row.Page, $row.Idx, $file.Extension.ToLower()
                    Move-Item -LiteralPath $file.FullName -Destination (Join-Path $outDir $name) -Force
                    $res.Saved++
                }
                Remove-Item -LiteralPath $chunk -Recurse -Force -ErrorAction SilentlyContinue
            }

            $script:pbFile.Value = $end
            Update-Ui
        }
        $res.Out = $outDir
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    $res
}

# =============================================================================================
# Window
# =============================================================================================

$script:PdfImages = Find-Tool 'pdfimages'
$script:PdfInfo   = Find-Tool 'pdfinfo'
if (-not $script:PdfImages -or -not $script:PdfInfo) {
    Show-Message ("rodriextract can't find its 'poppler' folder.`r`n`r`n" +
        "If you opened it from inside a zip file, please right-click the zip, choose 'Extract All...', " +
        "and run rodriextract.cmd from the extracted folder. Keep all the files together.") 'Error'
    exit 2
}
Write-LogFile ("tools found: " + $script:PdfImages)

$gray = [System.Drawing.SystemColors]::GrayText

$form = New-Object System.Windows.Forms.Form
$form.Text            = 'rodriextract'
$form.ClientSize      = New-Object System.Drawing.Size(620, 672)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9.5)
$form.AllowDrop       = $true

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 0, [int]$H = 0)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Location = New-Object System.Drawing.Point($X, $Y)
    if ($W -gt 0) { $l.Size = New-Object System.Drawing.Size($W, $H) } else { $l.AutoSize = $true }
    $l
}

$lblTitle = New-Label 'rodriextract' 18 10
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
$lblSub = New-Label 'Pulls the pictures out of PDF files, at the best quality available.' 22 52
$lblSub.ForeColor = $gray

# --- Step 1 ------------------------------------------------------------------------------
$gb1 = New-Object System.Windows.Forms.GroupBox
$gb1.Text = '1.  Choose what to process'
$gb1.Location = New-Object System.Drawing.Point(20, 84)
$gb1.Size = New-Object System.Drawing.Size(580, 128)

$btnFile = New-Object System.Windows.Forms.Button
$btnFile.Text = 'Choose PDF file(s)...'
$btnFile.Location = New-Object System.Drawing.Point(15, 26)
$btnFile.Size = New-Object System.Drawing.Size(265, 34)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = 'Choose a folder of PDFs...'
$btnFolder.Location = New-Object System.Drawing.Point(300, 26)
$btnFolder.Size = New-Object System.Drawing.Size(265, 34)

$lblTarget = New-Label 'Nothing chosen yet. You can also drag PDFs or a folder onto this window.' 15 68 550 22
$lblTarget.AutoEllipsis = $true
$lblTarget.ForeColor = $gray

$chkSub = New-Object System.Windows.Forms.CheckBox
$chkSub.Text = 'Also look inside sub-folders'
$chkSub.Location = New-Object System.Drawing.Point(15, 94)
$chkSub.AutoSize = $true

$gb1.Controls.AddRange(@($btnFile, $btnFolder, $lblTarget, $chkSub))

# --- Step 2 ------------------------------------------------------------------------------
$gb2 = New-Object System.Windows.Forms.GroupBox
$gb2.Text = '2.  Ignore small images'
$gb2.Location = New-Object System.Drawing.Point(20, 222)
$gb2.Size = New-Object System.Drawing.Size(580, 96)

$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Location = New-Object System.Drawing.Point(10, 22)
$flow.Size = New-Object System.Drawing.Size(560, 34)
$flow.WrapContents = $false

function New-FlowLabel([string]$t) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $t; $l.AutoSize = $true; $l.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 0)
    $l
}
function New-SizeBox {
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = 0; $n.Maximum = 100000; $n.Value = 300; $n.Width = 70
    $n.Margin = New-Object System.Windows.Forms.Padding(3, 4, 3, 0)
    $n
}
$nudW = New-SizeBox
$nudH = New-SizeBox
$flow.Controls.AddRange(@((New-FlowLabel 'Keep only images at least'), $nudW, (New-FlowLabel 'px wide and'), $nudH, (New-FlowLabel 'px tall')))

$lblHint = New-Label 'This skips icons, bullets and tiny logos. Set both to 0 to keep everything.' 15 62
$lblHint.ForeColor = $gray
$gb2.Controls.AddRange(@($flow, $lblHint))

# --- Options + buttons ---------------------------------------------------------------------
$chkDup = New-Object System.Windows.Forms.CheckBox
$chkDup.Text = 'Skip duplicate images (such as a logo repeated on every page)'
$chkDup.Location = New-Object System.Drawing.Point(24, 328)
$chkDup.AutoSize = $true
$chkDup.Checked = $true

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = 'Extract images'
$btnStart.Location = New-Object System.Drawing.Point(20, 360)
$btnStart.Size = New-Object System.Drawing.Size(400, 46)
$btnStart.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$btnStart.Enabled = $false

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'
$btnCancel.Location = New-Object System.Drawing.Point(430, 360)
$btnCancel.Size = New-Object System.Drawing.Size(170, 46)
$btnCancel.Enabled = $false

# --- Progress ------------------------------------------------------------------------------
$lblOverall = New-Label 'Ready.' 20 418 580 20
$pbOverall = New-Object System.Windows.Forms.ProgressBar
$pbOverall.Location = New-Object System.Drawing.Point(20, 440)
$pbOverall.Size = New-Object System.Drawing.Size(580, 22)

$lblFile = New-Label '' 20 470 580 20
$pbFile = New-Object System.Windows.Forms.ProgressBar
$pbFile.Location = New-Object System.Drawing.Point(20, 492)
$pbFile.Size = New-Object System.Drawing.Size(580, 22)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.Location = New-Object System.Drawing.Point(20, 526)
$txtLog.Size = New-Object System.Drawing.Size(580, 98)
$txtLog.BackColor = [System.Drawing.SystemColors]::Window
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = 'Open results folder'
$btnOpen.Location = New-Object System.Drawing.Point(20, 632)
$btnOpen.Size = New-Object System.Drawing.Size(200, 32)
$btnOpen.Enabled = $false

$lblFooter = New-Label ("rodriextract v{0}  -  uses Poppler (GPL)" -f $script:AppVersion) 300 640 300 20
$lblFooter.TextAlign = 'MiddleRight'
$lblFooter.ForeColor = $gray

$form.Controls.AddRange(@($lblTitle, $lblSub, $gb1, $gb2, $chkDup, $btnStart, $btnCancel,
        $lblOverall, $pbOverall, $lblFile, $pbFile, $txtLog, $btnOpen, $lblFooter))

# Share controls with the functions above
$script:txtLog = $txtLog; $script:pbFile = $pbFile; $script:lblFile = $lblFile

# =============================================================================================
# Behaviour
# =============================================================================================

function Set-Selection {
    param([string[]]$Paths)

    $valid = @($Paths | Where-Object {
            $_ -and ((Test-Path -LiteralPath $_ -PathType Container) -or
                ((Test-Path -LiteralPath $_ -PathType Leaf) -and ([System.IO.Path]::GetExtension($_) -ieq '.pdf')))
        })
    if ($valid.Count -eq 0) {
        Show-Message "That isn't a PDF file or a folder. Please choose a .pdf file or a folder that contains PDFs." 'Warning'
        return
    }
    $script:Selection = $valid
    if ($valid.Count -eq 1) { $lblTarget.Text = $valid[0] } else { $lblTarget.Text = "$($valid.Count) items selected" }
    $lblTarget.ForeColor = [System.Drawing.SystemColors]::WindowText
    $chkSub.Enabled = [bool]@($valid | Where-Object { Test-Path -LiteralPath $_ -PathType Container }).Count
    $btnStart.Enabled = $true
    $btnOpen.Enabled = $false
}

function Set-Busy {
    param([bool]$Busy)
    $gb1.Enabled = -not $Busy
    $gb2.Enabled = -not $Busy
    $chkDup.Enabled = -not $Busy
    $btnStart.Enabled = -not $Busy
    $btnCancel.Enabled = $Busy
    $form.AllowDrop = -not $Busy
}

function Start-Extraction {
    $minW   = [int]$nudW.Value
    $minH   = [int]$nudH.Value
    $dedupe = [bool]$chkDup.Checked
    $pdfs   = @(Get-PdfFiles -Items $script:Selection -Recurse ([bool]$chkSub.Checked))

    if ($pdfs.Count -eq 0) {
        Show-Message "No PDF files were found there.`r`n`r`nIf the PDFs are in sub-folders, tick 'Also look inside sub-folders'." 'Warning'
        return
    }

    $script:Cancel  = $false
    $script:Running = $true
    $script:OutputDirs.Clear()
    $txtLog.Clear()
    Set-Busy $true
    $pbOverall.Maximum = $pdfs.Count
    $pbOverall.Value = 0
    $pbFile.Value = 0
    $totalSaved = 0
    $done = 0
    $cancelled = $false

    Write-UiLog ("Started: {0} PDF(s), keeping images at least {1} x {2} px" -f $pdfs.Count, $minW, $minH)

    try {
        foreach ($pdf in $pdfs) {
            $done++
            $lblOverall.Text = "Overall: file $done of $($pdfs.Count)  -  $($pdf.Name)"
            $lblFile.Text = 'Reading PDF...'
            $pbFile.Value = 0
            Update-Ui

            try {
                $r = Convert-Pdf -Pdf $pdf -MinW $minW -MinH $minH -Dedupe $dedupe
                if ($r.Saved -gt 0) {
                    $totalSaved += $r.Saved
                    [void]$script:OutputDirs.Add($r.Out)
                    $extra = ''
                    if ($r.Dups -gt 0) { $extra = ", $($r.Dups) duplicate(s) skipped" }
                    Write-UiLog ("OK       {0}: {1} image(s) saved ({2} too small{3})" -f $pdf.Name, $r.Saved, $r.Small, $extra)
                }
                elseif ($r.Total -eq 0) {
                    Write-UiLog ("NONE     {0}: no images in this PDF" -f $pdf.Name)
                }
                else {
                    Write-UiLog ("NONE     {0}: {1} image(s) found, all smaller than {2} x {3}" -f $pdf.Name, $r.Total, $minW, $minH)
                }
            }
            catch {
                if ($_.Exception.Message -eq 'RODRI_CANCELLED') { throw }
                Write-UiLog ("SKIPPED  {0}: {1}" -f $pdf.Name, $_.Exception.Message)
            }
            $pbOverall.Value = $done
            Update-Ui
        }
    }
    catch {
        if ($_.Exception.Message -eq 'RODRI_CANCELLED') { $cancelled = $true }
        else {
            Write-UiLog ("ERROR: " + $_.Exception.Message)
            Show-Message ("Something went wrong:`r`n`r`n" + $_.Exception.Message + "`r`n`r`nDetails were saved to:`r`n" + $script:LogFile) 'Error'
        }
    }
    finally {
        $script:Running = $false
        Set-Busy $false
    }

    $lblFile.Text = ''
    if ($cancelled) {
        $lblOverall.Text = "Cancelled. $totalSaved image(s) were saved before stopping."
        Write-UiLog $lblOverall.Text
    }
    else {
        $lblOverall.Text = "Finished. $totalSaved image(s) saved."
        Write-UiLog $lblOverall.Text
        if ($totalSaved -gt 0) {
            Show-Message ("Done! $totalSaved image(s) saved.`r`n`r`nLook for a new folder next to each PDF, named after the PDF with '_images' on the end.") 'Information'
        }
        else {
            Show-Message ("No images at least $minW x $minH px were found.`r`n`r`nTry lowering the minimum size in step 2.") 'Information'
        }
    }
    $btnOpen.Enabled = ($script:OutputDirs.Count -gt 0)
    if ($script:CloseWhenDone) { $form.Close() }
}

$btnFile.Add_Click({ Invoke-Guarded {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = 'Choose one or more PDF files'
            $dlg.Filter = 'PDF files (*.pdf)|*.pdf'
            $dlg.Multiselect = $true
            if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { Set-Selection $dlg.FileNames }
        } })

$btnFolder.Add_Click({ Invoke-Guarded {
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Choose a folder that contains PDF files'
            $dlg.ShowNewFolderButton = $false
            if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { Set-Selection @($dlg.SelectedPath) }
        } })

$form.Add_DragEnter({
        param($s, $e)
        if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy }
    })
$form.Add_DragDrop({
        param($s, $e)
        $dropped = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
        Invoke-Guarded { Set-Selection $dropped }
    })

$btnStart.Add_Click({ Invoke-Guarded { Start-Extraction } })

$btnCancel.Add_Click({
        $script:Cancel = $true
        $btnCancel.Enabled = $false
        $lblOverall.Text = 'Cancelling...'
    })

$btnOpen.Add_Click({
        if ($script:OutputDirs.Count -gt 0) {
            if ($script:OutputDirs.Count -eq 1) { $target = $script:OutputDirs[0] }
            else { $target = Split-Path -Parent $script:OutputDirs[0] }
            Start-Process -FilePath $target
        }
    })

$form.Add_FormClosing({
        param($s, $e)
        if ($script:Running) {
            $e.Cancel = $true
            $script:Cancel = $true
            $script:CloseWhenDone = $true
        }
    })

$form.Add_Shown({ Write-LogFile 'window is showing' })
Write-LogFile 'window built'

if (-not $LoadOnly) {
    try { [void]$form.ShowDialog(); Write-LogFile 'window closed normally' }
    catch {
        Write-LogFile ("FATAL in window: " + $_.Exception.Message + " | " + $_.ScriptStackTrace)
        Show-Message ("rodriextract hit an unexpected problem and has to close.`r`n`r`n" + $_.Exception.Message + "`r`n`r`nDetails: " + $script:LogFile) 'Error'
        exit 2
    }
    exit 0
}
