# Changelog — Kyn

Regras: Semantic Versioning 2.0.0. Pré-1.0.0 = Pre-release.

> **Aviso de rastreabilidade:** as entradas abaixo de `v0.3.0-alpha.1`
> registram marcos pretendidos em ciclos anteriores do projeto e **não**
> constituem evidência de implementação. Várias descrevem recursos que o código
> não possui (por exemplo self-hosting, release "industrial estável",
> `Result<T, E>` e organização de módulos). O estado real, verificado por build
> e testes, está em [docs/status.md](docs/status.md). O versionamento será
> reconciliado antes de qualquer release pública.

## [v0.3.4-alpha.1] — 2026-11-07

Saída de texto: `str` como fatia estática e `print(...)` embutido.

- **AST:** `Expr.Kind.str_literal` (bytes sem aspas) e `Expr.Call.builtin`
  (`print`), permitindo que a semântica marque chamadas embutidas sem
  confundi-las com funções declaradas na fonte.
- **Parser:** literal de string passa a ser expressão (inclusive como argumento
  de chamada); string não terminada vira diagnóstico `.syntax` com a posição.
- **Semântica:** novo `Type.str` (não escalar) com **dois slots** (ponteiro e
  tamanho, mesma convenção nos dois backends) e `print` embutido: exatamente um
  argumento `str`, resultado `void`, nome reservado para funções declaradas.
  Diagnósticos novos: `str` em aritmética/condição, comparação `==`/`!=` de
  `str` (sem comparar ponteiros silenciosamente), literal solto como statement,
  `str` em parâmetro/retorno/argumento e campo de struct de tipo `str`.
- **Backend x86-64:** literais deduplicados em `.section .rodata` como listas de
  `.byte` (sem escapes), atribuição/cópia em dois `movq` e `print` via syscall
  `write` (texto + quebra de linha), sem depender de libc.
- **Backend LLVM IR:** `@.strN = private unnamed_addr constant [N x i8]`,
  `declare i64 @write(i32, ptr, i64)` e `print` como duas chamadas a `write`;
  `str` usa dois `alloca` (`ptr` + `i64`). IR aceito por `llvm-as` no CI.
- **Pool de strings:** `codegen.StrPool` deduplica por conteúdo, então cada
  texto distinto vira um único rótulo/constante independentemente das
  referências.
- **Semântica (correção de contrato):** `let`/`var` com inicializador `void`
  (por exemplo `let x = print("a");` ou `let x = f();` com `f` sem retorno)
  agora é diagnosticado como um **único** erro; antes `let x = f();` passava
  pela semântica e chegava ao backend com um tipo sem representação.
- **Testes:** 162 testes do compilador (29 novos: parser, semântica, os dois
  backends e o pool) e 7 da std; 4 fixtures e2e novas com `print` (stdout
  conferido), 1 módulo importado com `print` e 4 fixtures negativas —
  **86/86 casos**, com `tools/e2e.sh` passando a comparar `// expect-stdout:`
  além de `// expect-exit:`.
- **Docs:** `docs/syntax.ebnf`, `docs/grammar.ebnf`, `docs/architecture.md`
  (representação de `str` e saída de texto), `docs/status.md`,
  `docs/development.md`, `docs/language_reference.md`, `README.md`,
  `ROADMAP.md` e `DEVELOPMENT_STATE.md` atualizados.
- **Versão:** `0.3.4-alpha.1` (derivada de `build.zig.zon`).
- **Integração:** PR #15 mesclado em `main` como `89ca6ce`; CI verde nos runs
  `42420648098` (PR) e `42421025867` (`main`), com `zig fmt --check`, testes,
  e2e (stdout conferido) e `validate-ir-strict` sobre 71 módulos.

## [v0.3.3-alpha.1] — 2026-11-07

Structs com valor: declaração, literais, campos e layout nos dois backends.

- **Lexer:** palavra-chave `struct` e pontuação `.` (ponto, usada em `p.campo`).
- **Parser:** `struct Nome { campo: tipo, ... }` no nível superior (ordem livre em
  relação a `fn`, vírgula final opcional, erros com span); literais
  `Nome { campo: valor }`; acesso `p.campo` encadeável na gramática; nova
  atribuição `p.campo = valor`. Condições de `if`/`while` desativam o literal de
  struct, porque `Nome {` ali inicia o bloco.
- **AST:** `Program.structs`, `ast.StructDecl`/`ast.Field`,
  `Expr.field_access`, `Expr.struct_literal`/`FieldInit` e
  `Stmt.field_assign`, com índices resolvidos pela semântica.
