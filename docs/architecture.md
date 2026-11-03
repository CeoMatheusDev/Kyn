# Arquitetura

## Visão geral

O compilador bootstrap é escrito em Zig 0.17 e organizado como um módulo único
(`kyn`, raiz em `src/root.zig`) mais dois executáveis: a CLI (`src/main.zig`) e o
runner de integração (`src/runner.zig`).

```text
             fonte .kyn
                 │
                 ▼
        ┌──────────────────┐
        │  lexer/lexer.zig │  tokens + Span, diagnósticos E0002, recuperação
        └──────────────────┘
                 │  []Token
                 ▼
        ┌──────────────────┐
        │ parser/parser.zig│  precedência completa, diagnósticos E0001, synchronize()
        └──────────────────┘
                 │  ast.Program
                 ▼
        ┌──────────────────┐
        │   sema/sema.zig  │  2 passadas: declarações → corpos
        │  sema/types.zig  │  tipos internados, TypeId nos nós da AST
        │ sema/unsafe.zig  │  contexto unsafe + atributos
        └──────────────────┘
                 │  AST anotada com TypeId
                 ▼
        ┌──────────────────┐
        │  codegen/c.zig   │  C99 autocontido
        └──────────────────┘
                 │  texto .c
                 ▼
      cc/gcc/clang → binário
```

`src/driver.zig` é o único orquestrador: encadeia os estágios, decide onde parar e
devolve `Result{ .ok = Output | .failure }`. Falha de compilação **não** é exceção:
ela é representada pelos diagnósticos acumulados na `diag.List` do chamador.

## Componentes

### `src/diag.zig` — diagnósticos

`Span` (offsets), `LineMap` (offset → linha/coluna), `Code` (códigos estáveis
`E0001`…`W0001`) e `List.render`, que produz o formato:

```text
error[E0013]: mismatch de tipos: esperado `i32`, encontrado `str`
  --> t.kyn:1:14
   |
1 | let x: i32 = "texto";
   |              ^^^^^^
```

### `src/lexer/lexer.zig` — tokenizer

Palavras-chave, identificadores, inteiros (decimal, `0x`, `0o`, `0b`, `_`),
flutuantes (com expoente), strings com escapes (`\n \t \r \0 \\ \" \' \xNN`), chars e
todos os operadores. Comentários `//` e `/* … */` (aninháveis) são descartados.
Tokens mantêm slices da origem — a única alocação é o valor desescapado de
strings/chars. Erros léxicos viram `E0002` e a tokenização **continua**, para que o
parser ainda reporte o resto do arquivo.

### `src/parser/parser.zig` — parser

Recursivo-descendente com *binding powers* para expressões (todos associativos à
esquerda). A recuperação de erro é feita por `synchronize()`, que sempre consome ao
menos um token — invariantes de progresso evitam laço infinito em entradas
malformadas. O parser **não** resolve nomes nem tipos; ele apenas constrói a AST.

### `src/ast/ast.zig` — AST

Nós alocados na arena do pipeline e vivos até o fim da compilação. `Block.stmts`,
`Program.decls` e `ImplDecl.methods` são slices de elementos **mutáveis** porque a
semântica anota `Expr.type_id` no lugar, evitando uma segunda árvore.

### `src/sema/` — análise semântica

- `types.zig`: tipos internados por valor; `Id` é índice + 1 e `invalid` (0) marca
  "não resolvido". Comparação estrutural recursiva; `describe` gera nomes legíveis.
- `unsafe.zig`: `Context` (profundidade de blocos `unsafe`) e validação de atributos
  `#[repr(C)]` / `#[align(N)]`.
- `sema.zig`: duas passadas.
  1. **Declarações** — registra structs, enums, funções, `extern fn` e métodos, e
     resolve campos depois que todos os tipos existem (ordem irrelevante, recursão
     permitida).
  2. **Corpos** — escopos empilhados com shadowing entre escopos, tipagem de
     expressões com tipo esperado propagado (literais se adaptam ao contexto),
     mutabilidade por *lugar* (binding `var` **ou** acesso via `&mut`/ponteiro não
     `const`), caminhos de retorno, `break`/`continue`, aridade, `unsafe`.

