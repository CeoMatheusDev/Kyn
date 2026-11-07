# Changelog — Kyn

Regras: Semantic Versioning 2.0.0. Pré-1.0.0 = Pre-release.

> **Aviso de rastreabilidade:** as entradas abaixo de `v0.3.0-alpha.1`
> registram marcos pretendidos em ciclos anteriores do projeto e **não**
> constituem evidência de implementação. Várias descrevem recursos que o código
> não possui (por exemplo self-hosting, release "industrial estável",
> `Result<T, E>` e organização de módulos). O estado real, verificado por build
> e testes, está em [docs/status.md](docs/status.md). O versionamento será
> reconciliado antes de qualquer release pública.

## [v0.3.0-alpha.1] — 2026-11-07

Ciclo de integração do frontend com validação executável.

- **Build:** adicionados `build.zig` e `build.zig.zon` (Zig 0.17.0 como versão
  mínima). `zig build`, `zig build test` e `zig build e2e` funcionam.
- **Toolchain:** desbloqueio da validação com Zig 0.17.0 real (binário oficial
  obtido via pacote PyPI `ziglang` 0.17.0.post0).
- **Lexer:** contrato de tokens reescrito com `Tag` tipada, palavras-chave,
  operadores de dois caracteres e `Span` (offset, linha, coluna 1-based);
  comentários e espaços descartados; caractere inválido vira token diagnosticado.
- **AST:** novo modelo com funções, parâmetros, `let`/`var`, atribuição,
  `return`, `if`/`else`, `while`, blocos e expressões; anotações de resolução
  feitas pela semântica.
- **Parser:** constrói o programa completo, com precedência/associatividade
  documentadas em `docs/syntax.ebnf`; erros com span e mensagem.
- **Semântica:** escopos aninhados, resolução de nomes, tipos `i32`/`bool`/
  `void`, mutabilidade, verificação de chamadas, validação de `main`,
  verificação estrutural de retorno e atribuição de slots de pilha.
- **Diagnósticos:** módulo próprio com categoria estável, mensagem, linha e
  marcador `^`.
- **Backends:** interface em `src/codegen/codegen.zig` com dois emissores
  derivados da AST — LLVM IR textual e assembly x86-64 System V sem libc.
- **CLI `kync`:** `check` e `emit` (`--llvm`, `--asm`, `-o`, `--lib`) com
  códigos de saída 0/1/2/3 e ajuda/versão.
- **Testes:** 96 testes unitários (89 do compilador + 7 da std experimental);
  64 casos de ponta a ponta (9 fixtures
  comportamentais executadas, 50 fixtures `tests/integration/case_N.kyn`
  conferidas pelo código de saída e 5 fixtures negativas). Testes antigos em
  `src/test_*.zig` foram consolidados em `src/tests.zig` e `std/tests.zig`
  (o antigo `src/test_core.zig` importava um arquivo inexistente).
- **Documentação:** `README.md`, `docs/status.md`, `docs/architecture.md`,
  `docs/development.md`, `docs/grammar.ebnf`, `docs/syntax.ebnf` e `ROADMAP.md`
  reconciliados com o comportamento observado.

## [v2.3.0] — 2026-11-01
- Marco 3.10: Lançamento da Release Industrial Estável. Congelamento final do compilador self-hosted `kync`, documentação completa, empacotamento do binário final.

## [v2.2.0-rc.1] — 2026-11-01
- Marco 3.9: 50+ arquivos de integração end-to-end (`tests/integration/case_*.kyn`).

## [v2.1.0-beta.1] — 2026-11-01
- Marco 3.8: Result<T, E> nativo (`src/compiler/result.kyn`, `tests/result_basic.kyn`).

## [v2.0.0-beta.1] — 2026-11-01
- Marco 3.7: RingBuffer lock-free (`std/core/ringbuffer.kyn`, `tests/ringbuffer_basic.kyn`).

## [v1.9.0] — 2026-11-01
- Marco 3.6: Primitivas atômicas (`std/core/atomics.kyn`, `tests/atomics_basic.kyn`).

## [v1.8.0] — 2026-11-01
- Marco 3.5: Suporte a FFI Nativa com C (`src/compiler/ffi.kyn`, `tests/ffi_basic.kyn`).

