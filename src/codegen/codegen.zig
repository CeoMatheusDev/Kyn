const std = @import("std");
const ast = @import("../ast/ast.zig");

pub const Error = error{
    CodegenFailed,
};

pub const Codegen = struct {
    arena: std.mem.Allocator,
    output: std.ArrayList(u8),

    pub fn init(arena: std.mem.Allocator) Codegen {
        return .{ .arena = arena, .output = std.ArrayList(u8).empty };
    }

    pub fn emitProgram(self: *Codegen, node: *ast.Node) !void {
        // LLVM IR mínimo para uma função main que retorna i32 (0)
        try self.output.appendSlice(self.arena, "define i32 @main() {\n");
        try self.output.appendSlice(self.arena, "entry:\n");
        try self.output.appendSlice(self.arena, "  ret i32 0\n");
        try self.output.appendSlice(self.arena, "}\n");
        _ = node;
    }

    pub fn getOutput(self: *Codegen) []const u8 {
        return self.output.items;
    }
};
