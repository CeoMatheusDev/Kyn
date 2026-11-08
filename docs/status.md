# Implementation status

This document describes what was **observed at run time** in the review of
November 8, 2026, with Zig 0.17.0 and `as`/`ld` available. It adds the Phase
1.1 features: fixed-width integers (`i8`/`i16`/`i32`/`i64`/`u8`/`u16`/`u32`/
`u64`/`usize`), bitwise operators (`&` `|` `^` `~` `<<` `>>`) and explicit
conversion (`as T`). It replaces earlier
assessments based only on reading files.

## Summary

Kyn remains an **experimental prototype**. The difference from the previous
cycle is that there is now an integrated frontend pipeline **validated by
execution**: `.kyn` sources of the supported subset are compiled to x86-64
assembly, assembled, linked and executed with the exit code checked.

There are also now **named composite types** (`struct` with scalar fields,
literals, field access/assignment, copy by value) and **text and number
output**: `str` as a static slice (pointer + length) that also **crosses calls
by value** in parameters and returns, `print(...)` for text and `print_i32(...)`
for **values computed in decimal** (with sign and correct `i32` limits). That
makes it possible to validate **content**, not only the process exit code, and
the e2e suite checks stdout (`// expect-stdout:`).

Structs also cross calls **by value** now (parameters, arguments and returns),
with one register per field and the same six-register limit as `str`.

Enums with payload and exhaustive `switch` are implemented: a case is a tag
(the declaration order) plus one payload slot, `Shape.Circle(5)` builds a value,
`Color.Red` is a case without payload, and `switch` over an enum variable is
checked for exhaustiveness (missing cases are listed, a redundant `else` is
reported) and binds the payload with `Circle(radius)`. Enums also cross calls
**by value** now: a parameter and a return carry the pair (tag, payload) in two
registers, and the enum identity is checked in arguments, returns and
annotations. A struct field of enum type is still diagnosed as unsupported.

Methods are implemented too: an `impl` block holds `fn` declarations whose first
parameter is the receiver `self: Name` (by value), `value.method(args)` passes
the receiver as argument 1, the symbol is `Type_method` in both backends, and the
declaration rules (receiver shape, no field/duplicate/symbol clash, `main` free,
target declared) are all diagnosed. Methods also work for enums, chain on call
results (`p.moved(1, 1).sum()`) and count in the six-register limit.

Still missing: generics, slices, `unsafe`, struct with a struct field
(nested), `str` in a struct field, `str` comparison, concatenation or formatting,
integrated FFI, a stable standard library and functional self-hosting. The path
to freestanding/embedded targets is analysed in `docs/embedded.md`.

## Evidence per component

