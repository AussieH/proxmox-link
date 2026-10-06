<#
.SYNOPSIS
    Proxmox Link: feeds the Proxmox Dashboard widget (CORSAIR iCUE, XENEON EDGE) without a Stream Deck.

.DESCRIPTION
    Polls the Proxmox VE, Proxmox Backup Server and Proxmox Datacenter Manager connections set up in
    ProxmoxLink-Setup.ps1 and writes %APPDATA%\ProxmoxControl\state.json, the file the widget reads. Shows a tray icon
    with Open setup, Pause and Quit. Only one Proxmox Link runs per Windows user.

    Launched hidden, as the Start menu and sign-in shortcuts do it:
        powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ProxmoxLink.ps1

.PARAMETER NoTray
    Run in this console without a tray icon (for testing). Ctrl+C, or Stop in setup, ends it.
#>
[CmdletBinding()]
param([switch]$NoTray)

# The tray menu (Windows Forms) wants a single-threaded apartment; PowerShell 7 starts in a multi-threaded one.
if (-not $NoTray -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") -WindowStyle Hidden
    return
}

$core = Join-Path $PSScriptRoot 'ProxmoxLink.Core.ps1'
. $core
$paths = Get-PxPaths
[ProxmoxLink.Log]::Init($paths.LogDir)

# One Proxmox Link per user: a second copy just leaves.
$createdNew = $false
$mutex = New-Object Threading.Mutex($true, $paths.MutexName, [ref]$createdNew)
if (-not $createdNew) {
    Write-PxLog 'info' 'already running; this copy exits'
    if ($NoTray) { Write-Host 'Proxmox Link is already running.' }
    $mutex.Dispose()
    exit 0
}
# Setup's Stop button (and the uninstaller) signal this to ask for a clean exit.
$quitEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $paths.QuitEventName)
[void]$quitEvent.Reset()

$shared = [hashtable]::Synchronized(@{
    Stop = $false; Paused = $false; Done = $false; Light = 'grey'; Text = 'Proxmox Link: starting'
    StopEvent = New-Object Threading.ManualResetEvent($false); QuitEvent = $quitEvent; CorePath = $core
})

function Exit-PxLink([int]$Code = 0) {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose(); $quitEvent.Dispose()
    # The connection loops may still be inside a request: end the process rather than wait for them.
    [Environment]::Exit($Code)
}

if ($NoTray) {
    Write-Host "Proxmox Link $($script:PxVersion): writing $($paths.StateFile). Ctrl+C to stop."
    try { Invoke-PxSupervisor $shared }
    finally { Exit-PxLink 0 }
}

# ---------------------------------------------------------------------------------------------------------------------
# The tray icon. The supervisor runs in a runspace of its own so the menu never waits for a server.
# ---------------------------------------------------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Hide-PxOwnConsole
[Windows.Forms.Application]::EnableVisualStyles()

$rs = [runspacefactory]::CreateRunspace()
$rs.Open()
$sup = [powershell]::Create()
$sup.Runspace = $rs
[void]$sup.AddScript('param($core, $shared) . $core; [ProxmoxLink.Log]::Init((Get-PxPaths).LogDir); Invoke-PxSupervisor $shared').AddArgument($core).AddArgument($shared)
$supHandle = $sup.BeginInvoke()

$size = [Windows.Forms.SystemInformation]::SmallIconSize.Width
$colors = @{ green = '#3fb950'; amber = '#d29922'; red = '#f85149'; grey = '#8b949e' }
$icons = @{}
foreach ($k in $colors.Keys) { $bmp = New-PxIconBitmap $size $colors[$k]; $icons[$k] = [Drawing.Icon]::FromHandle($bmp.GetHicon()) }

$setupScript = Join-Path $PSScriptRoot 'ProxmoxLink-Setup.ps1'
function Open-PxSetup { Start-Process -FilePath (Get-PxPowerShellExe) -ArgumentList (Get-PxLaunchArguments $setupScript) -WindowStyle Hidden -WorkingDirectory $PSScriptRoot }

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = $icons.grey
$tray.Text = 'Proxmox Link: starting'
$menu = New-Object Windows.Forms.ContextMenuStrip
$miStatus = New-Object Windows.Forms.ToolStripMenuItem('Starting')
$miStatus.Enabled = $false
$miSetup = New-Object Windows.Forms.ToolStripMenuItem('Open setup')
$miSetup.Font = New-Object Drawing.Font($miSetup.Font, [Drawing.FontStyle]::Bold)
$miPause = New-Object Windows.Forms.ToolStripMenuItem('Pause')
$miQuit = New-Object Windows.Forms.ToolStripMenuItem('Quit')
[void]$menu.Items.Add($miStatus)
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($miSetup)
[void]$menu.Items.Add($miPause)
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($miQuit)
$tray.ContextMenuStrip = $menu
$ctx = New-Object Windows.Forms.ApplicationContext

$quitting = $false
$quit = {
    if ($script:quitting) { return }
    $script:quitting = $true
    $shared.Stop = $true
    [void]$shared.StopEvent.Set()
    $t0 = [datetime]::UtcNow
    while (-not $supHandle.IsCompleted -and ([datetime]::UtcNow - $t0).TotalSeconds -lt 5) { Start-Sleep -Milliseconds 100 }
    $tray.Visible = $false
    $ctx.ExitThread()
}
$miSetup.add_Click({ Open-PxSetup })
$tray.add_DoubleClick({ Open-PxSetup })
$miPause.add_Click({ $shared.Paused = -not $shared.Paused })
$miQuit.add_Click($quit)

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.add_Tick({
    if ($supHandle.IsCompleted) {
        # Stopped from setup or the uninstaller (the quit event), or the supervisor ended.
        if (-not $script:quitting) { $script:quitting = $true; $tray.Visible = $false; $ctx.ExitThread() }
        return
    }
    $light = [string]$shared.Light
    if ($icons.ContainsKey($light) -and -not [object]::ReferenceEquals($tray.Icon, $icons[$light])) { $tray.Icon = $icons[$light] }
    $text = [string]$shared.Text
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    if ($tray.Text -ne $text) { $tray.Text = $text }
    $miStatus.Text = $text -replace '^Proxmox Link: ', ''
    $miPause.Text = $(if ($shared.Paused) { 'Resume' } else { 'Pause' })
})
$timer.Start()
$tray.Visible = $true

$cfg = Read-PxConfig $paths.ConfigFile
if (-not @($cfg.connections | Where-Object { $_.host -and $_.tokenId -and $_.secret }).Count) {
    $tray.ShowBalloonTip(8000, 'Proxmox Link is running', 'No connection is set up yet. Double-click this icon to open setup.', [Windows.Forms.ToolTipIcon]::Info)
}

try { [Windows.Forms.Application]::Run($ctx) }
finally {
    $timer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    if (-not $supHandle.IsCompleted) { $shared.Stop = $true; [void]$shared.StopEvent.Set(); [void]$supHandle.AsyncWaitHandle.WaitOne(5000) }
    Exit-PxLink 0
}
