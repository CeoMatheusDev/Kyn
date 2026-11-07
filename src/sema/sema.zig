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
    /// Valor de struct (identidade nominal em `Symbol.struct_id`). Não é
    /// escalar: não participa de operadores, condições nem chamadas por valor.
    aggregate,
    /// Fatia de string estática (ponteiro + tamanho), representada em dois
    /// slots. Não é escalar: só inicializa, é copiada e é argumento de `print`.
    str,
    /// Tipo desconhecido: evita cascata de diagnósticos após um erro.
    unknown,

    pub fn name(self: Type) []const u8 {
        return switch (self) {
            .i32 => "i32",
            .bool => "bool",
            .void => "void",
            .aggregate => "struct",
            .str => "str",
            .unknown => "desconhecido",
        };
    }

    pub fn fromName(text: []const u8) ?Type {
        if (std.mem.eql(u8, text, "i32")) return .i32;
        if (std.mem.eql(u8, text, "bool")) return .bool;
        if (std.mem.eql(u8, text, "void")) return .void;
        if (std.mem.eql(u8, text, "str")) return .str;
        return null;
    }

    /// Tipos que podem existir como valor de expressão/variável. `str` é
    /// fatia (dois slots), não escalar, mas tem valor: pode ser inicializar,
    /// copiar, retornar e ser argumento.
    pub fn isValue(self: Type) bool {
        return self == .i32 or self == .bool or self == .str;
    }

    /// Palavras de registrador consumidas pela convenção de chamada: `str`
    /// ocupa dois registradores consecutivos (ponteiro e tamanho).
    pub fn registerWords(self: Type) usize {
        return if (self == .str) 2 else 1;
    }
};

pub const SymbolKind = enum { param, local };

pub const Symbol = struct {
    name: []const u8,
    typ: Type,
    mutable: bool,
    /// Slot de pilha relativo à função (parâmetros primeiro). Em variáveis de
    /// struct, os campos ocupam `slot + 1 .. slot + 1 + n`.
    slot: u32,
    kind: SymbolKind,
    decl_span: Span,
    /// Índice em `Checked.structs` quando `typ == .aggregate`.
    struct_id: u32 = 0,
};

/// Campo de um struct já validado: tipo escalar e índice na declaração.
pub const FieldInfo = struct {
    name: []const u8,
    typ: Type,
    span: Span,
};

pub const StructInfo = struct {
    decl: *const ast.StructDecl,
    fields: []FieldInfo,
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
    /// Structs declarados, na ordem da fonte (achatados entre módulos).
    structs: []StructInfo,

    pub fn findStruct(self: *const Checked, name: []const u8) ?u32 {
        for (self.structs, 0..) |info, i| {
            if (std.mem.eql(u8, info.decl.name, name)) return @intCast(i);
        }
        return null;
    }

    pub fn findFunction(self: *const Checked, name: []const u8) ?u32 {
        for (self.functions, 0..) |f, i| {
            if (std.mem.eql(u8, f.decl.name, name)) return @intCast(i);
        }
        return null;
    }
};

