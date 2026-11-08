# DEVELOPMENT_STATE — Kyn

**Maintained by:** continuity agent (Arena)
**Active branch:** `arena/cb8e637d-kyn` (from `d85f459` of `main`)
**Integration:** PRs #7–#11 (modules/`import`), PR #13 (`struct` with value,
`4234c07`), PR #15 (`str`/`print`, `89ca6ce`), PR #17 (`print_i32`,
`87903db`), PR #18 (docs, `3be9df0`), PR #19 (`str` by value, `9ec07be`),
PR #20–#22 (records, `2a68d9a`/`da92f44`/`d6eb534`), PR #23 (struct by value,
`1c80a7b`), PR #24 (records, `288eb3f`), PR #26 (`enum` + `switch`, `9125bff`),
PR #27 (records, `4e6a023`), PR #28 (enums by value, `9b989ad`) and PR #29
(release records, `d85f459`) merged into `main` (2026-11-07/08). Tags:
**`v0.3.7-alpha.1`** at `1c80a7b` (first tag), **`v0.3.9-alpha.1`** at `9125bff`
and **`v0.3.10-alpha.1`** at `9b989ad`, each with a GitHub release.
**Project version:** `0.3.11-alpha.1`
**Last validation:** 2026-11-09 — local (Zig 0.17.0 + GNU `as`/`ld`, Linux
x86-64): `zig build`, `zig build test` (244 compiler tests + 7 std), `zig build
e2e` (121/121, with stdout checked, including `str`, struct/enum by value and
methods on both receiver types) and `zig fmt --check`; `validate-ir` locally
without LLVM (documented skip) but all 90 emitted modules verified against
LLVM 22 through `llvmlite` (`parse_assembly` + `verify`); the 24 code blocks of
`docs/tutorial.md` checked with `kync check` (19 compile, 1 is a library file, 1
imports a module, 3 fail with the documented error) — the new method blocks also
run through `as`/`ld` (exit `34` and exit `6`).
**Working tree state:** check with `git status` before acting

---

## 1. How to prepare the environment (mandatory)

The Zig binary is **not** preserved between sessions (installed outside the
snapshot, in `~/.local`). Reinstall it before any validation:

```sh
python3 -m pip download ziglang==0.17.0.post0 --no-deps -d /tmp/zigwheel
mkdir -p ~/.local/zigpkg && cd ~/.local/zigpkg
python3 -m zipfile -e /tmp/zigwheel/*.whl .
chmod +x ziglang/zig && mkdir -p ~/.local/bin && ln -sf ~/.local/zigpkg/ziglang/zig ~/.local/bin/zig
export PATH=$HOME/.local/bin:$PATH
zig version    # must print 0.17.0
```

`ziglang==0.17.0` is *yanked* (partial upload); `0.17.0.post0` is the same
compiler with an intact wheel. There is no `llc`/`clang` in the environment —
only `as`, `ld`, `gcc` (GNU). That defines what can be validated (see §3).

## 2. Real project state (verified, not assumed)

Kyn is a systems language prototype with a Zig bootstrap compiler. In this cycle
the frontend pipeline is **integrated and validated by execution**:

```text
.kyn -> lexer (tokens+spans) -> parser (whole program) -> AST
     -> semantics (scopes/types/mutability/slots) -> backend
          -> textual LLVM IR (structural validation)
          -> x86-64 assembly (as + ld + execution: exit code checked)
```

