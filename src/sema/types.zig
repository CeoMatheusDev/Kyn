//! src/sema/types.zig — Representação e comparação de tipos.
//!
//! Tipos são internados por valor em uma `Table`; um `Id` é o índice + 1, e
//! `invalid` (0) marca "ainda não resolvido". A tabela é o único lugar que
//! conhece a forma dos tipos — o backend consulta `describe`/`intBits` em vez
//! de inspecionar a AST.

const std = @import("std");
pub const Id = u32;
pub const invalid: Id = 0;

pub const Int = struct {
    bits: u8,
    signed: bool,
    /// `true` para `isize`/`usize` (largura da arquitetura).
    addr_width: bool = false,
};

pub const NamedKind = enum { structure, enumeration };

pub const Type = union(enum) {
    void,
    bool,
    char,
    str,
    int: Int,
    /// bits: 32 ou 64.
    float: u8,
    ptr: struct { elem: Id, is_const: bool },
    ref_: struct { elem: Id, mutable: bool },
    named: struct { name: []const u8, kind: NamedKind },
};

pub const Table = struct {
    items: std.ArrayList(Type) = .empty,

    // Ids dos primitivos, preenchidos por `init`.
    void_id: Id = invalid,
    bool_id: Id = invalid,
    char_id: Id = invalid,
    str_id: Id = invalid,
    i8_id: Id = invalid,
    i16_id: Id = invalid,
    i32_id: Id = invalid,
    i64_id: Id = invalid,
    isize_id: Id = invalid,
    u8_id: Id = invalid,
    u16_id: Id = invalid,
    u32_id: Id = invalid,
    u64_id: Id = invalid,
    usize_id: Id = invalid,
    f32_id: Id = invalid,
    f64_id: Id = invalid,

    pub fn init(alloc: std.mem.Allocator) !Table {
        var self: Table = .{};
        // Id 0 é reservado para `invalid`.
        try self.items.append(alloc, .void);
        self.void_id = try self.add(alloc, .void);
        self.bool_id = try self.add(alloc, .bool);
        self.char_id = try self.add(alloc, .char);
        self.str_id = try self.add(alloc, .str);
        self.i8_id = try self.add(alloc, .{ .int = .{ .bits = 8, .signed = true } });
        self.i16_id = try self.add(alloc, .{ .int = .{ .bits = 16, .signed = true } });
        self.i32_id = try self.add(alloc, .{ .int = .{ .bits = 32, .signed = true } });
        self.i64_id = try self.add(alloc, .{ .int = .{ .bits = 64, .signed = true } });
        self.isize_id = try self.add(alloc, .{ .int = .{ .bits = 64, .signed = true, .addr_width = true } });
        self.u8_id = try self.add(alloc, .{ .int = .{ .bits = 8, .signed = false } });
        self.u16_id = try self.add(alloc, .{ .int = .{ .bits = 16, .signed = false } });
        self.u32_id = try self.add(alloc, .{ .int = .{ .bits = 32, .signed = false } });
        self.u64_id = try self.add(alloc, .{ .int = .{ .bits = 64, .signed = false } });
        self.usize_id = try self.add(alloc, .{ .int = .{ .bits = 64, .signed = false, .addr_width = true } });
        self.f32_id = try self.add(alloc, .{ .float = 32 });
        self.f64_id = try self.add(alloc, .{ .float = 64 });
        return self;
    }

    pub fn add(self: *Table, alloc: std.mem.Allocator, ty: Type) !Id {
        for (self.items.items, 0..) |existing, i| {
            if (same(self, existing, ty)) return @intCast(i);
        }
        try self.items.append(alloc, ty);
        return @intCast(self.items.items.len - 1);
    }

    pub fn get(self: Table, id: Id) Type {
        if (id == invalid or id >= self.items.items.len) return .void;
        return self.items.items[@intCast(id)];
    }

    fn same(self: *const Table, a: Type, b: Type) bool {
        switch (a) {
            .void, .bool, .char, .str => return std.meta.eql(a, b),
            .int => |ai| {
                const bi = switch (b) {
                    .int => |v| v,
                    else => return false,
                };
                return ai.bits == bi.bits and ai.signed == bi.signed and ai.addr_width == bi.addr_width;
            },
            .float => |af| return switch (b) {
                .float => |bf| af == bf,
                else => false,
            },
            .ptr => |ap| {
                const bp = switch (b) {
                    .ptr => |v| v,
                    else => return false,
                };
                return ap.is_const == bp.is_const and self.eql(ap.elem, bp.elem);
            },
            .ref_ => |ar| {
                const br = switch (b) {
                    .ref_ => |v| v,
                    else => return false,
                };
                return ar.mutable == br.mutable and self.eql(ar.elem, br.elem);
            },
            .named => |an| {
                const bn = switch (b) {
                    .named => |v| v,
                    else => return false,
                };
                return an.kind == bn.kind and std.mem.eql(u8, an.name, bn.name);
            },
        }
    }

    pub fn eql(self: *const Table, a: Id, b: Id) bool {
        if (a == b) return true;
        return same(self, self.get(a), self.get(b));
    }

    pub fn isInt(self: Table, id: Id) bool {
        return self.get(id) == .int;
    }

    pub fn isFloat(self: Table, id: Id) bool {
        return self.get(id) == .float;
    }

    pub fn isNumeric(self: Table, id: Id) bool {
        return self.isInt(id) or self.isFloat(id);
    }

    pub fn isBool(self: Table, id: Id) bool {
        return self.get(id) == .bool;
    }

    pub fn isStr(self: Table, id: Id) bool {
        return self.get(id) == .str;
    }

    pub fn isVoid(self: Table, id: Id) bool {
        return self.get(id) == .void;
    }

    pub fn isChar(self: Table, id: Id) bool {
        return self.get(id) == .char;
    }

    pub fn intInfo(self: Table, id: Id) ?Int {
        return switch (self.get(id)) {
            .int => |info| info,
            else => null,
        };
    }

    pub fn ptrElem(self: Table, id: Id) ?Id {
        return switch (self.get(id)) {
            .ptr => |p| p.elem,
            else => null,
        };
    }

    pub fn refElem(self: Table, id: Id) ?Id {
        return switch (self.get(id)) {
            .ref_ => |r| r.elem,
            else => null,
        };
    }

    pub fn isRawPtr(self: Table, id: Id) bool {
        return self.get(id) == .ptr;
    }

    /// Nome legível para diagnósticos. O resultado é alocado em `alloc`.
    pub fn describe(self: Table, alloc: std.mem.Allocator, id: Id) ![]const u8 {
        if (id == invalid) return "<não inferido>";
        return switch (self.get(id)) {
            .void => "void",
            .bool => "bool",
            .char => "char",
            .str => "str",
            .int => |info| try std.fmt.allocPrint(alloc, "{s}{d}", .{
                if (info.addr_width) (if (info.signed) "i" else "u") else (if (info.signed) "i" else "u"),
                info.bits,
            }),
            .float => |bits| try std.fmt.allocPrint(alloc, "f{d}", .{bits}),
            .ptr => |p| try std.fmt.allocPrint(alloc, "{s}{s}", .{
                if (p.is_const) "*const " else "*",
                try self.describe(alloc, p.elem),
            }),
            .ref_ => |r| try std.fmt.allocPrint(alloc, "{s}{s}", .{
                if (r.mutable) "&mut " else "&",
                try self.describe(alloc, r.elem),
            }),
            .named => |n| n.name,
        };
    }

    /// `isize`/`usize` são descritos pelo nome, não pela largura.
    pub fn describePrefixed(self: Table, alloc: std.mem.Allocator, id: Id) ![]const u8 {
        if (self.intInfo(id)) |info| {
            if (info.addr_width) return if (info.signed) "isize" else "usize";
        }
        return self.describe(alloc, id);
    }
};

