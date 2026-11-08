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
zig build            # constrói o kync
./.zig-cache/o/*/kync --help
```

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
- Até 6 registradores de argumento (SysV). `str` conta como 2;
- Cada campo de `struct` conta como 1 registrador;
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
let e: void = ();   // void não é armazenável, usado apenas como retorno
```

O tipo pode ser omitido quando o compilador consegue inferir:

```kyn
let x = 42;       // i32
let y = true;     // bool
let s = "olá";    // str
```

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

```kyn
let a = 5 & 3;    // 1
let b = 5 | 3;    // 7
let c = 5 ^ 3;    // 6
let d = ~5;       // -6
let e = 1 << 2;   // 4
let f = 8 >> 1;   // 4
```

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

`&variavel` produz um ponteiro para a variável. `*ptr` faz desreferência.

```kyn
var x: i32 = 42;
let p: ptr = &x;       // ptr<unknown>, compatível com qualquer ptr<T>
return *p;             // 42
```

### Acesso a campos via ponteiro: `(*ptr).field`

Se o ponteiro vier de `&struct_var`, o compilador sabe o layout da struct:

```kyn
struct Point { x: i32, y: i32 }
fn main() -> i32 {
    var p: Point = Point { x: 7, y: 8 };
    let ptr: ptr = &p;
    return (*ptr).x + (*ptr).y;   // 15
}
```

### Aritmética de ponteiros

```kyn
let p: ptr = &x;
let q = p + 4;   // ptr (avança 4 unidades do tipo pointee)
let r = p - 2;   // ptr
let d = p - q;   // i32 (diferença em unidades)
```

### Comparação de ponteiros

```kyn
if p == q { ... }   // bool
if p != q { ... }   // bool
```

**Não suportado:** `<`, `<=`, `>`, `>=` entre ponteiros; `ptr + ptr`.

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

## 13. Limites atuais (diagnostados pelo compilador)

O seguinte **não está implementado** e gera erro de compilação:

- `unsafe`, `#[...]` atributos;
- Generics, slices `[]T`;
- `str` em campo de struct, comparação relacional de `str` (`<`, `<=`, `>`, `>=`);
- Struct com campo de struct (aninhado), struct vazia;
- Enum como campo de struct, tipos de payload além de `i32`;
- `f32`/`f64` e outros tipos não-inteiros;
- `for`, closures, `Result<T, E>`/`?`, visibilidade `pub`;
- `main` retornando `str`;
- Mais de 6 registradores de argumento (cada `str` conta 2, cada campo de struct conta 1).

---

## 14. Como validar seus programas

Use o conjunto de testes e2e:

```bash
# Todos os testes
zig build e2e

# Apenas build
zig build

# Apenas testes unitários
zig build test
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
