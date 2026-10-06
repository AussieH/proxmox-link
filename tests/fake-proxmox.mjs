// A fake Proxmox VE, Backup Server and Datacenter Manager API over HTTPS on 127.0.0.1, for the tests. Which product
// answers depends on the token in the Authorization header. All data is made up and fixed (times count from T), so two
// writers polling it produce the same file. Every request is logged as one JSON line (path and which token, never the
// secret itself).
//   node tests/fake-proxmox.mjs --pfx cert.pfx --pass test --log calls.jsonl
// Prints {"port": N} once it listens.
import { appendFileSync, readFileSync } from "node:fs";
import https from "node:https";

const arg = (name, dflt) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : dflt; };
const PFX = arg("--pfx"), PASS = arg("--pass", "test"), LOG = arg("--log", null), PORT = Number(arg("--port", "0"));

export const TOKENS = {
  pve: "sdt@pve!link", pveSecret: "sdt-secret-pve-5e1a",
  pbs: "sdt@pbs!link", pbsSecret: "sdt-secret-pbs-7c2b",
  pdm: "sdt@pdm!link", pdmSecret: "sdt-secret-pdm-9d3c",
};
const T = 1759600000;
const G = 2 ** 30;

// ---- Proxmox VE ----------------------------------------------------------------------------------------------------
const NAMES = ["web", "db", "cache", "mail", "git", "ci", "wiki-é", "vpn", "dns", "proxy", "media", "files", "monitor", "docs", "chat"];
const guests = NAMES.map((n, i) => ({
  type: i % 3 === 1 ? "lxc" : "qemu", vmid: 100 + i, name: `sdt-${n}`, node: "pve01", status: i === 2 ? "stopped" : "running",
  cpu: 0.05 + i * 0.0123456, mem: (1 + i) * 2 ** 29 + 0.4, maxmem: 2 ** 33, disk: i * 2 ** 28, maxdisk: 2 ** 35, maxcpu: 2,
  uptime: i === 2 ? 0 : 3600 * (i + 1), template: 0,
  ...(i === 0 ? { tags: "web;prod" } : i === 1 ? { tags: "db,prod backup" } : {}),
  ...(i === 3 ? { hastate: "started" } : {}), ...(i === 4 ? { lock: "backup" } : {}),
}));
guests.push({ type: "qemu", vmid: 199, name: "sdt-template", node: "pve01", status: "stopped", cpu: 0, mem: 0, maxmem: 2 ** 31, maxdisk: 2 ** 33, maxcpu: 1, uptime: 0, template: 1 });
guests.push({ type: "qemu", vmid: 200, name: "sdt-other", node: "pve02", status: "running", cpu: 0.1, mem: 2 ** 31, maxmem: 2 ** 32, maxdisk: 2 ** 34, maxcpu: 2, uptime: 7200, template: 0, tags: "" });
guests.push({ type: "lxc", vmid: 150, name: "sdt-early", node: "pve02", status: "running", cpu: 0, mem: 2 ** 27, maxmem: 2 ** 29, maxdisk: 2 ** 32, maxcpu: 1, uptime: 60, template: 0 });
const resources = () => [
  { type: "node", id: "node/pve02", node: "pve02", status: "online", cpu: 0.05, maxcpu: 8, mem: 4 * G, maxmem: 32 * G, disk: 9 * G, maxdisk: 60 * G, uptime: 86400, level: "" },
  { type: "node", id: "node/pve01", node: "pve01", status: "online", cpu: 0.23456789, maxcpu: 16, mem: 12 * G, maxmem: 64 * G, disk: 20 * G, maxdisk: 100 * G, uptime: 864000, level: "" },
  { type: "node", id: "node/pve-old", node: "pve-old", status: "offline" },
  ...guests.map((x) => ({ ...x, id: `${x.type}/${x.vmid}` })),
  { type: "storage", id: "storage/pve01/local", storage: "local", node: "pve01", plugintype: "dir", content: "iso,vztmpl,backup", shared: 0, status: "available", disk: 20 * G, maxdisk: 100 * G },
  { type: "storage", id: "storage/pve02/local", storage: "local", node: "pve02", plugintype: "dir", content: "iso,vztmpl", shared: 0, status: "available", disk: 9 * G, maxdisk: 60 * G },
  { type: "storage", id: "storage/pve01/sdt-ceph", storage: "sdt-ceph", node: "pve01", plugintype: "rbd", content: "images,rootdir", shared: 1, status: "available", disk: 1.5 * 2 ** 40, maxdisk: 6 * 2 ** 40 },
  { type: "storage", id: "storage/pve02/sdt-ceph", storage: "sdt-ceph", node: "pve02", plugintype: "rbd", content: "images,rootdir", shared: 1, status: "available", disk: 1.5 * 2 ** 40, maxdisk: 6 * 2 ** 40 },
  { type: "storage", id: "storage/pve01/sdt-backups", storage: "sdt-backups", node: "pve01", plugintype: "pbs", content: "backup", shared: 0, status: "available", disk: 2 ** 40, maxdisk: 4 * 2 ** 40 },
  { type: "sdn", id: "sdn/pve01/localnetwork", sdn: "localnetwork", node: "pve01", status: "ok" },
];
const clusterTasks = () => Array.from({ length: 20 }, (_, i) => ({
  upid: `UPID:pve0${1 + (i % 2)}:${i}`, node: `pve0${1 + (i % 2)}`, type: i % 4 === 0 ? "vzdump" : i % 4 === 1 ? "qmstart" : i % 4 === 2 ? "vncproxy" : "vzstart",
  id: String(100 + i), user: "sdt@pve", starttime: T - 60 * ((i * 7) % 20), ...(i === 3 ? {} : { endtime: T - 60 * ((i * 7) % 20) + 30, status: i === 5 ? "TASK ERROR: sdt failure" : "OK" }),
}));
function pveRoute(p) {
  if (p === "/cluster/resources") return [200, resources()];
  if (p === "/cluster/status") return [200, [{ type: "cluster", id: "cluster", name: "sdt-lab", quorate: 1, nodes: 3, version: 4 }, { type: "node", name: "pve01", online: 1, ip: "192.0.2.11" }, { type: "node", name: "pve02", online: 1, ip: "192.0.2.12" }]];
  if (p === "/cluster/tasks") return [200, clusterTasks()];
  const m = p.match(/^\/nodes\/([^/]+)\/status$/);
  if (m) return m[1] === "pve01" ? [200, { loadavg: ["0.42", "0.35", "0.30"], pveversion: "pve-manager/9.0.6/sdt", uptime: 1 }] : [200, { loadavg: ["1.5", "1.25", "1"], pveversion: "pve-manager/8.4.1/sdt", uptime: 1 }];
  return [404, null];
}

