const std = @import("std");

pub const Error = error{
    UnexpectedToken,
    ExpectedSemicolon,
    ExpectedIdentifier,
    ExpectedExpression,
};

pub const NodeType = enum {
    program,
    variable_decl,
    binary_op,
    literal_int,
    identifier,
};

pub const Node = struct {
    typ: NodeType,
    text: []const u8, // para identificadores/valores
    left: ?*Node,
    right: ?*Node,
    line: u32,

    pub fn init(arena: std.mem.Allocator, typ: NodeType) !*Node {
        const node = try arena.create(Node);
        node.* = .{
            .typ = typ,
            .text = "",
            .left = null,
            .right = null,
            .line = 0,
        };
        return node;
    }
};
