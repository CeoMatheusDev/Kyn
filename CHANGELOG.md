# Changelog — Kyn

Rules: Semantic Versioning 2.0.0. Pre-1.0.0 = pre-release.

## [v0.3.12-alpha.1] — 2026-11-08

Repository maintenance and documentation consistency.

- **Repository conventions:** added `.editorconfig`, normalized text attributes,
  expanded generated-artifact exclusions and documented directory ownership.
- **Documentation:** rewrote the project overview, added a maintainer guide,
  refreshed the tutorial, reconciled the roadmap and embedded-target analysis
  with implemented integer and pointer features, and retired the stale
  cycle-specific development log in favor of canonical status documents.
- **VS Code extension:** corrected punctuation tokenization in the TextMate
  grammar; the extension remains declarative and does not yet include an LSP.
- **Build metadata:** standardized the build runner description. No compiler
  semantics or generated-code behavior changed in this maintenance cycle.

> **Traceability warning:** the entries below `v0.3.0-alpha.1` record milestones
> intended in earlier cycles of the project and do **not** constitute evidence of
> implementation. Several of them describe features the code does not have (for
> example self-hosting, a "stable industrial release", `Result<T, E>` and module
> organization). The real state, verified by build and tests, is in
> [docs/status.md](docs/status.md). Versioning will be reconciled before any
> public release.

## [v0.3.11-alpha.1] — 2026-11-09

Methods (`impl`) for structs and enums, plus the freestanding/embedded analysis.

- **Language:** `impl Name { fn method(self: Name, ...) -> T { ... } }` for a
  declared struct or enum. The receiver is the first parameter, explicit and by
  value (`self: Name`); `value.method(args)` passes it as **argument 1** and the
  written arguments are parameters 2..n. Methods live in a name space per type:
  a method never answers a bare call, cannot reuse a field name, must be unique
  per type and `main` stays a free function. An `impl` for an undeclared type is
  diagnosed, and a free `fn Type_method` collides with `Type.method` by a
  diagnostic instead of two identical symbols.
- **Backends:** the symbol is `Type_method` (`kyn_Point_sum`, `@Point_sum`). New
  `codegen.Arguments` (`receiver ++ args`) gives both backends one view of the
  argument list, so `emitCallWith`/`callRefOf` in x86-64 and
  `emitArgs`/`emit*Call` in the IR reuse the existing marshalling (`str` pair,
  enum pair, struct per field, scalar). No hidden parameter, no new ABI; the
  receiver counts in the six-register limit.
- **Composition:** methods chain on call results (`p.moved(1, 1).sum()`,
  `shape.grow(2).weight()`), work as arguments, and `switch` accepts `self`
  inside a method of an enum.
- **Semantics shared code:** the argument checking of free and method calls is a
  single `checkSignature` (arity, nominal identity of struct/enum arguments,
  register limit), and receiver problems use the new `invalid_method` kind.
- **Tests:** **244** compiler tests + 7 std. New: parser (impl target and method
  order, only `fn` inside `impl`, unclosed `impl`), semantics (resolution and
  nominal identity, arguments checked like a free call, declaration rules,
  unknown method/non-method receiver, receiver in the register limit) and codegen
  (mangled symbols and receiver placement in both backends) — 11 in total.
  **121/121** e2e cases: new positives `method_struct` and `method_enum`, new
  negatives `method_unknown`, `method_receiver`, `method_duplicate`, and the
  module fixture `import_method` calling methods of an imported type.
- **IR evidence:** 90/90 modules accepted by the LLVM verifier (`llvm-as` in CI).
  The verification caught a regression where an enum **constructor** returned
  from a function was routed through the call path (fixed and covered by a test);
  the test helper now recognizes `switch` as a block terminator.
- **Docs:** new `docs/embedded.md` — readiness, blockers and dependency order for
  freestanding and embedded targets (explicitly *not implemented*), which becomes
  Phase 2 of `ROADMAP.md`; `docs/tutorial.md` gained §12 (methods, two executed
  examples) and was renumbered; `docs/architecture.md`, `docs/syntax.ebnf`,
  `docs/grammar.ebnf`, `docs/language_reference.md`, `docs/language_design.md`,
  `docs/status.md`, `README.md`, `docs/development.md`, `ROADMAP.md` and
  `DEVELOPMENT_STATE.md` updated.
- **Version:** `0.3.11-alpha.1` (derived from `build.zig.zon`), published as the
  annotated tag `v0.3.11-alpha.1` with a GitHub release.
- **Integration:** PR #30 merged into `main` as `fcf49f1`; CI green in runs
  `42441709768` (PR) and `42441832907` (`main`), with `zig fmt --check`, 244 + 7
  tests, 121 e2e cases and `validate-ir-strict` over 90 modules.

