# The XENEON EDGE state file

`%APPDATA%\ProxmoxControl\state.json`: what Proxmox Link knows about its connections, for the **Proxmox Dashboard**
widget in CORSAIR iCUE on a XENEON EDGE. The Stream Deck plugin Proxmox & PBS Control (2.1.0 and later) writes the
identical file with `writer: "plugin"`; Proxmox Link writes it with `writer: "companion"`. Proxmox Link's tests
compare the two field for field. The descriptions of when the file is written and how connections are polled below are
the plugin's; Proxmox Link follows them, except that its refresh interval defaults to 30 s.

## Why a file

An iCUE widget cannot call the Proxmox API itself. iCUE enforces CORS for widgets (their Origin is `file://`), and
Proxmox sends no `Access-Control-Allow-Origin` (its `OPTIONS` answer is 501), so every request is blocked; only an
opaque `no-cors` request gets through, and it cannot be read. The self-signed certificate was not the problem: iCUE's
`self-signed-certificate` permission connected fine. Tested on a XENEON EDGE.

A widget can read files in a folder under the user's home through iCUE's undocumented FileSystem plugin
(`widgetbuilder.filesystemprovider:FileSystem:1.0`, a `folder` permission for `<Home>/AppData/Roaming/ProxmoxControl/`),
and iCUE delivers the whole file on each change. The plugin already polls every connection with the user's tokens, so
it writes what it reads.

## When it is written

- **At start**, before Stream Deck answers: the folder and a first file (`ready: false`, no connections). iCUE only
  watches a folder that existed when the widget was added, so the folder is made as early as possible.
- **On a change**, at most once a second, and **every 5 s** regardless, so the widget can tell a quiet estate from a
  plugin that stopped (the widget calls a file older than 60 s stale).
- **On exit** (when Node gets to run its exit handlers): once more with `running: false`.
- **Feed turned off** (the setting *Feed the XENEON EDGE widget*): once, with `enabled: false` and no connections; then
  nothing until it is turned on again.
- **A companion running:** it writes `companion.json` (`{"at": <ms>}`) in the same folder every 2 s; while that is
  under 5 s old the plugin leaves `state.json` alone.
- Windows only (iCUE is Windows-only); on macOS nothing is written.

Writes are whole: `state.json.tmp`, then renamed over `state.json`. iCUE holds `state.json` open without delete
sharing for a moment after each change, and Windows then refuses the rename; after one retry 5 ms later the file is
rewritten in place (Node opens files with read, write and delete sharing). `end: true` is always the last key, so a
read cut short does not parse, or parses without it, and is skipped.

## Polling

The feed uses the plugin's own polling: every connection that is set up is polled at the *Refresh every* interval
(5 to 60 s, default 10), as if one of its keys were on screen. A connection that fails is polled after 2, 4, 8, then
12 intervals until it answers. On a Proxmox VE connection the feed adds three light calls: `GET /cluster/status`
(quorum) and `GET /cluster/tasks` every 30 s, `GET /nodes/{node}/status` (load, version) for each online node (16 at
most) every 60 s. A call that fails is left alone for 10 minutes. Backup Server and Datacenter Manager connections add
nothing: everything comes from the calls the keys already make.

## The format

Times: `at` and `updatedAt` are Unix **milliseconds**; every time that comes from Proxmox (`start`, `end`, `last`,
`lastBackup`, `gc.at`, `verify.at`, `fullAt`) is Unix **seconds**, as Proxmox gives it. Sizes are bytes. CPU is a
fraction of the node's or guest's cores (0 to 1). Anything unknown is `null`. Lists are capped: 64 nodes, 600 guests, 120 storages, 15 tasks, 32 datastores, 400 backup groups, 32 remotes per
connection.