/// Limite de **registradores** de argumento por chamada no backend x86-64
/// (SysV). Não é um limite de parâmetros: cada `str` consome dois
/// (`Type.registerWords`), então três `str` preenchem a tabela.
pub const max_arg_registers: usize = 6;

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
    structs: std.ArrayList(StructInfo) = .empty,
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
        // Passo 0: nomes de struct antes de qualquer tipo ser resolvido.
        for (program.structs) |decl| {
            self.diags.current_file = decl.file_id;
            try self.registerStructName(decl);
        }
        for (program.structs) |decl| {
            self.diags.current_file = decl.file_id;
            try self.registerStructFields(decl);
        }

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
            .structs = try self.structs.toOwnedSlice(self.arena),
        };
    }

    fn findStructIndex(self: *const Checker, name: []const u8) ?u32 {
        for (self.structs.items, 0..) |info, i| {
            if (std.mem.eql(u8, info.decl.name, name)) return @intCast(i);
        }
        return null;
    }

    /// Primeiro passo dos structs: garante nomes únicos para que qualquer
    /// declaração possa ser referenciada por tipos resolvidos depois.
    fn registerStructName(self: *Checker, decl: *const ast.StructDecl) std.mem.Allocator.Error!void {
        for (self.structs.items) |existing| {
            if (std.mem.eql(u8, existing.decl.name, decl.name)) {
                if (self.fileName(existing.decl.file_id)) |path| {
                    try self.diags.add(
                        .duplicate_declaration,
                        decl.name_span,
                        "struct '{s}' já declarado em '{s}' (linha {d})",
                        .{ decl.name, path, existing.decl.name_span.line },
                    );
                } else {
                    try self.diags.add(
                        .duplicate_declaration,
                        decl.name_span,
                        "struct '{s}' já declarado (primeira declaração na linha {d})",
                        .{ decl.name, existing.decl.name_span.line },
                    );
                }
                return;
            }
        }

        try self.structs.append(self.arena, .{ .decl = decl, .fields = &.{} });
    }

    /// Segundo passo: resolve os tipos dos campos (somente escalares nesta
    /// etapa) e valida duplicidade.
    fn registerStructFields(self: *Checker, decl: *const ast.StructDecl) std.mem.Allocator.Error!void {
        const index = self.findStructIndex(decl.name) orelse return;
        // Declaração duplicada (já diagnosticada) compartilha o nome com a
        // primeira; não sobrescreve os campos dela.
        if (self.structs.items[index].decl != decl) return;

        if (decl.fields.len == 0) {
            try self.diags.add(
                .unsupported,
                decl.name_span,
                "struct '{s}' sem campos não é suportado nesta etapa",
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
                        "campo '{s}' já declarado no struct '{s}' (linha {d})",
                        .{ field.name, decl.name, previous.name_span.line },
                    );
                    break;
                }
            }

            const typ = try self.resolveTypeName(field.type_name);
            if (typ == .aggregate) {
                try self.diags.add(
                    .unsupported,
                    field.type_name.span,
                    "campo '{s}' de '{s}': struct com campo struct ainda não é suportado",
                    .{ field.name, decl.name },
                );
            } else if (typ == .str) {
                try self.diags.add(
                    .unsupported,
                    field.type_name.span,
                    "campo '{s}' de '{s}' de tipo 'str' ainda não é suportado",
                    .{ field.name, decl.name },
                );
            } else if (typ == .void) {
                try self.diags.add(
                    .type_mismatch,
                    field.type_name.span,
                    "campo '{s}' de '{s}' não pode ser 'void'",
                    .{ field.name, decl.name },
                );
            }

            fields[i] = .{ .name = field.name, .typ = typ, .span = field.span };
        }

        self.structs.items[index].fields = fields;
    }

    /// Caminho do arquivo de um símbolo, quando conhecido e diferente do
    /// arquivo atual (evita ruído em programas de um só arquivo).
    fn fileName(self: *const Checker, file_id: u32) ?[]const u8 {
        if (file_id == self.diags.current_file) return null;
        if (file_id >= self.options.file_names.len) return null;
        return self.options.file_names[file_id];
    }

    fn registerFunction(self: *Checker, func: *const ast.Function) std.mem.Allocator.Error!void {
        // Nomes de funções embutidas são reservados: declarar outra com o
        // mesmo nome criaria duas regras de resolução para a mesma chamada.
        if (builtinByName(func.name) != null) {
            try self.diags.add(
                .unsupported,
                func.name_span,
                "nome '{s}' é reservado para a função embutida",
                .{func.name},
            );
        }

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

        const params = try self.arena.alloc(Type, func.params.len);
        // Índice provisório: as assinaturas são anexadas na ordem da fonte.
        var register_words: usize = 0;
        for (func.params, 0..) |param, i| {
            params[i] = try self.resolveTypeName(param.type_name);
            register_words += params[i].registerWords();
            if (params[i] == .aggregate) {
                try self.diags.add(
                    .unsupported,
                    param.type_name.span,
                    "parâmetro '{s}' de '{s}': passagem de struct por valor ainda não é suportada",
                    .{ param.name, func.name },
                );
            }
        }

        // O limite do backend nativo é em registradores, não em parâmetros:
        // cada `str` consome dois.
        if (register_words > max_arg_registers) {
            try self.diags.add(
                .unsupported,
                func.name_span,
                "função '{s}' ocupa {d} registradores em parâmetros; o backend atual suporta no máximo {d} ('str' ocupa dois)",
                .{ func.name, register_words, max_arg_registers },
            );
        }

        const return_type: Type = if (func.return_type) |tn|
            try self.resolveTypeName(tn)
        else
            .void;
        if (return_type == .aggregate) {
            try self.diags.add(
                .unsupported,
                func.return_type.?.span,
                "função '{s}': retorno de struct por valor ainda não é suportado",
                .{func.name},
            );
        }

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
        if (self.findStructIndex(tn.name) != null) return .aggregate;
        try self.diags.add(
            .unknown_type,
            tn.span,
            "tipo '{s}' não suportado (disponíveis: i32, bool, str, void e structs declarados)",
            .{tn.name},
        );
        return .unknown;
    }

    /// Struct associado ao tipo anotado, quando houver.
    fn structIdOfTypeName(self: *const Checker, tn: ast.TypeName) ?u32 {
        return self.findStructIndex(tn.name);
    }

    /// Struct associado a uma expressão que produz valor de struct.
    fn structIdOfExpr(self: *const Checker, expr: *const ast.Expr) ?u32 {
        return switch (expr.kind) {
            .struct_literal => |lit| lit.resolved_struct,
            .identifier => if (expr.resolved) |idx| blk: {
                const sym = self.symbols.items[idx];
                break :blk if (sym.typ == .aggregate) sym.struct_id else null;
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
            _ = try self.declare(param.name, param.span, typ, false, .param, struct_id);
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
        struct_id: u32,
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

        // Valor de struct ocupa um slot de base (não usado) e um slot por
        // campo, na ordem da declaração — o mesmo mapeamento nos dois backends.
        // `str` ocupa dois slots consecutivos: ponteiro e tamanho.
        const extra_slots: u32 = if (typ == .aggregate and struct_id < self.structs.items.len)
            @intCast(self.structs.items[struct_id].fields.len)
        else if (typ == .str)
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
        });
        return @intCast(self.symbols.items.len - 1);
    }

    /// Resolve a base de um acesso a campo (hoje só um identificador simples).
    fn resolveFieldBase(self: *Checker, base: *ast.Expr) std.mem.Allocator.Error!?u32 {
        switch (base.kind) {
            .identifier => |name| {
                const index = self.lookup(name) orelse {
                    try self.diags.add(
                        .undefined_variable,
                        base.span,
                        "variável '{s}' não declarada",
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
                    "acesso a campo encadeado (struct com campo struct) ainda não é suportado",
                    .{},
                );
                return null;
            },
        }
    }

    /// Rótulo de tipo para mensagens: nome do struct quando aplicável.
    fn typeLabel(self: *const Checker, typ: Type, struct_id: u32) []const u8 {
        if (typ == .aggregate and struct_id < self.structs.items.len) {
            return self.structs.items[struct_id].decl.name;
        }
        return typ.name();
    }

    /// Texto curto da expressão usado em mensagens (bases de campo são nomes).
    fn exprText(self: *const Checker, expr: *const ast.Expr) []const u8 {
        _ = self;
        return switch (expr.kind) {
            .identifier => |name| name,
            else => "<expressão>",
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
                }
                const init_struct = self.structIdOfExpr(decl.init) orelse 0;

                // `void` não é armazenável — nem anotado (`let x: void = ...`)
                // nem inferido de uma chamada sem retorno (`let x = f();`).
                // Uma única mensagem cobre os dois casos; a variável não chega
                // aos backends com um tipo sem representação.
                if (declared_type == .void or init_type == .void) {
                    try self.diags.add(
                        .type_mismatch,
                        decl.name_span,
                        "variável '{s}' precisa de um valor: 'void' não pode ser armazenado",
                        .{decl.name},
                    );
                } else if (declared_type != .unknown and init_type != .unknown and declared_type != init_type) {
                    try self.diags.add(
                        .type_mismatch,
                        decl.init.span,
                        "inicializador de '{s}' tem tipo '{s}', mas a anotação é '{s}'",
                        .{ decl.name, self.typeLabel(init_type, init_struct), self.typeLabel(declared_type, declared_struct) },
                    );
                }

                // Mesmo tipo `struct`, structs diferentes.
                if (decl.type_name != null and declared_type == .aggregate and init_type == .aggregate) {
                    if (init_struct != declared_struct) {
                        try self.diags.add(
                            .type_mismatch,
                            decl.init.span,
                            "inicializador de '{s}' é do struct '{s}', mas a anotação é '{s}'",
                            .{
                                decl.name,
                                self.structs.items[init_struct].decl.name,
                                self.structs.items[declared_struct].decl.name,
                            },
                        );
                    }
                }

                // Variável de struct sem anotação: o struct vem do inicializador.
                const struct_id: u32 = if (declared_type == .aggregate) declared_struct else 0;

                stmt.decl_symbol = try self.declare(
                    decl.name,
                    decl.name_span,
                    declared_type,
                    decl.mutable,
                    .local,
                    struct_id,
                );
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
                        .{
                            assign.name,
                            self.typeLabel(sym.typ, sym.struct_id),
                            self.typeLabel(value_type, self.structIdOfExpr(assign.value) orelse 0),
                        },
                    );
                }
                if (sym.typ == .aggregate and value_type == .aggregate) {
                    const got = self.structIdOfExpr(assign.value);
                    if (got != null and got.? != sym.struct_id) {
                        try self.diags.add(
                            .type_mismatch,
                            assign.value.span,
                            "'{s}' é do struct '{s}', mas o valor atribuído é do struct '{s}'",
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
                if (sym.typ != .aggregate) {
                    try self.diags.add(
                        .type_mismatch,
                        fa.name_span,
                        "acesso a campo '{s}' exige um struct, mas '{s}' é do tipo '{s}'",
                        .{ fa.name, self.exprText(fa.base), self.typeLabel(sym.typ, sym.struct_id) },
                    );
                    return;
                }

                const info = &self.structs.items[sym.struct_id];
                const field_index = findField(info, fa.name) orelse {
                    try self.diags.add(
                        .undefined_field,
                        fa.name_span,
                        "struct '{s}' não tem o campo '{s}'",
                        .{ info.decl.name, fa.name },
                    );
                    return;
                };
                fa.field_index = field_index;

                if (!sym.mutable) {
                    try self.diags.add(
                        .immutable_assignment,
                        fa.name_span,
                        "'{s}.{s}' não pode ser atribuído: '{s}' foi declarado com 'let'",
                        .{ self.exprText(fa.base), fa.name, self.exprText(fa.base) },
                    );
                    return;
                }

                const field_type = info.fields[field_index].typ;
                if (field_type != .unknown and value_type != .unknown and field_type != value_type) {
                    try self.diags.add(
                        .type_mismatch,
                        fa.value.span,
                        "campo '{s}.{s}' é do tipo '{s}', mas o valor atribuído é '{s}'",
                        .{ self.exprText(fa.base), fa.name, field_type.name(), value_type.name() },
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
                const typ = try self.checkExpr(expr);
                if (typ == .str) {
                    try self.diags.add(
                        .unsupported,
                        expr.span,
                        "expressão do tipo 'str' sem uso; use 'print(...)' ou atribua a uma variável",
                        .{},
                    );
                } else if (typ == .aggregate) {
                    try self.diags.add(
                        .unsupported,
                        expr.span,
                        "valor de struct só pode inicializar ou ser atribuído a uma variável",
                        .{},
                    );
                }
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

            .str_literal => return .str,

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

            .field_access => |*access| {
                const base_index = try self.resolveFieldBase(access.base);
                if (base_index == null) return .unknown;

                const sym = self.symbols.items[base_index.?];
                if (sym.typ != .aggregate) {
                    try self.diags.add(
                        .type_mismatch,
                        access.name_span,
                        "acesso a campo '{s}' exige um struct, mas '{s}' é do tipo '{s}'",
                        .{ access.name, self.exprText(access.base), self.typeLabel(sym.typ, sym.struct_id) },
                    );
                    return .unknown;
                }

                const info = &self.structs.items[sym.struct_id];
                const field_index = findField(info, access.name) orelse {
                    try self.diags.add(
                        .undefined_field,
                        access.name_span,
                        "struct '{s}' não tem o campo '{s}'",
                        .{ info.decl.name, access.name },
                    );
                    return .unknown;
                };
                access.field_index = field_index;
                return info.fields[field_index].typ;
            },

            .struct_literal => |*lit| {
                const struct_id = self.findStructIndex(lit.type_name.name) orelse {
                    try self.diags.add(
                        .unknown_type,
                        lit.type_name.span,
                        "struct '{s}' não declarado",
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
                            "struct '{s}' não tem o campo '{s}'",
                            .{ info.decl.name, field_init.name },
                        );
                        _ = try self.checkExpr(field_init.value);
                        continue;
                    };
                    if (seen[field_index]) {
                        try self.diags.add(
                            .invalid_struct_literal,
                            field_init.name_span,
                            "campo '{s}' repetido no literal de '{s}'",
                            .{ field_init.name, info.decl.name },
                        );
                        _ = try self.checkExpr(field_init.value);
                        continue;
                    }
                    seen[field_index] = true;

                    const value_type = try self.checkExpr(field_init.value);
                    const field_type = info.fields[field_index].typ;
                    if (value_type != .unknown and field_type != .unknown and value_type != field_type) {
                        try self.diags.add(
                            .type_mismatch,
                            field_init.value.span,
                            "campo '{s}.{s}' é do tipo '{s}', mas o valor é '{s}'",
                            .{ info.decl.name, field_init.name, field_type.name(), value_type.name() },
                        );
                    }
                }

                for (info.fields, 0..) |field, i| {
                    if (!seen[i]) {
                        try self.diags.add(
                            .invalid_struct_literal,
                            lit.type_name.span,
                            "literal de '{s}' não inicializa o campo '{s}'",
                            .{ info.decl.name, field.name },
                        );
                    }
                }

                return .aggregate;
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
        if (lhs == .unknown or rhs == .unknown) return .unknown;

        // `str` é fatia (ponteiro + tamanho): comparar exigiria comparar
        // bytes, o que ainda não existe; diagnosticar em vez de comparar
        // ponteiros silenciosamente.
        if (lhs == .str or rhs == .str) {
            if (op == .eq or op == .ne) {
                try self.diags.add(
                    .unsupported,
                    span,
                    "comparação de 'str' com '{s}' ainda não é suportada",
                    .{op.spelling()},
                );
            } else {
                try self.diags.add(
                    .type_mismatch,
                    span,
                    "operador '{s}' espera dois 'i32', encontrado '{s}' e '{s}'",
                    .{ op.spelling(), lhs.name(), rhs.name() },
                );
            }
            return .unknown;
        }

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

        if (builtinByName(call.callee)) |builtin| {
            call.builtin = builtin;
            const expected = builtinParamType(builtin);
            if (arg_types.items.len != 1) {
                try self.diags.add(
                    .invalid_call,
                    span,
                    "'{s}' espera 1 argumento do tipo '{s}', recebeu {d}",
                    .{ @tagName(builtin), expected.name(), arg_types.items.len },
                );
                return .void;
            }
            const arg_type = arg_types.items[0];
            if (arg_type != .unknown and arg_type != expected) {
                try self.diags.add(
                    .type_mismatch,
                    call.args[0].span,
                    "'{s}' espera '{s}', encontrado '{s}'",
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
                "função '{s}' não declarada",
                .{call.callee},
            );
            return .unknown;
        }

        const func = self.functions.items[fn_index.?];
        call.callee_fn = fn_index;

        var arg_words: usize = 0;
        for (arg_types.items) |typ| arg_words += typ.registerWords();
        if (arg_words > max_arg_registers) {
            try self.diags.add(
                .unsupported,
                span,
                "chamada de '{s}' ocupa {d} registradores; o backend atual suporta no máximo {d} ('str' ocupa dois)",
                .{ call.callee, arg_words, max_arg_registers },
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
            if (actual == .aggregate) {
                try self.diags.add(
                    .unsupported,
                    call.args[i].span,
                    "argumento {d} de '{s}': passagem de struct por valor ainda não é suportada",
                    .{ i + 1, call.callee },
                );
                continue;
            }
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

/// Função embutida com esse identificador, quando houver. O nome do campo do
/// enum é o próprio identificador aceito na fonte.
fn builtinByName(name: []const u8) ?ast.Expr.Builtin {
    if (std.mem.eql(u8, name, "print")) return .print;
    if (std.mem.eql(u8, name, "print_i32")) return .print_i32;
    return null;
}

/// Tipo do único parâmetro exigido por cada função embutida.
fn builtinParamType(builtin: ast.Expr.Builtin) Type {
    return switch (builtin) {
        .print => .str,
        .print_i32 => .i32,
    };
}

/// Índice do campo `name` na declaração do struct.
fn findField(info: *const StructInfo, name: []const u8) ?u32 {
    for (info.fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    }
    return null;
}

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

test "sema: struct com literal, acesso e layout de slots" {
    var f = try Fixture.check(
        \\struct Ponto { x: i32, y: bool }
        \\fn main() -> i32 {
        \\    var p: Ponto = Ponto { x: 1, y: true };
        \\    p.x = p.x + 2;
        \\    let q: Ponto = p;
        \\    if q.y { return q.x; }
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.diags.count());
    const checked = f.checked.?;

    try testing.expectEqual(@as(usize, 1), checked.structs.len);
    try testing.expectEqualStrings("Ponto", checked.structs[0].decl.name);
    try testing.expectEqual(@as(usize, 2), checked.structs[0].fields.len);
    try testing.expectEqual(Type.i32, checked.structs[0].fields[0].typ);
    try testing.expectEqual(Type.bool, checked.structs[0].fields[1].typ);

    // Struct ocupa um slot de base + um slot por campo: p, q = 2 * 3 slots.
    try testing.expectEqual(@as(u32, 6), checked.functions[0].slot_count);
    try testing.expectEqual(Type.aggregate, checked.symbols[0].typ);
    try testing.expectEqual(@as(u32, 0), checked.symbols[0].struct_id);
    try testing.expectEqual(@as(u32, 0), checked.symbols[0].slot);
    try testing.expectEqual(@as(u32, 3), checked.symbols[1].slot);
}

test "sema: campo inexistente na leitura e na escrita" {
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

test "sema: literal de struct incompleto e com campo repetido" {
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
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "não inicializa o campo 'y'") != null);
    try testing.expectEqual(diagnostics.Kind.invalid_struct_literal, f.diags.items.items[1].kind);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[1].message, "repetido") != null);
}

test "sema: atribuição a campo de variável imutável" {
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
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "declarado com 'let'") != null);
}

test "sema: struct por valor em parâmetro, retorno e argumento é rejeitado" {
    var f = try Fixture.check(
        \\struct P { x: i32 }
        \\fn id(p: P) -> P { return p; }
        \\fn main() -> i32 {
        \\    let a: P = P { x: 1 };
        \\    let b: P = id(a);
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 3), f.diags.count());
    try testing.expectEqual(diagnostics.Kind.unsupported, f.diags.items.items[0].kind); // parâmetro
    try testing.expectEqual(diagnostics.Kind.unsupported, f.diags.items.items[1].kind); // retorno
    try testing.expectEqual(diagnostics.Kind.unsupported, f.diags.items.items[2].kind); // argumento
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "parâmetro 'p'") != null);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[2].message, "argumento 1") != null);
}

