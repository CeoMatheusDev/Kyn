# Kyn

**Kyn** é um projeto experimental de linguagem de programação de sistemas, desenvolvido com foco em controle explícito de recursos, interoperabilidade com C e compilação de baixo nível.

O repositório reúne um protótipo de compilador escrito em Zig, experimentos de implementação da linguagem Kyn, módulos iniciais de biblioteca padrão e testes/fixtures. O projeto ainda está em desenvolvimento: a implementação disponível não corresponde a uma linguagem estável ou pronta para produção.

> **Estado atual:** protótipo em estágio inicial. Interfaces, sintaxe, semântica e comandos de build ainda podem mudar.

## Objetivos de projeto

- Controle explícito de alocação e ciclo de vida de memória.
- Ausência de garbage collector como objetivo de projeto.
- Interoperabilidade com C e possibilidade de uso em sistemas de baixo nível.
- Separação conceitual entre recursos essenciais (`kyn:core`) e recursos dependentes do sistema operacional (`kyn:std`).
- Compilador com implementação bootstrap em Zig e, futuramente, componentes reimplementados em Kyn.

Esses itens descrevem objetivos e direção arquitetural; não devem ser interpretados como garantias de recursos já completos.

## Estado de implementação

| Área | O que existe no repositório | Estado |
| --- | --- | --- |
| Lexer | Lexer inicial em `src/lexer/lexer.zig` | Experimental |
| Parser e AST | Estruturas e parsing parcial em `src/parser/` e `src/ast/` | Experimental |
| Análise semântica | Estrutura inicial em `src/sema/` | Experimental |
| Geração de código | Emissor mínimo em `src/codegen/codegen.zig` | Experimental |
| Implementação em Kyn | Arquivos iniciais em `src/kyn/` e `src/compiler/` | Esqueleto / incompleto |
| Biblioteca padrão | Módulos iniciais em `std/` | Experimental |
| Testes | Testes Zig e arquivos de casos `.kyn` em `src/` e `tests/` | Parcial |

Consulte [o estado detalhado](docs/status.md) antes de depender de qualquer funcionalidade.

## Requisitos

- Zig **0.17.0**, conforme declarado pelos metadados e comentários atuais do projeto.
- Git para obter o código-fonte.

A versão do compilador Zig deve ser confirmada no ambiente antes de compilar. O repositório ainda não contém um `build.zig` nem um sistema de build unificado.

## Obtendo o código

```sh
git clone https://github.com/CeoMatheusDev/Kyn.git
cd Kyn
```

## Compilação e testes

Não há, no estado atual, um comando único de build ou uma CLI funcional documentada. Para executar isoladamente os testes Zig existentes:

```sh
zig test src/test_core.zig
zig test src/test_sema.zig
zig test src/test_codegen.zig
zig test src/test_std.zig
zig test src/test_unsafe.zig
```

Esses comandos executam apenas os arquivos de teste indicados; não representam uma validação completa do compilador, da biblioteca padrão ou dos arquivos `.kyn`.

A entrada `src/main.zig` é atualmente um ponto de entrada mínimo de bootstrap, não um compilador de produção. Os arquivos `.kyn` em `tests/` são fixtures/casos de teste e não devem ser considerados executáveis até existir um runner integrado.

## Estrutura do repositório

```text
.
├── docs/              # Especificação, gramática, arquitetura e guias
├── src/
│   ├── ast/           # Nós da AST
│   ├── codegen/       # Geração de código experimental
│   ├── compiler/      # Módulos iniciais escritos em Kyn
│   ├── ffi/           # Experimentos de interoperabilidade
│   ├── kyn/           # Protótipos do compilador em Kyn
│   ├── lexer/          # Lexer bootstrap em Zig
│   ├── parser/         # Parser bootstrap em Zig
│   └── sema/           # Análise semântica bootstrap
├── std/
│   ├── core/           # Primitivas independentes de SO (em desenvolvimento)
│   └── os/             # Integrações dependentes de SO (em desenvolvimento)
└── tests/              # Fixtures e casos de teste da linguagem
```

Os testes Zig ainda localizados diretamente em `src/test_*.zig` serão consolidados em uma estrutura própria quando os caminhos de importação e o fluxo de build forem padronizados.

## Documentação

- [Visão geral e arquitetura](docs/architecture.md)
- [Estado de implementação e limitações](docs/status.md)
- [Desenvolvimento, build e testes](docs/development.md)
- [Especificação em evolução](docs/spec.md)
- [Gramática lexical inicial](docs/grammar.ebnf)
- [Modelo de memória — proposta](docs/memory_model.md)
- [Roadmap](ROADMAP.md)
- [Histórico de alterações](CHANGELOG.md)
- [Como contribuir](CONTRIBUTING.md)

## Versionamento

A versão de desenvolvimento está em `VERSION`. O projeto usa SemVer e ainda não declara uma release estável. Consulte [a política de versionamento](docs/versioning.md) e o [changelog](CHANGELOG.md).

## Contribuindo

Contribuições são bem-vindas. Antes de abrir uma alteração, leia [CONTRIBUTING.md](CONTRIBUTING.md) e descreva claramente o comportamento que foi implementado e como foi verificado.

Não apresente protótipos, stubs ou objetivos do roadmap como funcionalidades concluídas.

## Licença

O projeto declara licenciamento duplo MIT e Apache-2.0. Consulte os arquivos de licença presentes no repositório e confirme os termos aplicáveis antes de redistribuir.
