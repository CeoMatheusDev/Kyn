//! Semantic analysis for the Zig bootstrap compiler.
//!
//! Responsibilities:
//! - register nominal struct, enum and function declarations before checking
//!   bodies, allowing recursion and calls before declarations;
//! - resolve variables, parameters, functions, methods, enum cases and fields,
//!   annotating AST nodes with stable indices rather than rewriting the tree;
//! - validate fixed-width integer types, bool, str, void, aggregates, enums and
//!   pointer types, including casts, mutability, operators and control flow;
//! - compute symbol slots and argument-register usage consumed by the backends;
//! - validate the entry-point contract and produce structured diagnostics.
//!
//! The AST is not modified structurally. Symbols, signatures and semantic
//! metadata are allocated from the compilation arena supplied to Checker.

const std = @import("std");
const ast = @import("../ast/ast.zig");
const diagnostics = @import("../diagnostics.zig");
const Span = @import("../span.zig").Span;

pub const Type = union(enum) {
    i32,
    i64,
    i16,
    i8,
    u64,
    u32,
    u16,
    u8,
    usize,
    bool,
    void,
    /// Struct value (nominal identity in `Symbol.struct_id`). Not a scalar:
    /// it takes part in no operators, conditions or value calls.
    aggregate,
    /// Static string slice (pointer + length), represented in two
    /// slots. Not a scalar: it only initializes, is copied and is a `print`
    str,
    /// Enum value: a tag (`i32`, the declaration order of the case) plus a
    /// payload slot (used only by cases that carry a value). Not a scalar: it
    /// takes part in no operator; the only consumer is `switch`.
    enumeration,
    /// Unknown type: avoids a cascade of diagnostics after an error.
    unknown,
    /// Pointer to a pointee type. When the pointee is an aggregate (struct),
    /// `struct_id` identifies which struct, enabling field access through
    /// pointers (`(*ptr).field`). Pointers take one register.
    ptr: PtrType,

    /// Pointer type with optional struct identity for field access.
    pub const PtrType = struct {
        // Pointee identity is immutable after checking; sharing a read-only
        // unknown sentinel is safe across independent compilations.
        pointee: *const Type,
        /// Struct id when pointee is `.aggregate`, 0 otherwise.
        struct_id: u32 = 0,
        /// True when `struct_id` is a valid index into `Checked.structs`.
        /// Needed because `struct_id == 0` is valid for the first struct.
        has_struct_id: bool = false,
    };

    /// Returns a static string representation of the type (`ptr<T>` for a
    /// known pointee). No allocation and no references to temporary storage.
    pub fn name(self: Type) []const u8 {
        return switch (self) {
            .i32 => "i32",
            .i64 => "i64",
            .i16 => "i16",
            .i8 => "i8",
            .u64 => "u64",
            .u32 => "u32",
            .u16 => "u16",
            .u8 => "u8",
            .usize => "usize",
            .bool => "bool",
            .void => "void",
            .aggregate => "struct",
            .str => "str",
            .enumeration => "enum",
            .unknown => "unknown",
            // Every returned slice must outlive this call. In particular, do
            // not return a slice of a stack-allocated formatting buffer: that
            // corrupts diagnostics for mismatched pointer types.
            .ptr => |pt| switch (pt.pointee.*) {
                .i8 => "ptr<i8>",
                .i16 => "ptr<i16>",
                .i32 => "ptr<i32>",
                .i64 => "ptr<i64>",
                .u8 => "ptr<u8>",
                .u16 => "ptr<u16>",
                .u32 => "ptr<u32>",
                .u64 => "ptr<u64>",
                .usize => "ptr<usize>",
                .bool => "ptr<bool>",
                .aggregate => "ptr<struct>",
                .ptr => "ptr<ptr>",
                .unknown => "ptr",
                else => "ptr<unsupported>",
            },
        };
    }

    pub fn fromName(text: []const u8) ?Type {
        if (std.mem.eql(u8, text, "i32")) return .i32;
        if (std.mem.eql(u8, text, "i64")) return .i64;
        if (std.mem.eql(u8, text, "i16")) return .i16;
        if (std.mem.eql(u8, text, "i8")) return .i8;
        if (std.mem.eql(u8, text, "u64")) return .u64;
        if (std.mem.eql(u8, text, "u32")) return .u32;
        if (std.mem.eql(u8, text, "u16")) return .u16;
        if (std.mem.eql(u8, text, "u8")) return .u8;
        if (std.mem.eql(u8, text, "usize")) return .usize;
        if (std.mem.eql(u8, text, "bool")) return .bool;
        if (std.mem.eql(u8, text, "void")) return .void;
        if (std.mem.eql(u8, text, "str")) return .str;
        if (std.mem.eql(u8, text, "ptr")) return ptrToUnknown();
        return null;
    }

    /// True when the type is a fixed-width integer (signed or unsigned).
    pub fn isInteger(self: Type) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .usize => true,
            else => false,
        };
    }

    /// Types that can exist as an expression/variable value. `str` is a
    /// slice (two slots), not a scalar, but it has a value: it can initialize,
    /// be copied, returned and passed as an argument. Pointers are values.
    pub fn isValue(self: Type) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .usize,
            .bool, .str,
            .ptr => true,
            else => false,
        };
    }

    /// Bit width of an integer type in bits; 0 for non-integers. Pointers
    /// are address-sized (64 bits on the current target).
    pub fn bitWidth(self: Type) u32 {
        return switch (self) {
            .i8, .u8 => 8,
            .i16, .u16 => 16,
            .i32, .u32 => 32,
            .i64, .u64, .usize => 64,
            .ptr => 64,
            else => 0,
        };
    }

    /// True when the type is signed.
    pub fn isSigned(self: Type) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64 => true,
            .u8, .u16, .u32, .u64 => false,
            else => false,
        };
    }

    /// Register words consumed by the calling convention: `str` takes two
    /// consecutive registers (pointer and length). 64-bit integers take two.
    /// Pointers take one register (address).
    pub fn registerWords(self: Type) usize {
        return switch (self) {
            .str => 2,
            .u64, .i64, .usize => 2,
            .ptr => 1,
            else => 1,
        };
    }

    /// True when this is a pointer type.
    pub fn isPtr(self: Type) bool {
        return switch (self) {
            .ptr => true,
            else => false,
        };
    }

    /// Structural equality: two types are equal when they have the same tag
    /// and, for pointers, the same pointee type.
    pub fn eq(self: Type, other: Type) bool {
        // Compare tags via discriminant. Same union type => same tag type.
        const self_tag = @tagName(self);
        const other_tag = @tagName(other);
        if (!std.mem.eql(u8, self_tag, other_tag)) return false;
        return switch (self) {
            .ptr => |a_pt| {
                const b_pt = other.ptr;
                return a_pt.pointee.eq(b_pt.pointee.*) and a_pt.struct_id == b_pt.struct_id and a_pt.has_struct_id == b_pt.has_struct_id;
            },
            else => true,
        };
    }
};

test "sema type metadata: generic pointer needs no checker initialization" {
    const generic = Type.fromName("ptr").?;
    try std.testing.expect(generic.isPtr());
    try std.testing.expectEqual(Type.unknown, generic.ptr.pointee.*);
    try std.testing.expectEqualStrings("ptr", generic.name());
}

test "sema type metadata: usize is a 64-bit unsigned integer" {
    const usize_type: Type = .usize;
    try std.testing.expectEqual(@as(u32, 64), usize_type.bitWidth());
    try std.testing.expect(!usize_type.isSigned());
    try std.testing.expectEqual(@as(usize, 2), usize_type.registerWords());
}

test "sema type metadata: signedness and widths match integer names" {
    const i8_type: Type = .i8;
    const u16_type: Type = .u16;
    const i32_type: Type = .i32;
    const i64_type: Type = .i64;
    const u64_type: Type = .u64;

    try std.testing.expectEqual(@as(u32, 8), i8_type.bitWidth());
    try std.testing.expectEqual(@as(u32, 16), u16_type.bitWidth());
    try std.testing.expectEqual(@as(u32, 32), i32_type.bitWidth());
    try std.testing.expectEqual(@as(u32, 64), u64_type.bitWidth());
    try std.testing.expect(i64_type.isSigned());
    try std.testing.expect(!u64_type.isSigned());
}

/// Generic `ptr` annotations have no known pointee. The sentinel is constant:
/// callers can resolve a pointer even before a Checker exists, and parallel
/// compilations never race while initializing pointer metadata.
const unknown_type: Type = .unknown;

fn ptrToUnknown() Type {
    return .{ .ptr = .{ .pointee = &unknown_type } };
}

/// A known pointer can be erased to `ptr<unknown>` at a generic boundary,
/// but an unknown pointer cannot be assigned to a known-pointee variable:
/// doing so would enable typed dereference without a pointee contract.
fn ptrTypesCompatible(expected: Type, actual: Type) bool {
    if (!expected.isPtr() or !actual.isPtr()) return false;
    // Compare full pointer types, including nominal struct identity.
    return expected.eq(actual) or expected.ptr.pointee.* == .unknown;
}

pub const SymbolKind = enum { param, local };

pub const Symbol = struct {
    name: []const u8,
    typ: Type,
    mutable: bool,
    /// Stack slot relative to the function (parameters first). For struct
    /// variables the fields occupy `slot + 1 .. slot + 1 + n`.
    slot: u32,
    kind: SymbolKind,
    decl_span: Span,
    /// Index into `Checked.structs` when `typ.eq(.aggregate)`. Valid only when
    /// `has_struct_id` is true (needed because `struct_id == 0` is a valid
    /// index for the first struct).
    struct_id: u32 = 0,
    has_struct_id: bool = false,
    /// Index into `Checked.enums` when `typ.eq(.enumeration)`.
    enum_id: u32 = 0,
};

/// Field of an already validated struct: scalar type and declaration index.
pub const FieldInfo = struct {
    name: []const u8,
    typ: Type,
    span: Span,
};

pub const StructInfo = struct {
    decl: *const ast.StructDecl,
    fields: []FieldInfo,
};

/// Case of an already validated enum: `payload` is `null` for a case without
/// a value and the payload type otherwise (only `i32` today).
pub const CaseInfo = struct {
    name: []const u8,
    name_span: Span,
    payload: ?Type,
    /// Value stored in the tag slot: the index in `EnumDecl.cases`, so the
    /// declaration order is part of the representation.
    tag: i32,
};

pub const EnumInfo = struct {
    decl: *const ast.EnumDecl,
    cases: []CaseInfo,
};

/// Owner of a function declaration, resolved from its `impl` block.
pub const Owner = union(enum) {
    /// Top-level `fn`.
    free,
    /// `impl` whose target type is not declared (already diagnosed).
    unresolved,
    struct_id: u32,
    enum_id: u32,

    pub fn isFree(self: Owner) bool {
        return switch (self) {
            .free => true,
            else => false,
        };
    }

    /// Declared inside `impl` and bound to a type.
    pub fn isMethod(self: Owner) bool {
        return switch (self) {
            .struct_id, .enum_id => true,
            else => false,
        };
    }
};

/// Type a method belongs to, used to resolve `value.method(...)`.
pub const MethodOwner = union(enum) {
    struct_id: u32,
    enum_id: u32,
};

pub const FunctionInfo = struct {
    decl: *const ast.Function,
    /// True when the function was declared inside `impl` (whether or not the
    /// target type resolved). Methods live in a name space per type: they never
    /// answer a free call and never take part in the `main` check.
    is_method: bool = false,
    /// Struct the method belongs to (`null` for a free function and for a method
    /// of an enum).
    owner_struct_id: ?u32 = null,
    /// Enum the method belongs to (`null` otherwise).
    owner_enum_id: ?u32 = null,
    /// Symbol name used by both backends: the declared name for a free function,
    /// `Type_method` for a method (deterministic, unique per type).
    symbol_name: []const u8 = "",
    return_type: Type,
    /// Struct tied to the return when `return_type.eq(.aggregate)`.
    return_struct_id: u32 = 0,
    params: []Type,
    /// Struct tied to each parameter (0 when the parameter is not a struct).
    param_struct_ids: []u32 = &.{},
    /// Enum tied to each parameter (0 when the parameter is not an enum).
    param_enum_ids: []u32 = &.{},
    /// Enum tied to the return when `return_type.eq(.enumeration)`.
    return_enum_id: u32 = 0,
    /// Number of stack slots used by the function (parameters + locals).
    slot_count: u32,
    /// Symbol range of this function in `Checked.symbols`
    /// (parameters first, then local variables).
    symbol_start: u32 = 0,
    symbol_count: u32 = 0,

    pub fn isMethod(self: FunctionInfo) bool {
        return self.is_method;
    }
};

pub const Checked = struct {
    functions: []FunctionInfo,
    /// Flat table; `Expr.resolved` and `Stmt.decl_symbol` index this slice.
    symbols: []Symbol,
    /// Declared structs, in source order (flattened across modules).
    structs: []StructInfo,
    /// Declared enums, in source order (flattened across modules).
    enums: []EnumInfo = &.{},

    pub fn findStruct(self: *const Checked, name: []const u8) ?u32 {
        for (self.structs, 0..) |info, i| {
            if (std.mem.eql(u8, info.decl.name, name)) return @intCast(i);
        }
        return null;
    }

    pub fn findEnum(self: *const Checked, name: []const u8) ?u32 {
        for (self.enums, 0..) |info, i| {
            if (std.mem.eql(u8, info.decl.name, name)) return @intCast(i);
        }
        return null;
    }

    /// Free function by name. Methods live in their own name space and are
    /// reached through `findMethod`/`Expr.MethodCall.resolved_fn`.
    pub fn findFunction(self: *const Checked, name: []const u8) ?u32 {
        for (self.functions, 0..) |f, i| {
            if (f.is_method) continue;
            if (std.mem.eql(u8, f.decl.name, name)) return @intCast(i);
        }
        return null;
    }

    /// Method of `owner` (a struct or enum index) named `name`.
    pub fn findMethod(self: *const Checked, owner: MethodOwner, name: []const u8) ?u32 {
        for (self.functions, 0..) |f, i| {
            if (!f.is_method) continue;
            if (!std.mem.eql(u8, f.decl.name, name)) continue;
            const matches = switch (owner) {
                .struct_id => |id| f.owner_struct_id == id,
                .enum_id => |id| f.owner_enum_id == id,
            };
            if (matches) return @intCast(i);
        }
        return null;
    }
};

/// Register words a type occupies in the calling convention: each scalar
/// struct field counts one, `str` counts two (pointer and length) and the
/// remaining scalars one. Single source for the semantics limit and for the
/// backends — so declaration, call and code emission never diverge.
pub fn registerWordsOf(structs: []const StructInfo, typ: Type, struct_id: u32) usize {
    if (typ.eq(.aggregate) and struct_id < structs.len) return structs[struct_id].fields.len;
    // An enum is a tag plus a payload slot, never a single register.
    if (typ.eq(.enumeration)) return 2;
    return typ.registerWords();
}

/// Limit of argument **registers** per call in the x86-64 backend
/// (SysV). It is not a parameter limit: each `str` consumes two
/// (`Type.registerWords`), so three `str` fill the table.
pub const max_arg_registers: usize = 6;

pub const Options = struct {
    /// Requires the program to define `fn main() -> i32` or `fn main() -> void`.
    require_main: bool = true,
    /// Path of each file, indexed by `ast.Function.file_id`. Used in
    /// messages to disambiguate declarations coming from imported modules.
    file_names: []const []const u8 = &.{},
};

