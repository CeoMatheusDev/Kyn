# Kyn

[![CI](https://github.com/CeoMatheusDev/Kyn/actions/workflows/ci.yml/badge.svg)](https://github.com/CeoMatheusDev/Kyn/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**Kyn** is an experimental systems programming language focused on explicit resource control, predictable compilation and low-level software.

The repository currently contains a Zig bootstrap compiler, an experimental Kyn standard library, early self-hosting prototypes, a VS Code language extension and a comprehensive fixture-based test suite. The compiler is not self-hosted and the language is not yet stable.

> **Project status:** experimental, pre-1.0. The supported language subset is defined by the implementation and its tests—not by roadmap items or design proposals.

## At a glance

| Component | Current state |
| --- | --- |
| Compiler implementation | Zig 0.17.0 bootstrap |
| Frontend | Lexer, parser, AST and semantic analysis |
| Backends | Textual LLVM IR and Linux x86-64 System V assembly |
| Language features | Fixed-width integers, booleans, strings, structs, enums, methods, pointers, imports and control flow |
| Standard library | Experimental; APIs and contracts are incomplete |
| Self-hosting | Not implemented; Kyn compiler files are prototypes/placeholders |
| Editor support | VS Code extension with compiler diagnostics, static completions, document outline and LLVM/Assembly emit commands |
| Stability | Experimental; syntax, semantics and ABI may change |

For exact feature coverage, limitations and validation evidence, see [Implementation status](docs/status.md).

## Design goals

- Explicit allocation and resource-lifetime control.
- No mandatory garbage collector.
- Predictable data representation and low-level operations.
- Minimal runtime assumptions.
- A small, auditable compiler and toolchain.
- A clear boundary between platform-independent core facilities and OS-specific facilities.

These are design goals, not claims that every corresponding feature is implemented.

## Build requirements

- Zig **0.17.0** (project-pinned).
- Git.
- Linux x86-64 with GNU `as` and `ld` for the native end-to-end suite.
- `llvm-as` or `clang` for local LLVM IR verification (CI installs a verifier).

## Build

```sh
git clone https://github.com/CeoMatheusDev/Kyn.git
cd Kyn

zig version
zig build
```

The compiler is produced at `zig-out/bin/kync`.

## Validate

```sh
zig fmt --check build.zig src std
zig build test
zig build e2e
zig build validate-ir
```

Use `zig build validate-ir-strict` to require an LLVM verifier. CI runs the strict validation step so a missing verifier cannot silently pass.

The last recorded executed baseline in [Implementation status](docs/status.md) is **246 compiler unit tests + 7 standard-library tests** and **130 end-to-end cases**. This maintenance branch adds four regression tests; they have not yet been executed, so the verified count must be refreshed after CI or a local test run.

## Quick start

Create `hello.kyn`:

```kyn
fn main() -> i32 {
    let answer: i32 = 6 * 7;
    print_i32(answer);
    return 0;
}
```

Check and emit native assembly:

```sh
zig-out/bin/kync check hello.kyn
zig-out/bin/kync emit --asm hello.kyn -o hello.s
as hello.s -o hello.o
ld hello.o -o hello
./hello
```

Emit LLVM IR with:

```sh
zig-out/bin/kync emit --llvm hello.kyn -o hello.ll
```

The CLI also supports `--lib` for library compilation. Run `zig-out/bin/kync --help` for the authoritative command-line interface.

## Repository layout

```text
.
├── .github/workflows/     # CI automation
├── docs/                  # Architecture, language docs and development guides
├── extension/             # VS Code language support
├── src/                   # Zig bootstrap compiler
│   ├── ast/
│   ├── codegen/
│   ├── compiler/           # Kyn-language compiler prototypes
│   ├── ffi/                # Isolated FFI experiment
│   ├── kyn/                # Self-hosting prototypes
│   ├── lexer/
│   ├── parser/
│   └── sema/
├── std/                   # Experimental Kyn/Zig standard-library modules
├── tests/                 # Unit, integration, positive/negative e2e fixtures
├── tools/                 # Validation scripts
├── build.zig              # Build graph and test steps
└── build.zig.zon          # Package metadata and Zig version
```

The existing directory boundaries are intentional. In particular, `src/compiler/` and `src/kyn/` are not part of the active Zig compilation pipeline. See [Architecture](docs/architecture.md) before moving compiler modules or changing ownership boundaries.

## Documentation

| Document | Purpose |
| --- | --- |
| [Tutorial](docs/tutorial.md) | Learn the implemented language subset |
| [Language guide (Portuguese)](docs/Kyn.md) | User-facing Kyn guide |
| [Language reference](docs/language_reference.md) | Preliminary, non-normative language design |
| [Syntax grammar](docs/syntax.ebnf) | Grammar accepted by the current parser |
| [Lexical grammar](docs/grammar.ebnf) | Tokens recognized by the lexer |
| [Architecture](docs/architecture.md) | Compiler pipeline, data flow and component contracts |
| [Implementation status](docs/status.md) | Verified features, limitations and test evidence |
| [Development guide](docs/development.md) | Build, CLI, testing and contribution workflow |
| [Memory model](docs/memory_model.md) | Proposed memory and ownership model |
| [Embedded analysis](docs/embedded.md) | Freestanding/embedded roadmap analysis |
| [Roadmap](ROADMAP.md) | Planned milestones; not a release commitment |
| [Changelog](CHANGELOG.md) | Version history and historical notes |
| [Contributing](CONTRIBUTING.md) | Engineering and review expectations |

## VS Code extension

The `extension/` directory contains declarative language support for `.kyn` files: TextMate syntax highlighting, bracket/indentation configuration and snippets. It does not yet provide a language server, semantic diagnostics, completion, navigation, formatting or debugging.

See [extension/README.md](extension/README.md) for local development and packaging.

## Engineering principles

- Preserve source slices and spans where possible; avoid unnecessary allocations and copies.
- Make allocation ownership and lifetime explicit.
- Keep parsing, semantic validation and code generation as separate stages.
- Add regression tests for every behavior change.
- Treat generated IR and assembly as compiler outputs that require validation.
- Do not claim support based solely on a prototype file or a design document.
- Record the exact commands executed; never report unexecuted validation as passing.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/development.md](docs/development.md) before making changes. Every feature change should include tests, updated documentation and a clear statement of what was—and was not—validated.

## License

The project is licensed exclusively under **Apache-2.0**. See [LICENSE](LICENSE) for the complete license text.
