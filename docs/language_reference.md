# Preliminary Kyn language reference

**Status:** illustrative proposal — not normative.  
**Intended extension:** `.kyn`

This document gathers examples and preliminary decisions for the programming
experience in Kyn. The syntax below is not fully supported by the current
compiler yet. Some module, function and type names are illustrative and do not
represent APIs that exist in the standard library.

> **What already compiles:** see [status.md](status.md) for the implemented
> subset and [syntax.ebnf](syntax.ebnf) for the exact grammar accepted by the
> parser. The examples in this document are design vision and must not be used as
> a compilability test.

## 1. File and minimal structure

A source program uses the `.kyn` extension. The intended shape of a simple
program is:

```kyn
// main.kyn
import std.io;

fn main() -> i32 {
    let message: str = "Hello, Kyn!";
    io.println(message);
    return 0;
}
```

The `main` entry point, the accepted signature and the return convention still
have to be formally specified.

## 2. Imports and modules

**Implemented today:** an import is a file path relative to the file that
declares it, placed before the functions:

```kyn
// main.kyn
import "util/format.kyn";
import "lib/math.kyn";

fn main() -> i32 {
    return double(21);
}
```

```kyn
// lib/math.kyn
fn double(x: i32) -> i32 {
    return x * 2;
}
```

Observed rules: the path is a string literal between quotes; each file is loaded
once; cycles, missing files and functions declared in more than one file produce
a diagnostic with the `file:line:column` of the source file. Symbols from every
module are gathered into a single global scope (*flattening*), so function names
must be unique in the program.

**Design vision (not implemented):** package imports (`import std.io;`),
visibility (`pub`), aliases, selective imports and module packaging/manifest.

## 3. Functions

Declarations use `fn`, typed parameters and `->` for the return type:

```kyn
fn add(left: i32, right: i32) -> i32 {
    return left + right;
}

fn initialize() -> void {
    return;
}
```

The syntax of generic functions, by-value or by-reference parameters, calling
conventions and external functions still needs a normative definition.

## 4. Variables and mutability

The proposed convention separates immutable and mutable bindings:

```kyn
fn main() -> void {
    let immutable: i32 = 100;
    var mutable: i32 = 200;

    mutable = 300;
    return;
}
```

Type inference may be considered in the future, but explicit annotations must
remain available. Shadowing and initialization rules still have to be defined.

## 5. Primitive types

Suggested initial set:

| Family | Implemented types |
| --- | --- |
| Signed integers | `i8`, `i16`, `i32`, `i64` |
| Unsigned integers | `u8`, `u16`, `u32`, `u64` |
| Architecture width | `usize` |
| Boolean | `bool` |
| Text | `str` |
| No return value | `void` |

**Implemented today:** all fixed-width integer types above (`i8`/`i16`/`i32`/`i64`,
`u8`/`u16`/`u32`/`u64`, `usize`), `bool` and `void`, plus `str` for static
literals. Arithmetic, ordering and bitwise operators require operands of the
same integer type; shifts accept an independently typed integer count. Integer
literals default to `i32`; literal overflow is diagnosed. Full native behavior
at every declared width is still pending (see `status.md`).

### Numeric conversion (`as`)

There are no implicit conversions between integer types. Convert between
integer types with the explicit cast expression `expr as Type`. Conversions
to or from `bool`, `str` and `void` are rejected:

```kyn
let a: u8 = 255 as u8;
let b: u32 = a as u32;   // widening (zero-extend)
let c: i32 = (-42 as i16) as i32;  // sign-extend then widen
let d: u8 = (300 as u32) as u8;    // narrowing (truncate)
```

