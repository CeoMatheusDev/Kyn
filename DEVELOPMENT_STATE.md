# DEVELOPMENT_STATE — Kyn

**Mantido por:** agente de continuidade (Arena)
**Branch ativa:** `arena/b9e5b3e8-kyn` (a partir de `d6eb534` de `main`)
**Integração:** PRs #7–#11 (módulos/`import`), PR #13 (`struct` com valor,
`4234c07`) e PR #15 (`str`/`print`, `89ca6ce`) mesclados em `main`
(2026-11-07); CI verde no PR #15 (run `42420648098`) e no merge
(`42421025867`). PR #17 (`print_i32`) mesclado como `87903db` e PR #18
(docs) como `3be9df0`; CI verde nos runs `42423945656`/`42424327653` (PRs) e
`42424147963`/`42424509215` (`main`). PR #19 (`str` por valor) → `9ec07be`;
PR #20 e #21 (registros) → `2a68d9a`/`da92f44`; PR #22 (último registro) →
`d6eb534`, base do ciclo atual (struct por valor), cujo PR será aberto sobre
`0.3.7-alpha.1`.
**Versão do projeto:** `0.3.7-alpha.1`
**Última validação:** 2026-11-07 — local (Zig 0.17.0 + GNU `as`/`ld`, Linux
x86-64): `zig build`, `zig build test` (204 testes), `zig build e2e` (102/102,
com stdout conferido, inclui `str` e struct por valor), `zig fmt --check` e
`kync --version` (`0.3.7-alpha.1`); `validate-ir` local sem LLVM (skip
documentado), validação estrita de 83 módulos feita no CI; 20 blocos de código
do `docs/tutorial.md` verificados com `kync check` (15 compilam e executam, 1 é
arquivo de biblioteca, 3 falham com o erro documentado, 1 importa o módulo)
**Estado do working tree:** verificar com `git status` antes de agir

---

## 1. Como preparar o ambiente (obrigatório)

O binário do Zig **não** é preservado entre sessões (instalado fora do snapshot,
em `~/.local`). Reinstale antes de qualquer validação:

```sh
python3 -m pip download ziglang==0.17.0.post0 --no-deps -d /tmp/zigwheel
mkdir -p ~/.local/zigpkg && cd ~/.local/zigpkg
python3 -m zipfile -e /tmp/zigwheel/*.whl .
chmod +x ziglang/zig && mkdir -p ~/.local/bin && ln -sf ~/.local/zigpkg/ziglang/zig ~/.local/bin/zig
export PATH=$HOME/.local/bin:$PATH
zig version    # deve imprimir 0.17.0
```

`ziglang==0.17.0` está *yanked* (upload parcial); `0.17.0.post0` é o mesmo
compilador com wheel íntegra. Não existe `llc`/`clang` no ambiente — só `as`,
`ld`, `gcc` (GNU). Isso define o que é validável (ver §3).

## 2. Estado real do projeto (verificado, não presumido)

O Kyn é um protótipo de linguagem de sistemas com compilador bootstrap em Zig.
Neste ciclo o pipeline do frontend foi **integrado e validado por execução**:

```text
.kyn -> lexer (tokens+spans) -> parser (programa completo) -> AST
     -> semântica (escopos/tipos/mutabilidade/slots) -> backend
          -> LLVM IR textual (validação estrutural)
          -> assembly x86-64 (as + ld + execução: exit code conferido)
```

