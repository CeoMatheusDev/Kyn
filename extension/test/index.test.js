"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  validateSnapshot, filePathOf, targetAt, findSymbol, referencesFor,
  remapSnapshotOffsets, isIdentifier, renameEntries
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

test("converts UTF-8 byte spans to VS Code UTF-16 offsets", () => {
  const source = 'fn main() { print("😀"); twice(); }';
  const byteStart = Buffer.from(source, "utf8").indexOf(Buffer.from("twice"));
  const utf16Start = source.indexOf("twice");
  const sample = {
    schema: 1,
    files: [{ id: 0, path: "/workspace/unicode.kyn" }],
    symbols: [{ id: "function:0", name: "twice", kind: "function", file: 0, start: byteStart, end: byteStart + 5 }],
    references: [{ target: "function:0", file: 0, start: byteStart, end: byteStart + 5 }]
  };
  remapSnapshotOffsets(sample, new Map([[0, source]]));
  assert.equal(sample.symbols[0].start, utf16Start);
  assert.equal(sample.symbols[0].end, utf16Start + 5);
  assert.equal(sample.references[0].start, utf16Start);
});

test("rename accepts Kyn identifiers and rejects keywords or malformed names", () => {
  for (const name of ["renamed", "_private", "value2"]) assert.equal(isIdentifier(name), true);
  for (const name of ["", "2value", "with-dash", "has space", "fn", "return", "true"]) {
    assert.equal(isIdentifier(name), false, name);
  }
});

test("rename entries use semantic identity, including declaration only for target", () => {
  const sameSpelling = {
    ...snapshot,
    symbols: [
      ...snapshot.symbols,
      { id: "function:other", name: "twice", kind: "function", file: 0, start: 0, end: 5 }
    ],
    references: [
      ...snapshot.references,
      { target: "function:other", file: 0, start: 10, end: 15, role: "call" }
    ]
  };
  const entries = renameEntries(sameSpelling, "function:0", "renamed");
  assert.deepEqual(entries.map(entry => [entry.file, entry.start, entry.end]), [
    [1, 3, 8], [0, 40, 45]
  ]);
  assert.equal(renameEntries(sameSpelling, "function:0", "fn"), null);
  assert.equal(renameEntries(sameSpelling, "missing", "renamed"), null);
});
