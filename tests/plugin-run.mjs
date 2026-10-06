// Runs the Stream Deck plugin Proxmox & PBS Control (its packaged .streamDeckPlugin, extracted as Stream Deck installs
// it) against a minimal fake Stream Deck, so the tests can compare the plugin's state.json with Proxmox Link's and check
// that the plugin steps aside for Proxmox Link's heartbeat. The plugin's APPDATA points at a test folder, never the real
// one. Nothing here talks to Stream Deck itself.
//   node tests/plugin-run.mjs --repo <streamdeck-proxmox> --work <folder> --appdata <folder> --settings <globals.json>
// Prints {"registered": true} once the plugin has connected; ends when stdin closes.
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";

const arg = (name) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : null; };
const REPO = arg("--repo"), WORK = arg("--work"), APPDATA = arg("--appdata"), SETTINGS = arg("--settings");
const PKG = join(REPO, "dist", "com.deaddesk.proxmox.streamDeckPlugin");
if (!existsSync(PKG)) { console.log(JSON.stringify({ error: `missing ${PKG}` })); process.exit(2); }
const { WebSocketServer } = createRequire(join(REPO, "package.json"))("ws");

const UUID = "com.deaddesk.proxmox";
const pluginDir = join(WORK, "com.deaddesk.proxmox.sdPlugin");
if (!existsSync(join(pluginDir, "manifest.json"))) {
  mkdirSync(WORK, { recursive: true });
  execFileSync(join(process.env.SystemRoot || "C:\\Windows", "System32", "tar.exe"), ["-xf", PKG, "-C", WORK]);
}
mkdirSync(APPDATA, { recursive: true });
const globals = JSON.parse(readFileSync(SETTINGS, "utf8"));
const version = JSON.parse(readFileSync(join(pluginDir, "manifest.json"), "utf8")).Version;

const wss = new WebSocketServer({ host: "127.0.0.1", port: 0 });
await new Promise((r) => wss.once("listening", r));
wss.on("connection", (ws) => {
  ws.on("message", (data) => {
    const m = JSON.parse(String(data));
    if (m.event === "registerPlugin") console.log(JSON.stringify({ registered: true, version }));
    if (m.event === "getGlobalSettings") ws.send(JSON.stringify({ event: "didReceiveGlobalSettings", payload: { settings: globals } }));
  });
});
const info = {
  application: { font: "Segoe UI", language: "en", platform: "windows", platformVersion: "10.0.26200", version: "7.5.1.22901" },
  plugin: { uuid: UUID, version }, devicePixelRatio: 1, colors: {},
  devices: [{ id: "DEV-SD", name: "Test Stream Deck", size: { columns: 5, rows: 3 }, type: 0 }],
};
const child = spawn(process.execPath, ["bin/plugin.js", "-port", String(wss.address().port), "-pluginUUID", UUID, "-registerEvent", "registerPlugin", "-info", JSON.stringify(info)], {
  cwd: pluginDir, stdio: ["ignore", "ignore", "pipe"], windowsHide: true, env: { ...process.env, APPDATA },
});
child.stderr.on("data", (d) => process.stderr.write(d));
child.on("exit", (code) => { console.log(JSON.stringify({ exited: code })); process.exit(0); });
const end = () => { try { child.kill(); } catch { /* gone */ } setTimeout(() => process.exit(0), 300); };
process.stdin.on("end", end);
process.stdin.on("close", end);
process.stdin.resume();