| Componente | Arquivo | Estado |
|---|---|---|
| Build | `build.zig`, `build.zig.zon` | Fonte única; `zig build`, `zig build test`, `zig build e2e` |
| CLI | `src/main.zig` | `check`/`emit` (`--llvm`, `--asm`, `-o`, `--lib`), códigos 0/1/2/3 |
| Lexer | `src/lexer/lexer.zig` | Tokens tipados, keywords (`import`, `struct`), operadores 1–2 chars, `.` e demais pontuação, literal de string sem escapes, spans; descarta trivia |
| Spans | `src/span.zig` | offset + linha/coluna 1-based; sem cópia de texto |
| Diagnósticos | `src/diagnostics.zig` | categoria estável + mensagem + linha/caret + `file` (arquivo de origem) |
| AST | `src/ast/ast.zig` | programa com `imports` e `structs`, funções (`file_id`), params, let/var, assign (variável e campo), return, if/else, while, blocos, expressões (acesso a campo, literal de struct, literal de string), `Call.builtin` (`print`, `print_i32`) |
| Parser | `src/parser/parser.zig` | programa completo, `import` antes das declarações, `struct`, literais e acesso a campo, precedência/associatividade, erro no primeiro token inválido |
| Semântica | `src/sema/sema.zig` | escopos, resolução, `i32`/`bool`/`str`/`void`/struct, campos e literais de struct, `str` e struct por valor em parâmetros/retornos (identidade nominal em `param_struct_ids`/`return_struct_id`), limite de 6 registradores via `registerWordsOf` (`str` = 2, campo = 1), builtins genéricos (`print`/`print_i32`: aridade, tipo e nome reservado), mutabilidade, chamadas, slots, `main`, `alwaysReturns` |
| Backend LLVM | `src/codegen/llvm.zig` | IR derivado da AST; structs por substituição escalar (um `alloca` por campo); `str` em `@.strN` + `declare i64 @write` + dois `alloca`, `str` por valor como `ptr`+`i64` e retorno `{ ptr, i64 }`, struct por valor com parâmetros achatados e retorno agregado `{ i32, i1, … }` (`insertvalue`/`extractvalue`); `print_i32` via `@kyn_print_i32` (uma vez por módulo); validado por `llvm-as` no CI |
| Backend nativo | `src/codegen/x86_64.zig` | System V sem libc; struct em slots consecutivos e por valor com um registrador por campo (retorno `%eax`/`%edx`/`%ecx`/`%r8d`/`%r9d`/`%r10d`); `str` em dois slots (ponteiro/tamanho) e por valor em pares de registradores (retorno `%rax`/`%rdx`), texto em `.rodata` e `print` por syscall `write`; `print_i32` com rotina decimal única em `.text`; validado executando binários e conferindo stdout |
| Driver | `src/driver.zig` | arena por compilação; `compile` (buffer único) e `compilePath` (grafo de imports, dedupe, ciclos, flatten); `Result.deinit()` |
| `unsafe`/`repr(C)` | `src/sema/unsafe.zig` | política isolada e testada; sem nós na AST ainda |
| Self-hosting | `src/kyn/*.kyn`, `src/compiler/*.kyn` | placeholders; não executados |
| Std | `std/core/*`, `std/os/*` | stubs experimentais; compilam nos testes |
| Fixtures | `tests/` | 50 `integration/case_N.kyn` (suportadas) + 52 entradas em `tests/e2e` (26 positivas, 7 módulos, 16 negativas, 3 módulos negativos); demais ainda não suportadas |
| CI | `.github/workflows/ci.yml` | ubuntu-24.04: fmt + test + e2e + validação de IR estrita |
| Validação de IR | `tools/validate-ir.sh` | `llvm-as`/`clang` sobre 83 módulos (inclui multi-arquivo, `struct`, `str`/`print`, `str` e struct por valor, `print_i32`); estrito no CI |
| Tutorial | `docs/tutorial.md` | Guia da linguagem (18 seções): CLI, tipos, controle de fluxo, structs por valor, módulos, diagnósticos, testes, limites e roadmap; 20 blocos `kyn` verificados com `kync check` | Conferido à mão + execução dos binários |

### Subconjunto aceito hoje

`import "caminho.kyn";` antes das declarações (caminho relativo ao arquivo
importador, cada arquivo carregado uma vez, símbolos achatados em escopo único),
`struct Nome { campo: tipo, ... }`, literais `Nome { campo: valor }` (todos os
campos, uma vez cada), acesso `p.campo` e atribuição `p.campo = v` em `var`,
cópia de struct por valor, literais de string, variáveis `str` (inferidas ou
anotadas) com cópia e atribuição, `str` por valor em parâmetros, argumentos e
retornos (par ponteiro+tamanho, dois registradores por `str`), `print(s: str)` e
`print_i32(n: i32)` embutidos (texto/decimais + quebra de linha), `fn`, `let`/`var`
(inicializador obrigatório),
inferência ou anotação (`i32`/`bool`/`str`/`void`/struct), atribuição só em `var`,
`return`, `if`/`else`/`else if`, `while`, blocos, aritmética, comparações,
`&&`/`||` com curto-circuito, `-`/`!`, literais inteiros/booleanos e chamadas a
funções do programa (≤ 6 registradores de argumentos, contando `str` como dois).

