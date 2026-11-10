const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const source = readFileSync(join(__dirname, "..", "HostOrigin.qml"), "utf8");

test("origin heartbeat and replay cap stay at the documented bounds", () => {
    assert.match(source, /property int heartbeatMs: 10000/);
    assert.match(source, /property int replayCap: 33554432/);
});
