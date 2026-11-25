<#
    rodriextract diagnostic tool - collects everything needed to work out why rodriextract
    does not start on a particular PC, and writes it to a single text file.
    Run it through rodriextract-diagnose.cmd (double-click).  Nothing is changed on the PC
    except temporary files, which are deleted.
#>
param([string]$Report, [string]$Stage1)

$ErrorActionPreference = 'Continue'
$ToolVersion = '1.0'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Report) { $Report = Join-Path $here 'rodriextract-diagnostic.txt' }
$script:Lines    = @()
$script:Findings = @()
$script:AppDir   = $null
$script:Started  = Get-Date
$script:Work     = Join-Path $env:TEMP ('rodriextract_diag_' + (Get-Random))

# ---------------------------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------------------------
function W { param([string]$Text = '') $script:Lines += $Text }

function Add-Finding { param([string]$Text) $script:Findings += $Text }

function Save-Report {
    $head = @(
        "rodriextract diagnostic report  (tool v$ToolVersion)",
        ("Generated: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        'NOTE: this report contains the computer name, user name and file paths of this PC.',
        ('-' * 78), 'AUTOMATIC FINDINGS', ('-' * 78))
    if ($script:Findings.Count -eq 0) { $head += '(nothing obviously wrong detected so far - read the sections below)' }
    else { foreach ($f in $script:Findings) { $head += "* $f" } }
    $head += ''
    try { Set-Content -LiteralPath $Report -Value ($head + $script:Lines) -Encoding UTF8 } catch { }
}

function Invoke-Section {
    param([string]$Title, [scriptblock]$Body)
    Write-Host ("  - " + $Title)
    W ''; W ('=' * 78); W $Title; W ('=' * 78)
    try { & $Body } catch { W ("!! this section failed: " + $_.Exception.Message) }
    Save-Report
}

function Format-ExitCode {
    param($Code)
    if ($null -eq $Code) { return 'n/a' }
    $u = [int64]$Code
    if ($u -lt 0) { $u += 4294967296 }      # show negative codes the way Windows does (0xC0000135 etc.)
    $hex = '0x{0:X8}' -f $u
    $meaning = switch ($u) {
        0          { 'success' }
        1          { 'general error' }
        2          { 'handled error (the app showed its own message)' }
        3221225781 { 'DLL NOT FOUND (a required file is missing)' }
        3221225595 { 'bad image format (corrupt or wrong-architecture file)' }
        3221225506 { 'ACCESS DENIED (blocked by permissions/security software)' }
        3221225794 { 'DLL initialisation failed (often security software injecting into the process)' }
        3221225477 { 'access violation (crash)' }
        3221226505 { 'fail-fast / stack buffer overrun (crash or forced termination)' }
        4294967295 { 'process was terminated (-1) - typical of being killed by another program' }
        3221225786 { 'terminated by Ctrl+C / forced close' }
        default    { '' }
    }
    "$Code ($hex) $meaning".Trim()
}

function Invoke-Proc {
    # Starts a program, waits up to TimeoutSec, captures output/exit code. Never throws.
    param([string]$File, [string]$ArgString, [int]$TimeoutSec = 30, [string]$Window = 'Hidden')
    $o = Join-Path $env:TEMP ('rdx_' + (Get-Random) + '.out')
    $e = Join-Path $env:TEMP ('rdx_' + (Get-Random) + '.err')
    $r = [pscustomobject]@{ Started = $false; Exited = $false; Code = $null; Seconds = 0; Title = ''; Out = ''; Err = ''; StartError = $null }
    $t0 = Get-Date
    try {
        $sp = @{ FilePath = $File; PassThru = $true; WindowStyle = $Window; RedirectStandardOutput = $o; RedirectStandardError = $e }
        if ($ArgString) { $sp.ArgumentList = $ArgString }
        $p = Start-Process @sp
        $r.Started = $true
        $null = $p.Handle
        while (-not $p.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
            Start-Sleep -Milliseconds 300
            try { $p.Refresh(); if ($p.MainWindowTitle) { $r.Title = $p.MainWindowTitle } } catch { }
        }
        if ($p.HasExited) { $p.WaitForExit(); $r.Exited = $true; $r.Code = $p.ExitCode }
        else { try { $p.Kill() } catch { } }
    }
    catch { $r.StartError = $_.Exception.Message }
    $r.Seconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    try { $r.Out = (Get-Content -LiteralPath $o -Raw -ErrorAction SilentlyContinue) } catch { }
    try { $r.Err = (Get-Content -LiteralPath $e -Raw -ErrorAction SilentlyContinue) } catch { }
    Remove-Item -LiteralPath $o, $e -Force -ErrorAction SilentlyContinue
    if ($null -eq $r.Out) { $r.Out = '' }
    if ($null -eq $r.Err) { $r.Err = '' }
    $r
}

function Write-ProcResult {
    param($R, [string]$Label)
    if ($R.StartError) { W "${Label}: COULD NOT START: $($R.StartError)"; return }
    if ($R.Exited) { W "${Label}: exited after $($R.Seconds)s, exit code $(Format-ExitCode $R.Code)" }
    else { W "${Label}: still running after $($R.Seconds)s (stopped by this tool)" }
    if ($R.Title) { W "    window title seen: '$($R.Title)'" }
    if ($R.Out.Trim()) { W '    --- output ---'; foreach ($l in ($R.Out.Trim() -split "`r?`n" | Select-Object -First 40)) { W "    $l" } }
    if ($R.Err.Trim()) { W '    --- errors ---'; foreach ($l in ($R.Err.Trim() -split "`r?`n" | Select-Object -First 40)) { W "    $l" } }
}

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
New-Item -ItemType Directory -Path $script:Work -Force | Out-Null

Write-Host ''
Write-Host 'Running checks...'

# ---------------------------------------------------------------------------------------------
Invoke-Section 'Basic checks done by the launcher (plain cmd, before PowerShell)' {
    if ($Stage1 -and (Test-Path -LiteralPath $Stage1)) {
        foreach ($l in (Get-Content -LiteralPath $Stage1 -Encoding Oem)) { W $l }
    }
    else { W '(not available)' }
}

# ---------------------------------------------------------------------------------------------
Invoke-Section 'System and PowerShell' {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) { W "OS: $($os.Caption)  version $($os.Version)  build $($os.BuildNumber)  $($os.OSArchitecture)" }
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) { W "Computer: $($cs.Name)  domain-joined: $($cs.PartOfDomain)  domain: $($cs.Domain)  model: $($cs.Model)" }
    W "User: $env:USERDOMAIN\$env:USERNAME"
    W "PowerShell: $($PSVersionTable.PSVersion)  edition $($PSVersionTable.PSEdition)"
    $mode = $ExecutionContext.SessionState.LanguageMode
    W "Language mode: $mode"
    if ("$mode" -ne 'FullLanguage') {
        Add-Finding "PowerShell is in '$mode' mode. In this mode rodriextract's window cannot be created (usually enforced by AppLocker/WDAC/security software). IT would need to allow it."
    }
    try { W "64-bit process: $([Environment]::Is64BitProcess)   64-bit OS: $([Environment]::Is64BitOperatingSystem)" } catch { }
    try { W ("Running as administrator: " + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) } catch { }
    $net = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
    if ($net) { W ".NET Framework 4.x release: $($net.Release)  (528040 or higher = 4.8)" }
    W ''
    W 'Execution policy (Get-ExecutionPolicy -List):'
    $pol = Get-ExecutionPolicy -List
    foreach ($p in $pol) {
        W ("    {0,-14} {1}" -f $p.Scope, $p.ExecutionPolicy)
        if (($p.Scope -in 'MachinePolicy', 'UserPolicy') -and "$($p.ExecutionPolicy)" -notin 'Undefined', 'Unrestricted', 'Bypass') {
            Add-Finding "A Group Policy sets the PowerShell execution policy ($($p.Scope) = $($p.ExecutionPolicy)). Such a policy overrides the '-ExecutionPolicy Bypass' used by rodriextract, so scripts may be refused."
        }
    }
}