```json
{
  "app": "Proxmox & PBS Control", "schema": 1, "writer": "plugin", "writerVersion": "2.1.0",
  "enabled": true, "running": true, "interval": 10, "ready": true,
  "connections": [ { "key": "A", ... }, { "key": "B", ... }, { "key": "C", ... } ],
  "seq": 42, "at": 1759600000123, "end": true
}
```

| Field | Meaning |
|---|---|
| `schema` | this format's version; a reader refuses a higher one ("update the widget") |
| `writer` | `plugin` or `companion` |
| `writerVersion` | the writer's version |
| `enabled` | false when the user turned the feed off; `connections` is then empty |
| `running` | false on the writer's last write |
| `ready` | false until the plugin has its settings (the first file at start) |
| `interval` | the refresh interval in seconds |
| `seq` | counts writes since the writer started |

### Every connection

| Field | Meaning |
|---|---|
| `key` | `A`, `B` or `C` |
| `kind` | `pve`, `pbs` or `pdm` |
| `label` | the connection's name in the plugin's settings |
| `host` | the host name only: no scheme, port, path or user info |
| `configured` | false when the connection has no host, token or secret; nothing else follows |
| `ok` | the last poll answered |
| `error` | the plugin's short error (`Auth failed`, `No permission`, `DNS failed`, `Refused`, `Timeout`, `TLS cert`, ...), else null |
| `updatedAt` | when it last answered (ms); the data below is from then, kept while it fails |

### Proxmox VE (`kind: "pve"`)

- `cluster`: `{ name, quorate, nodes }`, or null (a single node, or no right to read it)
- `nodes[]`: `{ name, remote, status, cpu, cpus, mem, maxmem, disk, maxdisk, uptime, load: [1, 5, 15 min], version }`
  (`disk` is the node's root file system; `load` and `version` from `/nodes/{node}/status`, null until read)
- `guests[]` (templates left out, by vmid): `{ vmid, name, type: "qemu" | "lxc", node, remote, status, cpu, cpus, mem,
  maxmem, disk, maxdisk, uptime, tags: [], ha, lock }` (`ha` is the HA state, `lock` a lock such as `backup`)
- `templates`: how many templates were left out
- `storages[]`: `{ storage, node, remote, shared, nodes, type, content, status, used, total }`; a shared storage once,
  with `node: null` and `nodes` the number of nodes that see it
- `tasks[]`: the newest cluster tasks: `{ node, type, id, status, start, end }` (`end: null` while running); no user

### Proxmox Datacenter Manager (`kind: "pdm"`)

- `remotes[]`: `{ name, type: "pve" | "pbs", error, nodes, nodesUp, guests, running }`
- `nodes[]`, `guests[]`, `storages[]`: as for Proxmox VE, each with its `remote`
- `datastores[]`: Backup Server remotes' datastores, `{ store, remote, used, total }`
- `totals`: `{ remotes, failed, nodesUp, nodesDown, running, stopped, cpu, cpus, mem, maxmem }` from `/resources/status`

### Proxmox Backup Server (`kind: "pbs"`)

- `server`: `{ cpu, mem, maxmem, uptime, load, rootUsed, rootTotal, version }`, or `{ error }` when the token cannot
  read the node
- `datastores[]` (A to Z): `{ store, used, total, avail, fullAt, gc: { state, at, running }, verify: { state, at },
  running: [task types], groups, snapshots, lastBackup }` (`fullAt`: Proxmox's estimate of when it fills; `verify`:
  the newest verification among the recent tasks; `groups` and `snapshots` null when the token cannot list groups)
- `groups[]` (newest first): `{ store, type: "vm" | "ct" | "host", id, last, count, name }` (`name`: the guest's name
  from a Proxmox VE or Datacenter Manager connection with that id); no owner and no comment
- `running`: how many tasks are running
- `tasks[]`: the newest finished tasks, `{ node, type, id, status, start, end }`

## What never goes in

Tokens, token IDs, secrets, URLs, ports, IP addresses of nodes, task users, backup owners and backup comments. The
tests search the file for every token and secret they use.
