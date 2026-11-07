# DEVELOPMENT_STATE — Kyn

**Mantido por:** agente de continuidade (Arena)
**Branch ativa:** `arena/23388a0b-kyn` (a partir de `eb8183f0283273554c797e5e977d258143aae77a` de `main`)
**Último commit:** `eb8183f docs: connect language proposal documents`
**Estado do working tree:** limpo (sem alterações não commitadas)

---

## Estado atual (confirmado em código e histórico)

O Kyn é um protótipo experimental de linguagem de sistemas e compilador bootstrap em Zig. Nenhuma funcionalidade está completa nem validada por build/testes neste ambiente (veja "Bloqueio" abaixo).

### Componentes e estado observado

| Componente | Arquivo | Estado | Observação |
|---|---|---|---|
| Ponto de entrada | `src/main.zig` | Placeholder | Apenas imprime versões/marcos; não compila fontes `.kyn`. |
| Lexer | `src/lexer/lexer.zig` | Parcial | Tokeniza identificador/número/símbolo/comentário/whitespace/EOF. Mantém slices da entrada. Possui 1 teste. |
| Parser | `src/parser/parser.zig` | Parcial | `parseProgram` encerra após o primeiro statement; `parseStatement` trata só `identifier` como `variable_decl`; `parseExpression` trata número e identificador. |
| AST | `src/ast/ast.zig` | Parcial | Poucos `NodeType` (program, variable_decl, binary_op, literal_int, identifier). Nós alocados via allocator; sem ownership documentado. |
| Semântica | `src/sema/sema.zig` | Parcial | `checkProgram` não percorre a árvore; tipo default `.i32`; tabela linear de símbolos; `lookup` sem escopos aninhados. Possui 1 teste. |
| Unsafe/Repr | `src/sema/unsafe.zig` | Placeholder | `UnsafeChecker`/`ReprChecker` quase vazios. Possui 1 teste. |
| Codegen | `src/codegen/codegen.zig` | Stub | `emitProgram` emite LLVM IR fixo (`main` retorna 0), ignora a AST. Possui 1 teste. |
| FFI | `src/ffi/ffi.zig` | Esboço | `extern "c"` printf; não integrado ao compilador. |
| Self-host (Kyn) | `src/kyn/*.kyn`, `src/compiler/*.kyn` | Placeholders | Todos contêm placeholders (`// placeholder`). Não constituem compilador funcional. |
| Biblioteca padrão | `std/core/*.zig|.kyn`, `std/os/*.zig` | Experimental | `core.zig` (stub), `arena.kyn`, `atomics.kyn`, `ringbuffer.kyn` usam sintaxe `.kyn` que o lexer atual **não** aceita (`impl`, `ref mut`, `Option`, etc.). |
| Build | (ausente) | Não padronizado | Não existe `build.zig` nem CLI unificada. |
| Testes Zig | `src/test_*.zig` | 5 arquivos | `test_core.zig` importa `kyn_core.zig` (inexistente) → **não compila**. Outros 4 compilam em tese, mas não podem ser executados sem Zig. |
| Fixtures `.kyn` | `tests/*.kyn` | Não executáveis | Sem runner integrado. Vários usam sintaxe não suportada pelo lexer/parser atual. |
| Documentação | `docs/*.md`, `*.ebnf` | Propostas | Não normativas; descrevem objetivos, não comportamento implementado. |

### Testes Zig existentes (não executáveis neste ambiente)

- `src/test_core.zig`: importa `kyn_core.zig`, que não existe no repositório → quebrado.
- `src/test_sema.zig`, `src/test_codegen.zig`, `test_unsafe.zig`: sintaticamente corretos, dependem de Zig 0.17.0.
- `src/test_std.zig`: importa `std/os/io.zig`, `thread.zig`, `net.zig` — arquivos existem, mas são stubs/plataforma.

### Git

- Branch atual: `arena/23388a0b-kyn` (ativa). `main` existe; `origin/main` sincronizado (working tree limpo).
- Nenhum commit pendente de integração; nenhuma alteração não commitada.

---

## Decisões técnicas registradas (confirmadas em código/docs)

