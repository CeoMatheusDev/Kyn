const std = @import("std");
const lexer = @import("lexer/lexer.zig");

pub fn main() !void {
    std.debug.print("Kyn v0.2.0-alpha.1 (bootstrap Zig 0.17.0)\n", .{});
    std.debug.print("Marco 1.3: Análise Semântica (Typechecker) + Sema\n", .{});
    const sema = @import("sema/sema.zig");
    var arena2 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena2.deinit();
    const a2 = arena2.allocator();
    var s = sema.Sema.init(a2);
    const n = try @import("ast/ast.zig").Node.init(a2, .variable_decl);
    n.text = "x";
    try s.checkStatement(n);
    const sym = s.lookup("x") orelse return;
    std.debug.print("Sema: variável 'x' do tipo {any}\n", .{sym.typ});
}
