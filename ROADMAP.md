# Roadmap

Sequência de trabalho proposta. Um item só é marcado como concluído quando o código
existe, há teste executável e a documentação descreve o comportamento observado.
Itens marcados com ✅ foram verificados em 2026-11-02 com `zig build check`
(26 testes unitários + 105 casos de integração, 0 falhas).

## Fase 1 — Bootstrap em Zig

- ✅ Criar a estrutura inicial de lexer, parser, AST, semântica e codegen.
- ✅ Definir build reproduzível com `build.zig` (alvos `build`, `test`,
  `integration`, `check`, `run`).
- ✅ Implementar CLI funcional e documentar argumentos e códigos de saída.
- ✅ Completar o parser e a construção da AST (subconjunto em `docs/syntax.ebnf`).
- ✅ Completar a análise semântica e o sistema de tipos do subconjunto
  (primitivos, referências, ponteiros, structs, enums).
- ✅ Integrar o pipeline de compilação de ponta a ponta (`src/driver.zig`).
- ✅ Definir e validar um backend de geração de código (C99, verificado com `cc`).
- ⬜ Backend próprio (LLVM IR ou código de máquina), removendo a dependência de um
  compilador C.

## Fase 2 — Linguagem e runtime

- ⬜ Formalizar sintaxe e semântica **completas** (hoje: subconjunto documentado).
- ✅ Especificar operações `unsafe` implementadas (dereferência de ponteiro cru,
  escrita por ponteiro, chamada de `extern fn`) e testá-las.
- ⬜ Especificar ownership, moves, empréstimos e lifetimes (hoje só há tipagem de
  referências, sem borrow checker).
- ⬜ Definir contratos de allocators e falhas de alocação.
- ⬜ Estabilizar FFI: convenção de chamada, layout `#[repr(C)]` testado contra C,
  ownership de buffers e strings.
- ⬜ Separar e validar as APIs de `kyn:core` e `kyn:std` (hoje `import` só valida o
  nome do módulo).
- ✅ Criar runner de testes para fixtures `.kyn` (`src/runner.zig`).
- ⬜ Slices `[]T`, arrays `[N]T` e indexação.
- ⬜ Generics, traits e `match`.
- ⬜ Semântica de `str` com comprimento (hoje é `const char *` terminado em NUL).

## Fase 3 — Qualidade e portabilidade

- ⬜ Adicionar CI para build, testes e formatação.
- ✅ Cobrir diagnósticos, entradas malformadas e casos de fronteira
  (`tests/diagnostics`, 26 casos, incluindo entrada malformada).
- ⬜ Definir targets e matriz de plataformas suportadas (hoje: Linux x86_64 com
  `cc`; o restante não foi testado).
- ⬜ Criar testes de interoperabilidade e regressão com bibliotecas C reais.
- ⬜ Documentar benchmarks reproduzíveis, sem alegações não verificadas.
- ⬜ Fuzzing contínuo do frontend.

## Fase 4 — Self-hosting e estabilidade

- ⬜ Implementar o compilador em Kyn sem placeholders (os rascunhos estão em
  `experiments/self-host-sketch/` e não são aceitos pelo compilador atual).
- ⬜ Demonstrar bootstrap reproduzível usando o compilador anterior.
- ⬜ Definir política de compatibilidade e versionamento da linguagem.
- ⬜ Publicar releases com artefatos, checksums e notas de versão.

## Próximo passo recomendado

CI executando `zig build check` em Linux, macOS e Windows: é o menor incremento que
transforma a verificação local em garantia contínua e destrava a matriz de
plataformas da Fase 3.
