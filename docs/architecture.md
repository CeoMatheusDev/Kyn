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
 Semantics (scopes, fixed-width integers, bool/str/void, structs/enums/pointers, mutability, stack slots)
      |
      v
  Backend (single interface)
      |-- Textual LLVM IR   -> src/codegen/llvm.zig
      +-- Linux x86-64/Kyn ABI -> src/codegen/x86_64.zig (as + ld -> executable)
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
- x86-64: every slot has 8 bytes; field access/copy uses `movq` for 64-bit
  integers and pointers, `movl` for smaller scalars. Parameters arrive in one
  register per field (`%rdi`, `%rsi`, …), calls push one word per field and pop
  in reverse order; the **return** uses `%rax`, `%rdx`, `%rcx`, `%r8`, `%r9`,
  `%r10` (or their 32-bit names for narrow fields; limit of 6 fields). Literal
  fields are evaluated on the stack before moving to the return registers, so
  one field cannot clobber another's result.
- LLVM IR: one `[n+1 x i64]` stack object per struct; the base address points
  at the reserved last word and field `i` is at `-8*(i+1)` (inbounds GEP). This
  keeps `&struct_var` and `(*ptr).field` stable and matches the native frame;
  typed field loads/stores still use their actual width. By-value parameters
  remain **flattened** into scalar arguments (`define i32 @f(i32 %arg0,
  i32 %arg1)` for `fn f(p: P)`); the return remains an aggregate (`{ i32, i1, … }`
  built with `insertvalue` and read with `extractvalue`). LLVM may scalarize
  non-escaping stack objects during optimization. This is NOT a C ABI layout.
- `sema.registerWordsOf` is the single source for the **6-register** parameter
  limit in declarations and calls: 1 per struct field or pointer, 2 per `str`
  or enum, and 2 per `i64`/`u64`/`usize`. Struct returns separately limit fields
  to six; enum returns use the tag/payload pair.
- Literals require every field exactly once, which guarantees structs are
  always initialized (no partially built state).

### Integer widths and Kyn's internal calling convention

- Each scalar occupies one eight-byte local slot. The native emitter keeps
  values up to 32 bits in `%eax`, normalizing 8-/16-bit results to their signed
  or unsigned range after operations/casts. `i64`, `u64` and `usize` use 64-bit
  loads, stores and ALU operations in `%rax`. Their return value is in `%rax`.
- Each wide **scalar parameter** occupies two consecutive argument registers:
  low 32 bits then high 32 bits (e.g. `%edi`, `%esi` for argument 1). The
  callee joins the halves before storing the value. A pointer or a wide struct
  **field** instead occupies one full 64-bit register. These are Kyn-internal
  rules using System V register names, **not** a C ABI or a promise of FFI.
- LLVM IR has typed scalar `i64` parameters/results, rather than the native
  pair-of-register representation. The semantic six-word budget is enforced
  for both emitters, but their machine-level ABIs are not interchangeable.
  `str` remains a pair of full 64-bit pointer/length values in native calls.
