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
- [ ] Completar o parser e a AST para a linguagem-alvo. Subconjunto atual:
      `fn`, `let`/`var`, atribuição, `return`, `if`/`else`, `while`, blocos e
      expressões com precedência. Faltam `import`, `struct`, `enum`, `impl`,
      `unsafe`, atributos, strings, slices, ponteiros e generics.
- [ ] Completar a análise semântica e o sistema de tipos além de
      `i32`/`bool`/`void` (inteiros de outras larguras, `f32`/`f64`, `str`,
      ownership, lifetimes, checagem de fluxo).
- [ ] Definir e validar o backend oficial. O backend x86-64 é validado por
      execução; o backend LLVM IR é validado apenas estruturalmente porque não
      há ferramenta LLVM no ambiente de desenvolvimento.

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
      (`tools/e2e.sh` + `zig build e2e`, com `// expect-exit: N`).
- [ ] Ampliar o runner para fixtures de diagnóstico (mensagem/posição esperadas
      por arquivo) em vez de apenas código de saída.

## Fase 3 — Qualidade e portabilidade

- [ ] Adicionar CI para build, testes e formatação (`zig fmt --check` já passa
      localmente).
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
