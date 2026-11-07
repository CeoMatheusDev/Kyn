//! Análise semântica do bootstrap.
//!
//! Responsabilidades:
//! - resolver nomes (variáveis, parâmetros e funções) e anotar a AST com
//!   índices de símbolo (`Expr.resolved`, `Stmt.decl_symbol`, `Call.callee_fn`);
//! - verificar tipos (`i32`, `bool`, `void`), mutabilidade e condições;
//! - atribuir um slot de pilha por variável de cada função, consumido pelos
//!   backends;
//! - validar o ponto de entrada `main`.
//!
//! A AST não é modificada estruturalmente: apenas recebe índices resolvidos.
//! Todos os símbolos e assinaturas são alocados na arena recebida.

const std = @import("std");
const ast = @import("../ast/ast.zig");
const diagnostics = @import("../diagnostics.zig");
const Span = @import("../span.zig").Span;

pub const Type = enum {
    i32,
    bool,
    void,
    /// Tipo desconhecido: evita cascata de diagnósticos após um erro.
    unknown,

    pub fn name(self: Type) []const u8 {
        return switch (self) {
            .i32 => "i32",
            .bool => "bool",
            .void => "void",
            .unknown => "desconhecido",
        };
    }

    pub fn fromName(text: []const u8) ?Type {
        if (std.mem.eql(u8, text, "i32")) return .i32;
        if (std.mem.eql(u8, text, "bool")) return .bool;
        if (std.mem.eql(u8, text, "void")) return .void;
        return null;
    }

    /// Tipos que podem existir como valor de expressão/variável.
    pub fn isValue(self: Type) bool {
        return self == .i32 or self == .bool;
    }
};

pub const SymbolKind = enum { param, local };

pub const Symbol = struct {
    name: []const u8,
    typ: Type,
    mutable: bool,
    /// Slot de pilha relativo à função (parâmetros primeiro).
    slot: u32,
    kind: SymbolKind,
    decl_span: Span,
};

pub const FunctionInfo = struct {
    decl: *const ast.Function,
    return_type: Type,
    params: []Type,
    /// Quantidade de slots de pilha usados pela função (parâmetros + locais).
    slot_count: u32,
    /// Intervalo de símbolos desta função em `Checked.symbols`
    /// (parâmetros primeiro, depois variáveis locais).
    symbol_start: u32 = 0,
    symbol_count: u32 = 0,
};

pub const Checked = struct {
    functions: []FunctionInfo,
    /// Tabela plana; `Expr.resolved` e `Stmt.decl_symbol` indexam este slice.
    symbols: []Symbol,

    pub fn findFunction(self: *const Checked, name: []const u8) ?u32 {
        for (self.functions, 0..) |f, i| {
            if (std.mem.eql(u8, f.decl.name, name)) return @intCast(i);
        }
        return null;
    }
};

/// Limite de parâmetros/argumentos por chamada no backend x86-64 (SysV).
pub const max_params: usize = 6;

pub const Options = struct {
    /// Exige que o programa defina `fn main() -> i32` ou `fn main() -> void`.
    require_main: bool = true,
    /// Caminho de cada arquivo, indexado por `ast.Function.file_id`. Usado nas
    /// mensagens para desambiguar declarações vindas de módulos importados.
    file_names: []const []const u8 = &.{},
};