| Component | File | State |
|---|---|---|
| Build | `build.zig`, `build.zig.zon` | Single source; `zig build`, `zig build test`, `zig build e2e` |
| CLI | `src/main.zig` | `check`/`emit` (`--llvm`, `--asm`, `-o`, `--lib`), codes 0/1/2/3 |
| Lexer | `src/lexer/lexer.zig` | Typed tokens, keywords (`import`, `struct`, `enum`, `impl`, `switch`), 1–2 char operators (including `->`/`=>`), `.` and other punctuation, string literal without escapes, spans; discards trivia |
| Spans | `src/span.zig` | offset + 1-based line/column; no text copies |
| Diagnostics | `src/diagnostics.zig` | stable category + message + line/caret + `file` (source file) |
| AST | `src/ast/ast.zig` | program with `imports`, `structs`, `enums` (cases with optional payload) and `impl` blocks (methods also live in `functions`, in source order), functions (`file_id`, `owner_type`), params, let/var, assign (variable and field), return, if/else, while, `switch` (arms with optional payload binding, `else`), blocks, expressions (field access, struct literal, enum case, enum constructor, string literal), `Call.builtin` (`print`, `print_i32`) |
| Parser | `src/parser/parser.zig` | whole program, `import` before declarations, `struct`, `enum` (optional payload, trailing comma), `impl` blocks (only `fn` inside, methods join `Program.functions`), `switch` arms (`Case`, `Case(name)`, `else`), literals, field access, dotted constructors and method calls, precedence/associativity, error on the first invalid token |
| Semantics | `src/sema/sema.zig` | scopes, resolution, `i32`/`bool`/`str`/`void`/struct/enum, enum cases (unique, `i32` payload only, tag = declaration order), enum nominality in annotations/assignments/arguments/returns (`param_enum_ids`, `return_enum_id`), exhaustive `switch` with payload binding rules, `alwaysReturns` over switches, methods (`Owner`, `impl` target resolution, `Type_method` mangling + symbol collision check, per-type name space, receiver `self: Name` rules, `invalid_method` diagnostics, shared `checkSignature` for free and method calls), struct fields and literals, `str` and struct by value in parameters/returns (nominal identity in `param_struct_ids`/`return_struct_id`), 6-register limit through `registerWordsOf` (`str` = 2, field = 1), generic builtins (`print`/`print_i32`: arity, type and reserved name), mutability, calls, slots, `main`, `alwaysReturns` |
| LLVM backend | `src/codegen/llvm.zig` | IR derived from the AST; enums as two `alloca i32` (tag + payload) with `switch i32` per arm, two `i32` parameters and `{ i32, i32 }` return; structs through scalar replacement (one `alloca` per field); `str` in `@.strN` + `declare i64 @write` + two `alloca`s, `str` by value as `ptr`+`i64` and `{ ptr, i64 }` return, struct by value with flattened parameters and aggregate return `{ i32, i1, … }` (`insertvalue`/`extractvalue`); `print_i32` through `@kyn_print_i32` (once per module); validated by `llvm-as` in CI |
| Native backend | `src/codegen/x86_64.zig` | System V without libc; method symbols `kyn_Type_method` with the receiver as argument 1 (`emitCallWith` + `codegen.Arguments`); enums in two slots (tag + payload) with `switch` as a `cmpl`/`je` chain, parameters/arguments as register pairs and return in `%eax`/`%edx`; struct in consecutive slots and by value with one register per field (return `%eax`/`%edx`/`%ecx`/`%r8d`/`%r9d`/`%r10d`); `str` in two slots (pointer/length) and by value in register pairs (return `%rax`/`%rdx`), text in `.rodata` and `print` through the `write` syscall; `print_i32` with a single decimal routine in `.text`; validated by running binaries and checking stdout |
| Driver | `src/driver.zig` | arena per compilation; `compile` (single buffer) and `compilePath` (import graph, dedupe, cycles, flatten); `Result.deinit()` |
| `unsafe`/`repr(C)` | `src/sema/unsafe.zig` | isolated, tested policy; no AST nodes yet |
| Self-hosting | `src/kyn/*.kyn`, `src/compiler/*.kyn` | placeholders; not executed |
| Std | `std/core/*`, `std/os/*` | experimental stubs; compile in the tests |
| Fixtures | `tests/` | 50 `integration/case_N.kyn` (supported) + 71 entries in `tests/e2e` (31 positive, 9 modules, 28 negative, 3 negative modules); the rest not supported yet |
| CI | `.github/workflows/ci.yml` | ubuntu-24.04: fmt + test + e2e + strict IR validation |
| IR validation | `tools/validate-ir.sh` | `llvm-as`/`clang` over 90 modules (includes multi-file, `struct`, `str`/`print`, `str`/struct/enum by value, methods, `print_i32`); strict in CI |
| Tutorial | `docs/tutorial.md` | Language guide (20 sections): CLI, types, control flow, structs by value, enums with `switch`, methods/`impl`, modules, diagnostics, tests, limits and roadmap; 24 `kyn` blocks checked with `kync check` |
| Embedded analysis | `docs/embedded.md` | Readiness, blockers and dependency order for freestanding/embedded targets; explicit "not implemented" |

### Subset accepted today

`import "path.kyn";` before declarations (path relative to the importing file,
each file loaded once, symbols flattened into a single scope), `enum Name {
Case, Case(i32) }` with tags in declaration order, `Color.Red` and
`Shape.Circle(5)` values, `switch` over an enum variable (`Case`,
`Case(name)`, `else`; exhaustiveness enforced) and enums by value in parameters
and returns (two registers, nominal identity checked), `impl Name { fn
method(self: Name, ...) -> T }` for structs and enums with the receiver passed by
value as argument 1 (`value.method(args)`, chaining on call results, symbol
`Type_method`), `struct Name {
field: type, ... }`, literals `Name { field: value }` (every field, once each),
`p.field` access and `p.field = v` assignment on `var`, struct copy by value,
string literals, `str` variables (inferred or annotated) with copy and
assignment, `str` by value in parameters, arguments and returns (pointer+length
pair, two registers per `str`), builtin `print(s: str)` and `print_i32(n: i32)`
(text/decimals + line break), `fn`, `let`/`var` (mandatory initializer),
inference or annotation (`i32`/`bool`/`str`/`void`/struct), assignment only on
`var`, `return`, `if`/`else`/`else if`, `while`, blocks, arithmetic, comparisons,
`&&`/`||` with short-circuit, `-`/`!`, integer/boolean literals and calls to
functions of the program (≤ 6 argument registers, counting `str` as two).

