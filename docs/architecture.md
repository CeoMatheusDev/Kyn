# Arquitetura

## Visão geral

O repositório contém dois conjuntos de código relacionados, em estágios
diferentes:

1. **Bootstrap em Zig** (`src/`): compilador funcional para um subconjunto da
   linguagem, com frontend integrado, dois backends e CLI.
2. **Protótipos em Kyn** (`src/kyn/`, `src/compiler/`): arquivos experimentais
   com placeholders, destinados a explorar a implementação do compilador na
   própria linguagem. Não são executados pelo `kync`.

A presença dos dois conjuntos não significa que exista pipeline self-hosted.

## Pipeline implementado

```text
Código-fonte .kyn
      |
      v
   Lexer  (tokens tipados + spans, sem cópia de texto)
      |
      v
   Parser (programa completo; falha no primeiro erro sintático)
      |
      v
   AST    (structs, funções, statements, expressões; slices da entrada)
      |
      v
 Semântica (escopos, tipos i32/bool/void, mutabilidade, slots de pilha)
      |
      v
  Backend (interface única)
      ├── LLVM IR textual   -> src/codegen/llvm.zig
      └── x86-64 System V   -> src/codegen/x86_64.zig  (as + ld -> executável)
```

O driver (`src/driver.zig`) executa o pipeline e centraliza a posse de memória:
uma arena por compilação guarda AST, tabela de símbolos, diagnósticos e saída do
backend; `Result.deinit()` libera tudo.

## Contratos entre estágios

- **Tokens**: `Tag` tipada, `text` como slice da entrada e `Span`
  (offset inicial/final, linha e coluna 1-based). Espaços e `// ...` não chegam
  ao parser; caracteres desconhecidos viram `.invalid` e são diagnosticados.
- **AST**: independente de decisões semânticas. Cada nó tem `span`; a semântica
  anota índices de resolução (`Expr.resolved`, `Stmt.decl_symbol`,
  `Stmt.Assign.resolved`, `Expr.Call.callee_fn`) sem alterar a estrutura.
- **Semântica**: produz `Checked` com assinaturas de funções, tipos de retorno,
  structs (campos e tipos), contagem de slots e uma tabela plana de símbolos.
  Erros não abortam a análise: são acumulados e o tipo `unknown` interrompe
  cascatas de diagnóstico. Structs entram em duas passadas (nomes, depois
  campos), para permitir referência em qualquer ordem.
- **Módulos**: `driver.compilePath` carrega o arquivo raiz e resolve cada
  `import` com `std.fs.path.resolveAlloc` a partir do diretório do arquivo
  importador; caminhos normalizados funcionam como chave de deduplicação. O
  grafo é percorrido em pré-ordem (raiz primeiro) e achatado em um único
  `ast.Program` — cada `ast.Function` carrega `file_id`, indexando
  `Result.sources` para atribuir diagnósticos ao arquivo certo. Ciclos,
  arquivos ausentes e nomes repetidos são diagnosticados antes do backend.
- **Backends**: recebem `*ast.Program` + `*sema.Checked` e devolvem texto
  alocado na arena. `codegen.Error` distingue AST inconsistente
  (`MiscompiledAst`), subconjunto não suportado (`UnsupportedNode`) e tipo sem
  representação (`UnsupportedType`).

## Componentes

### Lexer — `src/lexer/lexer.zig`

Palavras-chave, identificadores, inteiros decimais, operadores de um e dois
caracteres e pontuação. Mantém slices da entrada; nenhuma alocação por token.

### Parser — `src/parser/parser.zig`

Constrói o programa completo com precedência e associatividade documentadas em
`docs/syntax.ebnf`. Erros sintáticos registram diagnóstico com span e retornam
`error.ParseError`.

### Loader de módulos — `src/driver.zig`

`compilePath` mantém a pilha de DFS (detecção de ciclos), o conjunto de
caminhos já carregados e a lista de módulos na ordem de carregamento. Cada
módulo é lexado e parseado com o `current_file` correto nos diagnósticos; se
algum arquivo falhar, a compilação para com os diagnósticos já atribuídos. Não
há estado global: toda a memória vem da arena do `Result`.