# ---------------------------------------------------------------------------------------------
Invoke-Section 'Where is rodriextract?' {
    $cands = @($here, (Split-Path $here -Parent), (Join-Path (Split-Path $here -Parent) 'rodriextract'))
    foreach ($base in @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Documents", $env:OneDrive, "$env:OneDrive\Desktop", "$env:OneDrive\Documents")) {
        if ($base) { $cands += (Join-Path $base 'rodriextract') }
    }
    $found = @($cands | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'rodriextract.ps1')) } | Select-Object -Unique)
    if ($found.Count -eq 0) {
        foreach ($base in @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Documents", $env:OneDrive)) {
            if ($base -and (Test-Path -LiteralPath $base)) {
                $found += @(Get-ChildItem -LiteralPath $base -Filter 'rodriextract.ps1' -Recurse -Depth 3 -ErrorAction SilentlyContinue | ForEach-Object { $_.DirectoryName })
            }
        }
    }
    if ($found.Count -eq 0) {
        W 'rodriextract.ps1 was NOT found near this tool. Extract the diagnostic zip INTO the rodriextract folder and run again.'
        Add-Finding 'The rodriextract app folder was not found (or rodriextract.ps1 was deleted - possibly by antivirus). App-specific tests were skipped.'
        return
    }
    $script:AppDir = $found[0]
    W "Using app folder: $($script:AppDir)"
    if ($found.Count -gt 1) { W 'Other copies found:'; $found | Select-Object -Skip 1 | ForEach-Object { W "    $_" } }

    $p = $script:AppDir
    W "Path length: $($p.Length) characters"
    if ($p -like '\\*') { W 'Located on a network share (UNC path).'; Add-Finding 'The app is on a network share. cmd.exe and PowerShell often refuse to run from UNC paths: copy the folder to a local drive (e.g. C:\Users\<name>\rodriextract).' }
    if ($p -match 'OneDrive|SharePoint') { W 'Located inside OneDrive/SharePoint sync folder (files may be cloud-only placeholders).' }
    if ($p -match '\\Temp\\|Temp1_|\.zip') { Add-Finding 'The app appears to be running from a temporary location or from inside a zip. Extract the zip fully first.' }
    if ($p -match '[^\u0000-\u007F]') { W 'Path contains non-ASCII characters.' }
    if ($p -match '[&%!^()]') { W 'Path contains special characters (& % ! ^ ( ) ) that can confuse .cmd files.'; Add-Finding 'The folder path has special characters (& % ! ^ or brackets). Moving the folder to a simple path like C:\rodriextract is worth trying.' }
    if ($p.Length -gt 150) { Add-Finding 'The folder path is very long. Move it to a short path like C:\rodriextract.' }
    try {
        $tf = Join-Path $p ('write_test_' + (Get-Random) + '.tmp')
        Set-Content -LiteralPath $tf -Value 'x' -ErrorAction Stop
        Remove-Item -LiteralPath $tf -Force
        W 'App folder is writable: yes'
    }
    catch { W "App folder is writable: NO ($($_.Exception.Message))" }
}