1. **Toolchain declarada:** Zig 0.17.0 (README, docs/development.md, CHANGELOG). Nenhuma outra versão suportada documentada.
2. **Backend alvo:** LLVM IR direto emitido como texto (codegen emite strings fixas). Nenhuma interface de backend definida.
3. **Gerenciamento de memória:** allocator explícito passado para AST (`ast.Node.init(arena, ...)`), Sema e Codegen. Alocação via `arena.create` / `ArrayList.append` com `std.mem.Allocator`. Sem GC.
4. **Strings/spans:** `Token.text` e `Node.text` são slices `[]const u8` da entrada original (sem cópia), conforme diretriz de arquitetura.
5. **Erros:** Diferenciados por domínio (`AST.Error`, `Sema.Error`, `codegen.Error`, `UnsafeChecker.Error`). Uso de `!void` / unions de erro do Zig.
6. **Pipeline pretendido:** Lexer → Parser → AST → Sema → Codegen. Ainda não integrado.
7. **Separação std:** `kyn:core` (independente de SO) vs `kyn:std` (dependente de SO).
8. **Versão da linguagem:** não congelada; docs são propostas ilustrativas, não norma.

---

## Restrições técnicas identificadas

- **BLOQUEIO DE COMPILAÇÃO/VALIDAÇÃO:** Zig 0.17.0 não está instalado e não é obtível neste ambiente:
  - `ziglang.org` inalcançável (SSL_ERROR_SYSCALL, bloqueado pelo firewall).
  - Repositórios Debian (`deb.debian.org`) inalcançáveis (`apt` sem pacote `zig`).
  - GitHub alcançável, mas o `ziglang/zig` não possui tag/release `0.17.0` (última tag: `0.15.2`); releases não contêm binário 0.17.0.
  - Não há `clang`, `cmake` nem `ninja`; não é viável fazer bootstrap do Zig a partir do fonte (exigiria stage0 + C++ toolchain).
  - Consequência: **nenhum teste Zig pode ser compilado ou executado**; `build.zig` não pode ser validado.
- Sem `build.zig` nem CLI funcional.
- Pipeline frontend não conectado (lexer/parser/sema/codegen isolados).
- AST incompleta (sem expressões binárias completas, blocos, declarações `let`/`var` tipadas, struct/enum/impl).
- Semântica sem travessia da AST, sem sistema de tipos real, sem escopos aninhados.
- Codegen é stub fixo.
- Sem runner de fixtures `.kyn`; sem diagnósticos com span integrado.
- Os `.kyn` de `std/` e `tests/` usam sintaxe que o lexer atual não reconhece.

---

## Pendências (bugs e trabalho incompleto)

1. Obter toolchain Zig 0.17.0 para permitir compilação e validação.
2. Criar `build.zig` (build, testes, instalação) — Roadmap Fase 1.
3. Definir CLI `kync` e seus argumentos.
4. Completar parser (construir programa inteiro, blocos, `let`/`var`, expressões).
5. Completar AST (todos os nós da sintaxe proposta).
6. Completar semântica (travessia, tipos, escopos, mutabilidade).
7. Definir interface de backend e completar codegen a partir da AST.
8. Integrar pipeline ponta a ponta.
9. Criar runner de testes para fixtures `.kyn`.
10. Corrigir `src/test_core.zig` (importa `kyn_core.zig` inexistente).
11. Atualizar docs quando sintaxe/semântica/ABI mudarem.

---

## Próxima etapa (prioritária)

**Obter toolchain Zig 0.17.0 e validar o ambiente de build.**

- Arquivos/módulos envolvidos: nenhum ainda (pré-requisito de toolchain).
- Objetivo técnico: ter um `zig` funcional na versão declarada pelo projeto para compilar `src/main.zig` e executar `src/test_*.zig`.
- Dependências necessárias: acesso a `ziglang.org` (ou binário Zig 0.17.0 compatível com Debian 12 / glibc 2.36 / x86_64), ou alternativa aprovada.
- Critérios de conclusão: `zig version` retorna 0.17.0; `zig test src/test_sema.zig` (e demais que não dependam de arquivos ausentes) executam e passam.

**Após desbloquear a toolchain:** criar `build.zig` como fonte única de build/testes (Roadmap Fase 1), então completar parser → semântica → codegen de forma incremental, com teste para cada alteração.

---

## Histórico dos ciclos

| Ciclo | O que foi feito | Validado? |
|---|---|---|
| Atual (início) | Análise completa do repositório: estrutura, código-fonte, docs, testes, git, disponibilidade de toolchain. Confirmado que Zig 0.17.0 não está disponível neste ambiente (bloqueio de compilação/testes). | Não há build/testes possíveis até obter o Zig. |

---

**Próxima ação pendente:** resolver o bloqueio da toolchain Zig; somente então continuar o desenvolvimento incremental do compilador com validação obrigatória a cada etapa.
