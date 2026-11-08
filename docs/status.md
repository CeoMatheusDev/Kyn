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

Agora também existem **tipos compostos nomeados** (`struct` com campos
escalares, literais, acesso/atribuição a campo, cópia por valor) e **saída de
texto e números**: `str` como fatia estática (ponteiro + tamanho) que também
**atravessa chamadas por valor** em parâmetros e retornos, `print(...)`
para texto e `print_i32(...)` para **valores calculados em decimal** (com sinal
e limites de `i32` corretos). Isso permite validar **conteúdo**, não apenas o
código de saída do processo, e a suíte e2e confere stdout
(`// expect-stdout:`).

Agora structs também atravessam chamadas **por valor** (parâmetros, argumentos
e retornos), com um registrador por campo e o mesmo limite de seis registradores
do `str`. Ainda não existem: `enum`, `impl`/métodos, generics, slices,
ponteiros, `unsafe`, struct com campo struct (aninhado), `str` em campo de
struct, comparação, concatenação ou formatação de `str`, FFI integrada,
biblioteca padrão estável nem self-hosting funcional.

## Evidências por componente

| Componente | Arquivo | Estado observado | Validação |
| --- | --- | --- | --- |
| Build | `build.zig`, `build.zig.zon` | Fonte única de build, teste e e2e; Zig 0.17.0 exigido | `zig build`, `zig build test` executam |
| CLI | `src/main.zig` | `kync check`/`emit` com `--llvm`/`--asm`, `-o`, `--lib`; códigos 0/1/2/3 | Testes de fumaça manuais registrados em `docs/development.md` |
| Lexer | `src/lexer/lexer.zig` | Tokens tipados com span (linha/coluna), palavras-chave (inclui `import` e `struct`), operadores de 2 caracteres, pontuação com `.`, literal de string sem escapes; descarta comentários/espaços | Testes unitários |
| Spans | `src/span.zig` | Offsets + linha/coluna; sem cópia de texto | Testes unitários |
| Diagnósticos | `src/diagnostics.zig` | Categoria estável + mensagem + linha/caret + arquivo de origem (`file`) | Testes unitários |
| AST | `src/ast/ast.zig` | Funções, `struct`/campos, parâmetros, `let`/`var`, atribuição (variável e campo), `return`, `if`/`else`, `while`, blocos, expressões (acesso a campo, literal de struct, literal de string), `Call.builtin` para `print` | Testes unitários |
| Parser | `src/parser/parser.zig` | Programa completo, `import` antes das declarações, `struct`, literais de struct e acesso a campo, precedência e associatividade, erros com span | Testes unitários e negativos |
| Módulos | `src/driver.zig` | `compilePath` carrega o grafo de imports em pré-ordem, normaliza caminhos, deduplica e achata em um `Program` | Testes com diretório temporário + 3 fixtures e2e executadas + 3 negativas |
| Semântica | `src/sema/sema.zig` | Escopos aninhados, resolução de nomes, tipos `i32`/`bool`/`str`/`void`/struct, campos e literais de struct, `str` e struct por valor em parâmetros/retornos (identidade nominal preservada), limite de seis registradores via `registerWordsOf` (`str` = 2, campo de struct = 1), funções embutidas `print`/`print_i32` (aridade e tipo checados, nomes reservados), mutabilidade, chamadas, slots de pilha, validação de `main` | Testes unitários |
| Backend LLVM IR | `src/codegen/llvm.zig` | IR textual derivado da AST (aritmética, comparações, `&&`/`||` com `phi`, `if`, `while`, chamadas); structs por substituição escalar (um `alloca` por campo); `str` em `@.strN` com `declare i64 @write(i32, ptr, i64)`, `str` por valor como `ptr`+`i64` em parâmetros e retorno `{ ptr, i64 }`, struct por valor com parâmetros achatados em escalares e retorno agregado `{ i32, i1, … }` (`insertvalue`/`extractvalue`); `print` chamando `write` e `print_i32` via `@kyn_print_i32` (`urem`/`udiv`) | Testes estruturais localmente; aceito por `llvm-as` no CI (83/83 módulos) |
| Backend x86-64 | `src/codegen/x86_64.zig` | Assembly System V sem libc, `_start` + syscall `exit`; struct em slots consecutivos (base + um por campo); `str` em dois slots, parâmetros/retornos `str` em pares de registradores (`(%rdi,%rsi)`, `(%rdx,%rcx)`, `(%r8,%r9)`; retorno em `%rax`/`%rdx`), struct por valor com um registrador por campo (retorno em `%eax`/`%edx`/`%ecx`/`%r8d`/`%r9d`/`%r10d`), texto em `.rodata` e `print` via syscall `write`; `print_i32` com rotina decimal única (`divl` unsigned) | Executado: `as` + `ld` + código de saída e stdout conferido |
| FFI | `src/ffi/ffi.zig` | Experimento isolado de `extern "c" printf` | Não integrado |
| `unsafe`/`repr(C)` | `src/sema/unsafe.zig` | Política isolada e testada; AST ainda não possui esses nós | Testes unitários do módulo |
| Self-hosting | `src/kyn/*.kyn`, `src/compiler/*.kyn` | Placeholders; não executados pelo `kync` | Não demonstrado |
| Biblioteca padrão | `std/core/core.zig`, `std/os/*.zig` | Stubs experimentais; algumas APIs não fazem E/S real | Compilam nos testes da std |
| Fixtures | `tests/` | 50 `integration/case_N.kyn` + 52 entradas em `tests/e2e` (26 positivas com `struct_*`/`print_*`/`print_int_*`/`str_*`, 7 módulos, 16 negativas, 3 módulos negativos) + demais casos de linguagem ainda não suportados | `zig build e2e` (102 casos) |

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

