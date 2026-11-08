"use strict";
const vscode = require("vscode");
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { indexSource, tokenAt } = require("./index");
const MAX_OUTPUT = 4 * 1024 * 1024;
const SELECTOR = { language: "kyn", scheme: "file" };

function canonical(file) {
  const absolute = path.resolve(file);
  try { return fs.realpathSync.native(absolute); }
  catch { return path.normalize(absolute); }
}
function folderOf(doc) { return vscode.workspace.getWorkspaceFolder(doc.uri); }
function cwdOf(doc) { const f = folderOf(doc); return f ? f.uri.fsPath : path.dirname(doc.uri.fsPath); }
function compilerOf(doc) {
  const f = folderOf(doc);
  const configured = vscode.workspace.getConfiguration("kyn", doc.uri).get("compilerPath", "").trim();
  if (configured) return path.isAbsolute(configured) ? configured : path.resolve(f ? f.uri.fsPath : path.dirname(doc.uri.fsPath), configured);
  if (f) {
    const name = process.platform === "win32" ? "kync.exe" : "kync";
    const local = path.join(f.uri.fsPath, "zig-out", "bin", name);
    if (fs.existsSync(local)) return local;
  }
  return "kync";
}
function parseDiagnostics(output, cwd, aliases = new Map()) {
  const result = new Map();
  const pattern = /^(.+?):(\d+):(\d+): (error|warning): (.*)$/;
  for (const line of output.split(/\r?\n/)) {
    const m = line.match(pattern);
    if (!m) continue;
    const rawFile = canonical(path.isAbsolute(m[1]) ? m[1] : path.resolve(cwd, m[1]));
    const file = aliases.get(rawFile) || rawFile;
    const row = Math.max(0, Number(m[2]) - 1), col = Math.max(0, Number(m[3]) - 1);
    const item = new vscode.Diagnostic(new vscode.Range(row, col, row, col + 1), m[5],
      m[4] === "warning" ? vscode.DiagnosticSeverity.Warning : vscode.DiagnosticSeverity.Error);
    item.source = "kync";
    if (!result.has(file)) result.set(file, []);
    result.get(file).push(item);
  }
  return result;
}

