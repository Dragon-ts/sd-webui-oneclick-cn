@echo off
setlocal
cd /d "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set "RC=%ERRORLEVEL%"

if "%RC%"=="0" (
  echo.
  echo Installation finished. Run start_sd.bat to launch the WebUI.
  pause
)

exit /b %RC%