Fora do subconjunto: impressão de `bool`/`str` interpolado, `enum`,
`impl`/métodos, `unsafe`, atributos, struct por
valor em parâmetro/retorno/argumento, struct com campo struct, struct vazio,
campo de struct de tipo `str`, struct aninhado, comparação (`==`/`!=`),
concatenação e formatação de `str`, `main` retornando `str`, assinatura acima de
6 registradores, `f32`/`f64`, slices,
ponteiros, generics, `Result`/`?`, closures, `for`, `pub`, imports
qualificados/seletivos e pacotes.

### Validação executada neste ciclo

- `zig build` — sucesso (gera `zig-out/bin/kync`, versão `0.3.7-alpha.1`).
- `zig build test` — **204 testes** (197 do compilador + 7 da std), todos
  passando. Deste ciclo: semântica (struct aceito em parâmetro/retorno/argumento,
  identidades nominais preservadas na assinatura e na inferência de `let`,
  structs diferentes recusados em argumento e em retorno, retorno com 7 campos
  recusado, limite contado em registradores com struct de 4 campos + 3 `i32`) e
  backends (prólogo com um `movl` por campo, retorno em `%eax`/`%edx`, chamada
  empilhando um campo por vez, `let` de chamada que devolve struct gravando os
  campos, struct aninhado em expressão; no IR, assinatura achatada, agregado
  `{ i32, i32 }` com `insertvalue`, `extractvalue` do retorno e `{ i1, i32 }`
  para campo `bool`). O negativo antigo de "struct por valor não suportado" foi
  substituído por um positivo do novo contrato.
- `zig build e2e` — **102/102** casos: 26 fixtures comportamentais (3 novas de
  struct por valor: `struct_passagem`, `struct_retorno`, `struct_campos_tipos`),
  7 programas multi-arquivo (novo `import_struct_abi`), 50 `case_N.kyn`, 16
  negativas (`struct_param_unsupported` saiu; entraram `struct_nominal` e
  `struct_registradores`) e 3 módulos negativos.
- `zig fmt --check build.zig src std` — sem diferenças.
- Execução manual fora da suíte: programa com `origem()`, `soma(p)`,
  `desloca(p, d)`, `eco(p)`, `par(tres())` e chamadas aninhadas
  (`soma(eco(P { ... }))`) → binário via `as`/`ld` imprime `7 30 7 27 7 15` e sai
  com `27`; `emit --llvm` do mesmo programa confere assinaturas achatadas,
  `insertvalue` e `extractvalue`.
- `docs/tutorial.md`: 20 blocos `kyn` extraídos e passados por `kync check`; 15
  compilam e foram executados (código de saída/stdout conferidos), 1 é arquivo de
  biblioteca sem `main`, 3 falham exatamente com o erro documentado e 1 importa o
  módulo ao lado.
- `zig build validate-ir` sem LLVM local — avisa e sai 0 (skip documentado);
  o script percorre 83 módulos quando há `llvm-as`/`clang` (estrito no CI).
- Nota de método: a contagem de testes só é confiável com cache limpo
  (`rm -rf .zig-cache`), caso contrário `zig build test` reporta o passo
  "cached" e mantém o número antigo.

## 3. Decisões técnicas registradas

1. **Toolchain:** Zig 0.17.0 fixado em `build.zig.zon`; obtenção via wheel PyPI
   `ziglang` quando não houver instalador oficial disponível.
2. **Contrato de tokens:** `Tag` tipada + `Span` + slice da entrada. Whitespace e
   comentários não chegam ao parser. `&`/`|` isolados são inválidos.
3. **AST independente da semântica:** resolução é anotada por índices
   (`Expr.resolved`, `Stmt.decl_symbol`, `Assign.resolved`, `Call.callee_fn`);
   nenhum tipo é armazenado na AST.
4. **Diagnósticos acumulativos:** a semântica coleta erros e usa `unknown` para
   evitar cascata; o parser falha no primeiro erro sintático.
5. **Ownership:** uma arena por compilação (`driver.compile`) possui AST, tabela
   de símbolos, diagnósticos e saída; `Result.deinit()` libera.
6. **Backends textuais** atrás de uma interface única
   (`codegen.generate`), escolhidos por enum `Backend`.
