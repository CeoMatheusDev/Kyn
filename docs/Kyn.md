# Kyn — Guia do Usuário

Bem-vindo ao Kyn, uma linguagem experimental de sistemas compilada para
x86-64 Linux. Este documento ensina a usar a linguagem a partir de exemplos
que **realmente compilam** com o compilador atual (`kync`).

> **Status:** protótipo experimental. Nem todos os recursos de uma linguagem
> de produção estão disponíveis. Veja [status.md](status.md) para o conjunto
> exato do que foi implementado e validado.

---

## 1. Instalação e primeiro programa

O compilador Kyn se chama `kync`. Ele é construído com Zig:

```bash
zig build                  # compila e instala o kync em zig-out/bin/kync
zig-out/bin/kync --help
```

O bootstrap atual do compilador é escrito em **Zig 0.17.0**. O projeto usa
`build.zig` e o Zig Build System para compilar o compilador e executar os testes.
**Ainda não existe um sistema de build próprio em Kyn (`kyn.build`)**; isso é
uma possibilidade futura, não um recurso disponível.

Crie um arquivo `hello.kyn`:

```kyn
fn main() -> i32 {
    return 0;
}
```

Compile e execute:

```bash
./.zig-cache/o/*/kync emit --asm hello.kyn -o hello.s
as hello.s -o hello.o
ld hello.o -o hello
./hello
echo $?   # 0
```

Ou, mais simplesmente, use o runner de testes e2e:

```bash
zig build e2e
```

---

## 2. Estrutura de um programa

Um arquivo Kyn usa a extensão `.kyn`. Um programa consiste em:

- opcionalmente, `import "caminho";` no topo (arquivos `.kyn` relativos ao importador);
- declarações de `struct`, `enum`, `fn`;
- uma função `fn main() -> i32` que é o ponto de entrada.

Exemplo mínimo completo:

```kyn
struct Point { x: i32, y: i32 }

fn main() -> i32 {
    let p: Point = Point { x: 1, y: 2 };
    return p.x + p.y;
}
```

---

## 3. Funções

Declara uma função com `fn nome(param: Tipo, ...) -> Tipo { ... }`.

```kyn
fn sum(a: i32, b: i32) -> i32 {
    return a + b;
}

fn main() -> i32 {
    return sum(10, 20);   // 30
}
```

### Regras importantes

- O corpo da função é um bloco entre `{` e `}`;
- `return` encerra a função com um valor;
- Até 6 registradores de argumento x86-64, com convenção interna de Kyn (não é ABI C). `str`, `i64`, `u64` e `usize` contam como 2;
- Ponteiros e cada campo de `struct` contam como 1 registrador;
- `main` deve retornar `i32` (ou `void`, nesse caso o código de saída é 0).

---

## 4. Variáveis e tipos

Use `let` para variáveis imutáveis e `var` para mutáveis. Toda declaração
precisa de um inicializador.

### Tipos escalares

```kyn
let a: i32 = 42;
let b: u64 = 100;
let c: bool = true;
let d: str = "texto";
// void só pode ser usado como tipo de retorno; não é armazenável.
```

O tipo pode ser omitido quando o compilador consegue inferir:

```kyn
let x = 42;       // i32
let y = true;     // bool
let s = "olá";    // str
```

### Inteiros de largura fixa

O compilador aceita inteiros com largura e sinal explícitos:

| Tipo | Largura | Representação |
|---|---:|---|
| `i8`, `i16`, `i32`, `i64` | 8–64 bits | Com sinal |
| `u8`, `u16`, `u32`, `u64` | 8–64 bits | Sem sinal |
| `usize` | 64 bits no alvo x86-64 atual | Sem sinal |

Literais inteiros sem anotação são inferidos como `i32`. Operações binárias
entre inteiros exigem operandos do mesmo tipo, **exceto deslocamentos**, cujo
valor e contagem podem ser inteiros de tipos diferentes; não há conversão
implícita entre larguras ou entre tipos com/sem sinal nos demais operadores.
Overflow de literal fora da faixa do tipo é diagnosticado. Para converter, use
`as`:

```kyn
let small: u8 = 255 as u8;
let wide: u64 = small as u64;  // extensão com zero
let signed: i64 = (-42 as i32) as i64; // extensão de sinal
let truncated: u8 = (300 as u32) as u8; // mantém os bits inferiores
```

