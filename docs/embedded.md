# Kyn for embedded and freestanding targets

**Status of this document:** technical analysis and implementation order, not a
description of implemented features. Nothing here is a release promise; every
item is only done when the code exists, the tests run and `docs/status.md`
describes the observed behavior. The compiler today produces **Linux x86-64
programs**; it cannot compile or run firmware.

This document exists so the next big architectural milestone is written down
before any of it is built, and so the smaller cycles in between keep moving in
that direction instead of away from it.

---

## 1. What already supports the embedded direction

Verified facts, with the validation that backs each one (see
`docs/status.md` for the full table):

| Capability | State | Evidence |
| --- | --- | --- |
| Lexer → parser → AST → semantics → backend pipeline | Implemented | 246 compiler unit tests + 7 std tests |
| Native backend without libc (`_start`, `write`/`exit` syscalls, System V) | Implemented, executed | `as` + `ld` + exit code and stdout checked by 31 e2e fixtures |
| Textual LLVM IR backend (official target, configurable in principle) | Implemented for the current subset | 90/90 modules accepted by the LLVM verifier (`llvm-as` in CI) |
| Multi-file programs (`import "path.kyn";`) | Implemented | 9 executed module fixtures, 3 negative ones |
| Nominal `struct`/`enum` with documented layout and call ABI | Implemented (tag/payload pair, one register per field) | Structural tests in both backends + executed fixtures |
| `impl`/methods, by value, no hidden parameter | Implemented | 130 e2e cases, mangled `Type_method` symbols |
| Explicit register limit (6 words) instead of a silent ABI | Enforced with diagnostics | Declaration and call-site tests |
| Arena allocation for compiler-owned data, no global state | Implemented | Architecture notes in `docs/architecture.md` |

None of this is accidental: the pipeline already separates semantics from
code generation, both backends consume `sema.Checked`, and the ABI is written
down and tested. That is the part worth keeping.

## 2. What blocks firmware today

1. **One target.** The native backend is Linux x86-64 with hard-coded
   registers, a hard-coded `target triple` in the IR and a Linux `exit`
   syscall. There is no target abstraction to plug Cortex-M or RISC-V into.
2. **Pointers are still deliberately limited.** Typed pointers, address-of,
   dereference, struct-field access through a pointer, pointer arithmetic and
   pointer equality/inequality exist for the current target. Arrays, slices,
   indexing, nullability rules, ownership/borrowing and a formal aliasing model
   are not implemented.
3. **No `unsafe`/`volatile`.** `src/sema/unsafe.zig` holds the policy, but the
   AST has no `unsafe` block, no `volatile` qualifier and no attributes, so a
   register read could be reordered or dropped with no diagnostic.
4. **Integer widths exist, but target layout is not configurable.** The
   compiler supports `i8`/`i16`/`i32`/`i64`, `u8`/`u16`/`u32`/`u64` and
   `usize`, with explicit integer casts and bitwise/shift operators. The current
   target remains fixed to Linux x86-64; portable data layouts, overflow
   contracts across targets and target-specific integer semantics still need
   formalization.
5. **No layout control.** No `#[repr(C)]`, no explicit alignment, no
   compile-time offset assertions. A hardware register block must have a
   guaranteed layout.
6. **No freestanding mode.** The entry point is fixed (`fn main() -> i32`),
   sections are fixed (`.text` + `.rodata`), there is no linker script, no
   `.data`/`.bss` initialization, no vector table, no startup code and no
   configurable stack.
7. **The standard library is stub-level.** `std/core/core.zig` documents
   `Alloc.alloc` returning an empty slice and `Unsafe.block` doing nothing;
   some `std/os` APIs perform no real I/O. It is a contract placeholder, not a
   runtime.
8. **Cross-compilation and object formats.** Only `as`/`ld` on the host; no
   ELF/BIN/HEX emission, no target triple selection in the CLI, no linker
   script input.
9. **FFI is an isolated experiment.** `src/ffi/ffi.zig` is a single
   `extern "c" printf` declaration, not wired into the compiler.

## 3. Architecture direction

Keep **one** compiler and make the target an explicit input, instead of forking
a second implementation:

