const std = @import("std");
const sema = @import("sema/sema.zig");
const ast = @import("ast/ast.zig");

test "sema basic variable declaration" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = sema.Sema.init(a);
    const node = try ast.Node.init(a, .variable_decl);
    node.text = "x";
    try s.checkStatement(node);
    const sym = s.lookup("x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(sym.typ, .i32);
}
