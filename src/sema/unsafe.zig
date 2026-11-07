//! Verificações de `unsafe` e de representação (`#[repr(C)]`).
//!
//! O subconjunto atual da linguagem (ver `docs/status.md`) ainda não possui
//! blocos `unsafe`, `struct` nem atributos na AST. Este módulo mantém a
//! política de verificação isolada e testada, pronta para ser conectada quando
//! esses nós existirem — sem simulá-los no parser.

const std = @import("std");
const Span = @import("../span.zig").Span;

pub const Error = error{
    UnsafeOutsideBlock,
    ReprCInvalidLayout,
};

pub const UnsafeChecker = struct {
    in_unsafe: bool = false,

    pub fn init() UnsafeChecker {
        return .{};
    }

    pub fn enterUnsafe(self: *UnsafeChecker) void {
        self.in_unsafe = true;
    }

    pub fn exitUnsafe(self: *UnsafeChecker) void {
        self.in_unsafe = false;
    }

    /// Operações de baixo nível exigem contexto `unsafe` explícito.
    pub fn checkOperation(self: *UnsafeChecker, op: []const u8) !void {
        _ = op;
        if (!self.in_unsafe) return error.UnsafeOutsideBlock;
    }
};

pub const ReprChecker = struct {
    /// Valida que uma struct exposta na ABI declara `#[repr(C)]`.
    ///
    /// Enquanto a AST não tiver nós de `struct`, a checagem recebe os dados
    /// explicitamente; nenhum atributo é inferido.
    pub fn checkExternStruct(self: *ReprChecker, name: []const u8, span: Span, has_repr_c: bool) !void {
        _ = self;
        _ = span;
        _ = name;
        if (!has_repr_c) return error.ReprCInvalidLayout;
    }
};

test "unsafe: operação fora do bloco é rejeitada" {
    var checker = UnsafeChecker.init();
    try std.testing.expectError(error.UnsafeOutsideBlock, checker.checkOperation("raw_ptr"));

    checker.enterUnsafe();
    try checker.checkOperation("raw_ptr");
    checker.exitUnsafe();
    try std.testing.expectError(error.UnsafeOutsideBlock, checker.checkOperation("raw_ptr"));
}

test "unsafe: contexto aninhado simplificado" {
    var checker = UnsafeChecker.init();
    checker.enterUnsafe();
    checker.enterUnsafe();
    try checker.checkOperation("deref");
    checker.exitUnsafe();
    // A política atual não conta aninhamento; documentado como pendente.
    try std.testing.expectError(error.UnsafeOutsideBlock, checker.checkOperation("deref"));
}

test "repr(C): struct externa exige repr(C)" {
    var checker = ReprChecker{};
    try std.testing.expectError(error.ReprCInvalidLayout, checker.checkExternStruct("Point", .{}, false));
    try checker.checkExternStruct("Point", .{}, true);
}
