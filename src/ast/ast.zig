//! src/ast/ast.zig — Árvore sintática do Kyn.
//!
//! Todos os nós são alocados na arena do pipeline e vivem até o fim da
//! compilação; não há desalocação individual nem ciclos de referência.
//! `Expr.type_id` é preenchido pela análise semântica e consumido pelo
//! backend — o parser sempre o deixa como `types.invalid`.

const std = @import("std");
const diag = @import("../diag.zig");
const types = @import("../sema/types.zig");

pub const Span = diag.Span;

pub const Program = struct {
    imports: []const Import = &.{},
    /// Elementos mutáveis: a análise semântica anota tipos dentro dos nós.
    decls: []Decl = &.{},
    /// Span cobrindo todo o arquivo, usado para diagnósticos de nível de módulo.
    span: Span = .{},
};

pub const Import = struct {
    /// Caminho já normalizado (`std::io`, `core`, ...).
    path: []const u8,
    span: Span,
};

pub const Attr = struct {
    name: []const u8,
    args: []const []const u8,
    span: Span,
};

pub const Decl = union(enum) {
    func: Func,
    structure: StructDecl,
    enumeration: EnumDecl,
    impl: ImplDecl,
    extern_func: ExternFunc,
};

pub const Param = struct {
    name: []const u8,
    name_span: Span,
    ty: *TypeExpr,
    span: Span,
};

pub const Func = struct {
    name: []const u8,
    name_span: Span,
    span: Span,
    attrs: []const Attr = &.{},
    is_pub: bool = false,
    params: []const Param = &.{},
    /// `null` significa `void`.
    ret: ?*TypeExpr = null,
    body: Block,
};

pub const ExternFunc = struct {
    name: []const u8,
    name_span: Span,
    span: Span,
    params: []const Param = &.{},
    ret: ?*TypeExpr = null,
    is_variadic: bool = false,
};

pub const Field = struct {
    name: []const u8,
    name_span: Span,
    ty: *TypeExpr,
    span: Span,
};

pub const StructDecl = struct {
    name: []const u8,
    name_span: Span,
    span: Span,
    attrs: []const Attr = &.{},
    is_pub: bool = false,
    fields: []const Field = &.{},
};

pub const EnumVariant = struct {
    name: []const u8,
    span: Span,
};

pub const EnumDecl = struct {
    name: []const u8,
    name_span: Span,
    span: Span,
    attrs: []const Attr = &.{},
    is_pub: bool = false,
    variants: []const EnumVariant = &.{},
};

pub const ImplDecl = struct {
    target: []const u8,
    target_span: Span,
    span: Span,
    methods: []Func = &.{},
};

pub const Block = struct {
    /// Elementos mutáveis: a análise semântica anota tipos dentro dos nós.
    stmts: []Stmt = &.{},
    span: Span,
};

pub const Stmt = union(enum) {
    binding: Binding,
    assign: Assign,
    expr: Expr,
    ret: Return,
    cond: If,
    loop: While,
    range_for: RangeFor,
    break_: Span,
    continue_: Span,
    block: Block,
    unsafe_block: Block,
};

pub const Binding = struct {
    name: []const u8,
    name_span: Span,
    span: Span,
    mutable: bool,
    /// `null` pede inferência a partir do inicializador.
    ty: ?*TypeExpr,
    init: Expr,
};

pub const AssignOp = enum { assign, add, sub, mul, div, rem };

pub const Assign = struct {
    target: Expr,
    op: AssignOp,
    value: Expr,
    span: Span,
};

pub const Return = struct {
    /// `null` para `return;`.
    value: ?Expr,
    span: Span,
};

pub const If = struct {
    cond: Expr,
    then: Block,
    els: ?Else,
    span: Span,
};

pub const Else = union(enum) {
    block: Block,
    cond: *If,
};

pub const While = struct {
    cond: Expr,
    body: Block,
    span: Span,
};