Only fixed-width integer names are accepted as cast targets: `i8`, `i16`,
`i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `usize`. Casting to `bool`, `str` or
`void` is rejected by semantics. A same-width cast (`u8 as u8`) is a no-op.

### Bitwise operators

All fixed-width integer types have bitwise operators. AND/XOR/OR require
operands of the same type; shifts accept an independently typed integer count.
The result has the type of the left operand:

| Operator | Meaning | Precedence | Associativity |
| --- | --- | --- | --- |
| `~` | bitwise NOT (unary) | 11 (highest, prefix) | right |
| `<<` `>>` | left / right shift | 8 | left |
| `&` | bitwise AND | 7 | left |
| `^` | bitwise XOR | 6 | left |
| \| | bitwise OR | 5 | left |

The right shift is arithmetic for signed left operands, logical otherwise.
Shift counts outside the left operand's width have no portable behavior yet.
Bitwise AND/XOR/OR require both operands to have the same type:

```kyn
fn main() -> i32 {
    let a: u8 = 240 as u8;  // 11110000
    let b: u8 = 170 as u8;  // 10101010

    let and: u8 = a & b;    // 10100000 = 160
    let or:  u8 = a | b;    // 11111010 = 250
    let xor: u8 = a ^ b;    // 01011010 = 90
    let not: u8 = ~a;       // 00001111 = 15
    let shl: u8 = (1 as u8) << (4 as u8);   // 16
    let shr: u8 = (240 as u8) >> (4 as u8); // 15

    return 0;
}
```

Bitwise operators bind tighter than comparison but looser than additive
operators. Use parentheses to disambiguate when mixing them with `+`/`-` or
`==`/`!=`.

### Pointers (`ptr`, `&`, `*`)

**Implemented:** pointer values (described semantically as `ptr<T>`), address-of
(`&var`) and dereference (`*ptr`). The source annotation syntax is `ptr`; the
`ptr<T>` form describes the inferred pointee type and is not accepted as a
source-level generic type expression. A pointer is address-sized (one 64-bit
register). The pointee type is
tracked: `&` applied to a value of type `T` yields `ptr<T>`, and `*` applied to
a `ptr<T>` yields `T`. A generic `ptr` parameter or field has an unknown
pointee: a known `ptr<T>` can be passed or stored there (type erasure), but an
unknown pointer cannot be assigned to a variable with a known pointee. A local
`let p: ptr = &x` retains `x`'s inferred pointee type. Pointers can be stored,
passed and returned; they count as one register in the six-register limit.

```kyn
fn main() -> i32 {
    var x: i32 = 42;
    let p: ptr = &x;      // address of x; p has type ptr<i32>
    return *p;            // 42
}
```

Pointer arithmetic and comparison are supported for **known pointee types**:
- `ptr<T> + i32`, `i32 + ptr<T>`, `ptr<T> - i32` yield `ptr<T>`; offsets
  are signed and scaled by the pointee size (1/2/4/8 bytes for the scalar types;
  structs currently use their internal `(field_count + 1) * 8` byte frame size).
- `ptr<T> - ptr<T>` yields `i32`, the difference in those units; both operands
  must have the same pointee type, including nominal struct identity.
- `ptr<T> == ptr<U>` and `ptr<T> != ptr<U>` compare full addresses and yield
  `bool`, even when `T` and `U` differ. No dereference occurs.
- Pointer multiplication/division, `ptr + ptr`, untyped `ptr + i32` and
  relational comparisons are rejected by the frontend.

There are no arrays, bounds checks, ownership, aliasing or lifetime checks yet:
only use offsets inside an object (or one-past it), and never dereference a
one-past/dangling address. The layout is **not** `repr(C)`; no FFI guarantee
follows from the internal stride. Pointer distance is represented as `i32`, so
out-of-range differences cannot be represented by this subset.

Field access through a pointer is supported via `(*ptr).field`. The pointer
must point to a struct, and the struct's layout must be known (the pointer must
have been obtained via `&struct_var`):

```kyn
struct Point { x: i32, y: i32 }
fn main() -> i32 {
    var p: Point = Point { x: 7, y: 8 };
    let ptr: ptr = &p;
    return (*ptr).x + (*ptr).y;  // 15
}
```

Current limits, all diagnosed: `&` applied to a temporary or a `str` slice;
`*` on a non-pointer or an unknown/aggregate pointee as a scalar expression;
`ptr` used with `<`, `<=`, `>`, `>=`; `(*ptr).field` when the pointee's struct
identity is unknown. `&variable.field` is supported for direct struct fields;
`&(*ptr).field`, stores through raw pointers, `volatile` and const-qualified
pointers are not supported. A `ptr` function parameter has an unknown pointee
until a future typed-parameter syntax provides a contract.

At this stage `str` is a **static slice**: pointer to constant bytes + length,
kept in two slots. It exists to give the program text output:

```kyn
fn main() -> i32 {
    print("kyn");          // writes "kyn" and a line break
    var s: str = "a";
    s = "b";
    let t = s;             // copy of the slice (pointer + length)
    print(t);              // writes "b"
    return 0;
}
```

`str` also **crosses calls by value**: every `str` parameter, argument and return
carries two registers (pointer and length), and the six-register limit per call
counts each `str` as two.

```kyn
fn echo(s: str) -> str {
    return s;
}

