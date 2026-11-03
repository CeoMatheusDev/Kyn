# Estado de implementação

Revisão de 3 de novembro de 2026 (compilador 0.5.0-alpha.1), com base no que foi
executado neste repositório (Zig 0.17.0, `cc` = gcc em Linux x86_64). Nada aqui é
certificação de qualidade; é o registro do que os comandos do projeto produziram.

## Resumo

O Kyn deixou de ser um conjunto de esqueletos: existe um **pipeline de compilação
integrado e verificável** (fonte `.kyn` → C99 → binário) com CLI, build reproduzível,
testes unitários e suíte de integração. Nas duas últimas revisões entraram **arrays
`[N]T`, slices `[]T`, indexação, fatias, `for` sobre coleções** e **`match` sobre enums
com verificação de exaustividade**. A **linguagem** continua sendo um subconjunto
experimental: não há generics, traits, verificação de limites em tempo de execução,
borrow checker nem biblioteca padrão funcional.

## Evidências por componente

| Componente | Arquivo | Estado | Evidência |
| --- | --- | --- | --- |
| Build | `build.zig`, `build.zig.zon` | Implementado | `zig build`, `zig build test`, `zig build integration`, `zig build check` |
| CLI | `src/main.zig` | Implementado | subcomandos `check`, `emit`, `build`, `run`, `tokens`, `ast`, `version`, `help` |
| Lexer | `src/lexer/lexer.zig` | Implementado | 7 testes unitários; tokens com span; recuperação após erro |
| Parser | `src/parser/parser.zig` | Implementado | 1 teste unitário de literais + todos os casos de `tests/cases` |
| AST | `src/ast/ast.zig` | Implementado | 1 teste unitário; nós anotados com `type_id` pela semântica |
| Análise semântica | `src/sema/sema.zig`, `types.zig`, `unsafe.zig` | Implementado (subconjunto) | 9 testes unitários + 32 fixtures de diagnóstico |
| Backend | `src/codegen/c.zig` | Implementado (C99) | 1 teste unitário + 83 fixtures compiladas com `cc` e executadas |
| Diagnósticos | `src/diag.zig` | Implementado | 2 testes unitários; formato `error[E00xx]` com linha, coluna e `^^^` |
| Pipeline | `src/driver.zig` | Implementado | 3 testes unitários de ponta a ponta |
| Suíte de integração | `src/runner.zig` | Implementado | `zig build integration` → 122 casos, 0 falhas |
| Biblioteca padrão | `std/` | Não implementado | imports são validados, mas nenhum símbolo é fornecido |
| Self-hosting | `experiments/self-host-sketch/` | Rascunho | arquivos `.kyn` que o compilador atual não aceita |

Distribuição dos 27 testes unitários: `sema` 9 (tipos 4, semântica 2, unsafe 3) ·
`lexer` 7 · `driver` 3 · `diag` 2 · `runner` 2 · `ast` 1 · `parser` 1 · `codegen` 1.

Resultados medidos nesta revisão:

```console
$ zig build test        # All 27 tests passed.
$ zig build integration # integração OK: 122 caso(s), 0 falha(s)
```

## Subconjunto implementado

**Itens de nível superior:** `fn`, `extern fn` (com varargs), `struct`, `enum`, `impl`
(métodos com `self: &T` / `&mut T` e funções associadas), `import` (validado contra a
lista de módulos conhecidos), atributos `#[repr(C)]` e `#[align(N)]`, `pub` (aceito e
ignorado).

**Tipos:** `i8`…`i64`, `isize`, `u8`…`u64`, `usize`, `f32`, `f64`, `bool`, `char`,
`str`, `void`, `&T`, `&mut T`, `*T`, `*const T`, `[N]T` (array de tamanho fixo),
`[]T`/`[]const T` (slice), structs e enums nomeados. `[*]T` continua sendo aceito como
alias de ponteiro cru.

**Statements:** `let`, `var`, `let mut`, atribuição (`=`, `+=`, `-=`, `*=`, `/=`, `%=`),
`if`/`else if`/`else`, `while`, `for i in a..b`, `for x in colecao`,
`match enum { … }`, `return`, `break`, `continue`, blocos aninhados, `unsafe { … }`.

**Expressões:** precedência completa (`||`, `&&`, `|`, `^`, `&`, `==`/`!=`,
comparações, `<<`/`>>`, `+`/`-`, `*`/`/`/`%`), unários (`-`, `!`, `~`, `*`, `&`,
`&mut`), chamadas, métodos, `Tipo::item`, acesso a campo, `.len` de array/slice,
indexação `a[i]`, fatias `a[lo..hi]`/`a[lo..]`/`a[..hi]`/`a[..]`, literais de struct,
enum e array (`[1, 2, 3]`), casts `as`, parênteses.

**Regras de arrays e slices:** parâmetro `[N]T` decai para `[]T`; `[N]T` é convertido
automaticamente onde se espera `[]T`; `[]T` é aceitável onde se espera `[]const T`;
funções não podem retornar `[N]T` (E0099); arrays não são atribuíveis como um todo
(E0099); `for x in colecao` percorre uma cópia imutável do elemento.

