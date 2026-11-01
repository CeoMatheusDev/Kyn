# Diretrizes de design da linguagem

**Estado:** proposta arquitetural em discussão. Este documento registra a direção desejada para Kyn; não afirma que os recursos descritos já estejam implementados nem que todas as decisões estejam congeladas.

## Visão

Kyn pretende ser uma linguagem de programação de sistemas que combine:

- **Alto desempenho:** abstrações de custo zero sempre que viáveis, representação de dados previsível e controle de alocações.
- **Programação de baixo nível:** acesso explícito a memória, ponteiros, layout, alinhamento, atomics e interoperabilidade ABI.
- **Segurança:** verificações estáticas e garantias em tempo de compilação, com operações que possam violar invariantes isoladas e auditáveis.
- **Modernidade:** sistema de tipos expressivo, generics, avaliação em tempo de compilação, módulos e diagnósticos úteis.

Esses objetivos precisam ser conciliados. Desempenho não deve depender de comportamento indefinido, e segurança não deve esconder custos relevantes ou retirar do programador o controle necessário para sistemas.

## Princípios

### 1. Desempenho previsível

A linguagem deve buscar:

- Sem garbage collector obrigatório.
- Sem runtime obrigatório para funcionalidades fundamentais.
- Abstrações de custo zero quando puderem ser implementadas sem custo em tempo de execução.
- Layout e representação de tipos documentáveis e controláveis.
- Alocação explícita ou com estratégia claramente identificável.
- Otimizações em tempo de compilação, incluindo constant evaluation e monomorfização quando apropriado.
- Ausência de alocações implícitas inesperadas em operações básicas.

Qualquer alegação de desempenho deverá ser sustentada por benchmarks reproduzíveis, com compilador, flags, target e metodologia registrados.

### 2. Controle de baixo nível

Kyn deverá permitir programação próxima ao hardware e ao sistema operacional, incluindo:

- Ponteiros e operações de ponteiro com regras bem definidas.
- Controle de mutabilidade, alinhamento e layout de dados.
- Integração com C ABI e FFI explicitamente especificadas.
- Operações atômicas e um modelo de memória formal.
- Interação com recursos de sistema operacional por interfaces modulares.
- Possibilidade de implementar estruturas de dados e allocators personalizados.

O acesso de baixo nível deve ser explícito, mas não precisa tornar inseguras todas as operações que o utilizam. O compilador deverá distinguir operações de baixo nível que preservam invariantes daquelas que exigem obrigações adicionais do programador.

### 3. Segurança por construção

A direção preferencial é **safe by default**: código comum deve permanecer dentro de regras verificáveis pelo compilador. Operações que possam quebrar invariantes deverão exigir uma fronteira explícita, por exemplo, um bloco ou função unsafe, cuja semântica e obrigações serão formalizadas.

Áreas que exigem especificação:

- Inicialização e validade de valores.
- Bounds checking e operações que possam ser comprovadamente eliminadas pelo compilador.
- Ownership, empréstimos e aliasing.
- Lifetimes e validade de referências.
- Ponteiros crus e aritmética de ponteiros.
- Concorrência, atomics e data races.
- FFI, layout e contratos entre linguagens.

O mecanismo unsafe não deve ser interpretado como ausência total de verificações: o contrato deverá indicar precisamente quais garantias deixam de ser provadas e quais responsabilidades passam ao programador.

### 4. Sistema de tipos e abstrações modernas

Recursos a avaliar e especificar:

- Tipos estáticos e inferência controlada.
- Generics com estratégia de implementação definida.
- Monomorfização quando adequada ao desempenho e à previsibilidade.
- Enums e pattern matching.
- Tipos de resultado explícitos para falhas recuperáveis.
- Avaliação em tempo de compilação.
- Módulos, namespaces e interfaces de interoperabilidade.

Cada recurso deverá ter semântica definida, impacto de compilação avaliado e testes de conformidade antes de ser considerado estável.

## Modelo de memória — direção proposta

A direção preferencial combina:

1. Ownership e transferência explícita de propriedade.
2. Empréstimos compartilhados e exclusivos com regras de aliasing verificáveis.
3. Lifetimes inferidos quando isso não comprometer clareza ou diagnósticos.
4. Allocators selecionáveis e contratos explícitos de alocação.
5. Ponteiros crus e operações manuais disponíveis em contextos de baixo nível delimitados.
6. Nenhuma dependência de garbage collector para gerenciamento fundamental de memória.

Ainda é necessário decidir se o modelo será obrigatório em todo código seguro, como interoperará com memória externa e quais operações serão permitidas em contextos unsafe. Consulte [Modelo de memória](memory_model.md).

## Arquitetura pretendida do compilador

A arquitetura deve separar frontend, análise semântica, representação intermediária e backend:

~~~text
Source
  |
  v
Lexer -> Parser -> AST
                    |
                    v
              Name resolution
                    |
                    v
                Type check
                    |
                    v
          Ownership / lifetime checks
                    |
                    v
                   HIR
                    |
                    v
                   MIR
                    |
                    v
           Optimization passes
                    |
                    v
              Backend interface
                 /       \
              LLVM      Native
~~~

HIR e MIR são propostas de arquitetura, não componentes atualmente implementados. A MIR deverá permitir verificações e transformações independentes do backend. O backend LLVM pode ser uma primeira implementação pragmática; a interface deve evitar acoplamento irreversível a um único backend. Um backend nativo próprio é uma possibilidade futura, não um compromisso de curto prazo.

## Runtime e biblioteca padrão

A proposta é manter o runtime pequeno, modular e opcional sempre que possível. Primitivas essenciais devem ser separadas de serviços dependentes do sistema operacional.

- **kyn:core:** conceitos e primitivas fundamentais, com dependências mínimas.
- **kyn:std:** abstrações e serviços de biblioteca, incluindo integrações de plataforma.

Allocators, memória, atomics, I/O e abstrações de sistema devem ter contratos claros. A biblioteca padrão não deve impor custos ou políticas de alocação invisíveis.

## Decisões ainda abertas

As seguintes escolhas precisam de RFCs ou especificações antes de congelar a linguagem:

| Tema | Direção atual | Questão pendente |
| --- | --- | --- |
| Segurança | Safe by default | Fronteiras exatas e semântica de unsafe |
| Memória | Ownership + borrowing + allocators | Regras formais, lifetimes e interoperabilidade manual |
| Backend | Independência de backend; LLVM como opção inicial | IR interna e contrato do backend |
| Generics | Monomorfização em avaliação | Restrições, code bloat e estratégia de compilação |
| Runtime | Mínimo e modular | Quais recursos exigem runtime |
| Erros | Result types explícitos em avaliação | Sintaxe, propagação e interoperabilidade |

Não tratar essas direções como decisões finais sem especificação, implementação e testes.

## Critérios para aceitar funcionalidades

Uma funcionalidade de linguagem deve ser aceita quando:

1. Sua sintaxe e semântica estiverem documentadas.
2. Seus custos de memória e execução forem compreendidos.
3. Suas interações com segurança e unsafe estiverem especificadas.
4. Existirem testes positivos, negativos e de casos de fronteira.
5. O comportamento estiver integrado ao pipeline de compilação.
6. As limitações e garantias estiverem descritas sem alegações não verificadas.

## Sequência recomendada

1. Estabelecer build reproduzível e testes automatizados do compilador.
2. Formalizar tokens, spans, AST e diagnósticos.
3. Completar parser e resolução de nomes.
4. Definir sistema de tipos e regras de mutabilidade.
5. Especificar ownership, borrowing, lifetimes e unsafe.
6. Introduzir HIR e MIR com invariantes verificáveis.
7. Implementar backend por uma interface independente.
8. Evoluir runtime, FFI e biblioteca padrão com testes de integração.
9. Medir desempenho com benchmarks reproduzíveis.

## Relação com o estado atual

O compilador presente no repositório é um protótipo inicial em Zig. A maior parte das capacidades descritas aqui ainda não existe ou não está integrada. Consulte [Estado de implementação](status.md) e [Roadmap](../ROADMAP.md) para distinguir objetivos de funcionalidades disponíveis.