Outside the subset: printing `bool`/interpolated `str`, enum **struct fields**,
payload types other than `i32`, operators on enums, `switch` over a constructed
value, associated functions without a receiver, receiver literal or field read
on a call result, references (`&self`), `unsafe`, attributes, struct with a struct field, empty struct, struct field of
type `str`, nested struct, comparison (`==`/`!=`), concatenation and formatting
of `str`, `main` returning `str`, signatures above 6 registers, `f32`/`f64`,
slices, pointers, generics, `Result`/`?`, closures, `for`, `pub`,
qualified/selective imports and packages.

### Validation executed in this cycle

- `zig build` — success (produces `zig-out/bin/kync`, version `0.3.11-alpha.1`).
- `zig build test` — **244 tests** in the compiler suite plus **7** from the
  experimental `std`, all passing. From this cycle: parser (impl block keeps its
  target and hands the methods to `program.functions`, only `fn` inside `impl`,
  unclosed `impl`), semantics (methods resolve through the receiver type and stay
  nominal, method arguments checked like a free call, declaration rules — duplicate
  method, field clash, wrong/missing/misnamed receiver, unknown target, method
  `main`, `Type_method` symbol collision —, unknown method and non-method
  receiver, receiver counted in the register limit) and both backends (mangled
  symbols, receiver as argument 1, aggregate round trip through a method, plus a
  regression test for an enum constructor returned from a function).
- `zig build e2e` — **121/121** cases: 31 behavioral fixtures, including
  `method_struct` (struct receiver, chained call, `str` return, method inside
  conditions and loops) and `method_enum` (enum receiver, `switch` on `self`,
  method returning an enum and chaining), 3 with `enum` + `switch`, 6 with
  `struct`, 4 with `print`, 4 with `print_i32`, 3 with `str` by value; 9 executed
  multi-file programs (`import_method` calls the methods of an imported type);
  50 `case_N.kyn`; 28 negatives (3 new: `method_unknown`, `method_receiver`,
  `method_duplicate`) and 3 negative modules.
- `zig fmt --check build.zig src std` — no differences.
- `docs/tutorial.md`: 24 `kyn` blocks extracted and passed through `kync check`;
  19 compile (the two new method blocks were also assembled, linked and executed:
  `7 / 27`, exit `34` and `5 / 7`, exit `6`), 1 is a library file without `main`,
  1 imports a neighboring module and 3 fail exactly with the documented error.
- IR: all 90 emitted modules verified against LLVM 22 through `llvmlite`
  (`parse_assembly` + `verify`) — this caught and fixed a regression where an
  enum **constructor** returned from a function was routed to the call path.
- `zig build validate-ir` without local LLVM — warns and exits 0 (documented
  skip); CI runs `validate-ir-strict` over the same 90 modules.
- Method note: test counts are only reliable with a clean cache
  (`rm -rf .zig-cache`), otherwise `zig build test` reports the step as "cached"
  and keeps the old number.

## 3. Recorded technical decisions

1. **Toolchain:** Zig 0.17.0 pinned in `build.zig.zon`; obtained from the PyPI
   `ziglang` wheel when no official installer is available.
2. **Token contract:** typed `Tag` + `Span` + slice into the input. Whitespace
   and comments never reach the parser. Isolated `&`/`|` are invalid.
3. **AST independent of semantics:** resolution is annotated by indices
   (`Expr.resolved`, `Stmt.decl_symbol`, `Assign.resolved`, `Call.callee_fn`);
   no type is stored in the AST.
4. **Accumulative diagnostics:** semantics collects errors and uses `unknown` to
   avoid cascades; the parser fails on the first syntax error.
5. **Ownership:** one arena per compilation (`driver.compile`) owns the AST, the
   symbol table, the diagnostics and the output; `Result.deinit()` releases it.
6. **Textual backends** behind a single interface (`codegen.generate`), selected
   by the `Backend` enum.
7. **x86-64 as the executable validation path:** no libc, `_start` calls
   `kyn_main` and ends through the `exit` syscall; 8-byte frame per slot; `bool`
   materialized as 32 bits (known difference from the IR, which uses i1).
8. **LLVM IR is validated by a tool in CI:** local tests check structure (every
   block ends with `ret`/`br`/`unreachable`); `llvm-as` (or `clang -x ir`)
   validates the modules for real. Without local LLVM the `validate-ir` step
   skips; CI uses `validate-ir-strict`, which fails. The `target triple` is fixed
   to `x86_64-unknown-linux-gnu`.
