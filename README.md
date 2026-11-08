# Kyn

[![CI](https://github.com/CeoMatheusDev/Kyn/actions/workflows/ci.yml/badge.svg)](https://github.com/CeoMatheusDev/Kyn/actions/workflows/ci.yml)

**Kyn** is an experimental systems programming language project, developed with a
focus on explicit resource control, interoperability with C and low-level
compilation.

The repository brings together a compiler prototype written in Zig, experiments
of implementing the Kyn language itself, initial standard library modules and
tests/fixtures. The project is still under development: the available
implementation does not correspond to a stable, production-ready language.

> **Current state:** early-stage prototype, with an integrated frontend and a
> native x86-64 backend validated by execution. Interfaces, syntax, semantics and
> build commands may still change.

## Project goals

- Explicit control of allocation and memory lifetime.
- No garbage collector as a design goal.
- Interoperability with C and the ability to be used in low-level systems.
- A conceptual separation between essential features (`kyn:core`) and
  operating-system-dependent features (`kyn:std`).
- A compiler with a Zig bootstrap implementation and, in the future, components
  reimplemented in Kyn.

Those items describe goals and architectural direction; they must not be read as
guarantees of complete features.

## Implementation status

| Area | What exists | State |
| --- | --- | --- |
| Build | `build.zig` + `build.zig.zon` (Zig 0.17.0) | Working, validated |
| CLI | `kync check` / `kync emit` (`--llvm`, `--asm`, `-o`, `--lib`) | Working for the current subset |
| Lexer | `src/lexer/lexer.zig` with typed tokens and spans | Working, tested |
| Parser and AST | `src/parser/`, `src/ast/` for the documented subset | Working, tested |
| Modules | `src/driver.zig` (`compilePath`): `import "file.kyn";` resolved on disk | Working; paths relative to the importing file |
| Structs | `struct`, literals `Name { field: value }`, field access and assignment, by value in parameters/returns | Working locally, in calls (up to 6 fields) and across modules |
| Text and numbers | `str` as a static slice (by value in parameters/returns), builtin `print(...)` and `print_i32(...)` (text/decimals + line break) | Working locally and with modules; stdout checked in e2e |
| Semantic analysis | `src/sema/` with scopes, types and mutability | Working for `i32`/`bool`/`str`/`void` and structs |
| LLVM IR backend | `src/codegen/llvm.zig` derived from the AST | Accepted by `llvm-as` in CI (83/83 modules) |
| x86-64 backend | `src/codegen/x86_64.zig` (asm + `as`/`ld`) | Validated by execution |
| Implementation in Kyn | `src/kyn/`, `src/compiler/` | Skeleton / placeholders |
| Standard library | `std/` | Experimental |
| Tests | Unit (`zig build test`), e2e (`zig build e2e`) and IR (`zig build validate-ir`) | 228 unit tests (221 compiler + 7 std); 112 e2e cases (with stdout checked); IR validated by `llvm-as` in CI |

See the [detailed status](docs/status.md) and the
[subset accepted today](docs/syntax.ebnf) before depending on any feature.

## Requirements

- Zig **0.17.0** (checked by `build.zig.zon`).
- Git.
- Optional, for the native e2e suite: `bash`, GNU `as` and GNU `ld` on Linux
  x86-64.

## Getting the code

```sh
git clone https://github.com/CeoMatheusDev/Kyn.git
cd Kyn
```

## Building and testing

```sh
zig build                  # produces zig-out/bin/kync
zig build test             # unit tests (compiler + experimental std)
zig build e2e              # fixture -> assembly -> as/ld -> run -> check exit code
zig build validate-ir      # checks the LLVM IR with llvm-as/clang (when installed)
```

Example usage:

```sh
cat > hello.kyn <<'KYN'
fn main() -> i32 {
    let answer: i32 = 6 * 7;
    return answer % 256;
}
KYN

zig-out/bin/kync check hello.kyn
zig-out/bin/kync emit --llvm hello.kyn -o hello.ll
zig-out/bin/kync emit --asm  hello.kyn -o hello.s
as hello.s -o hello.o && ld hello.o -o hello && ./hello; echo "exit: $?"
```

A program can be split into files; every `import` comes before the functions and
the path is relative to the importing file:

```sh
cat > util.kyn <<'KYN'
fn double(x: i32) -> i32 {
    return x * 2;
}
KYN
cat > app.kyn <<'KYN'
import "util.kyn";

fn main() -> i32 {
    return double(21);
}
KYN
zig-out/bin/kync check app.kyn
zig-out/bin/kync emit --asm app.kyn -o app.s
```

Cycles, missing files and repeated functions across files are diagnosed with the
`file:line:column` of the source file.

Structs hold scalar fields and are handled by value in local variables
(`let`/`var`), with literals, field reads and writes:

```sh
cat > point.kyn <<'KYN'
struct Point {
    x: i32,
    y: i32,
}

fn main() -> i32 {
    var p: Point = Point { x: 3, y: 4 };
    p.x = p.x + p.y;
    return p.x;   // 7
}
KYN
zig-out/bin/kync emit --asm point.kyn -o point.s
```

A struct field of struct type and an empty `struct` are rejected with an explicit
diagnostic. Structs cross calls by value (one register per field, up to six
fields).

Text: `str` is a static slice and `print(...)` writes the text followed by a line
break (`write` from libc in the LLVM IR; a syscall in the native backend):

```sh
cat > hello2.kyn <<'KYN'
fn main() -> i32 {
    print("hello, kyn");
    let name = "bootstrap";
    print(name);
    return 0;
}
KYN
zig-out/bin/kync emit --asm hello2.kyn -o hello2.s
as hello2.s -o hello2.o && ld hello2.o -o hello2 && ./hello2
```

`print_i32` closes the other side of output: computed values appear in decimal
(0, positives, negatives and the `i32` limits), with the conversion done by a
dedicated routine in each backend — a `write` syscall in the native backend and
`@kyn_print_i32` calling libc `write` in the IR:

```sh
cat > count.kyn <<'KYN'
fn main() -> i32 {
    let a = 20;
    let b = 22;
    print("sum");
    print_i32(a + b);
    print_i32(0 - a);
    return 0;
}
KYN
zig-out/bin/kync emit --asm count.kyn -o count.s
as count.s -o count.o && ld count.o -o count && ./count
```

`str` in a struct field, comparison (`==`/`!=`), concatenation and formatting are
not supported yet and are diagnosed. `str` in parameters and returns is
supported by value (pointer + length, two registers per `str`).

`kync` returns `0` on success, `1` for compilation errors, `2` for invalid usage
and `3` for I/O failures. Details in [docs/development.md](docs/development.md).

New to the language? Start with the **[tutorial](docs/tutorial.md)**: a complete
guide, from the first program to structs by value, modules, diagnostics and
tests.

The `.kyn` files in `tests/` cover both the supported subset
(`tests/integration/`, `tests/e2e/`) and language cases **not** implemented yet
(for example `impl`, `Result<T, E>`, `unsafe`). Do not read the number of
fixtures as feature coverage.

## Repository structure

```text
.
├── build.zig            # build, tests and e2e
├── build.zig.zon
├── docs/                # architecture, status, grammars and language vision
├── src/
│   ├── ast/             # AST nodes
│   ├── codegen/         # backend interface, LLVM IR and x86-64
│   ├── compiler/        # initial modules written in Kyn (placeholders)
│   ├── ffi/             # interoperability experiments
│   ├── kyn/             # compiler prototypes in Kyn (placeholders)
│   ├── lexer/           # bootstrap lexer
│   ├── parser/          # bootstrap parser
│   ├── sema/            # semantic analysis and unsafe policy
│   ├── driver.zig       # integrated pipeline
│   ├── diagnostics.zig  # diagnostics and rendering
│   ├── span.zig         # source location
│   └── main.zig         # kync CLI
├── std/
│   ├── core/            # OS-independent primitives (experimental)
│   └── os/              # OS-dependent integrations (experimental)
├── tests/               # language fixtures (integration, e2e, fuzz...)
└── tools/e2e.sh         # native end-to-end validation
```

## Documentation

- [Overview and architecture](docs/architecture.md)
- [Implementation status and limitations](docs/status.md)
- [Development, build, CLI and tests](docs/development.md)
- [Evolving specification](docs/spec.md)
- [Preliminary `.kyn` language reference](docs/language_reference.md)
- [Language design principles](docs/language_design.md)
- [Implemented lexical grammar](docs/grammar.ebnf)
- [Syntactic grammar of the accepted subset](docs/syntax.ebnf)
- [Memory model — proposal](docs/memory_model.md)
- [Roadmap](ROADMAP.md)
- [Changelog](CHANGELOG.md)
- [How to contribute](CONTRIBUTING.md)

## Contributing

Contributions are welcome. Before opening a change, read
[CONTRIBUTING.md](CONTRIBUTING.md) and clearly describe the behavior implemented
and how it was verified (`zig build test`, `zig build e2e`).

Do not present prototypes, stubs or roadmap goals as finished features.

## License

The project declares dual MIT and Apache-2.0 licensing. Check the license files
present in the repository and confirm the applicable terms before redistributing.
