# DEVELOPMENT_STATE — Kyn

**Mantido por:** agente de continuidade (Arena)
**Branch ativa:** `arena/b8209933-kyn` (a partir de `ebc58b3` de `main`)
**Integração:** PRs #7–#11 (módulos/`import`) e PR #13 (`struct` com valor,
`4234c07`) mesclados em `main` (2026-11-07). O ciclo atual (`str` + `print`)
está no PR deste branch — os SHAs e runs ficam no §6 após a integração.
**Versão do projeto:** `0.3.4-alpha.1`
**Última validação:** 2026-11-07 — local (Zig 0.17.0 + GNU `as`/`ld`, Linux
x86-64): `zig build`, `zig build test` (169 testes), `zig build e2e` (86/86,
com stdout conferido), `zig fmt --check` e `kync --version`; o IR de 71 módulos
é validado por `llvm-as` no CI
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
| AST | `src/ast/ast.zig` | programa com `imports` e `structs`, funções (`file_id`), params, let/var, assign (variável e campo), return, if/else, while, blocos, expressões (acesso a campo, literal de struct, literal de string), `Call.builtin` (`print`) |
| Parser | `src/parser/parser.zig` | programa completo, `import` antes das declarações, `struct`, literais e acesso a campo, precedência/associatividade, erro no primeiro token inválido |
| Semântica | `src/sema/sema.zig` | escopos, resolução, `i32`/`bool`/`str`/`void`/struct, campos e literais de struct, `str` com dois slots, `print` embutido, mutabilidade, chamadas, slots, `main`, `alwaysReturns` |
| Backend LLVM | `src/codegen/llvm.zig` | IR derivado da AST; structs por substituição escalar (um `alloca` por campo); `str` em `@.strN` + `declare i64 @write` + dois `alloca`; validado por `llvm-as` no CI |
| Backend nativo | `src/codegen/x86_64.zig` | System V sem libc; struct em slots consecutivos; `str` em dois slots (ponteiro/tamanho), texto em `.rodata` e `print` por syscall `write`; validado executando binários e conferindo stdout |
| Driver | `src/driver.zig` | arena por compilação; `compile` (buffer único) e `compilePath` (grafo de imports, dedupe, ciclos, flatten); `Result.deinit()` |
| `unsafe`/`repr(C)` | `src/sema/unsafe.zig` | política isolada e testada; sem nós na AST ainda |
| Self-hosting | `src/kyn/*.kyn`, `src/compiler/*.kyn` | placeholders; não executados |
| Std | `std/core/*`, `std/os/*` | stubs experimentais; compilam nos testes |
| Fixtures | `tests/` | 50 `integration/case_N.kyn` (suportadas) + 36 entradas em `tests/e2e` (16 positivas, 5 módulos, 12 negativas, 3 módulos negativos); demais ainda não suportadas |
| CI | `.github/workflows/ci.yml` | ubuntu-24.04: fmt + test + e2e + validação de IR estrita |
| Validação de IR | `tools/validate-ir.sh` | `llvm-as`/`clang` sobre 71 módulos (inclui multi-arquivo, `struct` e `str`/`print`); estrito no CI |

### Subconjunto aceito hoje

`import "caminho.kyn";` antes das declarações (caminho relativo ao arquivo
importador, cada arquivo carregado uma vez, símbolos achatados em escopo único),
`struct Nome { campo: tipo, ... }`, literais `Nome { campo: valor }` (todos os
campos, uma vez cada), acesso `p.campo` e atribuição `p.campo = v` em `var`,
cópia de struct por valor, literais de string, variáveis `str` (inferidas ou
anotadas) com cópia e atribuição, `print(s: str)` embutido (texto + quebra de
linha), `fn`, `let`/`var` (inicializador obrigatório),
inferência ou anotação (`i32`/`bool`/`str`/`void`/struct), atribuição só em `var`,
`return`, `if`/`else`/`else if`, `while`, blocos, aritmética, comparações,
`&&`/`||` com curto-circuito, `-`/`!`, literais inteiros/booleanos e chamadas a
funções do programa (≤ 6 args).

Fora do subconjunto: `enum`, `impl`/métodos, `unsafe`, atributos, struct por
valor em parâmetro/retorno/argumento, struct com campo struct, struct vazio,
`str` em parâmetro/retorno/argumento, campo de struct de tipo `str`, comparação
(`==`/`!=`), concatenação e formatação de `str`, `f32`/`f64`, slices,
ponteiros, generics, `Result`/`?`, closures, `for`, `pub`, imports
qualificados/seletivos e pacotes.

