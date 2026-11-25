@echo off
setlocal
cd /d "%~dp0"
title rodriextract diagnostic
set "OUT=%~dp0rodriextract-diagnostic.txt"
set "S1=%TEMP%\rodriextract-diag-stage1.txt"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

echo ==============================================================
echo  rodriextract diagnostic
echo ==============================================================
echo This takes about a minute. Some windows may flash open and
echo close, and a small test window may appear. That is normal.
echo Please do not click anything until it says DONE.
echo.

rem If this folder is read-only, write the report to TEMP instead.
(echo test> "%OUT%") 2>nul || set "OUT=%TEMP%\rodriextract-diagnostic.txt"
del "%OUT%" 2>nul

echo Stage 1 of 2: basic checks...
call :stage1 > "%S1%" 2>&1

echo Stage 2 of 2: detailed checks...
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0rodriextract-diagnose.ps1" -Report "%OUT%" -Stage1 "%S1%"
set "RC=%ERRORLEVEL%"

if not exist "%OUT%" (
    echo The detailed PowerShell stage could not run ^(exit code %RC%^). This is itself useful information.
    (
        echo rodriextract diagnostic - STAGE 2 DID NOT RUN. PowerShell exit code: %RC%
        echo.
        type "%S1%"
    ) > "%OUT%"
) else (
    echo.>> "%OUT%"
    echo [launcher] stage 2 exit code: %RC%>> "%OUT%"
)
del "%S1%" 2>nul

echo.
echo ==============================================================
echo  DONE. Please send this file to whoever asked you to run this:
echo.
echo      %OUT%
echo ==============================================================
if not defined RDX_TEST (
    explorer /select,"%OUT%"
    pause
)
goto :eof

:stage1
echo [Stage 1: checks done with plain cmd, no PowerShell script needed]
echo Date/time : %DATE% %TIME%
ver
echo User      : %USERDOMAIN%\%USERNAME%
echo Computer  : %COMPUTERNAME%
echo Tool folder: %~dp0
echo.
echo --- Files in the tool folder ---
dir /a "%~dp0"
echo.
echo --- Is rodriextract in or near this folder? ---
for %%D in ("%~dp0" "%~dp0.." "%~dp0..\rodriextract" "%USERPROFILE%\Desktop\rodriextract" "%USERPROFILE%\Downloads\rodriextract") do if exist "%%~D\rodriextract.ps1" echo FOUND: %%~fD
echo.
echo --- "Downloaded from the internet" tags on the scripts (Zone.Identifier), as found ---
set "TAGGED="
call :tagcheck "%~dp0rodriextract-diagnose.ps1"
call :tagcheck "%~dp0..\rodriextract.ps1"
echo.
echo --- PowerShell execution policy at every level ---
"%PS%" -NoProfile -Command "Get-ExecutionPolicy -List | Format-Table -AutoSize | Out-String -Width 200"
if not defined TAGGED goto :untagged
echo Removing the tags so the diagnostic and the app can run (the rodriextract launchers do this too)...
set "RDX_DIR=%~dp0"
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath $env:RDX_DIR -Recurse -File | Unblock-File; $p = Split-Path -Parent $env:RDX_DIR.TrimEnd('\'); if (Test-Path -LiteralPath (Join-Path $p 'rodriextract.ps1')) { Get-ChildItem -LiteralPath $p -Recurse -File | Unblock-File }; 'unblock finished'"
echo exit code: %ERRORLEVEL%
:untagged
echo.
echo --- PowerShell policy settings in the registry ---
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell" /s
reg query "HKCU\SOFTWARE\Policies\Microsoft\Windows\PowerShell" /s
echo.
echo --- Where is PowerShell? ---
where powershell
echo.
echo --- PowerShell smoke test (-Command) ---
"%PS%" -NoProfile -Command "$ExecutionContext.SessionState.LanguageMode; $PSVersionTable.PSVersion.ToString()"
echo exit code: %ERRORLEVEL%
echo.
echo --- Can PowerShell create a window object (-Command) ---
"%PS%" -NoProfile -Command "try { Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.Form; 'FORM_CREATE_OK' } catch { 'FORM_CREATE_FAIL: ' + $_.Exception.Message }"
echo exit code: %ERRORLEVEL%
exit /b 0

:tagcheck
if not exist "%~f1" goto :tc_missing
dir /r "%~f1" 2>nul | find ":Zone.Identifier" >nul
if errorlevel 1 goto :tc_clean
echo TAGGED: %~f1
set "TAGGED=1"
exit /b 0
:tc_missing
echo missing: %~f1
exit /b 0
:tc_clean
echo not tagged: %~f1
exit /b 0
