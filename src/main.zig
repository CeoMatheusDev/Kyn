const std = @import("std");
const lexer = @import("lexer/lexer.zig");

pub fn main() !void {
    std.debug.print("Kyn v0.2.0-alpha.1 (bootstrap Zig 0.17.0)\n", .{});
    std.debug.print("Marco 1.4: CodeGen (LLVM IR) + integração completa\n", .{});
    const codegen = @import("codegen/codegen.zig");
    var arena3 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena3.deinit();
    const a3 = arena3.allocator();
    var cg = codegen.Codegen.init(a3);
    const n3 = try @import("ast/ast.zig").Node.init(a3, .program);
    try cg.emitProgram(n3);
    std.debug.print("LLVM IR gerado ({} bytes):\n{s}\n", .{ cg.getOutput().len, cg.getOutput() });
}
