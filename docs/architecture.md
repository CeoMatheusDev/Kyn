# Architecture

## Overview

The repository contains two related sets of code, at different stages:

1. **Zig bootstrap** (`src/`): a working compiler for a subset of the language,
   with an integrated frontend, two backends and a CLI.
2. **Kyn prototypes** (`src/kyn/`, `src/compiler/`): experimental files with
   placeholders, meant to explore implementing the compiler in the language
   itself. They are not executed by `kync`.

Having both sets does not mean a self-hosted pipeline exists.

## Implemented pipeline

```text
.kyn source code
      |
      v
   Lexer  (typed tokens + spans, no text copies)
      |
      v
   Parser (whole program; fails on the first syntax error)
      |
      v
   AST    (structs, functions, statements, expressions; slices into the input)
      |
      v
 Semantics (scopes, i32/bool/str/void/struct types, mutability, stack slots)
      |
      v
  Backend (single interface)
      |-- Textual LLVM IR   -> src/codegen/llvm.zig
      +-- x86-64 System V   -> src/codegen/x86_64.zig  (as + ld -> executable)
```

The driver (`src/driver.zig`) runs the pipeline and centralizes memory
ownership: one arena per compilation holds the AST, the symbol table, the
diagnostics and the backend output; `Result.deinit()` releases everything.

## Contracts between stages

- **Tokens**: typed `Tag`, `text` as a slice into the input and `Span`
  (start/end offsets, 1-based line and column). Whitespace and `// ...` never
  reach the parser; unknown characters become `.invalid` and are diagnosed.
- **AST**: independent of semantic decisions. Every node has a `span`;
  semantics annotates resolution indices (`Expr.resolved`, `Stmt.decl_symbol`,
  `Stmt.Assign.resolved`, `Expr.Call.callee_fn`) without changing the structure.
- **Semantics**: produces `Checked` with function signatures, return types,
  structs (fields and types), slot counts and a flat symbol table. Errors do not
  abort the analysis: they are accumulated and the `unknown` type stops
  diagnostic cascades. Structs are handled in two passes (names, then fields) so
  they can be referenced in any order.
- **Modules**: `driver.compilePath` loads the root file and resolves each
  `import` with `std.fs.path.resolveAlloc` starting from the importing file's
  directory; normalized paths act as the deduplication key. The graph is walked
  in pre-order (root first) and flattened into a single `ast.Program` — every
  `ast.Function` carries a `file_id` indexing `Result.sources`, so diagnostics
  point at the right file. Cycles, missing files and repeated names are
  diagnosed before the backend.
- **Backends**: receive `*ast.Program` + `*sema.Checked` and return
  arena-allocated text. `codegen.Error` distinguishes an inconsistent AST
  (`MiscompiledAst`), an unsupported subset (`UnsupportedNode`) and a type with
  no representation (`UnsupportedType`).

## Components

### Lexer — `src/lexer/lexer.zig`

Keywords, identifiers, decimal integers, one- and two-character operators and
punctuation. Keeps slices into the input; no allocation per token.

### Parser — `src/parser/parser.zig`

Builds the whole program with the precedence and associativity documented in
`docs/syntax.ebnf`. Syntax errors record a diagnostic with a span and return
`error.ParseError`.

### Module loader — `src/driver.zig`

`compilePath` keeps the DFS stack (cycle detection), the set of already loaded
paths and the module list in load order. Each module is lexed and parsed with
the right `current_file` in diagnostics; if any file fails, the compilation
stops with the diagnostics already assigned. There is no global state: all
memory comes from the `Result` arena.

### Structs (layout) — `src/sema/sema.zig` + backends

A struct value is **nominal** (`Symbol.struct_id` → `Checked.structs`) and can
cross calls **by value** (Cycle 9): one scalar field = one register word, in
declaration order.

- `Symbol.typ == .aggregate` reserves `1 + n` slots: the first is the base
  (reserved) and each field uses `slot + 1 + index`, in declaration order.