`as` só aceita conversões entre tipos inteiros. Conversões para/de `bool`, `str`
e `void` não são suportadas. Redução de largura trunca; aumento de largura usa
extensão de sinal ou zero conforme o tipo de origem.

### Mutabilidade

```kyn
var n: i32 = 0;
n = n + 1;        // OK: var é mutável

let m: i32 = 0;
m = m + 1;        // ERRO: 'let' é imutável
```

---

## 5. Expressões

### Aritmética

```kyn
let a = 10 + 5;   // 15
let b = 10 - 3;   // 7
let c = 4 * 3;    // 12
let d = 10 / 3;   // 3  (divisão inteira)
let e = 10 % 3;   // 1  (módulo)
```

### Comparações

```kyn
let x = (1 == 1);    // true
let y = (2 != 3);    // true
let z = (5 > 3);     // true
let w = (2 <= 2);    // true
```

Resultam em `bool`.

### Operadores lógicos (curto-circuito)

```kyn
let a = true && false;   // false
let b = true || false;   // true
```

### Bitwise

Os operadores bitwise estão disponíveis para operandos inteiros do mesmo tipo:

```kyn
let a: u8 = 5 as u8;
let b: u8 = 3 as u8;
let and: u8 = a & b;   // 1
let or: u8 = a | b;    // 7
let xor: u8 = a ^ b;   // 6
let not: u8 = ~a;      // inversão dos bits de u8
let left: u8 = a << (2 as u8);
let right: u8 = a >> (1 as u8);
```

`&`, `|`, `^` e `~` usam operandos do mesmo tipo. Em `<<` e `>>`, o operando
esquerdo define o tipo do resultado e a contagem pode ter outro tipo inteiro;
o deslocamento à direita é aritmético para tipos com sinal e lógico para tipos
sem sinal. A contagem é reduzida módulo a largura (8, 16, 32 ou 64 bits) do
operando esquerdo, inclusive quando tem outro tipo ou é negativa: usam-se os
bits baixos da representação em complemento de dois. Assim, `1 as u8 << 8`
usa contagem zero; valores válidos menores que a largura não mudam.

### Conversão explícita (`as`)

```kyn
let a: i32 = 300;
let b: u8 = a as u8;   // truncamento: 44
let c: i64 = a as i64; // extensão de sinal
```

`as` só funciona entre tipos inteiros. `bool` e `str` são rejeitados.

---

## 6. Fluxo de controle

### `if` / `else` / `else if`

A condição deve ser `bool`.

```kyn
let x = 10;
if x > 5 {
    return 1;
} else if x == 5 {
    return 2;
} else {
    return 3;
}
```

### `while`

```kyn
let total: i32 = 0;
let i: i32 = 0;
while i < 5 {
    total = total + i;
    i = i + 1;
}
return total;   // 10
```

### Blocos

```kyn
{
    let interno: i32 = 99;
    return interno;
}
```

Variáveis declaradas dentro de um bloco são locais a ele.

---

## 7. Strings (`str`)

`str` é uma fatia estática: ponteiro para bytes + comprimento. Só existem
literais estáticos por enquanto.

```kyn
let s: str = "Hello, Kyn!";
let t = "outro texto";   // inferido como str
```

### Impressão

```kyn
print("Hello");     // escreve o texto + quebra de linha
print_i32(42);      // escreve o número em decimal + quebra de linha
```

### Comparação de strings

`str == str` e `str != str` comparam ponteiro e comprimento:

```kyn
let a = "hello";
let b = "hello";
let c = "world";

if a == b { return 1; }   // verdadeiro
if a != c { return 2; }   // verdadeiro
return 0;
```

**Não suportado:** `<`, `<=`, `>`, `>=` em `str`, concatenação,
formatação.

---

## 8. Structs

Declare uma struct com campos scalares:

```kyn
struct Point { x: i32, y: i32 }
```

Crie um literal inicializando todos os campos, uma vez cada:

```kyn
let p: Point = Point { x: 7, y: 8 };
```

Acesse e atribua campos:

```kyn
let dx = p.x;       // leitura
p.x = p.x + 2;      // atribuição (apenas em var)
```

Structs são copiados por valor:

```kyn
let q: Point = p;   // cópia campo a campo
```

