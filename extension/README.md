# Kyn Language Support for Visual Studio Code

Initial editor support for the [Kyn](https://github.com/CeoMatheusDev/Kyn)
programming language.

## Features

- Language registration for `.kyn` files.
- TextMate syntax highlighting.
- Line comments, bracket matching, auto-closing pairs and indentation rules.
- Basic code snippets for functions, `main`, structs, enums and control flow.

## Development

1. Open the repository in Visual Studio Code.
2. Open the `extension/` directory as the extension project.
3. Press `F5` to launch an Extension Development Host.
4. Open a `.kyn` file to inspect language registration and highlighting.

The extension currently provides declarative editor support only. It does not
implement a language server, diagnostics, go-to-definition, semantic
highlighting, formatting, debugging, or compiler integration.

## Compiler

The Kyn compiler is currently bootstrapped in Zig. Build it from the repository
root with:

```sh
zig build
```

The generated `kync` executable is placed at `zig-out/bin/kync`.

## Scope

Keep the grammar aligned with the syntax actually accepted by the compiler.
Do not add editor features that imply unsupported language constructs.
