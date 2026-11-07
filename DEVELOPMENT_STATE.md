# DEVELOPMENT_STATE — Kyn

**Mantido por:** agente de continuidade (Arena)
**Branch ativa:** `arena/599599bc-kyn` (a partir de `5217796375ee4a6dbcd83036a3b3c7d4afee3eff` de `main`)
**Integração:** PR #8 mesclado em `main` como `837d4edb1fa64cf48ba7efe2d30735b087d92945`
(2026-11-07); CI em `main` verde (run `42414408475`) e suíte local retestada
após o merge.
**Versão do projeto:** `0.3.1-alpha.1`
**Última validação:** 2026-11-07 — local (Zig 0.17.0 + GNU as/ld, Debian 12 /
x86-64) e CI (run `42414049577`, ubuntu-24.04, 2m05s, verde, com
`validate-ir-strict`)
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
| Lexer | `src/lexer/lexer.zig` | Tokens tipados, keywords, operadores 1–2 chars, spans; descarta trivia |
| Spans | `src/span.zig` | offset + linha/coluna 1-based; sem cópia de texto |
| Diagnósticos | `src/diagnostics.zig` | categoria estável + mensagem + linha/caret |
| AST | `src/ast/ast.zig` | funções, params, let/var, assign, return, if/else, while, blocos, expressões |
| Parser | `src/parser/parser.zig` | programa completo, precedência/associatividade, erro no primeiro token inválido |
| Semântica | `src/sema/sema.zig` | escopos, resolução, `i32`/`bool`/`void`, mutabilidade, chamadas, slots, `main`, `alwaysReturns` |
| Backend LLVM | `src/codegen/llvm.zig` | IR derivado da AST; validado só estruturalmente |
| Backend nativo | `src/codegen/x86_64.zig` | System V sem libc; validado executando binários |
| Driver | `src/driver.zig` | arena por compilação; `Result.deinit()` |
| `unsafe`/`repr(C)` | `src/sema/unsafe.zig` | política isolada e testada; sem nós na AST ainda |
| Self-hosting | `src/kyn/*.kyn`, `src/compiler/*.kyn` | placeholders; não executados |
| Std | `std/core/*`, `std/os/*` | stubs experimentais; compilam nos testes |
| Fixtures | `tests/` | 50 `integration/case_N.kyn` (suportadas) + 14 em `tests/e2e`; demais ainda não suportadas |
| CI | `.github/workflows/ci.yml` | ubuntu-24.04: fmt + test + e2e + validação de IR estrita |
| Validação de IR | `tools/validate-ir.sh` | `llvm-as`/`clang` sobre 59 módulos; estrito no CI |

### Subconjunto aceito hoje

`fn`, `let`/`var` (inicializador obrigatório), inferência ou anotação
(`i32`/`bool`/`void`), atribuição só em `var`, `return`, `if`/`else`/`else if`,
`while`, blocos, aritmética, comparações, `&&`/`||` com curto-circuito, `-`/`!`,
literais inteiros/booleanos e chamadas a funções do próprio programa (≤ 6 args).

Fora do subconjunto: `import`, `struct`, `enum`, `impl`, `unsafe`, atributos,
strings, `f32`/`f64`, slices, ponteiros, generics, `Result`/`?`, closures, `for`.

### Validação executada nesta sessão

- `zig build` — sucesso (gera `zig-out/bin/kync`).
- `zig build test` — **96 testes** (89 do compilador + 7 da std), todos passando.
- `zig build e2e` — **64/64** casos: 9 fixtures comportamentais executadas,
  50 fixtures `case_N.kyn` com código de saída `N`, 5 fixtures negativas
  (código 1 + mensagem `erro:`).
- `zig fmt --check build.zig src std` — sem diferenças.
- `zig build validate-ir` sem LLVM — avisa e sai 0 (skip documentado);
  `--require-tool` (passo estrito) — sai 1, como esperado.
- Script de validação testado com stubs de `llvm-as`: aceitação (59/59),
  rejeição (59 falhas, exit 1) e descoberta de `llvm-as-18`.
- **CI real (GitHub Actions, run `42414049577`)**: verde em 2m05s, incluindo
  `zig build test`, `zig build e2e` e `zig build validate-ir-strict` (o
  `llvm-as` do runner aceitou o IR das 59 fixtures; o passo estrito falharia se
  o verificador faltasse ou rejeitasse algum módulo).
- CLI exercitada manualmente: sem args (2), arquivo inexistente (3), opção
  inválida (2), diagnóstico (1), `-o` com `check` (2), `emit` llvm/asm (0).

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
10. **Versionamento:** `0.3.1-alpha.1`; entradas antigas do CHANGELOG (até
    `v2.3.0`) marcadas como não comprovadas.
11. **CI:** GitHub Actions em `ubuntu-24.04`; a toolchain Zig vem do wheel
    oficial do PyPI (`ziglang==0.17.0.post0`) em um venv, o mesmo caminho
    documentado para o desenvolvimento local — o CI valida a própria receita.
    Ações fixadas em major (`actions/checkout@v7`).