class KynClient {
  constructor(context) {
    this.diagnostics = vscode.languages.createDiagnosticCollection("kync");
    this.output = vscode.window.createOutputChannel("Kyn");
    this.pending = new Map();
    this.children = new Map();
    this.generations = new Map();
    this.published = new Map();
    this.dead = false;
    context.subscriptions.push(this.diagnostics, this.output);
  }
  schedule(doc, immediate = false) {
    if (this.dead || doc.isClosed || doc.languageId !== "kyn" || doc.uri.scheme !== "file") return;
    const key = doc.uri.toString(), old = this.pending.get(key);
    if (old) clearTimeout(old);
    const cfg = vscode.workspace.getConfiguration("kyn", doc.uri);
    const delay = immediate ? 0 : Math.max(100, cfg.get("checkDebounce", 450));
    this.pending.set(key, setTimeout(() => { this.pending.delete(key); this.check(doc); }, delay));
  }
  clearRoot(uri) {
    const key = uri.toString(), old = this.published.get(key);
    if (old) for (const target of old) this.diagnostics.delete(target);
    this.published.delete(key);
  }
  publish(root, grouped) {
    this.clearRoot(root);
    const targets = new Set();
    for (const [file, items] of grouped) {
      const uri = vscode.Uri.file(file);
      this.diagnostics.set(uri, items);
      targets.add(uri);
    }
    this.published.set(root.toString(), targets);
  }
  async check(doc) {
    if (this.dead || doc.isClosed) return;
    const key = doc.uri.toString(), generation = (this.generations.get(key) || 0) + 1;
    this.generations.set(key, generation);
    const old = this.children.get(key);
    if (old) old.kill();
    const executable = compilerOf(doc), cwd = cwdOf(doc);
    let sourcePath = doc.uri.fsPath, temporaryPath = null;
    if (doc.isDirty) {
      temporaryPath = path.join(path.dirname(sourcePath),
        "." + path.basename(sourcePath) + "." + process.pid + "." + generation + ".kyn-check.tmp.kyn");
      try {
        await fs.promises.writeFile(temporaryPath, doc.getText(), "utf8");
      } catch (error) {
        if (temporaryPath) void fs.promises.unlink(temporaryPath).catch(() => {});
        this.fail(error, "temporary source file");
        return;
      }
      if (this.generations.get(key) !== generation || this.dead || doc.isClosed) {
        void fs.promises.unlink(temporaryPath).catch(() => {});
        return;
      }
      sourcePath = temporaryPath;
    }
    const args = ["check", sourcePath];
    const aliases = new Map([[canonical(sourcePath), canonical(doc.uri.fsPath)]]);
    const cleanup = () => {
      if (temporaryPath) void fs.promises.unlink(temporaryPath).catch(() => {});
    };
    this.output.appendLine("[check] " + doc.uri.fsPath);
    let child;
    try { child = cp.spawn(executable, args, { cwd, windowsHide: true, shell: false }); }
    catch (error) { cleanup(); this.fail(error, executable); return; }
    this.children.set(key, child);
    let stderr = "", stdout = "", bytes = 0, overflow = false;
    const collect = (target, chunk) => {
      bytes += chunk.length;
      if (bytes > MAX_OUTPUT) { overflow = true; child.kill(); return; }
      if (target === "stderr") stderr += chunk.toString("utf8");
      else stdout += chunk.toString("utf8");
    };
    child.stdout.on("data", chunk => collect("stdout", chunk));
    child.stderr.on("data", chunk => collect("stderr", chunk));
    child.on("error", error => {
      cleanup();
      if (this.generations.get(key) !== generation) return;
      this.children.delete(key); this.clearRoot(doc.uri); this.fail(error, executable);
    });
    child.on("close", code => {
      cleanup();
      if (this.generations.get(key) !== generation || this.dead) return;
      this.children.delete(key);
      if (overflow) { this.clearRoot(doc.uri); this.output.appendLine("[error] Compiler output exceeded 4 MiB."); return; }
      this.publish(doc.uri, parseDiagnostics(stderr + "\n" + stdout, cwd, aliases));
      if (code === 0) this.output.appendLine("[ok] " + doc.uri.fsPath);
      else if (code !== 1 && !stderr) this.output.appendLine("[error] kync exited with code " + code);
    });
  }
  fail(error, executable) {
    this.output.appendLine("[error] " + error.message + " (" + executable + ")");
    if (error.code === "ENOENT") void vscode.window.showWarningMessage("Kyn compiler not found. Run 'zig build' or configure kyn.compilerPath.");
    else void vscode.window.showErrorMessage("Could not run kync: " + error.message);
  }
  run(executable, args, cwd) {
    return new Promise(resolve => {
      let child;
      try { child = cp.spawn(executable, args, { cwd, windowsHide: true, shell: false }); }
      catch (error) { resolve({ error }); return; }
      let stdout = "", stderr = "", bytes = 0, overflow = false;
      const collect = (target, chunk) => {
        bytes += chunk.length;
        if (bytes > MAX_OUTPUT) { overflow = true; child.kill(); return; }
        if (target === "stdout") stdout += chunk.toString("utf8");
        else stderr += chunk.toString("utf8");
      };
      child.stdout.on("data", c => collect("stdout", c));
      child.stderr.on("data", c => collect("stderr", c));
      child.on("error", error => resolve({ error }));
      child.on("close", code => resolve({ code: overflow ? -1 : code, stdout, stderr }));
    });
  }
  async emit(doc, backend) {
    if (!doc || doc.languageId !== "kyn" || doc.uri.scheme !== "file") {
      void vscode.window.showInformationMessage("Open a local .kyn file first."); return;
    }
    if (doc.isDirty && !(await doc.save())) return;
    const suffix = backend === "--llvm" ? ".ll" : ".s";
    const output = path.join(path.dirname(doc.uri.fsPath), path.basename(doc.uri.fsPath, path.extname(doc.uri.fsPath)) + suffix);
    const executable = compilerOf(doc), cwd = cwdOf(doc);
    const args = ["emit", backend, doc.uri.fsPath, "-o", output];
    this.output.appendLine("[emit] " + doc.uri.fsPath);
    const result = await this.run(executable, args, cwd);
    if (result.error) { this.fail(result.error, executable); return; }
    if (result.code !== 0) {
      this.publish(doc.uri, parseDiagnostics(result.stderr + "\n" + result.stdout, cwd));
      this.output.appendLine("[error] kync emit exited with code " + result.code);
      this.output.show(true); return;
    }
    this.clearRoot(doc.uri);
    const generated = await vscode.workspace.openTextDocument(vscode.Uri.file(output));
    await vscode.window.showTextDocument(generated, { preview: false });
    this.output.appendLine("[ok] Wrote " + output);
  }
  checkOpen() {
    const docs = vscode.workspace.textDocuments.filter(d => d.languageId === "kyn" && d.uri.scheme === "file");
    for (const doc of docs) this.schedule(doc, true);
    if (!docs.length) void vscode.window.showInformationMessage("No open Kyn files.");
  }
  dispose() {
    this.dead = true;
    for (const timer of this.pending.values()) clearTimeout(timer);
    for (const child of this.children.values()) child.kill();
    this.pending.clear(); this.children.clear(); this.diagnostics.clear();
  }
}