## [v0.3.10-alpha.1] — 2026-11-08

Enums cross calls by value, with nominal identity enforced.

- **Semantics:** `FunctionInfo` carries `param_enum_ids` and `return_enum_id`;
  the two "enum in parameters/returns is not supported" diagnostics are gone;
  a different enum in an argument, in a `return` or in an annotated `let` is
  rejected (`argument 1 of 'paint' is enum 'B', expected 'A'`,
  `expected enum 'A' in return, found 'B'`) and `enumIdOfExpr` recognizes calls
  that return an enum, so `let c = pick(1);` infers the enum. An enum parameter
  counts **two** of the six argument registers (`registerWordsOf`), and the
  limit messages mention it. A struct **field** of enum type remains diagnosed.
- **x86-64:** new `emitEnumValue` (tag in `%eax`, payload in `%edx`) shared by
  `let`/assignment stores, `return`, argument passing and the single-argument
  fast path; enum parameters arrive as a register pair and calls push two words
  per enum (`pushq` tag, `pushq` payload) with the reverse pop restoring order.
  The payload is evaluated before the tag is written, so an expression using
  `%edx` (`idivl`) cannot clobber the pair.
- **LLVM IR:** an enum parameter becomes `i32 %argN, i32 %argN+1`, the return is
  the `{ i32, i32 }` aggregate built with `insertvalue`, and a call returning an
  enum is destructured with `extractvalue` (new `emitEnumCall` and
  `enumOperand`), including forwarding a returned enum straight as an argument
  or as the value of another `return`.
- **Tests:** **233** (226 compiler + 7 std): 5 new — enums crossing calls with
  `param_enum_ids`/`return_enum_id` and inferred `let`, identity errors in
  argument/return/annotation, the two-register limit, and structural tests for
  both backends (register pair, tags in `%eax`/`%edx`, `{ i32, i32 }`,
  `extractvalue`). **115/115** e2e cases: the `enum_in_parameter` negative
  became the `enum_passing` positive (enum built, passed, returned and consumed
  by `switch`, with stdout checked) and two negatives were added
  (`enum_nominal`, `enum_registers`). The `enum_switch`/`enum_switch_else`
  fixtures keep covering the in-function representation.
- **IR evidence:** 87/87 modules accepted by the LLVM verifier (LLVM 22 through
  `llvmlite` locally, `llvm-as` in CI).
- **Docs:** `docs/architecture.md` gained the enum layout/call contract,
  `docs/tutorial.md` §11 documents enums by value with a new verified example,
  plus `docs/syntax.ebnf`, `docs/language_reference.md` (§ 7), `docs/status.md`,
  `README.md`, `docs/development.md`, `ROADMAP.md` and `DEVELOPMENT_STATE.md`.
- **Version:** `0.3.10-alpha.1` (derived from `build.zig.zon`), published as the
  annotated tag `v0.3.10-alpha.1` with a GitHub release.
- **Integration:** PR #28 merged into `main` as `9b989ad`; CI green in runs
  `42436782775`/`42436791204` (push and PR) and `42437018292` (`main`), with
  `zig fmt --check`, 233 tests, 115 e2e cases and `validate-ir-strict` over 87
  modules.

## [v0.3.9-alpha.1] — 2026-11-07

Enums with payload and exhaustive `switch`, in both backends.

- **Lexer:** `enum` and `switch` are keywords and `=>` (fat arrow) is a single
  token, distinct from `=` and `>`; `describe` reports it and `isKeyword`
  classifies both keywords.
- **AST:** `Program.enums`; `EnumDecl`/`EnumCase` (optional `payload` type name,
  `file_id`, `span`); `Expr.Kind.method_call` (`MethodCall` with `base`, `name`,
  `args`, `resolved_enum`, `resolved_case`) for constructors; `FieldAccess`
  gained `resolved_enum`/`resolved_case` for `Color.Red`; `Stmt.Kind.switch_stmt`
  (`SwitchStmt` with `scrutinee`, `arms`, `else_body`, `else_span`,
  `resolved_enum`) and `SwitchArm` (`case_name`, optional `binding`, `body`,
  `resolved_case`, `binding_symbol`).
- **Parser:** `enum Name { Case, Case(i32), }` (trailing comma optional, stray
  separators ignored), `switch` arms `Case => { }`, `Case(name) => { }` and
  `else => { }` (a duplicate `else` is a syntax error), and dotted calls in
  `parseFieldChain`, so `Shape.Circle(5)` becomes a `method_call`. The top-level
  message now lists `enum`.
