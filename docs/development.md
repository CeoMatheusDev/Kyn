# Desenvolvimento

## Requisitos

- **Zig 0.17.0** — versão declarada em `build.zig.zon` (`minimum_zig_version`).
- Um compilador **C99** (`cc`, `gcc` ou `clang`) para `kyn run` e para a suíte de
  integração.
- Git.

```sh
zig version   # 0.17.0
cc --version
```

## Clonar e compilar

```sh
git clone https://github.com/CeoMatheusDev/Kyn.git
cd Kyn
zig build              # instala zig-out/bin/kyn
```

## Alvos do build

| Comando | O que executa |
| --- | --- |
| `zig build` | compila a CLI `kyn` em `zig-out/bin/kyn` |
| `zig build test` | 27 testes unitários (lexer, parser, AST, semântica, unsafe, codegen, driver, runner) |
| `zig build integration` | compila e executa as 122 fixtures de `tests/cases`, `tests/diagnostics` e `tests/regression` |
| `zig build check` | `test` + `integration` |
| `zig build run -- <args>` | executa a CLI (ex.: `zig build run -- check tests/cases/01_hello.kyn`) |

Opções úteis:

```sh
zig build integration -Dcc=clang      # usa outro compilador C na suíte
zig build -Doptimize=ReleaseFast      # modo de otimização da CLI
```

A suíte de integração grava o C intermediário e os binários em
`.zig-cache/integration/` (fora do controle de versão).

## Usando a CLI

```sh
zig-out/bin/kyn check  programa.kyn      # só frontend
zig-out/bin/kyn emit   programa.kyn      # C em stdout
zig-out/bin/kyn build  programa.kyn -o programa.c
zig-out/bin/kyn run    programa.kyn      # compila com cc e executa
zig-out/bin/kyn run    programa.kyn --emit-c /tmp/programa.c
zig-out/bin/kyn tokens programa.kyn      # depuração do lexer
zig-out/bin/kyn ast    programa.kyn      # depuração do parser
```

`--warn-unused` ativa `W0001`; `--no-main` remove a exigência de `fn main`.

## Onde tocar para cada mudança

| Mudança | Arquivos | Teste mínimo |
| --- | --- | --- |
| Novo token ou operador | `src/lexer/lexer.zig` (+ `Kind.text`) | `zig build test` |
| Nova sintaxe | `src/parser/parser.zig`, `src/ast/ast.zig` | caso em `tests/cases/` |
| Nova regra de tipo | `src/sema/sema.zig`, `src/sema/types.zig` | fixture em `tests/diagnostics/` |
| Novo atributo | `src/sema/unsafe.zig` | fixture em `tests/cases/` |
| Nova forma de código | `src/codegen/c.zig` | caso em `tests/cases/` com saída esperada |
| Novo comando de CLI | `src/main.zig` (+ `help_text`) | execução manual documentada no PR |
| Novo módulo/passo | `src/root.zig`, `src/driver.zig`, `build.zig` | `zig build check` |

## Fixtures da linguagem

Cada fixture `.kyn` tem um arquivo `.expect` irmão. O formato está documentado em
[tests/README.md](../tests/README.md). Fixtures de recursos ainda não implementados
ficam em `tests/pending/` com o motivo registrado em `tests/pending/README.md`.

## Fluxo recomendado

1. Crie uma branch de trabalho.
2. Faça uma alteração pequena e focada.
3. Adicione ou atualize a fixture/teste que cobre o comportamento.
4. Execute `zig build check` e cole o resultado no pull request.
5. Atualize a documentação se mudar sintaxe, semântica, códigos de diagnóstico,
   memória, ABI ou comandos.
6. Declare explicitamente o que **não** foi validado.

## Integração contínua

`.github/workflows/ci.yml` roda em cada push em `main` e em cada pull request:

| Plataforma | O que roda |
| --- | --- |
| `ubuntu-latest` | `zig build test`, `zig build integration`, build da CLI e smoke test |
| `macos-latest` | idem |
| `windows-latest` | `zig build test` e build da CLI |

O Windows fica sem a suíte de integração porque ela precisa de um compilador C99
chamado `cc` no `PATH`, e os runners do Windows trazem apenas o MSVC (`cl`). Quando
houver um `cc` configurado lá (MSYS2/MinGW, por exemplo), basta incluir a plataforma
na matriz com `integration: true`.

O workflow fixa o Zig em `0.17.0` via `mlugg/setup-zig@v2` — a mesma versão declarada
em `build.zig.zon`.

## Convenções de implementação

- Toda alocação do compilador vem da arena do pipeline (`init.arena`/`init.gpa` na
  CLI); nenhum componente guarda alocações entre execuções.
- Prefira `Span` (offsets na origem) a cópias de strings em diagnósticos.
- Diferencie erro léxico (E0002), sintático (E0001) e semântico (E001x): eles têm
  origens e recuperações diferentes.
- O backend **não** analisa tipos: ele confia nos `type_id` preenchidos pela
  semântica. Se um `type_id` estiver ausente, o bug é da semântica.
- Recuperação de erro nunca pode deixar de consumir tokens: `Parser.synchronize`
  garante progresso para evitar laço infinito em entradas malformadas.
- Não introduza API de biblioteca padrão sem contrato, implementação e teste.
- Não marque recurso como concluído só porque existe um arquivo com o nome dele.

## Limitações conhecidas do ambiente de desenvolvimento

- A suíte de integração precisa de um compilador C; sem ele, `zig build integration`
  falha nos casos executáveis (os de diagnóstico continuam válidos).
- A suíte de integração não roda no Windows em CI (sem `cc` no `PATH`); lá só os
  testes unitários são executados automaticamente.
- Não há formatador/linter de `.kyn` nem de Zig configurado no repositório.