const WORDS = ["fn","struct","enum","impl","import","let","var","mut","self","if","else","while","switch","return","as","true","false","i8","i16","i32","i64","u8","u16","u32","u64","usize","bool","str","void","ptr","print","print_i32"];
const SNIPPETS = [
  ["fn", "fn \${1:name}(\${2}) -> \${3:i32} {\n    \${0}\n}", "Function declaration"],
  ["struct", "struct \${1:Name} {\n    \${2:field}: \${3:i32},\n}", "Struct declaration"],
  ["enum", "enum \${1:Name} {\n    \${2:Variant},\n}", "Enum declaration"],
  ["impl", "impl \${1:Type} {\n    fn \${2:name}(self: \${1:Type}) -> \${3:i32} {\n        \${0}\n    }\n}", "Implementation block"],
  ["if", "if \${1:condition} {\n    \${0}\n}", "Conditional"],
  ["ifelse", "if \${1:condition} {\n    \${2}\n} else {\n    \${0}\n}", "If / else"],
  ["while", "while \${1:condition} {\n    \${0}\n}", "While loop"],
  ["switch", "switch \${1:value} {\n    \${2:Variant} => {\n        \${0}\n    },\n    else => {\n    },\n}", "Enum switch"],
  ["import", "import \"\${1:module.kyn}\";", "Import declaration"],
  ["main", "fn main() -> i32 {\n    \${0:return 0;}\n}", "Program entry point"]
];
function completions(document, position) {
  const prefix = document.lineAt(position).text.slice(0, position.character).match(/[A-Za-z_][A-Za-z0-9_]*$/);
  const range = prefix ? new vscode.Range(position.line, position.character - prefix[0].length, position.line, position.character) : new vscode.Range(position, position);
  const items = WORDS.map(word => {
    const item = new vscode.CompletionItem(word, vscode.CompletionItemKind.Keyword);
    item.range = range; return item;
  });
  for (const [name, body, detail] of SNIPPETS) {
    const item = new vscode.CompletionItem(name, vscode.CompletionItemKind.Snippet);
    item.insertText = new vscode.SnippetString(body); item.detail = detail; item.range = range; items.push(item);
  }
  return items;
}
function matchingBrace(source, open) {
  let depth = 0, string = false, comment = false, escaped = false;
  for (let i = open; i < source.length; i++) {
    const ch = source[i], next = source[i + 1];
    if (comment) { if (ch === "\n") comment = false; continue; }
    if (string) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === "\"") string = false;
      continue;
    }
    if (ch === "/" && next === "/") { comment = true; i++; continue; }
    if (ch === "\"") { string = true; continue; }
    if (ch === "{") depth++;
    else if (ch === "}" && --depth === 0) return i;
  }
  return source.length;
}
function symbols(document) {
  const source = document.getText(), result = [];
  const pattern = /^\s*(fn|struct|enum|impl)\s+([A-Za-z_][A-Za-z0-9_]*)/gm;
  let match;
  while ((match = pattern.exec(source)) !== null) {
    const kind = match[1], name = match[2];
    const nameOffset = match.index + match[0].lastIndexOf(name);
    const open = source.indexOf("{", pattern.lastIndex);
    if (open < 0) continue;
    const close = matchingBrace(source, open);
    const symbolKind = kind === "fn" ? vscode.SymbolKind.Function :
      kind === "struct" ? vscode.SymbolKind.Struct :
      kind === "enum" ? vscode.SymbolKind.Enum : vscode.SymbolKind.Namespace;
    result.push(new vscode.DocumentSymbol(name, kind, symbolKind,
      new vscode.Range(document.positionAt(match.index), document.positionAt(Math.min(source.length, close + 1))),
      new vscode.Range(document.positionAt(nameOffset), document.positionAt(nameOffset + name.length))));
    pattern.lastIndex = Math.max(pattern.lastIndex, close + 1);
  }
  return result;
}