Structs cruzam funções por valor (até 6 campos/registradores):

```kyn
fn distance(p: Point) -> i32 {
    return p.x + p.y;
}

fn main() -> i32 {
    let p: Point = Point { x: 3, y: 4 };
    return distance(p);   // 7
}
```

### Métodos (`impl`)

```kyn
impl Point {
    fn sum(self: Point) -> i32 {
        return self.x + self.y;
    }
}

fn main() -> i32 {
    let p: Point = Point { x: 3, y: 4 };
    return p.sum();   // 7
}
```

---

## 9. Enums

Declare um enum com casos opcionais de payload `i32`:

```kyn
enum Color { Red, Green, Blue }
enum Shape { Circle(i32), Square(i32) }
```

Use os casos:

```kyn
let c: Color = Color.Red;
let s: Shape = Shape.Circle(5);
```

### `switch` exaustivo

O `switch` sobre um enum deve cobrir todos os casos ou ter um `else`:

```kyn
fn describe(c: Color) -> i32 {
    switch c {
        Case(Color.Red) => return 1;
        Case(Color.Green) => return 2;
        Case(Color.Blue) => return 3;
    }
}

fn describe_any(c: Color) -> i32 {
    switch c {
        Case(Color.Red) => return 1;
        else => return 0;
    }
}
```

Binding de payload:

```kyn
fn radius(s: Shape) -> i32 {
    switch s {
        Case(Shape.Circle(r)) => return r;
        Case(Shape.Square(r)) => return r;
    }
}
```

Enums cruzam funções por valor (2 registradores: tag + payload).

---

## 10. Ponteiros (`ptr`)

O operador `&` obtém o endereço de uma variável e produz um ponteiro tipado
`ptr<T>`. O operador `*` desreferencia o ponteiro e produz um valor do tipo
apontado. A forma abreviada `ptr` em uma anotação representa `ptr<unknown>`.
`ptr<T>` é notação descritiva do tipo inferido pelo compilador, não uma sintaxe
de anotação genérica aceita pelo parser: no código-fonte, escreva `ptr`.

```kyn
var x: i32 = 42;
let p: ptr = &x;
let value: i32 = *p;   // 42
```

O tipo apontado é acompanhado pelo compilador quando conhecido: a declaração
`let p: ptr = &x` mantém o tipo de `x`. Parâmetros e campos declarados como `ptr` recebem
ponteiros tipados, mas apagam essa informação; não é permitido atribuir um
ponteiro de tipo apontado desconhecido a uma variável cujo tipo foi inferido
como `ptr<T>`. Ponteiros ocupam uma palavra/registrador no limite atual de
argumentos.

### Acesso a campos via ponteiro: `(*ptr).field`

Quando o endereço foi obtido de uma variável `struct`, o compilador preserva a
identidade/layout da estrutura para permitir acesso aos campos:

```kyn
struct Point { x: i32, y: i32 }

fn main() -> i32 {
    var point: Point = Point { x: 7, y: 8 };
    let p: ptr = &point;
    return (*p).x + (*p).y;   // 15
}
```

### Aritmética e comparação

O subconjunto atual aceita `ptr + i32`, `i32 + ptr` e `ptr - i32`, que produzem
ponteiros, além de `ptr - ptr`, que produz `i32`. Também aceita `==` e `!=` entre
ponteiros:

```kyn
let p: ptr = &x;
let q = p + 4;
let r = p - 2;
let distance: i32 = q - p;
let same: bool = p == q;
```

**Semântica atual:** o deslocamento é um `i32` com sinal, multiplicado pelo
tamanho do tipo apontado (1/2/4/8 bytes para escalares; structs usam seus slots
internos de 8 bytes). A subtração exige ponteiros de tipos compatíveis e
retorna uma distância `i32`; `==`/`!=` comparam o endereço inteiro de 64 bits,
mesmo quando os tipos apontados diferem. `ptr` sem origem tipada não pode ser
desreferenciado nem usado em aritmética; `let p: ptr = &x` preserva o tipo de
`x`. O layout interno não garante compatibilidade com C.

**Limites importantes:** não há verificação de bounds, lifetime, validade,
nullability ou aliasing; não há referências (`&T`, `&mut T`) nem bloco `unsafe`
integrado à linguagem. Os endereços podem ser inválidos; nunca desreferencie um
endereço fora do objeto. Comparações relacionais (`<`, `<=`, `>`, `>=`) e
`ptr + ptr` não são suportados.

