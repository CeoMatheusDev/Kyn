"use strict";

const IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/;

function tokenize(source) {
  const tokens = [];
  let i = 0;
  while (i < source.length) {
    const ch = source[i], next = source[i + 1];
    if (/\s/.test(ch)) { i++; continue; }
    if (ch === "/" && next === "/") {
      i += 2;
      while (i < source.length && source[i] !== "\n") i++;
      continue;
    }
    if (ch === "/" && next === "*") {
      i += 2;
      let depth = 1;
      while (i < source.length && depth) {
        if (source[i] === "/" && source[i + 1] === "*") { depth++; i += 2; }
        else if (source[i] === "*" && source[i + 1] === "/") { depth--; i += 2; }
        else i++;
      }
      continue;
    }
    if (ch === '"') {
      i++;
      while (i < source.length) {
        if (source[i] === "\\") i += 2;
        else if (source[i++] === '"') break;
      }
      continue;
    }
    const start = i;
    if (/[A-Za-z_]/.test(ch)) {
      i++;
      while (i < source.length && /[A-Za-z0-9_]/.test(source[i])) i++;
      tokens.push({ text: source.slice(start, i), start, end: i, identifier: true });
    } else {
      tokens.push({ text: ch, start, end: ++i, identifier: false });
    }
  }
  return tokens;
}

function indexSource(source, uri) {
  const tokens = tokenize(source);
  const declarations = [];
  const identifiers = tokens.filter(token => token.identifier);
  let depth = 0, implOwner = null, implDepth = -1, pendingImpl = null;
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (token.text === "}") {
      if (depth === implDepth) { implOwner = null; implDepth = -1; }
      depth = Math.max(0, depth - 1);
      continue;
    }
    if (token.identifier && token.text === "impl" && depth === 0) {
      const owner = tokens[i + 1];
      if (owner && owner.identifier) pendingImpl = owner.text;
      continue;
    }
    if (token.text === "{") {
      depth++;
      if (pendingImpl && implDepth < 0) { implOwner = pendingImpl; implDepth = depth; }
      pendingImpl = null;
      continue;
    }
    const topLevel = depth === 0;
    const inImpl = implDepth >= 0 && depth === implDepth;
    if (!token.identifier || (!topLevel && !inImpl) ||
        !["fn", "struct", "enum"].includes(token.text)) continue;
    const name = tokens[i + 1];
    if (!name || !name.identifier || !IDENTIFIER.test(name.text)) continue;
    const kind = token.text === "fn" ? "function" :
      token.text === "struct" ? "struct" : "enum";
    declarations.push({
      name: name.text,
      qualifiedName: inImpl ? implOwner + "." + name.text : name.text,
      kind: inImpl ? "method" : kind,
      uri,
      start: name.start,
      end: name.end
    });
  }
  return { uri, declarations, identifiers };
}

function tokenAt(index, offset) {
  let low = 0, high = index.identifiers.length - 1;
  while (low <= high) {
    const mid = (low + high) >>> 1, token = index.identifiers[mid];
    if (offset < token.start) high = mid - 1;
    else if (offset >= token.end) low = mid + 1;
    else return token;
  }
  return null;
}

module.exports = { tokenize, indexSource, tokenAt };
