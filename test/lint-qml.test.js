"use strict"

const { test } = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { spawnSync } = require("node:child_process")

function runLint(body) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "ristretto-lint-"))
  try {
    const binary = path.join(directory, "fake-lint")
    fs.writeFileSync(binary, "#!/bin/sh\n" + body, { mode: 0o700 })
    return spawnSync("bash", [path.join(__dirname, "lint-qml")], {
      cwd: directory,
      env: { ...process.env, RISTRETTO_QMLLINT_BIN: binary },
      encoding: "utf8"
    })
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
}

test("lint resolves source files outside the repository working directory", () => {
  const result = runLint('for argument do last="$argument"; done\ntest -f "$last" || exit 42\n')
  assert.equal(result.status, 0, result.stdout + result.stderr)
  assert.match(result.stdout, /qmllint checked [1-9][0-9]* files/)
})

test("lint fails on a nonzero exit without a formatted error", () => {
  const result = runLint("exit 42\n")
  assert.equal(result.status, 1, result.stdout + result.stderr)
  assert.match(result.stdout, /exit 42/)
})
