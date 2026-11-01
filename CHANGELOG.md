# Changelog — Kyn

Regras: Semantic Versioning 2.0.0. Pré-1.0.0 = Pre-release.

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