- **Semantics:** `Type.enumeration`; a value is **two slots** (tag = declaration
  order, plus a payload slot), `registerWords` = 2; `CaseInfo`/`EnumInfo` and
  `Checked.enums`/`findEnum`; enums are nominal in annotations and assignments
  (`is enum 'B', but the annotation is 'A'`); `switch` requires an enum
  *variable*, rejects unknown and duplicated cases, enforces the payload binding
  (`Circle` without binding, `Empty(x)` with binding), reports the missing cases
  in `'switch' on 'Color' is not exhaustive: missing 'Green', 'Blue'` and the
  redundant `else` in `'else' arm is unreachable`. Enums in parameters, returns
  and struct fields, payload types other than `i32`, operators on enum values
  and method calls other than constructors are diagnosed with dedicated
  messages.
- **x86-64:** enums in two consecutive slots; `let`/assignment store the tag
  literal (or evaluate the payload first), a copy moves both slots, and `switch`
  becomes a `cmpl`/`je` chain over the tag, copying the payload into the binding
  slot at the arm start.
- **LLVM IR:** enums as two `alloca i32`; `switch` lowers to `switch i32` with
  one block per arm and the `else` block (or the end block) as default; the
  payload is copied into the binding `alloca` at the arm start.
- **Driver:** `enum` declarations of every module are flattened into
  `Program.enums`; `file_id` is assigned by the loader.
- **Tests:** **228** (`221` compiler + `7` std), including lexer, parser, sema
  (12 new cases) and structural tests in both backends. **113/113** e2e cases
  with 2 new positives (`enum_switch`, `enum_switch_else`), 1 module
  (`import_enum`) and 8 new negatives
  (`enum_non_exhaustive`, `enum_unknown_case`, `enum_else_unreachable`,
  `enum_payload_missing`, `enum_payload_binding`, `enum_in_parameter`,
  `enum_in_field`, `enum_operator`).
- **IR evidence:** the 86 modules emitted by `validate-ir` (28 positive, 50
  integration, 8 module programs) are accepted by the LLVM verifier — LLVM 22
  locally through `llvmlite` (`parse_assembly` + `verify`) and `llvm-as` in CI.
- **Docs:** `docs/syntax.ebnf` and `docs/grammar.ebnf` describe `enum`, `switch`
  and `=>`; `docs/tutorial.md` gained section 11 ("Enums and `switch`", 19
  sections and 21 verified blocks, the new one executed through `as`/`ld`);
  `docs/language_reference.md` (§ 7) documents the implemented enum,
  `docs/status.md`, `docs/language_design.md`, `ROADMAP.md` and
  `DEVELOPMENT_STATE.md` updated. Residual Portuguese strings in compiler
  headers/messages and in the e2e report were also translated.
- **Version:** `0.3.9-alpha.1` (derived from `build.zig.zon`), published as the
  annotated tag `v0.3.9-alpha.1` with a GitHub release.
- **Integration:** PR #26 merged into `main` as `9125bff`; CI green in runs
  `42433210990`/`42433201467` (PR and push) and `42433391665` (`main`), with
  `zig fmt --check`, 228 tests, 113 e2e cases and `validate-ir-strict` over 86
  modules.

## [v0.3.8-alpha.1] — 2026-11-07

Project-wide English conversion: documentation, comments, compiler/CLI messages,
test names and fixtures.

- **Compiler messages:** all diagnostics, CLI help/errors and render prefixes are
  now English (`error:`/`warning:`, `file:line:column: error: message`). The
  affected assertions in `src/diagnostics.zig`, `src/driver.zig`, `src/sema/`,
  `src/parser/` and `src/codegen/` were updated together, so no test compares a
  string that no longer exists.
- **Identifiers in fixtures:** the `.kyn` fixtures and the inline test programs
  use English identifiers (`sum`, `greeting`, `point`, `counter`, `value`,
  `code`, …) and English printed text (`hello,`, `sum`, `end`, `module`), with
  the `// expect-stdout:` directives updated to match.
- **Fixture names:** `struct_passagem` → `struct_passing`, `struct_retorno` →
  `struct_return`, `struct_campos_tipos` → `struct_field_types`, `str_passagem` →
  `str_passing`, `str_retorno` → `str_return`, `str_retorno_ramo` →
  `str_return_branch`, `str_registradores` → `str_registers`,
  `struct_registradores` → `struct_registers`, `print_misto` → `print_mixed`,
  `print_int_extremos` → `print_int_extremes`; imported modules also use English
  file names (`point.kyn`, `text.kyn`, `output.kyn`, `one.kyn`, `two.kyn`,
  `three.kyn`, `missing.kyn`).
- **Docs:** `README.md`, `ROADMAP.md`, `CHANGELOG.md`, `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`, `DEVELOPMENT_STATE.md` and every file in `docs/`
  (`architecture`, `status`, `development`, `spec`, `language_design`,
  `language_reference`, `memory_model`, `tutorial`, `grammar.ebnf`,
  `syntax.ebnf`) are written in English; the project no longer mixes languages.
