"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { tokenize, indexSource, tokenAt } = require("../src/index");

test("ignores identifiers in line comments, block comments and strings", () => {
  const source = '// fn fake() {}\n/* struct Hidden {} */\nfn real() -> i32 { print("fake"); return 0; }';
  const index = indexSource(source, "file:///a.kyn");
  assert.deepEqual(index.declarations.map(x => x.name), ["real"]);
  assert.equal(index.identifiers.some(x => x.text === "fake"), false);
});

test("indexes top-level declarations and methods with qualified names", () => {
  const source = "struct Vec {}\nenum Color {}\nimpl Vec { fn length(self: Vec) -> i32 { return 0; } }";
  const index = indexSource(source, "file:///a.kyn");
  assert.deepEqual(index.declarations.map(x => [x.name, x.qualifiedName, x.kind]), [
    ["Vec", "Vec", "struct"], ["Color", "Color", "enum"], ["length", "Vec.length", "method"]
  ]);
});

test("tokenAt returns only identifier spans", () => {
  const index = indexSource("fn main() {}", "file:///a.kyn");
  assert.equal(tokenAt(index, 3).text, "main");
  assert.equal(tokenAt(index, 0), null);
  assert.equal(tokenAt(index, 7), null);
});

test("supports nested block comments", () => {
  const index = indexSource("/* outer /* fn hidden() {} */ end */ fn visible() {}", "file:///a.kyn");
  assert.deepEqual(index.declarations.map(x => x.name), ["visible"]);
});