test "sema: struct aninhado, vazio e duplicado são diagnosticados" {
    var f = try Fixture.check(
        \\struct Vazio {}
        \\struct Interno { v: i32 }
        \\struct Externo { i: Interno }
        \\struct Interno { v: i32 }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try testing.expect(f.diags.count() >= 3);
    var saw_empty = false;
    var saw_nested = false;
    var saw_dup = false;
    for (f.diags.items.items) |d| {
        switch (d.kind) {
            .unsupported => if (std.mem.indexOf(u8, d.message, "sem campos") != null) {
                saw_empty = true;
            } else if (std.mem.indexOf(u8, d.message, "campo struct") != null) {
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

test "sema: struct desconhecido e campo com tipo errado" {
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
    try testing.expectEqual(diagnostics.Kind.unknown_type, f.diags.items.items[0].kind); // anotação 'Q'
    var saw_unknown_struct = false;
    var saw_mismatch = false;
    for (f.diags.items.items) |d| {
        switch (d.kind) {
            .unknown_type => if (std.mem.indexOf(u8, d.message, "struct 'Q' não declarado") != null) {
                saw_unknown_struct = true;
            },
            .type_mismatch => saw_mismatch = true,
            else => {},
        }
    }
    try testing.expect(saw_unknown_struct);
    try testing.expect(saw_mismatch);
}

test "sema: struct usado como condição ou em comparação" {
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

test "sema: literal de struct como expressão solta é rejeitado" {
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

test "sema: struct diferente na anotação e no inicializador" {
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

test "sema: literal de string infere 'str' e ocupa dois slots" {
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

test "sema: 'print' aceita variável str e é void" {
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

test "sema: 'print' com tipo errado é diagnosticado" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    print(1);
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "'print' espera 'str'") != null);
}

test "sema: 'print' exige exatamente um argumento" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    print("a", "b");
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_call);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "recebeu 2") != null);
}

test "sema: 'print' sem argumento é diagnosticado" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    print();
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_call);
}

test "sema: 'str' não participa de aritmética" {
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

test "sema: comparação de 'str' é diagnosticada (sem comparar ponteiros)" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let s = "a";
        \\    if s == "a" { return 1; }
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "comparação de 'str'") != null);
}

