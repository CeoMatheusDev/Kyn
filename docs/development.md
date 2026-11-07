# Desenvolvimento

## Requisitos

- **Zig 0.17.0** (declarado em `build.zig.zon`; o campo `minimum_zig_version` é
  verificado pelo próprio Zig).
- Git.
- Para a suíte de ponta a ponta nativa: `bash`, GNU `as` e GNU `ld` em Linux
  x86-64. Sem essas ferramentas, `tools/e2e.sh` informa e é ignorado; os testes
  unitários continuam sendo a validação base.

Confirme a versão instalada:

```sh
zig version   # esperado: 0.17.0
```

Quando não houver Zig instalado no sistema, uma alternativa é o pacote PyPI
`ziglang`, que distribui binários oficiais (a versão `0.17.0.post0` corresponde
ao mesmo compilador 0.17.0):

```sh
python3 -m pip download ziglang==0.17.0.post0 --no-deps -d /tmp/zig
python3 -m zipfile -e /tmp/zig/*.whl /caminho/instalacao
/caminho/instalacao/ziglang/zig version
```

## Clonar e compilar

```sh
git clone https://github.com/CeoMatheusDev/Kyn.git
cd Kyn

zig build            # gera zig-out/bin/kync
zig build run -- --help
```

## Comandos de build

| Comando | Efeito |
| --- | --- |
| `zig build` | Compila e instala `zig-out/bin/kync`. |
| `zig build test` | Executa os testes unitários do compilador e da std experimental. |
| `zig build e2e` | Compila fixtures, monta com `as`, liga com `ld` e confere códigos de saída. |
| `zig build run -- <args>` | Executa o `kync` recém-compilado com os argumentos informados. |

## CLI `kync`

```text
kync <comando> [opções] <arquivo.kyn>

check <arquivo>   valida sintaxe e semântica, sem gerar código
emit <arquivo>    emite o artefato do backend selecionado

--llvm            LLVM IR textual (padrão)
--asm             assembly x86-64 (Linux, System V)
-o <arquivo>      grava a saída em arquivo (padrão: stdout)
--lib             não exige 'fn main' (unidade de biblioteca)
-h, --help        ajuda
-V, --version     versão e backends
```

Códigos de saída (contrato observado nos testes de fumaça manuais):

| Código | Significado |
| --- | --- |
| `0` | sucesso |
| `1` | erro de sintaxe ou semântica (diagnósticos em stderr) |
| `2` | uso inválido (comando/opção/argumento) |
| `3` | falha de E/S (ler fonte ou gravar artefato) |

Exemplos:

```sh
zig-out/bin/kync check tests/e2e/positive/fib.kyn
zig-out/bin/kync emit --llvm tests/e2e/positive/fib.kyn -o /tmp/fib.ll
zig-out/bin/kync emit --asm  tests/e2e/positive/fib.kyn -o /tmp/fib.s
as /tmp/fib.s -o /tmp/fib.o && ld /tmp/fib.o -o /tmp/fib && /tmp/fib; echo $?
```

## Validação

O projeto só declara uma etapa concluída quando existe teste executável:

1. **Testes unitários** (`zig build test`): lexer, spans, diagnósticos, AST,
   parser, semântica, backends e driver, além dos testes da std experimental.
2. **Ponta a ponta** (`zig build e2e`): cada fixture positiva vira binário
   nativo e o código de saída é comparado com `// expect-exit: N`; as fixtures
   de `tests/integration/case_N.kyn` devem terminar com código `N`; cada fixture
   negativa deve falhar com código `1` e mensagem `erro:`.

O backend LLVM IR **não** é validado por ferramenta LLVM (`llc`/`clang`) neste
ambiente: os testes verificam estrutura (blocos terminados, instruções, tipos).
Não trate o IR emitido como comprovado por um montador LLVM.

## Estrutura

```text
build.zig              # fonte única de build, testes e e2e
build.zig.zon          # versão mínima do Zig, versão do projeto
src/
  root.zig             # API pública (módulo "kyn")
  main.zig             # CLI kync
  driver.zig           # pipeline lexer -> parser -> sema -> backend
  span.zig             # offsets/linha/coluna
  diagnostics.zig      # diagnósticos e renderização
  lexer/lexer.zig      # tokens com spans
  ast/ast.zig          # AST (funções, statements, expressões)
  parser/parser.zig    # parser completo do subconjunto
  sema/sema.zig        # resolução de nomes, tipos, mutabilidade, slots
  sema/unsafe.zig      # política de unsafe/repr(C) (ainda não conectada)
  codegen/codegen.zig  # interface de backend
  codegen/llvm.zig     # backend LLVM IR textual
  codegen/x86_64.zig   # backend nativo x86-64 (montável/executável)
  ffi/ffi.zig          # experimento de FFI C
std/                   # biblioteca padrão experimental (kyn:core, kyn:std)
tests/                 # fixtures .kyn (integração e e2e)
tools/e2e.sh           # validação de ponta a ponta
```

## Fluxo recomendado

1. Crie uma branch de trabalho.
2. Faça uma alteração pequena e focada.
3. Adicione ou atualize testes que cubram o comportamento.
4. Execute `zig build test` e, se mexeu em backend/semântica,
   `zig build e2e`.
5. Atualize a documentação afetada (`docs/status.md`, `docs/syntax.ebnf`,
   `CHANGELOG.md`, `DEVELOPMENT_STATE.md`).
6. No pull request, informe o que foi executado e o que não foi validado.

## Convenções de implementação

- Prefira spans e slices da entrada a cópias de strings.
- Documente quem possui cada alocação; a AST, a tabela de símbolos, os
  diagnósticos e a saída do backend vivem na arena de uma compilação
  (`driver.compile`), liberada por `Result.deinit`.
- Separe erros de sintaxe, erros semânticos e falhas internas de backend
  (`codegen.Error`).
- Não introduza APIs de biblioteca padrão sem contrato e teste.
- Não marque recursos como concluídos apenas porque existe um arquivo com o
  nome correspondente.
