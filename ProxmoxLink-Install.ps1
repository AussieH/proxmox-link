<#
.SYNOPSIS
    Installs or removes Proxmox Link for the current Windows user. No administrator rights are needed.

.DESCRIPTION
    Install (run by Install.cmd): copies Proxmox Link to %LOCALAPPDATA%\Programs\ProxmoxLink, clears the "downloaded
    from the internet" mark on the copies (Unblock-File), adds Start menu shortcuts (Proxmox Link, Proxmox Link setup,
    Uninstall Proxmox Link) and, if asked, a Startup shortcut so it starts when you sign in, then opens setup.

    Uninstall (run by Uninstall.cmd): stops Proxmox Link, removes the shortcuts and the program folder, and, if you say
    so, your settings and saved tokens (%LOCALAPPDATA%\ProxmoxLink).

    Every shortcut runs PowerShell with -ExecutionPolicy Bypass for that one launch; the computer's and your execution
    policy are never changed.

.PARAMETER Startup
    Also start Proxmox Link when you sign in.
.PARAMETER Uninstall
    Remove Proxmox Link.
.PARAMETER RemoveSettings
    With -Uninstall: also delete settings and saved tokens without asking.
.PARAMETER KeepSettings
    With -Uninstall: keep settings without asking.
.PARAMETER NoLaunch
    Do not open setup at the end.
.PARAMETER Destination
    Where to install (default %LOCALAPPDATA%\Programs\ProxmoxLink).
.PARAMETER ProgramsDir
    The Start menu Programs folder (default: yours).
.PARAMETER StartupDir
    The Startup folder (default: yours).
#>
[CmdletBinding()]
param(
    [switch]$Startup,
    [switch]$Uninstall,
    [switch]$RemoveSettings,
    [switch]$KeepSettings,
    [switch]$NoLaunch,
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\ProxmoxLink'),
    [string]$ProgramsDir = [Environment]::GetFolderPath('Programs'),
    [string]$StartupDir = [Environment]::GetFolderPath('Startup')
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'ProxmoxLink.Core.ps1')
$paths = Get-PxPaths
$menuDir = Join-Path $ProgramsDir 'Proxmox Link'
$files = @('ProxmoxLink.ps1', 'ProxmoxLink-Setup.ps1', 'ProxmoxLink.Core.ps1', 'ProxmoxLink-Install.ps1', 'Install.cmd', 'Uninstall.cmd', 'README.md', 'LICENSE')

function Stop-Running {
    if (Test-PxRunning) {
        Write-Host 'Stopping Proxmox Link...'
        if (-not (Stop-PxLink 15000)) { Write-Warning 'Proxmox Link did not stop. Quit it from its tray icon, then run this again.'; exit 1 }
    }
}

if ($Uninstall) {
    Set-Location -LiteralPath ([IO.Path]::GetTempPath())   # never sit in the folder being removed
    Stop-Running
    foreach ($lnk in @((Get-PxStartupShortcutPath $StartupDir), $menuDir)) {
        if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Recurse -Force; Write-Host "Removed $lnk" }
    }
    if (Test-Path -LiteralPath $Destination) {
        foreach ($f in ($files + 'ProxmoxLink.ico')) { $p = Join-Path $Destination $f; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
        try { Remove-Item -LiteralPath $Destination -Recurse -Force; Write-Host "Removed $Destination" } catch { Write-Warning "Could not remove all of ${Destination}: $($_.Exception.Message)" }
    }
    try { if (Test-Path -LiteralPath $paths.CompanionFile) { Remove-Item -LiteralPath $paths.CompanionFile -Force } } catch { }
    $remove = $RemoveSettings
    if (-not $RemoveSettings -and -not $KeepSettings -and (Test-Path -LiteralPath $paths.ConfigDir)) {
        $answer = Read-Host "Also delete your Proxmox Link settings and saved tokens in $($paths.ConfigDir)? (y/N)"
        $remove = $answer -match '^(y|yes)$'
    }
    if ($remove -and (Test-Path -LiteralPath $paths.ConfigDir)) { Remove-Item -LiteralPath $paths.ConfigDir -Recurse -Force; Write-Host "Removed $($paths.ConfigDir)" }
    elseif (Test-Path -LiteralPath $paths.ConfigDir) { Write-Host "Kept your settings in $($paths.ConfigDir)." }
    Write-Host 'Proxmox Link is uninstalled. The widget''s folder (%APPDATA%\ProxmoxControl) is left for the Stream Deck plugin, if you use it.'
    exit 0
}

# ---- install ----------------------------------------------------------------------------------------------------------
foreach ($f in $files) { if (-not (Test-Path -LiteralPath (Join-Path $here $f))) { Write-Warning "$f is missing from $here. Extract the whole zip, then run Install.cmd again."; exit 1 } }
Stop-Running
[void][IO.Directory]::CreateDirectory($Destination)
if ((Resolve-Path -LiteralPath $here).Path.TrimEnd('\') -ne (Resolve-Path -LiteralPath $Destination).Path.TrimEnd('\')) {
    foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $here $f) -Destination (Join-Path $Destination $f) -Force }
}
# Files from a downloaded zip carry the mark of the web; clear it on the installed copies.
Get-ChildItem -LiteralPath $Destination -File | Unblock-File
$icon = Join-Path $Destination 'ProxmoxLink.ico'
try { Save-PxIconFile $icon } catch { Write-Warning "No icon: $($_.Exception.Message)" }
Write-Host "Installed in $Destination"

[void][IO.Directory]::CreateDirectory($menuDir)
$ps = Get-PxPowerShellExe
$link = Join-Path $Destination 'ProxmoxLink.ps1'
$setup = Join-Path $Destination 'ProxmoxLink-Setup.ps1'
New-PxShortcut -Path (Join-Path $menuDir 'Proxmox Link.lnk') -Target $ps -Arguments (Get-PxLaunchArguments $link) -WorkingDir $Destination -Icon $icon -Description 'Start Proxmox Link (feeds the Proxmox Dashboard widget)'
New-PxShortcut -Path (Join-Path $menuDir 'Proxmox Link setup.lnk') -Target $ps -Arguments (Get-PxLaunchArguments $setup) -WorkingDir $Destination -Icon $icon -Description 'Set up Proxmox Link'
New-PxShortcut -Path (Join-Path $menuDir 'Uninstall Proxmox Link.lnk') -Target (Join-Path $env:SystemRoot 'System32\cmd.exe') -Arguments "/c `"$(Join-Path $Destination 'Uninstall.cmd')`"" -WorkingDir ([IO.Path]::GetTempPath().TrimEnd('\')) -Icon $icon -Description 'Remove Proxmox Link' -WindowStyle 1
Write-Host "Start menu: $menuDir"
if ($Startup) { Set-PxStartAtSignIn $true $link $StartupDir; Write-Host 'Proxmox Link will start when you sign in.' }

if (-not $NoLaunch) {
    Write-Host 'Opening setup...'
    Start-Process -FilePath $ps -ArgumentList (Get-PxLaunchArguments $setup) -WindowStyle Hidden -WorkingDirectory $Destination
}
exit 0
