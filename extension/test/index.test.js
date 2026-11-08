"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  validateSnapshot, filePathOf, targetAt, findSymbol, referencesFor
} = require("../src/index");

const snapshot = {
  schema: 1,
  files: [{ id: 0, path: "/workspace/main.kyn" }, { id: 1, path: "/workspace/lib.kyn" }],
  symbols: [
    { id: "function:0", name: "twice", kind: "function", file: 1, start: 3, end: 8 },
    { id: "variable:0", name: "value", kind: "parameter", file: 1, start: 12, end: 17 }
  ],
  references: [
    { target: "function:0", file: 0, start: 40, end: 45, role: "call" },
    { target: "variable:0", file: 1, start: 29, end: 34, role: "read" },
    { target: "variable:0", file: 1, start: 39, end: 44, role: "read" }
  ]
};

test("validates the compiler semantic snapshot schema", () => {
  assert.equal(validateSnapshot(snapshot), true);
  assert.equal(validateSnapshot({ schema: 2, files: [], symbols: [], references: [] }), false);
  assert.equal(validateSnapshot({ schema: 1, files: [], symbols: [], references: [{}] }), false);
});

test("maps file ids and resolves declaration and reference spans", () => {
  assert.equal(filePathOf(snapshot, 1), "/workspace/lib.kyn");
  assert.equal(filePathOf(snapshot, 9), null);
  assert.equal(targetAt(snapshot, "/workspace/lib.kyn", 4), "function:0");
  assert.equal(targetAt(snapshot, "/workspace/main.kyn", 42), "function:0");
  assert.equal(targetAt(snapshot, "/workspace/main.kyn", 10), null);
});

test("returns compiler-identity references and optional declaration", () => {
  assert.equal(findSymbol(snapshot, "function:0").name, "twice");
  assert.equal(findSymbol(snapshot, "missing"), null);
  assert.deepEqual(referencesFor(snapshot, "variable:0", false).map(x => x.role), ["read", "read"]);
  assert.deepEqual(referencesFor(snapshot, "variable:0", true).map(x => x.id || x.target),
    ["variable:0", "variable:0", "variable:0"]);
});