9. **Documented native backend limits:** ≤ 6 parameters/arguments (diagnosed by
   semantics), no external calls, no optimization.
10. **Modules without a runtime:** `import "path";` is resolved at compile time by
    `driver.compilePath`, relative to the importing file; the graph is walked in
    DFS pre-order, deduplicated by normalized path (`std.fs.path.resolveAlloc`,
    no syscalls) and flattened into a single `ast.Program` before semantics —
    which is why no backend changed. Cycles (`.import_cycle`), missing files
    (`.import_not_found`) and repeated symbols (`.duplicate_declaration`) are
    diagnosed. Visibility, qualified/selective imports and packages do not exist.
11. **Structs by value, no escape:** scalar fields only; a struct variable
    reserves `1 + n` slots (base + one per field). x86-64 uses `movl` at the
    offsets; LLVM uses scalar replacement (one `alloca` per field, no aggregate
    types nor `getelementptr`), which is semantically equivalent while the struct
    does not escape the function. Struct literals require every field, preventing
    partially initialized state. Structs are registered in two passes (names,
    then fields) to allow any declaration order.
12. **Diagnostic attribution per file:** every `ast.Function` carries a
    `file_id`, `Diagnostic.file` indexes `Result.sources` and the CLI prints the
    right `file:line:column` even for errors in imported modules.
13. **Versioning and publishing:** SemVer with an `alpha` pre-release;
    `build.zig.zon` is the single source and the version is bumped on every
    integrated cycle. A validated cycle (tests + e2e + strict IR green in the
    `main` CI) gets an **annotated tag `vX.Y.Z-alpha.N`** and a GitHub release —
    the first is `v0.3.7-alpha.1` (2026-11-07, commit `1c80a7b`); old CHANGELOG
    entries (up to `v2.3.0`) remain marked as unproven.
14. **CI:** GitHub Actions on `ubuntu-24.04`; the Zig toolchain comes from the
    official PyPI wheel (`ziglang==0.17.0.post0`) in a venv, the same path
    documented for local development — CI validates its own recipe. Actions are
    pinned by major version (`actions/checkout@v7`).
15. **Validation is never silent:** every optional validation step has a strict
    variant used in CI.
16. **`str` is a static slice (pointer + length), not a scalar:** the variable
    reserves two slots (`slot` = pointer, `slot + 1` = length), the same mapping
    in both backends; literals are deduplicated by content in `codegen.StrPool`
    (label `.LstrN`/constant `@.strN` per distinct text). In the native backend
    the text lives in `.rodata` as a `.byte` list (no escapes) and `print` uses
    the `write` syscall (text + `\n`), without libc; in the IR the text is
    `private unnamed_addr constant [N x i8]` and `print` calls libc's `write`
    (`declare i64 @write(i32, ptr, i64)`). `print` is a builtin
    (`ast.Expr.Call.builtin`), requires exactly one `str`, returns `void` and the
    name is reserved for declared functions. Comparing `str` by content,
    concatenating and passing `str` by value between functions remains diagnosed —
    pointers are never compared silently.
17. **Stdout checking in e2e:** `tools/e2e.sh` compares the `// expect-stdout:`
    lines (one per expected line, in order) in addition to `// expect-exit:`; the
    comparison uses `diff` against the binary's real output, so content is
    validated, not only the exit code.
18. **Builtins declared in the enum, generic checking:** `ast.Expr.Builtin` is
    the single source (`print`, `print_i32`); semantics resolves the name through
    `builtinByName`, requires arity 1 and the `builtinParamType` type, reserves
    the name for declared functions and never sets `callee_fn`. Adding a builtin
    therefore requires one enum entry and one arm in each backend — no parallel
    resolution path.
19. **`print_i32` formats without libc in the native backend and without
    aggregates in the IR:** the routine is emitted **once per program/module**
    (flag in `codegen.ProgramState`), in `.text` in the assembly — never inside
    `.rodata`, which already caused a segmentation fault during the cycle — and
    uses **unsigned** `divl` after `negl` to get `-2147483648` right; in the IR
    the equivalent is `@kyn_print_i32` with `urem`/`udiv`, a `select` for the
    modulo and a `[12 x i8]` buffer. No dependency on `itoa`, global state or
    dynamic allocation.
20. **`str` by value in calls (own ABI, cycle 8):** every `str` parameter,
    argument and return carries a **pointer + length** pair, always in that
    order. On x86-64 the pairs are `(%rdi,%rsi)`, `(%rdx,%rcx)` and `(%r8,%r9)`
    and the return comes in `%rax` (pointer) and `%rdx` (length); the prologue
    stores both registers into the variable's two slots. Calls with more than one
    argument push one word per register and pop in reverse order (evaluation
    order preserved); with a single argument the pass is direct, without touching
    the stack. In the IR the parameters become `ptr %argN` + `i64 %argN+1` and
    the return is the `{ ptr, i64 }` aggregate (`insertvalue` to build,
    `extractvalue` to read); `emitCall` rejects a `str` return and the caller
    uses `strOperand`/`emitStrCall`, so a truncated aggregate `call` is never
    emitted.
