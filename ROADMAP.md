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
- [ ] Complete parser and AST for the target language. Current subset: `fn`,
      `let`/`var`, assignment, `return`, `if`/`else`, `while`, blocks,
      expressions with precedence, `import`, `struct` and `str`, both by value
      across functions. Missing: `enum`, `impl`, `unsafe`, attributes, `str`
      comparison and concatenation, slices, pointers and generics.
- [ ] Complete semantic analysis and the type system beyond
      `i32`/`bool`/`void`/`str` (other integer widths, `f32`/`f64`, `str` with
      ownership/lifetimes, flow checking).
- [ ] Define and validate the official backend. The x86-64 backend is validated
      by execution; the LLVM backend IR is accepted by `llvm-as` in CI, but the
      choice of the official backend (and a configurable `target triple`)
      remains pending.

## Phase 2 — Language and runtime

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

## Phase 3 — Quality and portability

- [x] Add CI for build, tests and formatting: `.github/workflows/ci.yml` runs
      `zig fmt --check`, `zig build test`, `zig build e2e` and
      `zig build validate-ir-strict` (with LLVM installed on the runner).
- [ ] Cover diagnostics, malformed input and boundary cases systematically.
- [ ] Define targets and the supported platform matrix (the native backend is
      Linux x86-64).
- [ ] Create interoperability and regression tests.
- [ ] Document reproducible benchmarks, with no unverified claims.

## Phase 4 — Self-hosting and stability

- [ ] Implement the compiler in Kyn without placeholders.
- [ ] Demonstrate reproducible bootstrap using the previous compiler.
- [ ] Define the compatibility and language versioning policy (align
      `CHANGELOG.md` with what is implemented).
- [ ] Publish releases with artifacts, checksums and release notes.

## Completion criterion

A step must only be considered complete when the corresponding code exists, the
tests are executable and the documentation describes the observed behavior.