pub const Checker = struct {
    arena: std.mem.Allocator,
    diags: *diagnostics.List,
    options: Options,

    symbols: std.ArrayList(Symbol) = .empty,
    functions: std.ArrayList(FunctionInfo) = .empty,
    structs: std.ArrayList(StructInfo) = .empty,
    enums: std.ArrayList(EnumInfo) = .empty,
    /// Start (index into `symbols`) of the current scope.
    scopes: std.ArrayList(usize) = .empty,

    fn_index: u32 = 0,
    fn_symbol_start: usize = 0,
    next_slot: u32 = 0,
    current_return: Type = .void,

    pub fn init(arena: std.mem.Allocator, diags: *diagnostics.List, options: Options) Checker {
        return .{ .arena = arena, .diags = diags, .options = options };
    }

    pub fn checkProgram(self: *Checker, program: *const ast.Program) std.mem.Allocator.Error!Checked {
        // Step 0: struct names before any type is resolved.
        for (program.structs) |decl| {
            self.diags.current_file = decl.file_id;
            try self.registerStructName(decl);
        }
        // Step 0b: enum names and cases, so that `resolveTypeName` can point
        // at them and `switch` can be checked.
        for (program.enums) |decl| {
            self.diags.current_file = decl.file_id;
            try self.registerEnum(decl);
        }

        for (program.structs) |decl| {
            self.diags.current_file = decl.file_id;
            try self.registerStructFields(decl);
        }

        // Step 0c: `impl` blocks must target a declared type, so that method
        // signatures can resolve their receiver.
        for (program.impls) |block| {
            self.diags.current_file = block.file_id;
            try self.checkImplTarget(block);
        }

        // Step 1: register signatures (allows calls before the declaration
        // and recursion).
        for (program.functions) |func| {
            self.diags.current_file = func.file_id;
            try self.registerFunction(func);
        }

        if (self.options.require_main) {
            try self.checkMain(program);
        }

        // Step 2: check bodies.
        for (program.functions, 0..) |func, i| {
            self.diags.current_file = func.file_id;
            try self.checkFunctionBody(func, @intCast(i));
        }
        self.diags.current_file = 0;

        return .{
            .functions = try self.functions.toOwnedSlice(self.arena),
            .symbols = try self.symbols.toOwnedSlice(self.arena),
            .structs = try self.structs.toOwnedSlice(self.arena),
            .enums = try self.enums.toOwnedSlice(self.arena),
        };
    }

    fn findStructIndex(self: *const Checker, name: []const u8) ?u32 {
        for (self.structs.items, 0..) |info, i| {
            if (std.mem.eql(u8, info.decl.name, name)) return @intCast(i);
        }
        return null;
    }

    fn findEnumIndex(self: *const Checker, name: []const u8) ?u32 {
        for (self.enums.items, 0..) |info, i| {
            if (std.mem.eql(u8, info.decl.name, name)) return @intCast(i);
        }
        return null;
    }

    /// Enum pass: unique name (against structs and enums), unique cases and a
    /// supported payload type. Tags follow the declaration order.
    fn registerEnum(self: *Checker, decl: *const ast.EnumDecl) std.mem.Allocator.Error!void {
        if (self.findEnumIndex(decl.name) != null or self.findStructIndex(decl.name) != null) {
            try self.diags.add(
                .duplicate_declaration,
                decl.name_span,
                "enum '{s}' already declared as a struct or enum",
                .{decl.name},
            );
            return;
        }

        if (decl.cases.len == 0) {
            try self.diags.add(
                .unsupported,
                decl.name_span,
                "enum '{s}' with no cases is not supported at this stage",
                .{decl.name},
            );
        }

        const cases = try self.arena.alloc(CaseInfo, decl.cases.len);
        for (decl.cases, 0..) |case, i| {
            for (decl.cases[0..i]) |previous| {
                if (std.mem.eql(u8, previous.name, case.name)) {
                    try self.diags.add(
                        .duplicate_declaration,
                        case.name_span,
                        "case '{s}' already declared in enum '{s}' (line {d})",
                        .{ case.name, decl.name, previous.name_span.line },
                    );
                    break;
                }
            }

            var payload: ?Type = null;
            if (case.payload) |tn| {
                const typ = try self.resolveTypeName(tn);
                if (typ.eq(.i32)) {
                    payload = .i32;
                } else if (!typ.eq(.unknown)) {
                    try self.diags.add(
                        .unsupported,
                        tn.span,
                        "case '{s}' of '{s}': payload type '{s}' is not supported yet (only 'i32')",
                        .{ case.name, decl.name, tn.name },
                    );
                }
            }

            cases[i] = .{
                .name = case.name,
                .name_span = case.name_span,
                .payload = payload,
                .tag = @intCast(i),
            };
        }

        try self.enums.append(self.arena, .{ .decl = decl, .cases = cases });
    }

    /// Index of the case inside the enum, by name.
    fn findCaseIndex(info: *const EnumInfo, name: []const u8) ?u32 {
        for (info.cases, 0..) |case, i| {
            if (std.mem.eql(u8, case.name, name)) return @intCast(i);
        }
        return null;
    }

    /// First struct pass: guarantees unique names so that any
    /// declaration can be referenced by types resolved later.
    fn registerStructName(self: *Checker, decl: *const ast.StructDecl) std.mem.Allocator.Error!void {
        if (self.findEnumIndex(decl.name) != null) {
            try self.diags.add(
                .duplicate_declaration,
                decl.name_span,
                "struct '{s}' already declared as an enum",
                .{decl.name},
            );
            return;
        }
        for (self.structs.items) |existing| {
            if (std.mem.eql(u8, existing.decl.name, decl.name)) {
                if (self.fileName(existing.decl.file_id)) |path| {
                    try self.diags.add(
                        .duplicate_declaration,
                        decl.name_span,
                        "struct '{s}' already declared in '{s}' (line {d})",
                        .{ decl.name, path, existing.decl.name_span.line },
                    );
                } else {
                    try self.diags.add(
                        .duplicate_declaration,
                        decl.name_span,
                        "struct '{s}' already declared (first declaration on line {d})",
                        .{ decl.name, existing.decl.name_span.line },
                    );
                }
                return;
            }
        }

        try self.structs.append(self.arena, .{ .decl = decl, .fields = &.{} });
    }

    /// Second pass: resolves field types (scalars only at this
    /// stage) and validates duplicates.
    fn registerStructFields(self: *Checker, decl: *const ast.StructDecl) std.mem.Allocator.Error!void {
        const index = self.findStructIndex(decl.name) orelse return;
        // A duplicated declaration (already diagnosed) shares its name with the
        // first one; it does not overwrite its fields.
        if (self.structs.items[index].decl != decl) return;

        if (decl.fields.len == 0) {
            try self.diags.add(
                .unsupported,
                decl.name_span,
                "struct '{s}' with no fields is not supported at this stage",
                .{decl.name},
            );
        }

        const fields = try self.arena.alloc(FieldInfo, decl.fields.len);
        for (decl.fields, 0..) |field, i| {
            for (decl.fields[0..i]) |previous| {
                if (std.mem.eql(u8, previous.name, field.name)) {
                    try self.diags.add(
                        .duplicate_declaration,
                        field.name_span,
                        "field '{s}' already declared in struct '{s}' (line {d})",
                        .{ field.name, decl.name, previous.name_span.line },
                    );
                    break;
                }
            }

            const typ = try self.resolveTypeName(field.type_name);
            if (typ.eq(.aggregate)) {
                try self.diags.add(
                    .unsupported,
                    field.type_name.span,
                    "field '{s}' of '{s}': a struct with a struct field is not supported yet",
                    .{ field.name, decl.name },
                );
            } else if (typ.eq(.str)) {
                try self.diags.add(
                    .unsupported,
                    field.type_name.span,
                    "field '{s}' of '{s}' of type 'str' is not supported yet",
                    .{ field.name, decl.name },
                );
            } else if (typ.eq(.enumeration)) {
                try self.diags.add(
                    .unsupported,
                    field.type_name.span,
                    "field '{s}' of '{s}' of enum type is not supported yet",
                    .{ field.name, decl.name },
                );
            } else if (typ.eq(.void)) {
                try self.diags.add(
                    .type_mismatch,
                    field.type_name.span,
                    "field '{s}' of '{s}' cannot be 'void'",
                    .{ field.name, decl.name },
                );
            }

            fields[i] = .{ .name = field.name, .typ = typ, .span = field.span };
        }

        self.structs.items[index].fields = fields;
    }

    /// File path of a symbol, when known and different from the
    /// current file (avoids noise in single-file programs).
    fn fileName(self: *const Checker, file_id: u32) ?[]const u8 {
        if (file_id == self.diags.current_file) return null;
        if (file_id >= self.options.file_names.len) return null;
        return self.options.file_names[file_id];
    }

    /// `impl` target as a nominal index: a struct, an enum or `null` when the
    /// name is not declared (already diagnosed).
    fn implTarget(self: *const Checker, block: *const ast.ImplBlock) Owner {
        if (self.findStructIndex(block.type_name.name)) |id| return .{ .struct_id = id };
        if (self.findEnumIndex(block.type_name.name)) |id| return .{ .enum_id = id };
        return .unresolved;
    }

    fn checkImplTarget(self: *Checker, block: *const ast.ImplBlock) std.mem.Allocator.Error!void {
        switch (self.implTarget(block)) {
            .unresolved => try self.diags.add(
                .unknown_type,
                block.type_name.span,
                "impl target '{s}' is not a declared struct or enum",
                .{block.type_name.name},
            ),
            else => {},
        }
    }

    /// Owner of a function declaration: `.free` for a top-level `fn`, the
    /// struct/enum of its `impl` block otherwise (`.unresolved` when that name is
    /// not declared, already diagnosed at the block).
    fn ownerOfFunction(self: *const Checker, func: *const ast.Function) Owner {
        const target = func.owner_type orelse return .free;
        if (self.findStructIndex(target.name)) |id| return .{ .struct_id = id };
        if (self.findEnumIndex(target.name)) |id| return .{ .enum_id = id };
        return .unresolved;
    }

    /// Name of the owner type, for messages.
    fn ownerName(self: *const Checker, owner: Owner) []const u8 {
        return switch (owner) {
            .struct_id => |id| self.structs.items[id].decl.name,
            .enum_id => |id| self.enums.items[id].decl.name,
            .free, .unresolved => "",
        };
    }

    /// Nominal label of a value type: the struct/enum name when known, the
    /// generic type name otherwise.
    fn nominalLabel(self: *const Checker, typ: Type, struct_id: u32, enum_id: u32) []const u8 {
        if (typ.eq(.aggregate) and struct_id < self.structs.items.len) {
            return self.structs.items[struct_id].decl.name;
        }
        if (typ.eq(.enumeration) and enum_id < self.enums.items.len) {
            return self.enums.items[enum_id].decl.name;
        }
        return typ.name();
    }

    fn registerFunction(self: *Checker, func: *const ast.Function) std.mem.Allocator.Error!void {
        const owner = self.ownerOfFunction(func);
        // Methods are mangled `Type_method`: unique per type, never equal to a
        // free function name unless the source spells it that way.
        const symbol_name: []const u8 = switch (owner) {
            .free, .unresolved => func.name,
            .struct_id, .enum_id => try std.fmt.allocPrint(
                self.arena,
                "{s}_{s}",
                .{ self.ownerName(owner), func.name },
            ),
        };

        if (owner.isFree()) {
            // Builtin names are reserved: declaring another function with the
            // same name would create two resolution rules for the same call.
            if (builtinByName(func.name) != null) {
                try self.diags.add(
                    .unsupported,
                    func.name_span,
                    "name '{s}' is reserved for the builtin function",
                    .{func.name},
                );
            }

            for (self.functions.items) |existing| {
                // A method is mangled `Type_method`, so a free function may carry
                // the same symbol; report it instead of emitting two labels.
                if (existing.is_method) {
                    if (!std.mem.eql(u8, existing.symbol_name, func.name)) continue;
                    try self.diags.add(
                        .duplicate_declaration,
                        func.name_span,
                        "function '{s}' shares the symbol 'kyn_{s}' with the method '{s}' (line {d}); rename one of them",
                        .{ func.name, existing.symbol_name, existing.decl.name, existing.decl.name_span.line },
                    );
                    break;
                }
                if (std.mem.eql(u8, existing.decl.name, func.name)) {
                    if (self.fileName(existing.decl.file_id)) |path| {
                        try self.diags.add(
                            .duplicate_declaration,
                            func.name_span,
                            "function '{s}' already declared in '{s}' (line {d})",
                            .{ func.name, path, existing.decl.name_span.line },
                        );
                    } else {
                        try self.diags.add(
                            .duplicate_declaration,
                            func.name_span,
                            "function '{s}' already declared (first declaration on line {d})",
                            .{ func.name, existing.decl.name_span.line },
                        );
                    }
                    break;
                }
            }
        } else {
            try self.checkMethodDeclaration(func, owner, symbol_name);
        }

        const params = try self.arena.alloc(Type, func.params.len);
        const param_struct_ids = try self.arena.alloc(u32, func.params.len);
        const param_enum_ids = try self.arena.alloc(u32, func.params.len);
        // Provisional index: signatures are appended in source order.
        var register_words: usize = 0;
        for (func.params, 0..) |param, i| {
            params[i] = try self.resolveTypeName(param.type_name);
            param_struct_ids[i] = self.structIdOfTypeName(param.type_name) orelse 0;
            param_enum_ids[i] = self.enumIdOfTypeName(param.type_name) orelse 0;
            register_words += self.wordsOf(params[i], param_struct_ids[i]);
        }

        // The receiver is the first parameter: it must be `self` of the owner
        // type, so `value.method()` always passes a value of the right type.
        if (owner.isMethod() and !std.mem.eql(u8, func.name, "main")) {
            if (func.params.len == 0) {
                try self.checkMethodReceiver(func, owner, .unknown, 0, 0);
            } else {
                try self.checkMethodReceiver(
                    func,
                    owner,
                    params[0],
                    param_struct_ids[0],
                    param_enum_ids[0],
                );
            }
        }

        // The native backend limit is in registers, not in parameters:
        // each `str` consumes two and each struct field one.
        const kind_label: []const u8 = if (owner.isMethod()) "method" else "function";
        const display: []const u8 = if (owner.isMethod())
            try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ self.ownerName(owner), func.name })
        else
            func.name;
        if (register_words > max_arg_registers) {
            try self.diags.add(
                .unsupported,
                func.name_span,
                "{s} '{s}' uses {d} parameter registers; the current backend supports at most {d} ('str' and an enum take two, each struct field one)",
                .{ kind_label, display, register_words, max_arg_registers },
            );
        }

        const return_type: Type = if (func.return_type) |tn|
            try self.resolveTypeName(tn)
        else
            .void;
        const return_struct_id: u32 = if (func.return_type) |tn|
            self.structIdOfTypeName(tn) orelse 0
        else
            0;

        const return_enum_id: u32 = if (func.return_type) |tn|
            self.enumIdOfTypeName(tn) orelse 0
        else
            0;

        // A struct returns in one register per field, in declaration order.
        if (return_type.eq(.aggregate) and return_struct_id < self.structs.items.len) {
            const field_count = self.structs.items[return_struct_id].fields.len;
            if (field_count > max_arg_registers) {
                try self.diags.add(
                    .unsupported,
                    func.return_type.?.span,
                    "{s} '{s}' returns a struct with {d} fields; the current backend supports at most {d}",
                    .{ kind_label, display, field_count, max_arg_registers },
                );
            }
        }

        try self.functions.append(self.arena, .{
            .decl = func,
            .is_method = func.owner_type != null,
            .owner_struct_id = switch (owner) {
                .struct_id => |id| id,
                else => null,
            },
            .owner_enum_id = switch (owner) {
                .enum_id => |id| id,
                else => null,
            },
            .symbol_name = symbol_name,
            .return_type = return_type,
            .return_struct_id = return_struct_id,
            .params = params,
            .param_struct_ids = param_struct_ids,
            .param_enum_ids = param_enum_ids,
            .return_enum_id = return_enum_id,
            .slot_count = 0,
        });
    }

    /// Declaration rules of a method: reserved entry point, symbol/field
    /// clashes and a unique name per type. The receiver shape is validated
    /// later, once the parameter types are resolved.
    fn checkMethodDeclaration(
        self: *Checker,
        func: *const ast.Function,
        owner: Owner,
        symbol_name: []const u8,
    ) std.mem.Allocator.Error!void {
        const owner_name = self.ownerName(owner);

        if (std.mem.eql(u8, func.name, "main")) {
            try self.diags.add(
                .unsupported,
                func.name_span,
                "method 'main' is not supported; declare 'fn main()' outside the 'impl'",
                .{},
            );
        }

        for (self.functions.items) |existing| {
            if (!std.mem.eql(u8, existing.symbol_name, symbol_name)) continue;
            if (existing.is_method) {
                try self.diags.add(
                    .duplicate_declaration,
                    func.name_span,
                    "method '{s}' already declared for '{s}' (line {d})",
                    .{ func.name, owner_name, existing.decl.name_span.line },
                );
            } else {
                try self.diags.add(
                    .duplicate_declaration,
                    func.name_span,
                    "method '{s}.{s}' shares the symbol 'kyn_{s}' with the function '{s}' (line {d}); rename one of them",
                    .{ owner_name, func.name, symbol_name, existing.decl.name, existing.decl.name_span.line },
                );
            }
            break;
        }

        // `value.name` and `value.name()` would be ambiguous to read.
        if (owner == .struct_id) {
            const id = owner.struct_id;
            if (id < self.structs.items.len) {
                for (self.structs.items[id].fields) |field| {
                    if (!std.mem.eql(u8, field.name, func.name)) continue;
                    try self.diags.add(
                        .duplicate_declaration,
                        func.name_span,
                        "struct '{s}' already has a field '{s}'; a method cannot reuse the name",
                        .{ owner_name, field.name },
                    );
                    break;
                }
            }
        }
    }

    /// The first parameter of a method is its receiver: it must be named `self`
    /// and have exactly the owner type (methods are nominal, like the values).
    fn checkMethodReceiver(
        self: *Checker,
        func: *const ast.Function,
        owner: Owner,
        receiver_type: Type,
        receiver_struct_id: u32,
        receiver_enum_id: u32,
    ) std.mem.Allocator.Error!void {
        const owner_name = self.ownerName(owner);
        if (func.params.len == 0) {
            try self.diags.add(
                .invalid_method,
                func.name_span,
                "method '{s}.{s}' must declare its receiver: 'self: {s}' as the first parameter",
                .{ owner_name, func.name, owner_name },
            );
            return;
        }

        const receiver = func.params[0];
        if (!std.mem.eql(u8, receiver.name, "self")) {
            try self.diags.add(
                .invalid_method,
                receiver.span,
                "the first parameter of method '{s}.{s}' must be named 'self', found '{s}'",
                .{ owner_name, func.name, receiver.name },
            );
        }

        const matches = switch (owner) {
            .struct_id => |id| receiver_type.eq(.aggregate) and receiver_struct_id == id,
            .enum_id => |id| receiver_type.eq(.enumeration) and receiver_enum_id == id,
            .free, .unresolved => true,
        };
        if (!matches) {
            try self.diags.add(
                .invalid_method,
                receiver.span,
                "parameter 'self' of method '{s}.{s}' must have type '{s}', found '{s}'",
                .{ owner_name, func.name, owner_name, self.nominalLabel(receiver_type, receiver_struct_id, receiver_enum_id) },
            );
        }
    }

    fn checkMain(self: *Checker, program: *const ast.Program) std.mem.Allocator.Error!void {
        var main_fn: ?*const ast.Function = null;
        for (program.functions) |func| {
            // A method named `main` is diagnosed separately and never satisfies
            // the entry point.
            if (func.owner_type != null) continue;
            if (std.mem.eql(u8, func.name, "main")) {
                main_fn = func;
                break;
            }
        }
        self.diags.current_file = if (main_fn) |main| main.file_id else 0;

        const main = main_fn orelse {
            try self.diags.add(
                .missing_main,
                program.span,
                "program does not define 'fn main()'",
                .{},
            );
            return;
        };

        if (main.params.len != 0) {
            try self.diags.add(
                .invalid_main,
                main.name_span,
                "'main' cannot take parameters at this stage",
                .{},
            );
        }

        const ret = if (main.return_type) |tn| Type.fromName(tn.name) orelse .unknown else .void;
        if (!ret.eq(.i32) and !ret.eq(.void) and !ret.eq(.unknown)) {
            try self.diags.add(
                .invalid_main,
                main.return_type.?.span,
                "'main' must return 'i32' or 'void', found '{s}'",
                .{main.return_type.?.name},
            );
        }
    }

    fn resolveTypeName(self: *Checker, tn: ast.TypeName) std.mem.Allocator.Error!Type {
        if (Type.fromName(tn.name)) |typ| return typ;
        if (self.findStructIndex(tn.name) != null) return .aggregate;
        if (self.findEnumIndex(tn.name) != null) return .enumeration;
        try self.diags.add(
            .unknown_type,
            tn.span,
            "unsupported type '{s}' (available: i32, bool, str, void, declared structs and enums)",
            .{tn.name},
        );
        return .unknown;
    }

    /// Register words of a value whose type depends on the concrete
    /// struct (see `registerWordsOf`, also used by the backends).
    fn wordsOf(self: *const Checker, typ: Type, struct_id: u32) usize {
        return registerWordsOf(self.structs.items, typ, struct_id);
    }

    /// Struct tied to the annotated type, when present.
    fn structIdOfTypeName(self: *const Checker, tn: ast.TypeName) ?u32 {
        return self.findStructIndex(tn.name);
    }

    /// Struct tied to an expression producing a struct value.
    fn structIdOfExpr(self: *const Checker, expr: *const ast.Expr) ?u32 {
        if (expr.kind == .unary) {
            const unary = expr.kind.unary;
            if (unary.op == .address_of and unary.operand.kind == .identifier) {
                if (unary.operand.resolved) |idx| {
                    const sym = self.symbols.items[idx];
                    if (sym.has_struct_id) return sym.struct_id;
                }
            }
        }
        return switch (expr.kind) {
            .struct_literal => |lit| lit.resolved_struct,
            .identifier => if (expr.resolved) |idx| blk: {
                const sym = self.symbols.items[idx];
                break :blk if (sym.has_struct_id) sym.struct_id else null;
            } else null,
            .call => |call| if (call.callee_fn) |index| blk: {
                const func = self.functions.items[index];
                break :blk if (func.return_type.eq(.aggregate)) func.return_struct_id else null;
            } else null,
            .method_call => |call| if (call.resolved_fn) |index| blk: {
                const func = self.functions.items[index];
                break :blk if (func.return_type.eq(.aggregate)) func.return_struct_id else null;
            } else null,
            else => null,
        };
    }

    /// Enum tied to the annotated type, when present.
    fn enumIdOfTypeName(self: *const Checker, tn: ast.TypeName) ?u32 {
        return self.findEnumIndex(tn.name);
    }

    /// Enum tied to an expression producing an enum value.
    fn enumIdOfExpr(self: *const Checker, expr: *const ast.Expr) ?u32 {
        return switch (expr.kind) {
            .identifier => if (expr.resolved) |idx| blk: {
                const sym = self.symbols.items[idx];
                break :blk if (sym.typ.eq(.enumeration)) sym.enum_id else null;
            } else null,
            .field_access => |access| access.resolved_enum,
            // A constructor carries `resolved_enum`; a method call that returns
            // an enum carries the method, whose return names the enum.
            .method_call => |call| if (call.resolved_fn) |index| blk: {
                const func = self.functions.items[index];
                break :blk if (func.return_type.eq(.enumeration)) func.return_enum_id else null;
            } else call.resolved_enum,
            .call => |call| if (call.callee_fn) |index| blk: {
                const func = self.functions.items[index];
                break :blk if (func.return_type.eq(.enumeration)) func.return_enum_id else null;
            } else null,
            else => null,
        };
    }

    fn checkFunctionBody(self: *Checker, func: *const ast.Function, index: u32) std.mem.Allocator.Error!void {
        const info = &self.functions.items[index];
        self.fn_index = index;
        self.fn_symbol_start = self.symbols.items.len;
        self.next_slot = 0;
        self.current_return = info.return_type;
        self.scopes.clearRetainingCapacity();

        try self.pushScope();
        defer self.scopes.clearRetainingCapacity();

        for (func.params) |param| {
            const typ = try self.resolveTypeName(param.type_name);
            const struct_id = self.structIdOfTypeName(param.type_name) orelse 0;
            const enum_id = self.enumIdOfTypeName(param.type_name) orelse 0;
            _ = try self.declare(param.name, param.span, typ, false, .param, struct_id, typ.eq(.aggregate), enum_id);
        }

        try self.checkStatements(func.body);

        if (info.return_type.isValue() and !alwaysReturns(func.body)) {
            try self.diags.add(
                .invalid_return,
                func.name_span,
                "function '{s}' may finish without running 'return' with value '{s}'",
                .{ func.name, info.return_type.name() },
            );
        }

        self.finishFunction(index);
    }

    fn finishFunction(self: *Checker, index: u32) void {
        const info = &self.functions.items[index];
        info.slot_count = self.next_slot;
        info.symbol_start = @intCast(self.fn_symbol_start);
        info.symbol_count = @intCast(self.symbols.items.len - self.fn_symbol_start);
        self.fn_symbol_start = self.symbols.items.len;
    }

    fn pushScope(self: *Checker) std.mem.Allocator.Error!void {
        try self.scopes.append(self.arena, self.symbols.items.len);
    }

    fn popScope(self: *Checker) void {
        _ = self.scopes.pop();
    }

    fn declare(
        self: *Checker,
        name: []const u8,
        span: Span,
        typ: Type,
        mutable: bool,
        kind: SymbolKind,
        struct_id: u32,
        has_struct_id: bool,
        enum_id: u32,
    ) !?u32 {
        if (self.scopes.items.len > 0) {
            const start = self.scopes.items[self.scopes.items.len - 1];
            for (self.symbols.items[start..]) |sym| {
                if (std.mem.eql(u8, sym.name, name)) {
                    try self.diags.add(
                        .duplicate_declaration,
                        span,
                        "'{s}' is already declared in this scope (line {d})",
                        .{ name, sym.decl_span.line },
                    );
                    return null;
                }
            }
        }

        // A struct value occupies one base slot (unused) and one slot per
        // field, in declaration order — the same mapping in both backends.
        // `str` occupies two consecutive slots: pointer and length.
        const extra_slots: u32 = if (typ.eq(.aggregate) and struct_id < self.structs.items.len)
            @intCast(self.structs.items[struct_id].fields.len)
        else if (typ.eq(.str) or typ.eq(.enumeration))
            1
        else
            0;

        const slot = self.next_slot;
        self.next_slot += 1 + extra_slots;
        try self.symbols.append(self.arena, .{
            .name = name,
            .typ = typ,
            .mutable = mutable,
            .slot = slot,
            .kind = kind,
            .decl_span = span,
            .struct_id = struct_id,
            .has_struct_id = has_struct_id,
            .enum_id = enum_id,
        });
        return @intCast(self.symbols.items.len - 1);
    }

    /// Resolves the base of a field access (today only a plain identifier).
    fn resolveFieldBase(self: *Checker, base: *ast.Expr) std.mem.Allocator.Error!?u32 {
        switch (base.kind) {
            .identifier => |name| {
                const index = self.lookup(name) orelse {
                    try self.diags.add(
                        .undefined_variable,
                        base.span,
                        "variable '{s}' is not declared",
                        .{name},
                    );
                    return null;
                };
                base.resolved = index;
                return index;
            },
            else => {
                try self.diags.add(
                    .unsupported,
                    base.span,
                    "chained field access (struct with a struct field) is not supported yet",
                    .{},
                );
                return null;
            },
        }
    }

    /// Type label for messages: the struct name when applicable.
    fn typeLabel(self: *const Checker, typ: Type, struct_id: u32) []const u8 {
        if (typ.eq(.aggregate) and struct_id < self.structs.items.len) {
            return self.structs.items[struct_id].decl.name;
        }
        if (typ.isPtr() and typ.ptr.pointee.* == .aggregate and typ.ptr.has_struct_id and
            typ.ptr.struct_id < self.structs.items.len)
        {
            return std.fmt.allocPrint(self.arena, "ptr<{s}>", .{
                self.structs.items[typ.ptr.struct_id].decl.name,
            }) catch typ.name();
        }
        return typ.name();
    }

    /// Short expression text used in messages (field bases are names).
    fn exprText(self: *const Checker, expr: *const ast.Expr) []const u8 {
        _ = self;
        return switch (expr.kind) {
            .identifier => |name| name,
            else => "<expression>",
        };
    }

    fn lookup(self: *const Checker, name: []const u8) ?u32 {
        var i = self.symbols.items.len;
        while (i > self.fn_symbol_start) {
            i -= 1;
            if (std.mem.eql(u8, self.symbols.items[i].name, name)) return @intCast(i);
        }
        return null;
    }

    fn checkStatements(self: *Checker, stmts: []*ast.Stmt) std.mem.Allocator.Error!void {
        for (stmts) |stmt| try self.checkStatement(stmt);
    }

    fn checkScopedBlock(self: *Checker, stmts: []*ast.Stmt) std.mem.Allocator.Error!void {
        try self.pushScope();
        defer self.popScope();
        try self.checkStatements(stmts);
    }

    fn checkStatement(self: *Checker, stmt: *ast.Stmt) std.mem.Allocator.Error!void {
        switch (stmt.kind) {
            .let_decl => |*decl| {
                const init_type = try self.checkExpr(decl.init);
                var declared_type: Type = init_type;
                var declared_struct: u32 = 0;
                if (decl.type_name) |tn| {
                    declared_type = try self.resolveTypeName(tn);
                    declared_struct = self.structIdOfTypeName(tn) orelse 0;
                    // `ptr` is an unspecified pointer annotation, not an
                    // instruction to forget the known pointee of `&x`.
                    // Retain it for dereference width and struct identity.
                    if (declared_type.isPtr() and init_type.isPtr() and declared_type.ptr.pointee.* == .unknown) {
                        declared_type = init_type;
                    }
                }
                const init_struct_opt = self.structIdOfExpr(decl.init);
                const init_struct: u32 = init_struct_opt orelse 0;

                // `void` is not storable — neither annotated (`let x: void = ...`)
                // nor inferred from a call without a return (`let x = f();`).
                // A single message covers both cases; the variable never reaches
                // the backends with a type that has no representation.
                if (declared_type.eq(.void) or init_type.eq(.void)) {
                    try self.diags.add(
                        .type_mismatch,
                        decl.name_span,
                        "variable '{s}' needs a value: 'void' cannot be stored",
                        .{decl.name},
                    );
                } else if (!declared_type.eq(.unknown) and !init_type.eq(.unknown) and !declared_type.eq(init_type) and !ptrTypesCompatible(declared_type, init_type)) {
                    try self.diags.add(
                        .type_mismatch,
                        decl.init.span,
                        "initializer of '{s}' has type '{s}', but the annotation is '{s}'",
                        .{ decl.name, self.typeLabel(init_type, init_struct), self.typeLabel(declared_type, declared_struct) },
                    );
                }

                // Same `struct` type, different structs.
                if (decl.type_name != null and declared_type.eq(.aggregate) and init_type.eq(.aggregate)) {
                    if (init_struct != declared_struct) {
                        try self.diags.add(
                            .type_mismatch,
                            decl.init.span,
                            "initializer of '{s}' is struct '{s}', but the annotation is '{s}'",
                            .{
                                decl.name,
                                self.structs.items[init_struct].decl.name,
                                self.structs.items[declared_struct].decl.name,
                            },
                        );
                    }
                }

                // Same `enum` type, different enums (nominal identity).
                const init_enum = self.enumIdOfExpr(decl.init);
                const declared_enum: u32 = if (decl.type_name) |tn|
                    self.enumIdOfTypeName(tn) orelse 0
                else
                    0;
                if (decl.type_name != null and declared_type.eq(.enumeration) and init_type.eq(.enumeration)) {
                    if (init_enum != null and init_enum.? != declared_enum) {
                        try self.diags.add(
                            .type_mismatch,
                            decl.init.span,
                            "initializer of '{s}' is enum '{s}', but the annotation is '{s}'",
                            .{
                                decl.name,
                                self.enums.items[init_enum.?].decl.name,
                                self.enums.items[declared_enum].decl.name,
                            },
                        );
                    }
                }

                // Struct variable without annotation: the struct comes from the initializer.
                // For pointer types, take the struct_id from the initializer (e.g. &struct_var).
                const init_has_struct: bool = init_struct_opt != null;
                const struct_id: u32 = if (!declared_type.eq(.aggregate) and !declared_type.isPtr())
                    0
                else if (declared_type.isPtr() and init_has_struct)
                    init_struct
                else if (decl.type_name != null)
                    declared_struct
                else
                    init_struct;



                // Same rule for enums: without annotation the enum comes from
                // the initializer.
                const enum_id: u32 = if (!declared_type.eq(.enumeration))
                    0
                else if (decl.type_name != null)
                    declared_enum
                else
                    init_enum orelse 0;

                stmt.decl_symbol = try self.declare(
                    decl.name,
                    decl.name_span,
                    declared_type,
                    decl.mutable,
                    .local,
                    struct_id,
                    init_has_struct or declared_type.eq(.aggregate),
                    enum_id,
                );
            },

            .assign => |*assign| {
                const value_type = try self.checkExpr(assign.value);
                const sym_index = self.lookup(assign.name) orelse {
                    try self.diags.add(
                        .undefined_variable,
                        assign.name_span,
                        "variable '{s}' is not declared",
                        .{assign.name},
                    );
                    return;
                };
                assign.resolved = sym_index;
                const sym = self.symbols.items[sym_index];
                if (!sym.mutable) {
                    try self.diags.add(
                        .immutable_assignment,
                        assign.name_span,
                        "'{s}' is immutable; declare it with 'var' to allow assignment",
                        .{assign.name},
                    );
                }
                if (!sym.typ.eq(.unknown) and !value_type.eq(.unknown) and !sym.typ.eq(value_type) and !ptrTypesCompatible(sym.typ, value_type)) {
                    try self.diags.add(
                        .type_mismatch,
                        assign.value.span,
                        "'{s}' has type '{s}', but the assigned value is '{s}'",
                        .{
                            assign.name,
                            self.typeLabel(sym.typ, sym.struct_id),
                            self.typeLabel(value_type, self.structIdOfExpr(assign.value) orelse 0),
                        },
                    );
                }
                if (sym.typ.eq(.enumeration) and value_type.eq(.enumeration)) {
                    const got = self.enumIdOfExpr(assign.value);
                    if (got != null and got.? != sym.enum_id) {
                        try self.diags.add(
                            .type_mismatch,
                            assign.value.span,
                            "'{s}' is enum '{s}', but the assigned value is enum '{s}'",
                            .{
                                assign.name,
                                self.enums.items[sym.enum_id].decl.name,
                                self.enums.items[got.?].decl.name,
                            },
                        );
                    }
                }
                if (sym.typ.eq(.aggregate) and value_type.eq(.aggregate)) {
                    const got = self.structIdOfExpr(assign.value);
                    if (got != null and got.? != sym.struct_id) {
                        try self.diags.add(
                            .type_mismatch,
                            assign.value.span,
                            "'{s}' is struct '{s}', but the assigned value is struct '{s}'",
                            .{
                                assign.name,
                                self.structs.items[sym.struct_id].decl.name,
                                self.structs.items[got.?].decl.name,
                            },
                        );
                    }
                }
            },

            .field_assign => |*fa| {
                const value_type = try self.checkExpr(fa.value);

                const base_index = try self.resolveFieldBase(fa.base);
                if (base_index == null) return;
                const sym = self.symbols.items[base_index.?];
                if (!sym.typ.eq(.aggregate)) {
                    try self.diags.add(
                        .type_mismatch,
                        fa.name_span,
                        "field access '{s}' requires a struct, but '{s}' has type '{s}'",
                        .{ fa.name, self.exprText(fa.base), self.typeLabel(sym.typ, sym.struct_id) },
                    );
                    return;
                }

                const info = &self.structs.items[sym.struct_id];
                const field_index = findField(info, fa.name) orelse {
                    try self.diags.add(
                        .undefined_field,
                        fa.name_span,
                        "struct '{s}' has no field '{s}'",
                        .{ info.decl.name, fa.name },
                    );
                    return;
                };
                fa.field_index = field_index;

                if (!sym.mutable) {
                    try self.diags.add(
                        .immutable_assignment,
                        fa.name_span,
                        "'{s}.{s}' cannot be assigned: '{s}' was declared with 'let'",
                        .{ self.exprText(fa.base), fa.name, self.exprText(fa.base) },
                    );
                    return;
                }

                const field_type = info.fields[field_index].typ;
                if (!field_type.eq(.unknown) and !value_type.eq(.unknown) and
                    !field_type.eq(value_type) and !ptrTypesCompatible(field_type, value_type))
                {
                    try self.diags.add(
                        .type_mismatch,
                        fa.value.span,
                        "field '{s}.{s}' has type '{s}', but the assigned value is '{s}'",
                        .{ self.exprText(fa.base), fa.name, field_type.name(), value_type.name() },
                    );
                }
            },

            .return_stmt => |value| {
                const expected = self.current_return;
                if (value) |expr| {
                    const actual = try self.checkExpr(expr);
                    if (expected.eq(.void)) {
                        try self.diags.add(
                            .invalid_return,
                            expr.span,
                            "the current function returns no value ('void'), but 'return' has an expression",
                            .{},
                        );
                    } else if (!expected.eq(.unknown) and !actual.eq(.unknown) and
                        !expected.eq(actual) and !ptrTypesCompatible(expected, actual))
                    {
                        try self.diags.add(
                            .invalid_return,
                            expr.span,
                            "expected return type '{s}', found '{s}'",
                            .{ expected.name(), actual.name() },
                        );
                    } else if (expected.eq(.enumeration) and actual.eq(.enumeration)) {
                        // Enums are nominal: the same shape is not enough.
                        const got = self.enumIdOfExpr(expr);
                        const want = self.functions.items[self.fn_index].return_enum_id;
                        if (got != null and got.? != want and want < self.enums.items.len) {
                            try self.diags.add(
                                .invalid_return,
                                expr.span,
                                "expected enum '{s}' in return, found '{s}'",
                                .{ self.enums.items[want].decl.name, self.enums.items[got.?].decl.name },
                            );
                        }
                    } else if (expected.eq(.aggregate) and actual.eq(.aggregate)) {
                        // Structs are nominal: the same shape is not enough.
                        const got = self.structIdOfExpr(expr) orelse 0;
                        const want = self.functions.items[self.fn_index].return_struct_id;
                        if (got != want) {
                            try self.diags.add(
                                .invalid_return,
                                expr.span,
                                "expected struct '{s}' in return, found '{s}'",
                                .{ self.structs.items[want].decl.name, self.structs.items[got].decl.name },
                            );
                        }
                    }
                } else if (expected.isValue()) {
                    try self.diags.add(
                        .invalid_return,
                        stmt.span,
                        "the current function must return '{s}'; a 'return' without a value is not allowed",
                        .{expected.name()},
                    );
                }
            },

            .expr_stmt => |expr| {
                const typ = try self.checkExpr(expr);
                if (typ.eq(.str)) {
                    try self.diags.add(
                        .unsupported,
                        expr.span,
                        "unused 'str' expression; use 'print(...)' or assign it to a variable",
                        .{},
                    );
                } else if (typ.eq(.aggregate)) {
                    try self.diags.add(
                        .unsupported,
                        expr.span,
                        "a struct value can only initialize or be assigned to a variable",
                        .{},
                    );
                } else if (typ.eq(.enumeration)) {
                    try self.diags.add(
                        .unsupported,
                        expr.span,
                        "an enum value can only initialize or be assigned to a variable, or be used in 'switch'",
                        .{},
                    );
                }
            },

            .if_stmt => |*if_stmt| {
                const cond_type = try self.checkExpr(if_stmt.cond);
                if (!cond_type.eq(.bool) and !cond_type.eq(.unknown)) {
                    try self.diags.add(
                        .invalid_condition,
                        if_stmt.cond.span,
                        "'if' condition must be 'bool', found '{s}'",
                        .{cond_type.name()},
                    );
                }
                try self.checkScopedBlock(if_stmt.then_body);
                if (if_stmt.else_body) |else_branch| {
                    switch (else_branch) {
                        .block => |stmts| try self.checkScopedBlock(stmts),
                        .if_stmt => |nested| try self.checkStatement(nested),
                    }
                }
            },

            .while_stmt => |*while_stmt| {
                const cond_type = try self.checkExpr(while_stmt.cond);
                if (!cond_type.eq(.bool) and !cond_type.eq(.unknown)) {
                    try self.diags.add(
                        .invalid_condition,
                        while_stmt.cond.span,
                        "'while' condition must be 'bool', found '{s}'",
                        .{cond_type.name()},
                    );
                }
                try self.checkScopedBlock(while_stmt.body);
            },

            .switch_stmt => |*sw| try self.checkSwitch(sw),

            .block => |stmts| try self.checkScopedBlock(stmts),
        }
    }

    /// `switch` over an enum: resolves every arm against the enum cases,
    /// checks the payload bindings and the exhaustiveness rule (every case or
    /// an `else` arm, never both).
    fn checkSwitch(self: *Checker, sw: *ast.Stmt.SwitchStmt) std.mem.Allocator.Error!void {
        const scrutinee_type = try self.checkExpr(sw.scrutinee);
        const enum_id = self.enumIdOfExpr(sw.scrutinee) orelse {
            if (!scrutinee_type.eq(.unknown) and !scrutinee_type.eq(.enumeration)) {
                try self.diags.add(
                    .type_mismatch,
                    sw.scrutinee.span,
                    "'switch' requires an enum value, found '{s}'",
                    .{self.typeLabel(scrutinee_type, self.structIdOfExpr(sw.scrutinee) orelse 0)},
                );
            }
            for (sw.arms) |arm| {
                try self.pushScope();
                try self.checkStatements(arm.body);
                self.popScope();
            }
            if (sw.else_body) |body| try self.checkScopedBlock(body);
            return;
        };
        sw.resolved_enum = enum_id;
        const info = &self.enums.items[enum_id];

        // Both backends read the tag from the variable slot, so the scrutinee
        // must be a place (an enum variable), not a constructed value.
        if (!std.mem.eql(u8, @tagName(sw.scrutinee.kind), "identifier")) {
            try self.diags.add(
                .unsupported,
                sw.scrutinee.span,
                "'switch' over a constructed enum value is not supported yet; store it in a variable first",
                .{},
            );
            // Keep checking the arms so the payload bindings exist; the
            // backend restriction is the only problem reported here.
        }

        const covered = try self.arena.alloc(bool, info.cases.len);
        @memset(covered, false);

        for (sw.arms) |*arm| {
            const case_index = findCaseIndex(info, arm.case_name) orelse {
                try self.diags.add(
                    .unknown_case,
                    arm.case_span,
                    "enum '{s}' has no case '{s}'",
                    .{ info.decl.name, arm.case_name },
                );
                try self.checkScopedBlock(arm.body);
                continue;
            };
            arm.resolved_case = case_index;
            const case = info.cases[case_index];

            if (covered[case_index]) {
                try self.diags.add(
                    .invalid_switch_arm,
                    arm.case_span,
                    "case '{s}' of enum '{s}' is already handled in this switch",
                    .{ case.name, info.decl.name },
                );
            }
            covered[case_index] = true;

            if (case.payload != null and arm.binding == null) {
                try self.diags.add(
                    .invalid_switch_arm,
                    arm.case_span,
                    "case '{s}' of enum '{s}' carries a payload; bind it with '{s}(name)'",
                    .{ case.name, info.decl.name, case.name },
                );
            } else if (case.payload == null and arm.binding != null) {
                try self.diags.add(
                    .invalid_switch_arm,
                    arm.binding_span orelse arm.case_span,
                    "case '{s}' of enum '{s}' has no payload; '{s}' cannot be bound",
                    .{ case.name, info.decl.name, arm.binding.? },
                );
            }

            try self.pushScope();
            if (arm.binding) |name| {
                if (case.payload != null) {
                    arm.binding_symbol = try self.declare(
                        name,
                        arm.binding_span orelse arm.case_span,
                        case.payload.?,
                        false,
                        .local,
                        0,
                        false,
                        0,
                    );
                }
            }
            try self.checkStatements(arm.body);
            self.popScope();
        }

        // Cases not handled by any arm, in declaration order.
        var missing: std.ArrayList(CaseInfo) = .empty;
        defer missing.deinit(self.arena);
        for (info.cases, 0..) |case, i| {
            if (!covered[i]) try missing.append(self.arena, case);
        }

        if (sw.else_body) |body| {
            if (missing.items.len == 0) {
                try self.diags.add(
                    .unreachable_arm,
                    sw.else_span orelse sw.scrutinee.span,
                    "'else' arm is unreachable: the switch already covers every case of '{s}'",
                    .{info.decl.name},
                );
            }
            try self.checkScopedBlock(body);
        } else if (missing.items.len > 0) {
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(self.arena);
            for (missing.items, 0..) |case, i| {
                if (i != 0) try list.appendSlice(self.arena, ", ");
                try list.print(self.arena, "'{s}'", .{case.name});
            }
            try self.diags.add(
                .non_exhaustive_switch,
                sw.scrutinee.span,
                "'switch' on '{s}' is not exhaustive: missing {s}",
                .{ info.decl.name, list.items },
            );
        }
    }

    fn checkExpr(self: *Checker, expr: *ast.Expr) std.mem.Allocator.Error!Type {
        switch (expr.kind) {
            .int_literal => |lit| {
                if (lit.value > std.math.maxInt(i32) or lit.value < std.math.minInt(i32)) {
                    try self.diags.add(
                        .integer_overflow,
                        expr.span,
                        "literal {s} does not fit in 'i32'",
                        .{lit.text},
                    );
                }
                return .i32;
            },

            .bool_literal => return .bool,

            .str_literal => return .str,

            .identifier => |name| {
                const sym_index = self.lookup(name) orelse {
                    try self.diags.add(
                        .undefined_variable,
                        expr.span,
                        "variable '{s}' is not declared",
                        .{name},
                    );
                    return .unknown;
                };
                expr.resolved = sym_index;
                return self.symbols.items[sym_index].typ;
            },

            .binary => |*binary| {
                const lhs = try self.checkExpr(binary.lhs);
                const rhs = try self.checkExpr(binary.rhs);
                return self.checkBinary(expr.span, binary.op, lhs, rhs);
            },

            .unary => |*unary| {
                const operand = try self.checkExpr(unary.operand);
                if (operand.eq(.unknown)) return .unknown;
                switch (unary.op) {
                    .neg => {
                        if (!operand.eq(.i32)) {
                            try self.diags.add(
                                .type_mismatch,
                                expr.span,
                                "operator '-' expects 'i32', found '{s}'",
                                .{operand.name()},
                            );
                            return .unknown;
                        }
                        return .i32;
                    },
                    .not => {
                        if (!operand.eq(.bool)) {
                            try self.diags.add(
                                .type_mismatch,
                                expr.span,
                                "operator '!' expects 'bool', found '{s}'",
                                .{operand.name()},
                            );
                            return .unknown;
                        }
                        return .bool;
                    },
                    .bitnot => {
                        if (!operand.isInteger()) {
                            try self.diags.add(
                                .type_mismatch,
                                expr.span,
                                "operator '~' expects an integer type, found '{s}'",
                                .{operand.name()},
                            );
                            return .unknown;
                        }
                        return operand;
                    },
                    .address_of => {
                        if (operand == .unknown) return .unknown;
                        // Only addressable storage has a stable location; a
                        // temporary such as `&42` is not an lvalue. String
                        // slices have two slots and are not addressable yet.
                        const addressable = switch (unary.operand.kind) {
                            .identifier => true,
                            .field_access => |field| field.resolved_enum == null and field.base.kind == .identifier,
                            else => false,
                        };
                        if (!addressable or operand == .str or operand == .enumeration or operand == .void) {
                            try self.diags.add(
                                .type_mismatch,
                                expr.span,
                                "operator '&' requires an addressable scalar or struct variable/field",
                                .{},
                            );
                            return .unknown;
                        }
                        // Allocate the pointee type in the arena so the
                        // pointer can reference it.
                        const pointee: Type = operand;
                        const pointee_slot = try self.arena.alloc(Type, 1);
                        pointee_slot[0] = pointee;

                        // If the operand is an identifier resolving to a struct
                        // variable, store the struct_id so field access through
                        // the pointer (*ptr).field can resolve the struct layout.
                        var ptr_struct_id: u32 = 0;
                        var ptr_has_struct_id: bool = false;
                        if (expr.kind.unary.operand.kind == .identifier) {
                            const id_expr = expr.kind.unary.operand;
                            if (id_expr.resolved) |si| {
                                const sym = self.symbols.items[si];
                                if (sym.has_struct_id) {
                                    ptr_struct_id = sym.struct_id;
                                    ptr_has_struct_id = true;
                                }
                            }
                        }

                        return Type{ .ptr = .{ .pointee = &pointee_slot[0], .struct_id = ptr_struct_id, .has_struct_id = ptr_has_struct_id } };
                    },
                    .dereference => {
                        // `*ptr` requires the operand to be a pointer. The
                        // result is the pointee type (e.g. `*p` where
                        // `p: ptr<i32>` yields `i32`).
                        if (operand.eq(.unknown)) return .unknown;
                        if (!operand.isPtr()) {
                            try self.diags.add(
                                .type_mismatch,
                                expr.span,
                                "operator '*' expects a pointer, found '{s}'",
                                .{operand.name()},
                            );
                            return .unknown;
                        }
                        // Access the pointee type through the union field.
                        const pointee = operand.ptr.pointee.*;
                        if (pointee == .unknown or pointee == .aggregate or pointee == .str or pointee == .enumeration) {
                            try self.diags.add(
                                .unsupported,
                                expr.span,
                                "cannot dereference pointer to '{s}' as a scalar value; the pointee must have a known scalar type",
                                .{pointee.name()},
                            );
                            return .unknown;
                        }
                        return pointee;
                    },
                }
            },

            .call => |*call| return self.checkCall(expr.span, call),

            .field_access => |*access| {
                // `Color.Red`: the base is an enum name, not a variable.
                if (std.mem.eql(u8, @tagName(access.base.kind), "identifier") and self.lookup(access.base.kind.identifier) == null) {
                    if (self.findEnumIndex(access.base.kind.identifier)) |enum_id| {
                        const info = &self.enums.items[enum_id];
                        const case_index = findCaseIndex(info, access.name) orelse {
                            try self.diags.add(
                                .unknown_case,
                                access.name_span,
                                "enum '{s}' has no case '{s}'",
                                .{ info.decl.name, access.name },
                            );
                            return .unknown;
                        };
                        const case = info.cases[case_index];
                        access.resolved_enum = enum_id;
                        access.resolved_case = case_index;
                        if (case.payload != null) {
                            try self.diags.add(
                                .invalid_call,
                                access.name_span,
                                "case '{s}' of enum '{s}' needs a payload: use '{s}.{s}(value)'",
                                .{ case.name, info.decl.name, info.decl.name, case.name },
                            );
                            return .unknown;
                        }
                        return .enumeration;
                    }
                }

                // Support `(*ptr).field`: dereference a pointer to a struct,
                // then access a field. The pointee type must be an aggregate
                // with a known struct_id (stored when the pointer was created
                // via `&struct_var`).
                var base_struct_id: u32 = 0;
                var is_ptr_access: bool = false;
                var ptr_has_struct_id: bool = false;

                if (access.base.kind == .unary) {
                    const unary_expr = access.base.kind.unary;
                    if (unary_expr.op == .dereference) {
                        // The operand of `*` is the pointer. Its type must be
                        // `ptr<struct>` so we can recover the struct_id.
                        const ptr_type = try self.checkExpr(unary_expr.operand);
                        if (ptr_type == .unknown) return .unknown;
                        if (!ptr_type.isPtr()) {
                            try self.diags.add(
                                .type_mismatch,
                                access.name_span,
                                "field access '{s}' requires a struct pointer, but operand has type '{s}'",
                                .{ access.name, ptr_type.name() },
                            );
                            return .unknown;
                        }
                        const pt = switch (ptr_type) {
                            .ptr => |pt| pt,
                            else => unreachable,
                        };
                        if (pt.pointee.eq(.aggregate)) {
                            base_struct_id = pt.struct_id;
                            ptr_has_struct_id = pt.has_struct_id;
                        } else if (pt.pointee.eq(.unknown)) {
                            // Pointer declared as `ptr` (ptr<unknown>) but
                            // initialized with `&struct_var`. Recover the
                            // struct_id from the symbol's struct_id field.
                                if (unary_expr.operand.kind == .identifier) {
                                if (unary_expr.operand.resolved) |idx| {
                                    const sym = self.symbols.items[idx];
                                    // For a `ptr` variable initialized with `&struct_var`,
                                    // the symbol's struct_id holds the struct identity
                                    // even though sym.typ is `.ptr`.
                                    if (sym.has_struct_id) {
                                        base_struct_id = sym.struct_id;
                                        ptr_has_struct_id = true;
                                    } else {
                                        try self.diags.add(
                                            .type_mismatch,
                                            access.name_span,
                                            "field access '{s}' requires a pointer to a struct, but pointee type is unknown",
                                            .{ access.name },
                                        );
                                        return .unknown;
                                    }
                                } else {
                                    try self.diags.add(
                                        .type_mismatch,
                                        access.name_span,
                                        "field access '{s}' requires a pointer to a struct, but pointee type is unknown",
                                        .{ access.name },
                                    );
                                    return .unknown;
                                }
                            } else {
                                try self.diags.add(
                                    .type_mismatch,
                                    access.name_span,
                                    "field access '{s}' requires a pointer to a struct, but pointee type is unknown",
                                    .{ access.name },
                                );
                                return .unknown;
                            }
                        } else {
                            try self.diags.add(
                                .type_mismatch,
                                access.name_span,
                                "field access '{s}' requires a pointer to a struct, but pointee has type '{s}'",
                                .{ access.name, pt.pointee.name() },
                            );
                            return .unknown;
                        }
                        is_ptr_access = true;
                    }
                }

                if (!is_ptr_access) {
                    const base_index = try self.resolveFieldBase(access.base);
                    if (base_index == null) return .unknown;

                    const sym = self.symbols.items[base_index.?];
                    if (!sym.typ.eq(.aggregate)) {
                        try self.diags.add(
                            .type_mismatch,
                            access.name_span,
                            "field access '{s}' requires a struct, but '{s}' has type '{s}'",
                            .{ access.name, self.exprText(access.base), self.typeLabel(sym.typ, sym.struct_id) },
                        );
                        return .unknown;
                    }

                    base_struct_id = sym.struct_id;
                }

                // For pointer access, missing has_struct_id means "unknown pointee"
                // (created via `ptrToUnknown()` or `&x` where x is not a known
                // struct). For direct access, struct_id is always a valid index.
                if (is_ptr_access and !ptr_has_struct_id) {
                    try self.diags.add(
                        .unsupported,
                        access.name_span,
                        "field access through a pointer requires pointee-type tracking (struct id unknown)",
                        .{},
                    );
                    return .unknown;
                }
                if (base_struct_id >= self.structs.items.len) {
                    try self.diags.add(
                        .unsupported,
                        access.name_span,
                        "field access: invalid struct id {d} (>= {d})",
                        .{ base_struct_id, self.structs.items.len },
                    );
                    return .unknown;
                }

                const info = &self.structs.items[base_struct_id];
                const field_index = findField(info, access.name) orelse {
                    try self.diags.add(
                        .undefined_field,
                        access.name_span,
                        "struct '{s}' has no field '{s}'",
                        .{ info.decl.name, access.name },
                    );
                    return .unknown;
                };
                access.field_index = field_index;
                return info.fields[field_index].typ;
            },

            .method_call => |*call| {
                // A variable shadows the enum name: `x.Case(...)` is not a
                // constructor either, so both cases fail the same way.
                const base_name: ?[]const u8 = if (std.mem.eql(u8, @tagName(call.base.kind), "identifier") and
                    self.lookup(call.base.kind.identifier) == null)
                    call.base.kind.identifier
                else
                    null;
                const enum_id = if (base_name) |name| self.findEnumIndex(name) else null;
                if (enum_id == null) {
                    // A struct name is a type: there is no value to call the
                    // method on.
                    if (base_name) |name| {
                        if (self.findStructIndex(name) != null) {
                            try self.diags.add(
                                .invalid_call,
                                call.base.span,
                                "struct '{s}' is a type, not a value; call the method on a variable of type '{s}'",
                                .{ name, name },
                            );
                            for (call.args) |arg| _ = try self.checkExpr(arg);
                            return .unknown;
                        }
                    }
                    return self.checkMethodCall(expr.span, call);
                }
                const info = &self.enums.items[enum_id.?];
                const case_index = findCaseIndex(info, call.name) orelse {
                    try self.diags.add(
                        .unknown_case,
                        call.name_span,
                        "enum '{s}' has no case '{s}'",
                        .{ info.decl.name, call.name },
                    );
                    for (call.args) |arg| _ = try self.checkExpr(arg);
                    return .unknown;
                };
                call.resolved_enum = enum_id.?;
                call.resolved_case = case_index;
                const case = info.cases[case_index];

                if (case.payload == null) {
                    try self.diags.add(
                        .invalid_call,
                        call.name_span,
                        "case '{s}' of enum '{s}' has no payload; use '{s}.{s}'",
                        .{ case.name, info.decl.name, info.decl.name, case.name },
                    );
                    for (call.args) |arg| _ = try self.checkExpr(arg);
                    return .unknown;
                }

                if (call.args.len != 1) {
                    try self.diags.add(
                        .invalid_call,
                        call.name_span,
                        "case '{s}' of enum '{s}' expects 1 payload argument, received {d}",
                        .{ case.name, info.decl.name, call.args.len },
                    );
                    for (call.args) |arg| _ = try self.checkExpr(arg);
                    return .unknown;
                }

                const arg_type = try self.checkExpr(call.args[0]);
                if (case.payload) |payload| {
                    if (!arg_type.eq(.unknown) and !arg_type.eq(payload)) {
                        try self.diags.add(
                            .type_mismatch,
                            call.args[0].span,
                            "payload of '{s}.{s}' has type '{s}', found '{s}'",
                            .{ info.decl.name, case.name, payload.name(), arg_type.name() },
                        );
                    }
                }
                return .enumeration;
            },

            .struct_literal => |*lit| {
                const struct_id = self.findStructIndex(lit.type_name.name) orelse {
                    try self.diags.add(
                        .unknown_type,
                        lit.type_name.span,
                        "struct '{s}' is not declared",
                        .{lit.type_name.name},
                    );
                    return .unknown;
                };
                lit.resolved_struct = struct_id;
                const info = &self.structs.items[struct_id];

                const seen = try self.arena.alloc(bool, info.fields.len);
                @memset(seen, false);

                for (lit.fields) |field_init| {
                    const field_index = findField(info, field_init.name) orelse {
                        try self.diags.add(
                            .undefined_field,
                            field_init.name_span,
                            "struct '{s}' has no field '{s}'",
                            .{ info.decl.name, field_init.name },
                        );
                        _ = try self.checkExpr(field_init.value);
                        continue;
                    };
                    if (seen[field_index]) {
                        try self.diags.add(
                            .invalid_struct_literal,
                            field_init.name_span,
                            "field '{s}' repeated in the literal of '{s}'",
                            .{ field_init.name, info.decl.name },
                        );
                        _ = try self.checkExpr(field_init.value);
                        continue;
                    }
                    seen[field_index] = true;

                    const value_type = try self.checkExpr(field_init.value);
                    const field_type = info.fields[field_index].typ;
                    if (!value_type.eq(.unknown) and !field_type.eq(.unknown) and
                        !value_type.eq(field_type) and !ptrTypesCompatible(field_type, value_type))
                    {
                        try self.diags.add(
                            .type_mismatch,
                            field_init.value.span,
                            "field '{s}.{s}' has type '{s}', but the value is '{s}'",
                            .{ info.decl.name, field_init.name, field_type.name(), value_type.name() },
                        );
                    }
                }

                for (info.fields, 0..) |field, i| {
                    if (!seen[i]) {
                        try self.diags.add(
                            .invalid_struct_literal,
                            lit.type_name.span,
                            "literal of '{s}' does not initialize field '{s}'",
                            .{ info.decl.name, field.name },
                        );
                    }
                }

                return .aggregate;
            },

            .cast => |*cast_expr| {
                const src_type = try self.checkExpr(cast_expr.expr);
                if (src_type.eq(.unknown)) return .unknown;

                const dst_type = try self.resolveTypeName(cast_expr.type_name);
                if (dst_type.eq(.unknown)) return .unknown;

                // Only integer <-> integer conversions are supported at this
                // stage. bool and str cannot be cast.
                if (!src_type.isInteger()) {
                    try self.diags.add(
                        .type_mismatch,
                        cast_expr.expr.span,
                        "cannot cast from '{s}' to an integer type", .{src_type.name()},
                    );
                    return .unknown;
                }
                if (!dst_type.isInteger()) {
                    try self.diags.add(
                        .type_mismatch,
                        cast_expr.type_name.span,
                        "cast target '{s}' is not an integer type", .{dst_type.name()},
                    );
                    return .unknown;
                }

                return dst_type;
            },
        }
    }

    fn checkBinary(
        self: *Checker,
        span: Span,
        op: ast.Expr.BinaryOp,
        lhs: Type,
        rhs: Type,
    ) !Type {
        if (lhs.eq(.unknown) or rhs.eq(.unknown)) return .unknown;

        // Enums take part in no operator: `==` would compare tags and hide the
        // payload, and arithmetic has no meaning for them.
        if (lhs.eq(.enumeration) or rhs.eq(.enumeration)) {
            try self.diags.add(
                .unsupported,
                span,
                "operator '{s}' is not supported on an enum value; use 'switch'",
                .{op.spelling()},
            );
            return .unknown;
        }

        // `str` is a slice (pointer + length): comparing two `str` values
        // compares both the pointer and the length. `str == str` and
        // `str != str` yield `bool`. Relational operators (`<`, `<=`, `>`,
        // `>=`) on `str` remain unsupported.
        if (lhs.eq(.str) or rhs.eq(.str)) {
            if (op == .eq or op == .ne) {
                if (!lhs.eq(.str) or !rhs.eq(.str)) {
                    try self.diags.add(
                        .type_mismatch,
                        span,
                        "operator '{s}' expects two 'str', found '{s}' and '{s}'",
                        .{ op.spelling(), lhs.name(), rhs.name() },
                    );
                    return .unknown;
                }
                return .bool;
            } else {
                try self.diags.add(
                    .type_mismatch,
                    span,
                    "operator '{s}' expects two 'i32', found '{s}' and '{s}'",
                    .{ op.spelling(), lhs.name(), rhs.name() },
                );
                return .unknown;
            }
        }

        const both_bool = lhs.eq(.bool) and rhs.eq(.bool);

        if (op.isArithmetic()) {
            // Offsets are signed i32 values measured in units of the known
            // pointee size. Subtraction of like-typed pointers yields the
            // distance in those units (i32). Other pointer arithmetic is
            // rejected here instead of failing later in a backend.
            if (lhs.isPtr() or rhs.isPtr()) {
                if (lhs.isPtr() and rhs.isPtr() and op == .sub and
                    lhs.ptr.pointee.* != .unknown and lhs.eq(rhs)) return .i32;
                if (lhs.isPtr() and lhs.ptr.pointee.* != .unknown and rhs == .i32 and
                    (op == .add or op == .sub)) return lhs;
                if (rhs.isPtr() and rhs.ptr.pointee.* != .unknown and lhs == .i32 and op == .add) return rhs;
                try self.diags.add(
                    .type_mismatch,
                    span,
                    "pointer arithmetic requires a known pointee and ptr +/- i32, i32 + ptr or compatible ptr - ptr",
                    .{},
                );
                return .unknown;
            }

            // Arithmetic: both operands must be the same integer type (not bool).
            if (lhs.eq(.bool) or rhs.eq(.bool) or !lhs.isInteger() or !rhs.isInteger() or !lhs.eq(rhs)) {
                try self.diags.add(
                    .type_mismatch,
                    span,
                    "operator '{s}' expects two operands of the same integer type, found '{s}' and '{s}'",
                    .{ op.spelling(), lhs.name(), rhs.name() },
                );
                return .unknown;
            }
            return lhs;
        }

        if (op.isComparison()) {
            // Relational comparisons require two integers of the same type;
            // pointer ordering has no language-level contract.
            if (lhs.eq(.bool) or rhs.eq(.bool) or !lhs.isInteger() or !rhs.isInteger() or !lhs.eq(rhs)) {
                try self.diags.add(
                    .type_mismatch,
                    span,
                    "operator '{s}' expects two operands of the same integer type, found '{s}' and '{s}'",
                    .{ op.spelling(), lhs.name(), rhs.name() },
                );
                return .unknown;
            }
            return .bool;
        }

        if (op.isLogical()) {
            if (!both_bool) {
                try self.diags.add(
                    .type_mismatch,
                    span,
                    "operator '{s}' expects two 'bool', found '{s}' and '{s}'",
                    .{ op.spelling(), lhs.name(), rhs.name() },
                );
                return .unknown;
            }
            return .bool;
        }

        if (op.isBitwise() and !op.isShift()) {
            // Bitwise AND/XOR/OR: both operands must be the same integer type.
            if (lhs.eq(.bool) or rhs.eq(.bool) or !lhs.isInteger() or !rhs.isInteger() or !lhs.eq(rhs)) {
                try self.diags.add(
                    .type_mismatch,
                    span,
                    "operator '{s}' expects two operands of the same integer type, found '{s}' and '{s}'",
                    .{ op.spelling(), lhs.name(), rhs.name() },
                );
                return .unknown;
            }
            return lhs;
        }

        if (op.isShift()) {
            // Shift: lhs is an integer, rhs is an integer shift amount. Result
            // has the type of lhs.
            if (!lhs.isInteger() or !rhs.isInteger()) {
                try self.diags.add(
                    .type_mismatch,
                    span,
                    "operator '{s}' expects an integer value and an integer shift amount, found '{s}' and '{s}'",
                    .{ op.spelling(), lhs.name(), rhs.name() },
                );
                return .unknown;
            }
            return lhs;
        }

        // Equality of addresses is well-defined even for different pointee
        // types. This never dereferences either operand.
        if ((op == .eq or op == .ne) and lhs.isPtr() and rhs.isPtr()) return .bool;

        // == and != (fallback for value types that are not bitwise)
        if (!lhs.eq(rhs) or !lhs.isValue()) {
            try self.diags.add(
                .type_mismatch,
                span,
                "operator '{s}' requires operands of the same type and non-void, found '{s}' and '{s}'",
                .{ op.spelling(), lhs.name(), rhs.name() },
            );
            return .unknown;
        }
        return .bool;
    }

    /// `value.method(args)`: resolves the receiver type, then checks the
    /// arguments against the method signature exactly like a free call. The
    /// receiver is passed by value as argument 1.
    fn checkMethodCall(
        self: *Checker,
        span: Span,
        call: *ast.Expr.MethodCall,
    ) std.mem.Allocator.Error!Type {
        // The receiver may be a variable or a call: `shape.weight()` and
        // `box.doubled().get()` both pass a value of the owner type.
        const recv_type = try self.checkExpr(call.base);
        if (!recv_type.eq(.aggregate) and !recv_type.eq(.enumeration)) {
            if (!recv_type.eq(.unknown)) {
                try self.diags.add(
                    .unsupported,
                    call.name_span,
                    "method calls are only supported on struct and enum values, but '{s}' has type '{s}'",
                    .{ self.exprText(call.base), recv_type.name() },
                );
            }
            for (call.args) |arg| _ = try self.checkExpr(arg);
            return .unknown;
        }

        const struct_id = if (recv_type.eq(.aggregate)) self.structIdOfExpr(call.base) orelse 0 else 0;
        const enum_id = if (recv_type.eq(.enumeration)) self.enumIdOfExpr(call.base) orelse 0 else 0;
        const owner: MethodOwner = if (recv_type.eq(.aggregate))
            .{ .struct_id = struct_id }
        else
            .{ .enum_id = enum_id };
        const owner_name = self.nominalLabel(recv_type, struct_id, enum_id);
        const method_index = self.findMethodIndex(owner, call.name) orelse {
            try self.diags.add(
                .invalid_call,
                call.name_span,
                "'{s}' has no method '{s}'",
                .{ owner_name, call.name },
            );
            for (call.args) |arg| _ = try self.checkExpr(arg);
            return .unknown;
        };

        call.resolved_fn = method_index;
        const func = self.functions.items[method_index];

        var arg_types: std.ArrayList(Type) = .empty;
        defer arg_types.deinit(self.arena);
        for (call.args) |arg| try arg_types.append(self.arena, try self.checkExpr(arg));

        // `Shape.area`: the receiver type names the method in messages.
        const display = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ owner_name, call.name });
        return self.checkSignature(
            span,
            display,
            func,
            call.args,
            arg_types.items,
            self.wordsOf(recv_type, struct_id),
        );
    }

    /// Checks a call site against a signature: register limit, arity and the
    /// nominal identity of struct/enum arguments. `receiver` accounts for the
    /// words of a method receiver, which counts as argument 1.
    fn checkSignature(
        self: *Checker,
        span: Span,
        display: []const u8,
        func: FunctionInfo,
        args: []*ast.Expr,
        arg_types: []const Type,
        receiver_words: ?usize,
    ) std.mem.Allocator.Error!Type {
        // The receiver is argument 1 of the callee but not written at the call
        // site, so it shifts the expected parameter of every written argument.
        const offset: usize = if (receiver_words != null) 1 else 0;
        const written_params: usize = func.params.len -| offset;

        var arg_words: usize = receiver_words orelse 0;
        for (arg_types, args) |typ, arg| {
            arg_words += self.wordsOf(typ, self.structIdOfExpr(arg) orelse 0);
        }
        if (arg_words > max_arg_registers) {
            try self.diags.add(
                .unsupported,
                span,
                "call to '{s}' uses {d} registers; the current backend supports at most {d} ('str' and an enum take two, each struct field one)",
                .{ display, arg_words, max_arg_registers },
            );
        }

        if (arg_types.len != written_params) {
            try self.diags.add(
                .invalid_call,
                span,
                "'{s}' expects {d} argument(s), received {d}",
                .{ display, written_params, arg_types.len },
            );
            return func.return_type;
        }

        for (arg_types, 0..) |actual, i| {
            const param_index = i + offset;
            if (param_index >= func.params.len) break;
            const expected = func.params[param_index];
            if (actual.eq(.unknown) or expected.eq(.unknown)) continue;
            if (actual.eq(.enumeration) and expected.eq(.enumeration)) {
                // Enums are nominal: the same shape is not enough.
                const got = self.enumIdOfExpr(args[i]);
                const want = if (param_index < func.param_enum_ids.len) func.param_enum_ids[param_index] else 0;
                if (got != null and got.? != want and want < self.enums.items.len) {
                    try self.diags.add(
                        .type_mismatch,
                        args[i].span,
                        "argument {d} of '{s}' is enum '{s}', expected '{s}'",
                        .{ i + 1, display, self.enums.items[got.?].decl.name, self.enums.items[want].decl.name },
                    );
                }
                continue;
            }
            if (actual.eq(.aggregate) and expected.eq(.aggregate)) {
                const got = self.structIdOfExpr(args[i]) orelse 0;
                const want = if (param_index < func.param_struct_ids.len) func.param_struct_ids[param_index] else 0;
                if (got != want) {
                    try self.diags.add(
                        .type_mismatch,
                        args[i].span,
                        "argument {d} of '{s}' is struct '{s}', expected '{s}'",
                        .{ i + 1, display, self.structs.items[got].decl.name, self.structs.items[want].decl.name },
                    );
                }
                continue;
            }
            if (!actual.eq(expected) and !ptrTypesCompatible(expected, actual)) {
                try self.diags.add(
                    .type_mismatch,
                    args[i].span,
                    "argument {d} of '{s}' must be '{s}', found '{s}'",
                    .{ i + 1, display, expected.name(), actual.name() },
                );
            }
        }

        return func.return_type;
    }

    fn checkCall(self: *Checker, span: Span, call: *ast.Expr.Call) std.mem.Allocator.Error!Type {
        var arg_types = std.ArrayList(Type).empty;
        defer arg_types.deinit(self.arena);

        for (call.args) |arg| {
            try arg_types.append(self.arena, try self.checkExpr(arg));
        }

        if (builtinByName(call.callee)) |builtin| {
            call.builtin = builtin;
            const expected = builtinParamType(builtin);
            if (arg_types.items.len != 1) {
                try self.diags.add(
                    .invalid_call,
                    span,
                    "'{s}' expects 1 argument of type '{s}', received {d}",
                    .{ @tagName(builtin), expected.name(), arg_types.items.len },
                );
                return .void;
            }
            const arg_type = arg_types.items[0];
            if (!arg_type.eq(.unknown) and !arg_type.eq(expected)) {
                try self.diags.add(
                    .type_mismatch,
                    call.args[0].span,
                    "'{s}' expects '{s}', found '{s}'",
                    .{ @tagName(builtin), expected.name(), arg_type.name() },
                );
            }
            return .void;
        }

        const fn_index = self.findFunctionIndex(call.callee);
        if (fn_index == null) {
            try self.diags.add(
                .invalid_call,
                call.callee_span,
                "function '{s}' is not declared",
                .{call.callee},
            );
            return .unknown;
        }

        const func = self.functions.items[fn_index.?];
        call.callee_fn = fn_index;
        return self.checkSignature(span, call.callee, func, call.args, arg_types.items, null);
    }

    /// Free function by name: methods never answer a bare call.
    fn findFunctionIndex(self: *const Checker, name: []const u8) ?u32 {
        for (self.functions.items, 0..) |func, i| {
            if (func.is_method) continue;
            if (std.mem.eql(u8, func.decl.name, name)) return @intCast(i);
        }
        return null;
    }

    /// Method of the receiver type, by name.
    fn findMethodIndex(self: *const Checker, owner: MethodOwner, name: []const u8) ?u32 {
        for (self.functions.items, 0..) |func, i| {
            if (!func.is_method) continue;
            if (!std.mem.eql(u8, func.decl.name, name)) continue;
            const matches = switch (owner) {
                .struct_id => |id| func.owner_struct_id != null and func.owner_struct_id.? == id,
                .enum_id => |id| func.owner_enum_id != null and func.owner_enum_id.? == id,
            };
            if (matches) return @intCast(i);
        }
        return null;
    }
};