| Component | File | Observed state | Validation |
| --- | --- | --- | --- |
| Build | `build.zig`, `build.zig.zon` | Single source for build, test and e2e; Zig 0.17.0 required | `zig build`, `zig build test` run |
| CLI | `src/main.zig` | `kync check`/`emit` with `--llvm`/`--asm`, `-o`, `--lib`; codes 0/1/2/3 | Manual smoke tests recorded in `docs/development.md` |
| Lexer | `src/lexer/lexer.zig` | Typed tokens with span (line/column), keywords (including `import`, `struct`, `enum`, `impl` and `switch`), two-character operators (including `->` and `=>`), punctuation with `.`, string literal without escapes; discards comments/whitespace | Unit tests |
| Spans | `src/span.zig` | Offsets + line/column; no text copies | Unit tests |
| Diagnostics | `src/diagnostics.zig` | Stable category + message + line/caret + source file (`file`) | Unit tests |
| AST | `src/ast/ast.zig` | Functions, `struct`/fields, `enum`/cases (optional payload), parameters, `let`/`var`, assignment (variable and field), `return`, `if`/`else`, `while`, `switch` with arms/`else`, blocks, expressions (field access, struct literal, enum case, enum constructor, string literal), binary operators (`+ - * / % == != < <= > >= && || & | ^ << >>`), unary operators (`- ! ~ & *`), `Expr.Kind.cast` (struct `Cast` with `expr` + `type_name`), `Call.builtin` for `print` | Unit tests |
| Parser | `src/parser/parser.zig` | Whole program, `import` before declarations, `struct`, `enum` with optional payload, `impl` blocks (their methods join `Program.functions` in source order), `switch` arms (`Case`, `Case(name)`, `else`), struct literals and field access, enum constructors (`Shape.Circle(5)`), method calls (`value.method(args)`), precedence and associativity (including bitwise `|`/`^`/`&`/`<<`/`>>`), unary `~`, address-of `&`, dereference `*`, `expr as Type` cast syntax, errors with span | Unit and negative tests |
| Modules | `src/driver.zig` | `compilePath` loads the import graph in pre-order, normalizes paths, deduplicates and flattens into one `Program` | Tests with a temporary directory + 3 executed e2e fixtures + 3 negative ones |
| Semantics | `src/sema/sema.zig` | Nested scopes, name resolution, types `i8`/`i16`/`i32`/`i64`/`u8`/`u16`/`u32`/`u64`/`usize`/`bool`/`str`/`void`/struct/enum (`isInteger`, `isValue`, `bitWidth`, `isSigned`, `fromName`, `name`, `registerWords`), enum cases (unique name and case, `i32` payload only), enum nominality in annotations, assignments, arguments and returns (`param_enum_ids`/`return_enum_id`), exhaustive `switch` (missing cases listed, unreachable `else`, unknown/duplicated case, payload binding rules), struct fields and literals, methods (`impl` target resolution, per-type name space, `Type_method` mangling, receiver `self: Name` rules, field/duplicate/symbol clash checks, shared argument checking between free and method calls), `str` and struct by value in parameters/returns (nominal identity preserved), six-register limit through `registerWordsOf` (`str` = 2, enum = 2, struct field = 1, receiver included), `print`/`print_i32` builtins (arity and type checked, reserved names), mutability, calls, stack slots, `main` validation, `checkBinary` width-aware (arithmetic/comparison/bitwise require same non-bool integer type; shift result = left operand type; logical requires bool; `==`/`!=` fallback via `isValue()`), `checkExpr` for `.unary.bitnot` (integer only, same type) and `.cast` (int↔int only, `bool`/`str` rejected, clear diagnostic), implicit narrowing rejected (initializer of `u8` from `i32` literal `300` fails) | Unit tests |
| LLVM IR backend | `src/codegen/llvm.zig` | Textual IR derived from the AST (arithmetic, comparisons, `&&`/`||` with `phi`, `if`, `while`, calls, `switch` lowered to `switch i32` on the tag with one block per arm); enums as two `alloca i32` slots (tag + payload), two `i32` parameters and a `{ i32, i32 }` return (`insertvalue`/`extractvalue`); structs through scalar replacement (one `alloca` per field); `str` in `@.strN` with `declare i64 @write(i32, ptr, i64)`, `str` by value as `ptr`+`i64` in parameters and `{ ptr, i64 }` return, struct by value with parameters flattened into scalars and aggregate return `{ i32, i1, … }` (`insertvalue`/`extractvalue`); `print` calling `write` and `print_i32` through `@kyn_print_i32` (`urem`/`udiv`); `llvmType` maps `i8/u8`→`i8`, `i16/u16`→`i16`, `i32/u32`→`i32`, `i64/u64/usize`→`i64`; `typeAlign` maps 1/2/4/8; bitwise operators emit `and`/`or`/`xor`/`shl`/`lshr`; `~` emits `xor -1`; `as` emits `trunc`/`zext`/`sext`; address-of and dereference currently fail with `UnsupportedNode` in this backend | Structural tests locally; 87/87 modules accepted by the LLVM verifier (LLVM 22 through `llvmlite` locally, `llvm-as` in CI) |
| x86-64 backend | `src/codegen/x86_64.zig` | System V assembly without libc, `_start` + `exit` syscall; enums in two slots (tag + payload) with `switch` as `cmpl`/`je` chains, parameters/arguments as register pairs and the return in `%eax`/`%edx`; struct in consecutive slots (base + one per field); `str` in two slots, `str` parameters/returns in register pairs (`(%rdi,%rsi)`, `(%rdx,%rcx)`, `(%r8,%r9)`; return in `%rax`/`%rdx`), struct by value with one register per field (return in `%eax`/`%edx`/`%ecx`/`%r8d`/`%r9d`/`%r10d`), text in `.rodata` and `print` through the `write` syscall; `print_i32` with a single decimal routine (unsigned `divl`); `regForWidth` maps 8→`%al`, 16→`%ax`, 32→`%eax`, 64→`%rax`; bitwise emit `andl`/`orl`/`xorl`/`shll`/`shrl`; `~` emits `notl %eax`; `as` emits `movsx`/`movzx` (extension) or no-op (truncation reads low part); native backend lowers address-of, dereference, pointer arithmetic and pointer comparisons | Executed: `as` + `ld` + exit code and stdout checked |
| FFI | `src/ffi/ffi.zig` | Isolated `extern "c" printf` experiment | Not integrated |
| `unsafe`/`repr(C)` | `src/sema/unsafe.zig` | Isolated, tested policy; the AST still has no such nodes | Unit tests of the module |
| Self-hosting | `src/kyn/*.kyn`, `src/compiler/*.kyn` | Placeholders; not executed by `kync` | Not demonstrated |
| Standard library | `std/core/core.zig`, `std/os/*.zig` | Experimental stubs; some APIs do no real I/O | Compile in the std tests |
| Fixtures | `tests/` | Numbered integration fixtures plus positive/negative programs and multi-file module scenarios under `tests/e2e/`; unsupported language experiments are kept separate from the accepted subset | `zig build e2e` (130 cases in the latest recorded local run) |

