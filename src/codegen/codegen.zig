//! Code-generator backend interface.
//!
//! Contract: receives an AST already validated by semantics (`Checked`) and
//! texto do artefato do backend escolhido, alocado na arena.
//!
//! Available backends:
//! - `.llvm_ir`: textual LLVM IR (the project's declared target; not validated by
//!   ferramenta LLVM neste ambiente);
//! - `.x86_64_asm`: Linux x86-64 assembly without libc, assemblable with `as` and
//!   linkable with `ld` — the path used for end-to-end executable validation.
//!
//! The interface is intentionally textual: the consumer decides where to write
//! returns the artifact. Backend errors mean inconsistent AST/semantics
//! (`MiscompiledAst`) or a subset not yet supported (`UnsupportedNode`).

const std = @import("std");
const ast = @import("../ast/ast.zig");
const sema = @import("../sema/sema.zig");

pub const llvm = @import("llvm.zig");
pub const x86_64 = @import("x86_64.zig");

/// Arguments of a call as seen by the callee: the receiver of a method comes
/// first (argument 1), then the arguments written at the call site.
///
/// Both backends walk the arguments through this view, so a method call and a
/// free call share the same marshalling code (`str`: two words, enum: two
/// words, struct: one word per field, scalar: one).
pub const Arguments = struct {
    receiver: ?*ast.Expr = null,
    list: []*ast.Expr = &.{},

    pub fn count(self: Arguments) usize {
        return self.list.len + @intFromBool(self.receiver != null);
    }

    pub fn at(self: Arguments, index: usize) *ast.Expr {
        if (self.receiver) |recv| {
            if (index == 0) return recv;
            return self.list[index - 1];
        }
        return self.list[index];
    }
};

pub const Backend = enum {
    llvm_ir,
    x86_64_asm,

    pub fn cliName(self: Backend) []const u8 {
        return switch (self) {
            .llvm_ir => "llvm",
            .x86_64_asm => "asm",
        };
    }

    pub fn extension(self: Backend) []const u8 {
        return switch (self) {
            .llvm_ir => ".ll",
            .x86_64_asm => ".s",
        };
    }

    pub fn description(self: Backend) []const u8 {
        return switch (self) {
            .llvm_ir => "LLVM IR textual",
            .x86_64_asm => "assembly x86-64 (Linux, System V)",
        };
    }

    pub fn fromCliName(name: []const u8) ?Backend {
        if (std.mem.eql(u8, name, "llvm")) return .llvm_ir;
        if (std.mem.eql(u8, name, "asm")) return .x86_64_asm;
        return null;
    }
};

/// Pool de literais de string de um programa.
///
/// Deduplicates by content: each distinct text becomes a single label in the
/// artifact (`@.strN` in LLVM IR, `.LstrN` in assembly), no matter how many
/// times it appears in the source. The identifier returned by `intern` is stable
/// specific to the backend that formats it.
pub const StrPool = struct {
    arena: std.mem.Allocator,
    texts: std.ArrayList([]const u8) = .empty,

    pub fn init(arena: std.mem.Allocator) StrPool {
        return .{ .arena = arena };
    }

    /// Returns the text index, inserting it when not present yet.
    pub fn intern(self: *StrPool, text: []const u8) !u32 {
        for (self.texts.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, text)) return @intCast(i);
        }
        try self.texts.append(self.arena, text);
        return @intCast(self.texts.items.len - 1);
    }
};

/// State shared across a program's functions during emission.
pub const ProgramState = struct {
    strs: StrPool,
    /// Was any `print` call emitted? Controls the line break constant in the
    /// artifact footer.
    used_print: bool = false,
    /// Was any `print_i32` call emitted? Controls the decimal conversion
    /// routine in the artifact footer (emitted once).
    used_print_i32: bool = false,
};

pub const Error = error{
    /// The AST lacks the annotations semantics is expected to provide.
    MiscompiledAst,
    /// Node or combination not implemented in the backend yet.
    UnsupportedNode,
    /// Type with no representation in the backend.
    UnsupportedType,
} || std.mem.Allocator.Error;

/// Size of one pointer-arithmetic step for the current x86-64 stack layout.
/// Keep this out of the frontend: both backends must agree on the same scale.
/// A struct pointer addresses its reserved base word, with fields at negative
/// eight-byte offsets. This is NOT a C-compatible struct layout guarantee.
pub fn pointeeStride(pointer: sema.Type, structs: []const sema.StructInfo) Error!u32 {
    if (!pointer.isPtr()) return error.MiscompiledAst;
    return switch (pointer.ptr.pointee.*) {
        .bool, .i8, .u8 => 1,
        .i16, .u16 => 2,
        .i32, .u32 => 4,
        .i64, .u64, .usize, .ptr => 8,
        .aggregate => blk: {
            if (!pointer.ptr.has_struct_id or pointer.ptr.struct_id >= structs.len) return error.MiscompiledAst;
            const words = structs[pointer.ptr.struct_id].fields.len + 1;
            break :blk std.math.cast(u32, words * 8) orelse return error.UnsupportedType;
        },
        else => error.MiscompiledAst,
    };
}

pub fn generate(
    arena: std.mem.Allocator,
    program: *const ast.Program,
    checked: *const sema.Checked,
    backend: Backend,
) Error![]const u8 {
    return switch (backend) {
        .llvm_ir => llvm.emit(arena, program, checked),
        .x86_64_asm => x86_64.emit(arena, program, checked),
    };
}

test "codegen: string pool deduplicates by content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var pool = StrPool.init(arena.allocator());
    try std.testing.expectEqual(@as(u32, 0), try pool.intern("kyn"));
    try std.testing.expectEqual(@as(u32, 1), try pool.intern("bootstrap"));
    try std.testing.expectEqual(@as(u32, 0), try pool.intern("kyn"));
    try std.testing.expectEqual(@as(usize, 2), pool.texts.items.len);
    try std.testing.expectEqualStrings("bootstrap", pool.texts.items[1]);
}

test "codegen: backend names for the CLI" {
    try std.testing.expectEqualStrings("llvm", Backend.llvm_ir.cliName());
    try std.testing.expectEqualStrings("asm", Backend.x86_64_asm.cliName());
    try std.testing.expectEqual(Backend.x86_64_asm, Backend.fromCliName("asm").?);
    try std.testing.expect(Backend.fromCliName("cobol") == null);
}

test "codegen: pointer stride follows the current scalar slot layout" {
    var byte: sema.Type = .u8;
    var word: sema.Type = .i32;
    var wide: sema.Type = .u64;
    try std.testing.expectEqual(@as(u32, 1), try pointeeStride(.{ .ptr = .{ .pointee = &byte } }, &.{}));
    try std.testing.expectEqual(@as(u32, 4), try pointeeStride(.{ .ptr = .{ .pointee = &word } }, &.{}));
    try std.testing.expectEqual(@as(u32, 8), try pointeeStride(.{ .ptr = .{ .pointee = &wide } }, &.{}));
    try std.testing.expectError(error.MiscompiledAst, pointeeStride(.i32, &.{}));
}