7. **x86-64 como caminho de validação executável:** sem libc, `_start` chama
   `kyn_main` e encerra por syscall `exit`; frame de 8 bytes por slot; `bool`
   materializado em 32 bits (diferença conhecida em relação ao IR, que usa i1).
8. **LLVM IR é validado por ferramenta no CI:** testes locais verificam
   estrutura (todo bloco termina com `ret`/`br`/`unreachable`); `llvm-as`
   (ou `clang -x ir`) valida os módulos de fato. Sem LLVM local, o passo
   `validate-ir` faz skip; o CI usa `validate-ir-strict`, que falha.
   O `target triple` é fixo em `x86_64-unknown-linux-gnu`.
9. **Limites documentados do backend nativo:** ≤ 6 parâmetros/argumentos
   (diagnosticados pela semântica), sem chamadas externas, sem otimização.
10. **Módulos sem runtime:** `import "caminho";` é resolvido em tempo de
    compilação por `driver.compilePath`, relativo ao arquivo importador; o grafo
    é percorrido em pré-ordem de DFS, deduplicado por caminho normalizado
    (`std.fs.path.resolveAlloc`, sem syscalls) e achatado em um único
    `ast.Program` antes da semântica — por isso nenhum backend mudou. Ciclos
    (`.import_cycle`), arquivos ausentes (`.import_not_found`) e símbolos
    repetidos (`.duplicate_declaration`) são diagnosticados. Visibilidade,
    imports qualificados/seletivos e pacotes não existem.
11. **Structs por valor, sem escape:** campos escalares apenas; variável de
    struct reserva `1 + n` slots (base + um por campo). x86-64 usa `movl` nos
    offsets; LLVM usa substituição escalar (um `alloca` por campo, sem tipos
    agregados nem `getelementptr`), o que é semanticamente equivalente enquanto
    o struct não escapa da função. Passagem por valor em
    parâmetro/retorno/argumento, campo struct e struct vazio são diagnosticados
    (`.unsupported`); literais exigem todos os campos, impedindo estado
    parcialmente inicializado. Structs são registrados em duas passadas (nomes,
    depois campos) para permitir qualquer ordem de declaração.
12. **Atribuição de diagnósticos por arquivo:** cada `ast.Function` carrega
    `file_id`, `Diagnostic.file` indexa `Result.sources` e a CLI imprime o
    `arquivo:linha:coluna` correto mesmo para erros em módulos importados.
13. **Versionamento:** `0.3.6-alpha.1` (incrementada a cada ciclo integrado;
    fonte única em `build.zig.zon`); entradas antigas do CHANGELOG (até
    `v2.3.0`) marcadas como não comprovadas.
14. **CI:** GitHub Actions em `ubuntu-24.04`; a toolchain Zig vem do wheel
    oficial do PyPI (`ziglang==0.17.0.post0`) em um venv, o mesmo caminho
    documentado para o desenvolvimento local — o CI valida a própria receita.
    Ações fixadas em major (`actions/checkout@v7`).
15. **Validação nunca silenciosa:** qualquer passo de validação opcional tem
    variante estrita usada no CI.
16. **`str` é fatia estática (ponteiro + tamanho), não escalar:** a variável
    reserva dois slots (`slot` = ponteiro, `slot + 1` = tamanho), o mesmo
    mapeamento nos dois backends; literais são deduplicados por conteúdo em
    `codegen.StrPool` (rótulo `.LstrN`/constante `@.strN` por texto distinto).
    No backend nativo o texto fica em `.rodata` como lista de `.byte` (sem
    escapes) e `print` usa a syscall `write` (texto + `\n`), sem libc; no IR o
    texto é `private unnamed_addr constant [N x i8]` e `print` chama
    `write` da libc (`declare i64 @write(i32, ptr, i64)`). `print` é embutida
    (`ast.Expr.Call.builtin`), exige exatamente um `str`, devolve `void` e o
    nome é reservado para funções declaradas. Comparar `str` por conteúdo,
    concatenar e passar `str` por valor entre funções continua diagnosticado —
    nunca se compara ponteiro silenciosamente.
17. **Conferência de stdout no e2e:** `tools/e2e.sh` compara as linhas
    `// expect-stdout:` (uma por linha esperada, na ordem) além de
    `// expect-exit:`; a comparação é feita com `diff` sobre a saída real do
    binário, então conteúdo é validado, não apenas o código de saída.
