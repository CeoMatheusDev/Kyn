# Referência preliminar da linguagem Kyn

**Status:** proposta ilustrativa — não normativa.  
**Extensão:** `.kyn`  
**Gramática do que está implementado:** [syntax.ebnf](syntax.ebnf)

Este documento reúne exemplos e decisões de design para a experiência de
programação em Kyn. **Parte da sintaxe abaixo ainda não é suportada** pelo
compilador 0.4.0-alpha.1: consulte a tabela de estado antes de copiar um exemplo.
Nomes de módulos, funções e tipos marcados como ilustrativos não representam APIs
existentes na biblioteca padrão.

## Estado dos exemplos deste documento

| Seção | Estado no compilador 0.4.0-alpha.1 |
| --- | --- |
| 1. Arquivo e estrutura mínima | Parcial: `fn main() -> i32` funciona; `import std.io` é aceito, mas não fornece `io.println` |
| 2. Importações e módulos | Parcial: `import` é aceito e o nome é validado; nenhum símbolo é importado |
| 3. Funções | Implementado, exceto generics e convenções ainda não especificadas |
| 4. Variáveis e mutabilidade | Implementado (`let`, `var`, `let mut`); shadowing entre escopos permitido |
| 5. Tipos primitivos | Implementado, com `str` = `const char *` terminado em NUL |
| 6. Estruturas e métodos | Implementado para `self: &T` / `&mut T`; funções como `sqrt` não existem |
| 7. Enumerações e resultados | Enums implementados; `Result<T, E>` e `?` **não** |
| 8. Coleções, slices e ponteiros | `&T`, `&mut T`, `*T`, `*const T`, `[N]T`, `[]T`, `[]const T`, indexação `a[i]`, fatias `a[lo..hi]` e `.len` implementados; `Vec`/`Map` da biblioteca padrão **não** existem |
| 9. Alocação e ciclo de vida | **Não implementado** (sem `Allocator`) |
| 10. Controle de fluxo | `if`/`else`, `while`, `break`, `continue`, `for i in a..b` e `for x in colecao` implementados |
| 11. Segurança e operações unsafe | Implementado para dereferência de ponteiro cru, escrita por ponteiro e chamada de `extern fn` |
| 12. Interoperabilidade com C | `extern fn` (inclusive variádico) implementado e testado; `#[repr(C)]` aceito |
| 13. Exemplo integrado | Parcial: compila se `io.println` for trocado por `println` |
| 14. Organização sugerida de um projeto | **Não implementado** (sem `kyn.toml`, sem resolução de módulos) |

## 1. Arquivo e estrutura mínima

Um programa-fonte utiliza a extensão `.kyn`. A forma pretendida de um programa simples é:

```kyn
// main.kyn
import std.io;

fn main() -> i32 {
    let message: str = "Hello, Kyn!";
    io.println(message);
    return 0;
}
```

O ponto de entrada `main`, a assinatura aceita e a convenção de retorno ainda precisam ser especificados formalmente.

## 2. Importações e módulos

A proposta utiliza importações explícitas:

```kyn
import std.io;
import std.memory;
import app.math.vector;
```

A resolução de caminhos, visibilidade, aliases, importações cíclicas e empacotamento de módulos ainda estão em aberto.

## 3. Funções

Declarações usam `fn`, parâmetros tipados e `->` para o tipo de retorno:

```kyn
fn add(left: i32, right: i32) -> i32 {
    return left + right;
}

fn initialize() -> void {
    return;
}
```

A sintaxe de funções genéricas, parâmetros por valor ou referência, convenções de chamada e funções externas ainda precisa de definição normativa.

## 4. Variáveis e mutabilidade

A convenção proposta diferencia bindings imutáveis e mutáveis:

```kyn
fn main() -> void {
    let immutable: i32 = 100;
    var mutable: i32 = 200;

    mutable = 300;
    return;
}
```

A inferência de tipos pode ser considerada futuramente, mas anotações explícitas devem permanecer disponíveis. Regras de shadowing e inicialização ainda precisam ser definidas.

## 5. Tipos primitivos

Conjunto inicial sugerido:

| Família | Tipos propostos |
| --- | --- |
| Inteiros com sinal | `i8`, `i16`, `i32`, `i64`, `i128` |
| Inteiros sem sinal | `u8`, `u16`, `u32`, `u64`, `u128` |
| Largura da arquitetura | `isize`, `usize` |
| Ponto flutuante | `f32`, `f64` |
| Booleano | `bool` |
| Caractere | `char` |
| Texto | `str` |
| Sem valor de retorno | `void` |

Tamanhos, alinhamento, overflow, conversões implícitas e representação de `char` e `str` ainda não são contratos estáveis. Em particular, `str` precisa ter uma representação e um modelo de lifetime definidos.

## 6. Estruturas e métodos

`struct` representa agregados nomeados:

```kyn
struct Vector3 {
    x: f32,
    y: f32,
    z: f32,
}

impl Vector3 {
    fn new(x: f32, y: f32, z: f32) -> Vector3 {
        return Vector3 {
            x: x,
            y: y,
            z: z,
        };
    }

    fn magnitude(self: &Vector3) -> f32 {
        return sqrt(
            self.x * self.x +
            self.y * self.y +
            self.z * self.z
        );
    }
}
```

A sintaxe de inicialização, métodos associados, receiver, visibilidade e layout de estruturas ainda precisa ser formalizada.

## 7. Enumerações e resultados

`enum` pode representar alternativas discriminadas:

```kyn
enum FileError {
    NotFound,
    PermissionDenied,
    InvalidFormat,
}
```

