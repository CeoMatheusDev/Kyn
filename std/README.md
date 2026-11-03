# Biblioteca padrão do Kyn

**Estado: planejamento.** Não existe API de biblioteca padrão ligada ao compilador
hoje. `import` valida o nome do módulo contra uma lista conhecida e nada mais; usar
qualquer símbolo importado resulta em `E0011` (nome indefinido).

Os únicos símbolos disponíveis em qualquer programa são os builtins do compilador
`print` e `println`, que aceitam 0 ou 1 argumento imprimível (`i*`, `u*`, `f*`,
`bool`, `char`, `str`) e não têm formatação. Para saída formatada, use a libc via
FFI:

```kyn
extern fn printf(fmt: *const u8, ...) -> i32;

fn main() -> i32 {
    unsafe {
        printf("%d %s\n", 42, "via libc");
    }
    return 0;
}
```

## Divisão pretendida

| Módulo | Escopo | Regra |
| --- | --- | --- |
| `kyn:core` | primitivas independentes de sistema operacional (memória, atomics, estruturas) | sem syscalls, sem alocação implícita, apto a bare-metal |
| `kyn:std` | recursos dependentes de SO (`io`, `thread`, `net`, tempo, processos) | pode usar syscalls; nunca é exigido por `kyn:core` |

Essa separação é arquitetural. Ela só passa a valer quando houver implementação,
contratos e testes — não basta existir um arquivo com o nome do módulo.

## O que precisa acontecer antes da primeira API

1. Definir `Allocator` como contrato (falha, alinhamento, ownership, dupla liberação).
2. Definir a representação de `str` e de slices `[]T` (hoje `str` é `const char *`
   terminado em NUL e slices não existem).
3. Decidir como módulos são resolvidos e compilados (um arquivo por módulo? um
   manifesto `kyn.toml`? ordem de compilação?).
4. Definir o modelo de erros (`Result<T, E>` ou outro) antes de qualquer API que
   possa falhar.
5. Cada API entra com teste em `tests/cases/` e diagnóstico esperado em
   `tests/diagnostics/`.

## Onde estavam os rascunhos

Os rascunhos anteriores de `std/core` e `std/os` (Zig e `.kyn`) foram movidos para
[`../experiments/stdlib-sketch/`](../experiments/stdlib-sketch/) porque simulavam
comportamento em vez de implementá-lo.
