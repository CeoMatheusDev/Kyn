//! Kyn AST (bootstrap).
//!
//! Ownership: every node, parameter slice and statement list is allocated by
//! the allocator passed to the parser (in practice, one arena per compilation).
//! There is no individual free: the owner is whoever created the allocator.
//!
//! Nodes reference the original text through slices (`[]const u8`), no copies.
//!
//! Semantic analysis annotates nodes with indices (`Expr.resolved`,
//! `Stmt.decl_symbol`, `Call.callee_fn`); the AST stores no types — the analysis
//! result lives in `sema.Checked`, keeping the AST free of semantic decisions.

const std = @import("std");
const Span = @import("../span.zig").Span;

/// Type name exactly as written in the source.
pub const TypeName = struct {
    name: []const u8,
    span: Span,
};

pub const Program = struct {
    /// Imports declared in the file, in source order. The module loader
    /// resolves them; the flattened program handed to semantics/backends has
    /// an empty `imports`.
    imports: []Import = &.{},
    /// `struct` declarations of every module, in pre-order.
    structs: []*StructDecl = &.{},
    /// `enum` declarations of every module, in pre-order.
    enums: []*EnumDecl = &.{},
    /// `impl` blocks of every module, in pre-order.
    impls: []*ImplBlock = &.{},
    /// Every function declaration in source order, free functions and methods
    /// mixed. Methods also belong to their `ImplBlock`.
    functions: []*Function,
    span: Span,
};

/// `struct Name { field: type, ... }` — top-level declaration.
pub const StructDecl = struct {
    name: []const u8,
    name_span: Span,
    fields: []Field,
    /// Source file of origin, assigned by the module loader.
    file_id: u32 = 0,
    span: Span,
};

/// `enum Name { Case, Case(type), ... }` — top-level declaration.
///
/// Cases are ordered: the index in this slice is the tag used by the backends,
/// so declaration order is part of the value representation.
pub const EnumDecl = struct {
    name: []const u8,
    name_span: Span,
    cases: []EnumCase,
    /// Source file of origin, assigned by the module loader.
    file_id: u32 = 0,
    span: Span,
};

pub const EnumCase = struct {
    name: []const u8,
    name_span: Span,
    /// `null` for a case without payload (`Red`); the payload type name for
    /// `Circle(i32)`. Only `i32` is supported at this stage.
    payload: ?TypeName,
    span: Span,
};

/// `impl Name { fn method(self: Name, ...) -> T { ... } }` — methods of a
/// struct or enum. The methods are also part of `Program.functions` (the single
/// list the pipeline walks); this block keeps the declaration order and the
/// target span for diagnostics.
pub const ImplBlock = struct {
    type_name: TypeName,
    methods: []*Function,
    /// Source file of origin, assigned by the module loader.
    file_id: u32 = 0,
    span: Span,
};

pub const Field = struct {
    name: []const u8,
    name_span: Span,
    type_name: TypeName,
    span: Span,
};

/// `import "path";` — path relative to the importing file.
pub const Import = struct {
    path: []const u8,
    path_span: Span,
    span: Span,
};

pub const Function = struct {
    name: []const u8,
    name_span: Span,
    /// Type the function is a method of (`impl Name { ... }`); `null` for a
    /// free function. Methods live in their own name space per type.
    owner_type: ?TypeName = null,
    /// Source file of origin (index into `driver.SourceFile`), assigned by the
    /// module loader; 0 for single-buffer compilations.
    file_id: u32 = 0,
    params: []Param,
    /// `null` when there is no return annotation (`fn main() { ... }`).
    return_type: ?TypeName,
    body: []*Stmt,
    span: Span,
};

pub const Param = struct {
    name: []const u8,
    type_name: TypeName,
    span: Span,
};

