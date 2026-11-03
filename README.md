# Kyn

**Kyn** é uma linguagem de programação de sistemas em desenvolvimento, com controle
explícito de recursos, ausência de garbage collector como objetivo de projeto e
interoperabilidade com C.

Este repositório contém um **compilador funcional em estágio inicial**: o pipeline
lexer → parser → AST → análise semântica → geração de C está implementado, integrado
e coberto por testes automatizados. A linguagem em si continua experimental — sintaxe
e semântica podem mudar.

> **Estado atual:** protótipo com pipeline de ponta a ponta verificável.
> Não é uma linguagem estável nem pronta para produção.

## O que funciona hoje

Um programa Kyn como este compila e executa:

```kyn
struct Vector2 {
    x: f64,
    y: f64,
}

impl Vector2 {
    fn new(x: f64, y: f64) -> Vector2 {
        return Vector2 { x: x, y: y };
    }

    fn sum(self: &Vector2) -> f64 {
        return self.x + self.y;
    }
}

fn main() -> i32 {
    let v: Vector2 = Vector2::new(1.5, 2.5);
    println(v.sum());
    return 0;
}
```

```console
$ kyn run exemplo.kyn
4.000000
```

O compilador traduz o programa para C99 e delega a compilação final a um compilador C
(`cc`). Erros de sintaxe, tipo, mutabilidade e uso indevido de `unsafe` são reportados
com código, posição e trecho da origem:

```console
$ kyn check exemplo.kyn
error[E0014]: não é possível atribuir ao campo `x` de um valor imutável
  --> exemplo.kyn:18:5
   |
18 |     v.x = 1.0;
   |     ^^^
   = help: declare o binding com `var` (ou `let mut`), ou receba o valor por `&mut`
```

## Requisitos

- **Zig 0.17.0** (bootstrap do compilador).
- Um compilador **C99** no `PATH` (`cc`, `gcc` ou `clang`) para `kyn run` e para a
  suíte de integração.

```sh
zig version   # deve imprimir 0.17.0
cc --version
```

## Build, testes e uso

```sh
zig build                 # gera zig-out/bin/kyn
zig build test            # 26 testes unitários (lexer, parser, semântica, backend)
zig build integration     # 105 fixtures .kyn compiladas e executadas de ponta a ponta
zig build check           # unitários + integração
zig build run -- help     # CLI
```

Comandos da CLI:

| Comando | O que faz |
| --- | --- |
| `kyn check <arq.kyn>` | lexer + parser + semântica, sem gerar código |
| `kyn emit <arq.kyn>` | escreve o C gerado em stdout (ou `-o`) |
| `kyn build <arq.kyn> -o saida.c` | escreve o C gerado em um arquivo |
| `kyn run <arq.kyn>` | compila o C com `cc` e executa o binário |
| `kyn tokens <arq.kyn>` | despeja a tokenização (depuração) |
| `kyn ast <arq.kyn>` | despeja a AST (depuração) |
| `kyn version` / `kyn help` | versões e ajuda |

Códigos de saída: `0` sucesso · `1` diagnósticos · `2` uso inválido · `3` falha
interna/de E/S · `4` falha no compilador C. Em `kyn run`, o código de saída do
programa é propagado.

## Subconjunto de linguagem implementado

| Área | Suportado | Ainda não |
| --- | --- | --- |
| Itens | `fn`, `extern fn`, `struct`, `enum`, `impl`, `import`, atributos `#[repr(C)]`/`#[align(N)]` | generics, traits, `match`, closures, visibilidade real de `pub` |
| Tipos | `i8`…`i64`, `isize`, `u8`…`u64`, `usize`, `f32`, `f64`, `bool`, `char`, `str`, `void`, `&T`, `&mut T`, `*T`, `*const T`, structs e enums nomeados | slices `[]T`, arrays `[N]T`, `Result<T, E>`, tuplas |
| Statements | `let`, `var`, `let mut`, atribuição simples e composta, `if`/`else if`/`else`, `while`, `for i in a..b`, `return`, `break`, `continue`, blocos, `unsafe { … }` | `for` sobre coleções, `match`, `defer` |
| Expressões | aritmética, comparação, lógica, bit a bit, shifts, unários, chamadas, métodos, `Tipo::item`, campos, literais de struct e enum, referências, dereferência, casts `as` | indexação, fatiamento, operadores de erro `?` |
| Verificações | tipos, escopo, shadowing, mutabilidade, caminhos de retorno, aridade, `unsafe` obrigatório para ponteiro cru e `extern fn`, atributos | borrow checker, lifetimes, ownership/moves |
| Bibliotecas | builtins `print`/`println`; FFI com C via `extern fn` | `kyn:core` e `kyn:std` (imports são validados, mas não fornecem símbolos) |

Consulte [docs/status.md](docs/status.md) para o estado detalhado e
[docs/language_reference.md](docs/language_reference.md) para a referência.

## Estrutura do repositório

```text
.
├── build.zig            # fonte única de verdade para build, testes e integração
├── src/
│   ├── main.zig         # CLI
│   ├── root.zig         # raiz do módulo `kyn` (e dos testes unitários)
│   ├── driver.zig       # pipeline: lex → parse → sema → backend
│   ├── diag.zig         # diagnósticos com código, span e snippet
│   ├── lexer/           # tokenizer
│   ├── parser/          # parser recursivo-descendente
│   ├── ast/             # nós da AST
│   ├── sema/            # tipos, escopos, unsafe, atributos
│   ├── codegen/         # backend C99
│   └── runner.zig       # runner da suíte de integração
├── tests/
│   ├── cases/           # fixtures que compilam e executam (saída esperada)
│   ├── diagnostics/     # fixtures que devem falhar com um código específico
│   ├── regression/      # casos de código de saída (1..50)
│   └── pending/         # fixtures de recursos ainda não implementados
├── std/                 # biblioteca padrão planejada (sem API ligada ao compilador)
├── experiments/         # rascunhos históricos (self-hosting e stdlib), fora do build
└── docs/                # especificação, gramática, arquitetura e estado
```

## Documentação

- [Arquitetura do compilador](docs/architecture.md)
- [Estado de implementação](docs/status.md)
- [Desenvolvimento, build e testes](docs/development.md)
- [Referência da linguagem](docs/language_reference.md)
- [Gramática lexical](docs/grammar.ebnf) e [gramática sintática](docs/syntax.ebnf)
- [Princípios de design](docs/language_design.md)
- [Modelo de memória](docs/memory_model.md)
- [Testes e fixtures](tests/README.md)
- [Roadmap](ROADMAP.md) · [Changelog](CHANGELOG.md) · [Como contribuir](CONTRIBUTING.md)

## Contribuindo

Contribuições são bem-vindas. Antes de abrir uma alteração, leia
[CONTRIBUTING.md](CONTRIBUTING.md) e descreva o que foi implementado e **como foi
verificado** (`zig build check` é o mínimo esperado). Não apresente protótipos, stubs
ou itens do roadmap como funcionalidades concluídas.

## Licença

Licenciado sob a licença MIT. Consulte [LICENSE](LICENSE).
