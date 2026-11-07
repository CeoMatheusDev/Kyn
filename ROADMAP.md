# Roadmap

Este roadmap representa a sequência de trabalho proposta. Os itens não são
promessas de release e só devem ser marcados como concluídos quando houver
implementação integrada e testes reproduzíveis.

## Fase 1 — Bootstrap em Zig

- [x] Criar a estrutura inicial do lexer, parser, AST, semântica e codegen.
- [x] Definir build reproduzível com `build.zig` (Zig 0.17.0, `zig build test`,
      `zig build e2e`).
- [x] Implementar CLI funcional e documentar seus argumentos (`kync check`,
      `kync emit`, `--llvm`/`--asm`, `-o`, `--lib`; códigos 0/1/2/3).
- [x] Integrar o pipeline de compilação de ponta a ponta para o subconjunto
      atual (lexer → parser → AST → semântica → backend), com validação
      executável via `as`/`ld`.
- [x] Compilação multi-arquivo com `import "caminho";` (resolução relativa ao
      arquivo importador, deduplicação, ciclos/arquivos ausentes/símbolos
      duplicados diagnosticados) e fixtures e2e executadas.
- [x] `struct` com campos escalares: declaração, literais, acesso e atribuição
      a campo, cópia por valor, layout documentado nos dois backends e
      restrições diagnosticadas (sem passagem por valor ainda).
- [x] Saída de texto: `str` como fatia estática (ponteiro + tamanho), literais
      deduplicados, `print(...)` embutido no backend nativo (syscall `write`) e
      no IR do LLVM (libc `write`), com stdout conferido na suíte e2e
      (`// expect-stdout:`).
- [x] Saída de valores: `print_i32(...)` embutido, com conversão decimal própria
      em cada backend (`divl` unsigned no nativo, `urem`/`udiv` no IR),
      cobrindo zero, negativos e os limites de `i32`; stdout conferido no e2e.
- [x] `str` por valor em parâmetros e retornos: ABI própria documentada
      (ponteiro + tamanho em pares de registradores, retorno em `%rax`/`%rdx`;
      `ptr`+`i64` e `{ ptr, i64 }` no IR), limite de seis registradores contando
      `str` como dois, e2e com helpers recebendo e devolvendo texto.
- [ ] Completar o parser e a AST para a linguagem-alvo. Subconjunto atual:
      `fn`, `let`/`var`, atribuição, `return`, `if`/`else`, `while`, blocos,
      expressões com precedência, `import`, `struct` (local) e `str` (inclusive
      por valor entre funções). Faltam struct por valor entre funções, `enum`,
      `impl`, `unsafe`, atributos, comparação/concatenação de `str`, slices,
      ponteiros e generics.
- [ ] Completar a análise semântica e o sistema de tipos além de
      `i32`/`bool`/`void`/`str` (inteiros de outras larguras, `f32`/`f64`,
      `str` com ownership/lifetimes, checagem de fluxo).
- [ ] Definir e validar o backend oficial. O backend x86-64 é validado por
      execução; o IR do backend LLVM é aceito por `llvm-as` no CI, mas a
      escolha do backend oficial (e um `target triple` configurável) segue
      pendente.

## Fase 2 — Linguagem e runtime

- [ ] Formalizar sintaxe e semântica (normatizar `syntax.ebnf` para a
      linguagem-alvo, hoje limitada ao subconjunto implementado).
- [ ] Especificar ownership, lifetimes e operações `unsafe`; conectar
      `src/sema/unsafe.zig` a nós reais da AST.
- [ ] Definir contratos de allocators e falhas de alocação.
- [ ] Estabilizar FFI e layout compatível com C.
- [ ] Separar e validar as APIs de `kyn:core` e `kyn:std` (hoje stubs
      experimentais; várias APIs não fazem E/S real).
- [x] Criar runner de testes para fixtures `.kyn` do subconjunto suportado
      (`tools/e2e.sh` + `zig build e2e`, com `// expect-exit: N` e
      `// expect-stdout:`).
- [ ] Ampliar o runner para fixtures de diagnóstico (mensagem/posição esperadas
      por arquivo) em vez de apenas código de saída e stdout.

## Fase 3 — Qualidade e portabilidade

- [x] Adicionar CI para build, testes e formatação: `.github/workflows/ci.yml`
      roda `zig fmt --check`, `zig build test`, `zig build e2e` e
      `zig build validate-ir-strict` (com LLVM instalado no runner).
- [ ] Cobrir diagnósticos, entradas malformadas e casos de fronteira de forma
      sistemática.
- [ ] Definir targets e matriz de plataformas suportadas (o backend nativo é
      Linux x86-64).
- [ ] Criar testes de interoperabilidade e regressão.
- [ ] Documentar benchmarks reproduzíveis, sem alegações não verificadas.

## Fase 4 — Self-hosting e estabilidade

- [ ] Implementar o compilador em Kyn sem placeholders.
- [ ] Demonstrar bootstrap reproduzível usando o compilador anterior.
- [ ] Definir política de compatibilidade e versionamento da linguagem
      (alinhar `CHANGELOG.md` ao que está implementado).
- [ ] Publicar releases com artefatos, checksums e notas de versão.

## Critério de conclusão

Uma etapa só deve ser considerada concluída quando o código correspondente
existir, os testes forem executáveis e a documentação descrever o comportamento
observado.
