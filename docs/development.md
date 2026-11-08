# Development

## Requirements

- **Zig 0.17.0** (declared in `build.zig.zon`; the `minimum_zig_version` field is
  checked by Zig itself).
- Git.
- For the native end-to-end suite: `bash`, GNU `as` and GNU `ld` on Linux
  x86-64. Without those tools `tools/e2e.sh` reports it and is skipped; the unit
  tests remain the base validation.

Confirm the installed version:

```sh
zig version   # expected: 0.17.0
```

When Zig is not installed on the system, one alternative is the PyPI package
`ziglang`, which distributes official binaries (version `0.17.0.post0`
corresponds to the same 0.17.0 compiler):

```sh
python3 -m pip download ziglang==0.17.0.post0 --no-deps -d /tmp/zig
python3 -m zipfile -e /tmp/zig/*.whl /install/path
/install/path/ziglang/zig version
```

## Clone and build

```sh
git clone https://github.com/CeoMatheusDev/Kyn.git
cd Kyn

zig build            # produces zig-out/bin/kync
zig build run -- --help
```

## Build commands

| Command | Effect |
| --- | --- |
| `zig build` | Compiles and installs `zig-out/bin/kync`. |
| `zig build test` | Runs the compiler unit tests and the experimental std tests. |
| `zig build e2e` | Compiles fixtures, assembles with `as`, links with `ld` and checks exit codes and printed text (`// expect-stdout:`). |
| `zig build validate-ir` | Validates the LLVM IR with `llvm-as`/`clang`; without LLVM it warns and skips. |
| `zig build validate-ir-strict` | Same as above, but fails when LLVM is missing (used in CI). |
| `zig build run -- <args>` | Runs the freshly built `kync` with the given arguments. |

## The `kync` CLI

```text
kync <command> [options] <file.kyn>      # loads the file and its imports

check <file>      validates syntax and semantics, no code generation
emit <file>       emits the selected backend artifact

--llvm            textual LLVM IR (default)
--asm             x86-64 assembly (Linux, System V)
-o <file>         writes the output to a file (default: stdout)
--lib             does not require 'fn main' (library unit)
-h, --help        help
-V, --version     version and backends
```

Exit codes (contract observed in the manual smoke tests):

| Code | Meaning |
| --- | --- |
| `0` | success |
| `1` | syntax or semantic error (diagnostics on stderr) |
| `2` | invalid usage (command/option/argument) |
| `3` | I/O failure (reading the source or writing the artifact) |

Imports: `import "path.kyn";` appears before the functions and the path is
resolved relative to the importing file's directory. Each file is read once
(diamond imports are merged), cycles and missing files become diagnostics (code
`1`) and diagnostics cite the source file.

Examples:

```sh
zig-out/bin/kync check tests/e2e/modules/import_nested/main.kyn
zig-out/bin/kync check tests/e2e/positive/fib.kyn
zig-out/bin/kync emit --llvm tests/e2e/positive/fib.kyn -o /tmp/fib.ll
zig-out/bin/kync emit --asm  tests/e2e/positive/fib.kyn -o /tmp/fib.s
as /tmp/fib.s -o /tmp/fib.o && ld /tmp/fib.o -o /tmp/fib && /tmp/fib; echo $?

# text output: `print` writes the string and the line break
zig-out/bin/kync emit --asm tests/e2e/positive/print_basic.kyn -o /tmp/p.s
as /tmp/p.s -o /tmp/p.o && ld /tmp/p.o -o /tmp/p && /tmp/p       # kyn / bootstrap

# computed values: `print_i32` formats in decimal (with sign)
zig-out/bin/kync emit --asm tests/e2e/positive/print_int_extremes.kyn -o /tmp/n.s
as /tmp/n.s -o /tmp/n.o && ld /tmp/n.o -o /tmp/n && /tmp/n       # 2147483647 / -2147483648 / 214748364
```

## Validation

The project only declares a step complete when there is an executable test:

1. **Unit tests** (`zig build test`): lexer, spans, diagnostics, AST, parser,
   semantics, backends and driver, plus the experimental std tests.