- **Evidence:** `zig build test` (204 tests), `zig build e2e` (102/102) and
  `zig fmt --check build.zig src std` green before and after the conversion; the
  suite was not weakened (no test removed, no assertion loosened).
- **Version:** `0.3.8-alpha.1` (derived from `build.zig.zon`).

## [v0.3.7-alpha.1] — 2026-11-07

Struct by value: structs cross calls in parameters, arguments and returns, with
nominal identity verified.

- **Semantics:** the "struct by value not supported" diagnostics (parameter,
  return and argument) are gone; `FunctionInfo` now carries `param_struct_ids`
  and `return_struct_id`, and `structIdOfExpr` recognizes calls that return a
  struct — including `let b = origin();` (inference preserves the struct).
  Different structs with the same shape are rejected in arguments, returns and
  annotations (`is struct 'B', expected 'A'`). The register limit became
  `sema.registerWordsOf` (struct field = 1, `str` = 2, scalar = 1), the single
  source for declaration, call and return; a struct return above 6 fields is
  diagnosed.
- **x86-64:** one register per field on entry (`%rdi`, `%rsi`, …), calls push one
  word per field and pop in reverse order, and the return uses
  `%eax`/`%edx`/`%ecx`/`%r8d`/`%r9d`/`%r10d`. Literal fields are evaluated on
  the stack before moving to the return registers, so one field never clobbers
  another's result; a struct returned by a call can be passed straight as an
  argument to another.
- **LLVM IR:** parameters flattened into scalar arguments (`define i32
  @sum(i32 %arg0, i32 %arg1)`), storage through scalar replacement (one `alloca`
  per field) and aggregate return `{ i32, i1, … }` with
  `insertvalue`/`extractvalue`; `return f()` returns the call's aggregate
  directly, without rebuilding it.
- **Tests:** 197 compiler tests (+11) and 7 std tests — **204 in total**; the old
  negative that required "struct by value not supported" became a positive of the
  new contract. 3 new e2e fixtures (`struct_passing`, `struct_return`,
  `struct_field_types`), 1 module with struct by value (`import_struct_abi`) and
  2 new negatives (`struct_nominal`, `struct_registers`) — **102/102 cases**;
  `validate-ir` covers **83 modules**.
- **Docs:** new [docs/tutorial.md](docs/tutorial.md) (complete language guide with
  examples verified by the compiler), plus `docs/architecture.md` (struct call
  contract), `docs/language_reference.md`, `docs/syntax.ebnf`, `docs/status.md`,
  `docs/development.md`, `README.md`, `ROADMAP.md` and `DEVELOPMENT_STATE.md`.
- **Version:** `0.3.7-alpha.1` (derived from `build.zig.zon`), published as the
  annotated tag `v0.3.7-alpha.1` with a GitHub release — the project's first tag
  and the milestone of the SemVer policy: every validated cycle (tests + e2e +
  strict IR green in the `main` CI) gets a `vX.Y.Z-alpha.N` tag.
- **Integration:** PR #23 merged into `main` as `1c80a7b`; CI green in runs
  `42427966554` (PR) and `42428126584` (`main`), with `zig fmt --check`, 204
  tests, 102 e2e cases and `validate-ir-strict` over 83 modules.

## [v0.3.6-alpha.1] — 2026-11-07

`str` by value: text crosses function calls in parameters and returns.

- **Semantics:** `str` is no longer restricted to local variables —
  `Type.isValue()` includes `.str`, so `str` parameters and returns are accepted
  like any scalar. The old `max_params` (now `max_arg_registers`) was replaced by
  a count in **register words** (`Type.registerWords()`: 1 per scalar, 2 per
  `str`), applied at declaration and on every call, with diagnostics that quote
  the total and the rule (`'str' takes two`). Still diagnosed: struct field of
  type `str`, `str` in arithmetic/condition/`==`/`!=`, `main` returning `str` and
  an unused `str` expression (message now generic, not only for literals).
- **x86-64 backend:** documented own ABI — every `str` parameter/argument takes
  two consecutive registers (pointer, length) in SysV order (`(%rdi,%rsi)`,
  `(%rdx,%rcx)`, `(%r8,%r9)`), and the return comes in `%rax` (pointer) + `%rdx`
  (length). The prologue stores both registers into the symbol's two slots; calls
  with more than one argument push one word per register and pop in reverse
  order, and the single-argument case goes straight to the register (no stack
  traffic). `emitStrValue` centralizes literal/identifier/call returning `str`,
  reused by `print`, assignment and `return`.
- **LLVM IR backend:** signatures expand each `str` into `ptr %argN` +
  `i64 %argN+1`; the return is the `{ ptr, i64 }` aggregate built with
  `insertvalue` and read with `extractvalue` (`StrOperand`/`strOperand` decides
  between literal, `load` and `extractvalue`). `emitCall` rejects a `str` return
  instead of emitting a truncated `call`.
