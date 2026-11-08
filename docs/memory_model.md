# Memory model

**Status:** design guidelines; this is not a formal guarantee of the current implementation.

Kyn aims to offer explicit control over memory and resources, focused on low-level systems. The final model still needs to be specified and validated by the compiler.

## Goals

- No dependency on a garbage collector.
- Make allocation and resource release explicit.
- Allow allocators chosen by the program.
- Offer low-level operations inside delimited, auditable contexts.
- Allow interoperability with C when layout and ABI are specified.

## Concepts under evaluation

### Allocators

The code in `std/core/arena.kyn` shows an arena prototype with a buffer and an offset. It must not be considered a safe or complete implementation: overflow checks, bounds, alignment, allocation failures and lifetime contracts still have to be defined.

### Unsafe operations

Operations that may violate memory invariants must be explicitly delimited. The exact semantics of `unsafe`, its obligations and what the compiler verifies still need a specification.

### Layout and ABI

Attributes such as `#[repr(C)]`, alignment and packing are interoperability goals. Compatibility can only be guaranteed after layout tests and integration with the supported C toolchains.

### Ownership and aliasing

Ownership, move semantics and aliasing rules are design topics. In the current state there is not enough evidence to claim that the compiler enforces those guarantees end to end.

## Requirements for stabilization

- Formal ownership and borrowing rules, if adopted.
- Definition of lifetimes and reference validity.
- Rules for raw pointers and pointer arithmetic.
- Alignment and size guarantees for types.
- Behavior on allocation failure.
- Safety, regression and ABI interoperability tests.