Uma família de tipos como `Result<T, E>` é proposta para erros explícitos:

```kyn
fn read_file(path: str) -> Result<[]u8, FileError> {
    // Implementação ilustrativa.
}
```

Os construtores de sucesso e erro, pattern matching, propagação de erro e representação ABI ainda não estão definidos.

## 8. Coleções, slices e ponteiros

A notação `[]T` é usada nestes exemplos como uma proposta de slice:

```kyn
let bytes: []u8;
```

A forma `*T` é reservada como notação proposta para ponteiro cru. Referências são representadas por `&T` e referências mutáveis por `&mut T`:

```kyn
fn increment(value: &mut i32) -> void {
    *value += 1;
}
```

Essas notações não definem, por si só, validade, lifetime, aliasing, nullability ou segurança de dereferência. Esses contratos precisam ser especificados antes de serem considerados recursos implementados.

## 9. Alocação e ciclo de vida

O objetivo é que alocações dinâmicas sejam explícitas e que o programador possa selecionar a estratégia de alocação:

```kyn
fn main() -> i32 {
    let allocator: Allocator = heap_allocator();
    let buffer: []u8 = allocator.alloc(u8, 1024);

    buffer[0] = 42;

    allocator.free(buffer);
    return 0;
}
```

`Allocator`, `heap_allocator`, `alloc` e `free` são nomes ilustrativos, não uma API padronizada disponível. O contrato final precisa definir falha de alocação, alinhamento, overflow, ownership, dupla liberação e duração do allocator.

Objetivos do modelo de memória:

- evitar garbage collector obrigatório;
- tornar alocação e liberação observáveis;
- permitir allocators customizados;
- definir ownership e transferência de propriedade;
- especificar empréstimos compartilhados e exclusivos;
- documentar layout, alinhamento e interoperabilidade.

Consulte [memory_model.md](memory_model.md).

## 10. Controle de fluxo

Exemplo de condicionais:

```kyn
fn calculate(value: i32) -> i32 {
    if value > 100 {
        return value * 2;
    } else if value > 0 {
        return value + 10;
    }

    return 0;
}
```

Exemplo de repetição:

```kyn
fn count() -> void {
    var index: usize = 0;

    while index < 10 {
        println(index);
        index += 1;
    }

    return;
}
```

As regras de escopo, expressões booleanas, break, continue, for e avaliação de curto-circuito precisam ser definidas.

## 11. Segurança e operações unsafe

A linguagem pretende oferecer operações de baixo nível sem misturá-las silenciosamente com operações seguras. Um formato possível para delimitar operações não verificáveis estaticamente é:

```kyn
unsafe {
    // Operações cujo contrato depende do programador.
}
```

A sintaxe e a semântica desse bloco ainda são propostas. A especificação deverá listar quais operações exigem `unsafe`, quais invariantes devem ser mantidos e como a FFI participa desse modelo.

## 12. Interoperabilidade com C

A interoperabilidade exige contratos explícitos para:

- convenção de chamada;
- layout e alinhamento;
- tipos compatíveis com C;
- ownership de buffers e strings;
- tratamento de erros entre fronteiras;
- duração de callbacks e ponteiros;
- símbolos exportados e importados.

Atributos como `#[repr(C)]` são apenas uma possibilidade de sintaxe em avaliação, não uma garantia disponível hoje.

## 13. Exemplo integrado

O exemplo reúne importação, estrutura, função, referência e fluxo de controle:

```kyn
import std.io;

struct Config {
    width: u32,
    height: u32,
    fullscreen: bool,
}

fn initialize(config: &Config) -> bool {
    if config.width == 0 || config.height == 0 {
        return false;
    }

    return true;
}

fn main() -> i32 {
    let config: Config = Config {
        width: 1920,
        height: 1080,
        fullscreen: false,
    };

    if !initialize(&config) {
        io.println("Initialization failed");
        return 1;
    }

    io.println("Kyn initialized successfully");
    return 0;
}
```

Este exemplo é uma visão de design. Não deve ser usado como teste de compilabilidade do estado atual.

## 14. Organização sugerida de um projeto

```text
project/
├── kyn.toml
├── src/
│   ├── main.kyn
│   ├── core/
│   │   ├── memory.kyn
│   │   └── allocator.kyn
│   ├── math/
│   │   ├── vector.kyn
│   │   └── matrix.kyn
│   └── platform/
│       └── linux.kyn
├── tests/
│   ├── memory_test.kyn
│   └── vector_test.kyn
└── build/
```

Essa árvore é uma convenção sugerida. O formato de manifesto `kyn.toml`, descoberta de módulos, diretórios de saída e organização de testes ainda não foram implementados como padrão.

## 15. Decisões pendentes antes de congelar a sintaxe

1. Gramática completa de declarações, tipos, expressões e padrões.
2. Precedência e associatividade de operadores.
3. Conversões numéricas e regras de overflow.
4. Semântica de `str`, slices e arrays.
5. Ownership, moves, borrowing e lifetimes.
6. Ponteiros crus, nullability e contexto `unsafe`.
7. Generics, traits/interfaces e monomorfização.
8. Módulos, visibilidade e resolução de dependências.
9. Layout, alinhamento, ABI e FFI.
10. Semântica de erros e tipos algébricos.
11. Modelo de concorrência e garantias contra data races.
12. Convenção do ponto de entrada e modelo de runtime.

## Referências relacionadas

- [Princípios de design](language_design.md)
- [Especificação geral](spec.md)
- [Modelo de memória](memory_model.md)
- [Arquitetura do compilador](architecture.md)
- [Estado de implementação](status.md)
