# Desenvolvimento

## Requisitos

- Zig 0.17.0 é a versão declarada pelos arquivos atuais do projeto.
- Git.
- Um ambiente compatível com a versão de Zig utilizada.

Confirme a versão instalada:

```sh
zig version
```

## Clonar

```sh
git clone https://github.com/CeoMatheusDev/Kyn.git
cd Kyn
```

## Testes Zig disponíveis

Os testes unitários estão atualmente distribuídos em arquivos `src/test_*.zig`. Execute-os individualmente:

```sh
zig test src/test_core.zig
zig test src/test_sema.zig
zig test src/test_codegen.zig
zig test src/test_std.zig
zig test src/test_unsafe.zig
```

A execução de cada comando deve ser registrada separadamente. Não existe ainda um alvo agregado que garanta que todos os testes foram executados.

## Fixtures da linguagem

Os arquivos `.kyn` em `tests/` documentam casos de sintaxe, semântica, módulos, FFI, memória e diagnósticos. Como o frontend ainda não está integrado a um runner, não existe um comando oficial para executar toda essa suíte.

Não interprete a quantidade de fixtures como cobertura de testes executados.

## Build

O repositório ainda não possui `build.zig`, configuração de instalação ou definição padronizada de artefatos. O comando de build e a CLI precisam ser definidos em uma etapa própria.

## Fluxo recomendado

1. Crie uma branch de trabalho.
2. Faça uma alteração pequena e focada.
3. Adicione ou atualize um teste que cubra o comportamento.
4. Execute os testes Zig relacionados.
5. Atualize a documentação se alterar sintaxe, semântica, memória, ABI ou comandos.
6. Informe no pull request o que foi executado e o que não foi validado.

## Convenções de implementação

- Evite alocações quando slices da entrada ou buffers reutilizáveis forem suficientes.
- Documente quem possui cada alocação e quando ela é liberada.
- Prefira spans (offset inicial/final) a cópias de strings para diagnósticos.
- Diferencie erros de sintaxe, erros semânticos e falhas internas.
- Não introduza APIs de biblioteca padrão sem definir contratos e testes.
- Não marque recursos como concluídos apenas porque existe um arquivo com o nome correspondente.

## Limitações conhecidas

- Não há build unificado.
- O pipeline completo do compilador não está conectado.
- As fixtures `.kyn` não possuem runner integrado.
- A implementação self-hosted está incompleta.