12. **Validação nunca silenciosa:** qualquer passo de validação opcional tem
    variante estrita usada no CI.

## 4. Pendências (priorizadas)

1. **Linguagem:** sem `import`/módulos, `struct`, `enum`, `impl`, `unsafe`,
   atributos, strings, tipos numéricos além de `i32`, slices e ponteiros.
2. **Tipos:** sem `i64`/`u32`/`f32`/`f64`, sem checagem de fluxo completa
   (só `alwaysReturns` estrutural), sem casts/conversões.
3. **Std experimental** com APIs que não fazem E/S real; `kyn:core` × `kyn:std`
   ainda não separados em módulos de build distintos.
4. **Self-hosting:** `src/kyn/` e `src/compiler/` continuam placeholders.
5. **Runner de fixtures** cobre apenas sucesso/negativo genérico; não confere
   mensagem/posição esperada por arquivo.
6. **Fuzz/edge cases** de `tests/fuzz/` não são executados por nenhum runner.
7. **`tests/diagnostics/*.kyn`** não são verificados pelo e2e (só
   `tests/e2e/negative`).
8. **Backend nativo** restrito a Linux x86-64, ≤ 6 argumentos, sem libc e sem
   otimização; sem testes de regressão com IR/asm completos (golden files).
9. **CI** roda apenas em `ubuntu-24.04` (sem matriz de SO, sem cache de build,
   sem artefatos publicados); `target triple` do IR é fixo.
10. **Cobertura de testes do compiler** concentrada em exemplos; sem medição de
    cobertura nem testes de estresse de entradas grandes.

## 5. Próxima etapa prioritária

**Implementar `import` e compilação multi-arquivo.**

- Por quê: é o primeiro item aberto do ROADMAP e desbloqueia organização de
  projetos; hoje o parser rejeita `import` no nível superior, então nenhuma
  fixture com módulos compila. Também é pré-requisito para separar `kyn:core`
  de `kyn:std` no build.
- Escopo mínimo proposto (incremental e testável):
  1. Lexer/parser: literal de string e `import "caminho";` no nível superior.
  2. Driver: resolver caminhos relativos ao arquivo de entrada, carregar cada
     arquivo uma vez, detectar ciclos e importações duplicadas com diagnóstico
     por span.
  3. Semântica: tabela de funções por módulo com resolução documentada
     (qualificação ou *flattening*), proibindo colisões de nome.
  4. CLI: `kync check/emit` com arquivo raiz cujos imports são carregados.
  5. Testes: unitários do resolver + fixtures e2e com 2–3 arquivos; casos
     negativos para ciclo, arquivo ausente e símbolo duplicado.
  6. Docs: `docs/syntax.ebnf`, `docs/status.md`, `docs/development.md`,
     `CHANGELOG.md` e este arquivo.
- Critérios de conclusão: `zig build test`, `zig build e2e` e
  `validate-ir-strict` verdes **no CI**; fixtures multi-arquivo executadas com
  código de saída conferido; nenhuma alegação sem log.

**Depois disso (ordem sugerida):** `struct`/`enum`/`impl` na AST e semântica →
conectar `unsafe`/`repr(C)` → ampliar tipos numéricos (`i64`, `u8`, `f32`...) →
runner de fixtures com diagnóstico esperado → `target triple` configurável →
início do self-hosting em Kyn.

## 6. Histórico dos ciclos

| Ciclo | O que foi feito | Validado? |
|---|---|---|
| Anterior | Análise do repositório; declarado bloqueio de toolchain (Zig 0.17.0 "indisponível") | Não (nenhum build/teste) |
| Ciclo 1 (2026-11-07) | Toolchain obtida via PyPI; `build.zig`+`.zon`; lexer/AST/parser/semântica reescritos com spans e diagnósticos; backends LLVM IR e x86-64; CLI `kync`; driver; 96 testes unitários; suíte e2e com 64 casos; documentação reconciliada; testes antigos consolidados. Integrado via PR #7 (`5217796`). | Sim: `zig build`, `zig build test`, `zig build e2e`, `zig fmt --check`; retestado após o merge |
| Ciclo 2 (2026-11-07) | CI no GitHub Actions (venv Python + wheel PyPI da toolchain; LLVM instalado no runner); `tools/validate-ir.sh` validando o IR de 59 fixtures com `llvm-as`, em modo estrito; passos `zig build validate-ir` e `validate-ir-strict`; versão `0.3.1-alpha.1`; docs atualizadas com a evidência do run. Integrado via PR #8 (`837d4ed`). | Sim: runs `42413779278`, `42414049577` e `42414408475` (main) verdes: fmt + 96 testes + 64 e2e + IR estrito; suíte local reproduzida do zero antes e depois do merge |

---

**Regra de retomada:** reinstalar a toolchain (§1), rodar `zig build test` e
`zig build e2e` (e `zig build validate-ir` se houver LLVM), conferir
`git status` e o último CI em `main` (`gh run list --branch main`), e só então
seguir para §5. Não repetir etapas já validadas nem presumir resultados sem
executar os comandos.
