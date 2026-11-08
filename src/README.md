# Compiler source

This directory contains the Zig bootstrap compiler.

## Active compilation pipeline

```text
main.zig → driver.zig → lexer → parser/AST → semantic analysis → codegen
```

- `main.zig`: command-line interface (`kync`).
- `driver.zig`: compilation orchestration, module loading and compilation lifetime.
- `span.zig`, `diagnostics.zig`: source locations and user-facing diagnostics.
- `lexer/`, `parser/`, `ast/`, `sema/`, `codegen/`: compiler stages.
- `ffi/`: isolated interoperability experiment; not integrated.
- `kyn/`, `compiler/`: Kyn-language prototypes; not part of the active bootstrap pipeline.

Keep stage boundaries explicit. Before moving a file, update Zig imports, build module configuration, tests, documentation and CI. See [architecture](../docs/architecture.md) and the [maintainer guide](../docs/maintainer-guide.md).
