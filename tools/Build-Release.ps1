<#
.SYNOPSIS
    Makes dist\ProxmoxLink-<version>.zip: the scripts, Install.cmd, Uninstall.cmd, README and LICENSE in one folder.
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\Build-Release.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'ProxmoxLink.Core.ps1')
$version = $script:PxVersion
$files = @('ProxmoxLink.ps1', 'ProxmoxLink-Setup.ps1', 'ProxmoxLink.Core.ps1', 'ProxmoxLink-Install.ps1', 'Install.cmd', 'Uninstall.cmd', 'README.md', 'LICENSE')
$dist = Join-Path $repo 'dist'
[void][IO.Directory]::CreateDirectory($dist)
$zip = Join-Path $dist "ProxmoxLink-$version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in $files) {
        $text = [IO.File]::ReadAllText((Join-Path $repo $f))
        if ($text -match '[^\x00-\x7F]') { throw "$f has non-ASCII characters (Windows PowerShell 5.1 would misread them)" }
        # Windows line endings in the release, whatever git checked out.
        $text = $text -replace "`r?`n", "`r`n"
        $entry = $archive.CreateEntry("ProxmoxLink-$version/$f", [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::Now
        $w = New-Object IO.StreamWriter($entry.Open(), (New-Object Text.UTF8Encoding($false)))
        try { $w.Write($text) } finally { $w.Dispose() }
    }
} finally { $archive.Dispose() }
$size = (Get-Item -LiteralPath $zip).Length
Write-Host "$zip ($([Math]::Round($size / 1KB, 1)) KB, $($files.Count) files)"
