const std = @import("std");
const ast = @import("../ast/ast.zig");

pub const Error = error{
    UnsafeOutsideBlock,
    ReprCInvalidLayout,
};

pub const UnsafeChecker = struct {
    in_unsafe: bool,

    pub fn init() UnsafeChecker {
        return .{ .in_unsafe = false };
    }

    pub fn enterUnsafe(self: *UnsafeChecker) void {
        self.in_unsafe = true;
    }

    pub fn exitUnsafe(self: *UnsafeChecker) void {
        self.in_unsafe = false;
    }

    pub fn checkOperation(self: *UnsafeChecker, op: []const u8) !void {
        if (!self.in_unsafe) return error.UnsafeOutsideBlock;
        _ = op;
    }
};

pub const ReprChecker = struct {
    pub fn checkStruct(self: *ReprChecker, node: *ast.Node) !void {
        if (node.typ != .variable_decl) return;
        // Placeholder: apenas aceita se for struct com repr(C)
        _ = self;
    }
};