fn title() -> str {
    return "kyn";
}

fn main() -> i32 {
    print(echo(title()));  // writes "kyn"
    return 0;
}
```

`print` is a builtin function (`print(expr)` requires exactly one `str`, returns
`void`, writes the text and the line break); the name is reserved for functions
declared in the source. `print_i32(expr)` follows the same rule with an `i32`
argument and writes the number in decimal, including `-2147483648`:

```kyn
fn main() -> i32 {
    let a = 20;
    let b = 22;
    print("sum");      // "sum"
    print_i32(a + b);  // "42"
    print_i32(0 - a);  // "-20"
    return 0;
}
```

Current limits, all diagnosed: struct field of type `str`, `str` in arithmetic,
condition or relational operators (`<`, `<=`, `>`, `>=`), concatenation,
formatting, `main` returning `str`, more than six registers in
parameters/arguments (each `str` counts two) and an unused `str` expression
(`print(...)` or assignment). String equality (`str == str`, `str != str`) is
supported: it compares both the pointer and the length and yields `bool`.

Not stable contracts yet: sizes and alignments of the other types, run-time
overflow, implicit conversions, `char` representation and the `str` lifetime
model (for now only static literals exist).

## 6. Structures and methods

**Implemented today:** `struct` with scalar fields, literals `Name { field:
value }` (every field exactly once), `p.field` access, `p.field = v` assignment
(only on `var`) and copy by value between variables:

```kyn
struct Point {
    x: i32,
    y: i32,
}

fn main() -> i32 {
    var p: Point = Point { x: 3, y: 4 };
    p.x = p.x + p.y;
    let q: Point = p;
    return q.x;
}
```

Structs cross calls **by value**, with one register per field:

```kyn
struct Point {
    x: i32,
    y: i32,
}

fn origin() -> Point {
    return Point { x: 3, y: 4 };
}

fn sum(p: Point) -> i32 {
    return p.x + p.y;
}

fn main() -> i32 {
    let a = origin();  // struct return
    return sum(a);     // by-value parameter (7)
}
```

The six-register limit applies to parameters/arguments and to the return (hence
at most six fields), counting `str` as two.

Current limits, all diagnosed: field of struct type (nested struct); empty
`struct`; struct as a condition, arithmetic operand or comparison; struct literal
outside initialization/assignment.

### Methods (`impl`)

Methods are **implemented** for structs and enums, in a name space per type:

```kyn
struct Point {
    x: i32,
    y: i32,
}

impl Point {
    // The receiver is an explicit first parameter, passed by value.
    fn sum(self: Point) -> i32 {
        return self.x + self.y;
    }

    fn moved(self: Point, dx: i32, dy: i32) -> Point {
        return Point { x: self.x + dx, y: self.y + dy };
    }
}