- **Tests:** 186 compiler tests (12 new) + 7 std — **193 in total**; the 2 old
  negatives that required "`str` in parameter/return not supported" were replaced
  by tests of the new contract. 3 new e2e fixtures with checked stdout
  (`str_passing`, `str_return`, `str_return_branch`), 1 imported module with
  `str` (`import_str`) and 2 new negatives (`str_registers`, `str_return_main`,
  replacing `str_param_unsupported`) — **97/97 cases**; `validate-ir` now covers
  **79 modules**.
- **Docs:** `docs/architecture.md` (calling convention and remaining
  restrictions), `docs/syntax.ebnf`, `docs/language_reference.md`,
  `docs/status.md`, `README.md` and `DEVELOPMENT_STATE.md`.
- **Version:** `0.3.6-alpha.1` (derived from `build.zig.zon`).

## [v0.3.5-alpha.1] — 2026-11-07

Value output: builtin `print_i32(n: i32)` with its own decimal formatting.

- **AST/Semantics:** `ast.Expr.Builtin` gained `print_i32` and builtin call
  checking became generic (arity 1 + expected type per builtin, reserved name
  derived from the enum) — `print` and `print_i32` follow the same rule, and the
  `void` result remains non-storable in `let`/`var`.
- **x86-64 backend:** `kyn_print_i32` routine emitted **once** per program, in
  `.text`, with unsigned `divl` and a 12-byte buffer on the stack (no libc and no
  global state); `print_i32` just passes the value in `%edi` and calls the
  routine, which writes the digits and the line break through the `write`
  syscall. `-2147483648` comes out correct (after `negl`, INT_MIN becomes
  `0x80000000` and the unsigned division produces the 10 digits).
- **LLVM IR backend:** internal function `@kyn_print_i32` emitted once per module
  (`alloca [12 x i8]`, loop with `phi`, `urem`/`udiv`, `select` for the modulo,
  `zext` to `i64`) and two calls to libc `write`.
- **Tests:** 174 compiler tests (12 new: parser, semantics of both builtins, the
  decimal routine in both backends and its absence when unused) and 7 std tests;
  4 new e2e fixtures with `print_i32`/mixed and 2 negatives — **92/92 cases**,
  with stdout checked line by line (including INT_MIN).
- **Docs:** `docs/syntax.ebnf` (`builtin_call` production), `docs/architecture.md`
  (decimal routine in both backends), `docs/status.md`, `docs/development.md`,
  `docs/language_reference.md`, `README.md`, `ROADMAP.md` and
  `DEVELOPMENT_STATE.md` updated.
- **Version:** `0.3.5-alpha.1` (derived from `build.zig.zon`).
- **Integration:** PR #17 merged into `main` as `87903db`; CI green in runs
  `42423945656` (PR) and `42424147963` (`main`), with `zig fmt --check`, tests,
  e2e (stdout checked) and `validate-ir-strict` over 75 modules.

## [v0.3.4-alpha.1] — 2026-11-07

Text output: `str` as a static slice and the `print(...)` builtin.

- **AST:** `Expr.Kind.str_literal` (bytes without quotes) and `Expr.Call.builtin`
  (`print`), letting semantics mark builtin calls without confusing them with
  functions declared in the source.
- **Parser:** the string literal becomes an expression (including as a call
  argument); an unterminated string becomes a `.syntax` diagnostic with the
  position.
- **Semantics:** new `Type.str` (not a scalar) with **two slots** (pointer and
  length, the same convention in both backends) and the `print` builtin: exactly
  one `str` argument, `void` result, name reserved for declared functions. New
  diagnostics: `str` in arithmetic/condition, `str` `==`/`!=` comparison (without
  silently comparing pointers), loose literal as a statement, `str` in
  parameter/return/argument and a struct field of type `str`.
- **x86-64 backend:** literals deduplicated in `.section .rodata` as `.byte`
  lists (no escapes), assignment/copy in two `movq` and `print` through the
  `write` syscall (text + line break), without libc.
- **LLVM IR backend:** `@.strN = private unnamed_addr constant [N x i8]`,
  `declare i64 @write(i32, ptr, i64)` and `print` as two calls to `write`; `str`
  uses two `alloca`s (`ptr` + `i64`). IR accepted by `llvm-as` in CI.
- **String pool:** `codegen.StrPool` deduplicates by content, so each distinct
  text becomes a single label/constant regardless of references.
- **Semantics (contract fix):** `let`/`var` with a `void` initializer (for
  example `let x = print("a");` or `let x = f();` with a void `f`) is now
  diagnosed as a **single** error; before, `let x = f();` passed semantics and
  reached the backend with a type that had no representation.
