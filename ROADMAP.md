# Roadmap

This roadmap represents the proposed sequence of work. The items are not
release promises and must only be marked as done when there is integrated
implementation and reproducible tests.

## Phase 1 — Zig bootstrap

- [x] Create the initial structure of lexer, parser, AST, semantics and codegen.
- [x] Define a reproducible build with `build.zig` (Zig 0.17.0, `zig build test`,
      `zig build e2e`).
- [x] Implement a working CLI and document its arguments (`kync check`,
      `kync emit`, `--llvm`/`--asm`, `-o`, `--lib`; codes 0/1/2/3).
- [x] Integrate the end-to-end compilation pipeline for the current subset
      (lexer → parser → AST → semantics → backend), with executable validation
      through `as`/`ld`.
- [x] Multi-file compilation with `import "path";` (resolution relative to the
      importing file, deduplication, diagnosed cycles/missing files/duplicated
      symbols) and executed e2e fixtures.
- [x] `struct` with scalar fields: declaration, literals, field access and
      assignment, copy by value, layout documented in both backends.
- [x] `struct` by value in parameters, arguments and returns: one register per
      field, aggregate return in the IR and a six-register limit shared with
      `str` (nominal identity enforced).
- [x] Text output: `str` as a static slice (pointer + length), deduplicated
      literals, `print(...)` builtin in the native backend (`write` syscall) and
      in LLVM IR (libc `write`), with stdout checked by the e2e suite
      (`// expect-stdout:`).
- [x] Value output: `print_i32(...)` builtin, with its own decimal conversion in
      each backend (unsigned `divl` in the native one, `urem`/`udiv` in the IR),
      covering zero, negatives and the `i32` limits; stdout checked in e2e.
- [x] `str` by value in parameters and returns: documented own ABI (pointer +
      length in register pairs, return in `%rax`/`%rdx`; `ptr`+`i64` and
      `{ ptr, i64 }` in the IR), six-register limit counting `str` as two, e2e
      with helpers receiving and returning text.
- [x] `enum` with optional `i32` payload and exhaustive `switch` (`Case`,
      `Case(name)` and `else` arms, tags in declaration order, tag + payload
      slots in both backends, missing/redundant cases diagnosed).
- [x] Enums **by value** across calls: parameters and returns carry the pair
      (tag, payload) in two registers, with nominal identity enforced in
      arguments, returns and annotations; an enum parameter counts two of the
      six argument registers.
- [x] `impl`/methods: `impl Name { fn method(self: Name, ...) }` for structs and
      enums, receiver passed by value as argument 1, `Type_method` mangling,
      per-type name spaces, nominal receiver rules and a shared argument checker
      for free and method calls.
- [x] Add fixed-width signed/unsigned integer types, `usize`, explicit casts,
      bitwise operators and shifts; validate the currently tested operations
      in both backends. Full native arithmetic at every declared width remains
      open below (the LLVM representation is not a native parity guarantee).
- [x] Add typed pointers, address-of, dereference, pointer field access,
      pointer arithmetic and pointer equality/inequality for the current target.
      Generic pointer parameters/struct fields now preserve full addresses, but
      the language still lacks bounds, lifetime and pointer-safety contracts.
- [ ] Close remaining native integer-width/overflow and ABI gaps before making
      cross-backend parity claims: an `i64` overflow-boundary probe currently
      differs between native assembly and LLVM (see `docs/status.md`). Add
      executable regressions as these paths become correct.
- [ ] Complete the language beyond the implemented subset: slices, arrays,
      nested aggregates, enum struct fields, richer payloads, `unsafe`,
      attributes, generics and a formal ownership/lifetime model.
- [ ] Extend semantic analysis with floating-point types, richer flow
      analysis, ownership/lifetime checking and a complete error model.
- [ ] Define and validate the official backend. The x86-64 backend is validated
      by execution; earlier LLVM IR passed `llvm-as` in CI, but the current
      changes still need a green strict verifier run. The choice of the
      official backend and a configurable `target triple` remain pending.

## Phase 2 — Freestanding and embedded targets

Dependency order and rationale in `docs/embedded.md`. Fixed-width integers,
bitwise operations and basic typed pointers are already implemented; this phase
covers the additional target and memory contracts required for firmware.

- [ ] Define pointer safety, nullability, aliasing and lifetime rules; add
      const-qualified pointers and real `unsafe` blocks only after the rules
      are specified and tested.
- [ ] `volatile` loads/stores preserved by both backends, plus MMIO/register
      abstractions in a future `kyn:embedded` package.
- [ ] Layout control: `#[repr(C)]`, explicit alignment and compile-time
      size/offset assertions.
- [ ] Freestanding mode: configurable entry point, `.data`/`.bss`
      initialization, section control, linker script input and ELF output.
- [ ] Target abstraction (`src/target/`): data layout and ABI out of the
      x86-64 backend, selected by the CLI instead of hard-coded.
- [ ] First embedded target: ARM Cortex-M4 (STM32F401RE) with startup code,
      vector table, linker script and a blink without runtime; then RISC-V
      RV32 to prove the abstraction.
- [ ] Split the standard library into `kyn:core` (target independent),
      `kyn:embedded` and `kyn:os`, replacing the documented stubs with real
      implementations.

## Phase 3 — Language and runtime

- [ ] Formalize syntax and semantics (make `syntax.ebnf` normative for the
      target language, today limited to the implemented subset).
- [ ] Specify ownership, lifetimes and `unsafe` operations; connect
      `src/sema/unsafe.zig` to real AST nodes.
- [ ] Define allocator contracts and allocation failures.
- [ ] Stabilize FFI and layout compatible with C.
- [ ] Separate and validate the `kyn:core` and `kyn:std` APIs (today
      experimental stubs; several APIs do no real I/O).
- [x] Create a test runner for `.kyn` fixtures of the supported subset
      (`tools/e2e.sh` + `zig build e2e`, with `// expect-exit: N` and
      `// expect-stdout:`).
- [ ] Extend the runner to diagnostic fixtures (expected message/position per
      file) instead of only exit code and stdout.

## Phase 4 — Quality and portability

- [x] Add CI for build, tests and formatting: `.github/workflows/ci.yml` runs
      `zig fmt --check`, `zig build test`, `zig build e2e` and
      `zig build validate-ir-strict` (with LLVM installed on the runner).
- [x] Repair strict-IR fixture parity for casts, bitwise, pointers and string
      equality, including cross-backend pointer arithmetic and the native
      slice-comparison stack order; add positive and negative regressions.
      Locally: Zig 0.17.0 unit/E2E, LLVM 20 verification and JIT execution;
      this is not evidence of green CI until the PR checks complete.
- [ ] Run strict `llvm-as` and the complete CI on the integration PR and on
      `main`; do not merge target foundations while a required check is red.
- [ ] Cover diagnostics, malformed input and boundary cases systematically.
- [ ] Define targets and the supported platform matrix (the native backend is
      Linux x86-64).
- [ ] Create interoperability and regression tests.
- [ ] Document reproducible benchmarks, with no unverified claims.

## Phase 5 — Self-hosting and stability

- [ ] Implement the compiler in Kyn without placeholders.
- [ ] Demonstrate reproducible bootstrap using the previous compiler.
- [ ] Define the compatibility and language versioning policy (align
      `CHANGELOG.md` with what is implemented).
- [ ] Publish releases with artifacts, checksums and release notes.

## Completion criterion

A step must only be considered complete when the corresponding code exists, the
tests are executable and the documentation describes the observed behavior.
