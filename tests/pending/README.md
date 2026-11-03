# Fixtures pendentes

Estas fixtures usam recursos que o compilador **ainda não implementa**. Elas ficam
fora da suíte (`zig build integration` não as lê) para que o resultado da suíte
signifique "tudo que está lá passa".

Quando um recurso for implementado, mova a fixture correspondente para
`tests/cases/` (com `.expect`) ou `tests/diagnostics/` e atualize esta tabela.

| Fixture | Recurso que falta |
| --- | --- |
| `arena_basic.kyn` | biblioteca padrão (`Arena`), slices `[]u8`, sintaxe `ref mut self` |
| `atomics_basic.kyn` | biblioteca padrão (`atomic_load`, `atomic_store`, `memory_barrier`) |
| `core_basic.kyn` | `unsafe { … }` em nível superior, bindings de nível superior, atributo `@align(8)` (a forma suportada é `#[align(8)]`) |
| `ffi_basic.kyn` | assinatura `extern` sem `->` e chamada `extern` fora de `unsafe` (hoje: E0001 e E0015 — veja `tests/cases/29_ffi_printf.kyn` e `tests/diagnostics/d22_extern_without_unsafe.kyn` para as formas suportadas) |
| `fuzzer.kyn` | `pub fn` com corpo, slices `[]u8` como parâmetro/retorno |
| `harness.kyn` | `pub fn` com corpo, slices `[]u8`, harness executável de fuzzing |
| `result_basic.kyn` | generics `Result<T, E>`, construtores `Ok`/`Err`, operador `?` |
| `ringbuffer_basic.kyn` | slices, `Option<T>`, `Some`/`None`, indexação, biblioteca padrão |
| `std_basic.kyn` | símbolos reais de `kyn:std` (`io::open`, `thread::spawn`, `net::connect`) e closures `|| {}` |
| `unsafe_basic.kyn` | `unsafe { … }` em nível superior (bloco `unsafe` só é aceito como statement) |

## Convenção ao mover uma fixture para cá

1. Mantenha o nome original quando possível (facilita o histórico).
2. Adicione uma linha nesta tabela com o recurso que falta.
3. Se parte do comportamento já for suportado, crie **também** um caso ativo em
   `tests/cases/` cobrindo a parte que funciona.
