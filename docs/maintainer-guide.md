# Maintainer guide

This document defines the repository-level maintenance contract. It is not a second implementation-status report; the canonical feature matrix and validation evidence live in [docs/status.md](status.md).

## Sources of truth

| Concern | Canonical file |
| --- | --- |
| Package version and minimum Zig version | `build.zig.zon` |
| Build graph and available steps | `build.zig` |
| Implemented language grammar | `docs/syntax.ebnf` and `docs/grammar.ebnf` |
| Verified feature support and limitations | [Implementation status](status.md) |
| Compiler architecture and stage contracts | [Architecture](architecture.md) |
| Developer workflow | [Development guide](development.md) |
| Planned work | [Roadmap](../ROADMAP.md) |
| Historical changes | [Changelog](../CHANGELOG.md) |

When two documents disagree, verify behavior against source and tests, update the canonical document first, then repair references and summaries.

## Change protocol

1. Identify the affected compiler stage and its public contract.
2. Make the smallest coherent change; avoid unrelated formatting or architecture churn.
3. Add positive, negative and boundary tests as appropriate.
4. Run `zig fmt` on changed Zig files.
5. Run `zig build test`; run `zig build e2e` for frontend, semantic or backend changes.
6. Run `zig build validate-ir-strict` when LLVM output or backend behavior changes.
7. Update grammar, status, tutorial and changelog when user-visible behavior changes.
8. Report exact commands and results, including unavailable validation.

## Architectural constraints

- Keep the Zig bootstrap pipeline explicit: lexer → parser/AST → semantic analysis → backend.
- Preserve source spans and avoid copying token text unnecessarily.
- Keep compilation-owned allocations under the compilation lifetime; document ownership when introducing longer-lived data.
- Do not make the experimental Kyn prototypes appear to be active compiler modules.
- Do not move source files without updating Zig imports, build module paths, tests, documentation and CI.
- Do not introduce dependencies without a concrete need and a cost/benefit review.

## Naming and formatting

- Zig source uses `snake_case.zig` and four-space indentation.
- Kyn source uses `.kyn` and four-space indentation.
- Documentation uses descriptive lowercase filenames with hyphens or underscores consistently within a section.
- Tests should describe behavior, not implementation accidents; group e2e cases by positive, negative or module scenario.
- Keep line endings as LF and text files UTF-8.

## Release discipline

A version is not stable because a changelog entry says so. A release requires reproducible builds, passing CI, documented language and ABI contracts, validated artifacts and an explicit compatibility policy. Until then, label the compiler and language experimental.
