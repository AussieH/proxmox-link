# Helpers for tests\Run-Tests.ps1: test certificates, child processes with their own APPDATA and LOCALAPPDATA, waiting.
# Nothing here touches the real %APPDATA%\ProxmoxControl or %LOCALAPPDATA%\ProxmoxLink.

$script:TestPass = 'test'

<# A self-signed certificate for localhost and 127.0.0.1, saved as a .pfx in a temp folder. Returns its SHA-256
   fingerprint. Made in memory: nothing is added to a certificate store. #>
function New-TestCertificate([string]$PfxPath, [string]$Name = 'localhost') {
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $req = New-Object Security.Cryptography.X509Certificates.CertificateRequest("CN=$Name", $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $san = New-Object Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder
    $san.AddDnsName('localhost')
    $san.AddIpAddress([Net.IPAddress]::Parse('127.0.0.1'))
    $req.CertificateExtensions.Add($san.Build())
    $cert = $req.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddDays(30))
    [IO.File]::WriteAllBytes($PfxPath, $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $script:TestPass))
    $fp = [ProxmoxLink.Http]::Fingerprint($cert.RawData)
    $cert.Dispose(); $rsa.Dispose()
    return $fp
}

<# Starts a process with extra environment variables; output goes to files in $LogDir. #>
function Start-TestProcess([string]$File, [string[]]$Arguments, [hashtable]$Env = @{}, [string]$LogDir, [string]$Name, [switch]$KeepStdin) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = [string]$Env[$k] }
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $out = New-Object Collections.Concurrent.ConcurrentQueue[string]
    $err = New-Object Collections.Concurrent.ConcurrentQueue[string]
    $t = [pscustomobject]@{ Process = $p; Out = $out; Err = $err; Name = $Name; LogDir = $LogDir; OutTask = $null; ErrTask = $null }
    $t.OutTask = Start-TestReader $p.StandardOutput $out
    $t.ErrTask = Start-TestReader $p.StandardError $err
    return $t
}

<# Reads a stream line by line on a thread-pool thread, into a queue. #>
function Start-TestReader($Reader, $Queue) {
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript('param($r, $q) while ($null -ne ($line = $r.ReadLine())) { $q.Enqueue($line) }').AddArgument($Reader).AddArgument($Queue)
    return @{ ps = $ps; handle = $ps.BeginInvoke(); rs = $rs }
}

function Get-TestLines($T, [switch]$Err) { $q = $T.Out; if ($Err) { $q = $T.Err }; return , @($q.ToArray()) }

function Wait-TestLine($T, [scriptblock]$Match, [int]$TimeoutMs = 15000) {
    $t0 = [datetime]::UtcNow
    while (([datetime]::UtcNow - $t0).TotalMilliseconds -lt $TimeoutMs) {
        foreach ($l in (Get-TestLines $T)) { if (& $Match $l) { return $l } }
        if ($T.Process.HasExited) { break }
        Start-Sleep -Milliseconds 100
    }
    throw "$($T.Name): no matching output (stdout: $((Get-TestLines $T) -join ' | ') stderr: $((Get-TestLines $T -Err) -join ' | '))"
}

function Stop-TestProcess($T, [int]$WaitMs = 3000) {
    if ($null -eq $T) { return }
    try { $T.Process.StandardInput.Close() } catch { }
    if (-not $T.Process.WaitForExit($WaitMs)) { try { $T.Process.Kill() } catch { }; [void]$T.Process.WaitForExit(3000) }
    foreach ($r in @($T.OutTask, $T.ErrTask)) { try { [void]$r.handle.AsyncWaitHandle.WaitOne(1000); $r.ps.Dispose(); $r.rs.Dispose() } catch { } }
    if ($T.LogDir) {
        try { (Get-TestLines $T) -join "`r`n" | Set-Content -LiteralPath (Join-Path $T.LogDir "$($T.Name).out.txt") -Encoding UTF8 } catch { }
        try { (Get-TestLines $T -Err) -join "`r`n" | Set-Content -LiteralPath (Join-Path $T.LogDir "$($T.Name).err.txt") -Encoding UTF8 } catch { }
    }
}