### Validação executada neste ciclo

- `zig build` — sucesso (gera `zig-out/bin/kync`, versão `0.3.4-alpha.1`).
- `zig build test` — **169 testes** (162 do compilador + 7 da std), todos
  passando. Inclui 29 novos deste ciclo: parser (literal de string como
  expressão, string vazia, string não terminada), pool de strings, semântica
  (`str` inferido com dois slots, `print` com variável/literal, tipo errado,
  número de argumentos, aritmética/condição/comparação com `str`, `str` em
  parâmetro/retorno/campo, nome `print` reservado, literal solto,
  imutabilidade), backends (texto em `.rodata`, dedupe de literais, slots
  ponteiro/tamanho, `write`/`@.strN` no LLVM, string vazia) e o contrato de
  `let`/`var` com inicializador `void` (um único diagnóstico, sem chegar ao
  backend com tipo sem representação).
- `zig build e2e` — **86/86** casos: 16 fixtures comportamentais executadas
  (4 com `print`, comparando **stdout** linha a linha), 5 programas
  multi-arquivo (inclui `import_print`, saída 4), 50 fixtures `case_N.kyn`,
  12 fixtures negativas (3 de struct, 3 de `str`/`print`, 1 de campo `str`) e
  3 módulos negativos com trecho de mensagem esperado (`expect-error.txt`).
- `zig fmt --check build.zig src std` — sem diferenças.
- `zig build validate-ir` sem LLVM local — avisa e sai 0 (skip documentado);
  o script percorre 71 módulos quando há `llvm-as`/`clang`.
- CLI exercitada: `emit --asm` + `as` + `ld` de um programa com quatro `print`
  (saída de texto conferida e código 7), `emit --llvm` do mesmo programa
  (`@.strN`, `declare i64 @write`, dois `alloca` por `str`) e `check` nos
  programas negativos (1 diagnóstico cada, mensagem correta).
