//! src/sema/unsafe.zig — Controle de operações `unsafe` e atributos de layout.
//!
//! Duas responsabilidades pequenas e testáveis:
//! 1. `Context` acompanha se o ponto atual do código está dentro de um bloco
//!    `unsafe` e produz o diagnóstico `E0015` quando uma operação que exige
//!    `unsafe` aparece fora dele.
//! 2. `checkAttrs` valida os atributos `#[repr(C)]` e `#[align(N)]`, que são
//!    os únicos reconhecidos pelo compilador hoje.
//!
//! O backend C é o único consumidor de `alignOf`; `repr(C)` é aceito e
//! registrado, mas o backend já emite layout compatível com C por padrão.

const std = @import("std");
const ast = @import("../ast/ast.zig");
const diag = @import("../diag.zig");

pub const Op = enum {
    deref_raw_ptr,
    write_raw_ptr,
    call_extern,

    pub fn describe(self: Op) []const u8 {
        return switch (self) {
            .deref_raw_ptr => "dereferência de ponteiro cru",
            .write_raw_ptr => "escrita através de ponteiro cru",
            .call_extern => "chamada de função `extern`",
        };
    }
};

pub const Context = struct {
    depth: u32 = 0,

    pub fn enter(self: *Context) void {
        self.depth += 1;
    }

    pub fn exit(self: *Context) void {
        self.depth -= 1;
    }

    pub fn inside(self: Context) bool {
        return self.depth > 0;
    }

    /// Retorna um diagnóstico quando a operação exige `unsafe` e o contexto
    /// atual não está dentro de um bloco `unsafe`.
    pub fn require(self: Context, alloc: std.mem.Allocator, op: Op, span: diag.Span) !?diag.Diagnostic {
        if (self.inside()) return null;
        return .{
            .code = .unsafe_required,
            .message = try std.fmt.allocPrint(alloc, "{s} exige um bloco `unsafe`", .{op.describe()}),
            .span = span,
            .help = "envolva a operação em `unsafe { ... }` para declarar que os invariantes são responsabilidade do chamador",
        };
    }
};

/// Alinhamento pedido por `#[align(N)]`, quando presente.
pub fn alignOf(attrs: []const ast.Attr) ?u32 {
    for (attrs) |attr| {
        if (!std.mem.eql(u8, attr.name, "align")) continue;
        if (attr.args.len != 1) continue;
        return std.fmt.parseInt(u32, attr.args[0], 10) catch null;
    }
    return null;
}

pub fn hasReprC(attrs: []const ast.Attr) bool {
    for (attrs) |attr| {
        if (!std.mem.eql(u8, attr.name, "repr")) continue;
        for (attr.args) |arg| {
            if (std.mem.eql(u8, arg, "C")) return true;
        }
    }
    return false;
}

/// Valida nomes e argumentos de atributos, registrando `E0020`/`E0001`.
pub fn checkAttrs(alloc: std.mem.Allocator, diags: *diag.List, attrs: []const ast.Attr) !void {
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.name, "repr")) {
            if (attr.args.len == 0) {
                try diags.add(alloc, .{
                    .code = .syntax,
                    .message = "`#[repr]` exige um argumento, por exemplo `#[repr(C)]`",
                    .span = attr.span,
                });
                continue;
            }
            for (attr.args) |arg| {
                if (!std.mem.eql(u8, arg, "C")) {
                    try diags.add(alloc, .{
                        .code = .unsupported,
                        .message = try std.fmt.allocPrint(alloc, "`#[repr({s})]` não é suportado", .{arg}),
                        .span = attr.span,
                        .help = "o único valor aceito hoje é `C`",
                    });
                }
            }
            continue;
        }
        if (std.mem.eql(u8, attr.name, "align")) {
            if (attr.args.len != 1 or (std.fmt.parseInt(u32, attr.args[0], 10) catch null) == null) {
                try diags.add(alloc, .{
                    .code = .syntax,
                    .message = "`#[align]` exige um inteiro, por exemplo `#[align(8)]`",
                    .span = attr.span,
                });
            }
            continue;
        }
        try diags.add(alloc, .{
            .code = .unknown_attribute,
            .message = try std.fmt.allocPrint(alloc, "atributo desconhecido `#[{s}]`", .{attr.name}),
            .span = attr.span,
            .help = "atributos reconhecidos: `repr(C)`, `align(N)`",
        });
    }
}

test "operations outside unsafe produce E0015" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = Context{};
    const outside = try ctx.require(a, .deref_raw_ptr, .{});
    try std.testing.expect(outside != null);
    try std.testing.expectEqual(diag.Code.unsafe_required, outside.?.code);

    ctx.enter();
    try std.testing.expect(try ctx.require(a, .deref_raw_ptr, .{}) == null);
    ctx.exit();
    try std.testing.expect(try ctx.require(a, .call_extern, .{}) != null);
}

test "nested unsafe blocks keep the context open" {
    var ctx = Context{};
    ctx.enter();
    ctx.enter();
    ctx.exit();
    try std.testing.expect(ctx.inside());
    ctx.exit();
    try std.testing.expect(!ctx.inside());
}

test "attributes are validated" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var diags: diag.List = .{};

    const repr = [_][]const u8{"C"};
    try checkAttrs(a, &diags, &[_]ast.Attr{.{ .name = "repr", .args = &repr, .span = .{} }});
    try std.testing.expect(!diags.hasErrors());
    try std.testing.expect(hasReprC(&[_]ast.Attr{.{ .name = "repr", .args = &repr, .span = .{} }}));

    const align_args = [_][]const u8{"8"};
    try checkAttrs(a, &diags, &[_]ast.Attr{.{ .name = "align", .args = &align_args, .span = .{} }});
    try std.testing.expectEqual(@as(?u32, 8), alignOf(&[_]ast.Attr{.{ .name = "align", .args = &align_args, .span = .{} }}));
    try std.testing.expect(!diags.hasErrors());

    try checkAttrs(a, &diags, &[_]ast.Attr{.{ .name = "inline", .args = &.{}, .span = .{} }});
    try std.testing.expect(diags.hasCode(.unknown_attribute));
}
