# Changelog — Kyn

Formato: [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).
Versionamento: SemVer 2.0.0. Abaixo de 1.0.0 tudo é pré-lançamento e pode quebrar.

A partir desta versão o número do compilador passa a refletir o que o código
realmente faz. Veja a nota em [Histórico anterior](#histórico-anterior-não-verificado).

## [0.5.0-alpha.1] — 2026-11-03

`match` sobre enums com verificação de exaustividade, e CI.

### Adicionado

- **`match` sobre enum** como statement, com três formas de padrão:
  `Enum::Variante`, `Variante` (sem qualificar) e o curinga `_`. Cada braço é um
  bloco, e o backend gera um `switch` de C com bloco e `break` próprios por braço
  (sem fallthrough).
- **Verificação de exaustividade**: sem curinga, todas as variantes precisam
  aparecer; caso contrário o compilador lista as que faltam.
- **Novos códigos de diagnóstico**: `E0024` (`match` não exaustivo) e `E0025`
  (variante inexistente, variante de outro enum, braço duplicado, sujeito que não é
  enum).
- **`match` exaustivo cujos braços terminam em `return` encerra a função** — não é
  preciso escrever um `return` morto depois dele.
- **Token `=>`** (`fat_arrow`) e palavra-chave `match` no lexer.
- **CI** (`.github/workflows/ci.yml`): `zig build test` + `zig build integration` +
  smoke test da CLI em Linux e macOS, e `zig build test` no Windows, com Zig fixado
  em 0.17.0. **Executado e verde nas três plataformas** (run 41554129555, PR #5).
- 2 casos executáveis (`34_match_enum`, `35_match_in_loop`) e 5 de diagnóstico
  (`d33`…`d37`).
- Teste unitário de `alwaysReturns`/`alwaysReturnsForC` para `match` exaustivo.

### Corrigido

- **Typedefs de slice emitidos antes dos tipos que referenciam**: `[]Estado`
  gerava `typedef struct { KynEstado *data; … }` antes do `typedef` de `KynEstado`,
  e o C não compilava. A emissão agora acontece depois de enums e structs
  (regressão da 0.4.0-alpha.1, encontrada pelo novo caso `35_match_in_loop`).
- **Aviso `-Wreturn-type` do gcc** em funções não-`void` que terminam em `match`
  exaustivo: o backend usa `alwaysReturnsForC` (que desconsidera a exaustividade,
  invisível para o C) e insere um `return 0;` inalcançável.
- O teste do lexer `lexes multi-character operators` passou a cobrir `=>`.
- **Build quebrado no Windows** (encontrado pelo próprio CI, não localmente):
  `parseArgs` recebia `std.process.Args.Vector`, que é `[*:0]u16` no Windows, e
  `std.mem.span` só aceita ponteiros de `u8` — `zig build` falhava com
  `invalid type given to std.mem.span: u16`. Os argumentos agora passam por
  `std.process.Args.Iterator` com alocador (converte UTF-16 → UTF-8 no Windows,
  identidade no POSIX). Reproduzido e verificado por compilação cruzada em
  `x86_64-windows`, `aarch64-windows`, `x86_64-macos` e `aarch64-linux`.

### Limitações

- `match` só aceita enum como sujeito e só existe como statement: sem padrões com
  ligação de variável, guardas `if`, faixas (`1..=5`) nem `match` como expressão.
- `break`/`continue` diretamente em um braço são rejeitados (E0021): no C gerado
  eles sairiam do `switch`, não do laço.
- O Windows roda apenas os testes unitários em CI porque a suíte de integração
  exige `cc` no `PATH`, ausente nos runners do Windows.

### Números desta revisão

`zig build test` → 27 testes; `zig build integration` → 122 casos (35 executáveis +
37 de diagnóstico + 50 de regressão), 0 falhas.

## [0.4.0-alpha.1] — 2026-11-03

Arrays, slices e indexação — o primeiro passo para coleções reais.

### Adicionado

- **Arrays `[N]T`**: literais `[1, 2, 3]` (com tipo inferido pelo contexto ou pelo
  primeiro elemento), campos de struct, indexação, `.len` constante e `for i in
  0..xs.len`.
- **Slices `[]T` e `[]const T`**: struct `{ data, len }` no C, um `typedef` por tipo
  de elemento, indexação, `.len` em tempo de execução e passagem por parâmetro.
- **Fatiamento** `xs[lo..hi]`, `xs[lo..]`, `xs[..hi]` e `xs[..]` sobre arrays e
  slices, com a constância dos elementos herdada do lugar de origem.
- **`for item in colecao`** sobre arrays e slices (o elemento é uma cópia imutável;
  o parser distingue essa forma de `for i in a..b` sem backtrack).
- **Decadência array → slice**: parâmetros `[N]T` viram `[]T`, e `[N]T` é convertido
  automaticamente onde se espera `[]T` (binding, argumento, retorno). A conversão
  fica explícita na AST como nó `to_slice`, inserido pela semântica.
- **Conversão `[]T` → `[]const T`** implícita.
- 4 casos executáveis (`30_arrays`, `31_slices`, `32_for_collection`,
  `33_array_struct`) e 6 casos de diagnóstico (`d27`…`d32`): indexação de valor não
  indexável (E0022), escrita em array imutável e em `[]const` (E0014), tamanho de
  array incompatível (E0013), retorno de array e atribuição de array como um todo
  (E0099).
- Teste unitário de tipos de array/slice (internação, distinção `[3]i32` × `[4]i32`,
  `[]T` × `[]const T`, `describe`, `elemOf`).

### Modificado

- `for i in a..xs.len` deixa de falhar: um limite literal adota o tipo do outro lado
  (antes `0` era `i32` e `.len` é `usize`, gerando E0013).
- `docs/syntax.ebnf` passa a cobrir arrays, slices, indexação, fatias e `for` sobre
  coleções, com as regras semânticas associadas.
- `docs/status.md`, `README.md`, `docs/architecture.md`,
  `docs/language_reference.md` e `tests/README.md` atualizados; motivos das fixtures
  de `tests/pending/` revisados (`[]u8` já compila — o que falta nelas é outra coisa).

### Limitações novas e explícitas

- **Índices e fatias não são verificados em tempo de execução**: fora dos limites é
  comportamento indefinido, como em C. Não há runtime onde inserir a checagem.
- Slices não têm ownership: `let s: []i32 = [1, 2, 3];` cria um literal composto com
  tempo de vida do bloco atual.
- Arrays multidimensionais, retorno de array e atribuição de array como um todo são
  rejeitados com E0099, com mensagem apontando a alternativa.
- `str` continua sem comprimento e não é indexável.

### Números desta revisão

`zig build test` → 27 testes; `zig build integration` → 115 casos (33 executáveis +
32 de diagnóstico + 50 de regressão), 0 falhas.

## [0.3.0-alpha.1] — 2026-11-02

Primeira versão com pipeline de compilação integrado e verificável.

### Adicionado

- **Build reproduzível**: `build.zig` + `build.zig.zon` com alvos `build`, `test`,
  `integration`, `check` e `run` (Zig 0.17.0).
- **CLI `kyn`** com `check`, `emit`, `build`, `run`, `tokens`, `ast`, `version`,
  `help`, opções `-o`, `--cc`, `--warn-unused`, `--no-main`, `--emit-c` e códigos de
  saída documentados (0/1/2/3/4, com propagação do código em `run`).
- **Lexer completo**: palavras-chave, inteiros decimais/hex/octal/binário com `_`,
  flutuantes com expoente, strings com escapes (`\n \t \r \0 \\ \" \' \xNN`), chars,
  comentários de linha e de bloco aninháveis, spans em todos os tokens e
  recuperação após erro léxico (E0002).
- **Parser recursivo-descendente** para `import`, `fn`, `extern fn` (com varargs),
  `struct`, `enum`, `impl`, atributos `#[…]`, `pub`, `let`/`var`/`let mut`,
  atribuição composta, `if`/`else if`/`else`, `while`, `for i in a..b`, `return`,
  `break`, `continue`, blocos, `unsafe { … }` e expressões com precedência completa
  (chamadas, métodos, `Tipo::item`, campos, literais de struct/enum, `&`, `&mut`,
  `*`, casts `as`).
- **Análise semântica em duas passadas** com tipos internados, escopos e shadowing,
  inferência de literais pelo contexto, verificação de mutabilidade por *lugar*,
  caminhos de retorno, aridade, `break`/`continue`, atributos e contexto `unsafe`.
- **Códigos de diagnóstico estáveis** E0001, E0002, E0010–E0023, E0099 e W0001,
  renderizados com caminho, linha, coluna, trecho da origem e marcador `^^^`.
- **Backend C99** (`src/codegen/c.zig`): structs, enums, métodos com receiver,
  funções associadas, FFI com `extern fn`, `print`/`println` por tipo estático,
  `#[align(N)]` via `__attribute__((aligned))`, prefixação `Kyn`/`kyn_` para evitar
  colisão com o C.
- **Suíte de integração** (`src/runner.zig` + `zig build integration`): 29 casos
  executáveis com saída e código de saída esperados, 26 casos de diagnóstico e 50
  casos de regressão de código de saída — 105 no total.
- **26 testes unitários** distribuídos em lexer (7), semântica (8), driver (3),
  diag (2), runner (2), ast (1), parser (1) e codegen (1).
- `tests/README.md`, `tests/pending/README.md`, `experiments/README.md`,
  `std/README.md`; `docs/grammar.ebnf` e `docs/syntax.ebnf` reescritos para o
  subconjunto implementado.

### Modificado

- `src/ast/ast.zig`, `src/lexer/lexer.zig`, `src/parser/parser.zig`,
  `src/sema/sema.zig`, `src/sema/unsafe.zig` e `src/main.zig` reescritos: as versões
  anteriores eram esqueletos (o parser parava no primeiro statement e a semântica
  não percorria a árvore).
- Fixtures reorganizadas: `tests/cases/`, `tests/diagnostics/`, `tests/regression/`
  e `tests/pending/`. As antigas `tests/integration/case_*.kyn` viraram
  `tests/regression/exit_NN.kyn` com saída esperada; `hello.kyn`,
  `parser_basic.kyn`, `sema_basic.kyn`, `codegen_basic.kyn`, `self_host.kyn`,
  `mutability_basic.kyn`, `regopt_basic.kyn` e `modules/basic.kyn` foram reescritas
  como casos válidos (as versões anteriores não eram programas compiláveis).

### Removido

- Emissor fixo de LLVM IR que ignorava a AST (`src/codegen/codegen.zig` antigo),
  substituído pelo backend C.
- `src/test_core.zig`, `src/test_sema.zig`, `src/test_codegen.zig`,
  `src/test_std.zig` e `src/test_unsafe.zig`: não compilavam (importavam
  `kyn_core.zig`, inexistente) e foram substituídos pelos testes dentro dos módulos.
- `src/ffi/ffi.zig` (demonstração em Zig, sem relação com o pipeline).

### Movido

- `src/kyn/*.kyn` e `src/compiler/*.kyn` → `experiments/self-host-sketch/`
  (rascunhos que o compilador atual não aceita).
- `std/core/*` e `std/os/*` → `experiments/stdlib-sketch/` (stubs em Zig com
  comportamento simulado e rascunhos `.kyn` de API).

## Histórico anterior (não verificado)

As entradas abaixo foram escritas antes de existir implementação correspondente:
elas descreviam intenção e arquivos de rascunho, não comportamento verificável. São
mantidas apenas como registro. Não use esses números de versão.

- **v2.3.0 (2026-11-01)** — "release industrial estável" e "compilador self-hosted
  `kync`": nunca existiram no repositório.
- **v2.2.0-rc.1** — 50 fixtures `tests/integration/case_*.kyn` (arquivos existiam;
  não havia runner que os executasse).
- **v2.1.0-beta.1** — `Result<T, E>` em `src/compiler/result.kyn` (rascunho).
- **v2.0.0-beta.1** — RingBuffer lock-free em `std/core/ringbuffer.kyn` (rascunho).
- **v1.9.0** — primitivas atômicas em `std/core/atomics.kyn` (rascunho).
- **v1.8.0** — FFI nativa com C em `src/compiler/ffi.kyn` (rascunho).
- **v1.7.0** — "otimização de registradores" em `src/compiler/regopt.kyn` (rascunho).
- **v1.6.0** — verificação de mutabilidade em `src/compiler/mutability.kyn`
  (rascunho; a verificação real chegou em 0.3.0-alpha.1).
- **v1.5.0** — ArenaAllocator em `std/core/arena.kyn` (rascunho).
- **v1.4.0** — sistema de módulos em `src/compiler/modules.kyn` (rascunho; em
  0.3.0-alpha.1 existe apenas validação do nome do módulo).
- **v1.2.0** — fuzz testing (fixtures existiam; sem harness executável).
- **v1.1.0** — diagnóstico estilo Rust/Zig em `src/compiler/diagnostics.kyn`
  (rascunho; a implementação real está em `src/diag.zig`).
