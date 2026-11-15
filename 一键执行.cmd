@echo off
setlocal
cd /d "%~dp0"
echo ============================================================
echo  OnePlus 10 Pro / iOS 16 - one-click builder
echo  See README-for step details. Logs: .\logs
echo ============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\oneclick.ps1" %*
echo.
echo exit code: %ERRORLEVEL%
echo.
pause