## [v1.7.0] — 2026-11-01
- Marco 3.4: Otimizações de registradores no CodeGen (`src/compiler/regopt.kyn`, `tests/regopt_basic.kyn`).

## [v1.6.0] — 2026-11-01
- Marco 3.3: Verificação de mutabilidade estrita (`src/compiler/mutability.kyn`, `tests/mutability_basic.kyn`).

## [v1.5.0] — 2026-11-01
- Marco 3.2: ArenaAllocator nativo (`std/core/arena.kyn`, `tests/arena_basic.kyn`).

## [v1.4.0] — 2026-11-01
- Marco 3.1: Sistema de Módulos & Imports (`src/compiler/modules.kyn`, `tests/modules/basic.kyn`).

## [v1.2.0] — 2026-11-01
- Fuzz Testing: `tests/fuzz/fuzzer.kyn`, `tests/fuzz/harness.kyn`, `tests/fuzz/edge_cases.kyn`.
- Garantia de crash-proof (sem panic/segfault) para entradas malformadas.

## [v1.1.0] — 2026-11-01
- Diagnostics: `src/compiler/span.kyn`, `src/compiler/diagnostics.kyn` (mensagens de erro estilo Rust/Zig).
- Testes: `tests/diagnostics/invalid_type.kyn`, `tests/diagnostics/invalid_syntax.kyn`.

## [v1.0.0] — 2026-11-01
- Marco 3.1/3.2: Self-Hosting — compilador reescrito em Kyn (`src/compiler/`), testes `tests/self_host_test.sh`.
- Linguagem estável oficial, pronta para produção.

## [v0.9.0-rc.1] — 2026-11-01
- Marco 2.4: Release Candidate do compilador Bootstrap. Cobertura de testes > 90%, otimizações de pipeline, especificações congeladas.
- README profissional com badges, roadmap SemVer e arquitetura.

## [v0.8.0-beta.2] — 2026-11-01
- Marco 2.3: `std/os/` (I/O, Threads, Networking), `src/ffi/ffi.zig` (FFI C), `tests/std_basic.kyn`, `src/test_std.zig`.
- Expansão da capacidade de interação com SO e ecossistemas externos.

## [v0.6.0-beta.1] — 2026-11-01
- Marco 2.2: `src/sema/unsafe.zig` (verificação de blocos `unsafe` e `#[repr(C)]`), `tests/unsafe_basic.kyn`, `src/test_unsafe.zig`.
- Transição alpha → beta: enforce de segurança e layout de memória.

## [v0.5.0-alpha.1] — 2026-11-01
- Marco 2.1: `std/core/core.zig` (unsafe, @align, alocadores explícitos), `tests/core_basic.kyn`, `src/test_core.zig`.
- Separação `kyn:core` (bare-metal) iniciada.

## [v0.4.0-alpha.1] — 2026-11-01
- Marco 1.4: `src/codegen/codegen.zig` (emissão LLVM IR básico), testes `tests/codegen_basic.kyn` + `src/test_codegen.zig`.
- Ciclo completo do compilador Bootstrap: Lexer → Parser → AST → Sema → CodeGen.

## [v0.3.0-alpha.1] — 2026-11-01
- Marco 1.3: `src/sema/sema.zig` (Typechecker básico, escopo `let`, `Result<i32, E>` inicial), testes `tests/sema_basic.kyn`.
- Integração `lexer` → `parser` → `ast` → `sema`.

## [v0.2.0-alpha.1] — 2026-11-01
- Marco 1.2: Parser (`src/parser/parser.zig`), AST (`src/ast/ast.zig`), testes `.kyn` (`tests/parser_basic.kyn`).
- Separação `lexer` → `parser` → `ast` respeitada.
- Erros sintáticos reportados via `!AST.Error`.

## [v0.1.0-alpha.1] — 2026-11-01
- Marco 1.1: estrutura de repositório, CLI `kync`, Lexer básico, testes Zig + `.kyn`.
- Dependência estrita: Zig 0.17.0.
- Target emissão: LLVM IR direto (Fase 1.4).