/// Builtin function for that identifier, when present. The enum field name
/// is the identifier accepted in the source.
fn builtinByName(name: []const u8) ?ast.Expr.Builtin {
    if (std.mem.eql(u8, name, "print")) return .print;
    if (std.mem.eql(u8, name, "print_i32")) return .print_i32;
    return null;
}

/// Type of the single parameter required by each builtin function.
fn builtinParamType(builtin: ast.Expr.Builtin) Type {
    return switch (builtin) {
        .print => .str,
        .print_i32 => .i32,
    };
}

/// Index of the `name` field in the struct declaration.
fn findField(info: *const StructInfo, name: []const u8) ?u32 {
    for (info.fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    }
    return null;
}

/// Simple structural check: does the block always end by running `return`?
/// Covers a direct `return`, nested blocks and an `if` whose branches both
/// terminate. Loops are not considered (termination cannot be proven).
pub fn alwaysReturns(stmts: []*ast.Stmt) bool {
    if (stmts.len == 0) return false;
    return stmtAlwaysReturns(stmts[stmts.len - 1]);
}

fn stmtAlwaysReturns(stmt: *const ast.Stmt) bool {
    return switch (stmt.kind) {
        .return_stmt => true,
        .block => |stmts| alwaysReturns(stmts),
        .if_stmt => |if_stmt| blk: {
            const else_branch = if_stmt.else_body orelse break :blk false;
            if (!alwaysReturns(if_stmt.then_body)) break :blk false;
            break :blk switch (else_branch) {
                .block => |stmts| alwaysReturns(stmts),
                .if_stmt => |nested| stmtAlwaysReturns(nested),
            };
        },
        // A switch terminates when every arm terminates. Without `else` this
        // relies on exhaustiveness, which the checker enforces and reports
        // separately, so the return diagnostic does not pile up on top of it.
        .switch_stmt => |sw| blk: {
            for (sw.arms) |arm| {
                if (!alwaysReturns(arm.body)) break :blk false;
            }
            if (sw.else_body) |body| break :blk alwaysReturns(body);
            break :blk true;
        },
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const lexer = @import("../lexer/lexer.zig");
const parser = @import("../parser/parser.zig");

const Fixture = struct {
    arena: *std.heap.ArenaAllocator,
    diags: *diagnostics.List,
    checked: ?Checked,

    fn check(source: []const u8, options: Options) !Fixture {
        const arena = try testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(testing.allocator);
        const a = arena.allocator();
        const diags = try a.create(diagnostics.List);
        diags.* = diagnostics.List.init(a);

        var lex = lexer.Lexer.init(source);
        const tokens = try lex.tokenize(a);
        var p = parser.Parser.init(a, tokens, diags);
        const program = p.parseProgram() catch |err| switch (err) {
            error.ParseError => return .{ .arena = arena, .diags = diags, .checked = null },
            else => return err,
        };

        var checker = Checker.init(a, diags, options);
        const checked = try checker.checkProgram(program);
        return .{ .arena = arena, .diags = diags, .checked = checked };
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        testing.allocator.destroy(self.arena);
    }

    fn kinds(self: *const Fixture, buf: []diagnostics.Kind) []diagnostics.Kind {
        var n: usize = 0;
        for (self.diags.items.items) |d| {
            if (n == buf.len) break;
            buf[n] = d.kind;
            n += 1;
        }
        return buf[0..n];
    }
};

/// True when some diagnostic contains `needle` (order-independent assertions).
fn sawMessage(f: *const Fixture, needle: []const u8) bool {
    for (f.diags.items.items) |d| {
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

fn expectOnly(f: *const Fixture, kind: diagnostics.Kind) !void {
    try testing.expectEqual(@as(usize, 1), f.diags.count());
    try testing.expectEqual(kind, f.diags.items.items[0].kind);
}

test "sema: valid program produces no diagnostics" {
    var f = try Fixture.check(
        \\fn add(a: i32, b: i32) -> i32 { return a + b; }
        \\fn main() -> i32 {
        \\    let x: i32 = 10;
        \\    var y = 20;
        \\    y = y + 1;
        \\    if x < y { return add(x, y); } else { return 0; }
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
    try testing.expect(f.checked != null);
    const checked = f.checked.?;
    try testing.expectEqual(@as(usize, 2), checked.functions.len);
    try testing.expectEqual(@as(u32, 2), checked.functions[0].slot_count); // a, b
    try testing.expectEqual(@as(u32, 2), checked.functions[1].slot_count); // x, y
}

test "sema: undeclared variable" {
    var f = try Fixture.check("fn main() -> i32 { return z; }", .{});
    defer f.deinit();
    try expectOnly(&f, .undefined_variable);
}

test "sema: assignment to immutable variable" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let x = 1;
        \\    x = 2;
        \\    return x;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .immutable_assignment);
}

test "sema: assignment to var is allowed" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    var x = 1;
        \\    x = 2;
        \\    return x;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: duplicate declaration in the same scope" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let x = 1;
        \\    let x = 2;
        \\    return x;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .duplicate_declaration);
}

test "sema: shadowing in an inner scope is allowed" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let x = 1;
        \\    if x > 0 { let x = 2; return x; }
        \\    return x;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: annotation differs from the initializer" {
    var f = try Fixture.check("fn main() -> i32 { let x: bool = 1; return 0; }", .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
}

test "sema: arithmetic with bool is rejected" {
    var f = try Fixture.check("fn main() -> i32 { let x = true + 1; return 0; }", .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
}

test "sema: i32 comparison produces bool" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let b: bool = 1 < 2;
        \\    if b { return 1; } else { return 0; }
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: if condition must be bool" {
    var f = try Fixture.check("fn main() -> i32 { if 1 { return 1; } return 0; }", .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_condition);
}

test "sema: while condition must be bool" {
    var f = try Fixture.check("fn main() -> i32 { while 0 { } return 0; }", .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_condition);
}

test "sema: return with a mismatched type" {
    var f = try Fixture.check("fn main() -> i32 { return true; }", .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_return);
}

test "sema: return with a value in a void function" {
    var f = try Fixture.check("fn main() -> void { return 1; }", .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_return);
}

test "sema: non-void function may finish without return" {
    var f = try Fixture.check("fn main() -> i32 { let x = 1; }", .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_return);
}

test "sema: path with if without else does not guarantee return" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    if 1 > 0 { return 1; }
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_return);
}

