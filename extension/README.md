# Kyn Language Support for Visual Studio Code

Lightweight VS Code support for Kyn, backed by the real `kync` compiler. Semantic navigation consumes the compiler's resolved symbol index; no third-party runtime dependency is required.

## Features

- `.kyn` registration, TextMate highlighting, comments, brackets and snippets.
- Compiler diagnostics from `kync check`, including imported source files.
- Automatic checks on open, edit and save with configurable debounce.
- Commands to check a file, emit LLVM IR and emit x86-64 Assembly.
- Static completions for language keywords, primitive types, builtins and snippets.
- Document outline for functions, structs, enums and implementation blocks.
- Compiler-resolved Go to Definition, Find All References and workspace symbol search.
- Unsaved current-file buffers are analyzed through a temporary sibling source file; relative imports continue to resolve from the original directory.
- Dedicated **Kyn** Output Channel with compiler activity and errors.
- Configurable compiler executable; auto-detects `zig-out/bin/kync`, then PATH.

## Requirements

- VS Code 1.85 or newer.
- A built Kyn compiler (`kync`).
- Zig 0.17.0 only to build the compiler from source.

From the repository root:

```sh
zig build
```

The default compiler path is `zig-out/bin/kync`.

## Configuration

| Setting | Default | Description |
| --- | --- | --- |
| `kyn.compilerPath` | `""` | Explicit path to `kync`; relative paths resolve from the workspace root. |
| `kyn.checkOnSave` | `true` | Check after saving. |
| `kyn.checkOnType` | `true` | Check after edits. |
| `kyn.checkDebounce` | `450` | Edit debounce in milliseconds (100–5000). |

Example:

```json
{
  "kyn.compilerPath": "/home/user/bin/kync",
  "kyn.checkOnSave": true,
  "kyn.checkOnType": true,
  "kyn.checkDebounce": 500
}
```

If the path is empty, the extension searches the workspace for
`zig-out/bin/kync`, then resolves `kync` from PATH.

## Commands

- **Kyn: Check Current File** — runs `kync check`.
- **Kyn: Check Open Kyn Files** — checks all open local `.kyn` documents.
- **Kyn: Emit LLVM IR** — writes and opens a sibling `.ll` file.
- **Kyn: Emit x86-64 Assembly** — writes and opens a sibling `.s` file.

Emit commands overwrite an existing output file with the same basename. The
LLVM backend does not yet support every pointer expression supported by the
native backend.

## Development

1. Open the `extension/` directory in VS Code.
2. Build the compiler with `zig build`.
3. Run `npm run check` and `npm test` to validate the extension and semantic snapshot resolver.
4. Press `F5` to launch an Extension Development Host.
5. Open a `.kyn` file in a workspace containing `zig-out/bin/kync`.
6. Introduce a syntax or semantic error and verify it appears in Problems.
7. Test Go to Definition (`F12`) and Find All References (`Shift+F12`) on a resolved function or variable.

There are no npm runtime dependencies. Package with `vsce package` after
installing the VS Code Extension Manager CLI.

## Current limitations

This is compiler integration, not an LSP implementation. Go to Definition and Find All References use the semantic snapshot emitted by `kync symbols --json --lib <file>`; they follow resolved function, method, variable, struct, enum-case and field identities within the root file's import graph. Workspace symbol search compiles open Kyn documents and merges their snapshots. Completion remains static and the document outline remains syntax-based. Rename, semantic completion, formatting, debugging, a persistent compiler process and incremental document synchronization are not implemented.

Each semantic request starts a compiler process. The current unsaved root buffer is passed through a temporary file in the same directory; dirty imported buffers are not overlaid and are analyzed from disk. A semantic error prevents publication of a new snapshot.

The extension follows the syntax accepted by the current bootstrap compiler.
Do not advertise unsupported language constructs as implemented.

## License

Apache-2.0. See [LICENSE](LICENSE).