---

## 11. Módulos e imports

Um arquivo pode importar outro:

```kyn
// main.kyn
import "util/math.kyn";

fn main() -> i32 {
    return double(21);
}
```

```kyn
// util/math.kyn
fn double(n: i32) -> i32 {
    return n + n;
}
```

Regras:
- O caminho é relativo ao arquivo que importa;
- Cada módulo é carregado uma vez;
- Ciclos, arquivos ausentes e símbolos duplicados são diagnosticados.

---

## 12. Exemplos completos

### Fatorial

```kyn
fn fat(n: i32) -> i32 {
    if n <= 1 { return 1; }
    return n * fat(n - 1);
}

fn main() -> i32 {
    return fat(5);   // 120
}
```

### Fibonacci

```kyn
fn fib(n: i32) -> i32 {
    if n <= 1 { return n; }
    return fib(n - 1) + fib(n - 2);
}

fn main() -> i32 {
    return fib(10);   // 55
}
```

### Estrutura com método e ponteiro

```kyn
struct Ret { w: i32, h: i32 }

impl Ret {
    fn area(self: Ret) -> i32 {
        return self.w * self.h;
    }
}

fn main() -> i32 {
    var r: Ret = Ret { w: 10, y: 5 };  // ← ERRO: campo se chama h, não y
    let ptr: ptr = &r;
    return (*ptr).w * (*ptr).h;        // 50 (via ponteiro)
}
```

Corrigido:

```kyn
struct Ret { w: i32, h: i32 }

impl Ret {
    fn area(self: Ret) -> i32 {
        return self.w * self.h;
    }
}

fn main() -> i32 {
    var r: Ret = Ret { w: 10, h: 5 };
    let ptr: ptr = &r;
    return (*ptr).w * (*ptr).h;   // 50
}
```

---

## 13. Limites atuais

Os itens abaixo não fazem parte do subconjunto implementado ou são rejeitados
pelo compilador:

- `unsafe` integrado à sintaxe/AST, atributos `#[...]` e referências `&T`/`&mut T`;
- Generics, slices `[]T`, arrays e indexação;
- `str` em campo de struct, concatenação/formatação e comparações relacionais de
  strings (`<`, `<=`, `>`, `>=`); `==` e `!=` comparam ponteiro e comprimento;
- Struct com campo de struct (aninhado) e struct vazia;
- Enum como campo de struct e payload de enum diferente de `i32`;
- `f32`, `f64` e demais tipos não-inteiros;
- `for`, closures, `Result<T, E>`/`?` e visibilidade `pub`;
- `main` retornando `str`;
- Chamadas com mais de 6 palavras/registradores de argumento: `str` e enum
  ocupam 2; ponteiros ocupam 1; structs contam um por campo. Não há ainda
  passagem de argumentos excedentes pela stack.

A presença de ponteiros não implica um modelo de memória seguro ou completo:
o compilador ainda não formaliza ownership, lifetimes, aliasing, nullability,
validade de endereço ou operações `volatile`.

---

## 14. Como validar seus programas

Use o conjunto de testes e2e:

```bash
# Compilar o compilador (gera zig-out/bin/kync)
zig build

# Checar um arquivo sem gerar código
zig-out/bin/kync check hello.kyn

# Emitir LLVM IR ou Assembly
zig-out/bin/kync emit --llvm hello.kyn -o hello.ll
zig-out/bin/kync emit --asm hello.kyn -o hello.s

# Testes unitários, e2e e validação LLVM
zig build test
zig build e2e
zig build validate-ir
```

Cada fixture positiva usa `// expect-exit: N` para declarar o código de
saída esperado. Cada fixture negativa deve falhar na checagem semântica.

---

## 15. Próximos passos

O Kyn está em desenvolvimento. Consulte:

- [status.md](status.md) — estado de implementação por componente;
- [language_reference.md](language_reference.md) — referência da linguagem;
- [syntax.ebnf](syntax.ebnf) — gramática exata aceita pelo parser;
- [ROADMAP.md](ROADMAP.md) — planejamento futuro (fases 2 a 5).

---

_Boa programação em Kyn!_
