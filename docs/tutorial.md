# The Kyn tutorial

This tutorial teaches how to write, compile and run programs in **Kyn** with the
current compiler (`kync`). Everything here was executed with the compiler
itself: the examples are complete programs, verified by the repository's test
suite.

> **Language state:** Kyn is under active development (`0.3.x`). The subset
> described in this tutorial is what the compiler **accepts and runs today**.
> The current subset includes fixed-width integers, explicit integer casts,
> bitwise operations, pointers, structs, enums, methods and imports. Slices,
> generics, integrated FFI and self-hosting remain incomplete or unimplemented.

## Index

1. [Philosophy in one page](#1-philosophy-in-one-page)
2. [Setting up](#2-setting-up)
3. [First program](#3-first-program)
4. [The `kync` CLI](#4-the-kync-cli)
5. [Types](#5-types)
6. [Variables and mutability](#6-variables-and-mutability)
7. [Operators](#7-operators)
8. [Control flow](#8-control-flow)
9. [Functions](#9-functions)
10. [Structs](#10-structs)
11. [Enums and `switch`](#11-enums-and-switch)
12. [Methods and `impl`](#12-methods-and-impl)
13. [Text and output](#13-text-and-output)
14. [Modules](#14-modules)
15. [Diagnostics](#15-diagnostics)
16. [Generating binaries and IR](#16-generating-binaries-and-ir)
17. [Testing your code](#17-testing-your-code)
18. [Common mistakes](#18-common-mistakes)
19. [Current limits](#19-current-limits)
20. [Where Kyn is going](#20-where-kyn-is-going)

---

## 1. Philosophy in one page

Kyn is a systems language: compiled, statically typed, with no mandatory runtime,
no garbage collector and no hidden costs. Three rules guide everything:

- **Explicit control.** What happens to memory and to the hardware must be
  written in the code.
- **No silent conversions.** Types do not change by themselves; the compiler
  rejects what is not provably valid.
- **A detectable error is a blocking error.** If the compiler can prove the
  program is wrong, it does not produce an executable — and it explains why.

You will find those rules in every chapter: `let` versus `var`, no coercion
between `i32`/`bool`/`str`, messages that state the expected and the found type,
and backend limits documented instead of undefined behavior.

---

## 2. Setting up

The compiler is written in Zig and uses Zig `0.17.0` (pinned in
`build.zig.zon`).

```sh
# 1. Toolchain (when no official Zig install is available)
python3 -m pip download ziglang==0.17.0.post0 --no-deps -d /tmp/zigwheel
mkdir -p ~/.local/zigpkg && cd ~/.local/zigpkg
python3 -m zipfile -e /tmp/zigwheel/*.whl .
chmod +x ziglang/zig
mkdir -p ~/.local/bin && ln -sf ~/.local/zigpkg/ziglang/zig ~/.local/bin/zig

# 2. Build kync
cd Kyn
zig build                 # produces zig-out/bin/kync
./zig-out/bin/kync --version

# 3. Validation suites
zig build test            # unit tests (lexer, parser, sema, backends)
zig build e2e             # compiles, assembles, links and runs the fixtures
```

Native backend requirements: `as` and `ld` (binutils) on Linux x86-64. To
validate the LLVM IR you need `llvm-as` or `clang` (`zig build validate-ir`).

---

## 3. First program

```kyn
fn main() -> i32 {
    return 42;
}
```

- Every program starts with `fn main() -> i32` (or `-> void`).
- `return` gives back the value; the return value of `main` becomes the
  process's **exit code** (42 here).
- No missing semicolons: every declaration and every `return` ends with `;`.

Save the file as `first.kyn` and run:

```sh
zig-out/bin/kync check first.kyn                  # check only
zig-out/bin/kync emit --asm first.kyn -o first.s  # x86-64 assembly
as first.s -o first.o && ld first.o -o first
./first; echo $?                                  # prints 42
```

`main` may also return nothing:

```kyn
fn main() -> void {
    return;
}
```

---

## 4. The `kync` CLI

| Command | What it does |
|---|---|
| `kync check <file.kyn>` | Analyzes the whole program and reports diagnostics; writes no output. |
| `kync emit --asm <file.kyn> -o out.s` | Emits Linux x86-64 assembly (Kyn register ABI, no libc). |
| `kync emit --llvm <file.kyn> -o out.ll` | Emits textual LLVM IR. |
| `kync emit --lib <...>` | Emits the experimental library module. |
| `kync --version` | Shows the version and available backends. |

CLI exit codes: `0` success, `1` compilation error, `2` invalid usage, `3` I/O
failure.

`check` and `emit` compile the **import graph** starting from the given file, so
you point at the program's `main.kyn`.

---

## 5. Types

| Type | Representation | Notes |
|---|---|---|
| `i8`, `i16`, `i32`, `i64` | 8/16/32/64-bit signed integers | Fixed-width integer types |
| `u8`, `u16`, `u32`, `u64` | 8/16/32/64-bit unsigned integers | Fixed-width integer types |
| `usize` | Target-sized unsigned integer | Currently represented as 64-bit on the supported target |
| `bool` | boolean | results of comparisons and `&&`/`\|\|` |
| `str` | static slice: pointer + length | literal text only; no concatenation |
| `void` | absence of value | return of `print`, `print_i32` and of functions with no value |
| `ptr` | Native pointer | Source annotation for an unknown pointee; `ptr<T>` is descriptive compiler notation, not source syntax |
| `struct` | scalar fields in declaration order | nominal: each `struct` is a distinct type |
| `enum` | tag + optional payload | Nominal; payload currently limited to `i32` |

Integer types are not implicitly converted. Use the explicit `as` operator for
integer-to-integer conversions; narrowing truncates and widening extends
according to the source type's signedness. Conversions involving `bool`,
`str` or `void` are rejected. Types remain nominal where applicable.

Literals:

```kyn
fn main() -> i32 {
    let whole = 42;
    let negative = 0 - 7;   // there is no negative literal: use the expression
    let yes = 1 < 2;        // bool
    let text = "kyn";
    let empty: str = "";
    return whole + negative + 49;
}
```

Literal overflow is diagnosed at compile time (`i32` covers
`-2147483648..2147483647`).

---

## 6. Variables and mutability

```kyn
fn main() -> i32 {
    let fixed = 10;          // immutable (default)
    var changeable: i32 = 1; // mutable, with a type annotation
    changeable = changeable + 1; // allowed
    // fixed = 20;           // error: 'fixed' is immutable
    return fixed + changeable;
}
```

Rules:

- `let` creates an immutable variable; `var` creates a mutable one.
- The initializer is **mandatory** — there is no variable without a defined
  value.
- The type annotation is optional when the initializer makes the type
  unambiguous: `let n = 42;` is `i32`.
- Assigning to a `let` is an error (`immutable_assignment`), and the same applies
  to struct fields (`p.x = 1;` requires `var p`).
- `void` is not storable: `let x = print("a");` is diagnosed.

---

## 7. Operators

```kyn
fn main() -> i32 {
    let a = 7;
    let b = 3;
    let sum = a + b;           // 10
    let diff = a - b;          // 4
    let product = a * b;       // 21
    let quotient = a / b;      // 2   (integer division, truncates toward zero)
    let rest = a % b;          // 1
    let less = a < b;          // bool
    let equal = a == a;        // bool
    let not = !less;           // bool
    let negated = 0 - a;       // -7
    let logic = less || b < a;
    return sum * 2 - diff + product + quotient + rest;
}
```

Precedence (tightest to loosest): unary operators, multiplicative operators,
additive operators, shifts, relational comparisons, equality, bitwise AND,
bitwise XOR, bitwise OR, logical AND and logical OR. Integer bitwise operators
require matching integer types (except shift counts, which may use another
integer type). Shift counts wrap modulo the left operand's width: `u8` shifted
by 8 uses count 0, and a negative count uses its two's-complement low bits.
Use parentheses when the intent is not obvious.

`&&` and `||` **short-circuit**: the right side is only evaluated when the result
is not already decided.

Division by zero is a case to handle in the code: there is no exception and no
automatic `panic` — the program is a binary that performs the operation you
asked for.

---

## 8. Control flow

```kyn
fn main() -> i32 {
    var total: i32 = 0;
    var i: i32 = 0;
    while i < 5 {
        if i % 2 == 0 {
            total = total + i;
        } else if i == 3 {
            total = total + 100;
        } else {
            total = total - 1;
        }
        i = i + 1;
    }
    return total; // 0 - 1 + 2 + 100 + 4 = 105
}
```

- Conditions require `bool` (an `i32` in `if` is an error, not "true if
  non-zero").
- Blocks are delimited by `{ }`; there is no `for`.
- `if`/`while` are statements, not expressions: to produce a value use `return`
  or a variable.
- `else if` chains without extra brace nesting.

---

## 9. Functions

```kyn
fn double(n: i32) -> i32 {
    return n + n;
}

fn sum(a: i32, b: i32) -> i32 {
    return a + b;
}

fn no_return(x: i32) -> void {
    print_i32(x);
    return;
}

fn main() -> i32 {
    no_return(sum(double(2), double(3)));
    return double(sum(1, 2));
}
```

- The signature declares parameter and return types; `-> void` may be omitted.
- Functions may be declared in any order and may be recursive.
- The compiler requires **every path** of a non-`void` function to end with a
  `return` carrying a value (`alwaysReturns` over the block structure).
- Calls nest freely, as long as the register limit is respected: **6 registers
  per call**, counting each struct field as one and each `str` as two.

```kyn
fn fibonacci(n: i32) -> i32 {
    if n < 2 {
        return n;
    }
    return fibonacci(n - 1) + fibonacci(n - 2);
}

fn main() -> i32 {
    return fibonacci(10); // 55
}
```

---

## 10. Structs

Structs group scalar fields and have **nominal identity**: two structs with the
same fields are still different types.

```kyn
struct Point {
    x: i32,
    y: i32,
}

fn main() -> i32 {
    var p: Point = Point { x: 3, y: 4 };
    p.x = p.x + 1;        // field assignment requires 'var'
    let copy: Point = p;  // field-by-field copy
    return copy.x + copy.y; // 8
}
```

- The literal must initialize **every** field, exactly once each.
- Accessing a field that does not exist is an error (`undefined_field`).
- A struct with a `str` field, with a struct field (nested) or an empty struct is
  not supported yet — all three cases are diagnosed.

### Struct by value in functions

Since `0.3.7-alpha.1`, structs cross calls by value, in parameters and in
returns:

```kyn
struct Point {
    x: i32,
    y: i32,
}

fn origin() -> Point {
    return Point { x: 3, y: 4 };
}

fn shift(p: Point, d: i32) -> Point {
    return Point { x: p.x + d, y: p.y + d };
}

fn sum(p: Point) -> i32 {
    return p.x + p.y;
}

fn main() -> i32 {
    let a = origin();          // struct return
    let b = shift(a, 10);      // parameter and return
    print_i32(sum(origin()));  // struct returned straight as an argument
    return sum(b);             // sum((13, 14)) = 27
}
```

Call contract (the same in both backends):

- Each scalar field takes **one register**, in declaration order.
- Structs return with one register per field (`%eax`, `%edx`, `%ecx`, `%r8d`,
  `%r9d`, `%r10d` on x86-64; aggregate `{ i32, … }` in the LLVM IR).
- The 6-register limit applies to parameters/arguments and to the struct return
  (hence: up to 6 fields). Wide scalar integers (`i64`, `u64`, `usize`) count
  two registers for arguments (low/high 32-bit halves), but return in `%rax`.
- `str` counts two registers; pointers and individual struct fields count one
  full register. A struct with four fields plus three `i32` already exceeds the
  limit and is diagnosed in the declaration **and** in the call. This is a
  Kyn-specific convention, not a C calling convention.

---

## 11. Enums and `switch`

An `enum` is a type with a closed set of cases. Cases are ordered: the position
in the declaration is the **tag** stored in the value, and a case may carry one
`i32` payload.

```kyn
enum Shape {
    Circle(i32),
    Square(i32),
    Empty,
}

fn main() -> i32 {
    let shape = Shape.Circle(5);
    var area_class: i32 = 0;
    switch shape {
        Circle(radius) => {
            area_class = radius;
        }
        Square(side) => {
            area_class = side;
        }
        Empty => {
            area_class = 0;
        }
    }
    print_i32(area_class); // 5
    return area_class;
}
```

Rules the compiler enforces:

- `Shape.Circle(5)` builds a case **with** payload; `Shape.Empty` (no
  parentheses) is a case **without** payload. Using the wrong form is a
  diagnostic, with the fix in the message.
- `switch` works on an enum **variable** and must be exhaustive: either every
  case has an arm or there is an `else` arm. Missing cases are listed:
  `'switch' on 'Shape' is not exhaustive: missing 'Square', 'Empty'`.
- An `else` arm in a switch that already covers every case is **unreachable**
  and therefore an error.
- `Case(name)` binds the payload to a new `i32` variable valid only inside that
  arm; a bare `Case` matches a case without payload.
- Enums compare equal by no operator: `==`, arithmetic and conditions on an
  enum are rejected — `switch` is the only consumer.
- Enums cross calls **by value**: a parameter and a return both carry the pair
  (tag, payload) in two registers, and the enum identity is checked (passing an
  enum of another type is an error, even with the same cases).
- Every enum parameter consumes **two** of the six argument registers.
- Still diagnosed: a struct **field** of enum type, a payload type other than
  `i32`, and `switch` over a constructed value (`switch Shape.Empty { ... }`) —
  store it in a variable first.

```kyn
enum Shape {
    Circle(i32),
    Square(i32),
    Empty,
}

fn make(kind: i32, size: i32) -> Shape {
    if kind == 0 {
        return Shape.Circle(size);
    }
    if kind == 1 {
        return Shape.Square(size);
    }
    return Shape.Empty;
}

fn weight(shape: Shape) -> i32 {
    var result: i32 = 0;
    switch shape {
        Circle(r) => {
            result = r;
        }
        Square(side) => {
            result = side * 2;
        }
        Empty => {
            result = 0;
        }
    }
    return result;
}

fn main() -> i32 {
    let circle = make(0, 3);      // enum returned by a call
    let square = make(1, 3);
    print_i32(weight(circle));    // 3
    print_i32(weight(square));    // 6
    print_i32(weight(make(2, 9))); // 0 — enum straight from a call
    return weight(circle) + weight(square);
}
```

Representation and call contract (the same in both backends): a tag slot plus a
payload slot, the payload slot unused when no case declares one. On x86-64 a
parameter arrives as a register pair (tag in `%edi`, payload in `%esi`, …), an
argument pushes two words and a return comes back in `%eax` (tag) and `%edx`
(payload); in the LLVM IR the parameters are flattened into two `i32` and the
return is the `{ i32, i32 }` aggregate. `switch` reads the tag and compares it
against the case order, and copies the payload into the binding slot at the
start of the arm.

---

## 12. Methods and `impl`

Methods are declared in an `impl` block for a struct or an enum and receive the
value they work on as an **explicit first parameter** named `self`:

```kyn
struct Point {
    x: i32,
    y: i32,
}

impl Point {
    fn sum(self: Point) -> i32 {
        return self.x + self.y;
    }

    fn moved(self: Point, dx: i32, dy: i32) -> Point {
        return Point { x: self.x + dx, y: self.y + dy };
    }
}

fn main() -> i32 {
    let p = Point { x: 3, y: 4 };
    print_i32(p.sum());            // 7
    let far = p.moved(10, 10);     // methods receive and return values
    print_i32(far.sum());          // 27
    return p.sum() + far.sum();    // 34
}
```

Rules the compiler enforces:

- The receiver is the **first parameter of the signature**, written
  `self: Point` — there is no implicit `self` at this stage. A method without it
  (`fn sum() -> i32`), with another name (`that: Point`) or with another type
  (`self: Pair`) is a diagnostic.
- `p.sum()` passes `p` as **argument 1**; the arguments written in the call are
  arguments 2..n. So `p.moved(10, 10)` is `fn moved(self: Point, dx: i32, dy:
  i32)` called with three words.
- Methods are **nominal** and per type: `Point.sum` exists only for `Point`, and
  a method never answers a bare call (`sum(p)` is `function 'sum' is not
  declared`).
- A method name cannot repeat a **field** of the struct, another method of the
  same type, or the symbol of a free function (`fn Point_sum()` collides with
  `Point.sum`).
- `main` must stay a free function.
- An `impl` for a name that is not a declared struct or enum is diagnosed.

Calling and composition work on values of any supported shape: a method may
return the type it belongs to (`p.moved(1, 1).sum()`), take `str` or enums as
parameters, and call other methods of the receiver. The receiver is an ordinary
argument for the **six-register** limit, so `self: Point` (two fields) plus four
`i32` parameters already fills it.

Example with an enum method:

```kyn
enum Shape {
    Circle(i32),
    Square(i32),
    Empty,
}

impl Shape {
    fn weight(self: Shape) -> i32 {
        var result: i32 = 0;
        switch self {
            Circle(r) => { result = r; }
            Square(side) => { result = side * 2; }
            Empty => { result = 0; }
        }
        return result;
    }

    fn grow(self: Shape, delta: i32) -> Shape {
        var bigger: Shape = Shape.Empty;
        switch self {
            Circle(r) => { bigger = Shape.Circle(r + delta); }
            Square(side) => { bigger = Shape.Square(side + delta); }
            Empty => { bigger = Shape.Empty; }
        }
        return bigger;
    }
}

fn main() -> i32 {
    let shape = Shape.Circle(5);
    print_i32(shape.weight());              // 5
    print_i32(shape.grow(2).weight());      // 7
    return shape.grow(1).weight();          // 6
}
```

Not supported yet, all diagnosed: associated functions without a receiver
(`Point.new(...)`), a receiver that is a temporary literal
(`Point { x: 1, y: 2 }.sum()`), reading a field of a call result
(`p.moved(1, 1).x`), references/`&self`, `f32` fields, generics, visibility and
operator methods.

The symbol of a method is `Type_method` (`kyn_Point_sum` in the native backend,
`@Point_sum` in the IR), so it is stable, unique per type and never collides
silently with a free function.

---

## 13. Text and output

`str` is a **static slice**: pointer to constant bytes + length. Today only
literals exist — there is no concatenation, no comparison by content and no
interpolation.

```kyn
fn main() -> i32 {
    print("kyn");        // text + line break
    print("");           // an empty string is valid
    print_i32(42);       // number + line break
    print_i32(0 - 7);    // -7
    print_i32(2147483647);
    return 0;
}
```

`print` and `print_i32` are **builtin functions**, not keywords:

- `print(expr)` requires exactly one `str`; returns `void`; writes the text and
  the line break.
- `print_i32(expr)` requires exactly one `i32`; returns `void`; writes the value
  in decimal (including `-2147483648`).
- The names are reserved: declaring `fn print(...)` is an error.
- The result is `void`, so it cannot be assigned to a variable.

`str` also travels between functions by value:

```kyn
fn title() -> str {
    return "kyn";
}

fn echo(s: str) -> str {
    return s;
}

fn main() -> i32 {
    let t = title();
    print(t);
    print(echo("bootstrap"));
    print(echo(title()));
    return 0;
}
```

On x86-64, `str` travels as a register pair (`%rdi`/`%rsi`, `%rdx`/`%rcx`,
`%r8`/`%r9`) and comes back in `%rax` (pointer) + `%rdx` (length). Since each
`str` consumes two registers, at most three fit in one call.

---

## 14. Modules

`import "path.kyn";` comes before any declaration and loads another file,
resolved **relative to the importing file**:

```kyn
import "point.kyn";

fn main() -> i32 {
    let p = origin();
    return p.x + p.y;
}
```

In `point.kyn` (a library file, with no `main`):

```kyn
struct Point {
    x: i32,
    y: i32,
}

fn origin() -> Point {
    return Point { x: 6, y: 7 };
}
```

Current rules:

- Each file is loaded **once** (deduplicated by normalized path), even with
  diamond imports.
- Symbols are flattened into a single scope: function and struct names must be
  unique in the whole program.
- Cycles, missing files and duplicated symbols are diagnosed with the correct
  source file.

---

## 15. Diagnostics

The compiler reports **every** independent error in one run, with file, line,
column, the source line and a marker:

```text
$ kync check example.kyn
example.kyn:3:18: error: initializer of 'x' has type 'str', but the annotation is 'i32'
    let x: i32 = "text";
                 ^^^^^^^
```

Categories exposed today: `error` (proven violation — blocks the executable) and
`warning` (risk, does not block). The CLI returns `1` when there is any error; no
backend runs in that case.

Common messages and what they mean:

| Message | Meaning |
|---|---|
| `variable 'x' is not declared` | name out of scope or mistyped |
| `initializer of 'x' has type 'str', but the annotation is 'i32'` | annotation and value disagree |
| `'x' is immutable; declare it with 'var'` | assignment to a `let` (or to a field of a `let`) |
| `function 'f' may finish without running 'return'` | path without return in a non-`void` function |
| `argument 1 of 'f' must be 'i32', found 'str'` | argument type |
| `argument 1 of 'f' is struct 'B', expected 'A'` | nominal structs |
| `function 'f' uses 7 parameter registers …` | backend limit (6, `str` = 2) |
| `struct 'P' has no field 'z'` | field does not exist |
| `literal of 'P' does not initialize field 'y'` | incomplete literal |

---

## 16. Generating binaries and IR

Two backends, one semantics:

```sh
# Native: Linux x86-64, Kyn-internal register ABI, no libc, its own _start
kync emit --asm program.kyn -o program.s
as program.s -o program.o
ld program.o -o program
./program

# Textual LLVM IR (validated by llvm-as in CI)
kync emit --llvm program.kyn -o program.ll
llvm-as program.ll -o program.bc
```

The native backend uses direct syscalls (`write` for `print`, `write` + decimal
division for `print_i32`, `exit` for the `main` return). There is no libc
dependency, no dynamic allocation and no global state.

The IR uses libc's `@write` for output and represents `str` as `{ ptr, i64 }` and
a struct as an aggregate in the return (parameters are flattened field by field).

---

## 17. Testing your code

The repository's `e2e` suite is driven by comments at the top of the file:

```kyn
// expect-stdout: hello, kyn
// expect-exit: 0
fn main() -> i32 {
    print("hello, kyn");
    return 0;
}
```

- `// expect-stdout: <line>` — one directive per expected line, compared **in
  order** with the real stdout (through `diff`).
- `// expect-exit: N` — expected exit code.

For invalid cases the fixture goes in `tests/e2e/negative/` and the expectation
is that `kync check` exits with code `1`.

```sh
zig build e2e        # 102 cases today
```

---

## 18. Common mistakes

**Forgetting to cover every path with `return`**

```kyn
fn sign(n: i32) -> i32 {
    if n < 0 {
        return 0 - 1;
    }
    // error: 'sign' may finish without running 'return' with value 'i32'
}

fn main() -> i32 {
    return sign(1);
}
```

Fix it with a final `return` outside the `if`.

**Using `i32` as a condition**

```kyn
fn main() -> i32 {
    let n = 1;
    // if n { }   // error: condition must be 'bool'
    if n != 0 {
        return 1;
    }
    return 0;
}
```

**Comparing `str`**

```kyn
fn main() -> i32 {
    // if "a" == "b" { }  // error: 'str' comparison is not supported
    return 0;
}
```

Copy the text into variables and compare what the language knows how to compare
(for now, there is no text comparison).

**Exceeding the register limit**

```kyn
fn too_many(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32) -> i32 {
    // error: 7 registers; the backend supports at most 6
    return a + b + c + d + e + f + g;
}

fn main() -> i32 {
    return 0;
}
```

Grouping values into a struct helps: `fn sum(p: Point)` consumes one register per
field and the same limit still applies.

**Returning `str` from `main`**

```kyn
// error: 'main' must return 'i32' or 'void'
fn main() -> str {
    return "kyn";
}
```

---

## 19. Current limits

The compiler's exact supported subset is maintained in [Implementation status](status.md) and [the accepted grammar](syntax.ebnf). The main limitations are:

- **Memory and pointers:** typed pointers and basic pointer operations exist, but there is no defined ownership/borrowing system, no slices, arrays, allocators or `defer`.
- **Types and aggregates:** fixed-width integers, `usize`, `bool`, `str`, `void`, structs and enums are implemented within documented restrictions. Nested structs, `str` struct fields and enum struct fields are not supported.
- **Enums:** payloads are currently limited to `i32`; enum values support parameters and returns, and `switch` is exhaustive. General enum operators and switching directly on a constructed temporary are not supported.
- **Text:** `str` is a static pointer-plus-length value. Printing and equality/inequality are implemented; concatenation, interpolation, formatting and relational comparisons are not.
- **Language abstractions:** no generics, slices, closures, `comptime`, error unions or complete error-handling model.
- **Safety and ABI:** no integrated `unsafe` syntax, stable ownership model, complete `repr(C)` contract or integrated C FFI.
- **Targets:** the executable native backend targets Linux x86-64 and uses a Kyn-internal register ABI, not the C ABI. Other architectures, Windows and freestanding/embedded targets are not implemented.
- **Tooling:** the VS Code extension currently provides declarative syntax support only. There is no LSP, semantic completion, navigation, formatter or debugger.

Do not infer support from files in `src/compiler/`, `src/kyn/`, `std/` or from design documents. Those areas include prototypes and experiments.

---

## 20. Where Kyn is going

The [roadmap](../ROADMAP.md) describes proposed work, not release commitments. The next architectural priorities are:

1. Establish a stable intermediate representation between semantic analysis and code generation.
2. Define pointer validity, aliasing, ownership and lifetime rules before expanding unsafe operations.
3. Specify target configuration and ABI boundaries before adding additional architectures.
4. Integrate FFI only after layout, calling convention and ownership contracts are testable.
5. Grow the standard library around explicit allocation and platform boundaries.
6. Develop the editor integration around a real language server backed by compiler diagnostics.
7. Begin self-hosting only when the language has enough stable features to support a reproducible bootstrap.

Every milestone should include positive and negative tests, updated grammar and documentation, and reproducible validation. The compiler must not silently accept programs that violate its defined contracts.
