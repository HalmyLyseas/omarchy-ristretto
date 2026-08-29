#!/usr/bin/env node
// test/host-contract.mjs -- pins the host wording/API members this plugin
// depends on but nothing else here checks. Read-only: never writes, never
// spawns a mutating command. Skips cleanly when the shell tree is absent.

import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PLUGIN_DIR = join(__dirname, "..");
const SHELL_TREE = process.env.RISTRETTO_SHELL_TREE || "/usr/share/omarchy/shell";

function skip(reason) {
  console.log(`SKIP: ${reason}`);
  process.exit(0);
}

if (!existsSync(SHELL_TREE)) {
  skip(`shell tree not found at ${SHELL_TREE} (set RISTRETTO_SHELL_TREE to override)`);
}

const failures = [];
let checks = 0;

function fileLines(path) {
  return readFileSync(path, "utf8").split("\n");
}

function assertContains(path, needle, why) {
  checks++;
  const lines = fileLines(path);
  const idx = lines.findIndex(l => l.includes(needle));
  if (idx === -1) {
    failures.push(`${path}: expected to find ${JSON.stringify(needle)} (${why}) -- host wording/API changed`);
  } else {
    console.log(`ok - ${path}:${idx + 1} contains ${JSON.stringify(needle)}`);
  }
}

const idleService = join(SHELL_TREE, "plugins/services/idle/Service.qml");
const lockService = join(SHELL_TREE, "plugins/lock/Service.qml");
const shellQml = join(SHELL_TREE, "shell.qml");

for (const [path, label] of [[idleService, "idle Service.qml"], [lockService, "lock Service.qml"], [shellQml, "shell.qml"]]) {
  if (!existsSync(path)) {
    failures.push(`${path}: missing (${label} not found under ${SHELL_TREE}) -- Omarchy's plugin layout changed`);
  }
}

if (existsSync(idleService)) {
  // Service.qml's origin latch (see docs/developers.md) reads these exact
  // log-event prefixes and property names off omarchy.idle.
  assertContains(idleService, 'logEvent("lock-system"', "origin latch: announcement event");
  assertContains(idleService, 'logEvent("process-start"', "origin latch: spawn-confirmed event");
  assertContains(idleService, 'logEvent("process-exit"', "origin latch: spawn-exited event");
  assertContains(idleService, "lock exitCode=", "origin latch: process-exit detail suffix");
  assertContains(idleService, "property string lastEvent", "Service.qml reads idleService.lastEvent");
  assertContains(idleService, "property bool stayAwake", "Service.qml reads idleService.stayAwake");
  assertContains(idleService, "screensaverTimeoutSeconds", "Panel.qml reads this derived timeout");
  assertContains(idleService, "lockTimeoutSeconds", "Panel.qml reads this derived timeout");
  assertContains(idleService, "function setIdleEnabled(", "Panel.qml calls this to flip stay-awake");
}

if (existsSync(lockService)) {
  assertContains(lockService, "readonly property bool locked:", "Service.qml reads lockService.locked");
  assertContains(lockService, "property bool pendingSessionLock", "secureLocked's not-yet-real-screen guard");
}

if (existsSync(shellQml)) {
  assertContains(shellQml, "function serviceFor(", "Panel.qml/BarWidget.qml resolve their own service");
  assertContains(shellQml, "function firstPartyServiceFor(", "Service.qml/Panel.qml resolve omarchy.idle/lock");
  assertContains(shellQml, "function mutateShellConfig(", "Panel.qml writes idle delays through this");
  assertContains(shellQml, "function updateEntryInline(", "Panel.qml writes its own settings through this");
}

// Ui/ components this plugin's QML declares as root elements, frozen at
// authoring time by scanning BarWidget.qml/Panel.qml -- a future Omarchy
// that renames or removes one of these breaks this plugin's UI.
const REQUIRED_UI_COMPONENTS = [
  "BarIconButton", "BarWidget", "CursorSurface", "KeyboardPanel", "Panel",
  "PanelHero", "PanelKeyCatcher", "PanelSectionHeader", "PanelSeparator",
  "PanelSlider", "PanelToolTip", "ToggleSwitch"
];
const uiDir = join(SHELL_TREE, "Ui");
if (!existsSync(uiDir)) {
  failures.push(`${uiDir}: missing -- Omarchy's shared Ui kit moved or was removed`);
} else {
  for (const name of REQUIRED_UI_COMPONENTS) {
    checks++;
    const path = join(uiDir, `${name}.qml`);
    if (existsSync(path)) console.log(`ok - ${path} exists`);
    else failures.push(`${path}: missing -- Ui/${name}.qml no longer ships with Omarchy`);
  }
}

// SUPPORTED_OMARCHY_MIN is a plain top-level Model.js constant (see
// Model.js), read here by regex rather than loading the whole strip-eval
// shim -- this test needs only the one string.
const modelSource = readFileSync(join(PLUGIN_DIR, "Model.js"), "utf8");
const minMatch = modelSource.match(/var SUPPORTED_OMARCHY_MIN\s*=\s*"([^"]+)"/);
if (!minMatch) {
  failures.push("Model.js: SUPPORTED_OMARCHY_MIN constant not found");
} else {
  const min = minMatch[1];
  const pacman = spawnSync("pacman", ["-Q", "omarchy"], { encoding: "utf8" });
  if (pacman.error || pacman.status !== 0) {
    console.log("SKIP: pacman -Q omarchy unavailable, cannot verify the installed version");
  } else {
    const versionMatch = pacman.stdout.match(/^omarchy\s+(\S+)/);
    const installed = versionMatch ? versionMatch[1].split("-")[0] : null;
    checks++;
    if (!installed) {
      failures.push(`pacman -Q omarchy: unparseable output ${JSON.stringify(pacman.stdout)}`);
    } else if (compareDotted(installed, min) < 0) {
      failures.push(`installed omarchy ${installed} is below SUPPORTED_OMARCHY_MIN (${min}) in Model.js`);
    } else {
      console.log(`ok - installed omarchy ${installed} >= SUPPORTED_OMARCHY_MIN ${min}`);
    }
  }
}

function compareDotted(a, b) {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const na = pa[i] || 0, nb = pb[i] || 0;
    if (na !== nb) return na - nb;
  }
  return 0;
}

console.log("");
if (failures.length > 0) {
  console.log(`test/host-contract.mjs: ${failures.length} FAILURE(S) of ${checks} checks`);
  failures.forEach(f => console.log(`  ${f}`));
  process.exit(1);
}
console.log(`test/host-contract.mjs: ${checks} checks ok`);
process.exit(0);
