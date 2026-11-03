//! src/driver.zig — Pipeline de compilação do Kyn.
//!
//! `compile` encadeia lexer → parser → semântica → backend e devolve o texto
//! em C pronto para ser escrito em disco. Cada estágio para no primeiro
//! conjunto de erros: os diagnósticos acumulados são a única forma de
//! comunicação de falha, então nunca há exceções de "erro de compilação"
//! misturadas com erros internos.

const std = @import("std");
const lex = @import("lexer/lexer.zig");
const ast = @import("ast/ast.zig");
const parser = @import("parser/parser.zig");
const sema = @import("sema/sema.zig");
const codegen = @import("codegen/c.zig");
const diag = @import("diag.zig");

pub const version = "0.3.0-alpha.1";
pub const language_version = "0.3";

pub const Options = struct {
    /// Exige `fn main` (compilação de executável).
    require_main: bool = true,
    /// Emite `W0001` para bindings nunca lidos.
    warn_unused: bool = false,
};

pub const Output = struct {
    c_source: []const u8,
    program: ast.Program,
    sema: *sema.Sema,
    warnings: usize = 0,
};

pub const Result = union(enum) {
    ok: Output,
    /// Diagnósticos já estão na `diag.List` do chamador.
    failure,
};

pub fn compile(
    alloc: std.mem.Allocator,
    source: []const u8,
    path: []const u8,
    diags: *diag.List,
    opts: Options,
) !Result {
    _ = path;
    var lexer = lex.Lexer.init(alloc, source, diags);
    const tokens = try lexer.tokenize();
    if (diags.hasErrors()) return .failure;

    var p = parser.Parser.init(alloc, source, tokens, diags);
    const program = try p.parseProgram();
    if (diags.hasErrors()) return .failure;

    const analyzer = try alloc.create(sema.Sema);
    analyzer.* = try sema.Sema.init(alloc, diags, .{
        .require_main = opts.require_main,
        .warn_unused = opts.warn_unused,
    });
    try analyzer.analyze(program);
    if (diags.hasErrors()) return .failure;

    var cg = codegen.Codegen.init(alloc, analyzer);
    const c_source = try cg.emit(program);
    return .{ .ok = .{
        .c_source = c_source,
        .program = program,
        .sema = analyzer,
        .warnings = diags.count(.warning),
    } };
}

/// Apenas lexer — usado por `kyn tokens`.
pub fn tokenize(alloc: std.mem.Allocator, source: []const u8, diags: *diag.List) ![]lex.Token {
    var lexer = lex.Lexer.init(alloc, source, diags);
    return lexer.tokenize();
}

/// Apenas lexer + parser — usado por `kyn ast`.
pub fn parse(alloc: std.mem.Allocator, source: []const u8, diags: *diag.List) !ast.Program {
    const tokens = try tokenize(alloc, source, diags);
    if (diags.hasErrors()) return .{ .decls = &.{}, .imports = &.{}, .span = .{} };
    var p = parser.Parser.init(alloc, source, tokens, diags);
    return p.parseProgram();
}

/// Lista os tokens com linha e coluna, um por linha.
pub fn dumpTokens(alloc: std.mem.Allocator, source: []const u8, tokens: []const lex.Token) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const lines = try diag.LineMap.build(alloc, source);
    for (tokens) |tok| {
        const pos = lines.locate(source, tok.span.start);
        try diag.appendf(&out, alloc, "{d}:{d}\t{s}\t\"{s}\"\n", .{
            pos.line,
            pos.col,
            @tagName(tok.kind),
            tok.text,
        });
    }
    return out.items;
}

/// Impressão legível da AST, útil para inspecionar o frontend.
pub fn dumpAst(alloc: std.mem.Allocator, program: ast.Program) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "program\n");
    for (program.imports) |imp| {
        try diag.appendf(&out, alloc, "  import {s}\n", .{imp.path});
    }
    for (program.decls) |decl| {
        switch (decl) {
            .func => |f| {
                try diag.appendf(&out, alloc, "  fn {s}(", .{f.name});
                for (f.params, 0..) |param, i| {
                    try diag.appendf(&out, alloc, "{s}{s}: {s}", .{ if (i > 0) ", " else "", param.name, param.ty.name() });
                }
                try diag.appendf(&out, alloc, ") -> {s}\n", .{if (f.ret) |r| r.name() else "void"});
                for (f.body.stmts) |stmt| try dumpStmt(&out, alloc, stmt, 2);
            },
            .extern_func => |f| try diag.appendf(&out, alloc, "  extern fn {s}({d} params, variadic={any})\n", .{
                f.name,
                f.params.len,
                f.is_variadic,
            }),
            .structure => |s| {
                try diag.appendf(&out, alloc, "  struct {s} {{\n", .{s.name});
                for (s.fields) |field| {
                    try diag.appendf(&out, alloc, "    {s}: {s}\n", .{ field.name, field.ty.name() });
                }
                try out.appendSlice(alloc, "  }\n");
            },
            .enumeration => |e| {
                try diag.appendf(&out, alloc, "  enum {s} {{", .{e.name});
                for (e.variants, 0..) |variant, i| {
                    try diag.appendf(&out, alloc, "{s}{s}", .{ if (i > 0) ", " else "", variant.name });
                }
                try out.appendSlice(alloc, "}\n");
            },
            .impl => |i| {
                try diag.appendf(&out, alloc, "  impl {s} ({} métodos)\n", .{ i.target, i.methods.len });
            },
        }
    }
    return out.items;
}