- **Semântica:** `Type.aggregate` + `Checked.structs` (duas passadas: nomes e
  depois campos), resolução de campo, validação de literais (todos os campos,
  uma vez cada), atribuição imutável, tipos incompatíveis e structs diferentes
  na anotação. Restrições diagnosticadas: struct por valor em
  parâmetro/retorno/argumento, campo de tipo struct, struct vazio, struct em
  condição/comparação e literal como expressão solta.
- **Layout:** variável de struct reserva `1 + n` slots (base + um por campo).
  x86-64 usa `movl` nos offsets dos slots; o backend LLVM aplica substituição
  escalar (um `alloca` por campo, sem tipos agregados). Struct nunca escapa da
  função nesta etapa, então não há cópia parcial nem estado não inicializado.
- **Driver:** structs dos módulos importados entram no programa achatado em
  pré-ordem, com `file_id` para atribuição correta dos diagnósticos.
- **Testes:** 132 testes do compilador (16 novos: lexer, parser, semântica,
  driver multi-arquivo e estrutura de IR/assembly) e 7 da std; 3 fixtures e2e
  novas com `struct` executadas (saídas 14, 10 e 21), 1 módulo com struct
  (saída 42) e 3 fixtures negativas de struct — 77/77 casos.
- **Docs:** `docs/syntax.ebnf` e `docs/grammar.ebnf` descrevem `struct`,
  literais e acesso a campo; `docs/architecture.md` documenta o layout;
  `docs/status.md`, `docs/development.md`, `docs/language_reference.md`,
  `README.md`, `ROADMAP.md` e `DEVELOPMENT_STATE.md` atualizados.
- **Versão:** `0.3.3-alpha.1` (derivada de `build.zig.zon`).
- **Integração:** PR #13 mesclado em `main` como `4234c07`; CI verde nos runs
  `42417725687` (PR) e `42417878774` (`main`), incluindo
  `zig build validate-ir-strict` com 66 módulos aceitos por `llvm-as`.

## [v0.3.2-alpha.1] — 2026-11-07

Módulos: `import` com caminhos relativos e compilação multi-arquivo.

- **Lexer:** literais de string entre aspas duplas (`"..."`, sem escapes e sem
  quebra de linha), com token `.string` guardando o conteúdo e
  `.string_unterminated` para literais abertos; nova palavra-chave `import`.
- **Parser:** `import "caminho";` no nível superior, antes das funções. Caminho
  precisa ser literal de string; `import` depois de uma função, caminho sem
  aspas e falta de `;` produzem diagnóstico de sintaxe com span.
- **Driver:** novo `compilePath(gpa, io, dir, caminho, opções)`, que carrega o
  arquivo raiz e resolve `import` recursivamente em relação ao diretório do
  arquivo importador (`std.fs.path.resolveAlloc`, sem syscalls). Cada caminho é
  normalizado e carregado uma única vez (importações em diamante não duplicam
  símbolos); ciclos geram `.import_cycle`, arquivos ausentes `.import_not_found`
  e símbolos repetidos entre arquivos `.duplicate_declaration`. Os módulos são
  achatados em um único `ast.Program` em pré-ordem (raiz primeiro), antes da
  semântica, de modo que os backends existentes não mudaram. `compile` continua
  disponível para um único buffer e diagnostica `import` como não resolvido.
- **Diagnósticos:** `Diagnostic.file` + `List.addInFile`; a CLI imprime
  `arquivo:linha:coluna` do arquivo correto, inclusive para erros dentro de
  módulos importados. `renderDiagnostics` agora recebe a lista de fontes.
- **CLI:** `kync check/emit <arquivo.kyn>` compila o arquivo e seus imports;
  erro de leitura do arquivo raiz continua saindo com código 3, enquanto
  importação ausente é erro de compilação (código 1).
- **Testes:** 108 testes do compilador (21 novos: lexer de strings, parser de
  `import` e carregamento multi-arquivo com diamante, ciclo, arquivo ausente,
  símbolo duplicado e atribuição de arquivo nos diagnósticos); 3 fixtures e2e
  positivas multi-arquivo executadas de verdade e 3 negativas com mensagem
  esperada. `tools/e2e.sh` e `tools/validate-ir.sh` ganharam as seções de
  módulos (70 casos e2e, 62 módulos de IR).
- **Docs:** `docs/syntax.ebnf` e `docs/grammar.ebnf` descrevem `import` e o
  literal de string; `docs/status.md`, `docs/development.md`,
  `docs/architecture.md`, `README.md`, `ROADMAP.md` e `DEVELOPMENT_STATE.md`
  atualizados com o estado verificado.
