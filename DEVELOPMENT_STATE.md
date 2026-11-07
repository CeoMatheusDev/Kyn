# DEVELOPMENT_STATE — Kyn

**Mantido por:** agente de continuidade (Arena)
**Branch ativa:** `arena/2089e297-kyn` (a partir de `89ca6ce` de `main`)
**Integração:** PRs #7–#11 (módulos/`import`), PR #13 (`struct` com valor,
`4234c07`) e PR #15 (`str`/`print`, `89ca6ce`) mesclados em `main`
(2026-11-07); CI verde no PR #15 (run `42420648098`) e no merge
(`42421025867`). O ciclo atual (`print_i32`) está no PR deste branch — SHAs e
runs ficam no §6 após a integração.
**Versão do projeto:** `0.3.5-alpha.1`
**Última validação:** 2026-11-07 — local (Zig 0.17.0 + GNU `as`/`ld`, Linux
x86-64): `zig build`, `zig build test` (181 testes), `zig build e2e` (92/92,
com stdout conferido, inclui INT_MIN), `zig fmt --check` e `kync --version`
(`0.3.5-alpha.1`); o IR de 75 módulos é validado por `llvm-as` no CI
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
| Semântica | `src/sema/sema.zig` | escopos, resolução, `i32`/`bool`/`str`/`void`/struct, campos e literais de struct, `str` com dois slots, builtins genéricos (`print`/`print_i32`: aridade, tipo e nome reservado), mutabilidade, chamadas, slots, `main`, `alwaysReturns` |
| Backend LLVM | `src/codegen/llvm.zig` | IR derivado da AST; structs por substituição escalar (um `alloca` por campo); `str` em `@.strN` + `declare i64 @write` + dois `alloca`; `print_i32` via `@kyn_print_i32` (uma vez por módulo); validado por `llvm-as` no CI |
| Backend nativo | `src/codegen/x86_64.zig` | System V sem libc; struct em slots consecutivos; `str` em dois slots (ponteiro/tamanho), texto em `.rodata` e `print` por syscall `write`; `print_i32` com rotina decimal única em `.text`; validado executando binários e conferindo stdout |
| Driver | `src/driver.zig` | arena por compilação; `compile` (buffer único) e `compilePath` (grafo de imports, dedupe, ciclos, flatten); `Result.deinit()` |
| `unsafe`/`repr(C)` | `src/sema/unsafe.zig` | política isolada e testada; sem nós na AST ainda |
| Self-hosting | `src/kyn/*.kyn`, `src/compiler/*.kyn` | placeholders; não executados |
| Std | `std/core/*`, `std/os/*` | stubs experimentais; compilam nos testes |
| Fixtures | `tests/` | 50 `integration/case_N.kyn` (suportadas) + 42 entradas em `tests/e2e` (20 positivas, 5 módulos, 14 negativas, 3 módulos negativos); demais ainda não suportadas |
| CI | `.github/workflows/ci.yml` | ubuntu-24.04: fmt + test + e2e + validação de IR estrita |
| Validação de IR | `tools/validate-ir.sh` | `llvm-as`/`clang` sobre 75 módulos (inclui multi-arquivo, `struct`, `str`/`print` e `print_i32`); estrito no CI |

### Subconjunto aceito hoje

`import "caminho.kyn";` antes das declarações (caminho relativo ao arquivo
importador, cada arquivo carregado uma vez, símbolos achatados em escopo único),
`struct Nome { campo: tipo, ... }`, literais `Nome { campo: valor }` (todos os
campos, uma vez cada), acesso `p.campo` e atribuição `p.campo = v` em `var`,
cópia de struct por valor, literais de string, variáveis `str` (inferidas ou
anotadas) com cópia e atribuição, `print(s: str)` e `print_i32(n: i32)`
embutidos (texto/decimais + quebra de linha), `fn`, `let`/`var`
(inicializador obrigatório),
inferência ou anotação (`i32`/`bool`/`str`/`void`/struct), atribuição só em `var`,
`return`, `if`/`else`/`else if`, `while`, blocos, aritmética, comparações,
`&&`/`||` com curto-circuito, `-`/`!`, literais inteiros/booleanos e chamadas a
funções do programa (≤ 6 args).

Fora do subconjunto: impressão de `bool`/`str` interpolado, `enum`,
`impl`/métodos, `unsafe`, atributos, struct por
valor em parâmetro/retorno/argumento, struct com campo struct, struct vazio,
`str` em parâmetro/retorno/argumento, campo de struct de tipo `str`, comparação
(`==`/`!=`), concatenação e formatação de `str`, `f32`/`f64`, slices,
ponteiros, generics, `Result`/`?`, closures, `for`, `pub`, imports
qualificados/seletivos e pacotes.

### Validação executada neste ciclo