18. **Builtins declarados no enum, checagem genérica:** `ast.Expr.Builtin` é a
    fonte única (`print`, `print_i32`); a semântica resolve o nome por
    `builtinByName`, exige aridade 1 e o tipo `builtinParamType`, reserva o
    nome para funções declaradas e nunca marca `callee_fn`. Assim adicionar um
    builtin exige uma entrada no enum e um arm em cada backend — sem caminho
    paralelo de resolução.
19. **`print_i32` formata sem libc no backend nativo e sem agregados no IR:**
    a rotina é emitida **uma vez por programa/módulo** (flag no
    `codegen.ProgramState`), em `.text` no assembly — nunca dentro de
    `.rodata`, o que já causou falha de segmentação durante o ciclo — e usa
    `divl` **unsigned** após `negl` para acertar `-2147483648`; no IR, o
    equivalente é `@kyn_print_i32` com `urem`/`udiv`, `select` para o módulo e
    buffer `[12 x i8]`. Nenhuma dependência de `itoa`, estado global ou
    alocação dinâmica.

20. **`str` por valor em chamadas (ABI própria, ciclo 8):** cada parâmetro,
    argumento e retorno `str` leva um par **ponteiro + tamanho**, sempre nesta
    ordem. No x86-64 os pares são `(%rdi,%rsi)`, `(%rdx,%rcx)` e `(%r8,%r9)` e o
    retorno vem em `%rax` (ponteiro) e `%rdx` (tamanho); o prólogo grava os dois
    registradores nos dois slots da variável. Chamadas com mais de um argumento
    empilham uma palavra por registrador e desempilham na ordem inversa (ordem
    de avaliação preservada); com um único argumento a passagem é direta, sem
    tocar na pilha. No IR os parâmetros viram `ptr %argN` + `i64 %argN+1` e o
    retorno é o agregado `{ ptr, i64 }` (`insertvalue` para montar,
    `extractvalue` para ler); `emitCall` recusa `str` de retorno e quem chama
    usa `strOperand`/`emitStrCall`, para não emitir `call` de agregado truncado.
21. **Limite de parâmetros é contado em palavras de registrador:** `Type.registerWords()`
    devolve 1 (escalares) ou 2 (`str`) e `max_params` é aplicado sobre essa
    soma, tanto na declaração quanto em cada chamada. Assim três `str` cabem,
    quatro não, e a mensagem cita o total e a regra (`'str' ocupa dois`) em vez
    de um número de argumentos — se o backend ganhar mais registradores o
    diagnóstico acompanha sozinho.

22. **Struct por valor em chamadas (ciclo 9):** um campo escalar = uma palavra
    de registrador, na ordem de declaração. x86-64: entrada em `%rdi`, `%rsi`,
    …; chamadas empilham uma palavra por campo e desempilham na ordem inversa;
    retorno em `%eax`, `%edx`, `%ecx`, `%r8d`, `%r9d`, `%r10d`. Campos de literal
    são avaliados na pilha antes de irem para os registradores de retorno (um
    campo nunca clobbera o outro) e um struct devolvido por chamada pode ser
    repassado direto como argumento. IR: parâmetros **achatados** em escalares e
    só o retorno é agregado `{ … }` — mantém a substituição escalar e dispensa
    `getelementptr`. Identidade nominal verificada em argumento, retorno e
    anotação (`param_struct_ids`/`return_struct_id`).
23. **Limite de registradores é a fonte única de verdade:** `sema.registerWordsOf`
    (1 por campo de struct, 2 por `str`, 1 por escalar) é usada pela declaração,
    pela chamada, pelo retorno e pelos dois backends. Retorno de struct acima de
    6 campos é diagnosticado, e o teste de consistência em `x86_64.zig` amarra a
    tabela SysV ao limite da semântica.

## 4. Pendências (priorizadas)

1. **Linguagem:** sem `enum`, `impl`/métodos, `unsafe`, atributos, tipos
   numéricos além de `i32`, slices e ponteiros; structs não têm campo `str`,
   campo struct nem forma vazia, e a passagem por valor está limitada a 6 campos
   (acima disso o retorno é diagnosticado) — `str` não tem comparação,
   concatenação nem formatação; a saída cobre texto literal e `i32` (não há
   impressão de `bool` nem `str` interpolado).
