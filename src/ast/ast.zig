//! AST do Kyn (bootstrap).
//!
//! Ownership: todos os nós, slices de parâmetros e listas de statements são
//! alocados pelo allocator passado ao parser (na prática, uma arena por
//! compilação). Não há liberação individual; o dono é quem criou o allocator.
//!
//! Os nós referenciam o texto original por slices (`[]const u8`), sem cópia.
//!
//! A semântica anota os nós com índices (`Expr.resolved`, `Stmt.decl_symbol`,
//! `Call.callee_fn`); a AST não armazena tipos — o resultado da análise vive em
//! `sema.Checked`, mantendo a AST independente de decisões semânticas.

const std = @import("std");
const Span = @import("../span.zig").Span;

/// Nome de tipo tal como escrito na fonte.
pub const TypeName = struct {
    name: []const u8,
    span: Span,
};

pub const Program = struct {
    /// Importações declaradas no arquivo, na ordem da fonte. O loader de
    /// módulos as resolve; o programa achatado entregue à semântica/backends
    /// tem `imports` vazio.
    imports: []Import = &.{},
    /// Declarações `struct` de todos os módulos, em pré-ordem.
    structs: []*StructDecl = &.{},
    functions: []*Function,
    span: Span,
};

/// `struct Nome { campo: tipo, ... }` — declaração no nível superior.
pub const StructDecl = struct {
    name: []const u8,
    name_span: Span,
    fields: []Field,
    /// Arquivo-fonte de origem, atribuído pelo loader de módulos.
    file_id: u32 = 0,
    span: Span,
};

pub const Field = struct {
    name: []const u8,
    name_span: Span,
    type_name: TypeName,
    span: Span,
};

/// `import "caminho";` — caminho relativo ao arquivo que importa.
pub const Import = struct {
    path: []const u8,
    path_span: Span,
    span: Span,
};

pub const Function = struct {
    name: []const u8,
    name_span: Span,
    /// Arquivo-fonte de origem (índice em `driver.SourceFile`), atribuído pelo
    /// loader de módulos; 0 em compilações de buffer único.
    file_id: u32 = 0,
    params: []Param,
    /// `null` quando não há anotação de retorno (`fn main() { ... }`).
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
    /// Índice do símbolo resolvido pela semântica (variáveis).
    resolved: ?u32 = null,

    pub const Kind = union(enum) {
        int_literal: IntLiteral,
        bool_literal: bool,
        identifier: []const u8,
        call: Call,
        binary: Binary,
        unary: Unary,
        /// `base.campo` — hoje só bases de tipo struct com campos escalares.
        field_access: FieldAccess,
        /// `Nome { campo: valor, ... }`
        struct_literal: StructLiteral,
    };

    pub const FieldAccess = struct {
        base: *Expr,
        name: []const u8,
        name_span: Span,
        /// Índice do campo na declaração do struct, preenchido pela semântica.
        field_index: ?u32 = null,
    };

    pub const StructLiteral = struct {
        type_name: TypeName,
        fields: []FieldInit,
        /// Índice do struct resolvido pela semântica.
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
            };
        }

        pub fn isArithmetic(self: BinaryOp) bool {
            return switch (self) {
                .add, .sub, .mul, .div, .mod => true,
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

        pub fn spelling(self: UnaryOp) []const u8 {
            return switch (self) {
                .neg => "-",
                .not => "!",
            };
        }
    };

    pub const Unary = struct {
        op: UnaryOp,
        operand: *Expr,
    };

    pub const Call = struct {
        callee: []const u8,
        callee_span: Span,
        args: []*Expr,
        /// Índice da função resolvida pela semântica.
        callee_fn: ?u32 = null,
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
    /// Índice do símbolo declarado (apenas `let_decl`), preenchido pela semântica.
    decl_symbol: ?u32 = null,

    pub const Kind = union(enum) {
        let_decl: VarDecl,
        assign: Assign,
        /// `base.campo = valor;` — atribuição a campo de struct.
        field_assign: FieldAssign,
        return_stmt: ?*Expr,
        expr_stmt: *Expr,
        if_stmt: IfStmt,
        while_stmt: WhileStmt,
        block: []*Stmt,
    };

    pub const VarDecl = struct {
        name: []const u8,
        name_span: Span,
        /// Anotação de tipo opcional (`let x: i32 = 1;`).
        type_name: ?TypeName,
        init: *Expr,
        mutable: bool,
    };

    pub const Assign = struct {
        name: []const u8,
        name_span: Span,
        value: *Expr,
        /// Índice do símbolo resolvido pela semântica.
        resolved: ?u32 = null,
    };

    pub const FieldAssign = struct {
        base: *Expr,
        name: []const u8,
        name_span: Span,
        value: *Expr,
        /// Índice do campo na declaração do struct, preenchido pela semântica.
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

/// Constrói um slice de AST em memória de arena a partir de uma lista.
pub fn toOwned(comptime T: type, arena: std.mem.Allocator, list: *std.ArrayList(T)) ![]T {
    return list.toOwnedSlice(arena);
}

test "ast: constrói nó de expressão em arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lit = try Expr.create(a, .{ .start = 0, .end = 2, .line = 1, .column = 1 }, .{
        .int_literal = .{ .value = 42, .text = "42" },
    });
    try std.testing.expectEqual(@as(i64, 42), lit.kind.int_literal.value);
    try std.testing.expect(lit.resolved == null);
}

test "ast: operadores reportam ortografia e categoria" {
    try std.testing.expectEqualStrings("+", Expr.BinaryOp.add.spelling());
    try std.testing.expect(Expr.BinaryOp.mul.isArithmetic());
    try std.testing.expect(!Expr.BinaryOp.mul.isComparison());
    try std.testing.expect(Expr.BinaryOp.ge.isComparison());
    try std.testing.expect(Expr.BinaryOp.or_op.isLogical());
    try std.testing.expectEqualStrings("!", Expr.UnaryOp.not.spelling());
}
