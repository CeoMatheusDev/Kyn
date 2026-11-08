# Kyn documentation

This folder holds the project's technical documentation. The documents explicitly distinguish behavior observed in the code, language proposals and planned features.

## Index

| Document | Contents |
| --- | --- |
| [Architecture](architecture.md) | Bootstrap compiler components and module organization |
| [Implementation status](status.md) | What is present, partial or missing |
| [Development](development.md) | Requirements, build, CLI, validation and contribution flow |
| [Specification](spec.md) | Principles and language decisions still in evolution |
| [Language reference](language_reference.md) | `.kyn` syntax examples, types, functions, memory, errors and modules |
| [Design principles](language_design.md) | Identity, requirements and architectural guidelines of the language |
| [Lexical grammar](grammar.ebnf) | Tokens, keywords and operators implemented in the lexer |
| [Syntactic grammar](syntax.ebnf) | Exact grammar of the subset accepted by the current parser |
| [Memory model](memory_model.md) | Proposed guidelines for memory, ownership and FFI |
| [Maintainer guide](maintainer-guide.md) | Sources of truth, change protocol and engineering conventions |

## Directory guides

- [Compiler source](../src/README.md) — active Zig pipeline and experimental prototypes.
- [Standard library](../std/README.md) — intended core/OS boundary and current limitations.
- [Tests](../tests/README.md) — fixture taxonomy and validation commands.

## Conventions

- **Implemented:** behavior verifiable in the current implementation.
- **Partial:** initial code exists, but the flow is not complete.
- **Proposed:** design decision not yet implemented or validated.
- **Planned:** roadmap item, with no delivery guarantee.

Documentation must follow the code. When they diverge, record the divergence and update the documentation after confirming the real behavior.