pub const Checker = struct {
    arena: std.mem.Allocator,
    diags: *diagnostics.List,
    options: Options,

    symbols: std.ArrayList(Symbol) = .empty,
    functions: std.ArrayList(FunctionInfo) = .empty,
    /// Início (índice em `symbols`) do escopo atual.
    scopes: std.ArrayList(usize) = .empty,

    fn_index: u32 = 0,
    fn_symbol_start: usize = 0,
    next_slot: u32 = 0,
    current_return: Type = .void,

    pub fn init(arena: std.mem.Allocator, diags: *diagnostics.List, options: Options) Checker {
        return .{ .arena = arena, .diags = diags, .options = options };
    }

    pub fn checkProgram(self: *Checker, program: *const ast.Program) std.mem.Allocator.Error!Checked {
        // Passo 1: registrar assinaturas (permite chamadas antes da declaração
        // e recursão).
        for (program.functions) |func| {
            self.diags.current_file = func.file_id;
            try self.registerFunction(func);
        }

        if (self.options.require_main) {
            try self.checkMain(program);
        }

        // Passo 2: verificar corpos.
        for (program.functions, 0..) |func, i| {
            self.diags.current_file = func.file_id;
            try self.checkFunctionBody(func, @intCast(i));
        }
        self.diags.current_file = 0;

        return .{
            .functions = try self.functions.toOwnedSlice(self.arena),
            .symbols = try self.symbols.toOwnedSlice(self.arena),
        };
    }

    /// Caminho do arquivo de um símbolo, quando conhecido e diferente do
    /// arquivo atual (evita ruído em programas de um só arquivo).
    fn fileName(self: *const Checker, file_id: u32) ?[]const u8 {
        if (file_id == self.diags.current_file) return null;
        if (file_id >= self.options.file_names.len) return null;
        return self.options.file_names[file_id];
    }

    fn registerFunction(self: *Checker, func: *const ast.Function) std.mem.Allocator.Error!void {
        for (self.functions.items) |existing| {
            if (std.mem.eql(u8, existing.decl.name, func.name)) {
                if (self.fileName(existing.decl.file_id)) |path| {
                    try self.diags.add(
                        .duplicate_declaration,
                        func.name_span,
                        "função '{s}' já declarada em '{s}' (linha {d})",
                        .{ func.name, path, existing.decl.name_span.line },
                    );
                } else {
                    try self.diags.add(
                        .duplicate_declaration,
                        func.name_span,
                        "função '{s}' já declarada (primeira declaração na linha {d})",
                        .{ func.name, existing.decl.name_span.line },
                    );
                }
                break;
            }
        }

        if (func.params.len > max_params) {
            try self.diags.add(
                .unsupported,
                func.name_span,
                "função '{s}' declara {d} parâmetros; o backend atual suporta no máximo {d}",
                .{ func.name, func.params.len, max_params },
            );
        }

        const params = try self.arena.alloc(Type, func.params.len);
        // Índice provisório: as assinaturas são anexadas na ordem da fonte.
        for (func.params, 0..) |param, i| {
            params[i] = try self.resolveTypeName(param.type_name);
        }

        const return_type: Type = if (func.return_type) |tn|
            try self.resolveTypeName(tn)
        else
            .void;

        try self.functions.append(self.arena, .{
            .decl = func,
            .return_type = return_type,
            .params = params,
            .slot_count = 0,
        });
    }

    fn checkMain(self: *Checker, program: *const ast.Program) std.mem.Allocator.Error!void {
        var main_fn: ?*const ast.Function = null;
        for (program.functions) |func| {
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
                "programa não define 'fn main()'",
                .{},
            );
            return;
        };

        if (main.params.len != 0) {
            try self.diags.add(
                .invalid_main,
                main.name_span,
                "'main' não pode receber parâmetros neste estágio",
                .{},
            );
        }

        const ret = if (main.return_type) |tn| Type.fromName(tn.name) orelse .unknown else .void;
        if (ret != .i32 and ret != .void and ret != .unknown) {
            try self.diags.add(
                .invalid_main,
                main.return_type.?.span,
                "'main' deve retornar 'i32' ou 'void', encontrado '{s}'",
                .{main.return_type.?.name},
            );
        }
    }

    fn resolveTypeName(self: *Checker, tn: ast.TypeName) std.mem.Allocator.Error!Type {
        if (Type.fromName(tn.name)) |typ| return typ;
        try self.diags.add(
            .unknown_type,
            tn.span,
            "tipo '{s}' não suportado (disponíveis: i32, bool, void)",
            .{tn.name},
        );
        return .unknown;
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
            _ = try self.declare(param.name, param.span, typ, false, .param);
        }

        try self.checkStatements(func.body);

        if (info.return_type.isValue() and !alwaysReturns(func.body)) {
            try self.diags.add(
                .invalid_return,
                func.name_span,
                "função '{s}' pode terminar sem executar 'return' com valor '{s}'",
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
    ) !?u32 {
        if (self.scopes.items.len > 0) {
            const start = self.scopes.items[self.scopes.items.len - 1];
            for (self.symbols.items[start..]) |sym| {
                if (std.mem.eql(u8, sym.name, name)) {
                    try self.diags.add(
                        .duplicate_declaration,
                        span,
                        "'{s}' já foi declarado neste escopo (linha {d})",
                        .{ name, sym.decl_span.line },
                    );
                    return null;
                }
            }
        }

        const slot = self.next_slot;
        self.next_slot += 1;
        try self.symbols.append(self.arena, .{
            .name = name,
            .typ = typ,
            .mutable = mutable,
            .slot = slot,
            .kind = kind,
            .decl_span = span,
        });
        return @intCast(self.symbols.items.len - 1);
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
                if (decl.type_name) |tn| {
                    declared_type = try self.resolveTypeName(tn);
                    if (declared_type != .unknown and init_type != .unknown) {
                        if (declared_type != init_type) {
                            try self.diags.add(
                                .type_mismatch,
                                decl.init.span,
                                "inicializador de '{s}' tem tipo '{s}', mas a anotação é '{s}'",
                                .{ decl.name, init_type.name(), declared_type.name() },
                            );
                        }
                    }
                }

                if (init_type == .void and declared_type != .void) {
                    try self.diags.add(
                        .type_mismatch,
                        decl.init.span,
                        "'{s}' exige um valor, mas a expressão é do tipo 'void'",
                        .{decl.name},
                    );
                }

                stmt.decl_symbol = try self.declare(decl.name, decl.name_span, declared_type, decl.mutable, .local);
            },

            .assign => |*assign| {
                const value_type = try self.checkExpr(assign.value);
                const sym_index = self.lookup(assign.name) orelse {
                    try self.diags.add(
                        .undefined_variable,
                        assign.name_span,
                        "variável '{s}' não declarada",
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
                        "'{s}' é imutável; declare com 'var' para permitir atribuição",
                        .{assign.name},
                    );
                }
                if (sym.typ != .unknown and value_type != .unknown and sym.typ != value_type) {
                    try self.diags.add(
                        .type_mismatch,
                        assign.value.span,
                        "'{s}' é do tipo '{s}', mas o valor atribuído é '{s}'",
                        .{ assign.name, sym.typ.name(), value_type.name() },
                    );
                }
            },

            .return_stmt => |value| {
                const expected = self.current_return;
                if (value) |expr| {
                    const actual = try self.checkExpr(expr);
                    if (expected == .void) {
                        try self.diags.add(
                            .invalid_return,
                            expr.span,
                            "função atual não retorna valor ('void'), mas 'return' tem expressão",
                            .{},
                        );
                    } else if (expected != .unknown and actual != .unknown and expected != actual) {
                        try self.diags.add(
                            .invalid_return,
                            expr.span,
                            "tipo de retorno esperado '{s}', encontrado '{s}'",
                            .{ expected.name(), actual.name() },
                        );
                    }
                } else if (expected.isValue()) {
                    try self.diags.add(
                        .invalid_return,
                        stmt.span,
                        "função atual deve retornar '{s}'; 'return' sem valor não é permitido",
                        .{expected.name()},
                    );
                }
            },

            .expr_stmt => |expr| {
                _ = try self.checkExpr(expr);
            },

            .if_stmt => |*if_stmt| {
                const cond_type = try self.checkExpr(if_stmt.cond);
                if (cond_type != .bool and cond_type != .unknown) {
                    try self.diags.add(
                        .invalid_condition,
                        if_stmt.cond.span,
                        "condição de 'if' deve ser 'bool', encontrado '{s}'",
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
                if (cond_type != .bool and cond_type != .unknown) {
                    try self.diags.add(
                        .invalid_condition,
                        while_stmt.cond.span,
                        "condição de 'while' deve ser 'bool', encontrado '{s}'",
                        .{cond_type.name()},
                    );
                }
                try self.checkScopedBlock(while_stmt.body);
            },

            .block => |stmts| try self.checkScopedBlock(stmts),
        }
    }

    fn checkExpr(self: *Checker, expr: *ast.Expr) std.mem.Allocator.Error!Type {
        switch (expr.kind) {
            .int_literal => |lit| {
                if (lit.value > std.math.maxInt(i32) or lit.value < std.math.minInt(i32)) {
                    try self.diags.add(
                        .integer_overflow,
                        expr.span,
                        "literal {s} não cabe em 'i32'",
                        .{lit.text},
                    );
                }
                return .i32;
            },

            .bool_literal => return .bool,

            .identifier => |name| {
                const sym_index = self.lookup(name) orelse {
                    try self.diags.add(
                        .undefined_variable,
                        expr.span,
                        "variável '{s}' não declarada",
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
                if (operand == .unknown) return .unknown;
                switch (unary.op) {
                    .neg => {
                        if (operand != .i32) {
                            try self.diags.add(
                                .type_mismatch,
                                expr.span,
                                "operador '-' espera 'i32', encontrado '{s}'",
                                .{operand.name()},
                            );
                            return .unknown;
                        }
                        return .i32;
                    },
                    .not => {
                        if (operand != .bool) {
                            try self.diags.add(
                                .type_mismatch,
                                expr.span,
                                "operador '!' espera 'bool', encontrado '{s}'",
                                .{operand.name()},
                            );
                            return .unknown;
                        }
                        return .bool;
                    },
                }
            },

            .call => |*call| return self.checkCall(expr.span, call),
        }
    }

    fn checkBinary(
        self: *Checker,
        span: Span,
        op: ast.Expr.BinaryOp,
        lhs: Type,
        rhs: Type,
    ) !Type {
        if (lhs == .unknown or rhs == .unknown) return .unknown;

        const both_i32 = lhs == .i32 and rhs == .i32;
        const both_bool = lhs == .bool and rhs == .bool;

        if (op.isArithmetic()) {
            if (!both_i32) {
                try self.diags.add(
                    .type_mismatch,
                    span,
                    "operador '{s}' espera dois 'i32', encontrado '{s}' e '{s}'",
                    .{ op.spelling(), lhs.name(), rhs.name() },
                );
                return .unknown;
            }
            return .i32;
        }

        if (op.isComparison()) {
            if (!both_i32) {
                try self.diags.add(
                    .type_mismatch,
                    span,
                    "operador '{s}' espera dois 'i32', encontrado '{s}' e '{s}'",
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
                    "operador '{s}' espera dois 'bool', encontrado '{s}' e '{s}'",
                    .{ op.spelling(), lhs.name(), rhs.name() },
                );
                return .unknown;
            }
            return .bool;
        }

        // == e !=
        if (lhs != rhs or !lhs.isValue()) {
            try self.diags.add(
                .type_mismatch,
                span,
                "operador '{s}' exige operandos do mesmo tipo e não-void, encontrado '{s}' e '{s}'",
                .{ op.spelling(), lhs.name(), rhs.name() },
            );
            return .unknown;
        }
        return .bool;
    }

    fn checkCall(self: *Checker, span: Span, call: *ast.Expr.Call) std.mem.Allocator.Error!Type {
        var arg_types = std.ArrayList(Type).empty;
        defer arg_types.deinit(self.arena);

        for (call.args) |arg| {
            try arg_types.append(self.arena, try self.checkExpr(arg));
        }

        const fn_index = self.findFunctionIndex(call.callee);
        if (fn_index == null) {
            try self.diags.add(
                .invalid_call,
                call.callee_span,
                "função '{s}' não declarada",
                .{call.callee},
            );
            return .unknown;
        }

        const func = self.functions.items[fn_index.?];
        call.callee_fn = fn_index;

        if (call.args.len > max_params) {
            try self.diags.add(
                .unsupported,
                span,
                "chamada de '{s}' com {d} argumentos; o backend atual suporta no máximo {d}",
                .{ call.callee, call.args.len, max_params },
            );
        }

        if (arg_types.items.len != func.params.len) {
            try self.diags.add(
                .invalid_call,
                span,
                "'{s}' espera {d} argumento(s), recebeu {d}",
                .{ call.callee, func.params.len, arg_types.items.len },
            );
            return func.return_type;
        }

        for (arg_types.items, func.params, 0..) |actual, expected, i| {
            if (actual == .unknown or expected == .unknown) continue;
            if (actual != expected) {
                try self.diags.add(
                    .type_mismatch,
                    call.args[i].span,
                    "argumento {d} de '{s}' deve ser '{s}', encontrado '{s}'",
                    .{ i + 1, call.callee, expected.name(), actual.name() },
                );
            }
        }

        return func.return_type;
    }

    fn findFunctionIndex(self: *const Checker, name: []const u8) ?u32 {
        for (self.functions.items, 0..) |func, i| {
            if (std.mem.eql(u8, func.decl.name, name)) return @intCast(i);
        }
        return null;
    }
};

/// Verificação estrutural simples: o bloco sempre termina executando `return`?
/// Cobre `return` direto, blocos aninhados e `if` com ambos os ramos
/// terminantes. Laços não são considerados (não há como provar término).
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
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Testes
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

fn expectOnly(f: *const Fixture, kind: diagnostics.Kind) !void {
    try testing.expectEqual(@as(usize, 1), f.diags.count());
    try testing.expectEqual(kind, f.diags.items.items[0].kind);
}

test "sema: programa válido não gera diagnósticos" {
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

test "sema: variável não declarada" {
    var f = try Fixture.check("fn main() -> i32 { return z; }", .{});
    defer f.deinit();
    try expectOnly(&f, .undefined_variable);
}

test "sema: atribuição a variável imutável" {
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

test "sema: atribuição a var é permitida" {
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

test "sema: declaração duplicada no mesmo escopo" {
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

test "sema: shadowing em escopo interno é permitido" {
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

test "sema: anotação diverge do inicializador" {
    var f = try Fixture.check("fn main() -> i32 { let x: bool = 1; return 0; }", .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
}

test "sema: aritmética com bool é rejeitada" {
    var f = try Fixture.check("fn main() -> i32 { let x = true + 1; return 0; }", .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
}

test "sema: comparação de i32 produz bool" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let b: bool = 1 < 2;
        \\    if b { return 1; } else { return 0; }
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: condição de if deve ser bool" {
    var f = try Fixture.check("fn main() -> i32 { if 1 { return 1; } return 0; }", .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_condition);
}

test "sema: condição de while deve ser bool" {
    var f = try Fixture.check("fn main() -> i32 { while 0 { } return 0; }", .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_condition);
}

test "sema: return com tipo divergente" {
    var f = try Fixture.check("fn main() -> i32 { return true; }", .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_return);
}

test "sema: return com valor em função void" {
    var f = try Fixture.check("fn main() -> void { return 1; }", .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_return);
}

test "sema: função não-void pode terminar sem return" {
    var f = try Fixture.check("fn main() -> i32 { let x = 1; }", .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_return);
}

test "sema: caminho com if sem else não garante retorno" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    if 1 > 0 { return 1; }
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_return);
}

test "sema: if/else com ambos returns é aceito" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    if 1 > 0 { return 1; } else { return 2; }
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: chamada de função resolve assinatura" {
    var f = try Fixture.check(
        \\fn twice(x: i32) -> i32 { return x + x; }
        \\fn main() -> i32 { return twice(21); }
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: chamada com aridade errada" {
    var f = try Fixture.check(
        \\fn twice(x: i32) -> i32 { return x + x; }
        \\fn main() -> i32 { return twice(1, 2); }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_call);
}

test "sema: chamada de função inexistente" {
    var f = try Fixture.check("fn main() -> i32 { return nada(); }", .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_call);
}

test "sema: argumento com tipo errado" {
    var f = try Fixture.check(
        \\fn id(x: i32) -> i32 { return x; }
        \\fn main() -> i32 { return id(true); }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
}

test "sema: tipo desconhecido" {
    var f = try Fixture.check("fn main() -> i32 { let x: u8 = 1; return 0; }", .{});
    defer f.deinit();
    try expectOnly(&f, .unknown_type);
}

test "sema: literal não cabe em i32" {
    var f = try Fixture.check("fn main() -> i32 { let x = 2147483648; return 0; }", .{});
    defer f.deinit();
    try expectOnly(&f, .integer_overflow);
}

test "sema: main ausente" {
    var f = try Fixture.check("fn other() -> i32 { return 1; }", .{});
    defer f.deinit();
    try expectOnly(&f, .missing_main);
}

test "sema: main com parâmetros é inválido" {
    var f = try Fixture.check("fn main(argc: i32) -> i32 { return 0; }", .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_main);
}

test "sema: função duplicada" {
    var f = try Fixture.check(
        \\fn main() -> i32 { return 1; }
        \\fn main() -> i32 { return 2; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .duplicate_declaration);
}

test "sema: resolução é anotada na AST" {
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

test "sema: alwaysReturns reconhece if/else completo" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    if 1 > 0 { return 1; } else if 2 > 1 { return 2; } else { return 3; }
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
}

test "sema: limite de parâmetros do backend é diagnosticado" {
    var f = try Fixture.check(
        \\fn many(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32) -> i32 { return a; }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
}

test "sema: limite de argumentos do backend é diagnosticado" {
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
