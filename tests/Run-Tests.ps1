<#
.SYNOPSIS
    Proxmox Link's tests. Run on Windows PowerShell 5.1 and, if installed, PowerShell 7:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
        pwsh -NoProfile -File tests\Run-Tests.ps1

.DESCRIPTION
    Needs Node (for the fake Proxmox API and the comparison). The comparison with the Stream Deck plugin also needs the
    plugin's repository beside this one (..\streamdeck-proxmox, or set PROXMOX_PLUGIN_REPO) with its package built
    (npm run build && npm run pack there) and its node_modules installed.

    Everything runs against a fake Proxmox API on 127.0.0.1 with made-up data and tokens and throwaway certificates,
    with APPDATA and LOCALAPPDATA pointed at a temp folder: the real %APPDATA%\ProxmoxControl and
    %LOCALAPPDATA%\ProxmoxLink are never touched, nothing is installed, and no shortcut is added to your Start menu or
    Startup folder.

.PARAMETER SkipTray
    Skip the test that starts Proxmox Link with its tray icon for a few seconds.
.PARAMETER SkipPlugin
    Skip the tests that run the Stream Deck plugin.
#>
[CmdletBinding()]
param([switch]$SkipTray, [switch]$SkipPlugin)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $Repo 'ProxmoxLink.Core.ps1')
. (Join-Path $PSScriptRoot 'TestLib.ps1')

$HostExe = (Get-Process -Id $PID).Path
$Edition = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
$OutDir = Join-Path (Join-Path $PSScriptRoot 'out') ($PSVersionTable.PSEdition.ToLowerInvariant())
[void][IO.Directory]::CreateDirectory($OutDir)
$Work = Join-Path ([IO.Path]::GetTempPath()) ('proxmox-link-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($Work)
$PluginRepo = if ($env:PROXMOX_PLUGIN_REPO) { $env:PROXMOX_PLUGIN_REPO } else { Join-Path (Split-Path -Parent $Repo) 'streamdeck-proxmox' }
$HavePlugin = (-not $SkipPlugin) -and (Test-Path -LiteralPath (Join-Path $PluginRepo 'dist\com.deaddesk.proxmox.streamDeckPlugin')) -and (Test-Path -LiteralPath (Join-Path $PluginRepo 'node_modules\ws'))
$TOK = @{
    pve = 'sdt@pve!link'; pveSecret = 'sdt-secret-pve-5e1a'
    pbs = 'sdt@pbs!link'; pbsSecret = 'sdt-secret-pbs-7c2b'
    pdm = 'sdt@pdm!link'; pdmSecret = 'sdt-secret-pdm-9d3c'
}
$Secrets = @($TOK.pveSecret, $TOK.pbsSecret, $TOK.pdmSecret, 'wrong-secret-link', $TOK.pve, $TOK.pbs, $TOK.pdm)

$results = New-Object Collections.Generic.List[object]
$script:passed = 0; $script:failed = 0; $script:skipped = 0
function T([string]$Id, [string]$Name, [scriptblock]$Body) {
    $t0 = [datetime]::UtcNow
    try {
        $note = & $Body
        $script:passed++
        $results.Add([ordered]@{ id = $Id; name = $Name; ok = $true; note = [string]($note -join ' '); seconds = [Math]::Round(([datetime]::UtcNow - $t0).TotalSeconds, 1) })
        Write-Host ("  ok    {0} {1}{2}" -f $Id, $Name, $(if ($note) { " ($($note -join ' '))" } else { '' }))
    } catch {
        $script:failed++
        $results.Add([ordered]@{ id = $Id; name = $Name; ok = $false; error = $_.Exception.Message })
        Write-Host ("  FAIL  {0} {1}`n        {2}" -f $Id, $Name, ($_.Exception.Message -replace "`n", "`n        ")) -ForegroundColor Red
    }
}
function Skip([string]$Id, [string]$Name, [string]$Why) {
    $script:skipped++
    $results.Add([ordered]@{ id = $Id; name = $Name; ok = $null; skipped = $Why })
    Write-Host "  skip  $Id $Name ($Why)" -ForegroundColor Yellow
}
function Assert-That([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$procs = New-Object Collections.Generic.List[object]
function New-LinkEnv([string]$Name) {
    $e = [pscustomobject]@{ Name = $Name; Roaming = (Join-Path $Work "$Name\roaming"); Local = (Join-Path $Work "$Name\local") }
    [void][IO.Directory]::CreateDirectory($e.Roaming); [void][IO.Directory]::CreateDirectory($e.Local)
    return $e
}
function Get-LinkPaths($E) {
    $oa = $env:APPDATA; $ol = $env:LOCALAPPDATA
    try { $env:APPDATA = $E.Roaming; $env:LOCALAPPDATA = $E.Local; return Get-PxPaths } finally { $env:APPDATA = $oa; $env:LOCALAPPDATA = $ol }
}
function Start-Link($E, [string]$Name, [switch]$Tray) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Repo 'ProxmoxLink.ps1'))
    if (-not $Tray) { $a += '-NoTray' }
    $t = Start-TestProcess $HostExe $a -Env @{ APPDATA = $E.Roaming; LOCALAPPDATA = $E.Local } -LogDir $OutDir -Name $Name
    $procs.Add($t)
    return $t
}
function Stop-LinkClean($E, $T, [int]$WaitMs = 15000) {
    $p = Get-LinkPaths $E
    $ev = $null
    if ([Threading.EventWaitHandle]::TryOpenExisting($p.QuitEventName, [ref]$ev)) { [void]$ev.Set(); $ev.Dispose() }
    $exited = $T.Process.WaitForExit($WaitMs)
    Stop-TestProcess $T
    return $exited
}
function Write-LinkConfig($E, [int]$Interval, [object[]]$Conns) {
    $cfg = New-PxConfig
    $cfg.interval = $Interval
    foreach ($c in $Conns) {
        $i = [Array]::IndexOf($script:PxKeys, $c.key)
        $o = New-PxConnectionConfig $c.key $c.kind
        foreach ($k in 'label', 'host', 'port', 'tokenId', 'fingerprint', 'trustWindows') { if ($c.ContainsKey($k)) { $o[$k] = $c[$k] } }
        if ($c.secret) { $o.secret = Protect-PxSecret $c.secret }
        $cfg.connections[$i] = $o
    }
    $path = Join-Path $E.Local 'ProxmoxLink\config.json'
    Save-PxConfig $cfg $path
    return $path
}
function Start-Plugin([string]$Name, [string]$AppData, [hashtable]$Globals) {
    $settings = Join-Path $Work "$Name-settings.json"
    [IO.File]::WriteAllText($settings, [ProxmoxLink.Json]::Stringify($Globals), (New-Object Text.UTF8Encoding($false)))
    $t = Start-TestProcess 'node' @((Join-Path $PSScriptRoot 'plugin-run.mjs'), '--repo', $PluginRepo, '--work', (Join-Path $Work 'plugin-pkg'), '--appdata', $AppData, '--settings', $settings) -LogDir $OutDir -Name $Name
    $procs.Add($t)
    [void](Wait-TestLine $t { param($l) $l -match '"registered"' } 30000)
    return $t
}
function Start-Fake([string]$Name, [string]$Pfx) {
    $log = Join-Path $Work "$Name-calls.jsonl"
    $t = Start-TestProcess 'node' @((Join-Path $PSScriptRoot 'fake-proxmox.mjs'), '--pfx', $Pfx, '--pass', 'test', '--log', $log) -LogDir $OutDir -Name $Name
    $procs.Add($t)
    $line = Wait-TestLine $t { param($l) $l -match '"port"' }
    return [pscustomobject]@{ Proc = $t; Port = [int]([ProxmoxLink.Json]::Parse($line))['port']; Log = $log }
}
function Get-Calls($Fake) {
    if (-not (Test-Path -LiteralPath $Fake.Log)) { return @() }
    $lines = [IO.File]::ReadAllLines($Fake.Log)
    return @($lines | Where-Object { $_ } | ForEach-Object { [ProxmoxLink.Json]::Parse($_) })
}
function Get-StateText([string]$Path) { $s = Read-TestState $Path; if ($s) { $s.text } else { $null } }
function Assert-NoSecrets([string]$Text, [string]$Where) {
    foreach ($s in $Secrets) { Assert-That (-not $Text.Contains($s)) "a token ID or secret is in $Where" }
    Assert-That ($Text -notmatch 'https?://') "a URL is in $Where"
    Assert-That ($Text -notmatch '192\.0\.2\.') "a node address is in $Where"
    Assert-That ($Text -notmatch 'sdt private note') "a backup comment is in $Where"
    Assert-That ($Text -notmatch '"owner"|"user"') "a backup owner or task user is in $Where"
}