- **Build:** `kyn.version` passa a vir de `build.zig.zon` via opções de build
  (fim da duplicação da versão em `src/root.zig`).
- **Integração:** PR #10 mesclado em `main` como `1c149dd`; CI verde nos runs
  `42415765698` (PR) e `42415945385` (`main`), incluindo
  `zig build validate-ir-strict` com 62 módulos aceitos por `llvm-as`.

## [v0.3.1-alpha.1] — 2026-11-07

Integração contínua e validação do backend LLVM IR por ferramenta real.

- **CI:** adicionado `.github/workflows/ci.yml` (ubuntu-24.04) que instala Zig
  0.17.0 a partir do wheel oficial do PyPI, instala LLVM e executa
  `zig fmt --check`, `zig build test`, `zig build e2e` e
  `zig build validate-ir-strict`. Execuções verdes: `42413779278` (primeira)
  e `42414049577` (com validação estrita e `actions/checkout@v7`).
- **Validação de IR:** novo `tools/validate-ir.sh`, que roda `llvm-as`
  (PATH, sufixo de versão ou `/usr/lib/llvm-*/bin`) ou `clang -x ir` sobre o IR
  de todas as fixtures suportadas (59 módulos). Sem LLVM, a variante leniente
  avisa; a variante `--require-tool` (usada no CI) falha, impedindo que a
  validação seja ignorada em silêncio.
- **Build:** novos passos `zig build validate-ir` e
  `zig build validate-ir-strict`.
- **Documentação:** `docs/development.md` descreve a suíte de validação, o
  workflow de CI e como reproduzir localmente; `README.md` ganha badge de CI;
  `docs/status.md` e `ROADMAP.md` atualizados com a evidência obtida.

## [v0.3.0-alpha.1] — 2026-11-07

Ciclo de integração do frontend com validação executável.

- **Build:** adicionados `build.zig` e `build.zig.zon` (Zig 0.17.0 como versão
  mínima). `zig build`, `zig build test` e `zig build e2e` funcionam.
- **Toolchain:** desbloqueio da validação com Zig 0.17.0 real (binário oficial
  obtido via pacote PyPI `ziglang` 0.17.0.post0).
- **Lexer:** contrato de tokens reescrito com `Tag` tipada, palavras-chave,
  operadores de dois caracteres e `Span` (offset, linha, coluna 1-based);
  comentários e espaços descartados; caractere inválido vira token diagnosticado.
- **AST:** novo modelo com funções, parâmetros, `let`/`var`, atribuição,
  `return`, `if`/`else`, `while`, blocos e expressões; anotações de resolução
  feitas pela semântica.
- **Parser:** constrói o programa completo, com precedência/associatividade
  documentadas em `docs/syntax.ebnf`; erros com span e mensagem.
- **Semântica:** escopos aninhados, resolução de nomes, tipos `i32`/`bool`/
  `void`, mutabilidade, verificação de chamadas, validação de `main`,
  verificação estrutural de retorno e atribuição de slots de pilha.
- **Diagnósticos:** módulo próprio com categoria estável, mensagem, linha e
  marcador `^`.
- **Backends:** interface em `src/codegen/codegen.zig` com dois emissores
  derivados da AST — LLVM IR textual e assembly x86-64 System V sem libc.
- **CLI `kync`:** `check` e `emit` (`--llvm`, `--asm`, `-o`, `--lib`) com
  códigos de saída 0/1/2/3 e ajuda/versão.
- **Testes:** 96 testes unitários (89 do compilador + 7 da std experimental);
  64 casos de ponta a ponta (9 fixtures
  comportamentais executadas, 50 fixtures `tests/integration/case_N.kyn`
  conferidas pelo código de saída e 5 fixtures negativas). Testes antigos em
  `src/test_*.zig` foram consolidados em `src/tests.zig` e `std/tests.zig`
  (o antigo `src/test_core.zig` importava um arquivo inexistente).
- **Documentação:** `README.md`, `docs/status.md`, `docs/architecture.md`,
  `docs/development.md`, `docs/grammar.ebnf`, `docs/syntax.ebnf` e `ROADMAP.md`
  reconciliados com o comportamento observado.

## [v2.3.0] — 2026-11-01
- Marco 3.10: Lançamento da Release Industrial Estável. Congelamento final do compilador self-hosted `kync`, documentação completa, empacotamento do binário final.

## [v2.2.0-rc.1] — 2026-11-01
- Marco 3.9: 50+ arquivos de integração end-to-end (`tests/integration/case_*.kyn`).

## [v2.1.0-beta.1] — 2026-11-01
- Marco 3.8: Result<T, E> nativo (`src/compiler/result.kyn`, `tests/result_basic.kyn`).

