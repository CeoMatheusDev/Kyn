# Kyn

Linguagem de baixo nível extremo, moderna, segura por padrão, sem GC e sem runtime pesado.

- Repositório oficial: https://github.com/CeoMatheusDev/Kyn
- Bootstrap: Zig 0.17.0 (Fase 1)
- Self-hosting: Kyn (Fase 3 / v1.0.0)
- 
![Kyn Logo](assets/branding/logos/logo_kyn.jpg)

## Estrutura

```text
Kyn/
├── assets/       # Logotipo oficial (branding)
├── docs/         # spec.md, grammar.ebnf, memory_model.md
├── src/          # Compilador Bootstrap (Zig 0.17.0)
├── std/          # kyn:core (bare-metal) / kyn:std (SO)
├── tests/        # .kyn testes de integração
└── examples/     # Kernels, Embarcados, Engines
```

## Versão atual

`v0.8.0-beta.2` — Marco 2.3 (`kyn:std`: I/O, Threads, Networking + FFI C).

Veja `CHANGELOG.md` para histórico SemVer (v0.1.0-alpha.1 → v0.2.0-alpha.1).