test "primitive types are interned once" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var table = try Table.init(a);

    const again = try table.add(a, .{ .int = .{ .bits = 32, .signed = true } });
    try std.testing.expectEqual(table.i32_id, again);
    try std.testing.expect(!table.eql(table.i32_id, table.u32_id));
}

test "composite types compare structurally" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var table = try Table.init(a);

    const ref_a = try table.add(a, .{ .ref_ = .{ .elem = table.i32_id, .mutable = true } });
    const ref_b = try table.add(a, .{ .ref_ = .{ .elem = table.i32_id, .mutable = true } });
    try std.testing.expectEqual(ref_a, ref_b);

    const ptr_const = try table.add(a, .{ .ptr = .{ .elem = table.u8_id, .is_const = true } });
    const ptr_mut = try table.add(a, .{ .ptr = .{ .elem = table.u8_id, .is_const = false } });
    try std.testing.expect(!table.eql(ptr_const, ptr_mut));
}

test "describe renders readable names" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var table = try Table.init(a);

    try std.testing.expectEqualStrings("i32", try table.describe(a, table.i32_id));
    try std.testing.expectEqualStrings("f64", try table.describe(a, table.f64_id));
    const ref_ty = try table.add(a, .{ .ref_ = .{ .elem = table.i32_id, .mutable = true } });
    try std.testing.expectEqualStrings("&mut i32", try table.describe(a, ref_ty));
    const ptr_ty = try table.add(a, .{ .ptr = .{ .elem = table.u8_id, .is_const = true } });
    try std.testing.expectEqualStrings("*const u8", try table.describe(a, ptr_ty));
    try std.testing.expectEqualStrings("usize", try table.describePrefixed(a, table.usize_id));
}