class WorkspaceSymbolIndex {
  constructor() { this.dirty = true; this.snapshot = null; this.refreshing = null; }
  invalidate() { this.dirty = true; }
  async get() {
    while (this.dirty || !this.snapshot) {
      if (!this.refreshing) {
        const pending = this.rebuild();
        this.refreshing = pending;
        try { await pending; }
        finally { if (this.refreshing === pending) this.refreshing = null; }
      } else {
        await this.refreshing;
      }
    }
    return this.snapshot;
  }
  async rebuild() {
    const files = await vscode.workspace.findFiles("**/*.kyn", "**/{.git,node_modules,zig-out}/**", 2000);
    const open = new Map(vscode.workspace.textDocuments
      .filter(doc => doc.languageId === "kyn" && doc.uri.scheme === "file")
      .map(doc => [doc.uri.toString(), doc]));
    const documents = new Map(), declarations = [];
    for (const uri of files) {
      const key = uri.toString(), doc = open.get(key);
      try {
        const source = doc ? doc.getText() : Buffer.from(await vscode.workspace.fs.readFile(uri)).toString("utf8");
        if (Buffer.byteLength(source, "utf8") > 1024 * 1024) continue;
        const indexed = indexSource(source, key);
        documents.set(key, indexed);
        declarations.push(...indexed.declarations);
      } catch { /* File may be unreadable or removed during indexing. */ }
    }
    for (const [key, doc] of open) {
      if (documents.has(key)) continue;
      const indexed = indexSource(doc.getText(), key);
      documents.set(key, indexed);
      declarations.push(...indexed.declarations);
    }
    const byName = new Map();
    for (const declaration of declarations) {
      if (!byName.has(declaration.name)) byName.set(declaration.name, []);
      byName.get(declaration.name).push(declaration);
    }
    this.snapshot = { documents, declarations, byName };
    this.dirty = false;
    return this.snapshot;
  }
  async resolve(document, position) {
    const snapshot = await this.get();
    const indexed = snapshot.documents.get(document.uri.toString());
    if (!indexed) return null;
    const token = tokenAt(indexed, document.offsetAt(position));
    if (!token) return null;
    const matches = snapshot.byName.get(token.text) || [];
    return matches.length === 1 ? { token, declaration: matches[0], snapshot } : null;
  }
  async definition(document, position) {
    const found = await this.resolve(document, position);
    if (!found) return null;
    const uri = vscode.Uri.parse(found.declaration.uri);
    const target = await vscode.workspace.openTextDocument(uri);
    return new vscode.Location(uri, new vscode.Range(
      target.positionAt(found.declaration.start), target.positionAt(found.declaration.end)
    ));
  }
  async references(document, position, includeDeclaration) {
    const found = await this.resolve(document, position);
    if (!found) return [];
    const locations = [];
    for (const indexed of found.snapshot.documents.values()) {
      const uri = vscode.Uri.parse(indexed.uri);
      const target = await vscode.workspace.openTextDocument(uri);
      for (const occurrence of indexed.identifiers) {
        if (occurrence.text !== found.token.text) continue;
        if (!includeDeclaration && indexed.uri === found.declaration.uri && occurrence.start === found.declaration.start) continue;
        locations.push(new vscode.Location(uri, new vscode.Range(
          target.positionAt(occurrence.start), target.positionAt(occurrence.end)
        )));
      }
    }
    return locations;
  }
  async workspaceSymbols(query) {
    const snapshot = await this.get(), needle = query.toLowerCase(), result = [];
    for (const declaration of snapshot.declarations) {
      if (needle && !declaration.name.toLowerCase().includes(needle) &&
          !declaration.qualifiedName.toLowerCase().includes(needle)) continue;
      const uri = vscode.Uri.parse(declaration.uri);
      const target = await vscode.workspace.openTextDocument(uri);
      const kind = declaration.kind === "function" || declaration.kind === "method" ? vscode.SymbolKind.Function :
        declaration.kind === "struct" ? vscode.SymbolKind.Struct : vscode.SymbolKind.Enum;
      result.push(new vscode.SymbolInformation(declaration.qualifiedName, kind, "",
        new vscode.Location(uri, new vscode.Range(
          target.positionAt(declaration.start), target.positionAt(declaration.end)
        ))));
    }
    return result;
  }
}