test "sema: if/else with both returns is accepted" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    if 1 > 0 { return 1; } else { return 2; }
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: function call resolves the signature" {
    var f = try Fixture.check(
        \\fn twice(x: i32) -> i32 { return x + x; }
        \\fn main() -> i32 { return twice(21); }
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: call with the wrong arity" {
    var f = try Fixture.check(
        \\fn twice(x: i32) -> i32 { return x + x; }
        \\fn main() -> i32 { return twice(1, 2); }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_call);
}

test "sema: call to a nonexistent function" {
    var f = try Fixture.check("fn main() -> i32 { return nada(); }", .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_call);
}

test "sema: argument with the wrong type" {
    var f = try Fixture.check(
        \\fn id(x: i32) -> i32 { return x; }
        \\fn main() -> i32 { return id(true); }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
}

test "sema: unknown type" {
    var f = try Fixture.check("fn main() -> i32 { let x: i128 = 1; return 0; }", .{});
    defer f.deinit();
    try expectOnly(&f, .unknown_type);
}

test "sema: literal does not fit in i32" {
    var f = try Fixture.check("fn main() -> i32 { let x = 2147483648; return 0; }", .{});
    defer f.deinit();
    try expectOnly(&f, .integer_overflow);
}

test "sema: missing main" {
    var f = try Fixture.check("fn other() -> i32 { return 1; }", .{});
    defer f.deinit();
    try expectOnly(&f, .missing_main);
}

test "sema: main with parameters is invalid" {
    var f = try Fixture.check("fn main(argc: i32) -> i32 { return 0; }", .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_main);
}

test "sema: duplicated function" {
    var f = try Fixture.check(
        \\fn main() -> i32 { return 1; }
        \\fn main() -> i32 { return 2; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .duplicate_declaration);
}

test "sema: resolution is annotated in the AST" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let x = 5;
        \\    return x;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
    const checked = f.checked.?;
    try testing.expectEqual(@as(usize, 1), checked.symbols.len);
    try testing.expectEqual(@as(u32, 0), checked.symbols[0].slot);
    try testing.expectEqualStrings("x", checked.symbols[0].name);
}

test "sema: alwaysReturns recognizes a complete if/else" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    if 1 > 0 { return 1; } else if 2 > 1 { return 2; } else { return 3; }
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: backend parameter limit is diagnosed" {
    var f = try Fixture.check(
        \\fn many(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32) -> i32 { return a; }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
}

test "sema: backend argument limit is diagnosed" {
    var f = try Fixture.check(
        \\fn many(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32) -> i32 { return a; }
        \\fn main() -> i32 { return many(1, 2, 3, 4, 5, 6, 7); }
    , .{});
    defer f.deinit();
    var found_unsupported = false;
    for (f.diags.items.items) |d| {
        if (d.kind == .unsupported) found_unsupported = true;
    }
    try testing.expect(found_unsupported);
}

test "sema: struct with literal, access and slot layout" {
    var f = try Fixture.check(
        \\struct Point { x: i32, y: bool }
        \\fn main() -> i32 {
        \\    var p: Point = Point { x: 1, y: true };
        \\    p.x = p.x + 2;
        \\    let q: Point = p;
        \\    if q.y { return q.x; }
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
    const checked = f.checked.?;

    try testing.expectEqual(@as(usize, 1), checked.structs.len);
    try testing.expectEqualStrings("Point", checked.structs[0].decl.name);
    try testing.expectEqual(@as(usize, 2), checked.structs[0].fields.len);
    try testing.expectEqual(Type.i32, checked.structs[0].fields[0].typ);
    try testing.expectEqual(Type.bool, checked.structs[0].fields[1].typ);

    // A struct occupies one base slot + one slot per field: p, q = 2 * 3 slots.
    try testing.expectEqual(@as(u32, 6), checked.functions[0].slot_count);
    try testing.expectEqual(Type.aggregate, checked.symbols[0].typ);
    try testing.expectEqual(@as(u32, 0), checked.symbols[0].struct_id);
    try testing.expectEqual(@as(u32, 0), checked.symbols[0].slot);
    try testing.expectEqual(@as(u32, 3), checked.symbols[1].slot);
}

test "sema: missing field on read and on write" {
    var f = try Fixture.check(
        \\struct P { x: i32 }
        \\fn main() -> i32 {
        \\    var p: P = P { x: 1 };
        \\    p.y = 2;
        \\    return p.z;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 2), f.diags.count());
    try testing.expectEqual(diagnostics.Kind.undefined_field, f.diags.items.items[0].kind);
    try testing.expectEqual(diagnostics.Kind.undefined_field, f.diags.items.items[1].kind);
}

test "sema: incomplete struct literal with a repeated field" {
    var f = try Fixture.check(
        \\struct P { x: i32, y: i32 }
        \\fn main() -> i32 {
        \\    let a: P = P { x: 1 };
        \\    let b: P = P { x: 1, x: 2, y: 3 };
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 2), f.diags.count());
    try testing.expectEqual(diagnostics.Kind.invalid_struct_literal, f.diags.items.items[0].kind);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "does not initialize field 'y'") != null);
    try testing.expectEqual(diagnostics.Kind.invalid_struct_literal, f.diags.items.items[1].kind);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[1].message, "repeated") != null);
}

