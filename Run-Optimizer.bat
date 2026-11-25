@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-Disk.ps1" -Mode Interactive
echo.
pause
