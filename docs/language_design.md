# Kyn language design principles

**Status:** design proposal — not normative and not fully implemented.

This document records the intended direction for Kyn. The examples are illustrative: they must not be treated as compilable code until each construct is defined in the specification, implemented in the compiler and covered by tests.

## Identity

Kyn is conceived as a systems programming language, with modern syntax and explicit control over resources. The goal is to combine low-level predictability with static safety mechanisms and abstractions whose cost the programmer can understand.

## Principles

1. **Predictable performance:** avoid hidden runtime costs and let the programmer understand the cost of abstractions.
2. **Explicit resource control:** allocation, release and resource duration must have clear contracts.
3. **Static typing:** types and conversions must be checked before code generation.
4. **Safe by construction:** prevent memory and concurrency errors through static analysis whenever possible, without promising guarantees that are not implemented.
5. **Interoperability:** allow integration with C through explicit layout and ABI contracts.
6. **Minimal runtime:** keep the runtime small and avoid mandatory garbage-collector dependencies.
7. **Controlled portability:** separate primitives that are independent of the operating system from platform-specific interfaces.
8. **Abstractions with explicit cost:** high-level abstractions must not hide relevant allocations, copies or synchronization.

## Language guidelines

| Area | Proposed direction | State |
| --- | --- | --- |
| Typing | Static, with limited and explicit inference | Proposed |
| Integers | Fixed widths and architecture-dependent types | Proposed |
| Functions | Declaration with `fn` and `-> Type` return | Proposed |
| Mutability | `let` immutable and `var` mutable | Proposed |
| Aggregates | `struct` and `enum` | `struct` and `enum` with exhaustive `switch` implemented for scalars |
| Methods | `impl` blocks | Proposed |
| Modules | Explicit imports | Experimental / under definition |
| Memory | Explicit allocators, no GC as a goal | Proposed |
| References | Shared and mutable borrowing | Proposed |
| Raw pointers | Low-level access in an auditable context | Proposed |
| Errors | Explicit types such as `Result<T, E>` | Proposed |
| Concurrency | Sharing and mutability safety as a design requirement | Planned |
| Metaprogramming | Compile-time evaluation (`comptime`) | Planned |

## Safety and the unsafe context

Operations that may violate invariants — for example dereferencing raw pointers, doing pointer arithmetic or calling external interfaces without a verified contract — must be delimited by an explicit `unsafe` context.

The keyword, its rules and the programmer's obligations are not formalized yet. The existence of an `unsafe` block must not be read as an automatic safety guarantee outside of it.

## Intended compilation model

The reference pipeline is:

```text
.kyn source
   |
 Lexer
   |
 Parser
   |
 AST
   |
Name resolution and semantic analysis
   |
 HIR
   |
 MIR
   |
 Optimizations
   |
 Backend
   |
 Object / executable
```

HIR and MIR are proposed architectural stages. The current repository implementation does not offer that full pipeline yet.

## Criteria to promote a proposal to a stable feature

A construct must only be considered a stable part of the language when there is:

- normative, unambiguous grammar;
- semantic rules, including conversions and error cases;
- implementation in frontend and backend;
- positive, negative and boundary tests;
- documented diagnostics;
- decisions on ABI, layout and compatibility, when applicable;
- an update of the specification version and the changelog.

## Relation to the implementation

See [status.md](status.md) to distinguish what exists in the repository from what is only planned. The overall specification is in [spec.md](spec.md), and the syntax examples are in [language_reference.md](language_reference.md).
