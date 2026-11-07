# DEVELOPMENT_STATE — Kyn

**Mantido por:** agente de continuidade (Arena)
**Branch ativa:** `arena/7663d1de-kyn` (a partir de `449f78b1dbdd9dc63de176c7e0dfb41b4a7291be` de `main`; `main` está em `ebc58b3`)
**Integração:** PRs #7 (`5217796`), #8 (`837d4ed`), #9 (`449f78b`), #10
(`1c149dd`, módulos/`import`) e #11 (`ebc58b3`, registro no estado) mesclados em
`main` (2026-11-07); CI em `main` verde nos runs `42415945385` e `42416270074`;
suíte local retestada após cada merge.
**Versão do projeto:** `0.3.2-alpha.1`
**Última validação:** 2026-11-07 — local pós-merge em `main` (Zig 0.17.0 + GNU
`as`/`ld`, Linux x86-64): `zig build`, `zig build test` (115 testes),
`zig build e2e` (70/70) e `zig fmt --check`; IR de 62 módulos aceito por
`llvm-as` no CI (runs `42415945385` e `42416270074`)
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
| Lexer | `src/lexer/lexer.zig` | Tokens tipados, keywords (inclui `import`), operadores 1–2 chars, literal de string sem escapes, spans; descarta trivia |
| Spans | `src/span.zig` | offset + linha/coluna 1-based; sem cópia de texto |
| Diagnósticos | `src/diagnostics.zig` | categoria estável + mensagem + linha/caret + `file` (arquivo de origem) |
| AST | `src/ast/ast.zig` | programa com `imports`, funções (`file_id`), params, let/var, assign, return, if/else, while, blocos, expressões |
| Parser | `src/parser/parser.zig` | programa completo, `import` antes das funções, precedência/associatividade, erro no primeiro token inválido |
| Semântica | `src/sema/sema.zig` | escopos, resolução, `i32`/`bool`/`void`, mutabilidade, chamadas, slots, `main`, `alwaysReturns` |
| Backend LLVM | `src/codegen/llvm.zig` | IR derivado da AST; validado só estruturalmente |
| Backend nativo | `src/codegen/x86_64.zig` | System V sem libc; validado executando binários |
| Driver | `src/driver.zig` | arena por compilação; `compile` (buffer único) e `compilePath` (grafo de imports, dedupe, ciclos, flatten); `Result.deinit()` |
| `unsafe`/`repr(C)` | `src/sema/unsafe.zig` | política isolada e testada; sem nós na AST ainda |
| Self-hosting | `src/kyn/*.kyn`, `src/compiler/*.kyn` | placeholders; não executados |
| Std | `std/core/*`, `std/os/*` | stubs experimentais; compilam nos testes |
| Fixtures | `tests/` | 50 `integration/case_N.kyn` (suportadas) + 17 em `tests/e2e` (9 positivas, 3 módulos, 5 negativas, 3 módulos negativos); demais ainda não suportadas |
| CI | `.github/workflows/ci.yml` | ubuntu-24.04: fmt + test + e2e + validação de IR estrita |
| Validação de IR | `tools/validate-ir.sh` | `llvm-as`/`clang` sobre 62 módulos (inclui os multi-arquivo); estrito no CI |

### Subconjunto aceito hoje

`import "caminho.kyn";` antes das funções (caminho relativo ao arquivo
importador, cada arquivo carregado uma vez, símbolos achatados em escopo único),
`fn`, `let`/`var` (inicializador obrigatório), inferência ou anotação
(`i32`/`bool`/`void`), atribuição só em `var`, `return`, `if`/`else`/`else if`,
`while`, blocos, aritmética, comparações, `&&`/`||` com curto-circuito, `-`/`!`,
literais inteiros/booleanos e chamadas a funções do programa (≤ 6 args).

Fora do subconjunto: `struct`, `enum`, `impl`, `unsafe`, atributos, strings em
expressões (só o literal do `import` é léxico), `f32`/`f64`, slices, ponteiros,
generics, `Result`/`?`, closures, `for`, `pub`, imports qualificados/seletivos e
pacotes.

### Validação executada neste ciclo