# ---------------------------------------------------------------------------------------------
Invoke-Section 'Are all files present and unmodified? (antivirus often deletes or changes files)' {
    if (-not $script:AppDir) { W '(skipped: app folder not found)'; return }
    $man = Join-Path $here 'diagnose-manifest.txt'
    if (-not (Test-Path -LiteralPath $man)) { W '(diagnose-manifest.txt missing from the diagnostic folder)'; return }

    $missing = @(); $changed = @(); $ok = 0
    foreach ($line in (Get-Content -LiteralPath $man)) {
        $f = $line -split '\|'
        if ($f[0] -eq 'file' -and $f.Count -ge 4) {
            $path = Join-Path $script:AppDir $f[1]
            if (-not (Test-Path -LiteralPath $path)) { $missing += $f[1]; continue }
            $item = Get-Item -LiteralPath $path
            if ($item.Length -ne [int64]$f[2]) { $changed += "$($f[1]) (size $($item.Length), expected $($f[2]))"; continue }
            $h = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
            if ($h -and $h -ne $f[3]) { $changed += "$($f[1]) (contents differ)"; continue }
            $ok++
        }
    }
    W "Files OK: $ok    missing: $($missing.Count)    changed: $($changed.Count)"
    if ($missing.Count) { W 'MISSING:'; $missing | ForEach-Object { W "    $_" } }
    if ($changed.Count) { W 'CHANGED:'; $changed | ForEach-Object { W "    $_" } }
    if ($missing.Count) { Add-Finding "$($missing.Count) bundled file(s) are MISSING from the app folder ($($missing[0]) ...). This is the classic sign of antivirus quarantining files during/after unzipping." }
    if ($changed.Count) { Add-Finding "$($changed.Count) bundled file(s) differ from the originals (could be antivirus rewriting them, or a damaged download)." }

    W ''
    foreach ($name in 'rodriextract.ps1', 'rodriextract.cmd') {
        $path = Join-Path $script:AppDir $name
        if (-not (Test-Path -LiteralPath $path)) { W "$name : MISSING"; Add-Finding "$name is missing from the app folder."; continue }
        $h = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $label = 'UNKNOWN version (edited?)'
        foreach ($line in (Get-Content -LiteralPath $man)) {
            $f = $line -split '\|'
            if ($f[0] -eq 'known' -and $f[1] -eq $name -and $f[2] -eq $h) { $label = $f[3] }
        }
        W "$name : $label"
    }

    W ''
    W 'Internet "Mark of the Web" flag on key files:'
    foreach ($rel in 'rodriextract.cmd', 'rodriextract.ps1', 'poppler\pdfimages.exe') {
        $path = Join-Path $script:AppDir $rel
        if (Test-Path -LiteralPath $path) {
            $z = Get-Content -LiteralPath $path -Stream Zone.Identifier -ErrorAction SilentlyContinue
            if ($z) { W "    $rel : flagged ($((($z | Where-Object { $_ -match 'ZoneId' }) -join ' ')))" } else { W "    $rel : not flagged" }
        }
    }
    W ''
    W 'Top-level listing:'
    Get-ChildItem -LiteralPath $script:AppDir -Force | ForEach-Object { W ("    {0,-32} {1,12:N0}  {2}" -f $_.Name, $(if ($_.PSIsContainer) { 0 } else { $_.Length }), $_.Attributes) }
}

