# Contributing to Kyn

Thanks for your interest in Kyn. Since the compiler and the language are still experimental, small, testable and documented contributions matter especially.

## Before you start

- Read [README.md](README.md), [docs/architecture.md](docs/architecture.md) and [docs/status.md](docs/status.md).
- Use the Zig version declared by the project (currently 0.17.0) and report the version actually used.
- Check whether the feature already exists or is tracked in the roadmap.

## Pull requests

Every PR must:

1. Have a clear, limited scope.
2. Explain the problem and the solution.
3. Include tests for the changed behavior, when applicable.
4. Report the commands executed and their results.
5. Update the documentation when syntax, semantics, API, memory, FFI or the build flow changes.
6. Clearly distinguish working code, prototype and placeholder.

## Technical guidelines

- Respect the intended separation between `kyn:core` and OS-dependent features.
- Avoid unnecessary copies and allocations; document ownership and lifetime.
- Do not introduce safety or performance guarantees without evidence and tests.
- Do not add dependencies without justifying the cost, build impact and the alternative considered.
- Preserve compatibility or explicitly document incompatible changes.

## Tests

Run `zig build test` for the unit tests. For changes in lexer, parser, semantics or backends, also run `zig build e2e`, which compiles `.kyn` fixtures of the supported subset, assembles with `as`, links with `ld` and checks each program's exit code (plus the `// expect-stdout:` lines when present). Features not implemented yet (for example generics, slices, integrated `unsafe` syntax and `Result<T, E>`) must not be presented as supported. `impl`/methods are implemented for the current subset.

## Commits

Prefer small commits with objective messages, for example:

- `feat(parser): parse grouped expressions`
- `fix(lexer): preserve line positions`
- `test(sema): cover duplicate declarations`
- `docs: clarify memory model status`

## Reporting bugs

Include the Zig version, operating system, reproduction steps, minimal input and observed output. Remove sensitive data before sharing logs.
