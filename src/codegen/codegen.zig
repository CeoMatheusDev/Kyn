//! Interface de backend do gerador de código.
//!
//! Contrato: recebe uma AST já validada pela semântica (`Checked`) e devolve o
//! texto do artefato do backend escolhido, alocado na arena.
//!
//! Backends disponíveis:
//! - `.llvm_ir`: LLVM IR textual (alvo declarado do projeto, sem validação por
//!   ferramenta LLVM neste ambiente);
//! - `.x86_64_asm`: assembly x86-64 Linux sem libc, montável com `as` e ligável
//!   com `ld` — caminho usado para validação executável de ponta a ponta.
//!
//! A interface é intencionalmente textual: o consumidor decide onde gravar o
//! resultado. Erros de backend indicam AST/semântica inconsistente
//! (`MiscompiledAst`) ou subconjunto ainda não suportado (`UnsupportedNode`).

const std = @import("std");
const ast = @import("../ast/ast.zig");
const sema = @import("../sema/sema.zig");

pub const llvm = @import("llvm.zig");
pub const x86_64 = @import("x86_64.zig");

pub const Backend = enum {
    llvm_ir,
    x86_64_asm,

    pub fn cliName(self: Backend) []const u8 {
        return switch (self) {
            .llvm_ir => "llvm",
            .x86_64_asm => "asm",
        };
    }

    pub fn extension(self: Backend) []const u8 {
        return switch (self) {
            .llvm_ir => ".ll",
            .x86_64_asm => ".s",
        };
    }

    pub fn description(self: Backend) []const u8 {
        return switch (self) {
            .llvm_ir => "LLVM IR textual",
            .x86_64_asm => "assembly x86-64 (Linux, System V)",
        };
    }

    pub fn fromCliName(name: []const u8) ?Backend {
        if (std.mem.eql(u8, name, "llvm")) return .llvm_ir;
        if (std.mem.eql(u8, name, "asm")) return .x86_64_asm;
        return null;
    }
};

/// Pool de literais de string de um programa.
///
/// Deduplica por conteúdo: cada texto distinto vira um único rótulo no
/// artefato (`@.strN` no LLVM IR, `.LstrN` no assembly), não importa quantas
/// vezes apareça na fonte. O identificador devolvido por `intern` é estável e
/// específico do backend que o formatar.
pub const StrPool = struct {
    arena: std.mem.Allocator,
    texts: std.ArrayList([]const u8) = .empty,

    pub fn init(arena: std.mem.Allocator) StrPool {
        return .{ .arena = arena };
    }

    /// Devolve o índice do texto, inserindo-o se ainda não existir.
    pub fn intern(self: *StrPool, text: []const u8) !u32 {
        for (self.texts.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, text)) return @intCast(i);
        }
        try self.texts.append(self.arena, text);
        return @intCast(self.texts.items.len - 1);
    }
};

/// Estado compartilhado entre as funções de um programa durante a emissão.
pub const ProgramState = struct {
    strs: StrPool,
    /// Alguma chamada a `print` foi emitida? Controla a constante de quebra de
    /// linha no rodapé do artefato.
    used_print: bool = false,
};

pub const Error = error{
    /// A AST não contém as anotações esperadas da semântica.
    MiscompiledAst,
    /// Nó ou combinação ainda não implementada no backend.
    UnsupportedNode,
    /// Tipo sem representação no backend.
    UnsupportedType,
} || std.mem.Allocator.Error;

pub fn generate(
    arena: std.mem.Allocator,
    program: *const ast.Program,
    checked: *const sema.Checked,
    backend: Backend,
) Error![]const u8 {
    return switch (backend) {
        .llvm_ir => llvm.emit(arena, program, checked),
        .x86_64_asm => x86_64.emit(arena, program, checked),
    };
}

test "codegen: pool de strings deduplica por conteúdo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var pool = StrPool.init(arena.allocator());
    try std.testing.expectEqual(@as(u32, 0), try pool.intern("kyn"));
    try std.testing.expectEqual(@as(u32, 1), try pool.intern("bootstrap"));
    try std.testing.expectEqual(@as(u32, 0), try pool.intern("kyn"));
    try std.testing.expectEqual(@as(usize, 2), pool.texts.items.len);
    try std.testing.expectEqualStrings("bootstrap", pool.texts.items[1]);
}

test "codegen: nomes de backend para CLI" {
    try std.testing.expectEqualStrings("llvm", Backend.llvm_ir.cliName());
    try std.testing.expectEqualStrings("asm", Backend.x86_64_asm.cliName());
    try std.testing.expectEqual(Backend.x86_64_asm, Backend.fromCliName("asm").?);
    try std.testing.expect(Backend.fromCliName("cobol") == null);
}