## Language subset accepted today

```kyn
fn sum(a: i32, b: i32) -> i32 {
    return a + b;
}

fn main() -> i32 {
    var total: i32 = 0;
    let step: i32 = 2;
    while total < 10 {
        total = total + step;
    }
    if total == 10 && sum(1, 2) == 3 {
        return total % 256;
    } else {
        return 1;
    }
}
```

Supported: `import "path";` before declarations (`.kyn` files resolved relative
to the importing file, each loaded once), `enum Name { Case, Case(i32) }` with
cases in declaration order (the tag), `Color.Red` for a case without payload,
`Shape.Circle(5)` for a case with payload, `switch` over an enum variable with
`Case`, `Case(name)` and `else` arms (`=>`), exhaustiveness enforced, enums by
value in parameters and returns (two registers, nominal identity checked),
`struct Name { ... }` with scalar fields, literals `Name { field: value }` (every field, once each), `p.field`
access and `p.field = v` assignment on `var` variables, struct copy by value,
string literals and `str` variables (inferred or annotated) with copy and
assignment, builtin `print(s: str)` and `print_i32(n: i32)` (text and decimals
with a line break), `fn`, `let`/`var` with a mandatory initializer, type
annotation or inference (`i8`/`i16`/`i32`/`i64`/`u8`/`u16`/`u32`/`u64`/
`usize`, `bool`, `str`, `void`, `ptr`), assignment (only on
`var`), `return`, `if`/`else`/`else if`, `while`, blocks, arithmetic
expressions, comparisons, `&&`/`||` with short-circuit, bitwise `&` `|` `^` `~`
`<<` `>>` (same-type integers), unary `-`/`!`/`~`/`&`/`*`, integer and boolean
literals, direct calls to functions of the program itself (up to 6 argument
registers, counting `str` as two and each struct field as one), `str`
by value in parameters/returns and struct by value in parameters, arguments and
returns (up to 6 fields), explicit conversion `expr as T` (int↔int only;
`bool`/`str`/`void` rejected; same-width is a no-op; narrowing truncates,
widening zero/sign-extends), address-of `&var` (yields `ptr<T>` where `T` is
the type of `var`; `ptr<T>` is descriptive type notation, while source annotations use `ptr` for `ptr<unknown>`, assignment-compatible
with any `ptr<T>`), dereference `*ptr` (yields the pointee type `T`),
field access through a pointer `(*ptr).field` (the pointee must be a known
struct, the struct_id is tracked from `&struct_var`), pointer arithmetic
(`ptr + i32`, `i32 + ptr`, `ptr - i32` yield `ptr`; `ptr - ptr` yields `i32`)
and pointer comparison (`ptr == ptr`, `ptr != ptr` yield `bool`). Pointers
count as one register in the six-register limit. String comparison
(`str == str`, `str != str`) compares both pointer and length and yields `bool`.