pub const Expr = struct {
    span: Span,
    kind: Kind,
    /// Symbol index resolved by semantic analysis (variables).
    resolved: ?u32 = null,

    pub const Kind = union(enum) {
        int_literal: IntLiteral,
        bool_literal: bool,
        /// String literal: bytes between quotes, with no escape interpretation.
        /// The value is a static slice (pointer + length), not a scalar.
        str_literal: []const u8,
        identifier: []const u8,
        call: Call,
        binary: Binary,
        unary: Unary,
        /// `base.field` — today only struct bases with scalar fields.
        field_access: FieldAccess,
        /// `Name { field: value, ... }`
        struct_literal: StructLiteral,
        /// `Enum.Case(value)` — enum constructor with payload. A dotted name
        /// without parentheses is a `field_access` whose base is the enum name.
        method_call: MethodCall,
        /// `expr as Type` — explicit numeric conversion.
        cast: Cast,
    };

    /// `base.name(args)`: an enum constructor (`Shape.Circle(5)`, base is the
    /// enum name) or a method call (`shape.area()`, base is a value). The
    /// parser produces it for any dotted name followed by `(`; semantics
    /// decides which of the two it is.
    pub const MethodCall = struct {
        base: *Expr,
        name: []const u8,
        name_span: Span,
        args: []*Expr,
        /// Enum index resolved by semantic analysis (`null` when the base is
        /// not an enum name).
        resolved_enum: ?u32 = null,
        /// Index of the case in `EnumDecl.cases`.
        resolved_case: ?u32 = null,
        /// Index of the method in `Checked.functions` (method calls only).
        resolved_fn: ?u32 = null,
    };

    /// `expr as Type` — explicit numeric conversion between integer widths.
    pub const Cast = struct {
        expr: *Expr,
        /// Target type name exactly as written in the source.
        type_name: TypeName,
    };

    pub const FieldAccess = struct {
        base: *Expr,
        name: []const u8,
        name_span: Span,
        /// Field index in the struct declaration, filled in by semantic analysis.
        field_index: ?u32 = null,
        /// Enum and case resolved by semantic analysis when the base is an enum
        /// name (`Color.Red`); `field_index` stays null in that case.
        resolved_enum: ?u32 = null,
        resolved_case: ?u32 = null,
    };
    pub const StructLiteral = struct {
        type_name: TypeName,
        fields: []FieldInit,
        /// Struct index resolved by semantic analysis.
        resolved_struct: ?u32 = null,
    };

    pub const FieldInit = struct {
        name: []const u8,
        name_span: Span,
        value: *Expr,
    };

    pub const IntLiteral = struct {
        value: i64,
        text: []const u8,
    };

    pub const BinaryOp = enum {
        add,
        sub,
        mul,
        div,
        mod,
        eq,
        ne,
        lt,
        le,
        gt,
        ge,
        and_op,
        or_op,
        /// Bitwise AND (`&`).
        bitand,
        /// Bitwise XOR (`^`).
        bitxor,
        /// Bitwise OR (`|`).
        bitor,
        /// Shift left (`<<`).
        shl,
        /// Shift right (`>>`).
        shr,

        pub fn spelling(self: BinaryOp) []const u8 {
            return switch (self) {
                .add => "+",
                .sub => "-",
                .mul => "*",
                .div => "/",
                .mod => "%",
                .eq => "==",
                .ne => "!=",
                .lt => "<",
                .le => "<=",
                .gt => ">",
                .ge => ">=",
                .and_op => "&&",
                .or_op => "||",
                .bitand => "&",
                .bitxor => "^",
                .bitor => "|",
                .shl => "<<",
                .shr => ">>",
            };
        }

        pub fn isArithmetic(self: BinaryOp) bool {
            return switch (self) {
                .add, .sub, .mul, .div, .mod => true,
                else => false,
            };
        }

        pub fn isBitwise(self: BinaryOp) bool {
            return switch (self) {
                .bitand, .bitxor, .bitor, .shl, .shr => true,
                else => false,
            };
        }

        pub fn isShift(self: BinaryOp) bool {
            return switch (self) {
                .shl, .shr => true,
                else => false,
            };
        }

        pub fn isComparison(self: BinaryOp) bool {
            return switch (self) {
                .lt, .le, .gt, .ge => true,
                else => false,
            };
        }

        pub fn isLogical(self: BinaryOp) bool {
            return switch (self) {
                .and_op, .or_op => true,
                else => false,
            };
        }
    };

    pub const Binary = struct {
        op: BinaryOp,
        lhs: *Expr,
        rhs: *Expr,
    };

    pub const UnaryOp = enum {
        neg,
        not,
        /// Bitwise complement (`~`).
        bitnot,
        /// Address-of (`&`): yields a pointer to the operand.
        address_of,
        /// Dereference (`*`): yields the value pointed to by the operand.
        dereference,

        pub fn spelling(self: UnaryOp) []const u8 {
            return switch (self) {
                .neg => "-",
                .not => "!",
                .bitnot => "~",
                .address_of => "&",
                .dereference => "*",
            };
        }
    };

    pub const Unary = struct {
        op: UnaryOp,
        operand: *Expr,
    };

    /// Builtin functions recognized by semantics, with no source declaration.
    /// Each field name is the identifier accepted in the source.
    pub const Builtin = enum {
        print,
        print_i32,
    };

    pub const Call = struct {
        callee: []const u8,
        callee_span: Span,
        args: []*Expr,
        /// Index of the function resolved by semantic analysis.
        callee_fn: ?u32 = null,
        /// Filled in by semantic analysis when the call is a builtin
        /// (`callee_fn` stays null in that case).
        builtin: ?Builtin = null,
    };

    pub fn create(arena: std.mem.Allocator, span: Span, kind: Kind) !*Expr {
        const node = try arena.create(Expr);
        node.* = .{ .span = span, .kind = kind };
        return node;
    }
};