fn main() -> i32 {
    let p = Point { x: 3, y: 4 };
    return p.moved(1, 1).sum(); // 9
}
```

- The receiver is `self: Name` as the first **parameter of the signature** (no
  implicit `self` yet); the written arguments of `p.moved(1, 1)` are parameters
  2 and 3.
- `Type_method` is the symbol in both backends; a method never answers a bare
  call, never collides silently with a free function (`fn Point_sum()` is
  diagnosed) and may not reuse a field name.
- The receiver counts as argument 1 for the six-register limit.
- `main` stays a free function; an `impl` for an undeclared type is diagnosed.

Limits, all diagnosed: associated functions without a receiver
(`Point.new(...)`), receiver literal (`Point { x: 1, y: 2 }.sum()`), field read on
a call result (`p.moved(1, 1).x`), references (`&self`), operator methods,
visibility, generics and `f32` fields.

**Design vision (not implemented):** references, associated functions and
`f32` arithmetic — the example below is the intended shape, still unsupported:

```kyn
impl Vector3 {
    fn new(x: f32, y: f32, z: f32) -> Vector3 {
        return Vector3 { x: x, y: y, z: z };
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

References, `f32`, initialization syntax and visibility still have to be
formalized.

## 7. Enumerations and results

`enum` represents discriminated alternatives. **Implemented today** (see
`docs/syntax.ebnf`): cases in declaration order become the tag, one case may
carry an `i32` payload, `switch` over an enum variable must be exhaustive, and
enums cross calls **by value** (two registers: tag + payload).

```kyn
enum Shape {
    Circle(i32),
    Square(i32),
    Empty,
}

fn main() -> i32 {
    let shape = Shape.Circle(5);
    var result: i32 = 0;
    switch shape {
        Circle(radius) => { result = radius; }
        Square(side) => { result = side; }
        Empty => { result = 0; }
    }
    return result;
}
```

Current limits, enforced by semantics: no struct **field** of enum type (the
struct layout would need a second slot per field), the payload is `i32` only, no
operator accepts an enum (`==` and arithmetic are diagnosed; `switch` is the
only consumer) and `switch` requires a variable, not a constructed value.
Payload types beyond `i32`, enum fields and nested payload patterns are the next
steps.

A type family such as `Result<T, E>` is proposed for explicit errors:

```kyn
fn read_file(path: str) -> Result<[]u8, FileError> {
    // Illustrative implementation.
}
```

The success and error constructors, pattern matching, error propagation and ABI
representation are not defined yet.

## 8. Collections, slices and pointers

The `[]T` notation is used in these examples as a slice proposal:

```kyn
let bytes: []u8;
```

The `*T` form is reserved as the proposed notation for a raw pointer. References
are represented by `&T` and mutable references by `&mut T`:

```kyn
fn increment(value: &mut i32) -> void {
    *value += 1;
}
```

Those notations do not by themselves define validity, lifetime, aliasing,
nullability or dereference safety. Those contracts have to be specified before
they can be considered implemented features.

## 9. Allocation and lifetime

The goal is for dynamic allocations to be explicit and for the programmer to be
able to choose the allocation strategy:

```kyn
fn main() -> i32 {
    let allocator: Allocator = heap_allocator();
    let buffer: []u8 = allocator.alloc(u8, 1024);

    buffer[0] = 42;

    allocator.free(buffer);
    return 0;
}
```

`Allocator`, `heap_allocator`, `alloc` and `free` are illustrative names, not a
standardized available API. The final contract must define allocation failure,
alignment, overflow, ownership, double free and allocator duration.

Memory model goals:

- avoid a mandatory garbage collector;
- make allocation and release observable;
- allow custom allocators;
- define ownership and ownership transfer;
- specify shared and exclusive borrows;
- document layout, alignment and interoperability.

See [memory_model.md](memory_model.md).

## 10. Control flow

Conditional example:

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

Loop example:

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

The rules for scoping, boolean expressions, break, continue, for and
short-circuit evaluation still have to be defined.

## 11. Safety and unsafe operations

The language intends to offer low-level operations without silently mixing them
with safe operations. One possible format to delimit operations that cannot be
statically verified is:

```kyn
unsafe {
    // Operations whose contract depends on the programmer.
}
```

The syntax and semantics of that block are still proposals. The specification
must list which operations require `unsafe`, which invariants must hold and how
FFI takes part in that model.

## 12. Interoperability with C

Interoperability requires explicit contracts for:

- calling convention;
- layout and alignment;
- C-compatible types;
- ownership of buffers and strings;
- error handling across boundaries;
- lifetime of callbacks and pointers;
- exported and imported symbols.

Attributes such as `#[repr(C)]` are only one possible syntax under evaluation,
not a guarantee available today.

## 13. Integrated example

The example combines imports, a structure, a function, a reference and control
flow:

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

This example is a design vision. It must not be used as a compilability test of
the current state.

## 14. Suggested project organization

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

That tree is a suggested convention. The `kyn.toml` manifest format, module
discovery, output directories and test organization have not been implemented as
a standard yet.

## 15. Pending decisions before freezing the syntax

1. Complete grammar of declarations, types, expressions and patterns.
2. Operator precedence and associativity.
3. Numeric conversions and overflow rules.
4. Semantics of `str`, slices and arrays.
5. Ownership, moves, borrowing and lifetimes.
6. Raw pointers, nullability and the `unsafe` context.
7. Generics, traits/interfaces and monomorphization.
8. Modules, visibility and dependency resolution.
9. Layout, alignment, ABI and FFI.
10. Error semantics and algebraic types.
11. Concurrency model and data-race guarantees.
12. Entry point convention and runtime model.

## Related references

- [Design principles](language_design.md)
- [Overall specification](spec.md)
- [Memory model](memory_model.md)
- [Compiler architecture](architecture.md)
- [Implementation status](status.md)
