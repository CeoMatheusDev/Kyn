# Versionamento do Kyn

Este documento define como o projeto identifica versões, registra mudanças e prepara releases. A política acompanha o estágio real do código: o Kyn é experimental e ainda não possui uma release estável verificável.

## 1. Esquema de versão

O projeto usa [Semantic Versioning 2.0.0](https://semver.org/lang/pt-BR/):

`MAJOR.MINOR.PATCH`

Enquanto a versão principal for `0`, a API, a sintaxe e a semântica podem mudar. O incremento segue estas regras:

- **PATCH:** correção compatível, regressão corrigida ou ajuste interno sem mudança intencional de comportamento público.
- **MINOR:** nova capacidade ou mudança incompatível durante a fase `0.y.z`; antes de `1.0.0`, MINOR é o eixo de evolução funcional.
- **MAJOR:** após `1.0.0`, mudança incompatível com o contrato público documentado.

Pré-lançamentos usam identificadores SemVer, por exemplo `0.2.0-alpha.1`, `0.2.0-beta.1` e `0.2.0-rc.1`. Não use `stable`, `1.0.0` ou equivalentes sem cumprir os critérios de estabilidade.

## 2. Versão atual do código

O arquivo `VERSION` contém a versão de desenvolvimento do repositório. Seu valor inicial é `0.1.0-dev`: um identificador de trabalho, **não** uma release publicada nem uma garantia de compatibilidade.

Quando houver releases reais:
- a versão de release deve ser idêntica ao nome da tag, sem o prefixo `v` no arquivo `VERSION`;
- tags Git seguem `vMAJOR.MINOR.PATCH` (ex.: `v0.2.0`);
- pré-lançamentos recebem tags como `v0.2.0-alpha.1`;
- uma tag publicada é imutável; correções geram uma nova versão.

A versão do compilador Zig usado para construir Kyn é uma dependência/toolchain e não deve ser confundida com a versão do próprio Kyn.

## 3. Changelog

`CHANGELOG.md` mantém as mudanças relevantes, organizadas em:
- `Unreleased`: alterações aceitas desde a última release;
- uma seção por versão efetivamente publicada, com data e categorias `Added`, `Changed`, `Fixed`, `Removed` e `Security`, quando aplicáveis.

Registre mudanças observáveis e verificáveis. Não registre itens de roadmap como concluídos, não invente versões retroativas e não use o changelog como substituto de testes ou evidência de implementação.

Ao preparar uma release:
1. confirme o commit que será lançado;
2. revise testes, documentação e compatibilidade;
3. mova as entradas de `Unreleased` para a versão correspondente;
4. atualize `VERSION`;
5. crie a tag anotada `vX.Y.Z`;
6. publique notas que descrevam limitações conhecidas e artefatos realmente gerados.

## 4. Branches

Fluxo recomendado, sem GitFlow completo:

- `main`: linha principal integrada; deve permanecer revisável e receber mudanças por PR.
- `feat/<assunto>`: novas funcionalidades.
- `fix/<assunto>`: correções.
- `docs/<assunto>`: documentação.
- `chore/<assunto>`: manutenção, build e infraestrutura.
- `release/<versão>`: opcional, apenas quando existir processo de estabilização de release.

Branches de trabalho devem partir de `main` e retornar por pull request. Evite manter `develop` como segunda linha permanente: isso duplica o ponto de integração e cria ambiguidade sobre qual branch representa o estado oficial. A alteração da branch padrão do GitHub para `main` é uma configuração administrativa e deve ser feita nas configurações do repositório.

## 5. Commits e pull requests

Use mensagens no formato Conventional Commits:

- `feat(parser): support grouped expressions`
- `fix(lexer): preserve token start line`
- `docs: define release policy`
- `test(sema): cover invalid declarations`
- `chore(build): add reproducible test entry point`

Tipos comuns: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `build`, `ci` e `chore`. O corpo deve explicar motivação e impacto quando não forem óbvios. Indique breaking changes com `!` e uma seção `BREAKING CHANGE:` no rodapé.

Um PR deve descrever escopo, testes executados (ou explicitamente não executados), impacto em compatibilidade e documentação atualizada. Não use o tipo do commit como mecanismo automático para publicar versões neste estágio.

## 6. Critérios para a primeira versão estável

Não publicar `1.0.0` antes de:
- build reproduzível em ambiente limpo;
- CLI e pipeline de compilação integrados;
- especificação de sintaxe e semântica suficientemente definida;
- contratos públicos de memória, ownership, unsafe e FFI documentados;
- testes unitários, integração e regressão executados em CI;
- matriz de plataformas e targets suportados definida;
- processo de release reproduzível e artefatos verificáveis.

Até lá, use versões `0.y.z` e deixe explícito que o projeto é experimental.