test "sema: 'str' como condição é rejeitado" {
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

test "sema: 'str' é aceito como parâmetro e como retorno" {
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
    // Parâmetro `str` ocupa dois slots (ponteiro e tamanho).
    try testing.expectEqual(Type.str, checked.functions[0].params[0]);
    try testing.expectEqual(Type.str, checked.functions[0].return_type);
    try testing.expectEqual(@as(u32, 2), checked.functions[1].slot_count);
}

test "sema: limite de registradores conta 'str' como dois" {
    var f = try Fixture.check(
        \\fn quatro(a: str, b: str, c: str, d: str) -> i32 { return 0; }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "8 registradores") != null);
}

test "sema: três parâmetros 'str' cabem nos seis registradores" {
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

test "sema: 'main' não pode retornar 'str'" {
    var f = try Fixture.check(
        \\fn main() -> str { return "a"; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_main);
}

test "sema: argumento 'str' onde se espera 'i32' é diagnosticado" {
    var f = try Fixture.check(
        \\fn dobro(n: i32) -> i32 { return n + n; }
        \\fn main() -> i32 { return dobro("a"); }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "deve ser 'i32', encontrado 'str'") != null);
}

test "sema: retorno 'str' sem valor é diagnosticado" {
    var f = try Fixture.check(
        \\fn nome() -> str { return; }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_return);
}

test "sema: função que retorna 'str' precisa terminar com return" {
    var f = try Fixture.check(
        \\fn nome(b: bool) -> str {
        \\    if b { return "a"; }
        \\}
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_return);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "com valor 'str'") != null);
}