### Structs (layout) — `src/sema/sema.zig` + backends

Um valor de struct é **nominal** (`Symbol.struct_id` → `Checked.structs`) e pode
atravessar chamadas **por valor** (Ciclo 9): um campo escalar = uma palavra de
registrador, na ordem de declaração.

- `Symbol.typ == .aggregate` reserva `1 + n` slots: o primeiro é a base
  (reservado) e cada campo usa `slot + 1 + índice`, na ordem da declaração.
- x86-64: cada slot tem 8 bytes; leitura/escrita de campo é `movl` no offset do
  slot, e a cópia de struct percorre os campos. Parâmetros chegam em um
  registrador por campo (`%rdi`, `%rsi`, …), chamadas empilham uma palavra por
  campo e desempilham na ordem inversa, e o **retorno** usa `%eax`, `%edx`,
  `%ecx`, `%r8d`, `%r9d`, `%r10d` (limite de 6 campos). Campos de literal são
  avaliados na pilha antes de irem para os registradores de retorno, para que
  um campo não clobbere o resultado do outro.
- LLVM IR: substituição escalar para armazenamento (um `alloca` por campo) e
  parâmetros **achatados** em argumentos escalares (`define i32 @f(i32 %arg0,
  i32 %arg1)` para `fn f(p: P)`); só o retorno é agregado (`{ i32, i1, … }`
  montado com `insertvalue` e lido com `extractvalue`). Nenhum
  `getelementptr` é necessário.
- `sema.registerWordsOf` é a fonte única do limite de **6 registradores**:
  conta 1 por campo de struct, 2 por `str` e 1 por escalar; vale para
  declaração, chamada e retorno de struct.
- Literais exigem todos os campos exatamente uma vez, o que garante struct
  sempre inicializado (sem estado parcialmente construído).

### Strings e saída de texto (`str`) — `print` + backends

`str` é uma **fatia estática**: ponteiro para bytes constantes + tamanho. Não é
escalar; existe para dar ao programa uma saída observável (texto) e preparar
`kyn:core` para E/S real.

- `Symbol.typ == .str` reserva dois slots consecutivos: `slot` guarda o
  ponteiro e `slot + 1` o tamanho (mesma convenção nos dois backends).
- **`str` por valor em chamadas** (Ciclo 8): parâmetros, argumentos e retornos
  levam dois registradores, sempre o ponteiro antes do tamanho. No x86-64 os pares
  são `(%rdi,%rsi)`, `(%rdx,%rcx)` e `(%r8,%r9)`; o retorno vem em `%rax`
  (ponteiro) e `%rdx` (tamanho). No IR os parâmetros viram `ptr %argN` +
  `i64 %argN+1` e o retorno é o agregado `{ ptr, i64 }` montado com
  `insertvalue` e lido com `extractvalue`. O limite de seis registradores é
  contado em **palavras de registrador** (`Type.registerWords()`): cada `str`
  ocupa dois, o que permite no máximo três `str` por assinatura.
- Literais de string são deduplicados por conteúdo (`codegen.StrPool`): cada
  texto distinto vira um único rótulo, com o número de referências livre.
- x86-64: bytes em `.section .rodata` como lista de `.byte` (sem escapes);
  `print` faz `write(1, ptr, len)` por syscall e uma segunda chamada para a
  quebra de linha (`.Lnl`). Não há dependência de libc.
- LLVM IR: cada texto vira `@.strN = private unnamed_addr constant [N x i8]`,
  `print` vira `call i64 @write(i32 1, ptr @.strN, i64 N)` com
  `declare i64 @write(i32, ptr, i64)`; o verificador do LLVM no CI aceita o IR.
- `print` e `print_i32` são embutidas (`ast.Expr.Call.builtin`), com a mesma
  regra: exatamente um argumento (`str`/`i32`), resultado `void` e quebra de
  linha ao final. Os nomes são reservados para funções declaradas na fonte, e
  um `let`/`var` com o resultado delas é diagnosticado (`void` não é
  armazenável).