pub const Stmt = struct {
    span: Span,
    kind: Kind,
    /// Index of the declared symbol (only `let_decl`), filled in by semantics.
    decl_symbol: ?u32 = null,

    pub const Kind = union(enum) {
        let_decl: VarDecl,
        assign: Assign,
        /// `base.field = value;` — assignment to a struct field.
        field_assign: FieldAssign,
        return_stmt: ?*Expr,
        expr_stmt: *Expr,
        if_stmt: IfStmt,
        while_stmt: WhileStmt,
        switch_stmt: SwitchStmt,
        block: []*Stmt,
    };

    /// `switch value { Case => {...} Case(binding) => {...} else => {...} }`
    pub const SwitchStmt = struct {
        scrutinee: *Expr,
        arms: []SwitchArm,
        else_body: ?[]*Stmt,
        /// Span of the `else` keyword, when present.
        else_span: ?Span = null,
        /// Enum index resolved by semantic analysis.
        resolved_enum: ?u32 = null,
    };

    pub const SwitchArm = struct {
        case_name: []const u8,
        case_span: Span,
        /// `Case(name)` binds the payload; `null` for a bare `Case`.
        binding: ?[]const u8,
        binding_span: ?Span,
        body: []*Stmt,
        span: Span,
        /// Index of the case in `EnumDecl.cases`.
        resolved_case: ?u32 = null,
        /// Symbol declared for the payload binding, filled in by semantics.
        binding_symbol: ?u32 = null,
    };

    pub const VarDecl = struct {
        name: []const u8,
        name_span: Span,
        /// Optional type annotation (`let x: i32 = 1;`).
        type_name: ?TypeName,
        init: *Expr,
        mutable: bool,
    };

    pub const Assign = struct {
        name: []const u8,
        name_span: Span,
        value: *Expr,
        /// Symbol index resolved by semantic analysis.
        resolved: ?u32 = null,
    };

    pub const FieldAssign = struct {
        base: *Expr,
        name: []const u8,
        name_span: Span,
        value: *Expr,
        /// Field index in the struct declaration, filled in by semantic analysis.
        field_index: ?u32 = null,
    };

    pub const IfStmt = struct {
        cond: *Expr,
        then_body: []*Stmt,
        else_body: ?ElseBranch,
    };

    pub const ElseBranch = union(enum) {
        block: []*Stmt,
        if_stmt: *Stmt,
    };

    pub const WhileStmt = struct {
        cond: *Expr,
        body: []*Stmt,
    };

    pub fn create(arena: std.mem.Allocator, span: Span, kind: Kind) !*Stmt {
        const node = try arena.create(Stmt);
        node.* = .{ .span = span, .kind = kind };
        return node;
    }
};

/// Builds an arena-allocated AST slice from a list.
pub fn toOwned(comptime T: type, arena: std.mem.Allocator, list: *std.ArrayList(T)) ![]T {
    return list.toOwnedSlice(arena);
}

test "ast: builds an expression node in an arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lit = try Expr.create(a, .{ .start = 0, .end = 2, .line = 1, .column = 1 }, .{
        .int_literal = .{ .value = 42, .text = "42" },
    });
    try std.testing.expectEqual(@as(i64, 42), lit.kind.int_literal.value);
    try std.testing.expect(lit.resolved == null);
}

test "ast: operators report spelling and category" {
    try std.testing.expectEqualStrings("+", Expr.BinaryOp.add.spelling());
    try std.testing.expect(Expr.BinaryOp.mul.isArithmetic());
    try std.testing.expect(!Expr.BinaryOp.mul.isComparison());
    try std.testing.expect(Expr.BinaryOp.ge.isComparison());
    try std.testing.expect(Expr.BinaryOp.or_op.isLogical());
    try std.testing.expectEqualStrings("!", Expr.UnaryOp.not.spelling());
}