- `zig build` — sucesso (gera `zig-out/bin/kync`).
- `zig build test` — **115 testes** (108 do compilador + 7 da std), todos
  passando. Inclui 21 novos: lexer de strings (conteúdo/span, vazio, não
  terminado, sem quebra de linha), parser de `import` (dois imports, import após
  função, caminho sem aspas, falta de `;`, string aberta) e driver multi-arquivo
  (import simples, subdiretório, diamante sem duplicação, ciclo, arquivo
  ausente, raiz ausente, símbolo duplicado, erro semântico em módulo importado,
  erro de sintaxe em módulo importado, `import` não resolvido em `compile`).
- `zig build e2e` — **70/70** casos: 9 fixtures comportamentais executadas,
  3 programas multi-arquivo (`modules/import_basic`, `import_nested`,
  `import_diamond`) compilados, montados, ligados e executados com código de
  saída conferido, 50 fixtures `case_N.kyn`, 5 fixtures negativas e 3 módulos
  negativos (ciclo, arquivo ausente, símbolo duplicado) com trecho de mensagem
  esperado (`expect-error.txt`).
- `zig fmt --check build.zig src std` — sem diferenças.
- `zig build validate-ir` sem LLVM — avisa e sai 0 (skip documentado);
  o script agora também percorre os 3 programas multi-arquivo (62 módulos no
  total quando há `llvm-as`/`clang`).
- CLI exercitada: `check` em `tests/e2e/modules/import_nested/main.kyn`
  (código 0), `emit --llvm/--asm` em programas multi-arquivo, diagnóstico com
  `arquivo:linha:coluna` do módulo importado, arquivo raiz ausente (código 3),
  `--version` reportando `kync 0.3.2-alpha.1 (zig 0.17.0)`.