// ---- Proxmox Backup Server -----------------------------------------------------------------------------------------
const groups = {
  "sdt-local": [
    { "backup-type": "vm", "backup-id": "100", "last-backup": T - 3600, "backup-count": 7, owner: TOKENS.pbs, comment: "sdt private note" },
    { "backup-type": "ct", "backup-id": "101", "last-backup": T - 50 * 3600, "backup-count": 3, owner: TOKENS.pbs },
    { "backup-type": "host", "backup-id": "sdt-laptop", "last-backup": T - 9 * 86400, "backup-count": 2, owner: "sdt@pbs" },
    { "backup-type": "vm", "backup-id": "777", "last-backup": T - 3600, "backup-count": 1, owner: "sdt@pbs" },
  ],
  "sdt-offsite": [{ "backup-type": "vm", "backup-id": "200", "last-backup": T - 1800, "backup-count": 4, owner: TOKENS.pbs }],
  "sdt-empty": [],
};
function pbsRoute(p, q) {
  if (p === "/nodes/localhost/status") return [200, { cpu: 0.0712, memory: { used: 3 * G, total: 8 * G, free: 5 * G }, root: { used: 20 * G, total: 100 * G, avail: 80 * G }, uptime: 172800, loadavg: [0.1, 0.25, 0.333], info: { version: "4.0.14" }, kversion: "Linux sdt" }];
  if (p === "/status/datastore-usage") return [200, [
    { store: "sdt-offsite", total: 2 * 2 ** 40, used: 1.8 * 2 ** 40, avail: 0.2 * 2 ** 40, "estimated-full-date": T + 20 * 86400 },
    { store: "sdt-local", total: 4 * 2 ** 40, used: 1.5 * 2 ** 40, avail: 2.5 * 2 ** 40, "estimated-full-date": 0 },
    { store: "sdt-empty", total: 2 ** 40, used: 0, avail: 2 ** 40 },
  ]];
  if (p === "/admin/gc") return [200, [{ store: "sdt-local", "last-run-state": "ok", "last-run-endtime": T - 7200 }, { store: "sdt-offsite", upid: "UPID:sdt:gc" }]];
  if (p === "/nodes/localhost/tasks") {
    if (q.get("running")) return [200, [{ worker_type: "verificationjob", worker_id: "sdt-local:v-1", starttime: T - 30, user: "sdt@pbs" }, { worker_type: "garbage_collection", worker_id: "sdt-offsite", starttime: T - 60, user: "sdt@pbs" }]];
    return [200, [
      { node: "localhost", worker_type: "backup", worker_id: "sdt-local:vm/100", status: "OK", starttime: T - 700, endtime: T - 600, user: TOKENS.pbs },
      { node: "localhost", worker_type: "verificationjob", worker_id: "sdt-local:v-0", status: "OK", starttime: T - 5000, endtime: T - 4000, user: "sdt@pbs" },
      { node: "localhost", worker_type: "verify", worker_id: "sdt-offsite:vm/200", status: "TASK ERROR: sdt bad chunk", starttime: T - 9000, endtime: T - 8000, user: "sdt@pbs" },
      { node: "localhost", worker_type: "garbage_collection", worker_id: "sdt-local", status: "OK", starttime: T - 7300, endtime: T - 7200, user: "sdt@pbs" },
      { node: "localhost", worker_type: "verificationjob", worker_id: "sdt-local:v-2", starttime: T - 30, user: "sdt@pbs" },
    ]];
  }
  const m = p.match(/^\/admin\/datastore\/([^/]+)\/groups$/);
  if (m) return groups[decodeURIComponent(m[1])] ? [200, groups[decodeURIComponent(m[1])]] : [404, null];
  return [404, null];
}