# ---------------------------------------------------------------------------------------------
Invoke-Section 'Security software and restrictions' {
    W 'Antivirus products registered with Windows Security Center:'
    $av = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)
    if ($av.Count -eq 0) { W '    (none reported / not available on this edition)' }
    foreach ($a in $av) { W "    $($a.displayName)   state=$($a.productState)" }

    W ''
    W 'Security-related services that are installed:'
    $pat = 'Defender|Sense|CrowdStrike|Falcon|Sentinel|Sophos|McAfee|Trellix|Symantec|Norton|Trend Micro|ESET|Kaspersky|Bitdefender|Carbon Black|Cylance|Cortex|Traps|Zscaler|Forcepoint|Avast|AVG |Malwarebytes|Elastic|Tanium|Netskope|Ivanti|AppSense|Airlock|Threatlocker|Beyond ?Trust|Cisco Secure|AMP|Webroot|FireEye|Trellix'
    $svcs = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $pat -or $_.Name -match $pat })
    if ($svcs.Count -eq 0) { W '    (none matched)' }
    foreach ($s in $svcs) { W ("    {0,-10} {1}" -f $s.Status, $s.DisplayName) }

    W ''
    W 'Microsoft Defender status:'
    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($mp) {
        W "    AMServiceEnabled=$($mp.AMServiceEnabled)  RealTimeProtection=$($mp.RealTimeProtectionEnabled)  AntivirusEnabled=$($mp.AntivirusEnabled)  Tamper=$($mp.IsTamperProtected)"
        W "    Signatures: $($mp.AntivirusSignatureVersion)  updated $($mp.AntivirusSignatureLastUpdated)"
    }
    else { W '    (Get-MpComputerStatus not available - Defender may not be the active antivirus)' }
    $pref = Get-MpPreference -ErrorAction SilentlyContinue
    if ($pref) {
        W "    Attack Surface Reduction rules configured: $(@($pref.AttackSurfaceReductionRules_Ids).Count)"
        $ids = @($pref.AttackSurfaceReductionRules_Ids); $acts = @($pref.AttackSurfaceReductionRules_Actions)
        for ($i = 0; $i -lt $ids.Count; $i++) { W "        $($ids[$i])  action=$($acts[$i])  (1=block, 2=audit)" }
        W "    PUA protection: $($pref.PUAProtection)   Cloud block level: $($pref.CloudBlockLevel)"
    }
    $det = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Sort-Object InitialDetectionTime -Descending | Select-Object -First 10)
    if ($det.Count) {
        W '    Recent Defender detections on this PC:'
        foreach ($d in $det) { W "        $($d.InitialDetectionTime)  $(($d.Resources | Select-Object -First 2) -join '; ')" }
    }

    W ''
    W 'Application control (AppLocker / WDAC / Software Restriction):'
    $svc = Get-Service AppIDSvc -ErrorAction SilentlyContinue
    if ($svc) { W "    AppLocker service (AppIDSvc): $($svc.Status), start type $($svc.StartType)" }
    $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    if ($dg) {
        W "    WDAC code-integrity policy (kernel): $($dg.CodeIntegrityPolicyEnforcementStatus)   user mode: $($dg.UsermodeCodeIntegrityPolicyEnforcementStatus)   (0=off 1=audit 2=ENFORCED)"
        if ($dg.UsermodeCodeIntegrityPolicyEnforcementStatus -eq 2) { Add-Finding 'Windows Defender Application Control (WDAC) is ENFORCED for user mode: only approved programs/scripts run. rodriextract probably needs to be allow-listed by IT.' }
    }
    if (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers') { W '    Software Restriction Policies are configured on this PC.' }
    try {
        $pol = Get-AppLockerPolicy -Effective -ErrorAction Stop
        $n = @($pol.RuleCollections).Count
        W "    AppLocker effective policy has $n rule collection(s)."
        if ($n -gt 0 -and $script:AppDir) {
            $files = @('rodriextract.cmd', 'rodriextract.ps1', 'poppler\pdfimages.exe', 'poppler\pdfinfo.exe', 'poppler\poppler.dll') | ForEach-Object { Join-Path $script:AppDir $_ } | Where-Object { Test-Path -LiteralPath $_ }
            foreach ($res in ($files | ForEach-Object { $pol | Test-AppLockerPolicy -Path $_ -User Everyone -ErrorAction SilentlyContinue })) {
                W "        $($res.FilePath) -> $($res.PolicyDecision)"
                if ("$($res.PolicyDecision)" -match 'Denied') { Add-Finding "AppLocker would DENY: $($res.FilePath). IT needs to allow rodriextract's folder." }
            }
        }
    }
    catch { W "    AppLocker policy: not available ($($_.Exception.Message))" }

    W ''
    W 'Security-related processes currently running:'
    $procPat = 'MsMpEng|MsSense|SenseIR|CSFalcon|csagent|Sentinel|Cylance|CbDefense|RepMgr|carbonblack|Sophos|SAV|mcshield|mfemms|masvc|ccSvcHst|Smc|tmbmsrv|coreServiceShell|PccNTMon|ekrn|avp|avgsvc|AvastSvc|bdagent|WRSA|ZSA|Zscaler|Traps|cyserver|elastic|Tanium|epwd|epag|McAfee|Trellix'
    $pr = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $procPat } | Select-Object -ExpandProperty ProcessName -Unique)
    if ($pr.Count) { W ("    " + ($pr -join ', ')) } else { W '    (none matched the known list)' }
}

