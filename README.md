# Kyn

[![CI](https://github.com/CeoMatheusDev/Kyn/actions/workflows/ci.yml/badge.svg)](https://github.com/CeoMatheusDev/Kyn/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**Kyn** is an experimental systems programming language focused on explicit resource control, predictable compilation and low-level software.

The repository currently contains a Zig bootstrap compiler, an experimental Kyn standard library, early self-hosting prototypes, a VS Code language extension and a comprehensive fixture-based test suite. The compiler is not self-hosted and the language is not yet stable.

> **Project status:** experimental, pre-1.0. The latest published prerelease is
> [v0.3.13-alpha.1](https://github.com/CeoMatheusDev/Kyn/releases/tag/v0.3.13-alpha.1)
> (source only; no binary assets). The supported subset is defined by the
> implementation and its tests—not by roadmap items or design proposals.

## At a glance

| Component | Current state |
| --- | --- |
| Compiler implementation | Zig 0.17.0 bootstrap; not self-hosted |
| Frontend and CLI | Lexer, parser, AST, semantic analysis; `kync check`, `emit` and `symbols --json` |
| Backends | Textual LLVM IR and Linux x86-64 assembly (Kyn-internal register ABI) |
| Language features | Tested subset of integers, booleans, static `str` slices, structs, enums, methods, pointers, file imports and control flow |
| Standard library | Experimental; APIs and contracts are incomplete |
| Self-hosting | Not implemented; Kyn compiler files are prototypes/placeholders |
| Editor support | VS Code extension with compiler diagnostics, compiler-resolved definition/reference navigation, workspace symbol search, static completions, outline and LLVM/Assembly emit commands |
| Stability | Experimental; syntax, semantics and ABI may change |

For detailed language rules and historical evidence, see [Implementation status](docs/status.md) and the [accepted syntax](docs/syntax.ebnf).

## Implemented today

This is the supported Linux x86-64 subset (plus editor integration), not a
list of design goals. Examples in design documents do **not** imply compiler
support:

- **Compiler and CLI:** lexing, parsing, semantic analysis and code generation
  for `.kyn` files. `kync check` reports diagnostics, `kync emit --asm` produces
  native assembly, `kync emit --llvm` produces textual IR, and
  `kync symbols --json` exposes compiler-resolved symbols/references. Quoted
  file imports resolve relative to the importer; cycles, missing files and
  duplicate symbols are diagnosed.
- **Core language:** explicitly typed `let`/`var`, functions and calls,
  `if`/`else`, `while`, short-circuit `&&`/`||`, `bool`, `i8`/`i16`/`i32`/`i64`,
  `u8`/`u16`/`u32`/`u64` and `usize`. The supported subset includes integer
  arithmetic, comparisons, bitwise operators, shifts and explicit
  integer-to-integer `as` casts.
- **Values and output:** `str` is a static pointer/length slice, not a managed
  string. `print(str)` writes text and `print_i32(i32)` writes decimal values.
  Structs with supported scalar fields, enums with optional `i32` payloads
  and `impl` methods have tested by-value call paths; `switch` over an enum
  variable is checked for exhaustiveness.
- **Pointers:** address-of, typed scalar dereference, struct pointer-field
  reads, scaled pointer arithmetic/distance and pointer equality for the
  current target. This is **not** a memory-safety or C-ABI guarantee.
- **Integer edge cases:** shift counts are reduced modulo the left operand's
  width. `/` and `%` cause a fatal trap on a zero divisor or signed `MIN / -1`
  (including `MIN % -1`). There is no recoverable exception or portable OS
  signal/exit-code guarantee.
- **Editor:** the VS Code extension supports highlighting, snippets,
  compiler-backed diagnostics, definition/reference navigation, workspace
  symbols, static completions, outline and compiler check/emit commands.
  It is not an LSP.

## Not implemented or not guaranteed

- **Language breadth:** no floating-point types, arrays/slices, generics,
  nested aggregate fields, general enum payloads, `Result<T, E>` or general
  string concatenation/formatting. `str` equality compares pointer/length
  identity, **not** text content.
- **Safety and runtime:** no pointer bounds/lifetime/ownership checks, defined
  nullability/aliasing model, integrated `unsafe` or `volatile`/MMIO contract,
  or usable allocation API. Overflow for `+`, `-` and `*` is not specified
  across backends; the division-trap and shift-count rules are not a general
  overflow policy.
- **Portability and interoperability:** no freestanding/embedded target,
  configurable target triple, stable external C ABI/`repr(C)` or integrated
  FFI. The native backend uses an internal register ABI on Linux x86-64, and
  LLVM IR has a fixed Linux x86-64 triple.
- **Completeness and distribution:** the standard library still contains
  stubs; self-hosting is not demonstrated. The extension has no integrated
  rename, formatter or debugger. The current prerelease has no binary assets,
  checksums or stable compatibility promise.

**Next priority:** specify and test `+`/`-`/`*` overflow behavior in both
backends; pointer safety and target/ABI contracts remain subsequent work.
See the [roadmap](ROADMAP.md) and [embedded analysis](docs/embedded.md) for
the longer-term plan.

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
# Check changed backend/CLI files; see .github/workflows/ci.yml for the
# complete CI formatting source set (some legacy files still have drift).
zig fmt --check build.zig src/main.zig src/codegen/llvm.zig src/codegen/x86_64.zig
zig build test
zig build e2e
zig build validate-ir
```

Use `zig build validate-ir-strict` to require an LLVM verifier. CI runs the strict validation step so a missing verifier cannot silently pass.

The published [v0.3.13-alpha.1](https://github.com/CeoMatheusDev/Kyn/releases/tag/v0.3.13-alpha.1)
commit [`e72993a`](https://github.com/CeoMatheusDev/Kyn/commit/e72993a76905624dde2d1f000a9fe15b88abd2cc)
passed both CI jobs **after merging**: Zig tests, native E2E, strict `llvm-as`
IR validation, extension tests and VSIX packaging
([main run 42538775584](https://github.com/CeoMatheusDev/Kyn/actions/runs/42538775584)).
For that release, local Zig 0.17.0/Linux x86-64 validation recorded **287/287
unit tests**, **167/167 native E2E cases** (including eight intentional traps)
and **120/120 LLVM 20-verified IR modules**; MCJIT executed the valid division
case and eight fatal cases. These results cover the release tree, **not** any
subsequent changes. Run the commands above on your own checkout;
`validate-ir` may skip without LLVM, whereas CI uses the strict step.

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

The `extension/` directory contains syntax highlighting, snippets and
compiler-backed diagnostics, definition/reference navigation and workspace
symbol search, plus static completions. It is not a language server and does
not provide a formatter or debugger. Rename support remains in the separate,
not-yet-integrated PR #36.

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
