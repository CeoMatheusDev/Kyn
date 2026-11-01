const std = @import("std");
const codegen = @import("codegen/codegen.zig");
const ast = @import("ast/ast.zig");

test "codegen basic LLVM IR" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cg = codegen.Codegen.init(a);
    const node = try ast.Node.init(a, .program);
    try cg.emitProgram(node);
    const out = cg.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, out, "define i32 @main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ret i32 0") != null);
}