/// `for i in start..end { ... }` — intervalo semiaberto.
pub const RangeFor = struct {
    var_name: []const u8,
    var_span: Span,
    start: Expr,
    end: Expr,
    body: Block,
    span: Span,
};

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    rem,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    and_,
    or_,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,

    pub fn text(self: BinOp) []const u8 {
        return switch (self) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .rem => "%",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .and_ => "&&",
            .or_ => "||",
            .bit_and => "&",
            .bit_or => "|",
            .bit_xor => "^",
            .shl => "<<",
            .shr => ">>",
        };
    }
};

pub const UnOp = enum { neg, not, bit_not };

pub const StructInit = struct {
    name: []const u8,
    name_span: Span,
    value: Expr,
};

pub const ExprKind = union(enum) {
    int_lit: i128,
    float_lit: f64,
    string_lit: []const u8,
    char_lit: u8,
    bool_lit: bool,
    ident: []const u8,
    self_,
    binary: struct { op: BinOp, lhs: *Expr, rhs: *Expr },
    unary: struct { op: UnOp, operand: *Expr },
    call: struct { callee: *Expr, args: []const *Expr },
    field: struct { object: *Expr, name: []const u8 },
    /// Caminho qualificado `Head::tail`: variante de enum, função associada
    /// ou item de módulo.
    path: struct { head: []const u8, tail: []const u8 },
    cast: struct { operand: *Expr, ty: *TypeExpr },
    struct_lit: struct { name: []const u8, inits: []StructInit },
    enum_lit: struct { name: []const u8, variant: []const u8 },
    ref_of: struct { operand: *Expr, mutable: bool },
    deref: *Expr,
};

pub const Expr = struct {
    kind: ExprKind,
    span: Span,
    /// Preenchido pela análise semântica.
    type_id: types.Id = types.invalid,

    pub fn make(alloc: std.mem.Allocator, kind: ExprKind, span: Span) !*Expr {
        const node = try alloc.create(Expr);
        node.* = .{ .kind = kind, .span = span };
        return node;
    }
};

pub const TypeExpr = union(enum) {
    prim: struct { kind: PrimKind, span: Span },
    named: struct { name: []const u8, span: Span },
    ref_: struct { inner: *TypeExpr, mutable: bool, span: Span },
    ptr: struct { inner: *TypeExpr, is_const: bool, span: Span },


    pub fn spanOf(self: *const TypeExpr) Span {
        return switch (self.*) {
            .prim => |p| p.span,
            .named => |n| n.span,
            .ref_ => |r| r.span,
            .ptr => |p| p.span,
        };
    }

    /// Nome legível usado em mensagens de diagnóstico.
    pub fn name(self: *const TypeExpr) []const u8 {
        return switch (self.*) {
            .prim => |p| p.kind.text(),
            .named => |n| n.name,
            .ref_ => |r| if (r.mutable) "&mut ..." else "&...",
            .ptr => |p| if (p.is_const) "*const ..." else "*...",
        };
    }
};

pub const PrimKind = enum {
    i8,
    i16,
    i32,
    i64,
    isize,
    u8,
    u16,
    u32,
    u64,
    usize,
    f32,
    f64,
    bool,
    char,
    str,
    void,

    pub fn text(self: PrimKind) []const u8 {
        return switch (self) {
            .i8 => "i8",
            .i16 => "i16",
            .i32 => "i32",
            .i64 => "i64",
            .isize => "isize",
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .usize => "usize",
            .f32 => "f32",
            .f64 => "f64",
            .bool => "bool",
            .char => "char",
            .str => "str",
            .void => "void",
        };
    }

    /// Reconhece o nome textual do tipo primitivo (`i32`, `str`, ...).
    pub fn fromText(name_text: []const u8) ?PrimKind {
        return std.meta.stringToEnum(PrimKind, name_text);
    }
};

test "primitive type names round-trip" {
    try std.testing.expectEqual(PrimKind.i32, PrimKind.fromText("i32").?);
    try std.testing.expectEqual(PrimKind.bool, PrimKind.fromText("bool").?);
    try std.testing.expectEqual(PrimKind.str, PrimKind.fromText("str").?);
    try std.testing.expectEqual(null, PrimKind.fromText("i33"));
    try std.testing.expectEqualStrings("usize", PrimKind.usize.text());
}
