# Tutorial do Kyn

Este tutorial ensina a escrever, compilar e executar programas em **Kyn** com o
compilador atual (`kync`). Tudo aqui foi executado com o próprio compilador: os
exemplos são programas completos, verificados pela suíte de testes do
repositório.

> **Estado da linguagem:** o Kyn está em desenvolvimento ativo (`0.3.x`). O
> subconjunto descrito neste tutorial é o que o compilador **aceita e executa
> hoje**. Recursos planejados (ponteiros, slices, `enum`, `defer`, generics,
> FFI, …) aparecem na última seção com o estado real de cada um.

## Índice

1. [Filosofia em uma página](#1-filosofia-em-uma-página)
2. [Preparando o ambiente](#2-preparando-o-ambiente)
3. [Primeiro programa](#3-primeiro-programa)
4. [A CLI `kync`](#4-a-cli-kync)
5. [Tipos](#5-tipos)
6. [Variáveis e mutabilidade](#6-variáveis-e-mutabilidade)
7. [Operadores](#7-operadores)
8. [Controle de fluxo](#8-controle-de-fluxo)
9. [Funções](#9-funções)
10. [Structs](#10-structs)
11. [Texto e saída](#11-texto-e-saída)
12. [Módulos](#12-módulos)
13. [Diagnósticos](#13-diagnósticos)
14. [Gerando binários e IR](#14-gerando-binários-e-ir)
15. [Testando seu código](#15-testando-seu-código)
16. [Erros comuns](#16-erros-comuns)
17. [Limites atuais](#17-limites-atuais)
18. [Para onde o Kyn vai](#18-para-onde-o-kyn-vai)

---

## 1. Filosofia em uma página

Kyn é uma linguagem de sistemas: compilada, tipada estaticamente, sem runtime
obrigatório, sem coletor de lixo e sem custos ocultos. Três regras guiam tudo:

- **Controle explícito.** O que acontece com a memória e com o hardware deve
  estar escrito no código.
- **Nenhuma conversão silenciosa.** Tipos não mudam sozinhos; o compilador
  recusa o que não é comprovadamente válido.
- **Erro detectável é erro impeditivo.** Se o compilador consegue provar que o
  programa está errado, ele não gera executável — e explica o motivo.

Você vai encontrar essas regras em cada capítulo: `let` versus `var`, ausência
de coerção entre `i32`/`bool`/`str`, mensagens que dizem o tipo esperado e o
encontrado, e limites de backend documentados em vez de comportamento
indefinido.

---

## 2. Preparando o ambiente

O compilador é escrito em Zig e usa Zig `0.17.0` (fixado em `build.zig.zon`).

```sh
# 1. Toolchain (quando não houver instalação oficial do Zig disponível)
python3 -m pip download ziglang==0.17.0.post0 --no-deps -d /tmp/zigwheel
mkdir -p ~/.local/zigpkg && cd ~/.local/zigpkg
python3 -m zipfile -e /tmp/zigwheel/*.whl .
chmod +x ziglang/zig
mkdir -p ~/.local/bin && ln -sf ~/.local/zigpkg/ziglang/zig ~/.local/bin/zig

# 2. Compilar o kync
cd Kyn
zig build                 # gera zig-out/bin/kync
./zig-out/bin/kync --version

# 3. Suítes de validação
zig build test            # testes unitários (lexer, parser, sema, backends)
zig build e2e             # compila, monta, liga e executa as fixtures
```

Requisitos do backend nativo: `as` e `ld` (binutils) em Linux x86-64. Para
validar o IR do LLVM é preciso `llvm-as` ou `clang` (`zig build validate-ir`).

---

## 3. Primeiro programa

```kyn
fn main() -> i32 {
    return 42;
}
```

- Todo programa começa por `fn main() -> i32` (ou `-> void`).
- `return` devolve o valor; o valor de retorno de `main` vira o **código de
  saída** do processo (aqui, 42).
- Não há ponto e vírgula faltando: toda declaração e todo `return` terminam
  com `;`.

Escreva o arquivo como `ola.kyn` e execute:

```sh
zig-out/bin/kync check ola.kyn                  # só verifica
zig-out/bin/kync emit --asm ola.kyn -o ola.s    # assembly x86-64
as ola.s -o ola.o && ld ola.o -o ola
./ola; echo $?                                  # imprime 42
```

`main` também pode não devolver nada:

```kyn
fn main() -> void {
    return;
}
```

---

## 4. A CLI `kync`

| Comando | O que faz |
|---|---|
| `kync check <arquivo.kyn>` | Analisa o programa inteiro e relata diagnósticos; não escreve saída. |
| `kync emit --asm <arquivo.kyn> -o saida.s` | Emite assembly x86-64 (Linux, System V, sem libc). |
| `kync emit --llvm <arquivo.kyn> -o saida.ll` | Emite LLVM IR textual. |
| `kync emit --lib <...>` | Emite o módulo da biblioteca experimental. |
| `kync --version` | Mostra versão e backends disponíveis. |

Códigos de saída da CLI: `0` sucesso, `1` erro de compilação, `2` uso inválido,
`3` falha de E/S.

`check` e `emit` compilam o **grafo de imports** a partir do arquivo indicado,
então você aponta para o `main.kyn` do programa.

---

## 5. Tipos

| Tipo | Representação | Observações |
|---|---|---|
| `i32` | inteiro com sinal, 32 bits | único tipo inteiro disponível hoje |
| `bool` | booleano | resultados de comparações e `&&`/`\|\|` |
| `str` | fatia estática: ponteiro + tamanho | só texto literal; sem concatenação |
| `void` | ausência de valor | retorno de `print`, `print_i32` e de funções sem valor |
| `struct` | campos escalares em ordem de declaração | nominal: cada `struct` é um tipo distinto |

Os tipos são nominais e **não há promoção implícita**: `i32` não vira `bool`,
`bool` não vira `i32`, `str` não vira `i32`. Toda conversão precisaria ser
explícita — quando existirem operadores de conversão, eles serão explícitos por
construção.

Literais:

```kyn
fn main() -> i32 {
    let inteiro = 42;
    let negativo = 0 - 7;   // não há literal negativo: use a expressão
    let sim = 1 < 2;        // bool
    let texto = "kyn";
    let vazio: str = "";
    return inteiro + negativo + 49;
}
```

Overflow de literal é diagnosticado na compilação (`i32` cobre
`-2147483648..2147483647`).

---

## 6. Variáveis e mutabilidade

```kyn
fn main() -> i32 {
    let fixo = 10;         // imutável (padrão)
    var mutavel: i32 = 1;  // mutável, com anotação de tipo
    mutavel = mutavel + 1; // permitido
    // fixo = 20;          // erro: 'fixo' é imutável
    return fixo + mutavel;
}
```

Regras:

- `let` cria uma variável imutável; `var` cria uma mutável.
- O inicializador é **obrigatório** — não existe variável sem valor definido.
- A anotação de tipo é opcional quando o inicializador deixa o tipo
  inequívoco: `let n = 42;` é `i32`.
- Atribuir a um `let` é erro (`immutable_assignment`), e o mesmo vale para
  campos de struct (`p.x = 1;` exige `var p`).
- `void` não é armazenável: `let x = print("a");` é diagnosticado.

---

## 7. Operadores

```kyn
fn main() -> i32 {
    let a = 7;
    let b = 3;
    let soma = a + b;          // 10
    let dif = a - b;           // 4
    let prod = a * b;          // 21
    let quoc = a / b;          // 2   (divisão inteira, trunca em direção a zero)
    let resto = a % b;         // 1
    let menor = a < b;         // bool
    let igual = a == a;        // bool
    let nao = !menor;          // bool
    let negado = 0 - a;        // -7
    let logico = menor || b < a;
    return soma * 2 - dif + prod + quoc + resto;
}
```

Precedência (do mais forte ao mais fraco): unários `-`/`!`, `*`/`/`/`%`,
`+`/`-`, comparações (`<`, `<=`, `>`, `>=`), igualdade (`==`, `!=`), `&&`, `||`.
Use parênteses quando a intenção não for óbvia.

`&&` e `||` têm **curto-circuito**: o lado direito só é avaliado quando o
resultado não está decidido.

Divisão por zero é um caso a tratar no código: não há exceção nem `panic`
automático — o programa é um binário que faz a operação que você pediu.

---

## 8. Controle de fluxo

```kyn
fn main() -> i32 {
    var total: i32 = 0;
    var i: i32 = 0;
    while i < 5 {
        if i % 2 == 0 {
            total = total + i;
        } else if i == 3 {
            total = total + 100;
        } else {
            total = total - 1;
        }
        i = i + 1;
    }
    return total; // 0 - 1 + 2 + 100 + 4 = 105
}
```

- Condições exigem `bool` (um `i32` em `if` é erro, não "verdadeiro se não
  zero").
- Blocos são delimitados por `{ }`; não há `for`.
- `if`/`while` são instruções, não expressões: para produzir valor use `return`
  ou variável.
- `else if` encadeia sem aninhamento extra de chaves.

---

## 9. Funções

```kyn
fn dobro(n: i32) -> i32 {
    return n + n;
}

fn soma(a: i32, b: i32) -> i32 {
    return a + b;
}

fn sem_retorno(x: i32) -> void {
    print_i32(x);
    return;
}

fn main() -> i32 {
    sem_retorno(soma(dobro(2), dobro(3)));
    return dobro(soma(1, 2));
}
```

- A assinatura declara os tipos dos parâmetros e do retorno; `-> void` pode ser
  omitido.
- Funções podem ser declaradas em qualquer ordem e podem ser recursivas.
- O compilador exige que **todo caminho** de uma função não-`void` termine com
  `return` com valor (`alwaysReturns` sobre a estrutura do bloco).
- Chamadas aninham livremente, desde que o limite de registradores seja
  respeitado: **6 registradores por chamada**, contando cada campo de struct
  como um e cada `str` como dois.

```kyn
fn fibonacci(n: i32) -> i32 {
    if n < 2 {
        return n;
    }
    return fibonacci(n - 1) + fibonacci(n - 2);
}

fn main() -> i32 {
    return fibonacci(10); // 55
}
```

---

## 10. Structs

Structs agrupam campos escalares e têm **identidade nominal**: dois structs com
os mesmos campos continuam sendo tipos diferentes.

```kyn
struct Ponto {
    x: i32,
    y: i32,
}

fn main() -> i32 {
    var p: Ponto = Ponto { x: 3, y: 4 };
    p.x = p.x + 1;        // atribuição de campo exige 'var'
    let copia: Ponto = p; // cópia campo a campo
    return copia.x + copia.y; // 8
}
```

- O literal precisa inicializar **todos** os campos, uma única vez cada.
- Acesso a campo inexistente é erro (`undefined_field`).
- Struct com campo `str`, com campo de struct (aninhado) ou vazio ainda não é
  suportado — os três casos são diagnosticados.

### Struct por valor em funções

Desde `0.3.7-alpha.1`, structs atravessam chamadas por valor, em parâmetros e
em retornos:

```kyn
struct Ponto {
    x: i32,
    y: i32,
}

fn origem() -> Ponto {
    return Ponto { x: 3, y: 4 };
}

fn desloca(p: Ponto, d: i32) -> Ponto {
    return Ponto { x: p.x + d, y: p.y + d };
}

fn soma(p: Ponto) -> i32 {
    return p.x + p.y;
}

fn main() -> i32 {
    let a = origem();          // retorno de struct
    let b = desloca(a, 10);    // parâmetro e retorno
    print_i32(soma(origem())); // struct devolvido direto como argumento
    return soma(b);            // soma((13, 14)) = 27
}
```

Contrato de chamada (o mesmo nos dois backends):

- Cada campo escalar ocupa **um registrador**, na ordem de declaração.
- Structs voltam com um registrador por campo (`%eax`, `%edx`, `%ecx`, `%r8d`,
  `%r9d`, `%r10d` no x86-64; agregado `{ i32, … }` no IR do LLVM).
- O limite de 6 registradores vale para parâmetros/argumentos e para o retorno
  de struct (portanto: até 6 campos).
- `str` conta dois registradores; um struct com quatro campos mais três
  `i32` já excede o limite e é diagnosticado na declaração **e** na chamada.

---

## 11. Texto e saída

`str` é uma **fatia estática**: ponteiro para bytes constantes + tamanho. Hoje
só existem literais — não há concatenação, comparação por conteúdo nem
interpolação.

```kyn
fn main() -> i32 {
    print("kyn");        // texto + quebra de linha
    print("");           // string vazia é válida
    print_i32(42);       // número + quebra de linha
    print_i32(0 - 7);    // -7
    print_i32(2147483647);
    return 0;
}
```

`print` e `print_i32` são **funções embutidas**, não palavras-chave:

- `print(expr)` exige exatamente um `str`; devolve `void`; escreve o texto e a
  quebra de linha.
- `print_i32(expr)` exige exatamente um `i32`; devolve `void`; escreve o valor
  em decimal (inclusive `-2147483648`).
- Os nomes são reservados: declarar `fn print(...)` é erro.
- O resultado é `void`, logo não pode ser atribuído a variável.

`str` também viaja entre funções por valor:

```kyn
fn titulo() -> str {
    return "kyn";
}

fn eco(s: str) -> str {
    return s;
}

fn main() -> i32 {
    let t = titulo();
    print(t);
    print(eco("bootstrap"));
    print(eco(titulo()));
    return 0;
}
```

No x86-64, `str` viaja como par de registradores (`%rdi`/`%rsi`, `%rdx`/`%rcx`,
`%r8`/`%r9`) e volta em `%rax` (ponteiro) + `%rdx` (tamanho). Como cada `str`
consome dois registradores, no máximo três cabem numa chamada.

---

## 12. Módulos

`import "caminho.kyn";` vem antes de qualquer declaração e carrega outro
arquivo, resolvido **relativamente ao arquivo importador**:

```kyn
import "ponto.kyn";

fn main() -> i32 {
    let p = origem();
    return p.x + p.y;
}
```

Em `ponto.kyn` (arquivo de biblioteca, sem `main`):

```kyn
struct Ponto {
    x: i32,
    y: i32,
}

fn origem() -> Ponto {
    return Ponto { x: 6, y: 7 };
}
```

Regras atuais:

- Cada arquivo é carregado **uma vez** (deduplicação por caminho normalizado),
  mesmo em importações em diamante.
- Os símbolos são achatados em um escopo único: nomes de função e de struct
  precisam ser únicos no programa inteiro.
- Ciclos, arquivos ausentes e símbolos duplicados são diagnosticados com o
  arquivo de origem correto.

---

## 13. Diagnósticos

O compilador relata **todos** os erros independentes de uma execução, com
arquivo, linha, coluna, a linha do código e um marcador:

```text
$ kync check exemplo.kyn
exemplo.kyn:3:18: erro: inicializador de 'x' tem tipo 'str', mas a anotação é 'i32'
    let x: i32 = "texto";
                 ^^^^^^^
```

Categorias hoje expostas: `erro` (violação comprovada — impede o executável) e
`aviso` (risco, não impede). A CLI devolve `1` quando há qualquer erro; nenhum
backend é executado nesse caso.

Mensagens comuns e o que significam:

| Mensagem | Significado |
|---|---|
| `variável 'x' não declarada` | nome fora de escopo ou digitado errado |
| `inicializador de 'x' tem tipo 'str', mas a anotação é 'i32'` | anotação e valor discordam |
| `'x' é imutável; declare com 'var'` | atribuição a `let` (ou a campo de `let`) |
| `função 'f' pode terminar sem executar 'return'` | caminho sem retorno em função não-`void` |
| `argumento 1 de 'f' deve ser 'i32', encontrado 'str'` | tipo do argumento |
| `argumento 1 de 'f' é do struct 'B', esperado 'A'` | structs nominais |
| `função 'f' ocupa 7 registradores …` | limite de backend (6, `str` = 2) |
| `struct 'P' não tem o campo 'z'` | campo inexistente |
| `literal de 'P' não inicializa o campo 'y'` | literal incompleto |

---

## 14. Gerando binários e IR

Dois backends, mesma semântica:

```sh
# Nativo: assembly System V, sem libc, _start próprio
kync emit --asm programa.kyn -o programa.s
as programa.s -o programa.o
ld programa.o -o programa
./programa

# LLVM IR textual (validado por llvm-as no CI)
kync emit --llvm programa.kyn -o programa.ll
llvm-as programa.ll -o programa.bc
```

O backend nativo usa syscalls diretas (`write` para `print`, `write` +
divisão decimal para `print_i32`, `exit` para o retorno de `main`). Não há
dependência de libc, alocação dinâmica nem estado global.

O IR usa `@write` da libc para saída e representa `str` como `{ ptr, i64 }` e
struct como agregado no retorno (parâmetros são achatados campo a campo).

---

## 15. Testando seu código

A suíte `e2e` do repositório é dirigida por comentários no topo do arquivo:

```kyn
// expect-stdout: ola, kyn
// expect-exit: 0
fn main() -> i32 {
    print("ola, kyn");
    return 0;
}
```

- `// expect-stdout: <linha>` — uma diretiva por linha esperada, comparadas **na
  ordem** com o stdout real (via `diff`).
- `// expect-exit: N` — código de saída esperado.

Para casos inválidos, a fixture vai em `tests/e2e/negative/` e o esperado é
`kync check` terminar com código `1`.

```sh
zig build e2e        # 102 casos hoje
```

---

## 16. Erros comuns

**Esquecer de cobrir todos os caminhos com `return`**

```kyn
fn sinal(n: i32) -> i32 {
    if n < 0 {
        return 0 - 1;
    }
    // erro: 'sinal' pode terminar sem executar 'return' com valor 'i32'
}

fn main() -> i32 {
    return sinal(1);
}
```

Corrija com um `return` final fora do `if`.

**Usar `i32` como condição**

```kyn
fn main() -> i32 {
    let n = 1;
    // if n { }   // erro: condição deve ser 'bool'
    if n != 0 {
        return 1;
    }
    return 0;
}
```

**Comparar `str`**

```kyn
fn main() -> i32 {
    // if "a" == "b" { }  // erro: comparação de 'str' não é suportada
    return 0;
}
```

Copie o texto para variáveis e compare o que a linguagem sabe comparar (por
enquanto, não há comparação de texto).

**Exceder o limite de registradores**

```kyn
fn muitos(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32) -> i32 {
    // erro: 7 registradores; o backend suporta no máximo 6
    return a + b + c + d + e + f + g;
}

fn main() -> i32 {
    return 0;
}
```

Agrupar valores em um struct ajuda: `fn soma(p: Ponto)` consome um registrador
por campo e o mesmo limite continua valendo.

**Retornar `str` em `main`**

```kyn
// erro: 'main' deve retornar 'i32' ou 'void'
fn main() -> str {
    return "kyn";
}
```

---

## 17. Limites atuais

O compilador diagnostica explicitamente cada item abaixo — nada falha em
silêncio:

- **Memória:** sem ponteiros, slices, arrays, alocadores, `defer`/`errdefer`.
- **Tipos:** só `i32`, `bool`, `str`, `void` e structs de campos escalares
  (sem `i8`/`i64`/`u32`/`f32`, sem `enum`, `union`, `char`).
- **Structs:** sem campo de struct, sem campo `str`, sem struct vazio, sem
  métodos/`impl`; struct por valor em chamadas **existe** (até 6 campos).
- **Texto:** sem concatenação, interpolação, comparação por conteúdo, escapes
  (`\n`) ou `print(bool)`.
- **Erros:** sem error sets, error unions ou `?`.
- **Metaprogramação:** sem generics, sem `comptime`.
- **Baixo nível:** sem `unsafe`, `volatile`, atomics, assembly inline, MMIO,
  atributos (`#[...]`), seções/símbolos controláveis ou convenções de chamada
  configuráveis.
- **Interop:** sem FFI C integrada (existe um experimento isolado em
  `src/ffi/`).
- **Alvos:** Linux x86-64 apenas; `target triple` do IR é fixo; sem ARM64,
  Windows ou freestanding/`--lib` estável.
- **CLI/ferramentas:** sem LSP, sem diagnósticos em JSON, sem fix-it
  automático.

---

## 18. Para onde o Kyn vai

Ordem planejada (detalhada em `DEVELOPMENT_STATE.md` §5 e `ROADMAP.md`):

1. `enum`, `impl`/métodos com `self`, `switch` exaustivo.
2. Tipos numéricos maiores (`i64`, `u8`, `f32`) com regras de conversão
   explícitas.
3. Ponteiros, arrays fixos e slices com layout documentado.
4. `unsafe`, `volatile`, atomics e MMIO — a fronteira explícita para hardware.
5. Error sets/unions, `try`, `defer`/`errdefer`.
6. Generics estáticos e `comptime`.
7. FFI C, cross-compilation, ARM64, freestanding e linking controlável.
8. Instalação de diagnósticos de primeira classe: códigos estáveis, notas,
   sugestões de correção e saída em JSON para editores.

Cada etapa entra com testes de sucesso **e** de falha, documentação e registro
em `DEVELOPMENT_STATE.md` — e nenhuma delas abre mão da regra central: o
compilador nunca aceita em silêncio um programa que ele consegue reprovar.