## [v2.0.0-beta.1] — 2026-11-01
- Marco 3.7: RingBuffer lock-free (`std/core/ringbuffer.kyn`, `tests/ringbuffer_basic.kyn`).

## [v1.9.0] — 2026-11-01
- Marco 3.6: Primitivas atômicas (`std/core/atomics.kyn`, `tests/atomics_basic.kyn`).

## [v1.8.0] — 2026-11-01
- Marco 3.5: Suporte a FFI Nativa com C (`src/compiler/ffi.kyn`, `tests/ffi_basic.kyn`).

## [v1.7.0] — 2026-11-01
- Marco 3.4: Otimizações de registradores no CodeGen (`src/compiler/regopt.kyn`, `tests/regopt_basic.kyn`).

## [v1.6.0] — 2026-11-01
- Marco 3.3: Verificação de mutabilidade estrita (`src/compiler/mutability.kyn`, `tests/mutability_basic.kyn`).

## [v1.5.0] — 2026-11-01
- Marco 3.2: ArenaAllocator nativo (`std/core/arena.kyn`, `tests/arena_basic.kyn`).

## [v1.4.0] — 2026-11-01
- Marco 3.1: Sistema de Módulos & Imports (`src/compiler/modules.kyn`, `tests/modules/basic.kyn`).

## [v1.2.0] — 2026-11-01
- Fuzz Testing: `tests/fuzz/fuzzer.kyn`, `tests/fuzz/harness.kyn`, `tests/fuzz/edge_cases.kyn`.
- Garantia de crash-proof (sem panic/segfault) para entradas malformadas.

## [v1.1.0] — 2026-11-01
- Diagnostics: `src/compiler/span.kyn`, `src/compiler/diagnostics.kyn` (mensagens de erro estilo Rust/Zig).
- Testes: `tests/diagnostics/invalid_type.kyn`, `tests/diagnostics/invalid_syntax.kyn`.

## [v1.0.0] — 2026-11-01
- Marco 3.1/3.2: Self-Hosting — compilador reescrito em Kyn (`src/compiler/`), testes `tests/self_host_test.sh`.
- Linguagem estável oficial, pronta para produção.

## [v0.9.0-rc.1] — 2026-11-01
- Marco 2.4: Release Candidate do compilador Bootstrap. Cobertura de testes > 90%, otimizações de pipeline, especificações congeladas.
- README profissional com badges, roadmap SemVer e arquitetura.

## [v0.8.0-beta.2] — 2026-11-01
- Marco 2.3: `std/os/` (I/O, Threads, Networking), `src/ffi/ffi.zig` (FFI C), `tests/std_basic.kyn`, `src/test_std.zig`.
- Expansão da capacidade de interação com SO e ecossistemas externos.

## [v0.6.0-beta.1] — 2026-11-01
- Marco 2.2: `src/sema/unsafe.zig` (verificação de blocos `unsafe` e `#[repr(C)]`), `tests/unsafe_basic.kyn`, `src/test_unsafe.zig`.
- Transição alpha → beta: enforce de segurança e layout de memória.

## [v0.5.0-alpha.1] — 2026-11-01
- Marco 2.1: `std/core/core.zig` (unsafe, @align, alocadores explícitos), `tests/core_basic.kyn`, `src/test_core.zig`.
- Separação `kyn:core` (bare-metal) iniciada.

## [v0.4.0-alpha.1] — 2026-11-01
- Marco 1.4: `src/codegen/codegen.zig` (emissão LLVM IR básico), testes `tests/codegen_basic.kyn` + `src/test_codegen.zig`.
- Ciclo completo do compilador Bootstrap: Lexer → Parser → AST → Sema → CodeGen.

## [v0.3.0-alpha.1] — 2026-11-01
- Marco 1.3: `src/sema/sema.zig` (Typechecker básico, escopo `let`, `Result<i32, E>` inicial), testes `tests/sema_basic.kyn`.
- Integração `lexer` → `parser` → `ast` → `sema`.

## [v0.2.0-alpha.1] — 2026-11-01
- Marco 1.2: Parser (`src/parser/parser.zig`), AST (`src/ast/ast.zig`), testes `.kyn` (`tests/parser_basic.kyn`).
- Separação `lexer` → `parser` → `ast` respeitada.
- Erros sintáticos reportados via `!AST.Error`.

## [v0.1.0-alpha.1] — 2026-11-01
- Marco 1.1: estrutura de repositório, CLI `kync`, Lexer básico, testes Zig + `.kyn`.
- Dependência estrita: Zig 0.17.0.
- Target emissão: LLVM IR direto (Fase 1.4).
