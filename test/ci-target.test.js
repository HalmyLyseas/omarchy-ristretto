const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");
const workflow = readFileSync(join(root, ".github/workflows/test.yml"), "utf8");
const lint = readFileSync(join(root, "test/lint-qml"), "utf8");
const hostContract = readFileSync(join(root, "test/host-contract.mjs"), "utf8");

test("CI pins the exact supported Omarchy 4.0.5 and 4.5.0 shell trees", () => {
    const matrix = workflow.match(/omarchy:\s*\[([^\]]+)\]/);
    assert.ok(matrix, "workflow declares an Omarchy matrix");
    assert.deepEqual(matrix[1].split(",").map(value => value.trim()).sort(), ["v4.0.5", "v4.5.0"]);
    assert.match(workflow, /--branch "\$\{\{ matrix\.omarchy \}\}"/);
    assert.match(workflow, /describe --tags --exact-match\)" = "\$\{\{ matrix\.omarchy \}\}"/);
    assert.match(workflow, /RISTRETTO_SHELL_TREE: \/tmp\/omarchy\/shell/);
    assert.match(workflow, /RISTRETTO_PLUGIN_VALIDATOR: \/tmp\/omarchy\/bin\/omarchy-plugin-validate/);
    assert.doesNotMatch(workflow, /pacman -Swdd/);
});

test("local lint prefers Qt 6 and accepts a selected shell tree", () => {
    assert.match(lint, /RISTRETTO_SHELL_TREE:-\/usr\/share\/omarchy\/shell/);
    assert.match(lint, /RISTRETTO_QMLLINT_BIN:-\/usr\/lib\/qt6\/bin\/qmllint/);
    assert.match(lint, /ln -s "\$SHELL_TREE"/);
});

test("host contract accepts the supported Quickshell series", () => {
    assert.match(hostContract, /0\\\.3\\\.\[12\]/);
    assert.match(hostContract, /expected Quickshell 0\.3\.1 or 0\.3\.2/);
});
