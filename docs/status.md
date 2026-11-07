# Estado de implementação

Este documento descreve o que foi **observado em execução** na revisão de
7 de novembro de 2026, com Zig 0.17.0 e `as`/`ld` disponíveis. Ele substitui
avaliações anteriores baseadas apenas na leitura de arquivos.

## Resumo

O Kyn continua sendo um **protótipo experimental**. A diferença em relação ao
ciclo anterior é que agora existe um pipeline do frontend integrado e
**validado por execução**: fontes `.kyn` do subconjunto suportado são
compiladas para assembly x86-64, montadas, ligadas e executadas com código de
saída conferido.

Ainda não existem: `import`, `struct`, `enum`, `impl`, generics, slices,
ponteiros, `unsafe`, strings, FFI integrada, biblioteca padrão estável nem
self-hosting funcional.

## Evidências por componente

| Componente | Arquivo | Estado observado | Validação |
| --- | --- | --- | --- |
| Build | `build.zig`, `build.zig.zon` | Fonte única de build, teste e e2e; Zig 0.17.0 exigido | `zig build`, `zig build test` executam |
| CLI | `src/main.zig` | `kync check`/`emit` com `--llvm`/`--asm`, `-o`, `--lib`; códigos 0/1/2/3 | Testes de fumaça manuais registrados em `docs/development.md` |
| Lexer | `src/lexer/lexer.zig` | Tokens tipados com span (linha/coluna), palavras-chave, operadores de 2 caracteres; descarta comentários/espaços | Testes unitários |
| Spans | `src/span.zig` | Offsets + linha/coluna; sem cópia de texto | Testes unitários |
| Diagnósticos | `src/diagnostics.zig` | Categoria estável + mensagem + linha/caret | Testes unitários |
| AST | `src/ast/ast.zig` | Funções, parâmetros, `let`/`var`, atribuição, `return`, `if`/`else`, `while`, blocos, expressões | Testes unitários |
| Parser | `src/parser/parser.zig` | Programa completo, precedência e associatividade, erros com span | Testes unitários e negativos |
| Semântica | `src/sema/sema.zig` | Escopos aninhados, resolução de nomes, tipos `i32`/`bool`/`void`, mutabilidade, chamadas, slots de pilha, validação de `main` | Testes unitários |
| Backend LLVM IR | `src/codegen/llvm.zig` | IR textual derivado da AST (aritmética, comparações, `&&`/`||` com `phi`, `if`, `while`, chamadas) | Testes estruturais localmente; aceito por `llvm-as` no CI (59/59 módulos) |
| Backend x86-64 | `src/codegen/x86_64.zig` | Assembly System V sem libc, `_start` + syscall `exit` | Executado: `as` + `ld` + código de saída |
| FFI | `src/ffi/ffi.zig` | Experimento isolado de `extern "c" printf` | Não integrado |
| `unsafe`/`repr(C)` | `src/sema/unsafe.zig` | Política isolada e testada; AST ainda não possui esses nós | Testes unitários do módulo |
| Self-hosting | `src/kyn/*.kyn`, `src/compiler/*.kyn` | Placeholders; não executados pelo `kync` | Não demonstrado |
| Biblioteca padrão | `std/core/core.zig`, `std/os/*.zig` | Stubs experimentais; algumas APIs não fazem E/S real | Compilam nos testes da std |
| Fixtures | `tests/` | 50 `integration/case_N.kyn` + 14 fixtures em `tests/e2e` + demais casos de linguagem ainda não suportados | `zig build e2e` (64 casos) |

## Subconjunto da linguagem aceito hoje

```kyn
fn soma(a: i32, b: i32) -> i32 {
    return a + b;
}

fn main() -> i32 {
    var total: i32 = 0;
    let passo: i32 = 2;
    while total < 10 {
        total = total + passo;
    }
    if total == 10 && soma(1, 2) == 3 {
        return total % 256;
    } else {
        return 1;
    }
}
```

Suportado: `fn`, `let`/`var` com inicializador obrigatório, anotação ou
inferência de tipo (`i32`, `bool`, `void`), atribuição (somente em `var`),
`return`, `if`/`else`/`else if`, `while`, blocos, expressões aritméticas,
comparações, `&&`/`||` com curto-circuito, unários `-`/`!`, literais inteiros e
booleanos, chamadas diretas de funções do próprio programa (até 6 argumentos).

Fora do subconjunto (diagnosticado ou rejeitado): `import`, `struct`, `enum`,
`impl`, `unsafe`, atributos `#[...]`, strings, `f32`/`f64` e demais tipos,
slices `[]T`, ponteiros, generics, `Result<T, E>`/`?`, closures, `for`.

## Validação executada neste ciclo

- `zig build` — sucesso.
- `zig build test` — 96 testes: 89 do compilador (spans, lexer, diagnóstico,
  ast, parser, sema, unsafe, backends, driver) e 7 da std experimental.
- `zig build e2e` — 64/64 casos: 9 fixtures comportamentais, 50 fixtures
  `case_N.kyn` com código de saída `N`, 5 fixtures negativas com código `1`.
- `zig fmt --check build.zig src std` — sem diferenças.
- `zig build validate-ir` (local, sem LLVM) — avisa e ignora, como documentado.
- CI (`.github/workflows/ci.yml`, run `42413779278` em 2026-11-07) — job
  "build, testes e validação de IR" concluído com sucesso em 1m50s:
  `zig fmt --check`, `zig build test`, `zig build e2e` e
  `zig build validate-ir-strict` (o `llvm-as` instalado no runner aceitou os 59
  módulos emitidos; o passo estrito falharia se o verificador faltasse ou
  rejeitasse qualquer módulo).

Não validado: execução em plataformas diferentes de Linux x86-64; desempenho;
fidelidade do IR a alvos LLVM diferentes de x86-64 (o `target triple` é fixo).

## Divergências históricas

- `CHANGELOG.md` contém entradas antigas (até `v2.3.0`) que descrevem marcos
  não comprovados pelo código. Elas foram mantidas por rastreabilidade, com
  aviso no próprio arquivo.
- A documentação de visão (`language_reference.md`, `spec.md`,
  `memory_model.md`) permanece não normativa; `syntax.ebnf` agora descreve
  apenas o que o parser aceita.

## Critérios mínimos para declarar uma versão estável

1. Build reproduzível e documentado em ambiente limpo. *(atendido)*
2. CLI com códigos de saída e diagnósticos especificados. *(atendido para o
   subconjunto atual)*
3. Pipeline lexer → parser → AST → semântica → backend integrado. *(atendido)*
4. Testes unitários, de integração e regressão em CI. *(testes existem; CI
   ainda não)*
5. Testes negativos para entradas inválidas e casos de fronteira. *(parcial)*
6. Contratos de memória e FFI documentados e testados. *(não)*
7. Self-hosting comprovado por bootstrap reproduzível. *(não)*
8. Release com artefatos, checksums e política de compatibilidade. *(não)*

Até que todos os critérios sejam atendidos, use os termos **experimental**,
**parcial** e **em desenvolvimento**.