- `zig build` — sucesso (gera `zig-out/bin/kync`, versão `0.3.5-alpha.1`).
- `zig build test` — **181 testes** (174 do compilador + 7 da std), todos
  passando. Inclui 12 novos deste ciclo: parser (chamada `print_i32` com
  expressão), semântica (aceita `i32`, tipo errado, aridade 0 e 2, nome
  reservado, `void` não armazenável) e backends (rotina decimal em `.text`,
  uma única emissão, ausência quando não usada; no IR, `@kyn_print_i32` com
  `urem`/`udiv`, `store i8 45`, `getelementptr` do buffer e duas chamadas a
  `write`).
- `zig build e2e` — **92/92** casos: 20 fixtures comportamentais executadas
  (4 novas com `print_i32`: `print_int_basic` com 0/7/42/1000/-7,
  `print_int_extremos` com INT_MAX/INT_MIN/9 dígitos, `print_int_loop` dentro
  de `while`, e `print_misto` com texto e número intercalados — todas com
  stdout conferido), 5 programas multi-arquivo, 50 fixtures `case_N.kyn`,
  14 fixtures negativas (2 novas de `print_i32`, com exatamente 1 diagnóstico
  cada) e 3 módulos negativos.
- `zig fmt --check build.zig src std` — sem diferenças (após `zig fmt`, que
  reformatou a string do helper em `x86_64.zig`).
- Execução manual fora da suíte: `emit --asm` + `as` + `ld` de um programa com
  oito `print_i32` (inclui INT_MIN e `6 * 7`) → texto correto e código de saída
  preservado; `emit --llvm` do mesmo programa → helper único e IR estrutural.