Outside the subset (diagnosed or rejected): enum **struct fields**, enum payload
types other than `i32`, operators on enum values (`==`, arithmetic), `switch`
over a constructed value, associated functions without a receiver, receiver
literal or field read on a call result, references (`&self`), `unsafe`,
`#[...]` attributes, struct with a struct field, empty struct, struct field of
type `str`, `str` relational operators (`<`, `<=`, `>`, `>=`), concatenation
and formatting of `str`, `f32`/`f64` and other types, `[]T` slices, generics,
`Result<T, E>`/`?`, closures, `for`, visibility (`pub`), qualified/selective
imports and packages.

## Validation executed in this cycle

- `zig build` — success.
- `zig build test` — 246 tests in the compiler suite (spans, lexer,
  diagnostics, ast, parser, sema, unsafe, backends, driver, multi-file loading,
  structs, `str`/`print`, `str` by value in calls, struct by value in calls,
  enums by value in calls, `impl`/methods, `print_i32`, enums with payload and
  exhaustive `switch`, string pool and rejection of `void` variables) plus 7
  from the experimental `std` (253 in total). One existing sema test was
  retargeted from `u8` (now accepted) to `i128` (still unknown).
- `zig build e2e` — 130/130 cases: 31 behavioral fixtures plus 3 new ones
  (`bitwise`, `cast` and `pointer`), 2 new pointer field-access fixtures
  (`pointer_field`, `ptr_field_unknown`), 9 executed multi-file programs,
  50 `case_N.kyn` fixtures with exit code `N`, 29 negative fixtures
  (8 enum, 4 struct, 3 methods, 4 `str`/`print`, 2 `print_i32`,
  1 `str` field, 1 `main` returning `str`, 1 implicit narrowing
  `implicit_narrowing`, 1 pointer type mismatch `ptr_type_mismatch`,
  1 pointer field unknown field `ptr_field_unknown`), 2 modules with enums
  (`import_enum`, plus the method example `import_method`) and 3 negative
  modules (cycle, missing file, duplicated symbol) with the expected message.
  The enum negatives include nominal identity (`enum_nominal`) and the
  two-register limit (`enum_registers`).
- `zig fmt --check build.zig src std` — no differences.
- `zig build validate-ir` (local, no LLVM) — warns and skips, as documented for
  the development environment; the same script covers 90 modules when
  `llvm-as`/`clang` is available, and all 87 were verified here against LLVM 22
  through `llvmlite` (`parse_assembly` + `verify`).
- CI (`.github/workflows/ci.yml`) — runs `42427966554` (PR #23) and
  `42428126584` (`main` after merge) green with `zig fmt --check`, `zig build
  test` (245 + 7 tests), `zig build e2e` (121 cases, with stdout checked) and
  `zig build validate-ir-strict` (90 modules accepted by `llvm-as`, including
  the `{ ptr, i64 }` aggregates of `str` and the `{ i32, i1, … }` of structs).
  The strict step fails if the verifier is missing or rejects any module.

Not validated: execution on platforms other than Linux x86-64; performance;
fidelity of the IR to LLVM targets other than x86-64 (the `target triple` is
fixed).

## Historical divergences

- `CHANGELOG.md` contains old entries (up to `v2.3.0`) that describe milestones
  unproven by the code. They were kept for traceability, with a warning in the
  file itself.
- The vision documentation (`language_reference.md`, `spec.md`,
  `memory_model.md`) remains non-normative; `syntax.ebnf` now describes only
  what the parser accepts.

## Minimum criteria to declare a stable version

1. Reproducible build documented on a clean environment. *(met)*
2. CLI with specified exit codes and diagnostics. *(met for the current subset)*
3. Pipeline lexer → parser → AST → semantics → backend integrated. *(met)*
4. Unit, integration and regression tests in CI. *(tests exist; CI does too)*
5. Negative tests for invalid input and boundary cases. *(partial)*
6. Memory and FFI contracts documented and tested. *(no)*
7. Self-hosting proven by a reproducible bootstrap. *(no)*
8. Release with artifacts, checksums and a compatibility policy. *(partial: tag
   `v0.3.7-alpha.1` published, no build artifacts yet)*

Until every criterion is met, use the terms **experimental**, **partial** and
**under development**.