function activate(context) {
  const client = new KynClient(context);
  const symbolIndex = new WorkspaceSymbolIndex();
  context.subscriptions.push(
    vscode.languages.registerCompletionItemProvider(SELECTOR, { provideCompletionItems: completions }, ".", ":", " "),
    vscode.languages.registerDocumentSymbolProvider(SELECTOR, { provideDocumentSymbols: symbols }),
    vscode.languages.registerDefinitionProvider(SELECTOR, { provideDefinition: (doc, pos) => symbolIndex.definition(doc, pos) }),
    vscode.languages.registerReferenceProvider(SELECTOR, { provideReferences: (doc, pos, ctx) => symbolIndex.references(doc, pos, ctx.includeDeclaration) }),
    vscode.languages.registerWorkspaceSymbolProvider({ provideWorkspaceSymbols: query => symbolIndex.workspaceSymbols(query) }),
    vscode.workspace.onDidOpenTextDocument(doc => { symbolIndex.invalidate(); client.schedule(doc, true); }),
    vscode.workspace.onDidChangeTextDocument(event => {
      if (vscode.workspace.getConfiguration("kyn", event.document.uri).get("checkOnType", true)) client.schedule(event.document);
    }),
    vscode.workspace.onDidSaveTextDocument(doc => {
      if (vscode.workspace.getConfiguration("kyn", doc.uri).get("checkOnSave", true)) client.schedule(doc, true);
    }),
    vscode.workspace.onDidCloseTextDocument(doc => {
      const key = doc.uri.toString(), timer = client.pending.get(key), child = client.children.get(key);
      client.generations.set(key, (client.generations.get(key) || 0) + 1);
      if (timer) clearTimeout(timer);
      if (child) child.kill();
      client.pending.delete(key); client.children.delete(key); client.clearRoot(doc.uri);
    }),
    vscode.workspace.onDidChangeConfiguration(event => { if (event.affectsConfiguration("kyn")) { symbolIndex.invalidate(); client.checkOpen(); } }),
    vscode.workspace.onDidCreateFiles(() => symbolIndex.invalidate()),
    vscode.workspace.onDidDeleteFiles(() => symbolIndex.invalidate()),
    vscode.workspace.onDidRenameFiles(() => symbolIndex.invalidate()),
    vscode.commands.registerCommand("kyn.checkCurrentFile", () => {
      const editor = vscode.window.activeTextEditor;
      if (editor) client.schedule(editor.document, true);
      else void vscode.window.showInformationMessage("Open a .kyn file first.");
    }),
    vscode.commands.registerCommand("kyn.emitLLVM", () => client.emit(vscode.window.activeTextEditor && vscode.window.activeTextEditor.document, "--llvm")),
    vscode.commands.registerCommand("kyn.emitAssembly", () => client.emit(vscode.window.activeTextEditor && vscode.window.activeTextEditor.document, "--asm")),
    vscode.commands.registerCommand("kyn.checkWorkspace", () => client.checkOpen()),
    { dispose: () => client.dispose() }
  );
  for (const doc of vscode.workspace.textDocuments) if (doc.languageId === "kyn") client.schedule(doc, true);
}
function deactivate() {}
module.exports = { activate, deactivate };