2. **End to end** (`zig build e2e`): every positive fixture becomes a native
   binary; the exit code is compared with `// expect-exit: N` and stdout with the
   `// expect-stdout: ...` lines (in order, one directive per line — that is how
   the `str`/`print`/`print_i32` fixtures are validated). The same applies to
   multi-file programs in `tests/e2e/modules/<case>/main.kyn`; the fixtures in
   `tests/integration/case_N.kyn` must exit with code `N`; every negative
   fixture must fail with code `1` and an `error:` message; in
   `tests/e2e/modules_negative/<case>/` the optional `expect-error.txt` file
   requires a specific excerpt in the message (cycle, missing file, duplicated
   symbol).
3. **LLVM IR** (`zig build validate-ir-strict`): runs `llvm-as` (or `clang`) over
   the IR of every supported fixture, including the multi-file programs and the
   `struct`/`print`/`print_i32`, `str`, struct-by-value, enum and method
   fixtures (90 modules). LLVM is not installed in the default development environment, so
   locally the `validate-ir` step only warns; CI installs LLVM and uses the
   **strict** variant, which fails if the verifier is missing or rejects any
   module.

The LLVM backend unit tests only check structure (terminated blocks, types,
instructions). Proof that the IR is accepted by an LLVM tool comes from CI, not
from the local tests.

## Continuous integration

`.github/workflows/ci.yml` runs on `push` (main and `arena/**`),
`pull_request` and manually. On `ubuntu-24.04` the workflow:

1. installs `python3-venv` and `llvm`;
2. installs Zig 0.17.0 from the official PyPI wheel (the same path described
   above) and exposes it on `PATH`;
3. runs `zig fmt --check build.zig src std`;
4. runs `zig build test` (244 + 7 tests) and `zig build e2e` (121 cases);
5. runs `zig build validate-ir-strict` (IR of 90 modules accepted by
   `llvm-as`).

A missing LLVM in CI **fails** the build, so IR validation cannot be skipped
silently.

## Release (SemVer)

The version lives only in `build.zig.zon` and is bumped on every integrated
cycle:

- `MAJOR` changes when the language specification gains a stable contract
  (1.0.0 is the stabilization milestone).
- `MINOR` follows each integrated feature set (`0.3.7`, `0.4.0`, …).
- the `-alpha.N` pre-release covers incremental cycles within the same `MINOR`.

A cycle only gets a tag after the `main` CI is green with `zig fmt --check`,
`zig build test`, `zig build e2e` and `zig build validate-ir-strict`. Tags are
annotated (`git tag -a vX.Y.Z-alpha.N`) and accompanied by a GitHub release with
highlights, validation evidence and the list of what **does not exist yet**.
First published tag: `v0.3.7-alpha.1` (commit `1c80a7b`).

## Structure

```text
build.zig              # single source for build, tests and e2e
build.zig.zon          # minimum Zig version, project version
src/
  root.zig             # public API ("kyn" module)
  main.zig             # kync CLI
  driver.zig           # lexer -> parser -> sema -> backend pipeline + import loader
  span.zig             # offsets/line/column
  diagnostics.zig      # diagnostics and rendering
  lexer/lexer.zig      # tokens with spans
  ast/ast.zig          # AST (structs, functions, statements, expressions)
  parser/parser.zig    # complete parser for the subset
  sema/sema.zig        # name resolution, types, mutability, slots
  sema/unsafe.zig      # unsafe/repr(C) policy (not wired yet)
  codegen/codegen.zig  # backend interface
  codegen/llvm.zig     # textual LLVM IR backend
  codegen/x86_64.zig   # native x86-64 backend (assemblable/executable)
  ffi/ffi.zig          # C FFI experiment
std/                   # experimental standard library (kyn:core, kyn:std)
tests/                 # .kyn fixtures (integration and e2e)
tools/e2e.sh           # end-to-end validation
```

## Recommended flow

1. Create a working branch.
2. Make one small, focused change.
3. Add or update tests covering the behavior.
4. Run `zig build test` and, if you touched backend/semantics, `zig build e2e`.
5. Update the affected documentation (`docs/status.md`, `docs/syntax.ebnf`,
   `CHANGELOG.md`, `DEVELOPMENT_STATE.md`).
6. In the pull request, state what was executed and what was not validated.

## Implementation conventions

- Prefer spans and slices into the input over string copies.
- Document who owns each allocation; the AST, symbol table, diagnostics and
  backend output live in one compilation's arena (`driver.compile`), released by
  `Result.deinit`.
- Separate syntax errors, semantic errors and internal backend failures
  (`codegen.Error`).
- Do not introduce standard library APIs without contract and tests.
- Do not mark a feature as done just because a file with the matching name
  exists.