- `print_i32` formata em decimal: no backend nativo a rotina `kyn_print_i32`
  (emitida uma única vez, em `.text`) divide por 10 com `divl` **unsigned** —
  depois de `negl`, INT_MIN vira `0x80000000` e o texto sai `-2147483648`;
  no IR, `@kyn_print_i32` faz o mesmo com `urem`/`udiv`, `select` para o módulo
  e um buffer `[12 x i8]` escrito de trás para frente. Nenhum dos dois usa
  `itoa`/libc no backend nativo nem estado global.
- Restrições desta etapa, todas diagnosticadas: campo de struct de tipo `str`,
  `str` em aritmética/condição/`==`/`!=` (comparar exigiria comparar bytes),
  `main` com retorno `str`, expressão `str` como statement e assinatura acima
  de seis registradores (`'str' ocupa dois`).

### Semântica — `src/sema/sema.zig`

- dois passos: assinaturas primeiro (permite recursão e chamadas antes da
  declaração), depois corpos;
- escopos aninhados com shadowing permitido e duplicidade diagnosticada no
  mesmo escopo;
- tipos `i32`, `bool`, `str`, `void` e structs nominais; operadores
  verificados por categoria;
- atribuição exige `var`;
- verificação estrutural de retorno (`alwaysReturns`) para funções não-void;
- validação de `fn main()` (sem parâmetros, retorno `i32` ou `void`);
- limite de 6 parâmetros/argumentos do backend nativo é diagnosticado.

### Backends — `src/codegen/`

- `llvm.zig`: IR textual com SSA simples, blocos básicos, `phi` para `&&`/`||`,
  `alloca` para variáveis. Sem ferramenta LLVM no ambiente local, a validação é
  estrutural (todo bloco termina com `ret`/`br`/`unreachable`) e o CI roda
  `llvm-as` sobre todas as fixtures (`tools/validate-ir.sh`).
- `x86_64.zig`: assembly System V sem libc. `_start` chama `kyn_main` e encerra
  via syscall `exit`. Variáveis em slots de 8 bytes no frame, expressões em
  `%eax` com pilha de temporários, chamadas com argumentos em
  `%edi/%esi/%edx/%ecx/%r8d/%r9d`. É o caminho validado por execução.

### Biblioteca padrão — `std/`

`kyn:core` (independente de SO) e `kyn:std` (dependente de SO) permanecem
experimentais. Compilam e têm testes, mas não fazem E/S real na maior parte das
APIs.

## Diretrizes de engenharia

- Manter slices e referências à entrada quando a vida útil permitir.
- Tornar explícita a origem e a duração dos allocators (arena por compilação).
- Separar interfaces independentes de plataforma das específicas de SO.
- Manter fixtures da linguagem separadas dos testes unitários do bootstrap.
- Não prometer determinismo, segurança de memória ou compatibilidade ABI sem
  testes e contratos verificáveis.

## Próximas decisões arquiteturais

1. Escolher o backend oficial de longo prazo (LLVM IR validado por ferramenta
   ou backend nativo próprio) e definir critérios de aceitação para ele.
2. Ampliar o contrato de módulos (visibilidade, imports qualificados, pacotes);
   hoje a resolução é por caminho relativo e os símbolos são achatados.
3. Definir a convenção de struct por valor para **agregados maiores** que a
   tabela de registradores (hoje limitado a 6 campos) — passagem por pilha ou
   `sret` — antes de `impl`/métodos com `self` grande.
4. Adicionar à AST os nós hoje ausentes (`enum`, `impl`, `unsafe`, atributos) e
   conectar `src/sema/unsafe.zig`.
5. Definir o modelo de memória executável (ownership, lifetimes, slices) antes
   de expandir a std.
6. Definir a comparação de `str` por conteúdo e a concatenação/formatação
   (hoje diagnosticadas); a passagem de `str` por valor em parâmetros e retornos
   foi decidida no Ciclo 8 (par ponteiro+tamanho, ver acima).