- **Tests:** 162 compiler tests (29 new: parser, semantics, both backends and the
  pool) and 7 std tests; 4 new e2e fixtures with `print` (stdout checked), 1
  imported module with `print` and 4 negative fixtures — **86/86 cases**, with
  `tools/e2e.sh` now comparing `// expect-stdout:` in addition to
  `// expect-exit:`.
- **Docs:** `docs/syntax.ebnf`, `docs/grammar.ebnf`, `docs/architecture.md`
  (`str` representation and text output), `docs/status.md`,
  `docs/development.md`, `docs/language_reference.md`, `README.md`,
  `ROADMAP.md` and `DEVELOPMENT_STATE.md` updated.
- **Version:** `0.3.4-alpha.1` (derived from `build.zig.zon`).
- **Integration:** PR #15 merged into `main` as `89ca6ce`; CI green in runs
  `42420648098` (PR) and `42421025867` (`main`), with `zig fmt --check`, tests,
  e2e (stdout checked) and `validate-ir-strict` over 71 modules.

## [v0.3.3-alpha.1] — 2026-11-07

Structs with value: declaration, literals, fields and layout in both backends.

- **Lexer:** `struct` keyword and `.` punctuation (dot, used in `p.field`).
- **Parser:** `struct Name { field: type, ... }` at top level (free order relative
  to `fn`, optional trailing comma, errors with span); literals
  `Name { field: value }`; `p.field` access chainable in the grammar; new
  assignment `p.field = value`. `if`/`while` conditions disable the struct
  literal, because `Name {` there starts the block.
- **AST:** `Program.structs`, `ast.StructDecl`/`ast.Field`,
  `Expr.field_access`, `Expr.struct_literal`/`FieldInit` and `Stmt.field_assign`,
  with indices resolved by semantics.
- **Semantics:** `Type.aggregate` + `Checked.structs` (two passes: names, then
  fields), field resolution, literal validation (every field, once each),
  immutable assignment, incompatible types and different structs in the
  annotation. Diagnosed restrictions: struct by value in
  parameter/return/argument, field of struct type, empty struct, struct in
  condition/comparison and literal as a loose expression.
- **Layout:** a struct variable reserves `1 + n` slots (base + one per field).
  x86-64 uses `movl` at the slot offsets; the LLVM backend applies scalar
  replacement (one `alloca` per field, no aggregate types). A struct never
  escapes the function at this stage, so there is no partial copy and no
  uninitialized state.
- **Driver:** structs from imported modules enter the flattened program in
  pre-order, with a `file_id` for correct diagnostic attribution.
- **Tests:** 132 compiler tests (16 new: lexer, parser, semantics, multi-file
  driver and IR/assembly structure) and 7 std tests; 3 new e2e fixtures with
  `struct` executed (exits 14, 10 and 21), 1 module with struct (exit 42) and 3
  negative struct fixtures — 77/77 cases.
- **Docs:** `docs/syntax.ebnf` and `docs/grammar.ebnf` describe `struct`,
  literals and field access; `docs/architecture.md` documents the layout;
  `docs/status.md`, `docs/development.md`, `docs/language_reference.md`,
  `README.md`, `ROADMAP.md` and `DEVELOPMENT_STATE.md` updated.
- **Version:** `0.3.3-alpha.1` (derived from `build.zig.zon`).
- **Integration:** PR #13 merged into `main` as `4234c07`; CI green in runs
  `42417725687` (PR) and `42417878774` (`main`), including
  `zig build validate-ir-strict` with 66 modules accepted by `llvm-as`.

## [v0.3.2-alpha.1] — 2026-11-07

Modules: `import` with relative paths and multi-file compilation.

- **Lexer:** string literals between double quotes (`"..."`, no escapes and no
  line break), with the `.string` token keeping the contents and
  `.string_unterminated` for open literals; new `import` keyword.
- **Parser:** `import "path";` at top level, before the functions. The path must
  be a string literal; `import` after a function, a path without quotes and a
  missing `;` produce a syntax diagnostic with a span.
- **Driver:** new `compilePath(gpa, io, dir, path, options)`, which loads the root
  file and resolves `import` recursively relative to the importing file's
  directory (`std.fs.path.resolveAlloc`, no syscalls). Each path is normalized
  and loaded once (diamond imports do not duplicate symbols); cycles produce
  `.import_cycle`, missing files `.import_not_found` and repeated symbols across
  files `.duplicate_declaration`. Modules are flattened into a single
  `ast.Program` in pre-order (root first), before semantics, so the existing
  backends did not change. `compile` remains available for a single buffer and
  diagnoses `import` as unresolved.
- **Diagnostics:** `Diagnostic.file` + `List.addInFile`; the CLI prints
  `file:line:column` of the right file, including errors inside imported modules.
  `renderDiagnostics` now receives the list of sources.
