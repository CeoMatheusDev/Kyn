# The Kyn tutorial

This tutorial teaches how to write, compile and run programs in **Kyn** with the
current compiler (`kync`). Everything here was executed with the compiler
itself: the examples are complete programs, verified by the repository's test
suite.

> **Language state:** Kyn is under active development (`0.3.x`). The subset
> described in this tutorial is what the compiler **accepts and runs today**.
> Planned features (pointers, slices, `defer`, generics, FFI, …) appear in the
> last section with the real state of each one.

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
12. [Text and output](#12-text-and-output)
13. [Modules](#13-modules)
14. [Diagnostics](#14-diagnostics)
15. [Generating binaries and IR](#15-generating-binaries-and-ir)
16. [Testing your code](#16-testing-your-code)
17. [Common mistakes](#17-common-mistakes)
18. [Current limits](#18-current-limits)
19. [Where Kyn is going](#19-where-kyn-is-going)

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
| `kync emit --asm <file.kyn> -o out.s` | Emits x86-64 assembly (Linux, System V, no libc). |
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
| `i32` | 32-bit signed integer | the only integer type available today |
| `bool` | boolean | results of comparisons and `&&`/`\|\|` |
| `str` | static slice: pointer + length | literal text only; no concatenation |
| `void` | absence of value | return of `print`, `print_i32` and of functions with no value |
| `struct` | scalar fields in declaration order | nominal: each `struct` is a distinct type |

Types are nominal and **there is no implicit promotion**: `i32` does not become
`bool`, `bool` does not become `i32`, `str` does not become `i32`. Every
conversion would have to be explicit — when conversion operators exist, they will
be explicit by construction.

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

Precedence (tightest to loosest): unary `-`/`!`, `*`/`/`/`%`, `+`/`-`,
comparisons (`<`, `<=`, `>`, `>=`), equality (`==`, `!=`), `&&`, `||`. Use
parentheses when the intent is not obvious.

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
  (hence: up to 6 fields).
- `str` counts two registers; a struct with four fields plus three `i32`
  already exceeds the limit and is diagnosed in the declaration **and** in the
  call.

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
- For now enums are **local variables only**: parameters, returns and struct
  fields of enum type are diagnosed as unsupported, and so is `switch` over a
  constructed value (`switch Shape.Empty { ... }`).

Representation (both backends): a tag slot plus a payload slot, the payload
slot unused when no case declares one; `switch` reads the tag and compares it
against the case order, and copies the payload into the binding slot at the
start of the arm.

---

## 12. Text and output

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

## 13. Modules

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

## 14. Diagnostics

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

## 15. Generating binaries and IR

Two backends, one semantics:

```sh
# Native: System V assembly, no libc, its own _start
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

## 16. Testing your code

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

## 17. Common mistakes

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

## 18. Current limits

The compiler explicitly diagnoses every item below — nothing fails silently:

- **Memory:** no pointers, slices, arrays, allocators, `defer`/`errdefer`.
- **Types:** only `i32`, `bool`, `str`, `void`, structs of scalar fields and
  local enums (no `i8`/`i64`/`u32`/`f32`, no `union`, no `char`).
- **Enums:** no enum in parameters/returns/struct fields, no payload other than
  `i32`, no operator on enum values, no `switch` over a constructed value, no
  nested payload patterns.
- **Structs:** no struct field, no `str` field, no empty struct, no
  methods/`impl`; struct by value in calls **exists** (up to 6 fields).
- **Text:** no concatenation, interpolation, comparison by content, escapes
  (`\n`) or `print(bool)`.
- **Errors:** no error sets, error unions or `?`.
- **Metaprogramming:** no generics, no `comptime`.
- **Low level:** no `unsafe`, `volatile`, atomics, inline assembly, MMIO,
  attributes (`#[...]`), controllable sections/symbols or configurable calling
  conventions.
- **Interop:** no integrated C FFI (there is an isolated experiment in
  `src/ffi/`).
- **Targets:** Linux x86-64 only; the IR `target triple` is fixed; no ARM64,
  Windows or freestanding/stable `--lib`.
- **CLI/tools:** no LSP, no JSON diagnostics, no automatic fix-it.

---

## 19. Where Kyn is going

Planned order (detailed in `DEVELOPMENT_STATE.md` §5 and `ROADMAP.md`):

1. `impl`/methods with `self`, enums across calls (parameters, returns, struct
   fields) and payloads beyond `i32`.
2. Larger numeric types (`i64`, `u8`, `f32`) with explicit conversion rules.
3. Pointers, fixed arrays and slices with documented layout.
4. `unsafe`, `volatile`, atomics and MMIO — the explicit border to hardware.
5. Error sets/unions, `try`, `defer`/`errdefer`.
6. Static generics and `comptime`.
7. C FFI, cross-compilation, ARM64, freestanding and controllable linking.
8. First-class diagnostics: stable codes, notes, fix suggestions and JSON output
   for editors.

Every step lands with success **and** failure tests, documentation and an entry
in `DEVELOPMENT_STATE.md` — and none of them gives up the central rule: the
compiler never silently accepts a program it can reject.
