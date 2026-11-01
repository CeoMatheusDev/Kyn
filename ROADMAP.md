# Roadmap

Este roadmap representa a sequência de trabalho proposta. Os itens não são promessas de release e só devem ser marcados como concluídos quando houver implementação integrada e testes reproduzíveis.

## Fase 1 — Bootstrap em Zig

- [x] Criar a estrutura inicial do lexer, parser, AST, semântica e codegen.
- [ ] Definir build reproduzível com `build.zig`.
- [ ] Implementar CLI funcional e documentar seus argumentos.
- [ ] Completar o parser e a construção da AST.
- [ ] Completar a análise semântica e o sistema de tipos.
- [ ] Integrar o pipeline de compilação de ponta a ponta.
- [ ] Definir e validar o backend de geração de código.

## Fase 2 — Linguagem e runtime

- [ ] Formalizar sintaxe e semântica.
- [ ] Especificar ownership, lifetimes e operações `unsafe`.
- [ ] Definir contratos de allocators e falhas de alocação.
- [ ] Estabilizar FFI e layout compatível com C.
- [ ] Separar e validar as APIs de `kyn:core` e `kyn:std`.
- [ ] Criar runner de testes para fixtures `.kyn`.

## Fase 3 — Qualidade e portabilidade

- [ ] Adicionar CI para build, testes e formatação.
- [ ] Cobrir diagnósticos, entradas malformadas e casos de fronteira.
- [ ] Definir targets e matriz de plataformas suportadas.
- [ ] Criar testes de interoperabilidade e regressão.
- [ ] Documentar benchmarks reproduzíveis, sem alegações não verificadas.

## Fase 4 — Self-hosting e estabilidade

- [ ] Implementar o compilador em Kyn sem placeholders.
- [ ] Demonstrar bootstrap reproduzível usando o compilador anterior.
- [ ] Definir política de compatibilidade e versionamento da linguagem.
- [ ] Publicar releases com artefatos, checksums e notas de versão.

## Critério de conclusão

Uma etapa só deve ser considerada concluída quando o código correspondente existir, os testes forem executáveis e a documentação descrever o comportamento observado.