2. **Módulos:** escopo único achatado (nomes de função precisam ser únicos no
   programa), sem `pub`/visibilidade, imports qualificados/seletivos, aliases,
   pacotes ou manifesto; deduplicação é por caminho normalizado (não por
   inode/realpath), então symlinks podem carregar o mesmo arquivo duas vezes.
3. **Tipos:** sem `i64`/`u32`/`f32`/`f64`, sem checagem de fluxo completa
   (só `alwaysReturns` estrutural), sem casts/conversões.
4. **Std experimental** com APIs que não fazem E/S real; `kyn:core` × `kyn:std`
   ainda não separados em módulos de build distintos.
5. **Self-hosting:** `src/kyn/` e `src/compiler/` continuam placeholders.
6. **Runner de fixtures** cobre apenas sucesso/negativo genérico; não confere
   mensagem/posição esperada por arquivo.
7. **Fuzz/edge cases** de `tests/fuzz/` não são executados por nenhum runner.
8. **`tests/diagnostics/*.kyn`** não são verificados pelo e2e (só
   `tests/e2e/negative`).
9. **Backend nativo** restrito a Linux x86-64, ≤ 6 registradores de argumentos
   (`str` conta dois, campo de struct um), sem libc e sem otimização; structs
   maiores que a tabela de registradores ficam para depois (pilha ou `sret`);
   sem testes de regressão com IR/asm completos (golden files).
10. **CI** roda apenas em `ubuntu-24.04` (sem matriz de SO, sem cache de build,
   sem artefatos publicados); `target triple` do IR é fixo.
11. **Cobertura de testes do compiler** concentrada em exemplos; sem medição de
    cobertura nem testes de estresse de entradas grandes.

## 5. Próxima etapa prioritária

**`enum` com payload escalar + `switch` exaustivo.**

- Por quê: `enum` é a base de error sets/error unions (0.6), de `impl` com
  retorno de estado e de qualquer modelagem de protocolo/estado em sistemas; o
  `switch` exaustivo é a forma do Kyn de transformar "esqueci um caso" em erro de
  compilação, coerente com a regra central do projeto.
- Escopo mínimo:
  1. Parser/AST: `enum Nome { A, B(i32), C }` (payload escalar único) e
     `switch valor { A => { ... }, B(n) => { ... } }` com `else` opcional apenas
     quando a exaustividade não é conhecida estaticamente.
  2. Semântica: tipo `enum` nominal (`EnumInfo` + id), construtor `Nome.Caso(...)`,
     payload ligado a um símbolo no braço do `switch`, verificação de
     exaustividade caso a caso (faltando → erro que lista os casos ausentes) e
     diagnóstico de braço redundante/inatingível.
  3. Backends: representação `tag` (i32) + payload em slot separado (mesma
     convenção nos dois); `switch` comparando a tag em cadeia (x86) / `switch`
     do IR com blocos por caso; passagem por valor de enum entre funções pode
     reusar `registerWordsOf` (enum = 1 palavra, com payload contado).
  4. Testes: unitários de parser/sema (exaustividade, caso desconhecido,
     payload com tipo errado, enum duplicado) e de codegen (tag/`switch` nos dois
     backends); fixtures e2e positivas (com stdout) e negativas (caso faltando,
     braço inatingível).
  5. Docs: `docs/syntax.ebnf`, `docs/language_reference.md`, `docs/tutorial.md`
     (novo capítulo), `docs/architecture.md`, `docs/status.md`, `README.md`,
     `ROADMAP.md`, `CHANGELOG.md` e este arquivo; versão `0.3.8-alpha.1`.
- Critérios de conclusão: `zig build test`, `zig build e2e` e
  `validate-ir-strict` verdes no CI, com um `enum` usado em programa real e um
  `switch` não exaustivo reprovado.

**Depois disso (ordem sugerida):** `impl`/métodos com `self` (struct e enum por
valor) → tipos numéricos maiores (`i64`, `u8`, `f32`) e conversões explícitas →
impressão de `bool` e concatenação/interpolação de `str` → ponteiros, arrays e
slices com layout documentado → `unsafe`/`volatile`/atomics/MMIO → error
unions/`try`/`defer` → generics/`comptime` → FFI C e cross-compilation
(ARM64/freestanding) → diagnósticos de primeira classe (códigos estáveis, notas,
fix-it, JSON/LSP) → self-hosting em Kyn.