### `src/codegen/c.zig` — backend C99

Consome a AST anotada; **não** repete análise de tipos. Mapeamentos principais:

| Kyn | C |
| --- | --- |
| `i32`, `u64`, `isize` | `int32_t`, `uint64_t`, `intptr_t` (via typedefs `kyn_*`) |
| `f32`, `f64`, `bool`, `char` | `float`, `double`, `bool`, `char` |
| `str` | `const char *` |
| `*u8`, `*const u8` | `char *`, `const char *` (compatível com cabeçalhos do sistema) |
| `&T`, `&mut T`, `*T` | `T *` |
| `[N]T` | `T nome[N]` (sintaxe de declarador) |
| `[]T`, `[]const T` | `typedef struct { T *data; size_t len; } KynSlice_I32;` (um por tipo de elemento) |
| `xs[i]` | `((xs)[i])` em array, `((xs).data[i])` em slice |
| `xs[lo..hi]` | literal composto `(KynSlice_T){ ptr + lo, hi - lo }` |
| `xs.len` | constante `N` em array, `((xs).len)` em slice |
| `struct Ponto` | `struct KynPonto` |
| `enum Cor { Vermelho }` | `enum { KynCor_Vermelho }` |
| método `Ponto::soma(self)` | `KynPonto_soma(const KynPonto *kyn_self)` |
| `print`/`println` | `printf` com formato escolhido pelo tipo estático |
| `#[align(8)]` | `__attribute__((aligned(8)))` quando disponível |

Nomes de tipos ganham o prefixo `Kyn` e símbolos de função ganham `kyn_`, evitando
colisão com palavras reservadas do C. `extern fn` preserva o nome C original para
linkar contra a libc.

Arrays e slices seguem o modelo do C: parâmetros `[N]T` decaem para `[]T` na análise
semântica (nó `to_slice` na AST, inserido pela semântica e nunca pelo parser), e o
backend emite um literal composto. **Não há verificação de limites**: `xs[i]` e
`xs[lo..hi]` viram acesso direto, como em C.

### `src/main.zig` — CLI

Parsing de argumentos próprio, códigos de saída documentados, `run` delegando a `cc`
e propagando o código do programa.

### `src/runner.zig` — suíte de integração

Compila em processo (via `driver`), grava o C, invoca `cc`, executa e compara saída e
código de saída; para fixtures de diagnóstico, exige falha com o código esperado.

## Decisões e invariantes

1. **Uma arena por compilação.** Nada é liberado no meio do pipeline; a CLI descarta
   a arena ao terminar.
2. **Diagnósticos são o único canal de erro de compilação.** Estágios param no
   primeiro conjunto de erros; nada de "meia AST" chegando ao backend.
3. **Spans sempre.** Toda mensagem aponta um intervalo da origem; nada de só linha.
4. **Backend burro, semântica esperta.** O codegen não decide tipos; se o C gerado
   estiver errado, a causa está na AST anotada.
5. **Progresso garantido no parser.** `synchronize()` consome ao menos um token.
6. **Nenhuma API de runtime escondida.** O C gerado depende apenas de libc padrão
   (`stdint.h`, `stdbool.h`, `stddef.h`, `stdio.h`).

## Próximas decisões arquiteturais

1. CI executando `zig build check` em Linux/macOS/Windows.
2. Backend próprio (LLVM IR ou código de máquina) para remover a dependência de `cc`.
3. Modelo de ownership/moves e borrow checking — hoje só há tipagem de referências.
4. Slices/arrays e a semântica de `str` (hoje `const char *` sem comprimento).
5. Resolução real de módulos e uma `kyn:core`/`kyn:std` ligada ao compilador.
6. Testes de fuzzing contínuo sobre o frontend (a fixture malformada atual cobre
   apenas o caminho de recuperação).
