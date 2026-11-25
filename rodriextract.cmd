@echo off
rem rodriextract launcher - double-click this file.
rem First run: relaunch ourselves minimised so no black window sits in the way.
if /i not "%~1"=="inner" (
    start "" /min "%~f0" inner
    exit /b
)

cd /d "%~dp0"
if not exist "%~dp0rodriextract.ps1" (
    start "" cmd /k "echo rodriextract.ps1 is missing. Please extract the whole zip and keep all the files together."
    exit /b 1
)

rem Files from a downloaded/emailed zip carry a "came from the internet" tag that can make
rem PowerShell stop and ask a question nobody can see. Remove the tag from our own folder.
dir /r "%~dp0rodriextract.ps1" 2>nul | find ":Zone.Identifier" >nul
if errorlevel 1 goto :launch
set "RDX_DIR=%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath $env:RDX_DIR -Recurse -File | Unblock-File" >nul 2>&1

:launch
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0rodriextract.ps1"
set "RC=%ERRORLEVEL%"

rem 0 = closed normally, 2 = the app already showed its own error message
if "%RC%"=="0" exit /b 0
if "%RC%"=="2" exit /b 2

start "" cmd /k "echo. & echo rodriextract could not start - error code %RC% & echo. & echo Please double-click rodriextract-visible.cmd to see what the error is, & echo and send what it says to the person who gave you rodriextract."
exit /b %RC%