## 6. Histórico dos ciclos

| Ciclo | O que foi feito | Validado? |
|---|---|---|
| Anterior | Análise do repositório; declarado bloqueio de toolchain (Zig 0.17.0 "indisponível") | Não (nenhum build/teste) |
| Ciclo 1 (2026-11-07) | Toolchain obtida via PyPI; `build.zig`+`.zon`; lexer/AST/parser/semântica reescritos com spans e diagnósticos; backends LLVM IR e x86-64; CLI `kync`; driver; 96 testes unitários; suíte e2e com 64 casos; documentação reconciliada; testes antigos consolidados. Integrado via PR #7 (`5217796`). | Sim: `zig build`, `zig build test`, `zig build e2e`, `zig fmt --check`; retestado após o merge |
| Ciclo 2 (2026-11-07) | CI no GitHub Actions (venv Python + wheel PyPI da toolchain; LLVM instalado no runner); `tools/validate-ir.sh` validando o IR de 59 fixtures com `llvm-as`, em modo estrito; passos `zig build validate-ir` e `validate-ir-strict`; versão `0.3.1-alpha.1`; docs atualizadas com a evidência do run. Integrado via PR #8 (`837d4ed`). | Sim: runs `42413779278`, `42414049577` e `42414408475` (main) verdes: fmt + 96 testes + 64 e2e + IR estrito; suíte local reproduzida do zero antes e depois do merge |
| Ciclo 3 (2026-11-07) | Registro da integração do CI no estado do projeto (`DEVELOPMENT_STATE.md`, badge no README, entradas do CHANGELOG). Integrado via PR #9 (`449f78b`). | Sim: run `42414846887` (main) verde |
| Ciclo 4 (2026-11-07) | `import` e compilação multi-arquivo: lexer de strings + `import`; parser com `import` no topo; `driver.compilePath` com DFS pré-ordem, dedupe por caminho normalizado, `.import_cycle`/`.import_not_found`; `Diagnostic.file`/`addInFile` e mensagens citando o arquivo; CLI multi-arquivo; 21 testes novos (115 no total); 3 fixtures e2e multi-arquivo executadas + 3 negativas com mensagem esperada; `validate-ir` cobre 62 módulos; versão `0.3.2-alpha.1` (agora derivada de `build.zig.zon`). Integrado via PR #10 (`1c149dd`). | Sim: local (108 testes do compilador, 70/70 e2e, `fmt --check`) e CI runs `42415765698` (PR) e `42415945385` (main), ambos verdes com IR estrito; suíte local retestada em `main` após o merge |
| Ciclo 5 (2026-11-07) | `struct` com valor: lexer (`struct`, `.`), parser (declaração, literal, acesso e atribuição a campo, condição sem ambiguidade), AST (`structs`, `field_access`, `struct_literal`, `field_assign`), semântica (`Type.aggregate`, `Checked.structs` em duas passadas, literais validados e restrições diagnosticadas), layout `1 + n` slots com substituição escalar no LLVM, driver propagando structs entre módulos, 16 testes novos (139 no total), 3 fixtures e2e com `struct` executadas + 1 módulo + 3 negativas (77/77), `validate-ir` com 66 módulos; versão `0.3.3-alpha.1`. Integrado via PR #13 (`4234c07`). | Sim: local (132 testes do compilador, 77/77 e2e, `fmt --check`) e CI runs `42417725687` (PR) e `42417878774` (main), ambos verdes com IR estrito; suíte local retestada em `main` após o merge |
| Ciclo 6 (2026-11-07) | `str` e `print`: literal de string como expressão, `ast.Expr.Call.builtin`, `Type.str` em dois slots (ponteiro + tamanho), `codegen.StrPool` deduplicando literais, texto em `.rodata` com syscall `write` no backend nativo e `@.strN` + `declare i64 @write` no IR; `print` embutido (um `str`, saída `void`, nome reservado) e restrições diagnosticadas (parâmetro/retorno/campo `str`, aritmética, condição, `==`/`!=`, literal solto); correção de contrato em `let`/`var` com `void`; `tools/e2e.sh` compara `// expect-stdout:`; 29 testes novos (169 no total), 4 fixtures com `print` + 1 módulo + 4 negativas (86/86), `validate-ir` com 71 módulos; versão `0.3.4-alpha.1`. Integrado via PR #15. | Sim: local (162 testes do compilador, 86/86 e2e com stdout, `fmt --check`, saída de binário via `as`/`ld`) e CI do PR #15 (run `42420648098`) verde com IR estrito; suíte local retestada em `main` após o merge |
| Ciclo 7 (2026-11-07) | `print_i32`: `ast.Expr.Builtin` com `print_i32` e checagem genérica de builtins (aridade, tipo esperado e nome reservado derivados do enum); rotina `kyn_print_i32` emitida uma vez por programa em `.text` no backend nativo (`divl` unsigned, buffer de 12 bytes, sem libc) e `@kyn_print_i32` no IR (`alloca [12 x i8]`, `phi`, `urem`/`udiv`, `select`, `zext`); 12 testes novos (181 no total), 4 fixtures novas com stdout conferido (inclui INT_MIN) + 2 negativas (92/92), `validate-ir` com 75 módulos; versão `0.3.5-alpha.1`. Integrado via PR #17 (`87903db`). | Sim: local (174 testes do compilador, 92/92 e2e com stdout, `fmt --check`, execução via `as`/`ld`, IR conferido) e CI runs `42423945656` (PR) e `42424147963` (`main`), ambos verdes com IR estrito; suíte local retestada em `main` após o merge |
| Ciclo 8 (2026-11-07) | `str` por valor em parâmetros e retornos: `Type.isValue()` inclui `.str` e novo `Type.registerWords()` (2 para `str`); limite de 6 registradores por assinatura contado em palavras (`função '...' ocupa N registradores...` / `chamada de '...' ocupa N ...`), substituindo `max_params`; backends com ABI própria (`(%rdi,%rsi)`, `(%rdx,%rcx)`, `(%r8,%r9)` e retorno `%rax`/`%rdx` no x86-64; `ptr`+`i64` e `{ ptr, i64 }` com `insertvalue`/`extractvalue` no IR), incluindo caminho rápido para um argumento e desempilhamento inverso para vários; 12 testes novos e 2 negativos obsoletos substituídos (193 no total), 3 fixtures novas com stdout + 1 módulo importado com `str` + 2 negativas novas (97/97), `validate-ir` com 79 módulos; versão `0.3.6-alpha.1`. Integrado via PR #19 (`9ec07be`). | Sim: local (186 testes do compilador, 97/97 e2e, `fmt --check`, execução via `as`/`ld` de `eco`/`titulo`/`marca` aninhados, IR conferido à mão) e CI runs `42425605484` (PR #19) e `42425757025` (`main`), ambos verdes com IR estrito; suíte local retestada em `main` após o merge |
| Ciclo 9 (2026-11-07, atual) | Struct por valor em parâmetros, argumentos e retornos: `FunctionInfo.param_struct_ids`/`return_struct_id` e `structIdOfExpr` reconhecendo chamadas (inferência de `let` preserva o struct), `sema.registerWordsOf` como fonte única do limite de 6 registradores (campo = 1, `str` = 2), identidade nominal verificada em argumento/retorno/anotação e retorno limitado a 6 campos; x86-64 com entrada um registrador por campo, chamadas empilhando campo a campo e retorno em `%eax`/`%edx`/`%ecx`/`%r8d`/`%r9d`/`%r10d` (campos avaliados na pilha para não clobberar uns aos outros); IR com parâmetros achatados, retorno agregado `{ i32, i1, … }` e `insertvalue`/`extractvalue`; 11 testes novos (204 no total), 3 fixtures e2e novas + 1 módulo com struct por valor + 2 negativas (102/102), `validate-ir` com 83 módulos; **novo `docs/tutorial.md`** com 20 blocos verificados; versão `0.3.7-alpha.1`. | Sim: local (197 testes do compilador, 102/102 e2e, `fmt --check`, execução via `as`/`ld` de `origem`/`desloca`/`eco`/`par`, IR conferido à mão, tutorial verificado bloco a bloco); CI do PR e de `main` registrados no cabeçalho |

---

**Regra de retomada:** reinstalar a toolchain (§1), rodar `zig build test` e
`zig build e2e` (e `zig build validate-ir` se houver LLVM), conferir
`git status` e o último CI em `main` (`gh run list --branch main`), e só então
seguir para §5. Não repetir etapas já validadas nem presumir resultados sem
executar os comandos.
