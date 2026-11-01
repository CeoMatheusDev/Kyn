## Release Industrial Estável (v2.3.0)

- Congelamento final do compilador self-hosted `kync`.
- Documentação completa atualizada em `docs/spec.md`.
- Empacotamento do binário final.
- Zero vazamentos de memória, alocadores explícitos, semântica `unsafe` rigorosa.
- Mensagens de diagnóstico limpas (estilo Rust/Zig).

## Especificação Kyn — v0.1.0-alpha.1

- Sem GC, sem runtime pesado.
- Separação `kyn:core` (zero-deps, bare-metal) vs `kyn:std` (SO).
- Memory explícita: `@align`, `@packed`, `#[repr(C)]`.
- Ownership / Move com `unsafe` explícito.
- Erros via `Result<T, E>` (sem exceções).
- `comptime` para metaprogramação (sem pré-processador de texto).
- FFI zero-cost com ABI C.
- Compilador bootstrap: Zig 0.17.0.
- Target: LLVM IR (marco 1.4).