# ---------------------------------------------------------------------------------------------
Invoke-Section 'Poppler tools (the programs that actually extract the images)' {
    if (-not $script:AppDir) { W '(skipped: app folder not found)'; return }
    $pdfinfo = Join-Path $script:AppDir 'poppler\pdfinfo.exe'
    $pdfimages = Join-Path $script:AppDir 'poppler\pdfimages.exe'
    foreach ($t in $pdfinfo, $pdfimages) {
        if (-not (Test-Path -LiteralPath $t)) { W "$t : MISSING"; Add-Finding "$(Split-Path $t -Leaf) is missing (likely removed by antivirus)."; continue }
        $r = Invoke-Proc -File $t -ArgString '-v' -TimeoutSec 20
        Write-ProcResult $r "$(Split-Path $t -Leaf) -v"
        if ($r.Exited -and $r.Code -ne 0) { Add-Finding "$(Split-Path $t -Leaf) fails to run: exit code $(Format-ExitCode $r.Code)." }
        if (-not $r.Started) { Add-Finding "$(Split-Path $t -Leaf) could not be started at all: $($r.StartError)" }
    }
    $sample = Join-Path $here 'diagnose-sample.pdf'
    if ((Test-Path -LiteralPath $sample) -and (Test-Path -LiteralPath $pdfimages)) {
        $wd = Join-Path $script:Work 'tools'; New-Item -ItemType Directory -Path $wd -Force | Out-Null
        Copy-Item -LiteralPath $sample -Destination (Join-Path $wd 'sample.pdf')
        $r = Invoke-Proc -File $pdfinfo -ArgString ('"' + (Join-Path $wd 'sample.pdf') + '"') -TimeoutSec 30
        Write-ProcResult $r 'pdfinfo on sample.pdf'
        $r = Invoke-Proc -File $pdfimages -ArgString ('-list "' + (Join-Path $wd 'sample.pdf') + '"') -TimeoutSec 30
        Write-ProcResult $r 'pdfimages -list on sample.pdf'
        $r = Invoke-Proc -File $pdfimages -ArgString ('-all "' + (Join-Path $wd 'sample.pdf') + '" "' + (Join-Path $wd 'out') + '"') -TimeoutSec 30
        Write-ProcResult $r 'pdfimages -all on sample.pdf'
        $outs = @(Get-ChildItem -LiteralPath $wd -Filter 'out-*' -ErrorAction SilentlyContinue)
        W "    images produced: $($outs.Count) (expected 1)"
        if ($outs.Count -ne 1) { Add-Finding 'pdfimages ran but did not produce the expected image from the test PDF.' }
    }
}