test "sema: assignment to a field of an immutable variable" {
    var f = try Fixture.check(
        \\struct P { x: i32 }
        \\fn main() -> i32 {
        \\    let p: P = P { x: 1 };
        \\    p.x = 2;
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .immutable_assignment);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "declared with 'let'") != null);
}

test "sema: struct by value in parameter, return and argument is accepted" {
    var f = try Fixture.check(
        \\struct P { x: i32, y: i32 }
        \\fn id(p: P) -> P { return p; }
        \\fn sum(p: P) -> i32 { return p.x + p.y; }
        \\fn main() -> i32 {
        \\    let a: P = P { x: 1, y: 2 };
        \\    let b = id(a);
        \\    let c: P = id(P { x: 3, y: 4 });
        \\    return sum(b) + sum(c);
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());

    const checked = f.checked.?;
    // Nominal identities preserved in the signature and the return.
    try testing.expectEqual(Type.aggregate, checked.functions[0].return_type);
    try testing.expectEqual(@as(u32, 0), checked.functions[0].return_struct_id);
    try testing.expectEqual(@as(u32, 0), checked.functions[0].param_struct_ids[0]);
    // A variable inferred from a call returning a struct keeps the right struct.
    try testing.expectEqual(Type.aggregate, checked.symbols[4].typ);
    try testing.expectEqual(@as(u32, 0), checked.symbols[4].struct_id);
}

test "sema: returned struct with 7 fields exceeds the backend" {
    var f = try Fixture.check(
        \\struct Grande { a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32 }
        \\fn grande() -> Grande { return Grande { a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7 }; }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "returns a struct with 7 fields") != null);
}