fn dumpStmt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, stmt: ast.Stmt, level: usize) !void {
    var prefix: std.ArrayList(u8) = .empty;
    for (0..level) |_| try prefix.appendSlice(alloc, "  ");
    switch (stmt) {
        .binding => |b| try diag.appendf(out, alloc, "{s}let {s}{s}\n", .{ prefix.items, b.name, if (b.mutable) " (mut)" else "" }),
        .assign => try diag.appendf(out, alloc, "{s}assign\n", .{prefix.items}),
        .expr => try diag.appendf(out, alloc, "{s}expr {s}\n", .{ prefix.items, try dumpExpr(alloc, stmt.expr) }),
        .ret => try diag.appendf(out, alloc, "{s}return\n", .{prefix.items}),
        .cond => try diag.appendf(out, alloc, "{s}if\n", .{prefix.items}),
        .loop => try diag.appendf(out, alloc, "{s}while\n", .{prefix.items}),
        .range_for => |r| try diag.appendf(out, alloc, "{s}for {s} in ..\n", .{ prefix.items, r.var_name }),
        .break_ => try diag.appendf(out, alloc, "{s}break\n", .{prefix.items}),
        .continue_ => try diag.appendf(out, alloc, "{s}continue\n", .{prefix.items}),
        .block => |b| try diag.appendf(out, alloc, "{s}block ({d} statements)\n", .{ prefix.items, b.stmts.len }),
        .unsafe_block => |b| try diag.appendf(out, alloc, "{s}unsafe ({d} statements)\n", .{ prefix.items, b.stmts.len }),
    }
}

fn dumpExpr(alloc: std.mem.Allocator, expr: ast.Expr) ![]const u8 {
    return switch (expr.kind) {
        .int_lit => |v| try std.fmt.allocPrint(alloc, "int {d}", .{v}),
        .float_lit => |v| try std.fmt.allocPrint(alloc, "float {d}", .{v}),
        .string_lit => |v| try std.fmt.allocPrint(alloc, "string \"{s}\"", .{v}),
        .char_lit => |v| try std.fmt.allocPrint(alloc, "char '{c}'", .{v}),
        .bool_lit => |v| try std.fmt.allocPrint(alloc, "bool {any}", .{v}),
        .ident => |v| try std.fmt.allocPrint(alloc, "ident {s}", .{v}),
        .self_ => try std.fmt.allocPrint(alloc, "self", .{}),
        .binary => |b| try std.fmt.allocPrint(alloc, "binary {s}", .{b.op.text()}),
        .unary => try std.fmt.allocPrint(alloc, "unary", .{}),
        .call => try std.fmt.allocPrint(alloc, "call", .{}),
        .field => |f| try std.fmt.allocPrint(alloc, "field .{s}", .{f.name}),
        .path => |p| try std.fmt.allocPrint(alloc, "path {s}::{s}", .{ p.head, p.tail }),
        .struct_lit => |s| try std.fmt.allocPrint(alloc, "struct_lit {s}", .{s.name}),
        .enum_lit => |e| try std.fmt.allocPrint(alloc, "enum_lit {s}::{s}", .{ e.name, e.variant }),
        .cast => try std.fmt.allocPrint(alloc, "cast", .{}),
        .ref_of => try std.fmt.allocPrint(alloc, "ref_of", .{}),
        .deref => try std.fmt.allocPrint(alloc, "deref", .{}),
    };
}

test "compile accepts a minimal program" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var diags: diag.List = .{};

    const source =
        \\fn main() -> i32 {
        \\    let x: i32 = 40 + 2;
        \\    return x;
        \\}
        \\
    ;
    const result = try compile(a, source, "t.kyn", &diags, .{});
    switch (result) {
        .ok => |out| {
            try std.testing.expect(std.mem.indexOf(u8, out.c_source, "int main(void)") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.c_source, "kyn_i32 kyn_x = (40 + 2)") != null);
        },
        .failure => {
            const text = try diags.render(a, source, "t.kyn");
            std.debug.print("{s}", .{text});
            return error.TestUnexpectedResult;
        },
    }
}

test "compile reports type mismatch instead of emitting C" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var diags: diag.List = .{};

    const source =
        \\fn main() -> i32 {
        \\    let x: i32 = "texto";
        \\    return x;
        \\}
        \\
    ;
    const result = try compile(a, source, "t.kyn", &diags, .{});
    try std.testing.expect(result == .failure);
    try std.testing.expect(diags.hasCode(.type_mismatch));
}

test "compile reports syntax errors with spans" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var diags: diag.List = .{};

    const source = "fn main() -> i32 {\n    let x = 10 +;\n    return x;\n}\n";
    const result = try compile(a, source, "t.kyn", &diags, .{});
    try std.testing.expect(result == .failure);
    try std.testing.expect(diags.hasCode(.syntax));
}