Write-Host "Proxmox Link $script:PxVersion tests on $Edition ($HostExe)"
Write-Host "work folder $Work"
if (-not $HavePlugin) { Write-Host "the Stream Deck plugin is not available at $PluginRepo (or -SkipPlugin): comparison tests are skipped" -ForegroundColor Yellow }

try {
    # ---- lint ------------------------------------------------------------------------------------------------------------
    Write-Host 'Lint'
    $scripts = Get-ChildItem -LiteralPath $Repo -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '\\(out|dist|node_modules)\\' }
    T 'L1' "every script parses ($(@($scripts).Count) files)" {
        $bad = @()
        foreach ($f in $scripts) {
            $tokens = $null; $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
            foreach ($e in $errors) { $bad += "$($f.Name):$($e.Extent.StartLineNumber): $($e.Message)" }
        }
        Assert-That (-not $bad.Count) ($bad -join "`n")
    }
    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
        T 'L2' 'PSScriptAnalyzer finds no errors' {
            $found = @($scripts | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Severity Error })
            Assert-That (-not $found.Count) (($found | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName) $($_.Message)" }) -join "`n")
        }
    } else { Skip 'L2' 'PSScriptAnalyzer' 'not installed; L1 parses every script instead' }
    T 'L3' 'the shipped files hold no personal path, private address or real-looking token' {
        $shipped = @('ProxmoxLink.ps1', 'ProxmoxLink-Setup.ps1', 'ProxmoxLink.Core.ps1', 'ProxmoxLink-Install.ps1', 'Install.cmd', 'Uninstall.cmd', 'README.md', 'LICENSE') + @(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in '.ps1', '.mjs', '.md' } | ForEach-Object { "tests\$($_.Name)" })
        $bad = @()
        foreach ($f in $shipped) {
            $text = [IO.File]::ReadAllText((Join-Path $Repo $f))
            if ($text -match '[A-Za-z]:\\Users\\[A-Za-z]') { $bad += "$f has a personal path" }
            if ($text -match '\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b') { $bad += "$f has a private address ($($Matches[1]))" }
            if ($text -match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') { $bad += "$f has a UUID (Proxmox token secrets look like one)" }
            if ($text -match ('Co-' + 'Authored-By')) { $bad += "$f has an attribution trailer" }
        }
        Assert-That (-not $bad.Count) ($bad -join "`n")
    }

    # ---- units ------------------------------------------------------------------------------------------------------------
    Write-Host 'Units'
    T 'U1' 'JSON reads and writes exactly as Node does (numbers, escapes, unicode, nesting)' {
        $vec = Join-Path $Work 'json-vectors.json'
        $js = @'
const v = [0, -0, 1, -1, 0.1, 0.30000000000000004, 1e21, 1e-7, 123456789012345, 2**53, 1979120929996.8, 0.0001, 1e-6, 1.7976931348623157e308, 0.23456789, 100.5, -3.25e-5,
  "", "plain", "quote \" backslash \\ slash /", "tab\tnew\nline\r", "\u0001\u001f\u007f", "\u00e9 \u00fc \u6f22\u5b57 \ud83d\ude00", "\ud800 lone", "lone \udc00", "\u2028\u2029", "<>&'",
  true, false, null, [], {}, [[1, [2, [3]]]], { a: { b: { c: [null, true, "x"] } } }, { "dup": 1, "Dup": 2 }];
require("fs").writeFileSync(process.argv[2], JSON.stringify(v.map((x) => JSON.stringify(x))));
'@
        [void](Invoke-TestNode $js @($vec) $Work)
        Assert-That ($LASTEXITCODE -eq 0) 'node failed to make the vectors'
        $list = [ProxmoxLink.Json]::Parse([IO.File]::ReadAllText($vec, [Text.Encoding]::UTF8))
        $bad = @()
        foreach ($s in $list) { $again = [ProxmoxLink.Json]::Stringify([ProxmoxLink.Json]::Parse($s)); if ($again -ne $s -and -not ($s -match '^\{' -and $again.Length -eq $s.Length)) { $bad += "$s -> $again" } }
        Assert-That (-not $bad.Count) ($bad -join "`n")
        "$(@($list).Count) values"
    }
    T 'U2' 'host names, tags and error words match the plugin''s own functions' {
        $hosts = @('pve01.home.arpa', 'https://pve01.home.arpa:8006/', 'HTTPS://PVE01.Home.Arpa', 'user:pass@pve01:8006/x?y', '192.0.2.10', 'https://[fd00::1]:8006', '  spaced.example  ', '', 'not a host')
        $tags = @('a;b,c', 'web prod', ';;x;;', '', 'one')
        $errors = @('HTTP 401 authentication failure', 'HTTP 403 Forbidden', 'getaddrinfo ENOTFOUND x', 'connect ECONNREFUSED', 'Timeout', 'poll timeout', 'certificate not trusted', 'Bad host: x', 'HTTP 500 Internal Server Error', 'Bad JSON from Proxmox', 'TLS error', 'Unreachable')
        $mine = [ordered]@{
            hosts = @($hosts | ForEach-Object { $J::HostOnly($_) })
            tags = @($tags | ForEach-Object { , ($J::Tags($_)) })
            errors = @($errors | ForEach-Object { Get-PxFriendlyError $_ })
        }
        if (Test-Path -LiteralPath (Join-Path $PluginRepo 'src\feed.js')) {
            $in = Join-Path $Work 'u2-in.json'
            [IO.File]::WriteAllText($in, [ProxmoxLink.Json]::Stringify([ordered]@{ hosts = $hosts; tags = $tags; errors = $errors }), (New-Object Text.UTF8Encoding($false)))
            $feed = ([Uri](Join-Path $PluginRepo 'src\feed.js')).AbsoluteUri
            $api = ([Uri](Join-Path $PluginRepo 'src\api.js')).AbsoluteUri
            $js = "(async () => { const f = await import('$feed'), a = await import('$api'); const i = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8')); console.log(JSON.stringify({ hosts: i.hosts.map(f.hostOnly), tags: i.tags.map(f.tagsOf), errors: i.errors.map((m) => a.friendlyError(new Error(m))) })); })();"
            $theirs = (Invoke-TestNode $js @($in) $Work) -join ''
            Assert-That ($theirs -eq [ProxmoxLink.Json]::Stringify($mine)) "plugin: $theirs`nlink:   $([ProxmoxLink.Json]::Stringify($mine))"
            'against the plugin''s feed.js and api.js'
        } else {
            Assert-That ($mine.hosts[1] -eq 'pve01.home.arpa' -and $mine.hosts[5] -eq 'fd00::1' -and $mine.errors[0] -eq 'Auth failed' -and $mine.errors[4] -eq 'Timeout') ([ProxmoxLink.Json]::Stringify($mine))
            'against fixed answers (plugin repository not found)'
        }
    }
    T 'U3' 'token secrets: DPAPI round trip, never plain in config.json, plain refused' {
        $e = New-LinkEnv 'u3'
        $plain = 'sdt-u3-secret-8f2e'
        $blob = Protect-PxSecret $plain
        Assert-That ($blob.StartsWith('dpapi:')) 'not marked as DPAPI'
        Assert-That ((Unprotect-PxSecret $blob) -eq $plain) 'did not round-trip'
        Assert-That ($null -eq (Unprotect-PxSecret 'dpapi:AAAA')) 'garbage decrypted'
        $path = Write-LinkConfig $e 30 @(@{ key = 'A'; kind = 'pve'; host = 'pve01.home.arpa'; port = 8006; tokenId = 'u3@pve!t'; secret = $plain })
        $raw = [IO.File]::ReadAllText($path)
        Assert-That (-not $raw.Contains($plain)) 'the plain secret is in config.json'
        Assert-That ($raw.Contains('dpapi:')) 'no protected secret in config.json'
        $back = Read-PxConfig $path
        Assert-That ((Get-PxRuntimeConnection $back.connections[0]).secret -eq $plain) 'the saved secret does not read back'
        $cfg = New-PxConfig; $cfg.connections[0].secret = 'plain-text'
        $refused = $false; try { Save-PxConfig $cfg (Join-Path $e.Local 'x.json') } catch { $refused = $true }
        Assert-That $refused 'a plain secret was saved'
        Assert-That ($path.StartsWith($Work)) 'config outside the test folder'
    }
    T 'U4' 'a state file held open without delete sharing (as iCUE holds it) is still written, in place, with no temp file left' {
        $dir = Join-Path $Work 'u4'
        Assert-That ((Write-PxFileWhole $dir 'state.json' '{"n":1}') -eq 'renamed') 'first write not renamed'
        Assert-That ((Write-PxFileWhole $dir 'state.json' '{"n":2}') -eq 'renamed') 'second write not renamed'
        $held = [IO.File]::Open((Join-Path $dir 'state.json'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $how = Write-PxFileWhole $dir 'state.json' '{"n":3,"longer":true}'
            $ms = $sw.ElapsedMilliseconds
            Assert-That ($how -eq 'in place') "written $how"
            $rd = New-Object IO.StreamReader($held); $held.Position = 0; $now = $rd.ReadToEnd()
            Assert-That ($now -eq '{"n":3,"longer":true}') "the held file holds $now"
            $how2 = Write-PxFileWhole $dir 'state.json' '{"n":4}'
            $held.Position = 0; $rd.DiscardBufferedData(); $now2 = $rd.ReadToEnd()
            Assert-That ($how2 -eq 'in place' -and $now2 -eq '{"n":4}') "a shorter write left $now2"
        } finally { $held.Dispose() }
        Assert-That (-not (Test-Path -LiteralPath (Join-Path $dir 'state.json.tmp'))) 'the temp file was left'
        Assert-That ($ms -lt 200) "took $ms ms"
        "$ms ms"
    }
    T 'U5' 'typed hosts: scheme, port, path and IPv6 handled' {
        $cases = @(
            @('pve01.home.arpa', 'pve01.home.arpa', $null), @('https://pve01.home.arpa:8006/', 'pve01.home.arpa', 8006), @('pbs.home.arpa:8007', 'pbs.home.arpa', 8007),
            @('192.0.2.5', '192.0.2.5', $null), @('fd00::5', 'fd00::5', $null), @('https://[fd00::5]:8443', 'fd00::5', 8443), @('', '', $null))
        foreach ($c in $cases) {
            $r = Split-PxHostInput $c[0]
            Assert-That ($r.host -eq $c[1] -and $r.port -eq $c[2]) "'$($c[0])' -> host '$($r.host)' port '$($r.port)'"
        }
    }

    # ---- certificates --------------------------------------------------------------------------------------------------
    Write-Host 'Certificates'
    $fp1 = New-TestCertificate (Join-Path $Work 'cert1.pfx')
    $fp2 = New-TestCertificate (Join-Path $Work 'cert2.pfx')
    $S1 = Start-Fake 'fake1' (Join-Path $Work 'cert1.pfx')
    $S2 = Start-Fake 'fake2' (Join-Path $Work 'cert2.pfx')
    $pveConn = { param($port, $pin, $win = $false) [pscustomobject]@{ key = 'A'; kind = 'pve'; label = ''; host = '127.0.0.1'; port = $port; tokenId = $TOK.pve; secret = $TOK.pveSecret; pin = $pin; trustWindows = $win; configured = $true } }
    T 'C1' 'the trusted fingerprint is accepted' {
        $data = Invoke-PxApi (& $pveConn $S1.Port $fp1) '/cluster/resources'
        Assert-That (@($data).Count -gt 10) 'no resources'
    }
    T 'C2' 'a different certificate is refused before anything is sent: no request, no token' {
        $before = @(Get-Calls $S2).Count
        $r = [ProxmoxLink.Http]::Get('127.0.0.1', $S2.Port, '/cluster/resources', (Get-PxAuthHeader (& $pveConn $S2.Port $fp1)), $fp1, $false, 8000, $true)
        Assert-That ($r.CertSeen -and -not $r.CertAccepted) 'the certificate was not refused'
        Assert-That ($r.Fingerprint -eq $fp2) 'the presented fingerprint was not reported'
        Assert-That ((Get-PxFriendlyError $r.Error) -eq 'TLS cert') "error: $($r.Error)"
        Start-Sleep -Milliseconds 300
        Assert-That (@(Get-Calls $S2).Count -eq $before) 'a request reached the server with the wrong certificate'
        $t = Test-PxConnection (& $pveConn $S2.Port $fp1)
        Assert-That ($t.cert -eq 'changed' -and $t.fingerprint -eq $fp2 -and -not $t.ok) "setup's Test said $($t.cert)"
    }
    T 'C3' 'with nothing trusted yet, Test shows the fingerprint and sends nothing' {
        $before = @(Get-Calls $S1).Count
        $t = Test-PxConnection (& $pveConn $S1.Port '')
        Assert-That ($t.cert -eq 'new' -and $t.fingerprint -eq $fp1 -and -not $t.ok) "Test said $($t.cert) $($t.fingerprint)"
        Start-Sleep -Milliseconds 300
        Assert-That (@(Get-Calls $S1).Count -eq $before) 'a request reached the server before the certificate was trusted'
    }
    T 'C4' '"accept a certificate Windows trusts" does not accept a self-signed one' {
        $r = [ProxmoxLink.Http]::Get('127.0.0.1', $S1.Port, '/cluster/resources', 'x', '', $true, 8000, $true)
        Assert-That ($r.CertSeen -and -not $r.CertAccepted -and -not $r.CertTrustedByWindows) 'a self-signed certificate was accepted'
    }
    T 'C5' 'certificate checks are never switched off for the process' {
        Assert-That ($null -eq [Net.ServicePointManager]::ServerCertificateValidationCallback) 'a process-wide callback is set'
        $proto = [Net.ServicePointManager]::SecurityProtocol
        Assert-That (($proto -band [Net.SecurityProtocolType]::Tls12) -and -not ($proto -band [Net.SecurityProtocolType]::Tls) -and -not ($proto -band [Net.SecurityProtocolType]::Tls11)) "protocols: $proto"
        "TLS: $proto"
    }
    T 'C6' 'setup''s Test with the trusted certificate: counts and versions' {
        $t = Test-PxConnection (& $pveConn $S1.Port $fp1)
        Assert-That ($t.ok -and $t.cert -eq 'pinned') "Test: $($t.error)"
        Assert-That ($t.summary -match '3 nodes \(2 online\), 17 guests \(16 running\), 4 storages, cluster sdt-lab, Proxmox VE 9\.0\.6') $t.summary
        $pbs = [pscustomobject]@{ key = 'C'; kind = 'pbs'; label = ''; host = '127.0.0.1'; port = $S1.Port; tokenId = $TOK.pbs; secret = $TOK.pbsSecret; pin = $fp1; trustWindows = $false; configured = $true }
        $t2 = Test-PxConnection $pbs
        Assert-That ($t2.ok -and $t2.summary -match '3 datastores, 5 backup groups, Backup Server 4\.0\.14') $t2.summary
        $bad = [pscustomobject]@{ key = 'A'; kind = 'pve'; label = ''; host = '127.0.0.1'; port = $S1.Port; tokenId = $TOK.pve; secret = 'wrong'; pin = $fp1; trustWindows = $false; configured = $true }
        Assert-That ((Test-PxConnection $bad).error -eq 'Auth failed') 'a wrong secret did not say Auth failed'
        $t.summary
    }

    # ---- the plugin and Proxmox Link side by side ----------------------------------------------------------------------
    Write-Host 'Proxmox Link against the Stream Deck plugin'
    $hostUrl = "https://127.0.0.1:$($S1.Port)"
    $globals1 = @{
        pollSeconds = 5; feedWidget = $true
        connA_kind = 'pve'; connA_name = 'sdt-cluster'; connA_host = $hostUrl; connA_token = $TOK.pve; connA_secret = $TOK.pveSecret; connA_insecure = $true
        connB_kind = 'pdm'; connB_name = 'sdt-dc'; connB_host = $hostUrl; connB_token = $TOK.pdm; connB_secret = $TOK.pdmSecret; connB_insecure = $true
        connC_kind = 'pbs'; connC_name = 'sdt-pbs'; connC_host = $hostUrl; connC_token = $TOK.pbs; connC_secret = $TOK.pbsSecret; connC_insecure = $true
    }
    $link1 = @(
        @{ key = 'A'; kind = 'pve'; label = 'sdt-cluster'; host = '127.0.0.1'; port = $S1.Port; tokenId = $TOK.pve; secret = $TOK.pveSecret; fingerprint = $fp1 },
        @{ key = 'B'; kind = 'pdm'; label = 'sdt-dc'; host = '127.0.0.1'; port = $S1.Port; tokenId = $TOK.pdm; secret = $TOK.pdmSecret; fingerprint = $fp1 },
        @{ key = 'C'; kind = 'pbs'; label = 'sdt-pbs'; host = '127.0.0.1'; port = $S1.Port; tokenId = $TOK.pbs; secret = $TOK.pbsSecret; fingerprint = $fp1 })
    $settled = {
        param($f)
        $a = Get-TestConn $f 'A'; $b = Get-TestConn $f 'B'; $c = Get-TestConn $f 'C'
        $f['ready'] -and $a['ok'] -and $a['cluster'] -and $a['tasks'] -and (@($a['nodes'] | Where-Object { $_['load'] }).Count -eq 2) -and $b['ok'] -and $b['remotes'] -and $c['ok'] -and (@($c['groups']).Count -eq 5) -and (@($c['groups'] | Where-Object { $_['id'] -eq '100' -and $_['name'] }).Count -eq 1)
    }
    $E1 = New-LinkEnv 'link1'
    [void](Write-LinkConfig $E1 5 $link1)
    $P1dir = Join-Path $Work 'plugin1'
    $L1 = Start-Link $E1 'link1'
    $P1 = $null
    if ($HavePlugin) { $P1 = Start-Plugin 'plugin1' $P1dir $globals1 }
    $p1State = Join-Path $P1dir 'ProxmoxControl\state.json'
    $l1Paths = Get-LinkPaths $E1

    T 'I1' 'Proxmox Link writes the file: a Proxmox VE cluster, a Datacenter Manager and a Backup Server, writer "companion"' {
        $s = Wait-TestState $l1Paths.StateFile $settled 'all three connections settled' 30000
        $f = $s.obj
        Assert-That ($f['writer'] -eq 'companion' -and $f['writerVersion'] -eq $script:PxVersion -and $f['schema'] -eq 1 -and $f['app'] -eq 'Proxmox & PBS Control' -and $f['interval'] -eq 5) 'header'
        Assert-That ($s.text.EndsWith(',"end":true}')) 'end: true is not last'
        $a = Get-TestConn $f 'A'
        Assert-That ($a['host'] -eq '127.0.0.1' -and @($a['guests']).Count -eq 17 -and $a['templates'] -eq 1) 'connection A'
        Assert-That ((Get-TestConn $f 'C')['groups'][0]['id'] -eq '200') 'groups newest first'
        Assert-That ($l1Paths.StateFile.StartsWith($Work)) 'state file outside the test folder'
        $L1.Process.Refresh()
        "Proxmox Link uses $([Math]::Round($L1.Process.WorkingSet64 / 1MB)) MB with three connections"
    }
    if ($HavePlugin) {
        T 'I2' 'field for field the same file as the Stream Deck plugin''s, for the same servers (apart from writer, times and seq)' {
            $ps = Wait-TestState $p1State $settled 'the plugin settled' 30000
            Start-Sleep -Milliseconds 1500
            $ps = Read-TestState $p1State; $ls = Read-TestState $l1Paths.StateFile
            Assert-That ($ps.obj['writer'] -eq 'plugin') 'the plugin''s file is not the plugin''s'
            $cmp = Compare-TestFiles $ps.text $ls.text $OutDir
            Assert-That $cmp.same $cmp.text
            $n = 0; foreach ($c in $ls.obj['connections']) { $n += @($c['guests']).Count + @($c['nodes']).Count + @($c['storages']).Count + @($c['groups']).Count + @($c['datastores']).Count + @($c['tasks']).Count }
            "identical, $($ls.text.Length) bytes, $n list entries"
        }
    } else { Skip 'I2' 'field-for-field comparison with the plugin' 'plugin not available' }
    T 'I3' 'no token, token ID, secret, URL, node address, owner, user or comment in the file or the log' {
        $text = Get-StateText $l1Paths.StateFile
        Assert-NoSecrets $text 'the state file'
        $log = [IO.File]::ReadAllText((Join-Path $l1Paths.LogDir 'ProxmoxLink.log'))
        foreach ($s in @($TOK.pveSecret, $TOK.pbsSecret, $TOK.pdmSecret)) { Assert-That (-not $log.Contains($s)) 'a secret is in the log' }
        $cfg = [IO.File]::ReadAllText($l1Paths.ConfigFile)
        foreach ($s in @($TOK.pveSecret, $TOK.pbsSecret, $TOK.pdmSecret)) { Assert-That (-not $cfg.Contains($s)) 'a plain secret is in config.json' }
        $files = @(Get-ChildItem -LiteralPath $l1Paths.StateDir -File | ForEach-Object { $_.Name } | Sort-Object)
        Assert-That (($files -join ',') -eq 'companion.json,state.json') "the widget's folder holds $($files -join ', ')"
    }
    T 'I4' 'the heartbeat: companion.json {"at": ms}, fresh every 2 s' {
        $c1 = [ProxmoxLink.Json]::Parse([IO.File]::ReadAllText($l1Paths.CompanionFile))
        Assert-That (@($c1.Keys).Count -eq 1 -and $c1['at'] -is [double]) "companion.json: $([IO.File]::ReadAllText($l1Paths.CompanionFile))"
        Start-Sleep -Milliseconds 2600
        $c2 = [ProxmoxLink.Json]::Parse([IO.File]::ReadAllText($l1Paths.CompanionFile))
        Assert-That (($c2['at'] - $c1['at']) -ge 1500 -and ([ProxmoxLink.Js]::Now() - $c2['at']) -lt 3000) 'not refreshed every 2 s'
    }
    T 'I5' 'while the state file is held open without delete sharing, Proxmox Link keeps writing it (in place)' {
        $seq0 = (Read-TestState $l1Paths.StateFile).obj['seq']
        $held = [IO.File]::Open($l1Paths.StateFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { Start-Sleep -Milliseconds 6500 } finally { $held.Dispose() }
        $s = Read-TestState $l1Paths.StateFile
        Assert-That ($s.obj['seq'] -gt $seq0) "seq stayed at $seq0"
        $log = [IO.File]::ReadAllText((Join-Path $l1Paths.LogDir 'ProxmoxLink.log'))
        Assert-That ($log -match 'state file: in place') 'the log does not show an in-place write'
        Assert-That (-not (Test-Path -LiteralPath "$($l1Paths.StateFile).tmp")) 'a temp file was left'
        "seq $seq0 -> $($s.obj['seq'])"
    }
    T 'I6' 'a second copy for the same user leaves at once' {
        $second = Start-Link $E1 'link1-second'
        Assert-That ($second.Process.WaitForExit(20000)) 'the second copy is still running'
        Stop-TestProcess $second
        Assert-That (@((Get-TestLines $second) -match 'already running').Count -gt 0) 'it did not say so'
        Assert-That (-not $L1.Process.HasExited) 'the first copy stopped'
    }
    T 'I7' 'saved settings are picked up while running' {
        $cfg = Read-PxConfig $l1Paths.ConfigFile
        $cfg.connections[0].label = 'sdt-renamed'
        Save-PxConfig $cfg $l1Paths.ConfigFile
        [void](Wait-TestState $l1Paths.StateFile { param($f) (Get-TestConn $f 'A')['label'] -eq 'sdt-renamed' -and (Get-TestConn $f 'A')['ok'] } 'the new name' 20000)
    }
    T 'I8' 'a clean exit writes running: false and removes the heartbeat' {
        Assert-That (Stop-LinkClean $E1 $L1) 'Proxmox Link did not exit when asked'
        $s = Read-TestState $l1Paths.StateFile
        Assert-That ($s.obj['running'] -eq $false -and $s.obj['writer'] -eq 'companion') "last file: running $($s.obj['running'])"
        Assert-That (-not (Test-Path -LiteralPath $l1Paths.CompanionFile)) 'companion.json is still there'
    }

    if ($HavePlugin) {
        T 'I9' 'with the plugin running too, the plugin steps aside while Proxmox Link''s heartbeat is fresh, and takes over when it quits' {
            # Proxmox Link now writes into the plugin's folder.
            $shared = [pscustomobject]@{ Name = 'shared'; Roaming = $P1dir; Local = $E1.Local }
            $sp = Get-LinkPaths $shared
            Assert-That ((Read-TestState $p1State).obj['writer'] -eq 'plugin') 'the plugin was not writing'
            $L1b = Start-Link $shared 'link1-shared'
            [void](Wait-TestState $p1State { param($f) $f['writer'] -eq 'companion' -and $f['ready'] } 'Proxmox Link writing' 20000)
            Start-Sleep -Milliseconds 4000   # the plugin checks the heartbeat every 2 s
            $writers = @{}; $t0 = [datetime]::UtcNow; $reads = 0
            while (([datetime]::UtcNow - $t0).TotalSeconds -lt 10) { $s = Read-TestState $p1State; if ($s) { $writers[$s.obj['writer']] = 1 + [int]$writers[$s.obj['writer']]; $reads++ }; Start-Sleep -Milliseconds 100 }
            Assert-That (-not $writers.ContainsKey('plugin')) "the plugin still wrote ($($writers['plugin']) of $reads reads)"
            Assert-That (Stop-LinkClean $shared $L1b) 'Proxmox Link did not exit'
            $back = Wait-TestState $p1State { param($f) $f['writer'] -eq 'plugin' -and $f['running'] -ne $false } 'the plugin taking over' 15000
            "$reads reads all by Proxmox Link; the plugin back after it quit"
        }
    } else { Skip 'I9' 'the plugin steps aside' 'plugin not available' }

    # ---- failures: the same errors as the plugin, and the back-off -------------------------------------------------------
    Write-Host 'Failures and back-off'
    $globals2 = @{
        pollSeconds = 5; feedWidget = $true
        connA_kind = 'pve'; connA_name = 'sdt-broken'; connA_host = $hostUrl; connA_token = $TOK.pve; connA_secret = 'wrong-secret-plugin'; connA_insecure = $true
        connB_kind = 'pve'; connB_name = 'sdt-off'; connB_host = 'https://127.0.0.1:1'; connB_token = $TOK.pve; connB_secret = $TOK.pveSecret; connB_insecure = $true
    }
    $link2 = @(
        @{ key = 'A'; kind = 'pve'; label = 'sdt-broken'; host = '127.0.0.1'; port = $S1.Port; tokenId = $TOK.pve; secret = 'wrong-secret-link'; fingerprint = $fp1 },
        @{ key = 'B'; kind = 'pve'; label = 'sdt-off'; host = '127.0.0.1'; port = 1; tokenId = $TOK.pve; secret = $TOK.pveSecret; fingerprint = $fp1 })
    $E2 = New-LinkEnv 'link2'
    [void](Write-LinkConfig $E2 5 $link2)
    $l2Paths = Get-LinkPaths $E2
    $P2dir = Join-Path $Work 'plugin2'
    $L2 = Start-Link $E2 'link2'
    $L2start = [ProxmoxLink.Js]::Now()
    $P2 = $null
    if ($HavePlugin) { $P2 = Start-Plugin 'plugin2' $P2dir $globals2 }
    $failed2 = { param($f) $f['ready'] -and (Get-TestConn $f 'A')['error'] -eq 'Auth failed' -and (Get-TestConn $f 'B')['error'] -eq 'Refused' }
    T 'F1' 'a wrong secret says Auth failed, a closed port Refused, a connection not set up says so' {
        $s = Wait-TestState $l2Paths.StateFile $failed2 'the errors' 30000
        $c = Get-TestConn $s.obj 'C'
        Assert-That ($c['configured'] -eq $false -and $c['kind'] -eq 'pbs' -and $c['label'] -eq 'C' -and $null -eq $c['host'] -and @($c.Keys).Count -eq 5) 'connection C'
        $a = Get-TestConn $s.obj 'A'
        Assert-That ($a['ok'] -eq $false -and $null -eq $a['updatedAt'] -and @($a.Keys).Count -eq 8) 'connection A'
    }
    if ($HavePlugin) {
        T 'F2' 'the same failing file as the plugin''s, field for field' {
            $ps = Wait-TestState (Join-Path $P2dir 'ProxmoxControl\state.json') $failed2 'the plugin''s errors' 30000
            $ls = Read-TestState $l2Paths.StateFile
            $cmp = Compare-TestFiles $ps.text $ls.text $OutDir
            Assert-That $cmp.same $cmp.text
            'identical'
        }
    } else { Skip 'F2' 'the failing file against the plugin''s' 'plugin not available' }
    T 'F3' 'a failing connection backs off: tried again after 2 intervals, then 4' {
        $t0 = [datetime]::UtcNow
        while (([datetime]::UtcNow - $t0).TotalSeconds -lt 45) {
            $mine = @(Get-Calls $S1 | Where-Object { $_['who'] -eq 'bad:link' })
            if ($mine.Count -ge 3) { break }
            Start-Sleep -Milliseconds 500
        }
        Assert-That ($mine.Count -ge 3) "only $($mine.Count) attempts in 45 s"
        $d1 = ($mine[1]['t'] - $mine[0]['t']) / 1000; $d2 = ($mine[2]['t'] - $mine[1]['t']) / 1000
        Assert-That ($d1 -ge 9.5 -and $d1 -le 12) "second try after $d1 s (want 10)"
        Assert-That ($d2 -ge 19.5 -and $d2 -le 22.5) "third try after $d2 s (want 20)"
        $theirs = @(Get-Calls $S1 | Where-Object { $_['who'] -eq 'bad:plugin' })
        $pd = @(); for ($i = 1; $i -lt $theirs.Count; $i++) { $pd += [Math]::Round(($theirs[$i]['t'] - $theirs[$i - 1]['t']) / 1000, 1) }
        "Proxmox Link: after $([Math]::Round($d1, 1)) s, then $([Math]::Round($d2, 1)) s; the plugin: $($pd -join ', ') s"
    }
    [void](Stop-LinkClean $E2 $L2)
    Stop-TestProcess $P2; Stop-TestProcess $P1

    # ---- the tray, setup and install ---------------------------------------------------------------------------------------
    Write-Host 'Tray, setup, install'
    if (-not $SkipTray) {
        T 'W1' 'with its tray icon: starts, writes "nothing set up", quits cleanly when setup''s Stop asks' {
            $E3 = New-LinkEnv 'tray'
            $p3 = Get-LinkPaths $E3
            $L3 = Start-Link $E3 'tray' -Tray
            $s = Wait-TestState $p3.StateFile { param($f) $f['ready'] -and @($f['connections']).Count -eq 3 } 'a first file' 30000
            Assert-That (@($s.obj['connections'] | Where-Object { $_['configured'] }).Count -eq 0) 'something is set up'
            Assert-That (-not $L3.Process.HasExited) 'the tray process ended'
            Assert-That (Stop-LinkClean $E3 $L3) 'it did not quit'
            Assert-That ((Read-TestState $p3.StateFile).obj['running'] -eq $false) 'no running: false'
        }
    } else { Skip 'W1' 'tray icon' '-SkipTray' }
    T 'W2' 'setup builds its window (connections A, B, C, Settings, API tokens)' {
        $E4 = New-LinkEnv 'setup'
        $t = Start-TestProcess $HostExe @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Repo 'ProxmoxLink-Setup.ps1'), '-SelfTest') -Env @{ APPDATA = $E4.Roaming; LOCALAPPDATA = $E4.Local } -LogDir $OutDir -Name 'setup'
        Assert-That ($t.Process.WaitForExit(60000)) 'setup did not finish'
        Stop-TestProcess $t
        Assert-That ($t.Process.ExitCode -eq 0 -and ((Get-TestLines $t) -contains 'SELFTEST OK')) "exit $($t.Process.ExitCode): $((Get-TestLines $t) -join ' ') $((Get-TestLines $t -Err) -join ' ')"
    }
    T 'W2b' 'setup used as a person would: Test shows the fingerprint, Trust, Test connects, Save keeps the secret encrypted' {
        $E6 = New-LinkEnv 'setup-drive'
        $drive = Join-Path $Work 'drive.json'
        [IO.File]::WriteAllText($drive, [ProxmoxLink.Json]::Stringify([ordered]@{ kind = 'pve'; label = 'sdt-ui'; host = "https://127.0.0.1:$($S1.Port)/"; port = 8006; tokenId = $TOK.pve; secret = $TOK.pveSecret }))
        $t = Start-TestProcess $HostExe @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Repo 'ProxmoxLink-Setup.ps1'), '-SelfTest', '-Drive', $drive) -Env @{ APPDATA = $E6.Roaming; LOCALAPPDATA = $E6.Local } -LogDir $OutDir -Name 'setup-drive'
        Assert-That ($t.Process.WaitForExit(90000)) 'setup did not finish'
        Stop-TestProcess $t
        $lines = Get-TestLines $t
        $t1 = @($lines | Where-Object { $_ -like 'TEST1:*' })[0]; $t2 = @($lines | Where-Object { $_ -like 'TEST2:*' })[0]; $sv = @($lines | Where-Object { $_ -like 'SAVE:*' })[0]
        Assert-That ($t1 -match 'not trusted yet' -and $t1.Contains($fp1)) "first Test: $t1"
        Assert-That ($t2 -match 'Connected: 3 nodes \(2 online\), 17 guests' -and $t2 -match 'Certificate: trusted') "second Test: $t2"
        Assert-That ($sv -match '^SAVE: Saved') "save: $sv"
        $cfgPath = Join-Path $E6.Local 'ProxmoxLink\config.json'
        $raw = [IO.File]::ReadAllText($cfgPath)
        Assert-That (-not $raw.Contains($TOK.pveSecret) -and $raw.Contains('dpapi:')) 'the secret is not encrypted in config.json'
        $c = (Read-PxConfig $cfgPath).connections[0]
        Assert-That ($c.host -eq '127.0.0.1' -and $c.port -eq $S1.Port -and $c.label -eq 'sdt-ui' -and $c.fingerprint -eq $fp1) "saved: $($c.host):$($c.port) $($c.fingerprint)"
        'typed https://127.0.0.1:port/ became host and port'
    }
    T 'W3' 'install and uninstall (into a test folder): files, icon, Start menu and Startup shortcuts, then all removed' {
        $E5 = New-LinkEnv 'install'
        $dest = Join-Path $Work 'install\Programs\ProxmoxLink'; $menu = Join-Path $Work 'install\StartMenu'; $start = Join-Path $Work 'install\Startup'
        [void][IO.Directory]::CreateDirectory($menu); [void][IO.Directory]::CreateDirectory($start)
        $common = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Repo 'ProxmoxLink-Install.ps1'), '-Destination', $dest, '-ProgramsDir', $menu, '-StartupDir', $start)
        $t = Start-TestProcess $HostExe ($common + @('-Startup', '-NoLaunch')) -Env @{ APPDATA = $E5.Roaming; LOCALAPPDATA = $E5.Local } -LogDir $OutDir -Name 'install'
        Assert-That ($t.Process.WaitForExit(60000)) 'install did not finish'
        Stop-TestProcess $t
        Assert-That ($t.Process.ExitCode -eq 0) "install exit $($t.Process.ExitCode): $((Get-TestLines $t -Err) -join ' ')"
        foreach ($f in 'ProxmoxLink.ps1', 'ProxmoxLink-Setup.ps1', 'ProxmoxLink.Core.ps1', 'ProxmoxLink-Install.ps1', 'Install.cmd', 'Uninstall.cmd', 'README.md', 'LICENSE', 'ProxmoxLink.ico') { Assert-That (Test-Path -LiteralPath (Join-Path $dest $f)) "$f was not installed" }
        $shell = New-Object -ComObject WScript.Shell
        foreach ($l in @((Join-Path $menu 'Proxmox Link\Proxmox Link.lnk'), (Join-Path $menu 'Proxmox Link\Proxmox Link setup.lnk'), (Join-Path $start 'Proxmox Link.lnk'))) {
            Assert-That (Test-Path -LiteralPath $l) "$l is missing"
            $lnk = $shell.CreateShortcut($l)
            Assert-That ($lnk.TargetPath -match 'WindowsPowerShell\\v1\.0\\powershell\.exe$') "$l runs $($lnk.TargetPath)"
            Assert-That ($lnk.Arguments -match '^-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' -and $lnk.Arguments.Contains($dest)) "$l arguments: $($lnk.Arguments)"
        }
        Assert-That (Test-Path -LiteralPath (Join-Path $menu 'Proxmox Link\Uninstall Proxmox Link.lnk')) 'no uninstall shortcut'
        $zone = Get-Item -LiteralPath (Join-Path $dest 'ProxmoxLink.ps1') -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue
        Assert-That ($null -eq $zone) 'the installed copy still carries the mark of the web'
        $u = Start-TestProcess $HostExe ($common + @('-Uninstall', '-RemoveSettings')) -Env @{ APPDATA = $E5.Roaming; LOCALAPPDATA = $E5.Local } -LogDir $OutDir -Name 'uninstall'
        Assert-That ($u.Process.WaitForExit(60000)) 'uninstall did not finish'
        Stop-TestProcess $u
        Assert-That ($u.Process.ExitCode -eq 0) "uninstall exit $($u.Process.ExitCode)"
        Assert-That (-not (Test-Path -LiteralPath $dest)) 'the program folder is still there'
        Assert-That (-not (Test-Path -LiteralPath (Join-Path $menu 'Proxmox Link'))) 'the Start menu folder is still there'
        Assert-That (-not (Test-Path -LiteralPath (Join-Path $start 'Proxmox Link.lnk'))) 'the Startup shortcut is still there'
    }
} finally {
    foreach ($p in $procs) { try { if (-not $p.Process.HasExited) { Stop-TestProcess $p } } catch { } }
    $summary = [ordered]@{ when = (Get-Date).ToString('s'); host = $Edition; passed = $script:passed; failed = $script:failed; skipped = $script:skipped; results = $results.ToArray() }
    [IO.File]::WriteAllText((Join-Path $OutDir 'results.json'), (Format-PxJson ([ProxmoxLink.Json]::Stringify($summary))), (New-Object Text.UTF8Encoding($false)))
    Write-Host ''
    Write-Host ("{0} passed, {1} failed, {2} skipped on {3}" -f $script:passed, $script:failed, $script:skipped, $Edition)
    if ($script:failed -eq 0) { try { Remove-Item -LiteralPath $Work -Recurse -Force } catch { } } else { Write-Host "left for a look: $Work" }
}
exit $(if ($script:failed) { 1 } else { 0 })