- Comparação do desenho: `print` no backend nativo não depende de libc (syscall
  `write`), enquanto o IR usa `write` da libc — decisão registrada em §3 (16).

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
13. **Versionamento:** `0.3.4-alpha.1`; entradas antigas do CHANGELOG (até
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

## 4. Pendências (priorizadas)

1. **Linguagem:** sem `enum`, `impl`/métodos, `unsafe`, atributos, tipos
   numéricos além de `i32`, slices e ponteiros; structs e `str` só em variáveis
   locais (sem parâmetro/retorno/argumento por valor, sem campo `str` ou struct,
   sem struct vazio); `str` não tem comparação, concatenação nem formatação de
   valores (só texto literal) e não há como imprimir inteiros.
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

**Imprimir valores: `print_i32(n: i32)` (formatação decimal na saída).**

- Por quê: com `print` já existe texto observável, mas um programa só consegue
  escrever literais de string — o resultado de um cálculo continua visível
  apenas pelo código de saída (≤ 255). Formatar `i32` fecha essa lacuna e
  destrava fixtures que comparam **conteúdo calculado**, sem depender de ABI de
  agregados, e prepara `kyn:core` para E/S de verdade.
- Escopo mínimo proposto (incremental e testável):
  1. Semântica: novo builtin `print_i32(n: i32) -> void` (mesmo caminho de
     `ast.Expr.Call.builtin` já usado por `print`), exigindo exatamente um
     `i32`; nomes de builtins reservados para funções declaradas.
  2. x86-64: rotina de conversão decimal (divisão por 10 com sinal, dígitos em
     buffer de pilha de 12 bytes, `write` do buffer e do `\n`); nenhuma
     dependência de libc e nenhum estado global.
  3. LLVM IR: mesma lógica como função interna emitida uma vez por módulo
     (`@kyn_print_i32`) com `alloca`, laço e `write`; sem agregados.
  4. Testes: unitários de semântica (tipo errado, número de argumentos, nomes
     reservados) e de codegen (ordem dos dígitos, sinal, `INT_MIN`,
     presença da rotina); e2e com `// expect-stdout:` para 0, positivos,
     negativos e o menor `i32`.
  5. Docs: `docs/syntax.ebnf`, `docs/architecture.md`, `docs/status.md`,
     `docs/language_reference.md`, `README.md`, `CHANGELOG.md` e este arquivo;
     versão `0.3.5-alpha.1`.
- Critérios de conclusão: `zig build test`, `zig build e2e` e
  `validate-ir-strict` verdes no CI, com stdout dos números conferido.

**Depois disso (ordem sugerida):** `str` por valor em parâmetro/retorno
(ponteiro + tamanho; ABI própria documentada) → struct por valor e struct
aninhado → `enum`/`impl` (métodos com `self`) → ampliar tipos numéricos
(`i64`, `u8`, `f32`...) → concatenação/interpolação de `str` → conectar
`unsafe`/`repr(C)` e FFI → `target triple` configurável → início do
self-hosting em Kyn.

## 6. Histórico dos ciclos

| Ciclo | O que foi feito | Validado? |
|---|---|---|
| Anterior | Análise do repositório; declarado bloqueio de toolchain (Zig 0.17.0 "indisponível") | Não (nenhum build/teste) |
| Ciclo 1 (2026-11-07) | Toolchain obtida via PyPI; `build.zig`+`.zon`; lexer/AST/parser/semântica reescritos com spans e diagnósticos; backends LLVM IR e x86-64; CLI `kync`; driver; 96 testes unitários; suíte e2e com 64 casos; documentação reconciliada; testes antigos consolidados. Integrado via PR #7 (`5217796`). | Sim: `zig build`, `zig build test`, `zig build e2e`, `zig fmt --check`; retestado após o merge |
| Ciclo 2 (2026-11-07) | CI no GitHub Actions (venv Python + wheel PyPI da toolchain; LLVM instalado no runner); `tools/validate-ir.sh` validando o IR de 59 fixtures com `llvm-as`, em modo estrito; passos `zig build validate-ir` e `validate-ir-strict`; versão `0.3.1-alpha.1`; docs atualizadas com a evidência do run. Integrado via PR #8 (`837d4ed`). | Sim: runs `42413779278`, `42414049577` e `42414408475` (main) verdes: fmt + 96 testes + 64 e2e + IR estrito; suíte local reproduzida do zero antes e depois do merge |
| Ciclo 3 (2026-11-07) | Registro da integração do CI no estado do projeto (`DEVELOPMENT_STATE.md`, badge no README, entradas do CHANGELOG). Integrado via PR #9 (`449f78b`). | Sim: run `42414846887` (main) verde |
| Ciclo 4 (2026-11-07) | `import` e compilação multi-arquivo: lexer de strings + `import`; parser com `import` no topo; `driver.compilePath` com DFS pré-ordem, dedupe por caminho normalizado, `.import_cycle`/`.import_not_found`; `Diagnostic.file`/`addInFile` e mensagens citando o arquivo; CLI multi-arquivo; 21 testes novos (115 no total); 3 fixtures e2e multi-arquivo executadas + 3 negativas com mensagem esperada; `validate-ir` cobre 62 módulos; versão `0.3.2-alpha.1` (agora derivada de `build.zig.zon`). Integrado via PR #10 (`1c149dd`). | Sim: local (108 testes do compilador, 70/70 e2e, `fmt --check`) e CI runs `42415765698` (PR) e `42415945385` (main), ambos verdes com IR estrito; suíte local retestada em `main` após o merge |
| Ciclo 5 (2026-11-07, atual) | `struct` com valor: lexer (`struct`, `.`), parser (declaração, literal, acesso e atribuição a campo, condição sem ambiguidade), AST (`structs`, `field_access`, `struct_literal`, `field_assign`), semântica (`Type.aggregate`, `Checked.structs` em duas passadas, literais validados e restrições diagnosticadas), layout `1 + n` slots com substituição escalar no LLVM, driver propagando structs entre módulos, 16 testes novos (139 no total), 3 fixtures e2e com `struct` executadas + 1 módulo + 3 negativas (77/77), `validate-ir` com 66 módulos; versão `0.3.3-alpha.1`. Integrado via PR #13 (`4234c07`). | Sim: local (132 testes do compilador, 77/77 e2e, `fmt --check`) e CI runs `42417725687` (PR) e `42417878774` (main), ambos verdes com IR estrito; suíte local retestada em `main` após o merge |

---

**Regra de retomada:** reinstalar a toolchain (§1), rodar `zig build test` e
`zig build e2e` (e `zig build validate-ir` se houver LLVM), conferir
`git status` e o último CI em `main` (`gh run list --branch main`), e só então
seguir para §5. Não repetir etapas já validadas nem presumir resultados sem
executar os comandos.