21. **The parameter limit is counted in register words:** `Type.registerWords()`
    returns 1 (scalars) or 2 (`str`) and `max_params` is applied over that sum,
    both at declaration and on every call. So three `str` fit, four do not, and
    the message quotes the total and the rule (`'str' takes two`) instead of an
    argument count — if the backend gains more registers the diagnostic follows
    on its own.
22. **Struct by value in calls (cycle 9):** one scalar field = one register
    word, in declaration order. x86-64: entry in `%rdi`, `%rsi`, …; calls push one
    word per field and pop in reverse order; return in `%eax`, `%edx`, `%ecx`,
    `%r8d`, `%r9d`, `%r10d`. Literal fields are evaluated on the stack before
    moving to the return registers (one field never clobbers another) and a
    struct returned by a call can be forwarded straight as an argument. IR:
    parameters **flattened** into scalars and only the return is the `{ … }`
    aggregate — keeps scalar replacement and avoids `getelementptr`. Nominal
    identity checked in arguments, returns and annotations
    (`param_struct_ids`/`return_struct_id`).
23. **The register limit is the single source of truth:** `sema.registerWordsOf`
    (1 per struct field, 2 per `str`, 1 per scalar) is used by the declaration,
    the call, the return and both backends. A struct return above 6 fields is
    diagnosed, and the consistency test in `x86_64.zig` ties the SysV table to the
    semantics limit.
24. **Methods (cycle 13):** `impl Name { fn m(self: Name, ...) }` for structs and
    enums. `Function.owner_type` marks a method; parse-time the method joins
    `Program.functions` (one list for the pipeline) and the `ImplBlock` keeps the
    target span. `FunctionInfo.owner_struct_id`/`owner_enum_id` give the nominal
    owner and `FunctionInfo.symbol_name` is the mangled `Type_method` used by both
    backends (`kyn_Point_sum`, `@Point_sum`). Name spaces never mix: free calls
    resolve through `findFunction` (methods skipped), `value.method(...)` through
    `findMethodIndex`, `main` only from a free function, and a free `fn Point_sum`
    collides with `Point.sum` by a diagnostic instead of two identical labels. The
    receiver is the first parameter (`self: Name`) and is **not** written at the
    call site: `codegen.Arguments` presents `receiver ++ args` to both backends, so
    marshalling (`str` pair, enum pair, struct per field, scalar) has a single
    implementation. No hidden parameter and no new ABI.
25. **`registerWordsOf` counts the receiver (cycle 13):** the six-register limit
    is applied to declaration and call site including `self`, with `str`/enum = 2
    and each struct field = 1; the messages name the method (`method 'Wide.pad'
    uses 7 parameter registers`). Diagnostic kind `invalid_method` covers missing,
    misnamed or wrongly typed receivers.
26. **The project language is English:** documentation, file names, comments,
    diagnostics/CLI messages, test names and fixture identifiers are all English.
    There is no mixed-language text left; assertions that compare message strings
    were migrated together with the messages, so a test can never pass by
    comparing a string that no longer exists.

## 4. Pending items (prioritized)

1. **Language:** no `unsafe`, attributes, numeric types beyond `i32`, slices or
   pointers; structs have no `str` field, no struct field and no empty form, and
   by-value passing is limited to 6 fields (above that the return is diagnosed) —
   `str` has no comparison, concatenation or formatting; output covers literal
   text and `i32` (no `bool` printing, no interpolated `str`). Methods exist but
   only with an explicit by-value `self`: no associated functions, no `&self`, no
   operator methods and no field read directly on a call result.
2. **Modules:** single flattened scope (function names must be unique in the
   program), no `pub`/visibility, qualified/selective imports, aliases, packages
   or manifest; deduplication is by normalized path (not inode/realpath), so
   symlinks can load the same file twice.
3. **Types:** no `i64`/`u32`/`f32`/`f64`, no complete flow checking (only
   structural `alwaysReturns`), no casts/conversions.
4. **Experimental std** with APIs that do no real I/O; `kyn:core` × `kyn:std`
   not yet separated into distinct build modules.
5. **Self-hosting:** `src/kyn/` and `src/compiler/` remain placeholders.
6. **Fixture runner** covers only success/generic negative; it does not check the
   expected message/position per file.
7. **Fuzz/edge cases** in `tests/fuzz/` are not executed by any runner.
8. **`tests/diagnostics/*.kyn`** are not checked by e2e (only
   `tests/e2e/negative`).
