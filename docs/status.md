# Estado de implementação

Este documento descreve o que foi observado nos arquivos do repositório na revisão de 1 de novembro de 2026. Não é uma certificação de qualidade nem substitui a execução dos testes no ambiente de desenvolvimento.

## Resumo

O Kyn deve ser tratado como um **protótipo de linguagem e compilador**. O código disponível ainda não sustenta as afirmações de compilador self-hosted completo, release industrial estável ou linguagem pronta para produção.

## Evidências por componente

| Componente | Evidência observada | Avaliação |
| --- | --- | --- |
| Ponto de entrada Zig | `src/main.zig` apenas imprime mensagens | Placeholder |
| Lexer | `src/lexer/lexer.zig` tokeniza categorias básicas | Parcial |
| Parser | `src/parser/parser.zig` trata um caso simplificado e encerra após o primeiro statement | Parcial |
| AST | `src/ast/ast.zig` define poucos tipos de nó | Parcial |
| Semântica | `checkProgram` não percorre a árvore; declaração usa tipo default | Parcial |
| Codegen | `emitProgram` emite sempre o mesmo `main` | Stub |
| Self-hosting | `src/kyn/*.kyn` contém placeholders | Não demonstrado |
| Biblioteca padrão | Existem arquivos iniciais em `std/core` e `std/os` | Experimental |
| Build | Não há `build.zig` na raiz | Não padronizado |
| Testes | Existem testes Zig e fixtures `.kyn`; não há runner integrado demonstrado | Parcial |

## Divergências importantes

- O README anterior descrevia o projeto como estável e self-hosted. Os arquivos `src/kyn/main.kyn` e `src/kyn/lexer.kyn` ainda contêm placeholders.
- O changelog registra funcionalidades e marcos que não estão demonstrados pelo código bootstrap revisado. Um registro de changelog não substitui implementação nem teste.
- A gramática existente é uma descrição lexical mínima, não uma gramática completa da linguagem.
- O modelo de memória descreve objetivos, mas não comprova garantias de ownership, ausência de aliasing inválido ou ausência de vazamentos.
- A geração de código existente é fixa e não reflete a AST.

## Critérios mínimos para declarar uma versão estável

1. Build reproduzível e documentado em ambiente limpo.
2. CLI funcional com códigos de saída e mensagens de diagnóstico especificados.
3. Pipeline lexer → parser → AST → semântica → backend integrado.
4. Testes unitários, de integração e regressão executados automaticamente em CI.
5. Testes negativos para entradas inválidas e casos de fronteira.
6. Contratos de memória e FFI documentados e testados.
7. Implementação self-hosted comprovada por um bootstrap reproduzível, se essa continuar sendo uma meta.
8. Release com artefatos, checksums, notas e política de compatibilidade.

Até que esses critérios sejam atendidos, prefira os termos **experimental**, **parcial** e **em desenvolvimento**.
