# Experiments

Rascunhos históricos preservados como referência de design. **Nada aqui é compilado,
testado ou aceito pelo compilador atual** — nem pelo `zig build`, nem pelo próprio
`kyn`.

## `self-host-sketch/`

Primeiras tentativas de escrever o compilador em Kyn (`main.kyn`, `lexer.kyn`,
`parser.kyn`, `sema.kyn`, `codegen.kyn`, `ast.kyn`) e módulos de apoio
(`diagnostics.kyn`, `span.kyn`, `modules.kyn`, `mutability.kyn`, `regopt.kyn`,
`result.kyn`, `ffi.kyn`).

Por que não são aceitos hoje: usam `pub fn` com corpo, generics (`Vec<Token>`),
slices `[]u8`, `Result<T, E>` e declarações que o subconjunto implementado
(`docs/syntax.ebnf`) não cobre. São rascunhos de intenção, não implementações.

## `stdlib-sketch/`

Rascunhos da biblioteca padrão:

- `core/*.kyn` — `Arena`, `RingBuffer`, primitivas atômicas.
- `core/core.zig`, `os/*.zig` — stubs em Zig cujo comportamento era simulado
  (`File.open` devolvia um `File{}` vazio, `Socket.connect` não abria socket,
  `Thread.spawn` não criava thread).

Nenhum desses símbolos é fornecido pelo compilador: `import` valida o nome do módulo
e nada mais. Consulte [`../std/README.md`](../std/README.md) para o plano da
biblioteca padrão real.

## Regra para este diretório

Arquivos entram aqui quando deixam de fazer parte do build mas ainda têm valor como
registro. Nada neste diretório pode ser citado como funcionalidade do projeto.
