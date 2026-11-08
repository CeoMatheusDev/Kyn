# Kyn Language Support for Visual Studio Code

Lightweight VS Code support for Kyn, backed by the real `kync` compiler. No
language server or third-party runtime dependency is required.

## Features

- `.kyn` registration, TextMate highlighting, comments, brackets and snippets.
- Compiler diagnostics from `kync check`, including imported source files.
- Automatic checks on open, edit and save with configurable debounce.
- Commands to check a file, emit LLVM IR and emit x86-64 Assembly.
- Static completions for language keywords, primitive types, builtins and snippets.
- Document outline for functions, structs, enums and implementation blocks.\n- Workspace-wide Go to Definition, Find All References and symbol search for uniquely named declarations.
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
2. Run `npm run check` and `npm test` to validate the extension and symbol index.
3. Press `F5` to launch an Extension Development Host.
4. Open a `.kyn` file in a workspace containing `zig-out/bin/kync`.
5. Introduce a syntax or semantic error and verify it appears in Problems.
6. Run the emit commands from the Command Palette.

There are no npm runtime dependencies. Package with `vsce package` after
installing the VS Code Extension Manager CLI.

## Current limitations

This is compiler integration, not a language server. Completion is static and
document symbols are syntax-based. Go-to-definition, rename, references,
formatting, debugging and incremental compiler protocol are not implemented.
Each check starts the compiler process; edits are debounced and superseded
checks for the same document are terminated.

The extension follows the syntax accepted by the current bootstrap compiler.
Do not advertise unsupported language constructs as implemented.

## License

Apache-2.0. See [LICENSE](LICENSE).