test "sema: different structs are not interchangeable as arguments" {
    var f = try Fixture.check(
        \\struct A { x: i32 }
        \\struct B { x: i32 }
        \\fn usa(a: A) -> i32 { return a.x; }
        \\fn main() -> i32 {
        \\    let b: B = B { x: 1 };
        \\    return usa(b);
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "is struct 'B', expected 'A'") != null);
}

test "sema: struct return with swapped identity is diagnosed" {
    var f = try Fixture.check(
        \\struct A { x: i32 }
        \\struct B { x: i32 }
        \\fn make() -> A { return B { x: 1 }; }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_return);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "expected struct 'A' in return, found 'B'") != null);
}

test "sema: struct counts one register per field in signature and call" {
    var f = try Fixture.check(
        \\struct Three { a: i32, b: i32, c: i32 }
        \\struct Four { a: i32, b: i32, c: i32, d: i32 }
        \\fn fits(p: Three, x: i32, s: str) -> i32 { return x; }
        \\fn does_not_fit(p: Four, x: i32, y: i32, z: i32) -> i32 { return x + y + z; }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "function 'does_not_fit' uses 7 parameter registers") != null);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "each struct field one") != null);
}

test "sema: nested, empty and duplicated structs are diagnosed" {
    var f = try Fixture.check(
        \\struct Empty {}
        \\struct Inner { v: i32 }
        \\struct Outer { i: Inner }
        \\struct Inner { v: i32 }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try testing.expect(f.diags.count() >= 3);
    var saw_empty = false;
    var saw_nested = false;
    var saw_dup = false;
    for (f.diags.items.items) |d| {
        switch (d.kind) {
            .unsupported => if (std.mem.indexOf(u8, d.message, "with no fields") != null) {
                saw_empty = true;
            } else if (std.mem.indexOf(u8, d.message, "struct field") != null) {
                saw_nested = true;
            },
            .duplicate_declaration => saw_dup = true,
            else => {},
        }
    }
    try testing.expect(saw_empty);
    try testing.expect(saw_nested);
    try testing.expect(saw_dup);
}

test "sema: unknown struct and field with the wrong type" {
    var f = try Fixture.check(
        \\struct P { x: i32 }
        \\fn main() -> i32 {
        \\    let a: Q = Q { x: 1 };
        \\    let b: P = P { x: true };
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try testing.expect(f.diags.count() >= 3);
    try testing.expectEqual(diagnostics.Kind.unknown_type, f.diags.items.items[0].kind); // annotation 'Q'
    var saw_unknown_struct = false;
    var saw_mismatch = false;
    for (f.diags.items.items) |d| {
        switch (d.kind) {
            .unknown_type => if (std.mem.indexOf(u8, d.message, "struct 'Q' is not declared") != null) {
                saw_unknown_struct = true;
            },
            .type_mismatch => saw_mismatch = true,
            else => {},
        }
    }
    try testing.expect(saw_unknown_struct);
    try testing.expect(saw_mismatch);
}

test "sema: struct used as a condition or in a comparison" {
    var f = try Fixture.check(
        \\struct P { x: i32 }
        \\fn main() -> i32 {
        \\    let a: P = P { x: 1 };
        \\    let b: P = P { x: 1 };
        \\    if a == b { return 1; }
        \\    if a { return 2; }
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 2), f.diags.count());
    try testing.expectEqual(diagnostics.Kind.type_mismatch, f.diags.items.items[0].kind);
    try testing.expectEqual(diagnostics.Kind.invalid_condition, f.diags.items.items[1].kind);
}

test "sema: struct literal as a loose expression is rejected" {
    var f = try Fixture.check(
        \\struct P { x: i32 }
        \\fn main() -> i32 {
        \\    P { x: 1 };
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
}

test "sema: different struct in annotation and initializer" {
    var f = try Fixture.check(
        \\struct A { x: i32 }
        \\struct B { x: i32 }
        \\fn main() -> i32 {
        \\    let a: A = B { x: 1 };
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "struct 'B'") != null);
}

test "sema: string literal infers 'str' and occupies two slots" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let s = "abc";
        \\    let t: str = s;
        \\    print(t);
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());

    const checked = f.checked.?;
    try testing.expectEqual(Type.str, checked.symbols[0].typ);
    try testing.expectEqual(@as(u32, 2), checked.symbols[1].slot);
    try testing.expectEqual(@as(u32, 4), checked.functions[0].slot_count);
}

test "sema: 'print' accepts a str variable and is void" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    var s: str = "a";
        \\    s = "b";
        \\    print(s);
        \\    print("literal");
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: 'print' with the wrong type is diagnosed" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    print(1);
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "'print' expects 'str'") != null);
}