- **CI real (GitHub Actions):** runs `42415765698` (PR #10), `42415945385`
  (`main` pós-merge) e `42416270074` (`main` pós-PR #11) verdes, com
  `zig fmt --check`, `zig build test` (115), `zig build e2e` (70) e
  `build validate-ir-strict` (o `llvm-as` do runner aceitou os 62 módulos).
- Suíte local reproduzida em `main` logo após o merge (`git checkout main &&
  git pull`): testes, 70/70 e2e, `fmt --check` e `kync --version` conferidos.

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
11. **Atribuição de diagnósticos por arquivo:** cada `ast.Function` carrega
    `file_id`, `Diagnostic.file` indexa `Result.sources` e a CLI imprime o
    `arquivo:linha:coluna` correto mesmo para erros em módulos importados.
12. **Versionamento:** `0.3.2-alpha.1`; entradas antigas do CHANGELOG (até
    `v2.3.0`) marcadas como não comprovadas.
13. **CI:** GitHub Actions em `ubuntu-24.04`; a toolchain Zig vem do wheel
    oficial do PyPI (`ziglang==0.17.0.post0`) em um venv, o mesmo caminho
    documentado para o desenvolvimento local — o CI valida a própria receita.
    Ações fixadas em major (`actions/checkout@v7`).
14. **Validação nunca silenciosa:** qualquer passo de validação opcional tem
    variante estrita usada no CI.

## 4. Pendências (priorizadas)

1. **Linguagem:** sem `struct`, `enum`, `impl`, `unsafe`, atributos, strings em
   expressões, tipos numéricos além de `i32`, slices e ponteiros.
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

**`struct` com valor (layout, campos e acesso) no subconjunto compilável.**

- Por quê: com módulos resolvidos, o próximo limitador é não haver tipos
  compostos — qualquer organização de dados exige variáveis soltas. `struct` é
  o primeiro nó de tipo que aparece no ROADMAP e destrava `impl`/métodos depois.
  Também força a primeira decisão de layout entre os dois backends, que precisa
  ser documentada e testada por execução.
- Escopo mínimo proposto (incremental e testável):
  1. AST/parser: `struct Nome { campo: tipo, ... }` no nível superior, campo com
     tipo `i32`/`bool` e span próprio; erro para corpo vazio na primeira versão
     ou documentar permitido, e para tipo de campo desconhecido.
  2. Semântica: tabela de structs, layout com offsets alinhados (i32 4 bytes,
     bool 1 byte com padding documentado), resolução `let p: Ponto = ...`,
     acesso `p.x` como lvalue/rvalue, diagnóstico de campo inexistente,
     duplicado e de atribuição a campo de `let`.
  3. Restrições da primeira versão (diagnosticadas, não silenciosas): struct só
     como variável local e campo de struct; sem parâmetros/retornos por valor,
     sem struct dentro de struct e sem literal composto até a etapa seguinte.
  4. Backends: x86-64 com slots na pilha (offsets fixos, `mov` por tamanho);
     LLVM IR com `alloca` do tipo struct e `getelementptr` para campos.
  5. Testes: unitários de parser/sema (offsets e diagnósticos) e fixtures e2e
     novas com execução real (soma/mutação de campos, `if` sobre campo) + IR
     das mesmas fixtures aceito por `llvm-as` no CI.
  6. Docs: `docs/syntax.ebnf`, `docs/architecture.md` (layout), `docs/status.md`,
     `README.md`, `CHANGELOG.md` e este arquivo; versão `0.3.3-alpha.1`.
- Critérios de conclusão: `zig build test`, `zig build e2e` e
  `validate-ir-strict` verdes **no CI**; fixtures com `struct` executadas com
  código de saída conferido; nenhuma alegação sem log.

**Depois disso (ordem sugerida):** literais compostos e `struct` por
parâmetro/retorno → `enum`/`impl` (métodos com `self`) → strings + `print` via
syscall `write` (validação por saída de texto, não só exit code) → ampliar tipos
numéricos (`i64`, `u8`, `f32`...) → conectar `unsafe`/`repr(C)` → `target triple`
configurável → início do self-hosting em Kyn.

## 6. Histórico dos ciclos

| Ciclo | O que foi feito | Validado? |
|---|---|---|
| Anterior | Análise do repositório; declarado bloqueio de toolchain (Zig 0.17.0 "indisponível") | Não (nenhum build/teste) |
| Ciclo 1 (2026-11-07) | Toolchain obtida via PyPI; `build.zig`+`.zon`; lexer/AST/parser/semântica reescritos com spans e diagnósticos; backends LLVM IR e x86-64; CLI `kync`; driver; 96 testes unitários; suíte e2e com 64 casos; documentação reconciliada; testes antigos consolidados. Integrado via PR #7 (`5217796`). | Sim: `zig build`, `zig build test`, `zig build e2e`, `zig fmt --check`; retestado após o merge |
| Ciclo 2 (2026-11-07) | CI no GitHub Actions (venv Python + wheel PyPI da toolchain; LLVM instalado no runner); `tools/validate-ir.sh` validando o IR de 59 fixtures com `llvm-as`, em modo estrito; passos `zig build validate-ir` e `validate-ir-strict`; versão `0.3.1-alpha.1`; docs atualizadas com a evidência do run. Integrado via PR #8 (`837d4ed`). | Sim: runs `42413779278`, `42414049577` e `42414408475` (main) verdes: fmt + 96 testes + 64 e2e + IR estrito; suíte local reproduzida do zero antes e depois do merge |
| Ciclo 3 (2026-11-07) | Registro da integração do CI no estado do projeto (`DEVELOPMENT_STATE.md`, badge no README, entradas do CHANGELOG). Integrado via PR #9 (`449f78b`) e complementado pelo PR #11 (`ebc58b3`). | Sim: runs `42414846887` e `42416270074` (main) verdes |
| Ciclo 4 (2026-11-07, atual) | `import` e compilação multi-arquivo: lexer de strings + `import`; parser com `import` no topo; `driver.compilePath` com DFS pré-ordem, dedupe por caminho normalizado, `.import_cycle`/`.import_not_found`; `Diagnostic.file`/`addInFile` e mensagens citando o arquivo; CLI multi-arquivo; 21 testes novos (115 no total); 3 fixtures e2e multi-arquivo executadas + 3 negativas com mensagem esperada; `validate-ir` cobre 62 módulos; versão `0.3.2-alpha.1` (agora derivada de `build.zig.zon`). Integrado via PR #10 (`1c149dd`). | Sim: local (108 testes do compilador, 70/70 e2e, `fmt --check`) e CI runs `42415765698` (PR) e `42415945385` (main), ambos verdes com IR estrito; suíte local retestada em `main` após o merge |

---

**Regra de retomada:** reinstalar a toolchain (§1), rodar `zig build test` e
`zig build e2e` (e `zig build validate-ir` se houver LLVM), conferir
`git status` e o último CI em `main` (`gh run list --branch main`), e só então
seguir para §5. Não repetir etapas já validadas nem presumir resultados sem
executar os comandos.
