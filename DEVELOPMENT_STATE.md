# DEVELOPMENT_STATE — Kyn

**Mantido por:** agente de continuidade (Arena)
**Branch ativa:** `arena/06084568-kyn` (a partir de `46b0a949f99efc9318f9f378afbb50684d358f73` de `main`)
**Versão do projeto:** `0.3.0-alpha.1`
**Última validação:** 2026-11-07, Zig 0.17.0 + GNU as/ld, Debian 12 / x86-64
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
8. **LLVM IR continua sendo o alvo declarado,** mas não é verificado por
   ferramenta LLVM neste ambiente; a validação é estrutural (todo bloco termina
   com `ret`/`br`/`unreachable`).
9. **Limites documentados do backend nativo:** ≤ 6 parâmetros/argumentos
   (diagnosticados pela semântica), sem chamadas externas, sem otimização.
10. **Versionamento:** `0.3.0-alpha.1`; entradas antigas do CHANGELOG (até
    `v2.3.0`) marcadas como não comprovadas.

## 4. Pendências (priorizadas)

1. **CI inexistente** (Fase 3): nenhum workflow roda `zig build test`/`e2e`/
   `fmt --check`; o LLVM IR nunca é validado por ferramenta LLVM.
2. **Linguagem:** sem `import`/módulos, `struct`, `enum`, `impl`, `unsafe`,
   atributos, strings, tipos numéricos além de `i32`, slices e ponteiros.
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
9. **Backend nativo** não suporta alinhamento ABI estrito para libc, nem
   plataformas diferentes de Linux x86-64; `codegen` não tem testes de regressão
   com IR/asm completos (golden files).

## 5. Próxima etapa prioritária

**Criar CI (GitHub Actions) com `zig build test`, `zig build e2e` e
`zig fmt --check`, e validação do LLVM IR por ferramenta (`llvm-as`/`clang`)
quando disponível no runner.**

- Por quê: o projeto declara LLVM IR como alvo, mas hoje só há validação
  estrutural; CI com LLVM disponível fecha a lacuna entre "emitimos IR" e "o IR
  é aceito por uma ferramenta LLVM". Ao mesmo tempo, garante que build/testes
  não regridam.
- Arquivos envolvidos: `.github/workflows/ci.yml` (novo), `build.zig`
  (possível passo `validate-ir`), `tools/validate-ir.sh` (novo, com skip quando
  não houver LLVM), `docs/development.md`, `README.md`.
- Critérios de conclusão: workflow versionado; `zig build test` e
  `zig build e2e` verdes no runner; `llvm-as` aceita o IR das fixtures
  positivas; documentação descrevendo como reproduzir localmente; nenhuma
  alegação sem log/artefato correspondente.

**Depois disso (ordem sugerida):** `import` + compilação multi-arquivo →
`struct`/`enum`/`impl` na AST e semântica → conectar `unsafe`/`repr(C)` →
ampliar tipos numéricos → runner de fixtures com diagnóstico esperado →
início do self-hosting em Kyn.

## 6. Histórico dos ciclos

| Ciclo | O que foi feito | Validado? |
|---|---|---|
| Anterior | Análise do repositório; declarado bloqueio de toolchain (Zig 0.17.0 "indisponível") | Não (nenhum build/teste) |
| Atual (2026-11-07) | Toolchain obtida via PyPI; `build.zig`+`.zon`; lexer/AST/parser/semântica reescritos com spans e diagnósticos; backends LLVM IR e x86-64; CLI `kync`; driver; 96 testes unitários; suíte e2e com 64 casos; documentação reconciliada; testes antigos consolidados | Sim: `zig build`, `zig build test`, `zig build e2e`, `zig fmt --check` |

---

**Regra de retomada:** reinstalar a toolchain (§1), rodar `zig build test` e
`zig build e2e`, conferir `git status`, e só então seguir para §5. Não repetir
etapas já validadas nem presumir resultados sem executar os comandos.
