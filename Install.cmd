@echo off
rem Proxmox Link installer: copies it to %LOCALAPPDATA%\Programs\ProxmoxLink for you alone (no administrator rights),
rem adds Start menu shortcuts, and opens setup. PowerShell runs with -ExecutionPolicy Bypass for this one run only;
rem your execution policy is not changed.
setlocal
echo Proxmox Link installer
echo.
set "STARTUP="
choice /c YN /n /m "Start Proxmox Link when you sign in? [Y/N] "
if errorlevel 2 goto install
set "STARTUP=-Startup"
:install
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0ProxmoxLink-Install.ps1" %STARTUP%
if errorlevel 1 (
  echo.
  echo Installation did not finish. See the message above.
  pause
  exit /b 1
)
echo.
echo Done. Set up a connection in the window that opens.
timeout /t 5 >nul
