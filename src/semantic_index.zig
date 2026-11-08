//! Compiler-resolved symbol index serialized for editor tooling.
//!
//! IDs are stable for one compilation snapshot and are derived from semantic
//! table indices. Consumers must treat them as opaque and replace the complete
//! snapshot after every successful compiler invocation.

const std = @import("std");
const ast = @import("ast/ast.zig");
const sema = @import("sema/sema.zig");

pub const Symbol = struct {
    id: []const u8,
    name: []const u8,
    kind: []const u8,
    file: u32,
    /// UTF-8 byte offsets in the source file (editor clients convert as needed).
    start: u32,
    end: u32,
    line: u32,
    column: u32,
    container: ?[]const u8 = null,
};

pub const Reference = struct {
    target: []const u8,
    file: u32,
    start: u32,
    end: u32,
    line: u32,
    column: u32,
    role: []const u8,
};

pub const File = struct {
    id: u32,
    path: []const u8,
};

pub const Document = struct {
    schema: u32 = 1,
    files: []const File,
    symbols: []const Symbol,
    references: []const Reference,
};

const Builder = struct {
    arena: std.mem.Allocator,
    program: *const ast.Program,
    checked: *const sema.Checked,
    symbols: std.ArrayList(Symbol) = .empty,
    references: std.ArrayList(Reference) = .empty,

    fn symbolId(self: *Builder, prefix: []const u8, index: usize) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}:{d}", .{ prefix, index });
    }

    fn pairId(self: *Builder, prefix: []const u8, owner: usize, index: usize) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}:{d}:{d}", .{ prefix, owner, index });
    }

    fn addSymbol(self: *Builder, id: []const u8, name: []const u8, kind: []const u8, file: u32, span: anytype, container: ?[]const u8) !void {
        try self.symbols.append(self.arena, .{
            .id = id,
            .name = name,
            .kind = kind,
            .file = file,
            .start = span.start,
            .end = span.end,
            .line = span.line,
            .column = span.column,
            .container = container,
        });
    }

    fn addReference(self: *Builder, target: []const u8, file: u32, span: anytype, role: []const u8) !void {
        try self.references.append(self.arena, .{
            .target = target,
            .file = file,
            .start = span.start,
            .end = span.end,
            .line = span.line,
            .column = span.column,
            .role = role,
        });
    }

    fn addTypeReference(self: *Builder, file: u32, type_name: ast.TypeName) !void {
        if (self.checked.findStruct(type_name.name)) |id| {
            try self.addReference(try self.symbolId("struct", @as(usize, id)), file, type_name.span, "type");
        } else if (self.checked.findEnum(type_name.name)) |id| {
            try self.addReference(try self.symbolId("enum", @as(usize, id)), file, type_name.span, "type");
        }
    }

    fn addDeclarations(self: *Builder) !void {
        for (self.checked.functions, 0..) |function, i| {
            const decl = function.decl;
            const kind: []const u8 = if (function.is_method) "method" else "function";
            const container = if (decl.owner_type) |owner| owner.name else null;
            try self.addSymbol(try self.symbolId("function", @as(usize, i)), decl.name, kind, decl.file_id, decl.name_span, container);
            if (decl.owner_type) |owner| try self.addTypeReference(decl.file_id, owner);
            for (decl.params) |param| try self.addTypeReference(decl.file_id, param.type_name);
            if (decl.return_type) |return_type| try self.addTypeReference(decl.file_id, return_type);
        }

        for (self.checked.structs, 0..) |info, i| {
            const decl = info.decl;
            try self.addSymbol(try self.symbolId("struct", i), decl.name, "struct", decl.file_id, decl.name_span, null);
            for (decl.fields, 0..) |field, j| {
                try self.addSymbol(try self.pairId("field", i, j), field.name, "field", decl.file_id, field.name_span, decl.name);
                try self.addTypeReference(decl.file_id, field.type_name);
            }
        }

        for (self.checked.enums, 0..) |info, i| {
            const decl = info.decl;
            try self.addSymbol(try self.symbolId("enum", i), decl.name, "enum", decl.file_id, decl.name_span, null);
            for (decl.cases, 0..) |case, j| {
                try self.addSymbol(try self.pairId("case", i, j), case.name, "enum_case", decl.file_id, case.name_span, decl.name);
                if (case.payload) |payload| try self.addTypeReference(decl.file_id, payload);
            }
        }

        for (self.checked.functions) |function| {
            const decl = function.decl;
            const end = @min(
                @as(usize, function.symbol_start) + @as(usize, function.symbol_count),
                self.checked.symbols.len,
            );
            const start: usize = @min(@as(usize, function.symbol_start), end);
            for (self.checked.symbols[start..end], start..) |symbol, symbol_index| {
                const kind: []const u8 = if (symbol.kind == .param) "parameter" else "variable";
                try self.addSymbol(
                    try self.symbolId("variable", symbol_index),
                    symbol.name,
                    kind,
                    decl.file_id,
                    symbol.decl_span,
                    decl.name,
                );
            }
        }
    }

    fn functionId(self: *Builder, index: ?u32) !?[]const u8 {
        if (index) |i| {
            if (@as(usize, i) < self.checked.functions.len) return try self.symbolId("function", @as(usize, i));
        }
        return null;
    }

    fn variableId(self: *Builder, index: ?u32) !?[]const u8 {
        if (index) |i| {
            if (@as(usize, i) < self.checked.symbols.len) return try self.symbolId("variable", @as(usize, i));
        }
        return null;
    }

    fn caseId(self: *Builder, enum_index: ?u32, case_index: ?u32) !?[]const u8 {
        if (enum_index) |ei| {
            if (case_index) |ci| {
                if (@as(usize, ei) < self.checked.enums.len and @as(usize, ci) < self.checked.enums[ei].cases.len) {
                    return try self.pairId("case", @as(usize, ei), @as(usize, ci));
                }
            }
        }
        return null;
    }

    fn structFieldId(self: *Builder, base: *ast.Expr, field_index: ?u32) !?[]const u8 {
        const index = field_index orelse return null;
        var owner: ?u32 = null;
        switch (base.kind) {
            .identifier => {
                if (base.resolved) |symbol_index| {
                    if (@as(usize, symbol_index) < self.checked.symbols.len) {
                        const symbol = self.checked.symbols[symbol_index];
                        if (symbol.has_struct_id) owner = symbol.struct_id;
                    }
                }
            },
            .unary => |unary| {
                if (unary.op == .dereference) return try self.structFieldId(unary.operand, field_index);
            },
            else => {},
        }
        if (owner) |struct_index| {
            if (@as(usize, struct_index) < self.checked.structs.len and @as(usize, index) < self.checked.structs[struct_index].fields.len) {
                return try self.pairId("field", @as(usize, struct_index), @as(usize, index));
            }
        }
        return null;
    }

    fn walkExpr(self: *Builder, expr: *ast.Expr, file: u32) std.mem.Allocator.Error!void {
        switch (expr.kind) {
            .identifier => {
                if (try self.variableId(expr.resolved)) |id| try self.addReference(id, file, expr.span, "read");
            },
            .call => |call| {
                if (try self.functionId(call.callee_fn)) |id| try self.addReference(id, file, call.callee_span, "call");
                for (call.args) |arg| try self.walkExpr(arg, file);
            },
            .method_call => |call| {
                if (try self.functionId(call.resolved_fn)) |id| {
                    try self.addReference(id, file, call.name_span, "call");
                } else if (try self.caseId(call.resolved_enum, call.resolved_case)) |id| {
                    try self.addReference(id, file, call.name_span, "construct");
                }
                try self.walkExpr(call.base, file);
                for (call.args) |arg| try self.walkExpr(arg, file);
            },
            .field_access => |access| {
                if (try self.caseId(access.resolved_enum, access.resolved_case)) |id| {
                    try self.addReference(id, file, access.name_span, "enum_case");
                } else if (try self.structFieldId(access.base, access.field_index)) |id| {
                    try self.addReference(id, file, access.name_span, "field_read");
                }
                try self.walkExpr(access.base, file);
            },
            .struct_literal => |literal| {
                if (literal.resolved_struct) |id| {
                    if (@as(usize, id) < self.checked.structs.len) {
                        try self.addReference(try self.symbolId("struct", @as(usize, id)), file, literal.type_name.span, "construct");
                        const fields = self.checked.structs[id].fields;
                        for (literal.fields) |init| {
                            for (fields, 0..) |field, field_index| {
                                if (std.mem.eql(u8, field.name, init.name)) {
                                    try self.addReference(try self.pairId("field", @as(usize, id), field_index), file, init.name_span, "field_init");
                                    break;
                                }
                            }
                            try self.walkExpr(init.value, file);
                        }
                    }
                }
            },
            .binary => |binary| {
                try self.walkExpr(binary.lhs, file);
                try self.walkExpr(binary.rhs, file);
            },
            .unary => |unary| try self.walkExpr(unary.operand, file),
            .cast => |cast| {
                try self.addTypeReference(file, cast.type_name);
                try self.walkExpr(cast.expr, file);
            },
            .int_literal, .bool_literal, .str_literal => {},
        }
    }

    fn walkStatements(self: *Builder, statements: []*ast.Stmt, file: u32) std.mem.Allocator.Error!void {
        for (statements) |stmt| {
            switch (stmt.kind) {
                .let_decl => |decl| {
                    if (decl.type_name) |type_name| try self.addTypeReference(file, type_name);
                    try self.walkExpr(decl.init, file);
                },
                .assign => |assign| {
                    if (try self.variableId(assign.resolved)) |id| try self.addReference(id, file, assign.name_span, "write");
                    try self.walkExpr(assign.value, file);
                },
                .field_assign => |assign| {
                    if (try self.structFieldId(assign.base, assign.field_index)) |id| {
                        try self.addReference(id, file, assign.name_span, "field_write");
                    }
                    try self.walkExpr(assign.base, file);
                    try self.walkExpr(assign.value, file);
                },
                .return_stmt => |value| {
                    if (value) |expr| try self.walkExpr(expr, file);
                },
                .expr_stmt => |expr| try self.walkExpr(expr, file),
                .if_stmt => |branch| {
                    try self.walkExpr(branch.cond, file);
                    try self.walkStatements(branch.then_body, file);
                    if (branch.else_body) |else_branch| switch (else_branch) {
                        .block => |body| try self.walkStatements(body, file),
                        .if_stmt => |nested| try self.walkStatements(&.{nested}, file),
                    };
                },
                .while_stmt => |loop| {
                    try self.walkExpr(loop.cond, file);
                    try self.walkStatements(loop.body, file);
                },
                .switch_stmt => |switch_stmt| {
                    try self.walkExpr(switch_stmt.scrutinee, file);
                    for (switch_stmt.arms) |arm| {
                        if (try self.caseId(switch_stmt.resolved_enum, arm.resolved_case)) |id| {
                            try self.addReference(id, file, arm.case_span, "pattern");
                        }
                        try self.walkStatements(arm.body, file);
                    }
                    if (switch_stmt.else_body) |body| try self.walkStatements(body, file);
                },
                .block => |body| try self.walkStatements(body, file),
            }
        }
    }

    fn walkProgram(self: *Builder) std.mem.Allocator.Error!void {
        for (self.program.functions) |function| {
            try self.walkStatements(function.body, function.file_id);
        }
    }
};

pub fn generate(
    arena: std.mem.Allocator,
    program: *const ast.Program,
    checked: *const sema.Checked,
    source_paths: []const []const u8,
) std.mem.Allocator.Error![]const u8 {
    var builder: Builder = .{
        .arena = arena,
        .program = program,
        .checked = checked,
    };
    try builder.addDeclarations();
    try builder.walkProgram();

    const files = try arena.alloc(File, source_paths.len);
    for (source_paths, 0..) |path, i| files[i] = .{ .id = @intCast(i), .path = path };

    const document: Document = .{
        .files = files,
        .symbols = builder.symbols.items,
        .references = builder.references.items,
    };
    return try std.json.Stringify.valueAlloc(arena, document, .{});
}
