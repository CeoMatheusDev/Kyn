const std = @import("std");
const ast = @import("../ast/ast.zig");
const lexer = @import("../lexer/lexer.zig");

pub const Error = error{
    UndefinedVariable,
    TypeMismatch,
    DuplicateDeclaration,
    ExpectedType,
};

pub const Type = enum {
    i32,
    bool_,
    unknown,
};

pub const Symbol = struct {
    name: []const u8,
    typ: Type,
    mutable: bool,
};

pub const Sema = struct {
    arena: std.mem.Allocator,
    scope: std.ArrayList(Symbol),

    pub fn init(arena: std.mem.Allocator) Sema {
        return .{ .arena = arena, .scope = std.ArrayList(Symbol).empty };
    }

    pub fn checkProgram(self: *Sema, node: *ast.Node) !void {
        if (node.typ != .program) return;
        _ = self;
    }

    pub fn checkStatement(self: *Sema, node: *ast.Node) !void {
        if (node.typ == .variable_decl) {
            const name = node.text;
            const typ: Type = .i32; // default simplificado
            try self.declare(name, typ, false);
        }
    }

    pub fn checkExpression(self: *Sema, node: *ast.Node) !Type {
        if (node.typ == .literal_int) return .i32;
        if (node.typ == .identifier) {
            const sym = self.lookup(node.text) orelse return error.UndefinedVariable;
            return sym.typ;
        }
        return .unknown;
    }

    fn declare(self: *Sema, name: []const u8, typ: Type, mutable: bool) !void {
        for (self.scope.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return error.DuplicateDeclaration;
        }
        try self.scope.append(self.arena, .{ .name = name, .typ = typ, .mutable = mutable });
    }

    pub fn lookup(self: *Sema, name: []const u8) ?Symbol {
        var i = self.scope.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.scope.items[i].name, name)) {
                return self.scope.items[i];
            }
        }
        return null;
    }
};

test "sema basic variable declaration" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sema = Sema.init(a);
    const node = try ast.Node.init(a, .variable_decl);
    node.text = "x";
    try sema.checkStatement(node);
    const sym = sema.lookup("x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(sym.typ, .i32);
}
