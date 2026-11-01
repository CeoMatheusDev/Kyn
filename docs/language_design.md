# Princípios de design da linguagem Kyn

**Status:** proposta de design — não normativa e ainda não implementada integralmente.

Este documento registra a direção pretendida para Kyn. Os exemplos são ilustrativos: não devem ser tratados como código compilável até que cada construção esteja definida na especificação, implementada no compilador e coberta por testes.

## Identidade

Kyn é concebida como uma linguagem de programação de sistemas, com sintaxe moderna e controle explícito sobre recursos. O objetivo é combinar previsibilidade de baixo nível com mecanismos estáticos de segurança e abstrações cujo custo possa ser entendido pelo programador.

## Princípios

1. **Desempenho previsível:** evitar custos de runtime ocultos e permitir que o programador entenda o custo das abstrações.
2. **Controle explícito de recursos:** alocação, liberação e duração de recursos devem ter contratos claros.
3. **Tipagem estática:** tipos e conversões devem ser verificados antes da geração de código.
4. **Segurança por construção:** prevenir erros de memória e concorrência quando possível por análise estática, sem prometer garantias ainda não implementadas.
5. **Interoperabilidade:** permitir integração com C por meio de contratos explícitos de layout e ABI.
6. **Runtime mínimo:** manter o runtime pequeno e evitar dependências obrigatórias de garbage collector.
7. **Portabilidade controlada:** separar primitivas independentes de sistema operacional de interfaces específicas de plataforma.
8. **Abstrações de custo explícito:** abstrações de alto nível não devem esconder alocações, cópias ou sincronização relevantes.

## Diretrizes de linguagem

| Área | Direção proposta | Estado |
| --- | --- | --- |
| Tipagem | Estática, com inferência limitada e explícita | Proposto |
| Inteiros | Larguras fixas e tipos dependentes da arquitetura | Proposto |
| Funções | Declaração com `fn` e retorno `-> Type` | Proposto |
| Mutabilidade | `let` imutável e `var` mutável | Proposto |
| Agregados | `struct` e `enum` | Proposto |
| Métodos | Blocos `impl` | Proposto |
| Módulos | Importações explícitas | Experimental / em definição |
| Memória | Allocators explícitos e ausência de GC como objetivo | Proposto |
| Referências | Borrowing compartilhado e mutável | Proposto |
| Ponteiros crus | Acesso de baixo nível em contexto auditável | Proposto |
| Erros | Tipos explícitos como `Result<T, E>` | Proposto |
| Concorrência | Segurança de compartilhamento e mutabilidade como requisito de projeto | Planejado |
| Metaprogramação | Avaliação em compilação (`comptime`) | Planejado |

## Segurança e contexto unsafe

Operações que possam violar invariantes — por exemplo, dereferenciar ponteiros crus, realizar aritmética de ponteiros ou chamar interfaces externas sem contrato verificado — devem ser delimitadas por um contexto explícito `unsafe`.

A palavra-chave, suas regras e as obrigações do programador ainda não estão formalizadas. A existência de um bloco `unsafe` não deve ser interpretada como garantia automática de segurança fora dele.

## Modelo de compilação pretendido

O pipeline de referência é:

```text
Fonte .kyn
   |
 Lexer
   |
 Parser
   |
 AST
   |
 Resolução de nomes e análise semântica
   |
 HIR
   |
 MIR
   |
 Otimizações
   |
 Backend
   |
 Objeto / executável
```

HIR e MIR são estágios arquiteturais propostos. A implementação atual do repositório ainda não oferece esse pipeline completo.

## Critérios para promover uma proposta a recurso estável

Uma construção só deve ser considerada parte estável da linguagem quando houver:

- gramática normativa e não ambígua;
- regras semânticas, incluindo conversões e casos de erro;
- implementação no frontend e backend;
- testes positivos, negativos e de fronteira;
- diagnósticos documentados;
- decisões sobre ABI, layout e compatibilidade, quando aplicável;
- atualização da versão da especificação e do changelog.

## Relação com a implementação

Consulte [status.md](status.md) para distinguir o que existe no repositório do que está apenas planejado. A especificação geral está em [spec.md](spec.md), e os exemplos sintáticos estão em [language_reference.md](language_reference.md).