9. **Native backend** restricted to Linux x86-64, ≤ 6 argument registers (`str`
   counts two, struct field one), no libc and no optimization; structs larger
   than the register table are left for later (stack or `sret`); no regression
   tests with complete IR/asm (golden files).
10. **CI** runs only on `ubuntu-24.04` (no OS matrix, no build cache, no
    published artifacts); the IR `target triple` is fixed.
11. **Compiler test coverage** concentrated on examples; no coverage measurement
    and no stress tests with large inputs.

## 5. Next priority step

**Fixed-width integers and bitwise operators (`u8`/`i8`, `u16`/`i16`, `u32`,
`u64`, `usize`).**

- Why: it is step 1 of the freestanding order recorded in `docs/embedded.md` and
  the first item the embedded analysis blocks on: hardware registers need exact
  widths, defined overflow and bit manipulation, and every later step (pointers,
  `volatile`/MMIO, `repr(C)`) depends on them.
- Minimum scope:
  1. Lexer/parser: nothing new (type names are identifiers); AST unchanged.
  2. Semantics: `Type` gains the widths with `size`/`alignment`/`signed`
     properties; integer literals checked against the annotated type; explicit
     conversions `value as T` with documented truncation/sign extension
     (implicit widening only where lossless); bitwise `&`/`|`/`^`, `~` and shifts
     `<<`/`>>` with a defined shift-amount rule; arithmetic follows the operand
     type with wrap-around documented; `print`/`print_i32` extended (`print_u32`,
     `print_u8`, …) or a width-parameterized builtin decided in the cycle.
  3. Backends: operand widths per type in both backends (`movb`/`movw`/`movl`/
     `movq` and `i8`/`i16`/`i32`/`i64` in IR), register words extended so a `u64`
     takes two; the ABI table stays the single source.
  4. Tests: value-model tests per width (limits, wrap, sign), conversion matrix,
     shift-edge cases (amount ≥ width) and structural tests for the emitted
     widths; positive e2e with a checksum-style program and negatives for
     out-of-range literals and narrowing without `as`.
  5. Docs: `docs/syntax.ebnf`, `docs/language_reference.md`, `docs/tutorial.md`
     (§5 Types and a new section), `docs/architecture.md`, `docs/status.md`,
     `docs/embedded.md` (mark step 1 done), `README.md`, `ROADMAP.md`,
     `CHANGELOG.md` and this file; version `0.3.12-alpha.1`.
- Completion criteria: `zig build test`, `zig build e2e` and
  `validate-ir-strict` green in CI, with a program mixing at least three widths
  and an explicit conversion, and invalid narrowing rejected.

**After that (dependency order from `docs/embedded.md`):** pointers and real
`unsafe` blocks → `volatile`/MMIO → `repr(C)`/alignment → freestanding mode
(custom entry point, sections, linker script, ELF) → target abstraction in
`src/target/` → ARM Cortex-M4 (STM32F401RE) then RISC-V RV32 → split
`kyn:core`/`kyn:embedded`/`kyn:os`. Language-side items that stay on the list:
enum **struct fields**, `bool` printing and `str` concatenation, `error` unions
with `try`/`defer`, generics/`comptime`, C FFI, diagnostics with stable codes and
JSON/LSP, and self-hosting.

## 6. Cycle history