test "sema: campo de tipo 'str' é diagnosticado" {
    var f = try Fixture.check(
        \\struct P { nome: str }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "tipo 'str'") != null);
}

test "sema: nome 'print' é reservado" {
    var f = try Fixture.check(
        \\fn print(v: i32) -> void {}
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "reservado") != null);
}

test "sema: literal de string solto é rejeitado" {
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

test "sema: atribuir a 'str' imutável é diagnosticado" {
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

test "sema: variável não pode receber valor 'void' inferido de chamada" {
    var f = try Fixture.check(
        \\fn nada() { }
        \\fn main() -> i32 {
        \\    let x = nada();
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "'void' não pode ser armazenado") != null);
}

test "sema: anotação de valor com inicializador 'void' gera um único diagnóstico" {
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

test "sema: anotação 'void' explícita em variável é rejeitada" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let x: void = 1;
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
}

test "sema: 'print' não produz valor para inicializar variável" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let x = print("a");
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
}

test "sema: 'print_i32' aceita expressão i32" {
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

test "sema: 'print_i32' com tipo errado é diagnosticado" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    print_i32("texto");
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "'print_i32' espera 'i32'") != null);
}

test "sema: 'print_i32' exige exatamente um argumento" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    print_i32();
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_call);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "recebeu 0") != null);
}

test "sema: 'print_i32' com dois argumentos é diagnosticado" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    print_i32(1, 2);
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .invalid_call);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "recebeu 2") != null);
}

test "sema: nome 'print_i32' também é reservado" {
    var f = try Fixture.check(
        \\fn print_i32(n: i32) -> void { }
        \\fn main() -> i32 { return 0; }
    , .{});
    defer f.deinit();
    try expectOnly(&f, .unsupported);
    try testing.expect(std.mem.indexOf(u8, f.diags.items.items[0].message, "reservado") != null);
}

test "sema: 'print_i32' não produz valor para inicializar variável" {
    var f = try Fixture.check(
        \\fn main() -> i32 {
        \\    let x = print_i32(1);
        \\    return 0;
        \\}
    , .{});
    defer f.deinit();
    try expectOnly(&f, .type_mismatch);
}