- x86-64: every slot has 8 bytes; field read/write is `movl` at the slot offset,
  and struct copy walks the fields. Parameters arrive in one register per field
  (`%rdi`, `%rsi`, …), calls push one word per field and pop in reverse order,
  and the **return** uses `%eax`, `%edx`, `%ecx`, `%r8d`, `%r9d`, `%r10d`
  (limit of 6 fields). Literal fields are evaluated on the stack before moving
  to the return registers, so one field cannot clobber another's result.
- LLVM IR: scalar replacement for storage (one `alloca` per field) and
  parameters **flattened** into scalar arguments (`define i32 @f(i32 %arg0,
  i32 %arg1)` for `fn f(p: P)`); only the return is an aggregate (`{ i32, i1, … }`
  built with `insertvalue` and read with `extractvalue`). No `getelementptr` is
  needed.
- `sema.registerWordsOf` is the single source for the **6-register** limit: it
  counts 1 per struct field, 2 per `str`, 2 per enum and 1 per scalar; it applies
  to declaration, call, struct return and enum return.
- Literals require every field exactly once, which guarantees structs are
  always initialized (no partially built state).

### Strings and text output (`str`) — `print` + backends

`str` is a **static slice**: pointer to constant bytes + length. It is not a
scalar; it exists to give programs observable output (text) and to prepare
`kyn:core` for real I/O.

- `Symbol.typ == .str` reserves two consecutive slots: `slot` holds the pointer
  and `slot + 1` the length (the same convention in both backends).
- **`str` by value in calls** (Cycle 8): parameters, arguments and returns carry
  two registers, always pointer before length. On x86-64 the pairs are
  `(%rdi,%rsi)`, `(%rdx,%rcx)` and `(%r8,%r9)`; the return comes in `%rax`
  (pointer) and `%rdx` (length). In the IR the parameters become `ptr %argN` +
  `i64 %argN+1` and the return is the `{ ptr, i64 }` aggregate built with
  `insertvalue` and read with `extractvalue`. The six-register limit is counted
  in **register words** (`Type.registerWords()`): each `str` takes two, allowing
  at most three `str` per signature.
- String literals are deduplicated by content (`codegen.StrPool`): each distinct
  text becomes a single label, with any number of references.
- x86-64: bytes in `.section .rodata` as a `.byte` list (no escapes); `print`
  does `write(1, ptr, len)` through a syscall plus a second call for the line
  break (`.Lnl`). No libc dependency.
- LLVM IR: each text becomes `@.strN = private unnamed_addr constant [N x i8]`,
  `print` becomes `call i64 @write(i32 1, ptr @.strN, i64 N)` with
  `declare i64 @write(i32, ptr, i64)`; the LLVM verifier in CI accepts the IR.
- `print` and `print_i32` are builtins (`ast.Expr.Call.builtin`) with the same
  rule: exactly one argument (`str`/`i32`), `void` result and a line break at
  the end. The names are reserved for functions declared in the source, and a
  `let`/`var` with their result is diagnosed (`void` is not storable).
- `print_i32` formats in decimal: in the native backend the `kyn_print_i32`
  routine (emitted once, in `.text`) divides by 10 with **unsigned** `divl` —
  after `negl`, INT_MIN becomes `0x80000000` and the text comes out
  `-2147483648`; in the IR, `@kyn_print_i32` does the same with `urem`/`udiv`,
  a `select` for the modulo and a `[12 x i8]` buffer written back to front.
  Neither uses `itoa`/libc in the native backend, nor global state.
- Restrictions at this stage, all diagnosed: struct field of type `str`, `str`
  in arithmetic/condition/`==`/`!=` (comparing would require comparing bytes),
  `main` returning `str`, `str` expression as a statement and signatures above
  six registers (`'str' takes two`).

### Enums (layout) — `src/sema/sema.zig` + backends