# ---------------------------------------------------------------------------------------------
Invoke-Section 'Can PowerShell show a window? (a few windows may flash on screen)' {
    $r = Invoke-Proc -File $psExe -ArgString '-NoProfile -Command "''PS_OK''"' -TimeoutSec 30
    Write-ProcResult $r 'Baseline: powershell -Command'
    $baseOk = ($r.Exited -and $r.Code -eq 0 -and $r.Out -match 'PS_OK')
    if (-not $baseOk) { Add-Finding 'Even a trivial PowerShell command does not run properly when started from here: PowerShell itself is blocked or being killed.' }

    $ts = Join-Path $script:Work 'winforms-test.ps1'
    Set-Content -LiteralPath $ts -Encoding ASCII -Value @'
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.Form
$f.Text = 'rodriextract diagnostic window'
$f.Size = New-Object System.Drawing.Size(360, 120)
$f.StartPosition = 'CenterScreen'
$t = New-Object System.Windows.Forms.Timer
$t.Interval = 1500
$t.Add_Tick({ $t.Stop(); $f.Close() })
$t.Start()
[void]$f.ShowDialog()
'FORM_OK'
exit 0
'@
    $tsq = '"' + $ts + '"'
    $a = Invoke-Proc -File $psExe -ArgString "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File $tsq" -TimeoutSec 30
    Write-ProcResult $a 'Variant A (exactly like rodriextract.cmd: hidden console + Bypass)'
    $b = Invoke-Proc -File $psExe -ArgString "-NoProfile -ExecutionPolicy Bypass -STA -File $tsq" -TimeoutSec 30 -Window Normal
    Write-ProcResult $b 'Variant B (visible console + Bypass)'
    $c = Invoke-Proc -File $psExe -ArgString "-NoProfile -STA -WindowStyle Hidden -File $tsq" -TimeoutSec 30
    Write-ProcResult $c 'Variant C (hidden console, no Bypass flag)'

    $aOk = ($a.Out -match 'FORM_OK'); $bOk = ($b.Out -match 'FORM_OK'); $cOk = ($c.Out -match 'FORM_OK')
    W ''
    W "Summary: A=$aOk  B=$bOk  C=$cOk"
    if ($baseOk) {
        if ($aOk) { W 'A window can be created exactly the way rodriextract.cmd does it.' }
        elseif ($bOk) { Add-Finding 'A window works when the console is VISIBLE but not when launched hidden: security software is probably blocking the hidden-window launch. Use rodriextract-visible.cmd as a workaround.' }
        elseif ($cOk) { Add-Finding 'A window works WITHOUT the "-ExecutionPolicy Bypass" flag but not with it: security software/policy dislikes that flag.' }
        else { Add-Finding 'PowerShell runs, but a script that creates a window fails in all launch variants (see errors above): likely Constrained Language Mode, AppLocker/WDAC script rules, or security software.' }
    }
}

