# Implementation status

The released baseline `v0.3.12-alpha.1` points to `main` commit `f977b27`,
whose [CI run 42534639767](https://github.com/CeoMatheusDev/Kyn/actions/runs/42534639767)
passed both jobs, including strict `llvm-as`. The division/remainder trap
contract below has separate local validation using Zig 0.17.0, Linux x86-64,
GNU `as`/`ld` and LLVM 20 (`llvmlite`). Previous `main` CI cannot validate
newer code: the final PR head and its post-merge `main` commit must pass their
own CI before the next tag. Earlier results remain historical evidence, not a
claim about outstanding feature branches.

## Summary

Kyn remains an **experimental prototype**. The integrated frontend pipeline
is **validated by execution**: `.kyn` sources of the supported subset compile
to x86-64 assembly, assemble, link and run with exit code/stdout checked. The
integrated shift contract defines counts modulo the left integer's width; the
division/remainder work below traps on zero divisors and signed MIN / -1 in
both backends. Neither establishes a stable calling convention, pointer safety
or a general arithmetic overflow model.

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

Still missing: generics, slices, `unsafe`, nested structs, `str` in a struct
field, **content-based** string equality (the supported `==`/`!=` compare the
slice pointer and length), concatenation or formatting, integrated FFI, a
stable standard library and functional self-hosting. The path to freestanding
and embedded targets is analysed in `docs/embedded.md`.

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
| Semantics | `src/sema/sema.zig` | Nested scopes, name resolution, types `i8`/`i16`/`i32`/`i64`/`u8`/`u16`/`u32`/`u64`/`usize`/`bool`/`str`/`void`/struct/enum (`isInteger`, `isValue`, `bitWidth`, `isSigned`, `fromName`, `name`, `registerWords`), enum cases (unique name and case, `i32` payload only), enum nominality in annotations, assignments, arguments and returns (`param_enum_ids`/`return_enum_id`), exhaustive `switch` (missing cases listed, unreachable `else`, unknown/duplicated case, payload binding rules), struct fields and literals, methods (`impl` target resolution, per-type name space, `Type_method` mangling, receiver `self: Name` rules, field/duplicate/symbol clash checks, shared argument checking between free and method calls), `str` and struct by value in parameters/returns (nominal identity preserved), six-register limit through `registerWordsOf` (`str`/enum/64-bit scalar = 2, struct field/pointer = 1, receiver included), `print`/`print_i32` builtins (arity and type checked, reserved names), mutability, calls, stack slots, `main` validation, `checkBinary` width-aware (arithmetic/comparison/bitwise require same non-bool integer type; shift result = left operand type; logical requires bool; `==`/`!=` fallback via `isValue()`), `checkExpr` for unary `-`/`~` (integer only, same type) and `.cast` (int↔int only, `bool`/`str` rejected, clear diagnostic), implicit narrowing rejected (initializer of `u8` from `i32` literal `300` fails) | Unit tests |
| LLVM IR backend | `src/codegen/llvm.zig` | Textual IR derived from the AST (arithmetic, comparisons, `&&`/`||` with `phi`, `if`, `while`, calls, `switch` lowered to `switch i32` on the tag with one block per arm); enums as two `alloca i32` slots (tag + payload), two `i32` parameters and a `{ i32, i32 }` return (`insertvalue`/`extractvalue`); structs in a contiguous `[n+1 x i64]` local frame with a reserved base word; `str` in `@.strN` with `declare i64 @write(i32, ptr, i64)`, `str` by value as `ptr`+`i64` in parameters and `{ ptr, i64 }` return, struct by value with parameters flattened into scalars and aggregate return `{ i32, i1, … }` (`insertvalue`/`extractvalue`); `print` calling `write` and `print_i32` through `@kyn_print_i32` (`urem`/`udiv`); `llvmType` maps `i8/u8`→`i8`, `i16/u16`→`i16`, `i32/u32`→`i32`, `i64/u64/usize`→`i64`; `typeAlign` maps 1/2/4/8; bitwise operators emit `and`/`or`/`xor`/`shl`/`ashr`/`lshr`; `~` emits `xor -1`; `as` emits `trunc`/`zext`/`sext`; address-of/typed scalar dereference and struct pointer-field reads use opaque `ptr`; pointer arithmetic scales signed offsets by `codegen.pointeeStride`; source `/`/`%` branch to `llvm.trap` before an invalid division | 120/120 modules locally verified via LLVM 20 `llvmlite`; strict `llvm-as` passed on the `v0.3.12-alpha.1` baseline; newer code requires CI |
| x86-64 backend | `src/codegen/x86_64.zig` | Linux assembly without libc, `_start` + `exit` syscall; enums (tag/payload) and `str` (pointer/length) use register pairs, structs use one register per field; 64-bit scalar integer parameters use low/high 32-bit halves in two registers while returns use `%rax`; pointers and wide struct fields use one 64-bit register. Narrow operations normalize results to 8/16 bits, wide operations use 64-bit ALU, casts extend/truncate without losing high bits. Typed pointer operations, strings and `print`/`print_i32` retain their tested paths. This is an internal Kyn ABI, not C-compatible; source `/`/`%` use width-matched divide instructions so zero and signed MIN / -1 trap | `as` + `ld` execution (167/167 local fixtures, eight SIGFPE cases; released `v0.3.12-alpha.1` `main` CI green) |
| FFI | `src/ffi/ffi.zig` | Isolated `extern "c" printf` experiment | Not integrated |
| `unsafe`/`repr(C)` | `src/sema/unsafe.zig` | Isolated, tested policy; the AST still has no such nodes | Unit tests of the module |
| Self-hosting | `src/kyn/*.kyn`, `src/compiler/*.kyn` | Placeholders; not executed by `kync` | Not demonstrated |
| Standard library | `std/core/core.zig`, `std/os/*.zig` | Experimental stubs; some APIs do no real I/O | Compile in the std tests |
| Fixtures | `tests/` | Numbered integration fixtures plus positive/negative programs and multi-file module scenarios under `tests/e2e/`; unsupported language experiments are kept separate from the accepted subset | `zig build e2e` (167/167 locally; strict CI on the newer branch is a separate gate) |

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
registers, counting `str` and each 64-bit integer scalar as two, each struct
field/pointer as one), `str` by value in parameters/returns and struct by value
in parameters, arguments and returns (up to 6 fields), explicit conversion
`expr as T` (int↔int only; `bool`/`str`/`void` rejected; same-width reinterprets
bits; narrowing truncates, widening zero/sign-extends), address-of `&var` (yields `ptr<T>` where `T` is
the type of `var`; `ptr<T>` is descriptive notation while source annotations
use `ptr`: local initializers retain a known pointee, generic parameters and
fields erase it, and unknown-to-known assignment is rejected), dereference
`*ptr` (yields the pointee type `T`), field access through a pointer
`(*ptr).field` (the pointee must be a known
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

## Division/remainder trap contract (local November 8, 2026)

Before this cycle, `i8` MIN divided by `-1` returned a truncated value in the
native backend: it used `idivl` even for a byte. LLVM emitted `sdiv i8` for the
same input, which produces poison; divisor zero also produced LLVM poison
while native division raised a CPU fault. Now source-level `/` and `%` have a
fatal trap, without a result, if the divisor is zero or a signed minimum is
paired with `-1`. This applies to all fixed integer widths and to `usize` for
zero divisors. Valid quotients truncate toward zero; signed remainders have
the dividend's sign. Source order and single evaluation of operands are
preserved. There is no catchable Kyn exception and **no portable signal/exit
code guarantee**: native Linux x86-64 raises SIGFPE (#DE), whereas LLVM 20
MCJIT uses an instruction trap (SIGILL on this host).

- Native `/`/`%` now use the actual 8-/16-/32-/64-bit `div`/`idiv` instruction,
  so valid operations have **no added branches** and even narrow MIN / -1
  faults instead of truncating a wide quotient. Result normalization remains.
- LLVM IR checks the divisor and, for signed types, MIN / -1 **before** the
  divide/remainder instruction. A single `llvm.trap` block per function is
  shared by the guards; no libc call is added for arithmetic. Internal pointer
  stride and decimal-printing divisions use fixed positive divisors.
- Local `zig build test` with a fresh cache: **280 compiler + 7 std = 287/287**.
  `zig build e2e`: **167/167** native cases, including eight trap fixtures with
  Linux SIGFPE exit status 136 and one valid-width/stdout/short-circuit case.
  No previous fixtures were removed. `tools/e2e.sh` disables core dumps for
  these deliberate fault tests.
- LLVM 20 `llvmlite.parse_assembly` + `.verify`: **120/120** emitted modules.
  MCJIT in isolated processes: the valid fixture returned 0 and wrote `rhs`
  exactly once; **8/8** exceptional fixtures trapped. This is runtime evidence,
  not a substitute for the strict `llvm-as` check on the final PR and the
  post-merge `main` commit.

**Still open:** overflow for `+`, `-`, `*`, pointer bounds/lifetimes, a stable
external ABI and cross-target/freestanding behavior. PRs #36/#37 remain open
with red compiler checks and must be reviewed independently.

## Shift-count contract (PR #41, integrated November 8, 2026)

Before this change, shifting a `u8` value by 8 returned **0** natively: the
32-bit x86 instruction shifted by 8 and only then truncated to 8 bits. LLVM
emitted `shl i8` with count 8, which produces poison rather than a portable
result. Shift counts are now reduced **modulo the left operand's width**
(8/16/32/64), including negative counts via their two's-complement low bits.
The LLVM backend masks the count after matching its bit width and before the
shift; x86-64 keeps its implicit masks for 32-/64-bit values and adds a single
mask instruction for 8-/16-bit values. Valid in-range shifts are unchanged.

- `zig build`, `zig build test` with a fresh Zig cache: **278 compiler + 7 std =
  285/285** tests passed.
- `zig build e2e`: **158/158** native fixtures, including the new
  `shift_count_modulo.kyn` (8-/16-/32-/64-bit, signed/unsigned and mixed count
  types). No existing fixtures were removed.
- LLVM 20 `llvmlite.parse_assembly` + `.verify`: **111/111** modules. The new
  fixture also returned 0 under MCJIT. These local checks are independent of
  strict `llvm-as` CI; both the final PR head (run 42532780270) and the
  post-merge `main` commit (run 42532984118) passed.
- Extension check/tests/manifests: 4/4 tests passed locally.

At the time of PR #41, division by zero and signed division overflow still
differed between backends; the later division/remainder cycle above addresses
that gap. Other arithmetic overflow, external ABI, pointer bounds/lifetimes,
freestanding targets and 1.0 readiness remain open. PRs #36/#37 still have
failing compiler checks and must not be merged red.

## Previous integer-width cycle (PR #40, local November 8, 2026)

- `zig build`, `zig build test` (fresh local Zig cache): success;
  **276 compiler + 7 std = 283/283** tests.
- `zig build e2e`: **157/157** native fixtures, including four new executable
  width/ABI cases and two negative diagnostics. Existing fixtures remain.
- LLVM 20 `llvmlite.parse_assembly` + `.verify`: **110/110** emitted modules;
  all four new positive cases executed with MCJIT (exit 0). The local
  environment has no `llvm-as`; these local checks are separate from the
  strict `llvm-as` result in PR #40's CI.
- CI formatting source set plus changed backend files, `git diff --check`:
  passed; extension check/tests/manifests: 4/4 tests passed. PR #40 and its
  post-merge `main` CI passed; PRs #36/#37 remain separate and red.

### GitHub CI and open branches

- [PR #38](https://github.com/CeoMatheusDev/Kyn/pull/38) merged as
  `ac49f66f944aa793d01c430fad7940254632e703`. Both CI jobs passed,
  including strict `zig build validate-ir-strict` (`llvm-as`) and native E2E
  ([PR run 42529572145](https://github.com/CeoMatheusDev/Kyn/actions/runs/42529572145)).
- PR #39 (documentation) merged as `d2c067e7c39d3a42cbeb83d40d8ad7dd9fba1e17`.
  Post-merge `main` [CI run 42530205764](https://github.com/CeoMatheusDev/Kyn/actions/runs/42530205764)
  passed both jobs (including strict LLVM validation). No branches were deleted.
- [PR #40](https://github.com/CeoMatheusDev/Kyn/pull/40) was merged as
  `33a61cd5bd7b5afe38e2b2fc21a320c112ad8686`. The final PR head passed
  both jobs (including strict LLVM and 157 E2E cases,
  [run 42531600138](https://github.com/CeoMatheusDev/Kyn/actions/runs/42531600138));
  post-merge `main` [run 42531803954](https://github.com/CeoMatheusDev/Kyn/actions/runs/42531803954)
  passed both jobs on that exact merge commit. The source branch was preserved.
- [PR #41](https://github.com/CeoMatheusDev/Kyn/pull/41) merged as
  `c04a6a7828f969ff5eff3f60be552a080f51a4b1`. The final PR head passed
  both jobs, including strict `llvm-as` and 158 executable E2E cases
  ([run 42532780270](https://github.com/CeoMatheusDev/Kyn/actions/runs/42532780270));
  post-merge `main` [run 42532984118](https://github.com/CeoMatheusDev/Kyn/actions/runs/42532984118)
  passed both jobs on the merge commit.
- PR #37 (target foundations, 10 exclusive commits) and PR #36 (editor rename,
  4 exclusive commits) remain open with failing compiler checks. Neither was
  merged or discarded; evaluate them independently after their required checks
  pass. Division failure behavior is addressed in the separate cycle above;
  prioritize remaining arithmetic overflow and target-aware contracts next.

**Reproduced, then fixed in PR #40:** at `main` commit `d2c067e`, the
following program returned **1** as native assembly but **0** with LLVM 20
MCJIT:

```kyn
fn main() -> i32 {
    let x: i64 = 2147483647 as i64;
    let y: i64 = x + (1 as i64);
    if y > x { return 0; }
    return 1;
}
```

It now returns **0** in both backends. Native wide ALU, signed/unsigned
comparisons, casts and internal calls are covered by
`tests/e2e/positive/integer_width_*.kyn`; narrow integer results are normalized
after arithmetic. Unary `-` now accepts all integer widths (including modular
unsigned values); `bool` remains rejected. The six-word limit is unchanged:
wide scalar arguments use two registers (low/high 32-bit halves), whereas a
wide struct field or pointer uses one full 64-bit register. Returns use `%rax`.
LLVM IR uses scalar `i64` arguments, so this is **not** a shared C-compatible
calling convention. Division failure behavior is specified in the later
cycle above; pointer validity/lifetimes, other arithmetic overflow and
cross-target integer semantics still lack portable language contracts.
Shift-count semantics are specified in PR #41 above. No freestanding target,
kernel ABI, memory-safety guarantee or 1.0 readiness is implied.

## Historical validation baseline (previous cycles)

The following older numbers and green CI runs describe earlier revisions,
not the current `main` or the present state of the open PRs.

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
8. Release with artifacts, checksums and a compatibility policy. *(partial:
   experimental tags and GitHub releases exist, but no build artifacts,
   checksums or stable compatibility policy yet)*

Until every criterion is met, use the terms **experimental**, **partial** and
**under development**.
