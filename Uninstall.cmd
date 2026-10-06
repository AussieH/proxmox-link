@echo off
rem Proxmox Link uninstaller: stops it, removes its shortcuts and program folder, and asks before deleting your settings
rem and saved tokens. Copies the remover to a temporary folder first, because it deletes the folder it lives in.
setlocal
set "SRC=%~dp0"
set "TMPDIR=%TEMP%\ProxmoxLink-uninstall-%RANDOM%"
mkdir "%TMPDIR%" >nul 2>&1
copy /y "%SRC%ProxmoxLink-Install.ps1" "%TMPDIR%\" >nul
copy /y "%SRC%ProxmoxLink.Core.ps1" "%TMPDIR%\" >nul
cd /d "%TMPDIR%"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%TMPDIR%\ProxmoxLink-Install.ps1" -Uninstall & pause & cd /d "%TEMP%" & rmdir /s /q "%TMPDIR%" & exit /b