- **CLI:** `kync check/emit <file.kyn>` compiles the file and its imports; a root
  file read error still exits with code 3, while a missing import is a
  compilation error (code 1).
- **Tests:** 108 compiler tests (21 new: string lexer, `import` parser and
  multi-file loading with diamond, cycle, missing file, duplicated symbol and
  file attribution in diagnostics); 3 positive multi-file e2e fixtures actually
  executed and 3 negatives with the expected message. `tools/e2e.sh` and
  `tools/validate-ir.sh` gained the module sections (70 e2e cases, 62 IR
  modules).
- **Docs:** `docs/syntax.ebnf` and `docs/grammar.ebnf` describe `import` and the
  string literal; `docs/status.md`, `docs/development.md`,
  `docs/architecture.md`, `README.md`, `ROADMAP.md` and `DEVELOPMENT_STATE.md`
  updated with the verified state.
- **Build:** `kyn.version` now comes from `build.zig.zon` through build options
  (no more duplicated version in `src/root.zig`).
- **Integration:** PR #10 merged into `main` as `1c149dd`; CI green in runs
  `42415765698` (PR) and `42415945385` (`main`), including
  `zig build validate-ir-strict` with 62 modules accepted by `llvm-as`.

## [v0.3.1-alpha.1] — 2026-11-07

Continuous integration and LLVM IR backend validation by a real tool.

- **CI:** added `.github/workflows/ci.yml` (ubuntu-24.04) that installs Zig
  0.17.0 from the official PyPI wheel, installs LLVM and runs
  `zig fmt --check`, `zig build test`, `zig build e2e` and
  `zig build validate-ir-strict`. Green runs: `42413779278` (first) and
  `42414049577` (with strict validation and `actions/checkout@v7`).
- **IR validation:** new `tools/validate-ir.sh`, which runs `llvm-as` (PATH,
  version suffix or `/usr/lib/llvm-*/bin`) or `clang -x ir` over the IR of every
  supported fixture (59 modules). Without LLVM the lenient variant warns; the
  `--require-tool` variant (used in CI) fails, preventing validation from being
  silently skipped.
- **Build:** new `zig build validate-ir` and `zig build validate-ir-strict`
  steps.
- **Documentation:** `docs/development.md` describes the validation suite, the CI
  workflow and how to reproduce it locally; `README.md` gains a CI badge;
  `docs/status.md` and `ROADMAP.md` updated with the evidence obtained.

## [v0.3.0-alpha.1] — 2026-11-07

Integration cycle of the frontend with executable validation.

- **Build:** added `build.zig` and `build.zig.zon` (Zig 0.17.0 as the minimum
  version). `zig build`, `zig build test` and `zig build e2e` work.
- **Toolchain:** unblocked validation with real Zig 0.17.0 (official binary
  obtained through the PyPI package `ziglang` 0.17.0.post0).
- **Lexer:** token contract rewritten with a typed `Tag`, keywords,
  two-character operators and `Span` (offset, 1-based line and column); comments
  and whitespace discarded; an invalid character becomes a diagnosed token.
- **AST:** new model with functions, parameters, `let`/`var`, assignment,
  `return`, `if`/`else`, `while`, blocks and expressions; resolution annotations
  filled in by semantics.
- **Parser:** builds the whole program, with precedence/associativity documented
  in `docs/syntax.ebnf`; errors with span and message.
- **Semantics:** nested scopes, name resolution, types `i32`/`bool`/`void`,
  mutability, call checking, `main` validation, structural return check and stack
  slot assignment.
- **Diagnostics:** dedicated module with stable category, message, line and a `^`
  marker.
- **Backends:** interface in `src/codegen/codegen.zig` with two emitters derived
  from the AST — textual LLVM IR and x86-64 System V assembly without libc.
- **`kync` CLI:** `check` and `emit` (`--llvm`, `--asm`, `-o`, `--lib`) with exit
  codes 0/1/2/3 plus help/version.
- **Tests:** 96 unit tests (89 compiler + 7 experimental std); 64 end-to-end
  cases (9 behavioral fixtures executed, 50 `tests/integration/case_N.kyn`
  fixtures checked by exit code and 5 negative fixtures). Old tests in
  `src/test_*.zig` were consolidated into `src/tests.zig` and `std/tests.zig`
  (the old `src/test_core.zig` imported a file that does not exist).
- **Documentation:** `README.md`, `docs/status.md`, `docs/architecture.md`,
  `docs/development.md`, `docs/grammar.ebnf`, `docs/syntax.ebnf` and `ROADMAP.md`
  reconciled with the observed behavior.

## [v2.3.0] — 2026-11-01
- Milestone 3.10: Stable Industrial Release launch. Final freeze of the self-hosted `kync` compiler, complete documentation, packaging of the final binary.

