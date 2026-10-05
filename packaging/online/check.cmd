@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\installer.ps1" -Action Check %*
set "PATCH_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %PATCH_EXIT%
