# Contribuindo com o Kyn

Obrigado pelo interesse no Kyn. Como o compilador e a linguagem ainda são experimentais, contribuições pequenas, testáveis e documentadas são especialmente importantes.

## Antes de começar

- Leia [README.md](README.md), [docs/architecture.md](docs/architecture.md) e [docs/status.md](docs/status.md).
- Use a versão de Zig declarada pelo projeto (atualmente 0.17.0) e informe a versão efetivamente utilizada.
- Verifique se a funcionalidade já existe ou está registrada no roadmap.

## Pull requests

Cada PR deve:

1. Ter um escopo claro e limitado.
2. Explicar o problema e a solução.
3. Incluir testes para o comportamento alterado, quando aplicável.
4. Informar os comandos executados e seus resultados.
5. Atualizar a documentação quando houver mudança de sintaxe, semântica, API, memória, FFI ou fluxo de build.
6. Distinguir claramente código funcional, protótipo e placeholder.

## Diretrizes técnicas

- Respeite a separação pretendida entre `kyn:core` e recursos dependentes do SO.
- Evite cópias e alocações desnecessárias; documente ownership e lifetime.
- Não introduza garantias de segurança ou performance sem evidência e testes.
- Não adicione dependências sem justificar o custo, o impacto no build e a alternativa considerada.
- Preserve compatibilidade ou documente explicitamente mudanças incompatíveis.

## Testes

Execute `zig build test` para os testes unitários. Para mudanças em lexer, parser, semântica ou backends, rode também `zig build e2e`, que compila fixtures `.kyn` do subconjunto suportado, monta com `as`, liga com `ld` e confere o código de saída de cada programa. Casos ainda não implementados (por exemplo `impl`, `Result<T, E>`, `unsafe`) permanecem como documentação e não devem ser apresentados como suportados.

## Commits

Prefira commits pequenos, com mensagens objetivas, por exemplo:

- `feat(parser): parse grouped expressions`
- `fix(lexer): preserve line positions`
- `test(sema): cover duplicate declarations`
- `docs: clarify memory model status`

## Relato de bugs

Inclua versão do Zig, sistema operacional, passos para reproduzir, entrada mínima e saída observada. Remova dados sensíveis antes de compartilhar logs.