- Shifts reduce the integer count modulo the left operand's 8/16/32/64-bit
  width, including negative counts (low two's-complement bits). LLVM converts
  independently typed counts to the left width, then masks by `width - 1`
  **before** emitting `shl`/`ashr`/`lshr` so no out-of-range count becomes
  poison. Native x86-64 implicitly masks 32-/64-bit counts; 8-/16-bit Kyn
  shifts use the 32-bit ALU and explicitly mask `%ecx` by 7/15. Valid counts
  require no additional native instructions on 32-/64-bit values.
- Source-level integer `/` and `%` trap on divisor zero and signed MIN / -1,
  for both quotient and remainder. The native backend uses width-matched
  `divb/w/l/q` or `idivb/w/l/q`, relying on hardware #DE without inserting
  branches on valid operations; narrow results are then normalized to Kyn's
  existing representation. LLVM guards the operands before the division or
  remainder, branching to a single cold `llvm.trap` block per function; its
  `sdiv`/`srem`/`udiv`/`urem` never consumes an invalid pair on a continuing
  path. Pointer-distance division uses a nonzero positive stride and the
  internal decimal printer divides by 10; neither is a source-level `/` or `%`.
  The exact process signal is outside the language contract, and no external
  C runtime is introduced for arithmetic.

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
  `declare i64 @write(i32, ptr, i64)`; this form is LLVM-verifier compatible.
  Strict `llvm-as` CI also passed on PR #38 and its `main` merge commit.
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

### Methods (`impl`) — `src/sema/sema.zig` + backends

A method is a `Function` whose `owner_type` is the `impl` target; parsing appends
it to `Program.functions` (one list for the pipeline) and keeps the `ImplBlock`
for the target span. Semantics resolves the owner to a nominal index
(`FunctionInfo.owner_struct_id` / `owner_enum_id`) and computes
`FunctionInfo.symbol_name`:

- **Mangling:** `Type_method` (`Point_sum`). Deterministic, unique per type
  (type names are unique) and checked against free functions: `fn Point_sum()`
  becomes the diagnostic *"shares the symbol 'kyn_Point_sum'"* instead of two
  identical labels.
- **Name spaces:** free calls resolve through `findFunction` (methods skipped),
  method calls through `findMethod`/`Expr.MethodCall.resolved_fn` keyed by the
  nominal receiver type; `main` is only ever satisfied by a free function.
- **Receiver:** the first parameter must be `self: Name` with the owner type. At
  the call site `value.method(args)` the receiver is passed as **argument 1**;
  `codegen.Arguments` gives both backends one view of the argument list
  (`receiver ++ args`), so marshalling — `str` pair, enum pair, struct per field,
  scalar — is written once and shared by free and method calls.
- x86-64 pushes the receiver fields first and pops in reverse, which lands them
  in `%edi`, `%esi`, … exactly like a free call; LLVM IR flattens the receiver
  into `%arg0..` of the definition. No new ABI and no hidden parameter.
- The receiver counts in the six-register limit (`registerWordsOf`), so a large
  `self` plus many arguments is diagnosed at declaration *and* at the call site.

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
- fixed-width signed/unsigned integers, 64-bit unsigned `usize`, `bool`, `str`, `void`, nominal
  structs/enums and inferred pointer types; operators and casts are checked by
  type category and integer width;
- assignment requires `var`;
- structural return check (`alwaysReturns`) for non-void functions;
- `fn main()` validation (no parameters, `i32` or `void` return);
- the native backend's 6-parameter/argument limit is diagnosed.

### Backends — `src/codegen/`

- `llvm.zig`: textual IR for integers/casts, enums, strings, calls and control
  flow, plus opaque `ptr` values, address-of, scalar dereference and struct
  field reads through a pointer. It uses SSA, `phi` for `&&`/`||` and `alloca`
  for locals. Signedness affects division, ordering and right shifts. LLVM
  converts independently typed shift counts to the left operand's width and
  masks by `width - 1` before shifting; the x86-64 backend applies the same
  rule to narrow operands (wide counts are masked by the hardware).
  `tools/validate-ir.sh` runs an LLVM verifier in CI; the accepted fixtures
  were also checked with LLVM 20 via `llvmlite` locally.
- Both backends use `codegen.pointeeStride` for the current x86-64 scalar/frame
  layout. `ptr<T> +/- i32` scales a signed offset, and compatible pointer
  subtraction divides the full 64-bit address difference before returning i32.
  The checker rejects unknown pointees, incompatible subtraction and invalid
  lvalues (`&42`, `&str`). A known initializer preserves its inferred `T` for
  local `ptr` annotations; generic parameters and struct fields erase it, but
  unknown-to-known assignment is rejected. The native backend transports
  pointer arguments and struct fields in full 64-bit registers/slots. No
  bounds, lifetime or C-layout guarantee is provided.
- `x86_64.zig`: Linux assembly without libc. `_start` calls `kyn_main` and
  exits through the `exit` syscall. Variables use 8-byte frame slots;
  expressions use `%eax` or `%rax`, saving intermediates on the stack. Calls
  use Kyn's layout in `%rdi/%rsi/%rdx/%rcx/%r8/%r9` (with 32-bit halves for
  wide scalar parameters). This is the path validated by execution.

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
   register table (today limited to 6 fields, receiver included) — stack passing
   or `sret` — which also lifts the "large `self`" limitation of methods.
4. Add the still-missing AST nodes for `unsafe` and attributes, and wire
   `src/sema/unsafe.zig`; extract data layout and calling convention into an
   explicit target description (see `docs/embedded.md` §3).
5. Define the executable memory model (ownership, lifetimes, slices) before
   expanding the std.
6. Define `str` comparison by content and concatenation/formatting (today
   diagnosed); `str` by value in parameters and returns was decided in Cycle 8
   (pointer+length pair, see above).
