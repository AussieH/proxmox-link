# Proxmox Link

Proxmox Link feeds the **Proxmox Dashboard** widget for the CORSAIR XENEON EDGE (in iCUE) when you don't have a Stream
Deck. It's a small Windows program written in PowerShell, so there's nothing else to install.

It reads your Proxmox VE servers or clusters, Proxmox Backup Servers and Proxmox Datacenter Managers with a read-only
API token. It writes what it reads to one file, which the widget watches: `%APPDATA%\ProxmoxControl\state.json`. That
file contains host names, nodes, guests, storage and backups. It never contains a token or a secret.

The Stream Deck plugin **Proxmox & PBS Control** writes exactly the same file. Use whichever one suits you. If you run
both, Proxmox Link writes the file and the plugin steps aside.

## What you need

- Windows 10 or 11. Proxmox Link runs on Windows PowerShell 5.1, which comes with Windows. PowerShell 7 works too.
- iCUE 5.51 or later with the Proxmox Dashboard widget on a XENEON EDGE.
- For each server, an API token with a read-only role (see [API tokens](#api-tokens)).

## Install

1. Download `ProxmoxLink-1.0.0.zip`.
2. Unblock the zip before you extract it: right-click it, choose **Properties**, tick **Unblock**, then **OK**. You can
   do the same in PowerShell: `Unblock-File .\ProxmoxLink-1.0.0.zip`. Unblocking the zip also unblocks the files you
   extract from it.
3. Extract the zip anywhere, then double-click **Install.cmd**.

The installer:

- Copies Proxmox Link to `%LOCALAPPDATA%\Programs\ProxmoxLink`, for your account only. No administrator rights are
  needed.
- Clears the "downloaded from the internet" mark on the installed files (`Unblock-File`).
- Adds **Proxmox Link**, **Proxmox Link setup** and **Uninstall Proxmox Link** to the Start menu.
- If you answer yes, adds a shortcut to your Startup folder so Proxmox Link starts when you sign in.
- Opens setup.

By default, Windows won't run unsigned PowerShell scripts. Every shortcut therefore starts PowerShell with
`-ExecutionPolicy Bypass`, which applies to that one launch only:

```
powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "...\ProxmoxLink.ps1"
```

Your computer's execution policy and your own are never changed. One exception: if your organization sets the
execution policy by Group Policy, that policy wins over the command line, and Proxmox Link can't run.

## Set up

Open **Proxmox Link setup** from the Start menu, or double-click the tray icon.

1. **Connection A, B or C:** each connection has these fields:
   - **Type:** Proxmox VE (port 8006), Proxmox Backup Server (8007) or Proxmox Datacenter Manager (8443).
   - **Name:** shown on the widget.
   - **Host:** the host name or address only, for example `pve01.home.arpa`.
   - **Port**, **Token ID** (for example `linkreader@pve!edge`) and **Secret**.

   One Datacenter Manager covers all of its remotes.
2. **Test.** The first Test stops at the server's certificate and shows its SHA-256 fingerprint. Compare it with the
   fingerprint the server reports (see [Certificates](#certificates)), then press **Trust this certificate**. Test then
   runs again and shows what it found, for example "3 nodes (3 online), 24 guests (18 running), 5 storages".
3. **Save.** If Proxmox Link isn't running yet, setup offers to start it.
4. Under **Settings** you can change these:
   - **Refresh every:** 5 to 60 seconds, 30 by default.
   - **Start Proxmox Link when I sign in.**
   - **Start** and **Stop.**

Within a few seconds the widget shows your servers. A running Proxmox Link picks up saved changes by itself.

## API tokens

Proxmox Link only reads, so give it its own user and a token with a read-only role. Each server shows a new token's
secret only once, when you create it.

**Proxmox VE.** In a shell on any node:

```
pveum user add linkreader@pve
pveum acl modify / --users linkreader@pve --roles PVEAuditor
pveum user token add linkreader@pve edge --privsep 0
```

The token ID is `linkreader@pve!edge`. In the web UI, go to Datacenter > Permissions > API Tokens > Add and untick
*Privilege Separation*. If you keep privilege separation, give the token itself `PVEAuditor` on `/`.

**Proxmox Backup Server.** In a shell on the Backup Server:

```
proxmox-backup-manager user create linkreader@pbs
proxmox-backup-manager user generate-token linkreader@pbs edge
proxmox-backup-manager acl update / Audit --auth-id linkreader@pbs
proxmox-backup-manager acl update / Audit --auth-id 'linkreader@pbs!edge'
```

A Backup Server never gives a token more rights than its user has, so grant `Audit` to both. The `Audit` role includes
`Datastore.Audit`.

**Proxmox Datacenter Manager.** In the web UI, under Configuration > Access Control:

1. Add a user in the *pdm* realm, for example `linkreader@pdm`.
2. Add an API token for that user and copy the secret.
3. Under Permissions, give both the user and the token the **Auditor** role on `/resource`.

The Datacenter Manager reaches its remotes with its own tokens, so you don't need a token on the servers behind it.

## Certificates

Proxmox servers make their own self-signed certificates. Windows PowerShell 5.1 has no switch to skip certificate
checks for one request. Proxmox Link never turns the checks off for the whole program either. Instead it uses **trust
on first use with a pinned fingerprint**:

- Each request carries its own certificate check.
- The check accepts only the certificate whose SHA-256 fingerprint you trusted in setup for that connection.
- A different certificate is refused while the encrypted connection is still being set up. That happens before any
  request is sent, so the token never reaches a server you didn't trust.
- Requests use TLS 1.2 or later.

To see a server's own fingerprint, run this on the server itself (use port 8006, 8007 or 8443):

```
openssl s_client -connect localhost:8006 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256
```

You can also find it in the web UI:

- **Proxmox VE:** select the node, then System > Certificates.
- **Backup Server:** Dashboard > Show Fingerprint.

When a server gets a new certificate, that connection shows **TLS cert**. Test then shows the new fingerprint for you to
check and trust. If Windows already trusts a server's certificate (Let's Encrypt or another authority, renewed every
few months), you can tick **Also accept a certificate Windows trusts** for that connection.

## How it works

- **Polling:** each connection that is set up is polled at the refresh interval. Proxmox Link makes the same calls the
  Stream Deck plugin makes:
  - **Proxmox VE:** `/cluster/resources`. Also quorum and recent tasks every 30 s, and the load and version of each
    online node every 60 s, for 16 nodes at most.
  - **Backup Server:** node status, datastore usage, garbage collection and tasks. Each datastore's backup groups are
    read every 60 s.
  - **Datacenter Manager:** `/resources/list` and `/resources/status`.
- **Polling budget:** each connection is polled in its own background thread. Its requests go one at a time, with an
  8-second timeout for each request and 20 seconds for a whole poll. A connection that fails is tried again after 2,
  then 4, then 8, then every 12 intervals, until it answers. A call that the token isn't allowed to make is left alone
  for 10 minutes.
- **The file:** the format is the one in the plugin's `docs/STATE-FILE.md`, with `writer: "companion"`.
  - Proxmox Link writes the file when something changes, at most once a second, and every 5 seconds regardless. Each
    write is whole: a temporary file is moved over `state.json`.
  - iCUE holds the file open for a moment after each change. While it does, Proxmox Link rewrites the file in place.
  - When Proxmox Link quits, it writes the file once more with `running: false`.
- **Heartbeat:** every 2 seconds Proxmox Link writes `companion.json` (`{"at": <milliseconds>}`) in the same folder.
  While that heartbeat is under 5 seconds old, the Stream Deck plugin leaves `state.json` alone.

## With or without the Stream Deck plugin

- **Without the plugin:** Proxmox Link alone feeds the widget.
- **With the plugin as well:** Proxmox Link writes the file while it runs, and the plugin steps aside. Quit or pause
  Proxmox Link, and the plugin takes over again within a few seconds.
- **The plugin alone:** don't install Proxmox Link. Make sure the plugin's *Feed the XENEON EDGE widget* setting is on.

## The tray icon

While it runs, Proxmox Link shows an icon in the notification area:

- **The light:** green when every connection answers, amber when some fail, red when all fail, grey when it's paused
  or nothing is set up.
- **The tooltip** names a failing connection.
- **Right-click** for **Open setup**, **Pause** and **Quit**. Pause stops polling, tells the widget Proxmox Link has
  stopped, and lets the plugin take over if it's installed.

Only one Proxmox Link runs for each Windows user.

## What it writes, and where

| What | Where |
|---|---|
| The widget's file and the heartbeat, and nothing else | `%APPDATA%\ProxmoxControl\state.json`, `companion.json` |
| Settings, with token secrets encrypted for your Windows account (DPAPI) | `%LOCALAPPDATA%\ProxmoxLink\config.json` |
| A small log (256 KB, three old files kept), with no tokens or secrets | `%LOCALAPPDATA%\ProxmoxLink\logs` |
| The program and its shortcuts | `%LOCALAPPDATA%\Programs\ProxmoxLink`, your Start menu, and your Startup folder if you choose |

Settings are kept outside `ProxmoxControl` because the widget can read that folder. The state file holds only each
connection's host name, never a token, token ID, secret, URL or port. It also never holds a node's address, a task's
user, or a backup's owner or comment. A token secret is only ever sent to the host you entered, and only after that
host's certificate checks out.

## Uninstall

Use **Uninstall Proxmox Link** in the Start menu, or run `Uninstall.cmd`. It does the following:

- Stops Proxmox Link.
- Removes the shortcuts and the program folder.
- Asks before it deletes your settings and saved tokens.

It leaves `%APPDATA%\ProxmoxControl` alone, because the Stream Deck plugin uses that folder too.

## Troubleshooting

| The widget or setup says | What it means |
|---|---|
| Auth failed | The token ID or secret is wrong, or the token was deleted. |
| No permission | The token works but lacks a right. On a Backup Server, check the user as well as the token. |
| DNS failed / Refused / Timeout / Unreachable | Check the host name, the port and the network path. Open `https://host:port` in a browser on this computer. |
| TLS cert | The certificate isn't the one you trusted. Press Test, check the new fingerprint, and trust it if it's right. |
| Proxmox Link is not running | Start it from the Start menu, or tick **Start Proxmox Link when I sign in**. |

The log is in `%LOCALAPPDATA%\ProxmoxLink\logs`. Setup's **Settings** tab has a link to it.

## Running from the source and the tests

You can run the scripts straight from a copy of this repository:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ProxmoxLink-Setup.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ProxmoxLink.ps1 -NoTray     # in the console, Ctrl+C stops
```

The tests need Node. They run against a fake Proxmox API on `127.0.0.1` that uses made-up data, made-up tokens and
throwaway certificates. They point `APPDATA` and `LOCALAPPDATA` at a temp folder and install nothing:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
pwsh -NoProfile -File .\tests\Run-Tests.ps1
```

Some tests compare Proxmox Link's file with the Stream Deck plugin's, field for field. They need the plugin's
repository next to this one, or the `PROXMOX_PLUGIN_REPO` environment variable set to its folder. The plugin must be
built and packaged first.

`tools\Build-Release.ps1` makes `dist\ProxmoxLink-<version>.zip`.

## License

MIT. Proxmox Link is not affiliated with or endorsed by Proxmox Server Solutions GmbH or CORSAIR. Proxmox is a
registered trademark of Proxmox Server Solutions GmbH.