# ---------------------------------------------------------------------------------------------
Invoke-Section "rodriextract's own engine on the sample PDF (no window)" {
    if (-not $script:AppDir) { W '(skipped: app folder not found)'; return }
    $wd = Join-Path $script:Work 'engine'; New-Item -ItemType Directory -Path $wd -Force | Out-Null
    $sample = Join-Path $here 'diagnose-sample.pdf'
    if (-not (Test-Path -LiteralPath $sample)) { W '(diagnose-sample.pdf missing)'; return }
    Copy-Item -LiteralPath $sample -Destination (Join-Path $wd 'sample.pdf')
    $app = (Join-Path $script:AppDir 'rodriextract.ps1') -replace "'", "''"
    $sp = (Join-Path $wd 'sample.pdf') -replace "'", "''"
    $ts = Join-Path $script:Work 'engine-test.ps1'
    Set-Content -LiteralPath $ts -Encoding ASCII -Value @"
`$ErrorActionPreference = 'Stop'
. '$app' -LoadOnly
`$script:Silent = `$true
Set-Selection @('$sp')
Start-Extraction
"@
    $r = Invoke-Proc -File $psExe -ArgString ('-NoProfile -ExecutionPolicy Bypass -STA -File "' + $ts + '"') -TimeoutSec 60
    Write-ProcResult $r 'Engine test'
    $outs = @(Get-ChildItem -LiteralPath $wd -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '_images' })
    W "    images produced: $($outs.Count) (expected 1)"
    if ($outs.Count -ne 1) { Add-Finding "The app's own engine did not produce the expected output on the test PDF (see 'Engine test' errors)." }
}

# ---------------------------------------------------------------------------------------------
Invoke-Section 'The real thing: start rodriextract exactly as the launcher does, and watch it for 10 seconds' {
    if (-not $script:AppDir) { W '(skipped: app folder not found)'; return }
    $app = Join-Path $script:AppDir 'rodriextract.ps1'
    $logFile = Join-Path $env:LOCALAPPDATA 'rodriextract\rodriextract.log'
    $before = 0
    if (Test-Path -LiteralPath $logFile) { $before = @(Get-Content -LiteralPath $logFile).Count }
    $r = Invoke-Proc -File $psExe -ArgString ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $app + '"') -TimeoutSec 10
    Write-ProcResult $r 'Real launch'
    $newLog = @()
    if (Test-Path -LiteralPath $logFile) { $newLog = @(Get-Content -LiteralPath $logFile | Select-Object -Skip $before) }
    $fatal = @($newLog | Where-Object { $_ -match 'FATAL|ERROR' })
    if ($r.Exited) { Add-Finding "rodriextract EXITED by itself within $($r.Seconds)s with exit code $(Format-ExitCode $r.Code) - this reproduces the problem. See 'Real launch' output and the app log below." }
    elseif ($fatal.Count) { Add-Finding "rodriextract started but reported an error: $($fatal[0].Trim())" }
    elseif ($r.Title -ne 'rodriextract') { Add-Finding "rodriextract kept running but its main window was not seen (title seen: '$($r.Title)')." }
    else { W '    => It started and stayed open: the app works on this PC when launched this way.' }
    W ''
    W 'App log lines written during this test:'
    if ($newLog.Count) { $newLog | ForEach-Object { W "    $_" } }
    else {
        W '    (nothing new in the log; versions before 1.1 only log when extracting)'
        if ($r.Exited -and -not (Test-Path -LiteralPath $logFile)) { Add-Finding 'No app log was created at all: the script may have been blocked or killed before running its first line (execution policy, AppLocker, or antivirus).' }
    }
}

# ---------------------------------------------------------------------------------------------
Invoke-Section 'App log (last 60 lines of %LOCALAPPDATA%\rodriextract\rodriextract.log)' {
    $logFile = Join-Path $env:LOCALAPPDATA 'rodriextract\rodriextract.log'
    if (Test-Path -LiteralPath $logFile) { Get-Content -LiteralPath $logFile | Select-Object -Last 60 | ForEach-Object { W $_ } } else { W '(no log file)' }
}

# ---------------------------------------------------------------------------------------------
Invoke-Section 'Windows event logs (last 3 days): security software blocks and crashes' {
    $since = (Get-Date).AddDays(-3)
    $queries = @(
        @{ Label = 'Defender'; Log = 'Microsoft-Windows-Windows Defender/Operational'; Ids = 1006, 1007, 1008, 1015, 1116, 1117, 1118, 1119, 1121, 1122, 5007 },
        @{ Label = 'AppLocker EXE/DLL'; Log = 'Microsoft-Windows-AppLocker/EXE and DLL'; Ids = 8002, 8003, 8004 },
        @{ Label = 'AppLocker MSI/Script'; Log = 'Microsoft-Windows-AppLocker/MSI and Script'; Ids = 8005, 8006, 8007 },
        @{ Label = 'Code Integrity (WDAC)'; Log = 'Microsoft-Windows-CodeIntegrity/Operational'; Ids = 3076, 3077, 3033, 3034 },
        @{ Label = 'Application crashes'; Log = 'Application'; Ids = 1000, 1001, 1002 }
    )
    foreach ($q in $queries) {
        W ''
        W "[$($q.Label)]"
        try { $ev = @(Get-WinEvent -FilterHashtable @{ LogName = $q.Log; Id = $q.Ids; StartTime = $since } -MaxEvents 60 -ErrorAction Stop) }
        catch { W "    none, or not readable ($($_.Exception.Message.Split([char]10)[0]))"; continue }
        if ($q.Label -eq 'Application crashes') { $ev = @($ev | Where-Object { $_.Message -match 'powershell|pdfimages|pdfinfo|rodriextract|cmd\.exe' }) }
        if ($ev.Count -eq 0) { W '    none in the last 3 days'; continue }
        # identical messages are collapsed into one line with a count
        $groups = @($ev | Group-Object { $_.Message } | Sort-Object { $_.Group[0].TimeCreated } -Descending | Select-Object -First 8)
        foreach ($g in $groups) {
            $e = $g.Group[0]
            $m = ($e.Message -replace '\s+', ' ')
            if ($m.Length -gt 380) { $m = $m.Substring(0, 380) + '...' }
            W "    $($e.TimeCreated.ToString('yyyy-MM-dd HH:mm'))  id=$($e.Id)  x$($g.Count)  $m"
        }
        $hit = @($ev | Where-Object { $_.Message -match 'rodriextract|pdfimages|pdfinfo|poppler' })
        if ($hit.Count) { Add-Finding "$($q.Label) log has $($hit.Count) event(s) mentioning rodriextract/poppler files - security software acted on them (details in the section above)." }
    }
}

# ---------------------------------------------------------------------------------------------
Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
W ''
W ('-' * 78)
W ("End of report. Took {0:N0} seconds." -f ((Get-Date) - $script:Started).TotalSeconds)
Save-Report

Write-Host ''
if ($script:Findings.Count -gt 0) {
    Write-Host 'Findings:' -ForegroundColor Yellow
    foreach ($f in $script:Findings) { Write-Host "  * $f" }
}
else { Write-Host 'No obvious problem was detected automatically.' -ForegroundColor Green }
exit 0
