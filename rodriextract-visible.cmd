@echo off
rem Same as rodriextract.cmd, but keeps the black window open so any error can be read.
cd /d "%~dp0"
echo rodriextract - troubleshooting launcher
echo (leave this window open while the program is running)
echo.
dir /r "%~dp0rodriextract.ps1" 2>nul | find ":Zone.Identifier" >nul
if errorlevel 1 goto :launch
echo These files came from the internet and are tagged as such; removing the tag...
set "RDX_DIR=%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath $env:RDX_DIR -Recurse -File | Unblock-File"
echo.

:launch
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0rodriextract.ps1"
echo.
echo rodriextract finished with code %ERRORLEVEL%   (0 = normal)
echo Log file: %LOCALAPPDATA%\rodriextract\rodriextract.log
echo.
pause