test "sema: 'print' requires exactly one argument" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    print("a", "b");
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_call);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "received 2") != null);
}

test "sema: 'print' without an argument is diagnosed" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    print();
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_call);
}

test "sema: 'str' takes part in no arithmetic" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let n = "a" + 1;
        \\    return n;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "'str'") != null);
}

test "sema: 'str' comparison with == and != is accepted" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let s = "a";
        \\    let t = "b";
        \\    if s == t { return 1; }
        \\    if s != "a" { return 2; }
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: 'str' comparison with relational operators is rejected" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let s = "a";
        \\    let t = "b";
        \\    if s < t { return 1; }
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "expects two 'i32'") != null);
}

test "sema: 'str' as a condition is rejected" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let s = "a";
        \\    if s { return 1; }
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_condition);
}

test "sema: 'str' is accepted as parameter and as return" {
    var f = try Fixture.check(
        \\fn eco(s: str) -> str { return s; }
        \\fn mostra(s: str) -> i32 { print(s); return 0; }
        \\fn main() -> i32 {
        \\    let a = eco("kyn");
        \\    print(a);
        \\    return mostra(eco(a));
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());

    const checked = f.checked.?;
    // A `str` parameter occupies two slots (pointer and length).
    try testing.expectEqual(Type.str, checked.functions[0].params[0]);
    try testing.expectEqual(Type.str, checked.functions[0].return_type);
    try testing.expectEqual(@as(u32, 2), checked.functions[1].slot_count);
}

test "sema: register limit counts 'str' as two" {
    var f = try Fixture.check(
        \\fn four(a: str, b: str, c: str, d: str) -> i32 { return 0; }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "uses 8 parameter registers") != null);
}

test "sema: three 'str' parameters fit in the six registers" {
    var f = try Fixture.check(
        \\fn tres(a: str, b: str, c: str) -> i32 {
        \\    print(a);
        \\    print(b);
        \\    print(c);
        \\    return 0;
        \\}
        \\fn main() -> i32 { return tres("a", "b", "c"); }
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: 'main' cannot return 'str'" {
    var f = try Fixture.check(
        \\fn main() -> str { return "a"; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_main);
}

test "sema: 'str' argument where 'i32' is expected is diagnosed" {
    var f = try Fixture.check(
        \\fn dobro(n: i32) -> i32 { return n + n; }
        \\fn main() -> i32 { return dobro("a"); }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "must be 'i32', found 'str'") != null);
}

test "sema: 'str' return without a value is diagnosed" {
    var f = try Fixture.check(
        \\fn nome() -> str { return; }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_return);
}

test "sema: function returning 'str' must end with return" {
    var f = try Fixture.check(
        \\fn nome(b: bool) -> str {
        \\    if b { return "a"; }
        \\}
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_return);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "with value 'str'") != null);
}

test "sema: field of type 'str' is diagnosed" {
    var f = try Fixture.check(
        \\struct P { name: str }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "type 'str'") != null);
}

test "sema: name 'print' is reserved" {
    var f = try Fixture.check(
        \\fn print(v: i32) -> void {}
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "reserved") != null);
}

test "sema: loose string literal is rejected" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    "texto";
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "print") != null);
}

test "sema: assigning to an immutable 'str' is diagnosed" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let s = "a";
        \\    s = "b";
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .immutable_assignment);
}

test "sema: variable cannot take a 'void' value inferred from a call" {
    var f = try Fixture.check(
        \\fn nada() { }
        \\fn main() -> i32 {
        \\    let x = nada();
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "'void' cannot be stored") != null);
}

test "sema: value annotation with a 'void' initializer gives a single diagnostic" {
    var f = try Fixture.check(
        \\fn nada() { }
        \\fn main() -> i32 {
        \\    let x: i32 = nada();
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
}

test "sema: explicit 'void' annotation on a variable is rejected" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let x: void = 1;
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
}

test "sema: 'print' produces no value for variable initialization" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let x = print("a");
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
}

test "sema: 'print_i32' accepts an i32 expression" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let x = 6 * 7;
        \\    print_i32(x);
        \\    print_i32(0 - 1);
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: 'print_i32' with the wrong type is diagnosed" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    print_i32("texto");
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "'print_i32' expects 'i32'") != null);
}

test "sema: 'print_i32' requires exactly one argument" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    print_i32();
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_call);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "received 0") != null);
}

test "sema: 'print_i32' with two arguments is diagnosed" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    print_i32(1, 2);
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_call);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "received 2") != null);
}

test "sema: name 'print_i32' is reserved as well" {
    var f = try Fixture.check(
        \\fn print_i32(n: i32) -> void { }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "reserved") != null);
}

test "sema: 'print_i32' produces no value for variable initialization" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let x = print_i32(1);
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
}

test "sema: enum case without payload and exhaustive switch are accepted" {
    var f = try Fixture.check(
        \\enum Color { Red, Green, Blue }
        \\fn main() -> i32 {
        \\    let c = Color.Green;
        \\    var total: i32 = 0;
        \\    switch c {
        \\        Red => { total = 1; }
        \\        Green => { total = 2; }
        \\        Blue => { total = 3; }
        \\    }
        \\    return total;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());

    const checked = f.checked.?;
    try testing.expectEqual(@as(usize, 1), checked.enums.len);
    try testing.expectEqualStrings("Color", checked.enums[0].decl.name);
    try testing.expectEqual(@as(usize, 3), checked.enums[0].cases.len);
    try testing.expectEqual(@as(i32, 0), checked.enums[0].cases[0].tag);
    try testing.expectEqual(@as(i32, 2), checked.enums[0].cases[2].tag);
    try testing.expectEqual(Type.enumeration, checked.symbols[0].typ);
    // Tag slot + payload slot for the enum, one slot for the counter.
    try testing.expectEqual(@as(u32, 3), checked.functions[0].slot_count);
}

test "sema: payload binding declares an i32 symbol for the arm" {
    var f = try Fixture.check(
        \\enum Shape { Circle(i32), Empty }
        \\fn main() -> i32 {
        \\    let s = Shape.Empty;
        \\    switch s {
        \\        Circle(r) => { return r; }
        \\        Empty => { return 0; }
        \\    }
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());

    const sw = f.checked.?.functions[0].decl.body[1].kind.switch_stmt;
    try testing.expectEqual(@as(usize, 2), sw.arms.len);
    try testing.expectEqual(@as(u32, 0), sw.arms[0].resolved_case.?);
    try testing.expectEqual(Type.i32, f.checked.?.symbols[sw.arms[0].binding_symbol.?].typ);
    // `r` lives in its own scope: it is not visible after the switch.
    try testing.expectEqual(@as(usize, 2), f.checked.?.functions[0].symbol_count);
}

test "sema: non-exhaustive switch lists the missing cases" {
    var f = try Fixture.check(
        \\enum Color { Red, Green, Blue }
        \\fn main() -> i32 {
        \\    let c = Color.Red;
        \\    switch c {
        \\        Red => { return 1; }
        \\    }
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .non_exhaustive_switch);
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[0].message, "missing 'Green', 'Blue'") != null,
    );
}

test "sema: 'else' arm in an exhaustive switch is unreachable" {
    var f = try Fixture.check(
        \\enum Color { Red, Green }
        \\fn main() -> i32 {
        \\    let c = Color.Red;
        \\    switch c {
        \\        Red => { return 1; }
        \\        Green => { return 2; }
        \\        else => { return 3; }
        \\    }
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unreachable_arm);
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[0].message, "already covers every case") != null,
    );
}

test "sema: unknown and duplicated cases are diagnosed" {
    var f = try Fixture.check(
        \\enum Color { Red, Green }
        \\fn main() -> i32 {
        \\    let c = Color.Red;
        \\    switch c {
        \\        Purple => { return 1; }
        \\        Red => { return 2; }
        \\        Red => { return 3; }
        \\        Green => { return 4; }
        \\    }
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 2), f.diags.count());
    try testing.expectEqual(diagnostics.Kind.unknown_case, f.diags.items.items[0].kind);
    try testing.expectEqual(diagnostics.Kind.invalid_switch_arm, f.diags.items.items[1].kind);
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[1].message, "already handled") != null,
    );
}

test "sema: payload binding rules" {
    var f = try Fixture.check(
        \\enum Shape { Circle(i32), Empty }
        \\fn main() -> i32 {
        \\    let s = Shape.Empty;
        \\    switch s {
        \\        Circle => { return 1; }
        \\        Empty(x) => { return 2; }
        \\    }
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 2), f.diags.count());
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[0].message, "carries a payload; bind it with 'Circle(name)'") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[1].message, "has no payload; 'x' cannot be bound") != null,
    );
}