Suportado: `import "caminho";` antes das declarações (arquivos `.kyn` resolvidos
relativos ao arquivo importador, cada um carregado uma vez), `struct Nome { ... }`
com campos escalares, literais `Nome { campo: valor }` (todos os campos, uma vez
cada), acesso `p.campo` e atribuição `p.campo = v` em variáveis `var`, cópia de
struct por valor, literais de string e variáveis `str` (inferidas ou anotadas)
com cópia e atribuição, `print(s: str)` e `print_i32(n: i32)` embutidos (texto e
decimais com quebra de linha), `fn`, `let`/`var` com inicializador obrigatório, anotação ou
inferência de tipo (`i32`, `bool`, `str`, `void`), atribuição (somente em `var`),
`return`, `if`/`else`/`else if`, `while`, blocos, expressões aritméticas,
comparações, `&&`/`||` com curto-circuito, unários `-`/`!`, literais inteiros e
booleanos, chamadas diretas de funções do próprio programa (até 6 registradores
de argumentos, contando `str` como dois e cada campo de struct como um), `str`
por valor em parâmetros/retornos e struct por valor em parâmetros, argumentos e
retornos (até 6 campos).

Fora do subconjunto (diagnosticado ou rejeitado): `enum`, `impl`/métodos,
`unsafe`, atributos `#[...]`, struct com campo de tipo struct, struct vazio,
campo de struct de tipo `str`,
comparação (`==`/`!=`), concatenação e formatação de `str`, `f32`/`f64` e demais tipos,
slices `[]T`, ponteiros, generics, `Result<T, E>`/`?`, closures, `for`,
visibilidade (`pub`), imports qualificados/seletivos e pacotes.

## Validação executada neste ciclo

- `zig build` — sucesso.
- `zig build test` — 204 testes: 197 do compilador (spans, lexer, diagnóstico,
  ast, parser, sema, unsafe, backends, driver, carregamento multi-arquivo,
  structs, `str`/`print`, `str` por valor em chamadas, struct por valor em
  chamadas, `print_i32`, pool de strings e rejeição de variável `void`) e 7 da
  std experimental.
- `zig build e2e` — 102/102 casos: 26 fixtures comportamentais (6 com `struct`,
  incluindo 3 de struct por valor, 4 com `print`, 4 com `print_i32`/misto, 3 com
  `str` por valor, todas conferindo stdout), 7 programas multi-arquivo
  executados (com struct, struct por valor, `print` no módulo e `str`
  importado), 50 fixtures `case_N.kyn` com código de saída `N`, 16 fixtures
  negativas (4 de struct, incluindo structs nominais trocados e limite de
  registradores; 4 de `str`/`print`, 2 de `print_i32`, 1 de campo `str`, 1 de
  `main` retornando `str`) e 3 módulos negativos (ciclo, arquivo ausente,
  símbolo duplicado) com mensagem esperada.
- `zig fmt --check build.zig src std` — sem diferenças.
- `zig build validate-ir` (local, sem LLVM) — avisa e ignora, como documentado
  no ambiente de desenvolvimento; o mesmo script cobre 83 módulos quando há
  `llvm-as`/`clang`.
- CI (`.github/workflows/ci.yml`) — runs `42425605484` (PR #19) e
  `42425757025` (`main` pós-merge) verdes com `zig fmt --check`, `zig build
  test` (193 testes), `zig build e2e` (97 casos, com stdout conferido) e
  `zig build validate-ir-strict` (79 módulos aceitos pelo `llvm-as`, incluindo
  o retorno agregado `{ ptr, i64 }` do `str`). O passo estrito falha se o
  verificador faltar ou rejeitar qualquer módulo.

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
