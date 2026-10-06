<#
.SYNOPSIS
    Proxmox Link setup: connections, API tokens, certificates, refresh interval, start at sign-in, start and stop.

.DESCRIPTION
    A small window (Windows Forms, built into Windows). Up to three connections, A, B and C, each a Proxmox VE server
    or cluster (port 8006), a Proxmox Backup Server (8007) or a Proxmox Datacenter Manager (8443), as in the Stream Deck
    plugin Proxmox & PBS Control. Test checks a connection and shows its certificate's fingerprint to trust.

    Settings are saved in %LOCALAPPDATA%\ProxmoxLink\config.json, token secrets encrypted for your Windows account.

.PARAMETER SelfTest
    Build the window without showing it, check it, and exit (used by the tests).
.PARAMETER Screenshot
    With -SelfTest: a folder to save a picture of each tab in (drawn off screen).
.PARAMETER Drive
    With -SelfTest: a JSON file with a connection (kind, label, host, port, tokenId, secret) to fill in as connection A,
    Test, trust and Save, as a person would (used by the tests, against a fake server).
#>
[CmdletBinding()]
param([switch]$SelfTest, [string]$Screenshot, [string]$Drive)

# Windows Forms wants a single-threaded apartment; PowerShell 7 starts in a multi-threaded one.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA -and -not $SelfTest) {
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") -WindowStyle Hidden
    return
}