- `zig build validate-ir` sem LLVM local — avisa e sai 0 (skip documentado);
  o script percorre 75 módulos quando há `llvm-as`/`clang`.
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
13. **Versionamento:** `0.3.5-alpha.1`; entradas antigas do CHANGELOG (até
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

## 4. Pendências (priorizadas)

1. **Linguagem:** sem `enum`, `impl`/métodos, `unsafe`, atributos, tipos
   numéricos além de `i32`, slices e ponteiros; structs e `str` só em variáveis
   locais (sem parâmetro/retorno/argumento por valor, sem campo `str` ou struct,
   sem struct vazio); `str` não tem comparação nem concatenação; a saída cobre
   texto literal e `i32` (não há impressão de `bool`, `str` interpolado nem
   formatação configurável).
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
9. **Backend nativo** restrito a Linux x86-64, ≤ 6 argumentos, sem libc e sem
   otimização; sem testes de regressão com IR/asm completos (golden files).
10. **CI** roda apenas em `ubuntu-24.04` (sem matriz de SO, sem cache de build,
   sem artefatos publicados); `target triple` do IR é fixo.
11. **Cobertura de testes do compiler** concentrada em exemplos; sem medição de
    cobertura nem testes de estresse de entradas grandes.

## 5. Próxima etapa prioritária

**`str` por valor em parâmetro e retorno (ABI própria documentada).**

- Por quê: hoje `str` só existe em variáveis locais — não há como escrever um
  helper `fn titulo() -> str` nem receber texto por parâmetro, o que trava
  qualquer biblioteca real. É também o pré-requisito mais próximo de
  `impl`/métodos (struct por valor) e o item nº 6 de
  `docs/architecture.md` («como `str` atravessa chamadas»).
- Escopo mínimo proposto (incremental e testável):
  1. Semântica: permitir `str` em parâmetros e retorno de função, mantendo os
     diagnósticos apenas para campo de struct de tipo `str` e para as
     operações ainda inexistentes (comparação/concatenação). `max_params`
     continua valendo em **registradores** — `str` consome dois.
  2. x86-64: convenção documentada — cada `str` ocupa dois registradores
     consecutivos (ponteiro, tamanho), na ordem SysV (`%rdi/%rsi`,
     `%rdx/%rcx`, `%r8/%r9`), com limite de 3 parâmetros `str`; retorno em
     `%rax` (ponteiro) e `%rdx` (tamanho). `kyn_main` continua recebendo
     nada e `str` de retorno só pode ser consumido por `print`/cópia.
  3. LLVM IR: assinatura com dois parâmetros por `str` (`ptr` + `i64`) e
     retorno `{ ptr, i64 }`; `extractvalue` para ler o par — é o primeiro uso
     deliberado de tipo agregado no IR, com `llvm-as` validando no CI.
  4. Testes: unitários de semântica (aridade/tipos, `str` em retorno,
     `main` sem retorno `str`) e de codegen (dois registradores/dois
     parâmetros, ordem dos pares, `extractvalue`), e2e executado com
     `// expect-stdout:` cobrindo helper que recebe e devolve texto.
  5. Docs: `docs/syntax.ebnf`, `docs/architecture.md` (convenção de chamada),
     `docs/status.md`, `docs/language_reference.md`, `README.md`,
     `CHANGELOG.md` e este arquivo; versão `0.3.6-alpha.1`.
- Critérios de conclusão: `zig build test`, `zig build e2e` e
  `validate-ir-strict` verdes no CI, com programas reais usando `str` entre
  funções.

**Depois disso (ordem sugerida):** struct por valor e struct aninhado →
`enum`/`impl` (métodos com `self`) → tipos numéricos maiores (`i64`, `u8`,
`f32`) → impressão de `bool` e interpolação de `str` → `unsafe`/`repr(C)` e
FFI → `target triple` configurável → início do self-hosting em Kyn.

## 6. Histórico dos ciclos

| Ciclo | O que foi feito | Validado? |
|---|---|---|
| Anterior | Análise do repositório; declarado bloqueio de toolchain (Zig 0.17.0 "indisponível") | Não (nenhum build/teste) |
| Ciclo 1 (2026-11-07) | Toolchain obtida via PyPI; `build.zig`+`.zon`; lexer/AST/parser/semântica reescritos com spans e diagnósticos; backends LLVM IR e x86-64; CLI `kync`; driver; 96 testes unitários; suíte e2e com 64 casos; documentação reconciliada; testes antigos consolidados. Integrado via PR #7 (`5217796`). | Sim: `zig build`, `zig build test`, `zig build e2e`, `zig fmt --check`; retestado após o merge |
| Ciclo 2 (2026-11-07) | CI no GitHub Actions (venv Python + wheel PyPI da toolchain; LLVM instalado no runner); `tools/validate-ir.sh` validando o IR de 59 fixtures com `llvm-as`, em modo estrito; passos `zig build validate-ir` e `validate-ir-strict`; versão `0.3.1-alpha.1`; docs atualizadas com a evidência do run. Integrado via PR #8 (`837d4ed`). | Sim: runs `42413779278`, `42414049577` e `42414408475` (main) verdes: fmt + 96 testes + 64 e2e + IR estrito; suíte local reproduzida do zero antes e depois do merge |
| Ciclo 3 (2026-11-07) | Registro da integração do CI no estado do projeto (`DEVELOPMENT_STATE.md`, badge no README, entradas do CHANGELOG). Integrado via PR #9 (`449f78b`). | Sim: run `42414846887` (main) verde |
| Ciclo 4 (2026-11-07) | `import` e compilação multi-arquivo: lexer de strings + `import`; parser com `import` no topo; `driver.compilePath` com DFS pré-ordem, dedupe por caminho normalizado, `.import_cycle`/`.import_not_found`; `Diagnostic.file`/`addInFile` e mensagens citando o arquivo; CLI multi-arquivo; 21 testes novos (115 no total); 3 fixtures e2e multi-arquivo executadas + 3 negativas com mensagem esperada; `validate-ir` cobre 62 módulos; versão `0.3.2-alpha.1` (agora derivada de `build.zig.zon`). Integrado via PR #10 (`1c149dd`). | Sim: local (108 testes do compilador, 70/70 e2e, `fmt --check`) e CI runs `42415765698` (PR) e `42415945385` (main), ambos verdes com IR estrito; suíte local retestada em `main` após o merge |
| Ciclo 5 (2026-11-07) | `struct` com valor: lexer (`struct`, `.`), parser (declaração, literal, acesso e atribuição a campo, condição sem ambiguidade), AST (`structs`, `field_access`, `struct_literal`, `field_assign`), semântica (`Type.aggregate`, `Checked.structs` em duas passadas, literais validados e restrições diagnosticadas), layout `1 + n` slots com substituição escalar no LLVM, driver propagando structs entre módulos, 16 testes novos (139 no total), 3 fixtures e2e com `struct` executadas + 1 módulo + 3 negativas (77/77), `validate-ir` com 66 módulos; versão `0.3.3-alpha.1`. Integrado via PR #13 (`4234c07`). | Sim: local (132 testes do compilador, 77/77 e2e, `fmt --check`) e CI runs `42417725687` (PR) e `42417878774` (main), ambos verdes com IR estrito; suíte local retestada em `main` após o merge |
| Ciclo 6 (2026-11-07, atual) | `str` e `print`: literal de string como expressão, `ast.Expr.Call.builtin`, `Type.str` em dois slots (ponteiro + tamanho), `codegen.StrPool` deduplicando literais, texto em `.rodata` com syscall `write` no backend nativo e `@.strN` + `declare i64 @write` no IR; `print` embutido (um `str`, saída `void`, nome reservado) e restrições diagnosticadas (parâmetro/retorno/campo `str`, aritmética, condição, `==`/`!=`, literal solto); correção de contrato em `let`/`var` com `void`; `tools/e2e.sh` compara `// expect-stdout:`; 29 testes novos (169 no total), 4 fixtures com `print` + 1 módulo + 4 negativas (86/86), `validate-ir` com 71 módulos; versão `0.3.4-alpha.1`. Integrado via PR #15. | Sim: local (162 testes do compilador, 86/86 e2e com stdout, `fmt --check`, saída de binário via `as`/`ld`) e CI do PR #15 (run `42420648098`) verde com IR estrito; suíte local retestada em `main` após o merge |

---

**Regra de retomada:** reinstalar a toolchain (§1), rodar `zig build test` e
`zig build e2e` (e `zig build validate-ir` se houver LLVM), conferir
`git status` e o último CI em `main` (`gh run list --branch main`), e só então
seguir para §5. Não repetir etapas já validadas nem presumir resultados sem
executar os comandos.