// ---- Proxmox Datacenter Manager: two remotes that both have a node pve01 and a VM 100, a Backup Server remote, and
//      one remote it cannot reach ----------------------------------------------------------------------------------
const PDM = {
  "sdt-east": {
    nodes: [{ node: "pve01", cpu: 0.3, maxcpu: 8, mem: 10 * G, maxmem: 32 * G, uptime: 500000 }, { node: "pve02", cpu: 0.1, maxcpu: 8, mem: 6 * G, maxmem: 32 * G, uptime: 400000 }],
    guests: [{ type: "qemu", vmid: 100, name: "sdt-east-web", node: "pve01", status: "running", tags: ["edge", "prod"] }, { type: "lxc", vmid: 101, name: "sdt-east-dns", node: "pve01", status: "running" }, { type: "qemu", vmid: 102, name: "sdt-east-old", node: "pve02", status: "stopped" }],
  },
  "sdt-west": {
    nodes: [{ node: "pve01", cpu: 0.5, maxcpu: 4, mem: 12 * G, maxmem: 16 * G, uptime: 90000 }],
    guests: [{ type: "qemu", vmid: 100, name: "sdt-west-web", node: "pve01", status: "running" }, { type: "qemu", vmid: 103, name: "sdt-west-ci", node: "pve01", status: "stopped" }, { type: "qemu", vmid: 190, name: "sdt-west-tpl", node: "pve01", status: "stopped", template: true }],
  },
};
const pdmGuest = (x) => ({ cpu: x.status === "running" ? 0.1 : 0, maxcpu: 2, mem: x.status === "running" ? 2 * G : 0, maxmem: 4 * G, disk: 0, maxdisk: 32 * G, uptime: x.status === "running" ? 7200 : 0, tags: x.tags || [], pool: "", template: !!x.template, name: x.name, node: x.node, status: x.status, vmid: x.vmid });
const pdmList = () => [
  ...Object.entries(PDM).map(([remote, r]) => ({ remote, error: null, resources: [
    ...r.nodes.map((n) => ({ type: "pve-node", id: `remote/${remote}/node/${n.node}`, status: "online", "cgroup-mode": 2, level: "", ...n })),
    ...r.guests.map((x) => ({ type: `pve-${x.type}`, id: `remote/${remote}/guest/${x.vmid}`, ...pdmGuest(x) })),
    { type: "pve-storage", id: `remote/${remote}/storage/pve01/local`, storage: "local", node: "pve01", status: "available", disk: G, maxdisk: 100 * G },
    { type: "pve-network", id: `remote/${remote}/network/pve01/vmbr0`, name: "vmbr0", node: "pve01", status: "ok" },
  ] })),
  { remote: "sdt-backup", error: null, resources: [
    { type: "pbs-node", id: "remote/sdt-backup/node/localhost", name: "localhost", cpu: 0.02, mem: G, maxmem: 8 * G, uptime: 1000 },
    { type: "pbs-datastore", id: "remote/sdt-backup/datastore/sdt-store", name: "sdt-store", disk: 3 * 2 ** 40, maxdisk: 8 * 2 ** 40 },
  ] },
  { remote: "sdt-gone", error: "sdt-gone: connection refused (sdt)", resources: [] },
];
function pdmStatus() {
  const all = Object.values(PDM), guestsAll = all.flatMap((r) => r.guests), nodes = all.flatMap((r) => r.nodes);
  const count = (type) => ({ running: guestsAll.filter((x) => x.type === type && !x.template && x.status === "running").length, stopped: guestsAll.filter((x) => x.type === type && !x.template && x.status === "stopped").length, template: guestsAll.filter((x) => x.type === type && x.template).length, unknown: 0 });
  return {
    remotes: 4, failed_remotes: 1, "remote-list": [...Object.keys(PDM).map((name) => ({ name, status: "Good", ty: "pve" })), { name: "sdt-backup", status: "Good", ty: "pbs" }, { name: "sdt-gone", status: "Failed", ty: "pve" }],
    pve_nodes: { online: nodes.length, offline: 0, unknown: 0 }, qemu: count("qemu"), lxc: count("lxc"),
    pve_cpu_stats: { used: nodes.reduce((s, x) => s + x.cpu * x.maxcpu, 0), max: nodes.reduce((s, x) => s + x.maxcpu, 0), allocated: 0 },
    pve_memory_stats: { used: nodes.reduce((s, x) => s + x.mem, 0), total: nodes.reduce((s, x) => s + x.maxmem, 0), avail: 0 },
  };
}
function pdmRoute(p) {
  if (p === "/resources/list") return [200, pdmList()];
  if (p === "/resources/status") return [200, pdmStatus()];
  return [404, null];
}

