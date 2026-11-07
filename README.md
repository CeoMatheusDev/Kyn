# Kyn

[![CI](https://github.com/CeoMatheusDev/Kyn/actions/workflows/ci.yml/badge.svg)](https://github.com/CeoMatheusDev/Kyn/actions/workflows/ci.yml)

**Kyn** é um projeto experimental de linguagem de programação de sistemas,
desenvolvido com foco em controle explícito de recursos, interoperabilidade com
C e compilação de baixo nível.

O repositório reúne um protótipo de compilador escrito em Zig, experimentos de
implementação da linguagem Kyn, módulos iniciais de biblioteca padrão e
testes/fixtures. O projeto ainda está em desenvolvimento: a implementação
disponível não corresponde a uma linguagem estável ou pronta para produção.

> **Estado atual:** protótipo em estágio inicial, com frontend integrado e
> backend nativo x86-64 validado por execução. Interfaces, sintaxe, semântica e
> comandos de build ainda podem mudar.

## Objetivos de projeto

- Controle explícito de alocação e ciclo de vida de memória.
- Ausência de garbage collector como objetivo de projeto.
- Interoperabilidade com C e possibilidade de uso em sistemas de baixo nível.
- Separação conceitual entre recursos essenciais (`kyn:core`) e recursos
  dependentes do sistema operacional (`kyn:std`).
- Compilador com implementação bootstrap em Zig e, futuramente, componentes
  reimplementados em Kyn.

Esses itens descrevem objetivos e direção arquitetural; não devem ser
interpretados como garantias de recursos completos.

## Estado de implementação

| Área | O que existe | Estado |
| --- | --- | --- |
| Build | `build.zig` + `build.zig.zon` (Zig 0.17.0) | Funcional, validado |
| CLI | `kync check` / `kync emit` (`--llvm`, `--asm`, `-o`, `--lib`) | Funcional para o subconjunto atual |
| Lexer | `src/lexer/lexer.zig` com tokens tipados e spans | Funcional, testado |
| Parser e AST | `src/parser/`, `src/ast/` para o subconjunto documentado | Funcional, testado |
| Módulos | `src/driver.zig` (`compilePath`): `import "arquivo.kyn";` resolvido no disco | Funcional; caminhos relativos ao arquivo importador |
| Análise semântica | `src/sema/` com escopos, tipos e mutabilidade | Funcional para `i32`/`bool`/`void` |
| Backend LLVM IR | `src/codegen/llvm.zig` derivado da AST | Aceito por `llvm-as` no CI (62/62 módulos) |
| Backend x86-64 | `src/codegen/x86_64.zig` (asm + `as`/`ld`) | Validado por execução |
| Implementação em Kyn | `src/kyn/`, `src/compiler/` | Esqueleto / placeholders |
| Biblioteca padrão | `std/` | Experimental |
| Testes | Unitários (`zig build test`), e2e (`zig build e2e`) e IR (`zig build validate-ir`) | 115 testes unitários (108 do compilador + 7 da std); 70 casos e2e; IR validado por `llvm-as` no CI |

Consulte [o estado detalhado](docs/status.md) e o
[subconjunto aceito hoje](docs/syntax.ebnf) antes de depender de qualquer
funcionalidade.

## Requisitos

- Zig **0.17.0** (verificado por `build.zig.zon`).
- Git.
- Opcional, para a suíte e2e nativa: `bash`, GNU `as` e GNU `ld` em Linux
  x86-64.

## Obtendo o código

```sh
git clone https://github.com/CeoMatheusDev/Kyn.git
cd Kyn
```

## Compilação e testes

```sh
zig build                  # gera zig-out/bin/kync
zig build test             # testes unitários (compilador + std experimental)
zig build e2e              # fixture -> assembly -> as/ld -> executa -> confere código
zig build validate-ir      # confere o LLVM IR com llvm-as/clang (se instalado)
```

Exemplo de uso:

```sh
cat > hello.kyn <<'KYN'
fn main() -> i32 {
    let resposta: i32 = 6 * 7;
    return resposta % 256;
}
KYN

zig-out/bin/kync check hello.kyn
zig-out/bin/kync emit --llvm hello.kyn -o hello.ll
zig-out/bin/kync emit --asm  hello.kyn -o hello.s
as hello.s -o hello.o && ld hello.o -o hello && ./hello; echo "saída: $?"
```

Um programa pode ser dividido em arquivos; cada `import` vem antes das funções e
o caminho é relativo ao arquivo que importa:

```sh
cat > util.kyn <<'KYN'
fn dobro(x: i32) -> i32 {
    return x * 2;
}
KYN
cat > app.kyn <<'KYN'
import "util.kyn";

fn main() -> i32 {
    return dobro(21);
}
KYN
zig-out/bin/kync check app.kyn
zig-out/bin/kync emit --asm app.kyn -o app.s
```

Ciclos, arquivos ausentes e funções repetidas entre arquivos são diagnosticados
com `arquivo:linha:coluna` do arquivo de origem.

`kync` retorna `0` em sucesso, `1` para erros de compilação, `2` para uso
inválido e `3` para falhas de E/S. Detalhes em
[docs/development.md](docs/development.md).

Os arquivos `.kyn` em `tests/` cobrem tanto o subconjunto suportado
(`tests/integration/`, `tests/e2e/`) quanto casos de linguagem ainda **não**
implementados (por exemplo `impl`, `Result<T, E>`, `unsafe`). Não interprete a
quantidade de fixtures como cobertura de recursos.

## Estrutura do repositório

```text
.
├── build.zig            # build, testes e e2e
├── build.zig.zon
├── docs/                # arquitetura, status, gramáticas e visão de linguagem
├── src/
│   ├── ast/             # nós da AST
│   ├── codegen/         # interface de backend, LLVM IR e x86-64
│   ├── compiler/        # módulos iniciais escritos em Kyn (placeholders)
│   ├── ffi/             # experimentos de interoperabilidade
│   ├── kyn/             # protótipos do compilador em Kyn (placeholders)
│   ├── lexer/           # lexer bootstrap
│   ├── parser/          # parser bootstrap
│   ├── sema/            # análise semântica e política de unsafe
│   ├── driver.zig       # pipeline integrado
│   ├── diagnostics.zig  # diagnósticos e renderização
│   ├── span.zig         # localização na fonte
│   └── main.zig         # CLI kync
├── std/
│   ├── core/            # primitivas independentes de SO (experimental)
│   └── os/              # integrações dependentes de SO (experimental)
├── tests/               # fixtures da linguagem (integração, e2e, fuzz...)
└── tools/e2e.sh         # validação de ponta a ponta nativa
```

## Documentação

- [Visão geral e arquitetura](docs/architecture.md)
- [Estado de implementação e limitações](docs/status.md)
- [Desenvolvimento, build, CLI e testes](docs/development.md)
- [Especificação em evolução](docs/spec.md)
- [Referência preliminar da linguagem `.kyn`](docs/language_reference.md)
- [Princípios de design da linguagem](docs/language_design.md)
- [Gramática lexical implementada](docs/grammar.ebnf)
- [Gramática sintática do subconjunto aceito](docs/syntax.ebnf)
- [Modelo de memória — proposta](docs/memory_model.md)
- [Roadmap](ROADMAP.md)
- [Histórico de alterações](CHANGELOG.md)
- [Como contribuir](CONTRIBUTING.md)

## Contribuindo

Contribuições são bem-vindas. Antes de abrir uma alteração, leia
[CONTRIBUTING.md](CONTRIBUTING.md) e descreva claramente o comportamento
implementado e como foi verificado (`zig build test`, `zig build e2e`).

Não apresente protótipos, stubs ou objetivos do roadmap como funcionalidades
concluídas.

## Licença

O projeto declara licenciamento duplo MIT e Apache-2.0. Consulte os arquivos de
licença presentes no repositório e confirme os termos aplicáveis antes de
redistribuir.
