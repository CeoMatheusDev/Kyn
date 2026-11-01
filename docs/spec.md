# Especificação da linguagem Kyn

**Estado:** documento de projeto em evolução, não uma especificação normativa congelada.

Este documento registra objetivos e decisões preliminares. A sintaxe e a semântica devem ser consideradas experimentais até que estejam implementadas, testadas e versionadas formalmente.

## Objetivos

- Linguagem voltada a sistemas e software de baixo nível.
- Controle explícito de alocação e ciclo de vida de recursos.
- Sem garbage collector como objetivo de projeto.
- Interoperabilidade com C por meio de uma ABI documentada.
- Separação entre funcionalidades essenciais e funcionalidades dependentes do sistema operacional.
- Tratamento explícito de erros, com a proposta de tipos como `Result<T, E>`.

## Diretrizes propostas

| Tema | Diretriz | Situação |
| --- | --- | --- |
| Memória | Alocação explícita e allocators visíveis | Proposto |
| Segurança | Uso delimitado de operações `unsafe` | Proposto |
| Layout | Atributos de representação e alinhamento | Proposto |
| FFI | Interoperabilidade com ABI C | Experimental |
| Erros | Tipos de resultado em vez de exceções | Proposto |
| Metaprogramação | Recursos `comptime` | Planejado |
| Módulos | Importação e organização modular | Experimental |

## Sintaxe e gramática

A [referência preliminar da linguagem](language_reference.md) reúne exemplos ilustrativos de arquivos `.kyn`. Os [princípios de design](language_design.md) registram os objetivos arquiteturais. A gramática em [grammar.ebnf](grammar.ebnf) descreve apenas um subconjunto lexical inicial observado no lexer; [syntax.ebnf](syntax.ebnf) é um esboço sintático proposto e ainda não normativo. Nenhum desses documentos deve ser interpretado como prova de que a sintaxe correspondente já é aceita pelo compilador.

## Modelo de memória

Consulte [memory_model.md](memory_model.md). As regras ali descritas são objetivos de projeto e não garantias formais já implementadas.

## Processo de evolução

Uma funcionalidade só deve ser promovida a parte estável da linguagem quando possuir:

1. Definição sintática e semântica não ambígua.
2. Implementação no compilador.
3. Testes positivos e negativos.
4. Documentação de erros e casos de fronteira.
5. Compatibilidade ou política explícita de breaking changes.

A versão da linguagem e a versão do compilador devem ser identificadas separadamente quando o versionamento formal for adotado.
