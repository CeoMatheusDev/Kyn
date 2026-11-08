"use strict";

const path = require("node:path");

function validateSnapshot(snapshot) {
  return !!snapshot && snapshot.schema === 1 &&
    Array.isArray(snapshot.files) &&
    Array.isArray(snapshot.symbols) &&
    Array.isArray(snapshot.references) &&
    snapshot.files.every(file => Number.isInteger(file.id) && typeof file.path === "string") &&
    snapshot.symbols.every(symbol =>
      typeof symbol.id === "string" && typeof symbol.name === "string" &&
      typeof symbol.kind === "string" && Number.isInteger(symbol.file) &&
      Number.isInteger(symbol.start) && Number.isInteger(symbol.end) &&
      symbol.start >= 0 && symbol.end >= symbol.start) &&
    snapshot.references.every(reference =>
      typeof reference.target === "string" && Number.isInteger(reference.file) &&
      Number.isInteger(reference.start) && Number.isInteger(reference.end) &&
      reference.start >= 0 && reference.end >= reference.start);
}

function filePathOf(snapshot, fileId) {
  const file = snapshot.files.find(entry => entry.id === fileId);
  return file ? file.path : null;
}

function targetAt(snapshot, sourcePath, offset, canonicalize = path.resolve) {
  const source = canonicalize(sourcePath);
  const declaration = snapshot.symbols.find(symbol => {
    const file = filePathOf(snapshot, symbol.file);
    return file && canonicalize(file) === source &&
      symbol.start <= offset && offset < symbol.end;
  });
  if (declaration) return declaration.id;
  const reference = snapshot.references.find(item => {
    const file = filePathOf(snapshot, item.file);
    return file && canonicalize(file) === source &&
      item.start <= offset && offset < item.end;
  });
  return reference ? reference.target : null;
}


function remapSnapshotOffsets(snapshot, sourceTextByFile) {
  for (const file of snapshot.files) {
    const source = sourceTextByFile.get(file.id);
    if (typeof source !== "string") continue;
    const entries = [
      ...snapshot.symbols.filter(item => item.file === file.id),
      ...snapshot.references.filter(item => item.file === file.id)
    ];
    const offsets = [...new Set(entries.flatMap(item => [item.start, item.end]))].sort((a, b) => a - b);
    const bytes = Buffer.from(source, "utf8"), converted = new Map();
    let byteOffset = 0, utf16Offset = 0;
    for (const target of offsets) {
      if (target > bytes.length) continue;
      while (byteOffset < target) {
        const lead = bytes[byteOffset];
        let width = lead < 0x80 ? 1 : lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4;
        if (byteOffset + width > target || byteOffset + width > bytes.length) width = 1;
        byteOffset += width;
        utf16Offset += width === 4 ? 2 : 1;
      }
      converted.set(target, utf16Offset);
    }
    for (const entry of entries) {
      const start = converted.get(entry.start), end = converted.get(entry.end);
      if (start !== undefined && end !== undefined) {
        entry.start = start;
        entry.end = end;
      }
    }
  }
  return snapshot;
}

function findSymbol(snapshot, id) {
  return snapshot.symbols.find(symbol => symbol.id === id) || null;
}

function referencesFor(snapshot, id, includeDeclaration) {
  const result = [];
  if (includeDeclaration) {
    const declaration = findSymbol(snapshot, id);
    if (declaration) result.push(declaration);
  }
  for (const reference of snapshot.references) {
    if (reference.target === id) result.push(reference);
  }
  return result;
}

module.exports = { validateSnapshot, filePathOf, targetAt, findSymbol, referencesFor, remapSnapshotOffsets };