An enum value is **nominal** (`Symbol.enum_id` → `Checked.enums`) and crosses
calls **by value** (Cycle 12), like a two-field record: the **tag** (the case
index in declaration order) plus one **payload** word.

- `Symbol.typ == .enumeration` reserves two consecutive slots: `slot` holds the
  tag and `slot + 1` the payload (the payload slot stays unused when no case
  declares one). `sema.registerWordsOf` counts **2** for an enum, so an enum
  parameter consumes two of the six argument registers.
- The only consumer of a value is `switch`: the scrutinee must be a variable, the
  arms compare the tag and the payload is copied into the binding slot at the
  start of the arm.
- x86-64: parameters arrive as a register **pair** (tag then payload) stored with
  two `movl`; arguments push two words in the same order; the return leaves the
  tag in `%eax` and the payload in `%edx` — the same pair as a two-field struct
  return, so a call can be forwarded straight to another call or returned.
- LLVM IR: two `alloca i32` (tag + payload) for storage, parameters **flattened**
  into `i32 %argN, i32 %argN+1`, and the return as the `{ i32, i32 }` aggregate
  built with `insertvalue` / read with `extractvalue`.
- Restrictions at this stage, all diagnosed: struct field of type enum (the
  struct layout would need a second slot per field), payload types other than
  `i32`, any operator on an enum value and `switch` over a constructed value.

### Semantics — `src/sema/sema.zig`

- two passes: signatures first (allows recursion and calls before the
  declaration), then bodies;
- nested scopes with shadowing allowed and duplicates diagnosed in the same
  scope;
- types `i32`, `bool`, `str`, `void` and nominal structs; operators checked by
  category;
- assignment requires `var`;
- structural return check (`alwaysReturns`) for non-void functions;
- `fn main()` validation (no parameters, `i32` or `void` return);
- the native backend's 6-parameter/argument limit is diagnosed.

### Backends — `src/codegen/`

- `llvm.zig`: textual IR with simple SSA, basic blocks, `phi` for `&&`/`||`,
  `alloca` for variables. Without an LLVM tool in the local environment
  validation is structural (every block ends with `ret`/`br`/`unreachable`) and
  CI runs `llvm-as` over every fixture (`tools/validate-ir.sh`).
- `x86_64.zig`: System V assembly without libc. `_start` calls `kyn_main` and
  exits through the `exit` syscall. Variables in 8-byte frame slots, expressions
  in `%eax` with a temporary stack, calls with arguments in
  `%edi/%esi/%edx/%ecx/%r8d/%r9d`. This is the path validated by execution.

### Standard library — `std/`

`kyn:core` (OS-independent) and `kyn:std` (OS-dependent) remain experimental.
They compile and have tests, but most APIs do no real I/O.

## Engineering guidelines

- Keep slices and references into the input whenever the lifetime allows it.
- Make the origin and duration of allocators explicit (one arena per
  compilation).
- Separate platform-independent interfaces from OS-specific ones.
- Keep language fixtures separate from the bootstrap unit tests.
- Do not promise determinism, memory safety or ABI compatibility without
  verifiable tests and contracts.

## Next architectural decisions

1. Choose the long-term official backend (LLVM IR validated by a tool or an
   own native backend) and define acceptance criteria for it.
2. Widen the module contract (visibility, qualified imports, packages); today
   resolution is by relative path and symbols are flattened.
3. Define the struct-by-value convention for **aggregates larger** than the
   register table (today limited to 6 fields) — stack passing or `sret` — before
   `impl`/methods with a large `self`.
4. Add the still-missing AST nodes (`enum`, `impl`, `unsafe`, attributes) and
   wire `src/sema/unsafe.zig`.
5. Define the executable memory model (ownership, lifetimes, slices) before
   expanding the std.
6. Define `str` comparison by content and concatenation/formatting (today
   diagnosed); `str` by value in parameters and returns was decided in Cycle 8
   (pointer+length pair, see above).
