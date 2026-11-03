# Testes

Três suítes automatizadas, todas executadas por `zig build check`:

| Comando | O que roda |
| --- | --- |
| `zig build test` | 26 testes unitários Zig (lexer, parser, AST, semântica, unsafe, codegen, driver, runner) |
| `zig build integration` | 105 fixtures `.kyn` de ponta a ponta |
| `zig build check` | as duas anteriores |

## Layout

```text
tests/
├── cases/         29 casos que compilam, executam e têm saída verificada
├── diagnostics/   26 casos que devem falhar com um código de diagnóstico específico
├── regression/    50 casos de código de saída (exit 1..50)
└── pending/       fixtures de recursos ainda não implementados (fora do build)
```

## Formato `.expect`

Cada `nome.kyn` tem um `nome.expect` irmão.

Caso executável:

```text
# comentário opcional
exit: 0            # código de saída esperado (padrão 0)
stdout: |          # saída esperada; linhas recuadas por dois espaços
  primeira linha   # \t \n \r \" \\ são interpretados
  segunda linha
```

Caso de diagnóstico (a compilação **deve** falhar com aquele código):

```text
error: E0013
```

Se `stdout:` for omitido, a saída do programa não é comparada — apenas o código de
saída.

## Como o runner funciona

`src/runner.zig` (executável `kyn-test`, criado por `zig build integration`):

1. lê cada `.kyn` e o `.expect` correspondente;
2. executa o pipeline completo **em processo** (`src/driver.zig`), sem passar pela
   CLI;
3. para casos de diagnóstico, exige falha e a presença do código esperado;
4. para casos executáveis, grava o C em `.zig-cache/integration/`, invoca o
   compilador C de `--cc` (padrão `cc`), executa o binário e compara código de
   saída e stdout;
5. imprime `ok`/`FAIL` por caso e um resumo; sai com `1` se houver falha.

O backend precisa de um compilador C99 no `PATH`. Para usar outro:

```sh
zig build integration -Dcc=clang
```

## Cobertura atual

**`tests/cases/`** — saída básica, aritmética e precedência, mutabilidade,
`if`/`while`/`break`/`continue`, `for i in a..b`, recursão, structs com métodos e
funções associadas, enums, casts, strings e escapes, operadores lógicos e bit a bit,
referências e ponteiros crus com `unsafe`, FFI com `puts`/`printf`, código de saída,
atributos `#[repr(C)]`/`#[align(8)]`, shadowing, structs por referência (`&`/`&mut`),
`print`/`println` por tipo, imports e `fn main -> void`.

**`tests/diagnostics/`** — um caso por código: E0001 (sintaxe), E0002 (string não
terminada, caractere inválido, entrada malformada), E0010, E0011, E0012, E0013
(incluindo literal fora do intervalo), E0014 (incluindo `&mut` de binding imutável),
E0015 (ponteiro cru e `extern fn` fora de `unsafe`), E0016 (caminho sem retorno e
assinatura de `main`), E0017, E0018, E0019, E0020, E0021, E0022 e E0023.

**`tests/regression/`** — `exit_01.kyn` … `exit_50.kyn`, cada um devolvendo o próprio
número como código de saída.

## Adicionando um caso

1. Crie `tests/cases/NN_nome.kyn` (ou `tests/diagnostics/dNN_nome.kyn`).
2. Crie o `.expect` irmão.
3. Rode `zig build integration` e cole o resultado no pull request.

Fixtures de recursos ainda não implementados vão para `tests/pending/` com o motivo
registrado em [`pending/README.md`](pending/README.md).
