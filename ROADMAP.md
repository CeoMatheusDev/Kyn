# Roadmap

Sequência de trabalho proposta. Um item só é marcado como concluído quando o código
existe, há teste executável e a documentação descreve o comportamento observado.
Itens marcados com ✅ foram verificados com `zig build check` (27 testes unitários +
122 casos de integração, 0 falhas, em 2026-11-03).

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
- ✅ Slices `[]T`/`[]const T`, arrays `[N]T`, indexação, fatiamento, `.len` e
  `for item in colecao` (0.4.0-alpha.1). Sem verificação de limites em tempo de
  execução e sem ownership de slices — ambos dependem de runtime e borrow checker.
- ✅ `match` sobre enum com verificação de exaustividade, curinga `_` e variantes
  qualificadas ou não (0.5.0-alpha.1). Apenas como statement: sem padrões com ligação,
  guardas ou faixas.
- ⬜ Generics e traits.
- ⬜ `match` como expressão (depende de blocos como expressão).
- ⬜ Semântica de `str` com comprimento (hoje é `const char *` terminado em NUL).

## Fase 3 — Qualidade e portabilidade

- ✅ CI para build e testes em Linux, macOS e Windows
  (`.github/workflows/ci.yml`), verde nas três plataformas (run 41554129555). O
  Windows roda só os unitários: a suíte de integração exige `cc` no `PATH`, ausente
  nos runners do Windows.
- ⬜ Adicionar formatação/lint ao CI.
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

`Result<T, E>`: exige generics mínimos (monomorfização por instanciação) e é o
pré-requisito para qualquer API real da biblioteca padrão. Na sequência, `cc` no CI do
Windows (MSYS2/MinGW) para que a suíte de integração rode nas três plataformas.
