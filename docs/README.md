# Documentação do Kyn

Esta pasta concentra a documentação técnica do projeto. Os documentos distinguem explicitamente comportamento observado no código, propostas de linguagem e funcionalidades planejadas.

## Índice

| Documento | Conteúdo |
| --- | --- |
| [Diretrizes de design](language_design.md) | Objetivos de desempenho, baixo nível, segurança, modernidade e decisões pendentes |
| [Arquitetura](architecture.md) | Componentes do compilador bootstrap e organização dos módulos |
| [Estado de implementação](status.md) | O que está presente, parcial ou ausente |
| [Desenvolvimento](development.md) | Requisitos, comandos de teste e fluxo de contribuição |
| [Especificação](spec.md) | Princípios e decisões de linguagem ainda em evolução |
| [Gramática](grammar.ebnf) | Gramática lexical mínima documentada |
| [Modelo de memória](memory_model.md) | Diretrizes propostas para memória, ownership e FFI |

## Convenções

- **Implementado:** comportamento verificável na implementação atual.
- **Parcial:** existe código inicial, mas o fluxo não está completo.
- **Proposto:** decisão de projeto ainda não implementada ou validada.
- **Planejado:** item de roadmap, sem garantia de entrega.

A documentação deve acompanhar o código. Quando houver divergência, registre a divergência e atualize a documentação após confirmar o comportamento real.