test "sema: constructor payload is checked" {
    var f = try Fixture.check(
        \\enum Shape { Circle(i32), Empty }
        \\fn main() -> i32 {
        \\    let a = Shape.Circle(true);
        \\    let b = Shape.Circle(1, 2);
        \\    let c = Shape.Empty(1);
        \\    let d = Shape.Circle;
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 4), f.diags.count());
    try testing.expectEqual(diagnostics.Kind.type_mismatch, f.diags.items.items[0].kind);
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[0].message, "payload of 'Shape.Circle' has type 'i32', found 'bool'") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[1].message, "expects 1 payload argument, received 2") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[2].message, "has no payload; use 'Shape.Empty'") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[3].message, "needs a payload: use 'Shape.Circle(value)'") != null,
    );
}

test "sema: enums are nominal in annotations and assignments" {
    var f = try Fixture.check(
        \\enum A { One, Two }
        \\enum B { One, Two }
        \\fn main() -> i32 {
        \\    let a: A = B.One;
        \\    var b: A = A.Two;
        \\    b = B.One;
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 2), f.diags.count());
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[0].message, "is enum 'B', but the annotation is 'A'") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[1].message, "is enum 'A', but the assigned value is enum 'B'") != null,
    );
}

test "sema: enum in a struct field is unsupported" {
    var f = try Fixture.check(
        \\enum Color { Red }
        \\struct Holder { c: Color }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[0].message, "of enum type is not supported yet") != null,
    );
}

test "sema: enums cross calls by value" {
    var f = try Fixture.check(
        \\enum Color { Red, Green, Blue }
        \\fn pick(n: i32) -> Color {
        \\    if n == 0 { return Color.Red; }
        \\    if n == 1 { return Color.Green; }
        \\    return Color.Blue;
        \\}
        \\fn label(c: Color) -> i32 {
        \\    var value: i32 = 0;
        \\    switch c {
        \\        Red => { value = 1; }
        \\        Green => { value = 2; }
        \\        Blue => { value = 3; }
        \\    }
        \\    return value;
        \\}
        \\fn main() -> i32 {
        \\    let c = pick(1);
        \\    return label(c) + label(pick(2));
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());

    const checked = f.checked.?;
    const pick = checked.findFunction("pick").?;
    try testing.expectEqual(Type.enumeration, checked.functions[pick].return_type);
    try testing.expectEqual(@as(u32, 0), checked.functions[pick].return_enum_id);

    const label = checked.findFunction("label").?;
    try testing.expectEqual(Type.enumeration, checked.functions[label].params[0]);
    try testing.expectEqual(@as(u32, 0), checked.functions[label].param_enum_ids[0]);
    // The enum parameter takes two slots (tag + payload), the local one.
    try testing.expectEqual(@as(u32, 3), checked.functions[label].slot_count);
    // `let c = pick(1);` infers the enum from the call.
    const c_symbol = checked.symbols[checked.functions[2].symbol_start];
    try testing.expectEqual(Type.enumeration, c_symbol.typ);
    try testing.expectEqual(@as(u32, 0), c_symbol.enum_id);
}

test "sema: enum identity is checked in arguments, returns and annotations" {
    var f = try Fixture.check(
        \\enum A { One, Two }
        \\enum B { One, Two }
        \\fn paint(a: A) -> i32 { return 0; }
        \\fn give() -> A { return B.One; }
        \\fn main() -> i32 {
        \\    let a: A = B.Two;
        \\    let painted = paint(B.One);
        \\    return painted;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 3), f.diags.count());
    // Order follows the phases: signatures first, then the bodies.
    try testing.expect(sawMessage(&f, "expected enum 'A' in return, found 'B'"));
    try testing.expect(sawMessage(&f, "is enum 'B', but the annotation is 'A'"));
    try testing.expect(sawMessage(&f, "argument 1 of 'paint' is enum 'B', expected 'A'"));
}

test "sema: an enum parameter counts two registers" {
    var f = try Fixture.check(
        \\enum Shape { Circle(i32), Empty }
        \\fn too_wide(a: Shape, b: Shape, c: Shape, d: i32) -> i32 { return 0; }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[0].message, "uses 7 parameter registers") != null,
    );

    var g = try Fixture.check(
        \\enum Shape { Circle(i32), Empty }
        \\fn ok(a: Shape, b: Shape, c: i32) -> i32 { return 0; }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer g.deinit();
    try testing.expectEqual(@as(usize, 0), g.diags.count());
}

test "sema: switch requires an enum value" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let x = 1;
        \\    switch x {
        \\        Red => { return 1; }
        \\    }
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[0].message, "'switch' requires an enum value, found 'i32'") != null,
    );
}

test "sema: switch over a constructed value is unsupported" {
    var f = try Fixture.check(
        \\enum Color { Red }
        \\fn main() -> i32 {
        \\    switch Color.Red {
        \\        Red => { return 1; }
        \\    }
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[0].message, "store it in a variable first") != null,
    );
}

test "sema: duplicated case inside an enum is diagnosed" {
    var f = try Fixture.check(
        \\enum Color { Red, Red }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .duplicate_declaration);
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[0].message, "case 'Red' already declared in enum 'Color'") != null,
    );
}

test "sema: a struct and an enum cannot share a name" {
    var f = try Fixture.check(
        \\struct Color { x: i32 }
        \\enum Color { Red }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .duplicate_declaration);
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[0].message, "enum 'Color' already declared as a struct or enum") != null,
    );
}

test "sema: non-i32 payload and empty enum are unsupported" {
    var f = try Fixture.check(
        \\enum Weird { Box(bool) }
        \\enum Nothing { }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 2), f.diags.count());
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[0].message, "payload type 'bool' is not supported yet") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[1].message, "with no cases is not supported") != null,
    );
}

test "sema: operators on enum values are unsupported" {
    var f = try Fixture.check(
        \\enum Color { Red, Green }
        \\fn main() -> i32 {
        \\    let a = Color.Red;
        \\    let b = Color.Green;
        \\    if a == b { return 1; }
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(
        std.mem.indexOf(u8, f.diags.items.items[0].message, "'==' is not supported on an enum value") != null,
    );
}

test "sema: an enum value cannot be used as a statement" {
    var f = try Fixture.check(
        \\enum Color { Red }
        \\fn main() -> i32 {
        \\    Color.Red;
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
}

test "sema: alwaysReturns understands a switch with every arm returning" {
    var f = try Fixture.check(
        \\enum Color { Red, Green }
        \\fn pick(c: i32) -> i32 {
        \\    let color = Color.Red;
        \\    switch color {
        \\        Red => { return 1; }
        \\        Green => { return 2; }
        \\    }
        \\}
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: methods resolve through the receiver type and stay nominal" {
    var f = try Fixture.check(
        \\struct Point { x: i32, y: i32 }
        \\struct Pair { a: i32, b: i32 }
        \\enum Shape { Circle(i32), Empty }
        \\impl Point {
        \\    fn sum(self: Point) -> i32 { return self.x + self.y; }
        \\    fn shifted(self: Point, dx: i32, dy: i32) -> Point {
        \\        return Point { x: self.x + dx, y: self.y + dy };
        \\    }
        \\}
        \\impl Shape {
        \\    fn weight(self: Shape) -> i32 { return 1; }
        \\    fn grow(self: Shape) -> Shape { return Shape.Empty; }
        \\}
        \\fn free_sum(p: Point) -> i32 { return p.sum(); }
        \\fn main() -> i32 {
        \\    let p = Point { x: 1, y: 2 };
        \\    let q = p.shifted(1, 1);
        \\    let s = Shape.Circle(3);
        \\    let t = s.grow();
        \\    return p.sum() + q.sum() + free_sum(p) + s.weight() + t.weight();
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());

    const checked = f.checked.?;
    // Methods are registered with their owner and mangled symbol name.
    const sum = checked.findMethod(.{ .struct_id = 0 }, "sum").?;
    try testing.expect(checked.functions[sum].isMethod());
    try testing.expectEqualStrings("Point_sum", checked.functions[sum].symbol_name);
    try testing.expectEqualStrings("sum", checked.functions[sum].decl.name);
    try testing.expectEqual(@as(u32, 0), checked.functions[sum].owner_struct_id.?);
    try testing.expectEqualStrings("Point", checked.structs[0].decl.name);

    const weight = checked.findMethod(.{ .enum_id = 0 }, "weight").?;
    try testing.expectEqualStrings("Shape_weight", checked.functions[weight].symbol_name);
    // The receiver is the only parameter of `fn weight(self: Shape)`.
    try testing.expectEqual(@as(usize, 1), checked.functions[weight].params.len);

    // A method is never reachable as a free function, and `main` is a free
    // function, not a method.
    try testing.expect(checked.findFunction("sum") == null);
    try testing.expect(checked.findFunction("main") != null);
    try testing.expect(checked.findMethod(.{ .struct_id = 1 }, "sum") == null);
}

test "sema: a method call checks its arguments like a free call" {
    var f = try Fixture.check(
        \\struct Point { x: i32 }
        \\enum Shape { Circle(i32), Empty }
        \\impl Point {
        \\    fn move(self: Point, dx: i32) -> i32 { return self.x + dx; }
        \\}
        \\impl Shape {
        \\    fn swap(self: Shape, other: Shape) -> i32 { return 0; }
        \\}
        \\fn main() -> i32 {
        \\    let p = Point { x: 1 };
        \\    let s = Shape.Circle(2);
        \\    let a = p.move(1, 2);
        \\    let b = p.move(s);
        \\    let c = s.swap(p);
        \\    return a + b + c;
        \\}
    , .{});
    defer f.deinit();
    try testing.expect(sawMessage(&f, "'Point.move' expects 1 argument(s), received 2"));
    try testing.expect(sawMessage(&f, "argument 1 of 'Point.move' must be 'i32', found 'enum'"));
    try testing.expect(sawMessage(&f, "argument 1 of 'Shape.swap' must be 'enum', found 'struct'"));
}

test "sema: method declarations are validated" {
    var f = try Fixture.check(
        \\struct Point { x: i32 }
        \\struct Pair { a: i32 }
        \\impl Point {
        \\    fn sum(self: Point) -> i32 { return self.x; }
        \\    fn sum(self: Point) -> i32 { return 0; }
        \\    fn x(self: Point) -> i32 { return self.x; }
        \\    fn wrong(self: Pair) -> i32 { return 0; }
        \\    fn noargs() -> i32 { return 1; }
        \\    fn misnamed(that: Point) -> i32 { return 2; }
        \\    fn main() -> i32 { return 3; }
        \\}
        \\impl Missing {
        \\    fn ghost(self: Missing) -> i32 { return 4; }
        \\}
        \\fn Point_sum() -> i32 { return 5; }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try testing.expect(sawMessage(&f, "impl target 'Missing' is not a declared struct or enum"));
    try testing.expect(sawMessage(&f, "method 'sum' already declared for 'Point'"));
    try testing.expect(sawMessage(&f, "struct 'Point' already has a field 'x'; a method cannot reuse the name"));
    try testing.expect(sawMessage(&f, "parameter 'self' of method 'Point.wrong' must have type 'Point', found 'Pair'"));
    try testing.expect(sawMessage(&f, "method 'Point.noargs' must declare its receiver: 'self: Point'"));
    try testing.expect(sawMessage(&f, "the first parameter of method 'Point.misnamed' must be named 'self', found 'that'"));
    try testing.expect(sawMessage(&f, "method 'main' is not supported; declare 'fn main()' outside the 'impl'"));
    try testing.expect(sawMessage(&f, "function 'Point_sum' shares the symbol 'kyn_Point_sum' with the method 'sum'"));
}

test "sema: unknown methods and non-method receivers are diagnosed" {
    var f = try Fixture.check(
        \\struct Point { x: i32 }
        \\struct Sink { v: i32 }
        \\impl Point {
        \\    fn sum(self: Point) -> i32 { return self.x; }
        \\}
        \\fn main() -> i32 {
        \\    let p = Point { x: 1 };
        \\    let sink = Sink { v: 2 };
        \\    let n: i32 = 3;
        \\    let a = p.nope();
        \\    let b = sink.sum();
        \\    let c = n.sum();
        \\    let d = Point.sum(p);
        \\    return a + b + c + d;
        \\}
    , .{});
    defer f.deinit();
    try testing.expect(sawMessage(&f, "'Point' has no method 'nope'"));
    try testing.expect(sawMessage(&f, "'Sink' has no method 'sum'"));
    try testing.expect(sawMessage(&f, "method calls are only supported on struct and enum values, but 'n' has type 'i32'"));
    try testing.expect(sawMessage(&f, "struct 'Point' is a type, not a value; call the method on a variable of type 'Point'"));
}

test "sema: the method receiver counts as argument 1 in the register limit" {
    var f = try Fixture.check(
        \\struct Wide { a: i32, b: i32, c: i32 }
        \\impl Wide {
        \\    fn pad(self: Wide, x: i32, y: i32, z: i32, w: i32) -> i32 {
        \\        return x + y + z + w;
        \\    }
        \\}
        \\fn main() -> i32 {
        \\    let w = Wide { a: 1, b: 2, c: 3 };
        \\    return w.pad(1, 2, 3, 4);
        \\}
    , .{});
    defer f.deinit();
    try testing.expect(sawMessage(&f, "method 'Wide.pad' uses 7 parameter registers"));
    try testing.expect(sawMessage(&f, "call to 'Wide.pad' uses 7 registers"));
}

test "sema: generic ptr annotation keeps known pointee and static type names" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    var x: i32 = 1;
        \\    var y: u8 = 2 as u8;
        \\    let p: ptr = &x;
        \\    let q: ptr = &y;
        \\    let eq: bool = p == q;
        \\    return *p;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
    const symbols = f.checked.?.symbols;
    try testing.expectEqual(Type.i32, symbols[2].typ.ptr.pointee.*);
    try testing.expectEqual(Type.u8, symbols[3].typ.ptr.pointee.*);
    try testing.expectEqualStrings("ptr<i32>", symbols[2].typ.name());
    try testing.expectEqualStrings("ptr<u8>", symbols[3].typ.name());
    try testing.expectEqual(Type.bool, symbols[4].typ);
}

test "sema: unknown pointee and temporary addresses have diagnostics" {
    var unknown = try Fixture.check(
        \\fn read(p: ptr) -> i32 { return *p; }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer unknown.deinit();
    try testing.expect(sawMessage(&unknown, "pointee must have a known scalar type"));

    var temporary = try Fixture.check("fn main() -> i32 { let p: ptr = &42; return 0; }", .{});
    defer temporary.deinit();
    try testing.expect(sawMessage(&temporary, "requires an addressable scalar"));
}

test "sema: bool cannot be cast to integer in the backend" {
    var f = try Fixture.check("fn main() -> i32 { return true as i32; }", .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(sawMessage(&f, "cannot cast from 'bool'"));
}

test "sema: pointer arithmetic validates known pointee and operators" {
    var multiply = try Fixture.check(
        \\fn main() -> i32 { var x = 1; let p = &x; let bad = p * 2; return 0; }
    , .{});
    defer multiply.deinit();
    try testing.expect(sawMessage(&multiply, "pointer arithmetic requires a known pointee"));

    var unknown = try Fixture.check(
        \\fn advance(p: ptr) -> ptr { return p + 1; }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer unknown.deinit();
    try testing.expect(sawMessage(&unknown, "pointer arithmetic requires a known pointee"));

    var relational = try Fixture.check(
        \\fn main() -> i32 { var x = 1; var y = 2; if &x < &y { return 1; } return 0; }
    , .{});
    defer relational.deinit();
    try testing.expect(sawMessage(&relational, "expects two operands of the same integer type"));
}

test "sema: typed pointers can pass through generic pointer fields and parameters" {
    var f = try Fixture.check(
        \\struct Box { p: ptr }
        \\fn boxed(p: ptr) -> Box { return Box { p: p }; }
        \\fn main() -> i32 {
        \\    var x: i32 = 3;
        \\    var b: Box = boxed(&x);
        \\    b.p = &x;
        \\    if b.p != &x { return 1; }
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: erased pointer cannot regain a known pointee by assignment" {
    var f = try Fixture.check(
        \\fn erase(p: ptr) -> ptr { return p; }
        \\fn main() -> i32 {
        \\    var x: i32 = 3;
        \\    var typed: ptr = &x;
        \\    typed = erase(&x);
        \\    return *typed;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(sawMessage(&f, "ptr<i32>"));
}

test "sema: pointers to different structs preserve nominal identity" {
    var f = try Fixture.check(
        \\struct A { x: i32 }
        \\struct B { x: i32 }
        \\fn main() -> i32 {
        \\    var a: A = A { x: 1 };
        \\    var b: B = B { x: 2 };
        \\    var p = &a;
        \\    p = &b;
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(sawMessage(&f, "ptr<A>"));
    try testing.expect(sawMessage(&f, "ptr<B>"));
}