```
Kyn source (.kyn)
      │
   frontend: lexer → parser → AST → sema      (target independent)
      │
   target description (data layout, ABI, registers, word size, endianness)
      │
   backends: x86-64 native │ ARM (Cortex-M) │ LLVM IR │ …
      │
   drivers: executable │ object/ELF │ BIN/HEX + linker script
```

Proposed layout (only when the corresponding cycle starts — no empty modules
are created ahead of time):

```
src/target/
├── target.zig          # Target = arch + os + ABI + data layout
├── data_layout.zig     # sizes/alignments per type, pointer width
├── abi.zig             # calling convention description
└── targets/
    ├── x86_64_linux.zig
    └── thumb_cortex_m.zig
```

Rules for that refactor, to avoid churn:

- `sema` stays target independent; it may **query** the data layout (type
  sizes, alignment) but must not encode x86-64 specifics.
- The six-register limit and the `%eax`/`%edx` return pairs move out of
  `x86_64.zig` into the target description, so a new backend does not copy
  them.
- Every new target lands with: a layout test, an ABI test, at least one
  executed fixture and a row in `docs/status.md`.

## 4. Implementation order

Order chosen so each step is useful on its own and testable on the host:

1. **Fixed-width integers** — `u8`/`i8`, `u16`/`i16`, `u32`, `u64`, `usize`;
   explicit `as` conversions with truncation/sign rules; bitwise `&`/`|`/`^`,
   `~`, `<<`/`>>`; defined wrap semantics; `print` for the new widths.
   *Checkpoint:* value-model tests per width in both backends.
2. **Pointers and `unsafe`** — `*T`, `*const T`, address-of, dereference,
   integer → pointer conversion inside `unsafe`, explicit border to the type
   checker (wire `src/sema/unsafe.zig` to real AST nodes).
   *Checkpoint:* a fixture that writes through a pointer into an `i32` local.
3. **`volatile` and MMIO** — `volatile` qualifier on loads/stores preserved by
   both backends, no reordering/elimination; a `Register`/`Mmio` abstraction in
   a future `kyn:embedded` package.
   *Checkpoint:* IR/assembly inspection proving one load per read.
4. **Layout control** — `#[repr(C)]`, explicit alignment, compile-time
   `offset_of`/size assertions; documented padding rules.
   *Checkpoint:* layout test matching a reference C struct.
5. **Freestanding mode** — `--freestanding`, configurable entry symbol,
   `.data`/`.bss` initialization, section control, linker script input,
   `-o` producing ELF (plus `objcopy`-style BIN/HEX paths documented, not
   reimplemented).
   *Checkpoint:* a freestanding x86-64 binary with no libc and a custom entry
   point, executed on the host.
6. **First real target: ARM Cortex-M4 (STM32F401RE)** — Thumb-2 code generation
   for the subset above, vector table and startup code, linker script, LED
   blink with no runtime.
   *Checkpoint:* binary produced by the compiler, checked structurally on the
   host and flashed on the board.
7. **Second target: RISC-V RV32** — proves the target abstraction with a very
   different ISA.
8. **LLVM target configuration** — select the triple/CPU/features from the
   `Target`, keeping the native backend as the reference implementation.

Steps 1–4 are language work that also benefits Linux programs; steps 5–7 are
the freestanding milestone. That is why the roadmap marks freestanding as a
**separate phase** rather than a rewrite of the current backends.

## 5. Standard library split (direction)

```
kyn:core        # target independent: types, memory, pointers, slices, bits, atomics
kyn:embedded    # mmio, registers, interrupts: no OS dependency
kyn:os/linux    # files, processes, sockets
```

`core` must not depend on `embedded` or `os`, and the compiler must not depend
on any of them. Today `std/core` explicitly documents its stubs; those tests
stay until each API is replaced by a real implementation with behavior tests.

## 6. What this document does not claim

- That Kyn compiles for any microcontroller today.
- That the current LLVM IR is valid for non-x86-64 targets (the triple is fixed
  and only the x86-64 datapath is exercised).
- That the standard library, FFI or `unsafe` policy is usable in production.
- A schedule. The order above is a dependency order, not dates.
