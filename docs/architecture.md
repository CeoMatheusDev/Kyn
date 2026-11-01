# Arquitetura

## Visão geral

O repositório contém dois conjuntos de código relacionados, mas em estágios diferentes:

1. **Bootstrap em Zig:** implementação inicial dos componentes de frontend e backend em `src/`.
2. **Protótipos em Kyn:** arquivos experimentais em `src/kyn/` e `src/compiler/`, destinados a explorar a implementação do compilador na própria linguagem.

A presença dos dois conjuntos não significa que exista atualmente um pipeline self-hosted completo.

## Pipeline pretendido

```text
Código-fonte Kyn
      |
      v
    Lexer
      |
      v
    Parser
      |
      v
      AST
      |
      v
 Análise semântica
      |
      v
 Geração de código
      |
      v
   Backend / alvo
```

Este é o pipeline arquitetural pretendido. No código atual, cada estágio é parcial e ainda não está conectado em um fluxo completo de compilação.

## Componentes atuais

### Lexer — `src/lexer/`

O lexer Zig define tipos iniciais de token para identificadores, números, símbolos, comentários, espaços em branco e fim de arquivo. Os tokens mantêm slices da entrada original, evitando cópias desnecessárias de texto.

### AST — `src/ast/`

A AST usa nós alocados por um `std.mem.Allocator`, com tipo de nó, texto, linha e referências opcionais a filhos. A estrutura é inicial e ainda não representa toda a sintaxe da linguagem.

### Parser — `src/parser/`

O parser consome tokens e constrói nós básicos. A implementação atual não percorre nem constrói um programa completo; consulte [status](status.md) antes de assumir cobertura sintática.

### Análise semântica — `src/sema/`

Há uma tabela linear de símbolos e tipos iniciais (`i32`, `bool` e `unknown`). A verificação de programa ainda não percorre a AST integralmente. A estrutura deve evoluir antes de ser considerada um typechecker completo.

### Geração de código — `src/codegen/`

O emissor atual produz um fragmento fixo de LLVM IR para uma função `main` que retorna zero. Ele ainda não traduz expressões ou declarações da AST.

### Implementação em Kyn — `src/kyn/` e `src/compiler/`

Esses diretórios contêm arquivos iniciais e placeholders. Não constituem, no estado atual, um compilador self-hosted funcional.

## Biblioteca padrão

- `std/core/`: primitivas que se pretende manter independentes do sistema operacional.
- `std/os/`: interfaces que dependem de recursos do sistema operacional.

A separação é arquitetural. Os módulos existentes são experimentais e não oferecem, por si só, uma API estável.

## Diretrizes de engenharia

- Manter slices e referências à entrada quando a vida útil permitir, evitando alocações e cópias desnecessárias.
- Tornar explícita a origem e a duração dos allocators usados por AST, tabelas e buffers.
- Definir invariantes de parser e semântica antes de otimizar estruturas de dados.
- Separar interfaces independentes de plataforma das implementações específicas de SO.
- Manter fixtures da linguagem separados dos testes unitários do bootstrap.
- Não prometer determinismo, segurança de memória ou compatibilidade ABI sem testes e contratos verificáveis.

## Próximas decisões arquiteturais

1. Definir um `build.zig` como fonte única de verdade para build, testes e instalação.
2. Definir o contrato de tokens, spans e diagnósticos.
3. Estabelecer uma AST com ownership e ciclo de vida documentados.
4. Completar o parser e a travessia semântica.
5. Definir uma interface de backend antes de expandir a geração de código.
6. Estabelecer testes de integração que executem o compilador de ponta a ponta.
