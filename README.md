<p align="center">
  <h1 align="center">Kyn Programming Language</h1>
</p>

<p align="center">
  <b>A modern, ultra-low-level, memory-safe, and high-performance system programming language.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-v0.9.0--rc.1-blueviolet?style=for-the-badge" alt="Version">
  <img src="https://img.shields.io/badge/bootstrap-Zig%200.17.0-orange?style=for-the-badge" alt="Bootstrap">
  <img src="https://img.shields.io/badge/license-MIT%2FApache--2.0-blue?style=for-the-badge" alt="License">
  <img src="https://img.shields.io/badge/status-Release%20Candidate-success?style=for-the-badge" alt="Status">
</p>

---

## 🚀 Sobre o Kyn

O **Kyn** foi concebido para o Santo Graal da engenharia de software: controle absoluto de hardware (ARM, x86, RISC-V), segurança moderna sem *garbage collector*, performance de nível de metal cru (*bare-metal*), e portabilidade total para sistemas operacionais, motores de jogos (*game engines*) e sistemas embarcados.

---

## 📈 Evolução e Marcos de Desenvolvimento (Roadmap)

O compilador evoluiu de forma incremental e rigorosa sob o versionamento **SemVer 2.0.0**:

| Versão / Tag | Estágio | Foco Principal | Status |
| :--- | :--- | :--- | :--- |
| `v0.1.0-alpha.1` | **Bootstrap Base** | Estrutura de pastas, CLI `kync` e Lexer básico em Zig 0.17.0. | Concluído ✅ |
| `v0.2.0-alpha.1` | **Parser & AST** | Construção da Árvore Sintática Abstrata e descida recursiva. | Concluído ✅ |
| `v0.3.0-alpha.1` | **Análise Semântica** | Typechecker básico, escopos e checagem de variáveis `let`. | Concluído ✅ |
| `v0.4.0-alpha.1` | **Code Generation** | Emissão de LLVM IR nativo para o pipeline completo. | Concluído ✅ |
| `v0.5.0-alpha.1` | **Core & Bare-Metal** | Camada `kyn:core`, alocadores explícitos e semântica `unsafe`. | Concluído ✅ |
| `v0.6.0-beta.1` | **Segurança Avançada** | Validação semântica estrita para blocos `unsafe` e `#[repr(C)]`. | Concluído ✅ |
| `v0.8.0-beta.2` | **Std & FFI** | Biblioteca padrão `kyn:std` (I/O, Threads, Net) e FFI com C de custo zero. | Concluído ✅ |
| `v0.9.0-rc.1` | **Release Candidate** | Otimizações de pipeline, cobertura de testes > 90% e congelamento da spec. | **Atual 🚀** |
| `v1.0.0` | **Self-Hosted** | Compilador reescrito na própria linguagem Kyn (Estável). | Planejado ⏳ |

---

## 🛠️ Arquitetura do Repositório

```text
Kyn/
├── docs/             # Especificação formal, gramática EBNF e modelo de memória
├── src/              # Compilador Bootstrap (Lexer, Parser, AST, Sema, CodeGen, FFI)
├── std/              # Biblioteca Padrão (kyn:core para bare-metal e kyn:std para OS)
├── tests/            # Testes de integração e suítes end-to-end (.kyn)
└── examples/         # Exemplos para Kernel, Embarcados e Game Engines
```

---

## ⚙️ Compilação e Uso (Bootstrap em Zig 0.17.0)

Para compilar e testar o compilador `kync`:

```bash
# Executar testes unitários e internos
zig test src/test_sema.zig
zig test src/test_codegen.zig
zig test src/test_std.zig

# Compilar o executável CLI do compilador
zig build-exe src/main.zig -I src --name kync
```

---

## 📄 Licença

Distribuído sob os termos das licenças MIT e Apache-2.0. Consulte o arquivo `LICENSE` para detalhes.