**Verificações semânticas (código → significado):**

| Código | Verificação |
| --- | --- |
| E0001 | erro de sintaxe |
| E0002 | erro léxico (string não terminada, caractere inválido, escape inválido) |
| E0010 | tipo desconhecido |
| E0011 | nome indefinido (variável, função, `self` fora de método) |
| E0012 | declaração duplicada (função, tipo, campo, variante, binding no mesmo escopo) |
| E0013 | mismatch de tipos (inclui literal fora do intervalo) |
| E0014 | atribuição a lugar imutável (inclui `&mut` de binding imutável) |
| E0015 | operação que exige `unsafe` fora de bloco `unsafe` |
| E0016 | retorno ausente ou incompatível (inclui assinatura inválida de `main`) |
| E0017 | aridade de chamada |
| E0018 | módulo de `import` desconhecido |
| E0019 | campo/variante inexistente ou não inicializado |
| E0020 | atributo desconhecido |
| E0021 | `break`/`continue` fora de laço |
| E0022 | operando inválido para o operador |
| E0023 | módulo sem `fn main` (quando se compila um executável) |
| E0024 | `match` não cobre todas as variantes do enum |
| E0025 | padrão de `match` inválido (variante inexistente, de outro enum, braço duplicado ou sujeito que não é enum) |
| E0099 | recurso explicitamente não suportado |
| W0001 | variável nunca lida (só com `--warn-unused`) |

## Limitações conhecidas e honestidade

- **`match` só aceita enum como sujeito** e é apenas statement (não expressão): não
  há padrões com ligação de variável, guardas `if`, faixas (`1..=5`) nem `match`
  aninhado como valor.
- **Sem backend nativo.** A geração de código produz C99; não há emissor de LLVM IR,
  assembly nem código de máquina. O emissor mínimo de LLVM IR que existia em
  `src/codegen` foi substituído pelo backend C.
- **Sem borrow checker.** Referências são tipadas, mas não há verificação de
  lifetimes, aliasing exclusivo ou moves. `unsafe` é exigido para dereferência de
  ponteiro cru, escrita por ponteiro e chamada de `extern fn` — nada além disso.
- **Biblioteca padrão inexistente.** `import` valida o nome do módulo e nada mais;
  `print`/`println` são builtins do compilador, não uma API de `kyn:std`.
- **`print`/`println` aceitam no máximo um argumento** e não têm formatação;
  `printf` da libc está disponível via FFI para casos reais.
- **Números de ponto flutuante imprimem com `%f`** (6 casas decimais).
- **Inteiros usam aritmética do C**: overflow de inteiros assinados não é verificado
  em tempo de execução.
- **Índices e fatias não são verificados em tempo de execução.** `xs[i]` e
  `xs[lo..hi]` compilam para acesso direto em C: fora dos limites é comportamento
  indefinido, exatamente como em C. Não há runtime onde inserir a verificação.
- **Slices não têm ownership.** `let s: []i32 = [1, 2, 3];` cria um array composto
  com tempo de vida do bloco atual; devolver essa fatia de uma função apontaria para
  memória liberada. Sem borrow checker, isso é responsabilidade de quem escreve.
- **Arrays não são multidimensionais** (`[3][2]i32` é E0099) e não podem ser
  retornados por funções nem atribuídos como um todo.
- **`str` não é indexável** e não tem comprimento: continua sendo `const char *`
  terminado em NUL.
- **Conversões implícitas** existem apenas para literais (inteiro/float no contexto e
  literal de string em parâmetro `*const u8`). Todo o resto exige `as`.
- **`pub` é aceito e ignorado**; não há controle de visibilidade entre módulos.
- **O mapeamento `*u8`/`*const u8` → `char *`/`const char *`** é deliberado, para
  manter compatibilidade com cabeçalhos do sistema na FFI.

## Critérios mínimos para declarar uma versão estável

1. Gramática normativa e testes negativos para toda a sintaxe aceita. ✅ parcial
   (gramática documentada em `docs/syntax.ebnf` para o subconjunto implementado).
2. Build reproduzível e documentado em ambiente limpo. ✅
3. CLI com códigos de saída e diagnósticos especificados. ✅
4. Pipeline lexer → parser → AST → semântica → backend integrado. ✅
5. Testes unitários, de integração e regressão executados automaticamente. ✅ local
   (`zig build check`); ❌ ainda não há CI configurado.
6. Testes negativos para entradas inválidas e casos de fronteira. ✅
   (`tests/diagnostics`, incluindo entrada malformada).
7. Contratos de memória e FFI documentados **e testados**. ❌ parcial: FFI é testada,
   contratos de memória continuam propositivos.
8. Backend próprio (não depender de um compilador C) e matriz de plataformas. ❌
9. Implementação self-hosted comprovada por bootstrap reproduzível. ❌
10. Release com artefatos, checksums e política de compatibilidade. ❌
