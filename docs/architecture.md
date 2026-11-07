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

Um valor de struct é **nominal** (`Symbol.struct_id` → `Checked.structs`) e vive
apenas em variáveis locais: não há passagem por valor em parâmetros/retorno nem
campo de tipo struct nesta etapa, então um struct nunca escapa da função.

- `Symbol.typ == .aggregate` reserva `1 + n` slots: o primeiro é a base
  (reservado) e cada campo usa `slot + 1 + índice`, na ordem da declaração.
- x86-64: cada slot tem 8 bytes; leitura/escrita de campo é `movl` no offset do
  slot, e a cópia de struct percorre os campos.
- LLVM IR: substituição escalar — um `alloca` por campo, com o tipo do campo
  (`i32`/`i1`). Não há tipos agregados nem `getelementptr`, e um struct que
  nunca escapa tem a mesma semântica observável.
- Literais exigem todos os campos exatamente uma vez, o que garante struct
  sempre inicializado (sem estado parcialmente construído).

### Semântica — `src/sema/sema.zig`

- dois passos: assinaturas primeiro (permite recursão e chamadas antes da
  declaração), depois corpos;
- escopos aninhados com shadowing permitido e duplicidade diagnosticada no
  mesmo escopo;
- tipos `i32`, `bool`, `void`; operadores verificados por categoria;
- atribuição exige `var`;
- verificação estrutural de retorno (`alwaysReturns`) para funções não-void;
- validação de `fn main()` (sem parâmetros, retorno `i32` ou `void`);
- limite de 6 parâmetros/argumentos do backend nativo é diagnosticado.

### Backends — `src/codegen/`

- `llvm.zig`: IR textual com SSA simples, blocos básicos, `phi` para `&&`/`||`,
  `alloca` para variáveis. Sem ferramenta LLVM no ambiente, a validação é
  estrutural (todo bloco termina com `ret`/`br`/`unreachable`).
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
3. Definir o contrato de struct por valor entre funções (ABI SysV para
   agregados pequenos ou convenção própria) antes de `impl`/métodos.
4. Adicionar à AST os nós hoje ausentes (`enum`, `impl`, `unsafe`, atributos) e
   conectar `src/sema/unsafe.zig`.
5. Definir o modelo de memória executável (ownership, lifetimes, slices) antes
   de expandir a std.
6. Definir a representação de `str` e a saída de texto (`write`/libc) para que
   a validação observe conteúdo, não apenas código de saída.
