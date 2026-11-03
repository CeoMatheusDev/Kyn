# Documentação do Kyn

Esta pasta concentra a documentação técnica do projeto. Os documentos distinguem explicitamente comportamento observado no código, propostas de linguagem e funcionalidades planejadas.

## Índice

| Documento | Conteúdo |
| --- | --- |
| [Arquitetura](architecture.md) | Componentes do compilador bootstrap e organização dos módulos |
| [Estado de implementação](status.md) | O que está presente, parcial ou ausente |
| [Desenvolvimento](development.md) | Requisitos, comandos de teste e fluxo de contribuição |
| [Especificação](spec.md) | Princípios e decisões de linguagem ainda em evolução |
| [Referência da linguagem](language_reference.md) | Exemplos de sintaxe `.kyn`, tipos, funções, memória, erros e módulos |
| [Princípios de design](language_design.md) | Identidade, requisitos e diretrizes arquiteturais da linguagem |
| [Gramática lexical](grammar.ebnf) | Regras lexicais implementadas pelo lexer |
| [Gramática sintática](syntax.ebnf) | Gramática do subconjunto implementado (normativa para 0.4.0-alpha.1) |
| [Modelo de memória](memory_model.md) | Diretrizes propostas para memória, ownership e FFI |
| [Testes e fixtures](../tests/README.md) | Suítes, formato `.expect` e cobertura |

## Convenções

Atualizado em 2026-11-03 para o compilador 0.4.0-alpha.1.

- **Implementado:** comportamento verificável na implementação atual.
- **Parcial:** existe código inicial, mas o fluxo não está completo.
- **Proposto:** decisão de projeto ainda não implementada ou validada.
- **Planejado:** item de roadmap, sem garantia de entrega.

A documentação deve acompanhar o código. Quando houver divergência, registre a divergência e atualize a documentação após confirmar o comportamento real.
