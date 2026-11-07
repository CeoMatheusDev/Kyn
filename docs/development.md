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
| `zig build e2e` | Compila fixtures, monta com `as`, liga com `ld` e confere códigos de saída e o texto impresso (`// expect-stdout:`). |
| `zig build validate-ir` | Valida o LLVM IR com `llvm-as`/`clang`; sem LLVM, avisa e ignora. |
| `zig build validate-ir-strict` | Igual ao anterior, mas falha se não houver LLVM (usado no CI). |
| `zig build run -- <args>` | Executa o `kync` recém-compilado com os argumentos informados. |

## CLI `kync`

```text
kync <comando> [opções] <arquivo.kyn>      # carrega o arquivo e seus imports

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

Importações: `import "caminho.kyn";` aparece antes das funções e o caminho é
resolvido em relação ao diretório do arquivo importador. Cada arquivo é lido uma
única vez (importações em diamante são mescladas), ciclos e arquivos ausentes
viram diagnóstico (código `1`) e os diagnósticos citam o arquivo de origem.

Exemplos:

```sh
zig-out/bin/kync check tests/e2e/modules/import_nested/main.kyn
zig-out/bin/kync check tests/e2e/positive/fib.kyn
zig-out/bin/kync emit --llvm tests/e2e/positive/fib.kyn -o /tmp/fib.ll
zig-out/bin/kync emit --asm  tests/e2e/positive/fib.kyn -o /tmp/fib.s
as /tmp/fib.s -o /tmp/fib.o && ld /tmp/fib.o -o /tmp/fib && /tmp/fib; echo $?

# saída de texto: `print` escreve a string e a quebra de linha
zig-out/bin/kync emit --asm tests/e2e/positive/print_basic.kyn -o /tmp/p.s
as /tmp/p.s -o /tmp/p.o && ld /tmp/p.o -o /tmp/p && /tmp/p       # kyn / bootstrap

# valores calculados: `print_i32` formata em decimal (com sinal)
zig-out/bin/kync emit --asm tests/e2e/positive/print_int_extremos.kyn -o /tmp/n.s
as /tmp/n.s -o /tmp/n.o && ld /tmp/n.o -o /tmp/n && /tmp/n       # 2147483647 / -2147483648 / 214748364
```

## Validação

O projeto só declara uma etapa concluída quando existe teste executável:

1. **Testes unitários** (`zig build test`): lexer, spans, diagnósticos, AST,
   parser, semântica, backends e driver, além dos testes da std experimental.
2. **Ponta a ponta** (`zig build e2e`): cada fixture positiva vira binário
   nativo; o código de saída é comparado com `// expect-exit: N` e o stdout com
   as linhas `// expect-stdout: ...` (na ordem, uma diretiva por linha — é assim
   que as fixtures de `str`/`print`/`print_i32` são validadas). O mesmo vale
   para programas
   multi-arquivo em `tests/e2e/modules/<caso>/main.kyn`; as
   fixtures de `tests/integration/case_N.kyn` devem terminar com código `N`;
   cada fixture negativa deve falhar com código `1` e mensagem `erro:`; em
   `tests/e2e/modules_negative/<caso>/` o arquivo opcional `expect-error.txt`
   exige um trecho específico na mensagem (ciclo, arquivo ausente, símbolo
   duplicado).

3. **LLVM IR** (`zig build validate-ir-strict`): roda `llvm-as` (ou `clang`)
   sobre o IR de todas as fixtures suportadas, incluindo os programas
   multi-arquivo e as fixtures de `struct`/`print`/`print_i32`/`str` por valor (79 módulos).
   Não há LLVM instalado no ambiente
   de desenvolvimento padrão, então localmente o passo `validate-ir` apenas
   avisa; o CI instala LLVM e usa a variante **estrita**, que falha se o
   verificador estiver ausente ou rejeitar qualquer módulo.

Os testes unitários do backend LLVM verificam apenas estrutura (blocos
terminados, tipos, instruções). A prova de que o IR é aceito por uma ferramenta
LLVM vem do CI, não dos testes locais.

## Integração contínua

`.github/workflows/ci.yml` roda em `push` (main e `arena/**`), `pull_request` e
manualmente. Em `ubuntu-24.04` o workflow:

1. instala `python3-venv` e `llvm`;
2. instala Zig 0.17.0 a partir do wheel oficial do PyPI (o mesmo caminho
   descrito acima) e o expõe no `PATH`;
3. executa `zig fmt --check build.zig src std`;
4. executa `zig build test` (193 testes) e `zig build e2e` (97 casos);
5. executa `zig build validate-ir-strict` (IR de 79 módulos aceito por
   `llvm-as`).

A ausência de LLVM no CI **falha** o build, por isso a validação do IR não pode
ser ignorada silenciosamente.

## Estrutura

```text
build.zig              # fonte única de build, testes e e2e
build.zig.zon          # versão mínima do Zig, versão do projeto
src/
  root.zig             # API pública (módulo "kyn")
  main.zig             # CLI kync
  driver.zig           # pipeline lexer -> parser -> sema -> backend + loader de imports
  span.zig             # offsets/linha/coluna
  diagnostics.zig      # diagnósticos e renderização
  lexer/lexer.zig      # tokens com spans
  ast/ast.zig          # AST (structs, funções, statements, expressões)
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