## [v2.2.0-rc.1] — 2026-11-01
- Milestone 3.9: 50+ end-to-end integration files (`tests/integration/case_*.kyn`).

## [v2.1.0-beta.1] — 2026-11-01
- Milestone 3.8: native Result<T, E> (`src/compiler/result.kyn`, `tests/result_basic.kyn`).

## [v2.0.0-beta.1] — 2026-11-01
- Milestone 3.7: lock-free RingBuffer (`std/core/ringbuffer.kyn`, `tests/ringbuffer_basic.kyn`).

## [v1.9.0] — 2026-11-01
- Milestone 3.6: atomic primitives (`std/core/atomics.kyn`, `tests/atomics_basic.kyn`).

## [v1.8.0] — 2026-11-01
- Milestone 3.5: native C FFI support (`src/compiler/ffi.kyn`, `tests/ffi_basic.kyn`).

## [v1.7.0] — 2026-11-01
- Milestone 3.4: register optimizations in codegen (`src/compiler/regopt.kyn`, `tests/regopt_basic.kyn`).

## [v1.6.0] — 2026-11-01
- Milestone 3.3: strict mutability checking (`src/compiler/mutability.kyn`, `tests/mutability_basic.kyn`).

## [v1.5.0] — 2026-11-01
- Milestone 3.2: native ArenaAllocator (`std/core/arena.kyn`, `tests/arena_basic.kyn`).

## [v1.4.0] — 2026-11-01
- Milestone 3.1: Module & Import system (`src/compiler/modules.kyn`, `tests/modules/basic.kyn`).

## [v1.2.0] — 2026-11-01
- Fuzz testing: `tests/fuzz/fuzzer.kyn`, `tests/fuzz/harness.kyn`, `tests/fuzz/edge_cases.kyn`.
- Crash-proof guarantee (no panic/segfault) for malformed input.

## [v1.1.0] — 2026-11-01
- Diagnostics: `src/compiler/span.kyn`, `src/compiler/diagnostics.kyn` (Rust/Zig-style error messages).
- Tests: `tests/diagnostics/invalid_type.kyn`, `tests/diagnostics/invalid_syntax.kyn`.

## [v1.0.0] — 2026-11-01
- Milestone 3.1/3.2: Self-hosting — compiler rewritten in Kyn (`src/compiler/`), tests `tests/self_host_test.sh`.
- Official stable language, ready for production.

## [v0.9.0-rc.1] — 2026-11-01
- Milestone 2.4: Bootstrap compiler release candidate. Test coverage > 90%, pipeline optimizations, frozen specifications.
- Professional README with badges, SemVer roadmap and architecture.

## [v0.8.0-beta.2] — 2026-11-01
- Milestone 2.3: `std/os/` (I/O, threads, networking), `src/ffi/ffi.zig` (C FFI), `tests/std_basic.kyn`, `src/test_std.zig`.
- Expansion of the ability to interact with the OS and external ecosystems.

## [v0.6.0-beta.1] — 2026-11-01
- Milestone 2.2: `src/sema/unsafe.zig` (`unsafe` block and `#[repr(C)]` checking), `tests/unsafe_basic.kyn`, `src/test_unsafe.zig`.
- Alpha → beta transition: safety enforcement and memory layout.

## [v0.5.0-alpha.1] — 2026-11-01
- Milestone 2.1: `std/core/core.zig` (unsafe, @align, explicit allocators), `tests/core_basic.kyn`, `src/test_core.zig`.
- `kyn:core` (bare-metal) separation started.

## [v0.4.0-alpha.1] — 2026-11-01
- Milestone 1.4: `src/codegen/codegen.zig` (basic LLVM IR emission), tests `tests/codegen_basic.kyn` + `src/test_codegen.zig`.
- Full bootstrap compiler cycle: Lexer → Parser → AST → Sema → CodeGen.

## [v0.3.0-alpha.1] — 2026-11-01
- Milestone 1.3: `src/sema/sema.zig` (basic typechecker, `let` scope, initial `Result<i32, E>`), tests `tests/sema_basic.kyn`.
- `lexer` → `parser` → `ast` → `sema` integration.

## [v0.2.0-alpha.1] — 2026-11-01
- Milestone 1.2: Parser (`src/parser/parser.zig`), AST (`src/ast/ast.zig`), `.kyn` tests (`tests/parser_basic.kyn`).
- `lexer` → `parser` → `ast` separation respected.
- Syntax errors reported through `!AST.Error`.

## [v0.1.0-alpha.1] — 2026-11-01
- Milestone 1.1: repository structure, `kync` CLI, basic lexer, Zig + `.kyn` tests.
- Strict dependency: Zig 0.17.0.
- Target emission: direct LLVM IR (Phase 1.4).
