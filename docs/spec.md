# Kyn language specification

**Status:** evolving design document, not a frozen normative specification.

This document records goals and preliminary decisions. Syntax and semantics must be considered experimental until they are implemented, tested and formally versioned.

## Goals

- A language aimed at systems and low-level software.
- Explicit control of allocation and resource lifetime.
- No garbage collector as a design goal.
- Interoperability with C through a documented ABI.
- Separation between essential features and operating-system-dependent features.
- Explicit error handling, with types such as `Result<T, E>` as the proposal.

## Proposed guidelines

| Theme | Guideline | Situation |
| --- | --- | --- |
| Memory | Explicit allocation and visible allocators | Proposed |
| Safety | Delimited use of `unsafe` operations | Proposed |
| Layout | Representation and alignment attributes | Proposed |
| FFI | Interoperability with the C ABI | Experimental |
| Errors | Result types instead of exceptions | Proposed |
| Metaprogramming | `comptime` resources | Planned |
| Modules | Imports and modular organization | Experimental |

## Syntax and grammar

The [preliminary language reference](language_reference.md) gathers illustrative `.kyn` file examples. The [design principles](language_design.md) record the architectural goals. The grammar in [grammar.ebnf](grammar.ebnf) describes only an initial lexical subset observed in the lexer; [syntax.ebnf](syntax.ebnf) is a proposed syntactic sketch and is not normative yet. None of those documents may be read as proof that the corresponding syntax is already accepted by the compiler.

## Memory model

See [memory_model.md](memory_model.md). The rules described there are design goals, not formal guarantees already implemented.

## Evolution process

A feature must only be promoted to a stable part of the language when it has:

1. Unambiguous syntactic and semantic definition.
2. Implementation in the compiler.
3. Positive and negative tests.
4. Documentation of errors and boundary cases.
5. Compatibility or an explicit breaking-change policy.

Language version and compiler version must be identified separately once formal versioning is adopted.