// ---- the server ----------------------------------------------------------------------------------------------------
const AUTH = {
  [`PVEAPIToken=${TOKENS.pve}=${TOKENS.pveSecret}`]: "pve",
  [`PBSAPIToken=${TOKENS.pbs}:${TOKENS.pbsSecret}`]: "pbs",
  [`PDMAPIToken=${TOKENS.pdm}:${TOKENS.pdmSecret}`]: "pdm",
};
const server = https.createServer({ pfx: readFileSync(PFX), passphrase: PASS }, (req, res) => {
  const u = new URL(req.url, "https://x");
  const who = AUTH[req.headers.authorization || ""] || null;
  // A wrong secret is logged by its last part only (the tests use made-up "wrong-..." secrets to tell writers apart).
  const tag = who || ("bad:" + String(req.headers.authorization || "").split(/[=:-]/).pop());
  if (LOG) appendFileSync(LOG, JSON.stringify({ t: Date.now(), method: req.method, path: u.pathname, who: tag }) + "\n");
  if (!who) { res.writeHead(401, "authentication failure"); return res.end("{}"); }
  if (req.method !== "GET") { res.writeHead(405, "only GET here"); return res.end("{}"); }
  const p = u.pathname.replace(/^\/api2\/json/, "");
  const [code, data] = who === "pdm" ? pdmRoute(p) : who === "pbs" ? pbsRoute(p, u.searchParams) : pveRoute(p);
  res.writeHead(code, { "content-type": "application/json;charset=UTF-8" });
  res.end(JSON.stringify({ data }));
});
server.listen(PORT, "127.0.0.1", () => { console.log(JSON.stringify({ port: server.address().port })); });
process.stdin.on("end", () => process.exit(0));
process.stdin.resume();
