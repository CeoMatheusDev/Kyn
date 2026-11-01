# Modelo de memória

**Estado:** diretrizes de projeto; não constitui uma garantia formal da implementação atual.

O Kyn pretende oferecer controle explícito sobre memória e recursos, com foco em sistemas de baixo nível. O modelo definitivo ainda precisa ser especificado e validado pelo compilador.

## Objetivos

- Não depender de garbage collector.
- Tornar alocação e liberação de recursos explícitas.
- Permitir allocators escolhidos pelo programa.
- Oferecer operações de baixo nível em contextos delimitados e auditáveis.
- Permitir interoperabilidade com C quando o layout e a ABI forem especificados.

## Conceitos em avaliação

### Allocators

O código em `std/core/arena.kyn` apresenta um protótipo de arena com buffer e offset. Ele não deve ser considerado uma implementação segura ou completa: verificações de overflow, limites, alinhamento, falhas de alocação e contratos de vida útil ainda precisam ser definidos.

### Operações unsafe

Operações que possam violar invariantes de memória devem ser explicitamente delimitadas. A semântica exata de `unsafe`, suas obrigações e o que o compilador verifica ainda precisam de especificação.

### Layout e ABI

Atributos como `#[repr(C)]`, alinhamento e empacotamento são objetivos de interoperabilidade. A compatibilidade só poderá ser garantida após testes de layout e integração com toolchains C suportadas.

### Ownership e aliasing

Ownership, move semantics e regras de aliasing são tópicos de projeto. Não há, no estado atual, evidência suficiente para afirmar que o compilador impõe essas garantias de ponta a ponta.

## Requisitos para estabilização

- Regras formais de ownership e empréstimo, se adotadas.
- Definição de lifetime e validade de referências.
- Regras para ponteiros crus e aritmética de ponteiros.
- Garantias de alinhamento e tamanho de tipos.
- Comportamento em caso de falha de alocação.
- Testes de segurança, regressão e interoperabilidade ABI.