<# The state file as the widget would take it: whole (end: true last) or $null. #>
function Read-TestState([string]$Path) {
    try {
        $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $rd = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $text = $rd.ReadToEnd() } finally { $fs.Dispose() }
        if (-not $text.TrimEnd().EndsWith('"end":true}')) { return $null }
        $o = [ProxmoxLink.Json]::Parse($text)
        if ($o['end'] -ne $true) { return $null }
        return @{ obj = $o; text = $text }
    } catch { return $null }
}

function Wait-TestState([string]$Path, [scriptblock]$Pred, [string]$What, [int]$TimeoutMs = 20000) {
    $t0 = [datetime]::UtcNow
    $last = $null
    while (([datetime]::UtcNow - $t0).TotalMilliseconds -lt $TimeoutMs) {
        $s = Read-TestState $Path
        if ($s) { $last = $s; if (& $Pred $s.obj) { return $s } }
        Start-Sleep -Milliseconds 100
    }
    $shown = if ($last) { $last.text.Substring(0, [Math]::Min(500, $last.text.Length)) } else { 'nothing whole' }
    throw "timed out waiting for the state file: $What; it holds $shown"
}

function Get-TestConn($State, [string]$Key) { foreach ($c in $State['connections']) { if ($c['key'] -eq $Key) { return $c } }; return $null }

<# Compares two state files field for field, keys in the same order, ignoring writer, writerVersion, seq, at and each
   connection's updatedAt. Done in Node (JSON.parse keeps key order) so the comparison is independent of this code. #>
function Compare-TestFiles([string]$PluginText, [string]$LinkText, [string]$OutDir) {
    $a = Join-Path $OutDir 'compare-plugin.json'; $b = Join-Path $OutDir 'compare-link.json'
    [IO.File]::WriteAllText($a, $PluginText, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($b, $LinkText, (New-Object Text.UTF8Encoding($false)))
    $js = @'
const fs = require("fs");
const strip = (t) => { const f = JSON.parse(t); for (const k of ["writer", "writerVersion", "seq", "at"]) delete f[k]; for (const c of f.connections) delete c.updatedAt; return f; };
const a = strip(fs.readFileSync(process.argv[2], "utf8")), b = strip(fs.readFileSync(process.argv[3], "utf8"));
const sa = JSON.stringify(a, null, 1), sb = JSON.stringify(b, null, 1);
if (sa === sb) { console.log("SAME " + sa.length); process.exit(0); }
const la = sa.split("\n"), lb = sb.split("\n");
for (let i = 0; i < Math.max(la.length, lb.length); i++) if (la[i] !== lb[i]) { console.log("DIFF at line " + (i + 1) + "\nplugin: " + la.slice(Math.max(0, i - 3), i + 3).join("\n        ") + "\nlink:   " + lb.slice(Math.max(0, i - 3), i + 3).join("\n        ")); break; }
process.exit(1);
'@
    $out = Invoke-TestNode $js @($a, $b) $OutDir
    return @{ same = ($LASTEXITCODE -eq 0); text = ($out -join "`n") }
}

<# Runs a snippet of CommonJS in Node from a file (Windows PowerShell 5.1 mangles quotes in native arguments). The
   snippet's own arguments start at process.argv[2]. #>
function Invoke-TestNode([string]$Code, [string[]]$Arguments = @(), [string]$Dir = [IO.Path]::GetTempPath()) {
    $file = Join-Path $Dir ('snippet-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.cjs')
    [IO.File]::WriteAllText($file, $Code, (New-Object Text.UTF8Encoding($false)))
    try { return (& node $file @Arguments 2>&1) } finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}