$core = Join-Path $PSScriptRoot 'ProxmoxLink.Core.ps1'
. $core
$paths = Get-PxPaths
[ProxmoxLink.Log]::Init($paths.LogDir)
$linkScript = Join-Path $PSScriptRoot 'ProxmoxLink.ps1'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not $SelfTest) {
    $created = $false
    $setupMutex = New-Object Threading.Mutex($true, $paths.SetupMutexName, [ref]$created)
    if (-not $created) {
        # Setup is already open: bring it forward instead of opening a second one.
        try { [void](New-Object -ComObject WScript.Shell).AppActivate('Proxmox Link setup') } catch { }
        return
    }
    Hide-PxOwnConsole
    try { Add-Type -Namespace ProxmoxLink -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'; [void][ProxmoxLink.Dpi]::SetProcessDPIAware() } catch { }
}
[Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------------------------------------------------
# Words
# ---------------------------------------------------------------------------------------------------------------------
$KindItems = @(
    @{ kind = 'pve'; text = 'Proxmox VE' },
    @{ kind = 'pbs'; text = 'Proxmox Backup Server' },
    @{ kind = 'pdm'; text = 'Proxmox Datacenter Manager' }
)
$ErrorHelp = @{
    'Auth failed'   = 'The token ID or secret is wrong, or the token was deleted.'
    'No permission' = 'The token works but lacks a right: see API tokens. On a Backup Server, check the user as well as the token.'
    'DNS failed'    = 'This computer cannot find that host name. Check the spelling, or use the address.'
    'Refused'       = 'Nothing answers on that port. Proxmox VE uses 8006, a Backup Server 8007, a Datacenter Manager 8443.'
    'Timeout'       = 'No answer in time. Check the host, the port and the network path: open https://host:port in a browser on this computer.'
    'Unreachable'   = 'This computer has no route to that host. Check the address and the network.'
    'Connect failed' = 'Could not connect. Check the host, the port and the network path.'
    'Bad host'      = 'That host name is not valid. Enter just the name or address, for example pve01.home.arpa.'
    'TLS error'     = 'The secure connection failed before the certificate was checked. Check the port.'
    'Connection reset' = 'The server closed the connection. Check the port and the connection''s type.'
}

$TokenHelp = @'
Proxmox Link only reads: give it its own user and an API token with a read-only role. The secret is shown once, when you create the token, so keep it on screen until the connection is set up.

PROXMOX VE
In a shell on any node of the cluster:
    pveum user add linkreader@pve
    pveum acl modify / --users linkreader@pve --roles PVEAuditor
    pveum user token add linkreader@pve edge --privsep 0
The token ID is then linkreader@pve!edge. In the web UI: Datacenter > Permissions > API Tokens > Add, untick Privilege Separation (or keep it and give the token itself PVEAuditor on /).

PROXMOX BACKUP SERVER
In a shell on the Backup Server:
    proxmox-backup-manager user create linkreader@pbs
    proxmox-backup-manager user generate-token linkreader@pbs edge
    proxmox-backup-manager acl update / Audit --auth-id linkreader@pbs
    proxmox-backup-manager acl update / Audit --auth-id 'linkreader@pbs!edge'
A Backup Server never gives a token more than its user has, so grant both. The Audit role includes Datastore.Audit.

PROXMOX DATACENTER MANAGER
In the web UI, under Configuration > Access Control:
    1. Add a user in the pdm realm, for example linkreader@pdm.
    2. Add an API token for it, for example edge, and copy the secret.
    3. Under Permissions, give both the user and the token the Auditor role on /resource.
The Datacenter Manager talks to its remotes with its own tokens, so nothing is needed on the servers behind it.

CHECKING A CERTIFICATE'S FINGERPRINT
Proxmox servers make their own (self-signed) certificates, so the first Test shows the certificate's SHA-256 fingerprint and asks you to trust it. Compare it with the one the server reports, then press Trust. On the server itself (Proxmox VE uses 8006, a Backup Server 8007, a Datacenter Manager 8443):
    openssl s_client -connect localhost:8006 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256
In the web UI: on Proxmox VE, the node > System > Certificates; on a Backup Server, Dashboard > Show Fingerprint.
After that Proxmox Link accepts only that certificate for that connection. If the server gets a new certificate, Test shows the new fingerprint to trust. For a certificate from Let's Encrypt or another authority Windows trusts, which renews every few months, tick "Also accept a certificate Windows trusts".

WHERE THE TOKEN IS KEPT
In %LOCALAPPDATA%\ProxmoxLink\config.json, the secret encrypted for your Windows account (DPAPI). It is only ever sent to the host you enter, and only after that host's certificate checks out. It is never written to the widget's file or the log.
'@

# ---------------------------------------------------------------------------------------------------------------------
# The window
# ---------------------------------------------------------------------------------------------------------------------
$cfg = Read-PxConfig $paths.ConfigFile
$font = New-Object Drawing.Font('Segoe UI', 9)
$dirty = $false
$ui = @{}

function New-Label([string]$Text, [switch]$Bold, [switch]$Muted, [int]$Width = 0) {
    $l = New-Object Windows.Forms.Label
    $l.UseMnemonic = $false   # an & is an &, not a keyboard shortcut
    $l.Text = $Text
    $l.AutoSize = $true
    if ($Width) { $l.MaximumSize = New-Object Drawing.Size($Width, 0) }
    $l.Margin = New-Object Windows.Forms.Padding(3, 6, 3, 3)
    if ($Bold) { $l.Font = New-Object Drawing.Font($font, [Drawing.FontStyle]::Bold) }
    if ($Muted) { $l.ForeColor = [Drawing.SystemColors]::GrayText }
    return $l
}
function New-Button([string]$Text) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text
    $b.AutoSize = $true
    $b.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $b.Padding = New-Object Windows.Forms.Padding(8, 2, 8, 2)
    $b.Margin = New-Object Windows.Forms.Padding(0, 3, 8, 3)
    return $b
}
function New-Flow {
    $f = New-Object Windows.Forms.FlowLayoutPanel
    $f.AutoSize = $true
    $f.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $f.WrapContents = $false
    $f.Margin = New-Object Windows.Forms.Padding(0)
    return $f
}
function Set-Dirty { $script:dirty = $true; $statusLabel.Text = 'Not saved yet.' }
<# Grey example text inside an empty box. #>
function Set-Placeholder($Box, [string]$Text) {
    try {
        if (-not ('ProxmoxLink.Cue' -as [type])) { Add-Type -Namespace ProxmoxLink -Name Cue -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);' }
        $Box.add_HandleCreated({ param($s, $e) [void][ProxmoxLink.Cue]::SendMessage($s.Handle, 0x1501, [IntPtr]1, [string]$s.AccessibleDescription) })
        $Box.AccessibleDescription = $Text
    } catch { }
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Proxmox Link setup'
$form.Font = $font
$form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font
$form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
$form.ClientSize = New-Object Drawing.Size(720, 700)
$form.MinimumSize = New-Object Drawing.Size(660, 640)
try { $iconBmp = New-PxIconBitmap 32; $form.Icon = [Drawing.Icon]::FromHandle($iconBmp.GetHicon()) } catch { }

$root = New-Object Windows.Forms.TableLayoutPanel
$root.Dock = [Windows.Forms.DockStyle]::Fill
$root.ColumnCount = 1
$root.RowCount = 3
$root.Padding = New-Object Windows.Forms.Padding(12)
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
$form.Controls.Add($root)

$head = New-Object Windows.Forms.FlowLayoutPanel
$head.FlowDirection = [Windows.Forms.FlowDirection]::TopDown
$head.AutoSize = $true
$head.Dock = [Windows.Forms.DockStyle]::Fill
$head.WrapContents = $false
$head.Controls.Add((New-Label "Proxmox Link $script:PxVersion" -Bold))
$head.Controls.Add((New-Label 'Feeds the Proxmox Dashboard widget on a CORSAIR XENEON EDGE without a Stream Deck. It reads your Proxmox servers with a read-only API token and writes what it reads to one file the widget watches: host names, nodes, guests, storage and backups, never a token or secret.' -Width 680))
$root.Controls.Add($head, 0, 0)

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = [Windows.Forms.DockStyle]::Fill
$tabs.Margin = New-Object Windows.Forms.Padding(0, 8, 0, 8)
$root.Controls.Add($tabs, 0, 1)

# ---- one tab per connection ------------------------------------------------------------------------------------------
function Get-KindIndex([string]$Kind) { for ($i = 0; $i -lt $KindItems.Count; $i++) { if ($KindItems[$i].kind -eq $Kind) { return $i } }; return 0 }

function Update-CertLabel($u) {
    if ($u.pin) { $u.certLabel.Text = "Trusted: SHA-256 $($u.pin)"; $u.certLabel.ForeColor = [Drawing.SystemColors]::ControlText }
    else { $u.certLabel.Text = 'Not trusted yet: press Test.'; $u.certLabel.ForeColor = [Drawing.SystemColors]::GrayText }
}

function Update-SecretHint($u) {
    if ($u.secretBox.Text) { $u.secretHint.Text = 'A new secret: saved encrypted for your Windows account when you press Save.'; return }
    if ($u.stored.secret) {
        if ($null -ne (Unprotect-PxSecret $u.stored.secret)) { $u.secretHint.Text = 'A secret is saved (encrypted for your Windows account). Type a new one to replace it.' }
        else { $u.secretHint.Text = 'The saved secret cannot be read on this Windows account. Enter it again.' }
    } else { $u.secretHint.Text = 'The token''s secret, shown once when the token was made.' }
}

<# The connection as typed (not yet saved), with the secret typed or, failing that, the saved one. #>
function Get-UiConnection($u) {
    $hp = Split-PxHostInput $u.hostBox.Text
    $port = if ($hp.port) { [int]$hp.port } else { [int]$u.portBox.Value }
    $secret = if ($u.secretBox.Text) { $u.secretBox.Text.Trim() } else { Unprotect-PxSecret $u.stored.secret }
    $hostName = [string]$hp.host
    [pscustomobject]@{
        key = $u.key; kind = $KindItems[$u.kindBox.SelectedIndex].kind; label = $u.labelBox.Text.Trim(); host = $hostName; port = $port
        tokenId = $u.tokenBox.Text.Trim(); secret = $secret; pin = [string]$u.pin; trustWindows = [bool]$u.trustBox.Checked
        configured = [bool]($hostName -and $u.tokenBox.Text.Trim() -and $secret)
    }
}

function Show-TestResult($u, $res) {
    $u.pending = $null
    $u.trustBtn.Enabled = $false
    $lines = New-Object Collections.Generic.List[string]
    if ($res.cert -eq 'new' -or $res.cert -eq 'changed') {
        if ($res.cert -eq 'new') { $lines.Add("This server's certificate is not trusted yet.") }
        else { $lines.Add('WARNING: the certificate changed since you trusted it. If the server got a new certificate, check and trust the new one. If not, something may be between you and the server: do not trust it.') }
        $lines.Add('')
        $lines.Add('SHA-256 fingerprint:')
        $lines.Add("    $($res.fingerprint)")
        if ($res.subject) { $lines.Add("Issued to: $($res.subject)") }
        if ($res.issuer -and $res.issuer -ne $res.subject) { $lines.Add("Issued by: $($res.issuer)") }
        if ($res.notAfter) { $lines.Add("Expires: $($res.notAfter)") }
        $lines.Add('')
        $lines.Add('Check that it matches the fingerprint the server shows (see API tokens), then press Trust this certificate. Nothing, not even the token, was sent to the server.')
        $u.pending = $res.fingerprint
        $u.trustBtn.Enabled = $true
    } elseif ($res.ok) {
        $lines.Add("Connected: $($res.summary).")
        $lines.Add($(if ($res.cert -eq 'windows') { 'Certificate: trusted by Windows.' } else { "Certificate: trusted (SHA-256 $($res.fingerprint))." }))
        $lines.Add('Press Save to keep this connection.')
    } else {
        $word = [string]$res.error
        $help = $ErrorHelp[$word]
        if (-not $help -and $word -match '^HTTP') { $help = 'The server answered, but not as this type of server does. Check the connection''s type and port.' }
        if (-not $help -and $word -match '^Enter') { $lines.Add($word) }
        else {
            $lines.Add("Failed: $word")
            if ($help) { $lines.Add($help) }
            if ($res.cert -eq 'pinned') { $lines.Add('The certificate was fine (trusted).') }
        }
    }
    $u.result.Text = $lines -join "`r`n"
}

$pending = New-Object Collections.Generic.List[object]   # Tests running in the background
function Start-UiTest($u) {
    $conn = Get-UiConnection $u
    if ($conn.secret) { [ProxmoxLink.Log]::AddSecret($conn.secret) }
    $u.result.Text = "Testing $($conn.host):$($conn.port)..."
    $u.testBtn.Enabled = $false
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript('param($core, $conn) . $core; Test-PxConnection $conn').AddArgument($core).AddArgument($conn)
    $pending.Add(@{ u = $u; ps = $ps; rs = $rs; handle = $ps.BeginInvoke() })
}

function New-ConnectionTab($c) {
    $u = @{ key = $c.key; stored = $c; pin = $c.fingerprint; pending = $null }
    $page = New-Object Windows.Forms.TabPage("Connection $($c.key)")
    $page.Padding = New-Object Windows.Forms.Padding(10)
    $page.UseVisualStyleBackColor = $true
    $grid = New-Object Windows.Forms.TableLayoutPanel
    $grid.Dock = [Windows.Forms.DockStyle]::Fill
    $grid.ColumnCount = 2
    $grid.AutoScroll = $false
    [void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    $pos = @{ row = 0 }
    $add = {
        param($label, $control, $hint)
        $grid.Controls.Add((New-Label $label), 0, $pos.row)
        $control.Margin = New-Object Windows.Forms.Padding(3, 3, 3, 0)
        $grid.Controls.Add($control, 1, $pos.row)
        $pos.row++
        if ($hint) { $grid.Controls.Add($hint, 1, $pos.row); $pos.row++ }
    }

    $u.kindBox = New-Object Windows.Forms.ComboBox
    $u.kindBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    foreach ($k in $KindItems) { [void]$u.kindBox.Items.Add("$($k.text) (port $($script:PxDefaultPort[$k.kind]))") }
    $u.kindBox.SelectedIndex = Get-KindIndex $c.kind
    $u.kindBox.Width = 320
    $u.lastKind = $c.kind

    $u.labelBox = New-Object Windows.Forms.TextBox; $u.labelBox.Width = 320; $u.labelBox.Text = $c.label
    $u.hostBox = New-Object Windows.Forms.TextBox; $u.hostBox.Width = 320; $u.hostBox.Text = $c.host
    $u.portBox = New-Object Windows.Forms.NumericUpDown; $u.portBox.Minimum = 1; $u.portBox.Maximum = 65535; $u.portBox.Width = 90; $u.portBox.Value = $c.port
    $u.tokenBox = New-Object Windows.Forms.TextBox; $u.tokenBox.Width = 320; $u.tokenBox.Text = $c.tokenId
    $u.secretBox = New-Object Windows.Forms.TextBox; $u.secretBox.Width = 320; $u.secretBox.UseSystemPasswordChar = $true
    $u.secretHint = New-Label '' -Muted -Width 470
    $u.certLabel = New-Label '' -Width 470
    $u.trustBox = New-Object Windows.Forms.CheckBox
    $u.trustBox.Text = 'Also accept a certificate Windows trusts (Let''s Encrypt or another authority)'
    $u.trustBox.AutoSize = $true
    $u.trustBox.Checked = [bool]$c.trustWindows

    Set-Placeholder $u.labelBox 'shown on the widget, for example Homelab'
    Set-Placeholder $u.hostBox 'host name or address, for example pve01.home.arpa'
    Set-Placeholder $u.tokenBox 'user@realm!token, for example linkreader@pve!edge'
    & $add 'Type' $u.kindBox $null
    & $add 'Name' $u.labelBox $null
    & $add 'Host' $u.hostBox $null
    & $add 'Port' $u.portBox $null
    & $add 'Token ID' $u.tokenBox (New-Label 'A read-only token: see API tokens.' -Muted -Width 470)
    & $add 'Secret' $u.secretBox $u.secretHint
    & $add 'Certificate' $u.certLabel $u.trustBox

    $buttons = New-Flow
    $u.testBtn = New-Button 'Test'
    $u.trustBtn = New-Button 'Trust this certificate'
    $u.trustBtn.Enabled = $false
    $u.clearBtn = New-Button 'Clear this connection'
    $buttons.Controls.AddRange(@($u.testBtn, $u.trustBtn, $u.clearBtn))
    & $add '' $buttons $null

    $u.result = New-Object Windows.Forms.TextBox
    $u.result.Multiline = $true
    $u.result.ReadOnly = $true
    $u.result.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
    $u.result.Dock = [Windows.Forms.DockStyle]::Fill
    $u.result.Margin = New-Object Windows.Forms.Padding(3, 6, 3, 3)
    $u.result.Text = 'Fill in the connection, then press Test.'
    for ($r = 0; $r -lt $pos.row; $r++) { [void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize))) }
    [void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
    $grid.Controls.Add($u.result, 0, $pos.row)
    $grid.SetColumnSpan($u.result, 2)
    $page.Controls.Add($grid)

    Update-CertLabel $u
    Update-SecretHint $u

    # Handlers find their connection through the control's Tag (a closure would not see this script's functions).
    foreach ($ctl in @($u.kindBox, $u.labelBox, $u.hostBox, $u.portBox, $u.tokenBox, $u.secretBox, $u.trustBox, $u.testBtn, $u.trustBtn, $u.clearBtn)) { $ctl.Tag = $c.key }
    $u.kindBox.add_SelectedIndexChanged({
        param($s, $e)
        $u = $ui[[string]$s.Tag]
        if ($null -eq $u) { return }
        $new = $KindItems[$u.kindBox.SelectedIndex].kind
        if ([int]$u.portBox.Value -eq $script:PxDefaultPort[$u.lastKind]) { $u.portBox.Value = $script:PxDefaultPort[$new] }
        $u.lastKind = $new
        Set-Dirty
    })
    $hostChanged = {
        param($s, $e)
        # A trusted certificate belongs to one host and port.
        $u = $ui[[string]$s.Tag]
        if ($null -eq $u) { return }
        $hp = Split-PxHostInput $u.hostBox.Text
        $p = if ($hp.port) { [int]$hp.port } else { [int]$u.portBox.Value }
        $same = ($hp.host -eq $u.stored.host -and $p -eq $u.stored.port)
        if (-not $same -and $u.pin) { $u.pin = ''; Update-CertLabel $u }
        elseif ($same -and -not $u.pin -and $u.stored.fingerprint) { $u.pin = $u.stored.fingerprint; Update-CertLabel $u }
        Set-Dirty
    }
    $u.hostBox.add_TextChanged($hostChanged)
    $u.portBox.add_ValueChanged($hostChanged)
    foreach ($box in @($u.labelBox, $u.tokenBox)) { $box.add_TextChanged({ Set-Dirty }) }
    $u.secretBox.add_TextChanged({ param($s, $e) $u = $ui[[string]$s.Tag]; if ($u) { Update-SecretHint $u; Set-Dirty } })
    $u.trustBox.add_CheckedChanged({ Set-Dirty })
    $u.testBtn.add_Click({ param($s, $e) Start-UiTest $ui[[string]$s.Tag] })
    $u.trustBtn.add_Click({
        param($s, $e)
        $u = $ui[[string]$s.Tag]
        if (-not $u.pending) { return }
        $msg = "Trust this certificate for $($u.hostBox.Text.Trim())?`r`n`r`nSHA-256 fingerprint:`r`n$($u.pending)`r`n`r`nOnly say yes if it matches the fingerprint the server itself shows."
        $answer = [Windows.Forms.MessageBox]::Show($form, $msg, 'Trust this certificate', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question, [Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
        $u.pin = Format-PxFingerprint $u.pending
        $u.pending = $null
        $u.trustBtn.Enabled = $false
        Update-CertLabel $u
        Set-Dirty
        Start-UiTest $u
    })
    $u.clearBtn.add_Click({
        param($s, $e)
        $u = $ui[[string]$s.Tag]
        $answer = [Windows.Forms.MessageBox]::Show($form, "Clear connection $($u.key)? Its host, token and trusted certificate are removed when you press Save.", 'Clear connection', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
        $u.labelBox.Text = ''; $u.hostBox.Text = ''; $u.tokenBox.Text = ''; $u.secretBox.Text = ''; $u.trustBox.Checked = $false
        $u.stored = New-PxConnectionConfig $u.key $KindItems[$u.kindBox.SelectedIndex].kind
        $u.portBox.Value = $script:PxDefaultPort[$u.stored.kind]
        $u.pin = ''; Update-CertLabel $u; Update-SecretHint $u
        $u.result.Text = 'Cleared. Press Save to keep it that way.'
        Set-Dirty
    })
    $tabs.TabPages.Add($page)
    return $u
}

foreach ($c in $cfg.connections) { $ui[$c.key] = New-ConnectionTab $c }

# ---- Settings ----------------------------------------------------------------------------------------------------------
$sPage = New-Object Windows.Forms.TabPage('Settings')
$sPage.Padding = New-Object Windows.Forms.Padding(10)
$sPage.UseVisualStyleBackColor = $true
$sFlow = New-Object Windows.Forms.FlowLayoutPanel
$sFlow.Dock = [Windows.Forms.DockStyle]::Fill
$sFlow.FlowDirection = [Windows.Forms.FlowDirection]::TopDown
$sFlow.WrapContents = $false
$sFlow.AutoScroll = $true

$intervalRow = New-Flow
$intervalRow.Controls.Add((New-Label 'Refresh every'))
$intervalBox = New-Object Windows.Forms.NumericUpDown
$intervalBox.Minimum = 5; $intervalBox.Maximum = 60; $intervalBox.Increment = 5; $intervalBox.Width = 70
$intervalBox.Value = $cfg.interval
$intervalRow.Controls.Add($intervalBox)
$intervalRow.Controls.Add((New-Label 'seconds'))
$sFlow.Controls.Add($intervalRow)
$sFlow.Controls.Add((New-Label 'Every connection that is set up is checked at this interval. One that fails is checked after 2, 4, 8, then 12 intervals until it answers.' -Muted -Width 640))

$signIn = New-Object Windows.Forms.CheckBox
$signIn.Text = 'Start Proxmox Link when I sign in'
$signIn.AutoSize = $true
$signIn.Margin = New-Object Windows.Forms.Padding(3, 14, 3, 3)
$signIn.Checked = Test-Path -LiteralPath (Get-PxStartupShortcutPath)
$sFlow.Controls.Add($signIn)
$sFlow.Controls.Add((New-Label 'Adds a shortcut to your Startup folder (Settings > Apps > Startup lists it too). Changed at once.' -Muted -Width 640))

$runLabel = New-Label '' -Bold
$runLabel.Margin = New-Object Windows.Forms.Padding(3, 16, 3, 3)
$sFlow.Controls.Add($runLabel)
$runRow = New-Flow
$startBtn = New-Button 'Start'
$stopBtn = New-Button 'Stop'
$runRow.Controls.AddRange(@($startBtn, $stopBtn))
$sFlow.Controls.Add($runRow)
$sFlow.Controls.Add((New-Label 'While it runs, Proxmox Link shows an icon in the notification area with Open setup, Pause and Quit. It picks up saved changes within a few seconds.' -Muted -Width 640))

$sFlow.Controls.Add((New-Label 'With the Stream Deck plugin too' -Bold))
$sFlow.Controls.Add((New-Label 'If Proxmox & PBS Control (the Stream Deck plugin) runs on this computer as well, Proxmox Link writes the widget''s file and the plugin steps aside while Proxmox Link runs. Quit Proxmox Link and the plugin takes over again within a few seconds.' -Width 640))

$sFlow.Controls.Add((New-Label 'Files' -Bold))
$sFlow.Controls.Add((New-Label "The widget reads $($paths.StateFile). Settings and the log are in $($paths.ConfigDir)." -Width 640))
$linkRow = New-Flow
$openLogs = New-Object Windows.Forms.LinkLabel; $openLogs.Text = 'Open the log folder'; $openLogs.AutoSize = $true; $openLogs.Margin = New-Object Windows.Forms.Padding(3, 6, 16, 3)
$openState = New-Object Windows.Forms.LinkLabel; $openState.Text = 'Open the widget''s folder'; $openState.AutoSize = $true; $openState.Margin = New-Object Windows.Forms.Padding(3, 6, 3, 3)
$linkRow.Controls.AddRange(@($openLogs, $openState))
$sFlow.Controls.Add($linkRow)
$sPage.Controls.Add($sFlow)
$tabs.TabPages.Add($sPage)

# ---- API tokens --------------------------------------------------------------------------------------------------------
$hPage = New-Object Windows.Forms.TabPage('API tokens')
$hPage.Padding = New-Object Windows.Forms.Padding(10)
$hPage.UseVisualStyleBackColor = $true
$helpBox = New-Object Windows.Forms.TextBox
$helpBox.Multiline = $true
$helpBox.ReadOnly = $true
$helpBox.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
$helpBox.Dock = [Windows.Forms.DockStyle]::Fill
$helpBox.Font = New-Object Drawing.Font('Consolas', 9)
$helpBox.Text = $TokenHelp -replace "`r?`n", "`r`n"
$helpBox.add_GotFocus({ $helpBox.Select(0, 0) })   # readable, not all highlighted; select a command to copy it
$hPage.Controls.Add($helpBox)
$tabs.TabPages.Add($hPage)

# ---- bottom row ----------------------------------------------------------------------------------------------------------
$bottom = New-Object Windows.Forms.TableLayoutPanel
$bottom.ColumnCount = 2
$bottom.AutoSize = $true
$bottom.Dock = [Windows.Forms.DockStyle]::Fill
[void]$bottom.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$bottom.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
$statusLabel = New-Label '' -Muted
$bottom.Controls.Add($statusLabel, 0, 0)
$saveRow = New-Flow
$saveBtn = New-Button 'Save'
$closeBtn = New-Button 'Close'
$saveRow.Controls.AddRange(@($saveBtn, $closeBtn))
$bottom.Controls.Add($saveRow, 1, 0)
$root.Controls.Add($bottom, 0, 2)
$form.AcceptButton = $null
$form.CancelButton = $closeBtn

# ---------------------------------------------------------------------------------------------------------------------
# Behaviour
# ---------------------------------------------------------------------------------------------------------------------
function Update-RunState {
    $running = Test-PxRunning
    $runLabel.Text = $(if ($running) { 'Proxmox Link is running.' } else { 'Proxmox Link is stopped.' })
    $startBtn.Enabled = -not $running
    $stopBtn.Enabled = $running
}

function Save-Ui {
    $new = New-PxConfig
    $new.interval = [int]$intervalBox.Value
    $notes = New-Object Collections.Generic.List[string]
    for ($i = 0; $i -lt $script:PxKeys.Count; $i++) {
        $u = $ui[$script:PxKeys[$i]]
        $conn = Get-UiConnection $u
        $c = New-PxConnectionConfig $u.key $conn.kind
        $c.label = $conn.label; $c.host = $conn.host; $c.port = $conn.port; $c.tokenId = $conn.tokenId
        $c.secret = $(if ($u.secretBox.Text) { Protect-PxSecret $u.secretBox.Text.Trim() } else { $u.stored.secret })
        $c.fingerprint = [string]$u.pin
        $c.trustWindows = [bool]$u.trustBox.Checked
        $new.connections[$i] = $c
        $any = $c.host -or $c.tokenId -or $c.secret
        if ($any -and -not $conn.configured) { $notes.Add("$($u.key) is not complete (it needs a host, token ID and secret)") }
        elseif ($conn.configured -and -not $c.fingerprint -and -not $c.trustWindows) { $notes.Add("$($u.key) has no trusted certificate yet (press Test)") }
    }
    try { Save-PxConfig $new $paths.ConfigFile }
    catch { [void][Windows.Forms.MessageBox]::Show($form, "Could not save the settings: $($_.Exception.Message)", 'Proxmox Link', 'OK', 'Error'); return $false }
    $script:cfg = $new
    foreach ($k in $script:PxKeys) {
        $u = $ui[$k]
        $u.stored = $new.connections[[Array]::IndexOf($script:PxKeys, $k)]
        $u.secretBox.Text = ''
        Update-SecretHint $u
    }
    $script:dirty = $false
    $statusLabel.Text = $(if ($notes.Count) { 'Saved. Note: ' + ($notes -join '; ') + '.' } else { 'Saved.' })
    Write-PxLog 'info' 'settings saved in setup'
    if (-not $SelfTest -and -not (Test-PxRunning) -and -not $notes.Count) {
        $answer = [Windows.Forms.MessageBox]::Show($form, 'Saved. Proxmox Link is not running: start it now?', 'Proxmox Link', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -eq [Windows.Forms.DialogResult]::Yes) { Start-PxLink $linkScript }
    }
    return $true
}

$saveBtn.add_Click({ [void](Save-Ui) })
$closeBtn.add_Click({ $form.Close() })
$form.add_FormClosing({
    param($s, $e)
    if (-not $script:dirty) { return }
    $answer = [Windows.Forms.MessageBox]::Show($form, 'Save your changes?', 'Proxmox Link', [Windows.Forms.MessageBoxButtons]::YesNoCancel, [Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -eq [Windows.Forms.DialogResult]::Cancel) { $e.Cancel = $true }
    elseif ($answer -eq [Windows.Forms.DialogResult]::Yes) { if (-not (Save-Ui)) { $e.Cancel = $true } }
})
$intervalBox.add_ValueChanged({ Set-Dirty })
$signIn.add_CheckedChanged({
    try { Set-PxStartAtSignIn $signIn.Checked $linkScript; $statusLabel.Text = $(if ($signIn.Checked) { 'Proxmox Link will start when you sign in.' } else { 'Proxmox Link will no longer start when you sign in.' }) }
    catch { [void][Windows.Forms.MessageBox]::Show($form, "Could not change the Startup shortcut: $($_.Exception.Message)", 'Proxmox Link', 'OK', 'Error') }
})
$startBtn.add_Click({
    if ($script:dirty) { if (-not (Save-Ui)) { return } }
    if (-not (Test-PxRunning)) { Start-PxLink $linkScript }
    $statusLabel.Text = 'Starting Proxmox Link...'
})
$stopBtn.add_Click({
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try { $gone = Stop-PxLink 10000 } finally { $form.Cursor = [Windows.Forms.Cursors]::Default }
    $statusLabel.Text = $(if ($gone) { 'Proxmox Link stopped.' } else { 'Proxmox Link did not stop yet; try Quit on its icon.' })
    Update-RunState
})
$openLogs.add_LinkClicked({ [void][IO.Directory]::CreateDirectory($paths.LogDir); Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList "`"$($paths.LogDir)`"" })
$openState.add_LinkClicked({ [void][IO.Directory]::CreateDirectory($paths.StateDir); Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList "`"$($paths.StateDir)`"" })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 300
$tick = 0
$onTick = {
    foreach ($p in $pending.ToArray()) {
        if (-not $p.handle.IsCompleted) { continue }
        $res = $null
        try { $out = $p.ps.EndInvoke($p.handle); if ($out.Count) { $res = $out[$out.Count - 1] } } catch { $res = @{ ok = $false; error = $_.Exception.Message; cert = 'none' } }
        if ($null -eq $res) { $res = @{ ok = $false; error = 'The test did not finish.'; cert = 'none' } }
        $p.ps.Dispose(); $p.rs.Dispose()
        [void]$pending.Remove($p)
        $p.u.testBtn.Enabled = $true
        Show-TestResult $p.u $res
    }
    $script:tick++
    if ($script:tick % 5 -eq 0) { Update-RunState }
}
$timer.add_Tick($onTick)

Update-RunState
$statusLabel.Text = $(if (Test-Path -LiteralPath $paths.ConfigFile) { '' } else { 'Start with Connection A: fill it in and press Test.' })
$dirty = $false

if ($SelfTest) {
    # Built, not shown: check the parts the tests rely on (and, with -Screenshot, draw each tab to a picture), then leave.
    $ok = ($tabs.TabPages.Count -eq 5) -and ($ui.Count -eq 3) -and ($ui['A'].kindBox.Items.Count -eq 3) -and ($helpBox.Text -match 'PVEAuditor') -and ($intervalBox.Value -ge 5)
    if ($Drive) {
        # Fill in connection A as a person would, press Test, trust the certificate it shows, Test again, Save.
        $d = [ProxmoxLink.Json]::Parse([IO.File]::ReadAllText($Drive))
        $u = $ui['A']
        $u.kindBox.SelectedIndex = Get-KindIndex ([string]$d['kind'])
        $u.labelBox.Text = [string]$d['label']; $u.hostBox.Text = [string]$d['host']; $u.portBox.Value = [int]$d['port']
        $u.tokenBox.Text = [string]$d['tokenId']; $u.secretBox.Text = [string]$d['secret']
        $runTest = {
            Start-UiTest $u
            $t0 = [datetime]::UtcNow
            while ($pending.Count -and ([datetime]::UtcNow - $t0).TotalSeconds -lt 30) { Start-Sleep -Milliseconds 100; & $onTick }
            return $u.result.Text
        }
        Write-Output ('TEST1: ' + ((& $runTest) -replace "`r`n", ' | '))
        if ($u.pending -and $u.trustBtn.Enabled) {
            $u.pin = Format-PxFingerprint $u.pending
            Update-CertLabel $u
            Write-Output ('TEST2: ' + ((& $runTest) -replace "`r`n", ' | '))
        }
        Write-Output ('SAVE: ' + $(if (Save-Ui) { $statusLabel.Text } else { 'failed' }))
    }
    if ($Screenshot) {
        [void][IO.Directory]::CreateDirectory($Screenshot)
        $form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
        $form.Location = New-Object Drawing.Point(-10000, -10000)
        $form.ShowInTaskbar = $false
        $form.Show()
        $ui['A'].result.Text = "This server's certificate is not trusted yet.`r`n`r`nSHA-256 fingerprint:`r`n    AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99`r`nIssued to: CN=pve01.home.arpa`r`n`r`nCheck that it matches the fingerprint the server shows (see API tokens), then press Trust this certificate."
        for ($i = 0; $i -lt $tabs.TabPages.Count; $i++) {
            $tabs.SelectedIndex = $i
            [Windows.Forms.Application]::DoEvents()
            $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
            $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
            $bmp.Save((Join-Path $Screenshot ("setup-{0}.png" -f $i)), [Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
        }
        $form.Hide()
    }
    $form.Dispose()
    if ($ok) { Write-Output 'SELFTEST OK'; exit 0 } else { Write-Output 'SELFTEST FAILED'; exit 1 }
}

$timer.Start()
[void]$form.ShowDialog()
$timer.Stop()
foreach ($p in $pending.ToArray()) { try { $p.ps.Dispose(); $p.rs.Dispose() } catch { } }
if ($setupMutex) { try { $setupMutex.ReleaseMutex() } catch { }; $setupMutex.Dispose() }