| Cycle | What was done | Validated? |
|---|---|---|
| Previous | Repository analysis; declared toolchain blocker (Zig 0.17.0 "unavailable") | No (no build/test) |
| Cycle 1 (2026-11-07) | Toolchain obtained from PyPI; `build.zig`+`.zon`; lexer/AST/parser/semantics rewritten with spans and diagnostics; LLVM IR and x86-64 backends; `kync` CLI; driver; 96 unit tests; e2e suite with 64 cases; documentation reconciled; old tests consolidated. Integrated through PR #7 (`5217796`). | Yes: `zig build`, `zig build test`, `zig build e2e`, `zig fmt --check`; retested after the merge |
| Cycle 2 (2026-11-07) | GitHub Actions CI (Python venv + PyPI wheel; LLVM installed on the runner); `tools/validate-ir.sh` validating the IR of 59 fixtures with `llvm-as` in strict mode; `zig build validate-ir` and `validate-ir-strict` steps; version `0.3.1-alpha.1`; docs updated with the run evidence. Integrated through PR #8 (`837d4ed`). | Yes: runs `42413779278`, `42414049577` and `42414408475` (main) green: fmt + 96 tests + 64 e2e + strict IR; local suite reproduced from scratch before and after the merge |
| Cycle 3 (2026-11-07) | Registration of the CI integration in the project state (`DEVELOPMENT_STATE.md`, README badge, CHANGELOG entries). Integrated through PR #9 (`449f78b`). | Yes: run `42414846887` (main) green |
| Cycle 4 (2026-11-07) | `import` and multi-file compilation: string lexer + `import`; parser with top-level `import`; `driver.compilePath` with pre-order DFS, dedupe by normalized path, `.import_cycle`/`.import_not_found`; `Diagnostic.file`/`addInFile` and messages citing the file; multi-file CLI; 21 new tests (115 total); 3 multi-file e2e fixtures executed + 3 negatives with the expected message; `validate-ir` covers 62 modules; version `0.3.2-alpha.1` (now derived from `build.zig.zon`). Integrated through PR #10 (`1c149dd`). | Yes: local (108 compiler tests, 70/70 e2e, `fmt --check`) and CI runs `42415765698` (PR) and `42415945385` (main), both green with strict IR; local suite retested on `main` after the merge |
| Cycle 5 (2026-11-07) | `struct` with value: lexer (`struct`, `.`), parser (declaration, literal, field access and assignment, unambiguous conditions), AST (`structs`, `field_access`, `struct_literal`, `field_assign`), semantics (`Type.aggregate`, `Checked.structs` in two passes, validated literals and diagnosed restrictions), `1 + n` slot layout with scalar replacement in LLVM, driver propagating structs across modules, 16 new tests (139 total), 3 struct e2e fixtures executed + 1 module + 3 negatives (77/77), `validate-ir` with 66 modules; version `0.3.3-alpha.1`. Integrated through PR #13 (`4234c07`). | Yes: local (132 compiler tests, 77/77 e2e, `fmt --check`) and CI runs `42417725687` (PR) and `42417878774` (main), both green with strict IR; local suite retested on `main` after the merge |
| Cycle 6 (2026-11-07) | `str` and `print`: string literal as an expression, `ast.Expr.Call.builtin`, `Type.str` in two slots (pointer + length), `codegen.StrPool` deduplicating literals, text in `.rodata` with the `write` syscall in the native backend and `@.strN` + `declare i64 @write` in the IR; builtin `print` (one `str`, `void` output, reserved name) and diagnosed restrictions (`str` parameter/return/field, arithmetic, condition, `==`/`!=`, loose literal); contract fix in `let`/`var` with `void`; `tools/e2e.sh` compares `// expect-stdout:`; 29 new tests (169 total), 4 fixtures with `print` + 1 module + 4 negatives (86/86), `validate-ir` with 71 modules; version `0.3.4-alpha.1`. Integrated through PR #15. | Yes: local (162 compiler tests, 86/86 e2e with stdout, `fmt --check`, binary output through `as`/`ld`) and CI of PR #15 (run `42420648098`) green with strict IR; local suite retested on `main` after the merge |
| Cycle 7 (2026-11-07) | `print_i32`: `ast.Expr.Builtin` with `print_i32` and generic builtin checking (arity, expected type and reserved name derived from the enum); `kyn_print_i32` routine emitted once per program in `.text` in the native backend (unsigned `divl`, 12-byte buffer, no libc) and `@kyn_print_i32` in the IR (`alloca [12 x i8]`, `phi`, `urem`/`udiv`, `select`, `zext`); 12 new tests (181 total), 4 new fixtures with checked stdout (including INT_MIN) + 2 negatives (92/92), `validate-ir` with 75 modules; version `0.3.5-alpha.1`. Integrated through PR #17 (`87903db`). | Yes: local (174 compiler tests, 92/92 e2e with stdout, `fmt --check`, execution through `as`/`ld`, IR checked) and CI runs `42423945656` (PR) and `42424147963` (`main`), both green with strict IR; local suite retested on `main` after the merge |
| Cycle 8 (2026-11-07) | `str` by value in parameters and returns: `Type.isValue()` includes `.str` and new `Type.registerWords()` (2 for `str`); 6-register limit per signature counted in words (`function '...' uses N parameter registers...` / `call to '...' uses N registers...`), replacing `max_params`; backends with their own ABI (`(%rdi,%rsi)`, `(%rdx,%rcx)`, `(%r8,%r9)` and return `%rax`/`%rdx` on x86-64; `ptr`+`i64` and `{ ptr, i64 }` with `insertvalue`/`extractvalue` in the IR), including a fast path for one argument and reverse popping for several; 12 new tests and 2 obsolete negatives replaced (193 total), 3 new fixtures with stdout + 1 imported module with `str` + 2 new negatives (97/97), `validate-ir` with 79 modules; version `0.3.6-alpha.1`. Integrated through PR #19 (`9ec07be`). | Yes: local (186 compiler tests, 97/97 e2e, `fmt --check`, `as`/`ld` execution of nested `echo`/`title`/`tag`, IR checked by hand) and CI runs `42425605484` (PR #19) and `42425757025` (`main`), both green with strict IR; local suite retested on `main` after the merge |
| Cycle 9 (2026-11-07) | Struct by value in parameters, arguments and returns: `FunctionInfo.param_struct_ids`/`return_struct_id` and `structIdOfExpr` recognizing calls (`let` inference preserves the struct), `sema.registerWordsOf` as the single source of the 6-register limit (field = 1, `str` = 2), nominal identity checked in argument/return/annotation and return limited to 6 fields; x86-64 with one register per field on entry, calls pushing field by field and return in `%eax`/`%edx`/`%ecx`/`%r8d`/`%r9d`/`%r10d` (fields evaluated on the stack so they do not clobber each other); IR with flattened parameters, `{ i32, i1, … }` aggregate return and `insertvalue`/`extractvalue`; 11 new tests (204 total), 3 new e2e fixtures + 1 module with struct by value + 2 negatives (102/102), `validate-ir` with 83 modules; **new `docs/tutorial.md`** with 20 verified blocks; tag `v0.3.7-alpha.1`; version `0.3.7-alpha.1`. Integrated through PR #23 (`1c80a7b`). | Yes: local (197 compiler tests, 102/102 e2e, `fmt --check`, `as`/`ld` execution of `origin`/`shift`/`echo`/`pair`, IR checked by hand, tutorial verified block by block) and CI runs `42427966554` (PR #23) and `42428126584` (`main`), both green with strict IR; local suite retested on `main` after the merge; tag `v0.3.7-alpha.1` published |
| Cycle 13 (2026-11-09) | `impl`/methods with an explicit by-value `self` for structs and enums: `kw_impl` token, `ast.ImplBlock` + `Function.owner_type` + `MethodCall.resolved_fn`, `Owner`, `FunctionInfo.symbol_name` (`Type_method`), `checkMethodDeclaration`/`checkMethodReceiver`, `invalid_method` kind, shared `checkSignature` between free and method calls, `codegen.Arguments` (receiver first) consumed by both backends, `emitCallWith`/`callRefOf` in x86-64 and LLVM, `switch` on `self`, chained calls on call results. 11 new tests (3 parser, 5 sema, 3 codegen), 2 new positives + 3 new negatives + 1 module fixture, `docs/embedded.md` added as the freestanding analysis, docs and version `0.3.11-alpha.1`. | Yes: local (244 + 7 tests, 121/121 e2e, 90/90 IR modules, `fmt --check`) |
| Cycle 12 (2026-11-08) | Enums **by value** across calls: `FunctionInfo.param_enum_ids`/`return_enum_id`, nominal identity in arguments/returns/annotations, `enumIdOfExpr` recognizing calls, the two `unsupported` diagnostics (enum in parameter/return) removed; x86-64 with a register pair per enum (tag, payload) in parameters/arguments and the return in `%eax`/`%edx` (`emitEnumValue` shared by store/return/arguments); LLVM IR with flattened `i32` pairs and the `{ i32, i32 }` aggregate (`insertvalue`/`extractvalue`, `emitEnumCall`/`enumOperand`). 5 new tests, 1 new positive and 2 new negatives in e2e (the old `enum_in_parameter` negative became the `enum_passing` positive), docs and version `0.3.10-alpha.1`. | Yes: local (233 tests, 115/115 e2e, 87/87 IR modules, `fmt --check`) |
| Cycle 11 (2026-11-07) | `enum` with optional `i32` payload and exhaustive `switch`: lexer (`enum`, `switch`, `=>`), AST (`EnumDecl`/`EnumCase`, `MethodCall`, `SwitchStmt`/`SwitchArm`), parser (`parseEnum`, `parseSwitch`, dotted call), semantics (`Type.enumeration`, two slots, nominality, exhaustiveness, payload binding rules, enum restrictions), both backends (tag/payload slots, `switch` as `cmp`/`je` chain and `switch i32`), driver flattening, 24 new unit tests, 2 positives, 1 module and 8 negatives in e2e, docs (including a new tutorial section) and version `0.3.9-alpha.1`. | Yes: local (228 tests, 113/113 e2e, `fmt --check`) |
| Cycle 10 (2026-11-07) | Project-wide English conversion: `src/**` (doc comments, messages, test names), `tools/*.sh`, `build.zig`, `.github/workflows/ci.yml`, `.kyn` fixtures (comments, identifiers and printed text) with renamed files and modules, `std/`, and every document (`README`, `ROADMAP`, `CHANGELOG`, `CONTRIBUTING`, `CODE_OF_CONDUCT`, `DEVELOPMENT_STATE`, `docs/*`); assertion strings migrated with the messages; version `0.3.8-alpha.1`. | Yes: local (204 tests, 102/102 e2e, `fmt --check`) before and after the conversion, with no test removed or loosened |

---

**Resumption rule:** reinstall the toolchain (§1), run `zig build test` and
`zig build e2e` (and `zig build validate-ir` when LLVM is available), check
`git status` and the latest CI on `main` (`gh run list --branch main`), and only
then move on to §5. Do not repeat already validated steps or assume results
without running the commands.
