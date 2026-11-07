//! Backend LLVM IR (texto).
//!
//! Emite IR textual para o subconjunto atual: funções `i32`/`void`, variáveis
//! (`i32`/`bool`), aritmética, comparações, `&&`/`||` com curto-circuito,
//! `if`/`else`, `while` e chamadas diretas de função.
//!
//! Structs: como valores de struct só existem em variáveis locais (sem
//! parâmetros, retorno, ponteiros ou campos de struct), cada campo ganha seu
//! próprio `alloca` — substituição escalar de um struct que nunca escapa. Isso
//! dispensa tipos agregados e `getelementptr` sem mudar a semântica observável.
//!
//! Este emissor não é validado por um montador LLVM no ambiente de
//! desenvolvimento (não há `llc`/`clang` disponíveis); os testes verificam a
//! estrutura do texto emitido. Para validação executável de ponta a ponta, veja
//! o backend `x86_64_asm`, que é montado e ligado com `as`/`ld`.

const std = @import("std");
const ast = @import("../ast/ast.zig");
const sema = @import("../sema/sema.zig");
const codegen = @import("codegen.zig");

pub const Error = codegen.Error;

pub fn emit(
    arena: std.mem.Allocator,
    program: *const ast.Program,
    checked: *const sema.Checked,
) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var state = codegen.ProgramState{ .strs = codegen.StrPool.init(arena) };
    try out.print(arena, "; LLVM IR gerado pelo kync (bootstrap)\n", .{});
    try out.print(arena, "target triple = \"x86_64-unknown-linux-gnu\"\n\n", .{});

    for (program.functions, 0..) |func, i| {
        var emitter = FnEmitter.init(arena, func, checked, checked.functions[i], &state);
        try emitter.emitFunction();
        try emitter.serialize(&out);
        try out.append(arena, '\n');
    }

    // `print` usa `write` da libc: o IR declara o símbolo e cada string vira
    // uma constante privada em lista de bytes (sem escapes de aspas).
    if (state.strs.texts.items.len > 0 or state.used_print) {
        try out.print(arena, "declare i64 @write(i32, ptr, i64)\n\n", .{});
        for (state.strs.texts.items, 0..) |text, index| {
            if (text.len == 0) {
                try out.print(arena, "@.str{d} = private unnamed_addr constant [0 x i8] zeroinitializer, align 1\n", .{index});
                continue;
            }
            try out.print(arena, "@.str{d} = private unnamed_addr constant [{d} x i8] [", .{ index, text.len });
            for (text, 0..) |byte, byte_index| {
                if (byte_index != 0) try out.print(arena, ", ", .{});
                try out.print(arena, "i8 {d}", .{byte});
            }
            try out.print(arena, "], align 1\n", .{});
        }
        if (state.used_print) {
            try out.print(arena, "@.nl = private unnamed_addr constant [1 x i8] [i8 10], align 1\n", .{});
        }
    }

    return out.toOwnedSlice(arena);
}

fn llvmType(typ: sema.Type) codegen.Error![]const u8 {
    return switch (typ) {
        .i32 => "i32",
        .bool => "i1",
        .void => "void",
        // Struct em LLVM é representado campo a campo (substituição escalar).
        .aggregate => error.UnsupportedType,
        // `str` é ponteiro + tamanho: representado por dois slots.
        .str => error.UnsupportedType,
        .unknown => error.UnsupportedType,
    };
}

fn typeAlign(typ: sema.Type) codegen.Error!u32 {
    return switch (typ) {
        .i32 => 4,
        .bool => 1,
        .void => error.UnsupportedType,
        .aggregate => error.UnsupportedType,
        .str => error.UnsupportedType,
        .unknown => error.UnsupportedType,
    };
}

const Operand = struct {
    text: []const u8,
    typ: sema.Type,
};

const Block = struct {
    label: []const u8,
    body: std.ArrayList(u8) = .empty,
    terminated: bool = false,
};

const FnEmitter = struct {
    arena: std.mem.Allocator,
    func: *const ast.Function,
    checked: *const sema.Checked,
    info: sema.FunctionInfo,
    /// Estado compartilhado do programa (pool de strings e uso de `print`).
    state: *codegen.ProgramState,

    blocks: std.ArrayList(Block) = .empty,
    current: usize = 0,
    tmp_count: u32 = 0,
    label_count: u32 = 0,

    fn init(
        arena: std.mem.Allocator,
        func: *const ast.Function,
        checked: *const sema.Checked,
        info: sema.FunctionInfo,
        state: *codegen.ProgramState,
    ) FnEmitter {
        return .{ .arena = arena, .func = func, .checked = checked, .info = info, .state = state };
    }

    fn block(self: *FnEmitter) *Block {
        return &self.blocks.items[self.current];
    }

    fn startBlock(self: *FnEmitter, label: []const u8) !void {
        try self.blocks.append(self.arena, .{ .label = label });
        self.current = self.blocks.items.len - 1;
    }

    fn emit(self: *FnEmitter, comptime fmt: []const u8, args: anytype) !void {
        const b = self.block();
        if (b.terminated) return;
        try b.body.print(self.arena, fmt, args);
    }

    fn br(self: *FnEmitter, label: []const u8) !void {
        if (self.block().terminated) return;
        try self.emit("  br label %{s}\n", .{label});
        self.block().terminated = true;
    }

    fn condBr(self: *FnEmitter, cond: []const u8, then_label: []const u8, else_label: []const u8) !void {
        if (self.block().terminated) return;
        try self.emit("  br i1 {s}, label %{s}, label %{s}\n", .{ cond, then_label, else_label });
        self.block().terminated = true;
    }

    fn retVoid(self: *FnEmitter) !void {
        if (self.block().terminated) return;
        try self.emit("  ret void\n", .{});
        self.block().terminated = true;
    }

    fn newTemp(self: *FnEmitter) ![]const u8 {
        const name = try std.fmt.allocPrint(self.arena, "%t{d}", .{self.tmp_count});
        self.tmp_count += 1;
        return name;
    }

    fn newLabel(self: *FnEmitter, prefix: []const u8) ![]const u8 {
        const name = try std.fmt.allocPrint(self.arena, "{s}{d}", .{ prefix, self.label_count });
        self.label_count += 1;
        return name;
    }

    fn varName(self: *FnEmitter, slot: u32) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "%v{d}", .{slot});
    }

    fn symbolAt(self: *FnEmitter, index: u32) *const sema.Symbol {
        return &self.checked.symbols[index];
    }

    fn emitFunction(self: *FnEmitter) !void {
        try self.startBlock("entry");

        // Alocação de todos os slots de uma vez, no bloco de entrada.
        const sym_start: usize = self.info.symbol_start;
        const sym_end: usize = sym_start + self.info.symbol_count;
        for (self.checked.symbols[sym_start..sym_end]) |sym| {
            if (sym.typ == .str) {
                // Ponteiro no slot base e tamanho no slot seguinte.
                try self.emit("  {s} = alloca ptr, align 8\n", .{try self.varName(sym.slot)});
                try self.emit("  {s} = alloca i64, align 8\n", .{try self.varName(sym.slot + 1)});
                continue;
            }
            if (sym.typ == .aggregate) {
                if (sym.struct_id >= self.checked.structs.len) return error.MiscompiledAst;
                for (self.checked.structs[sym.struct_id].fields, 0..) |field, i| {
                    const ty = try llvmType(field.typ);
                    const align_value = try typeAlign(field.typ);
                    const name = try self.varName(sym.slot + 1 + @as(u32, @intCast(i)));
                    try self.emit("  {s} = alloca {s}, align {d}\n", .{ name, ty, align_value });
                }
                continue;
            }
            const ty = try llvmType(sym.typ);
            const align_value = try typeAlign(sym.typ);
            const name = try self.varName(sym.slot);
            try self.emit("  {s} = alloca {s}, align {d}\n", .{ name, ty, align_value });
        }

        // Parâmetros são copiados para os seus slots.
        for (self.func.params, 0..) |_, i| {
            const sym = &self.checked.symbols[sym_start + i];
            const ty = try llvmType(sym.typ);
            const align_value = try typeAlign(sym.typ);
            const name = try self.varName(sym.slot);
            try self.emit("  store {s} %arg{d}, ptr {s}, align {d}\n", .{ ty, i, name, align_value });
        }

        try self.emitStatements(self.func.body);

        if (!self.block().terminated) {
            if (self.info.return_type == .void) {
                try self.retVoid();
            } else {
                // A semântica garante `return` em todos os caminhos; este
                // terminador é apenas uma salvaguarda estrutural do IR.
                try self.emit("  unreachable\n", .{});
                self.block().terminated = true;
            }
        }

        // Todo bloco básico precisa terminar com `ret`, `br` ou `unreachable`.
        // Blocos que só são alcançados por desvios condicionais (por exemplo o
        // `if_end` quando ambos os ramos retornam) são fechados aqui.
        for (self.blocks.items) |*b| {
            if (b.terminated) continue;
            try b.body.appendSlice(self.arena, "  unreachable\n");
            b.terminated = true;
        }
    }

    fn serialize(self: *FnEmitter, out: *std.ArrayList(u8)) !void {
        var signature: std.ArrayList(u8) = .empty;
        for (self.func.params, 0..) |_, i| {
            const param_type = try llvmType(self.info.params[i]);
            if (i != 0) try signature.appendSlice(self.arena, ", ");
            try signature.print(self.arena, "{s} %arg{d}", .{ param_type, i });
        }

        const ret_type = try llvmType(self.info.return_type);
        try out.print(self.arena, "define {s} @{s}({s}) {{\n", .{ ret_type, self.func.name, signature.items });

        for (self.blocks.items) |*b| {
            try out.print(self.arena, "{s}:\n", .{b.label});
            try appendIndented(out, self.arena, b.body.items);
        }
        try out.appendSlice(self.arena, "}\n");
    }

    fn emitStatements(self: *FnEmitter, stmts: []*ast.Stmt) Error!void {
        for (stmts) |stmt| {
            if (self.block().terminated) return;
            try self.emitStatement(stmt);
        }
    }

    fn emitStatement(self: *FnEmitter, stmt: *ast.Stmt) Error!void {
        switch (stmt.kind) {
            .let_decl => |decl| {
                const symbol = self.symbolAt(stmt.decl_symbol orelse return error.MiscompiledAst);
                if (symbol.typ == .aggregate) {
                    try self.emitStructStore(symbol, decl.init);
                    return;
                }
                if (symbol.typ == .str) {
                    try self.emitStrStore(symbol, decl.init);
                    return;
                }
                const value = try self.emitExpr(decl.init);
                if (value.typ == .void) return error.UnsupportedNode;
                const ty = try llvmType(symbol.typ);
                const align_value = try typeAlign(symbol.typ);
                const name = try self.varName(symbol.slot);
                try self.emit("  store {s} {s}, ptr {s}, align {d}\n", .{ ty, value.text, name, align_value });
            },

            .assign => |assign| {
                const symbol = self.symbolAt(assign.resolved orelse return error.MiscompiledAst);
                if (symbol.typ == .aggregate) {
                    try self.emitStructStore(symbol, assign.value);
                    return;
                }
                if (symbol.typ == .str) {
                    try self.emitStrStore(symbol, assign.value);
                    return;
                }
                const value = try self.emitExpr(assign.value);
                if (value.typ == .void) return error.UnsupportedNode;
                const ty = try llvmType(symbol.typ);
                const align_value = try typeAlign(symbol.typ);
                const name = try self.varName(symbol.slot);
                try self.emit("  store {s} {s}, ptr {s}, align {d}\n", .{ ty, value.text, name, align_value });
            },

            .field_assign => |field_assign| {
                const base = self.symbolAt(field_assign.base.resolved orelse return error.MiscompiledAst);
                if (base.typ != .aggregate) return error.MiscompiledAst;
                const field_index = field_assign.field_index orelse return error.MiscompiledAst;
                if (base.struct_id >= self.checked.structs.len) return error.MiscompiledAst;
                const field = &self.checked.structs[base.struct_id].fields[field_index];

                const value = try self.emitExpr(field_assign.value);
                if (value.typ == .void) return error.UnsupportedNode;
                const ty = try llvmType(field.typ);
                const align_value = try typeAlign(field.typ);
                const name = try self.varName(base.slot + 1 + field_index);
                try self.emit("  store {s} {s}, ptr {s}, align {d}\n", .{ ty, value.text, name, align_value });
            },

            .return_stmt => |maybe_expr| {
                if (self.info.return_type == .void) {
                    try self.retVoid();
                } else {
                    const expr = maybe_expr orelse return error.MiscompiledAst;
                    const value = try self.emitExpr(expr);
                    const ty = try llvmType(self.info.return_type);
                    try self.emit("  ret {s} {s}\n", .{ ty, value.text });
                    self.block().terminated = true;
                }
            },

            .expr_stmt => |expr| {
                _ = try self.emitExpr(expr);
            },

            .if_stmt => |if_stmt| {
                const cond = try self.emitExpr(if_stmt.cond);
                const then_label = try self.newLabel("if_then");
                const else_label = try self.newLabel("if_else");
                const end_label = try self.newLabel("if_end");
                try self.condBr(cond.text, then_label, else_label);

                try self.startBlock(then_label);
                try self.emitStatements(if_stmt.then_body);
                try self.br(end_label);

                try self.startBlock(else_label);
                if (if_stmt.else_body) |else_branch| {
                    switch (else_branch) {
                        .block => |stmts| try self.emitStatements(stmts),
                        .if_stmt => |nested| try self.emitStatement(nested),
                    }
                }
                try self.br(end_label);

                try self.startBlock(end_label);
            },

            .while_stmt => |while_stmt| {
                const cond_label = try self.newLabel("while_cond");
                const body_label = try self.newLabel("while_body");
                const end_label = try self.newLabel("while_end");

                try self.br(cond_label);
                try self.startBlock(cond_label);
                const cond = try self.emitExpr(while_stmt.cond);
                try self.condBr(cond.text, body_label, end_label);

                try self.startBlock(body_label);
                try self.emitStatements(while_stmt.body);
                try self.br(cond_label);

                try self.startBlock(end_label);
            },

            .block => |stmts| try self.emitStatements(stmts),
        }
    }

    fn emitExpr(self: *FnEmitter, expr: *ast.Expr) Error!Operand {
        switch (expr.kind) {
            .int_literal => |lit| {
                const text = try std.fmt.allocPrint(self.arena, "{d}", .{lit.value});
                return .{ .text = text, .typ = .i32 };
            },

            .bool_literal => |value| {
                return .{ .text = if (value) "true" else "false", .typ = .bool };
            },

            .identifier => {
                const symbol = self.symbolAt(expr.resolved orelse return error.MiscompiledAst);
                // `str` são dois slots: só é copiado/impresso por rotinas
                // dedicadas, e a semântica recusa usá-lo como escalar.
                if (symbol.typ == .str) return error.MiscompiledAst;
                const ty = try llvmType(symbol.typ);
                const align_value = try typeAlign(symbol.typ);
                const name = try self.varName(symbol.slot);
                const result = try self.newTemp();
                try self.emit("  {s} = load {s}, ptr {s}, align {d}\n", .{ result, ty, name, align_value });
                return .{ .text = result, .typ = symbol.typ };
            },

            .unary => |unary| return self.emitUnary(expr, unary),

            .binary => |binary| return self.emitBinary(binary),

            .call => |call| return self.emitCall(call),

            .field_access => |access| {
                const base = self.symbolAt(access.base.resolved orelse return error.MiscompiledAst);
                if (base.typ != .aggregate) return error.MiscompiledAst;
                const field_index = access.field_index orelse return error.MiscompiledAst;
                if (base.struct_id >= self.checked.structs.len) return error.MiscompiledAst;
                const field_type = self.checked.structs[base.struct_id].fields[field_index].typ;

                const ty = try llvmType(field_type);
                const align_value = try typeAlign(field_type);
                const name = try self.varName(base.slot + 1 + field_index);
                const result = try self.newTemp();
                try self.emit("  {s} = load {s}, ptr {s}, align {d}\n", .{ result, ty, name, align_value });
                return .{ .text = result, .typ = field_type };
            },

            // Struct completo não é um operando: `let`/atribuição o tratam
            // campo a campo em `emitStructStore`.
            .struct_literal => return error.UnsupportedNode,
            // `str` são dois slots (ponteiro + tamanho), tratados por
            // `emitStrStore` e `emitPrint`.
            .str_literal => return error.UnsupportedNode,
        }
    }

    /// Grava um valor `str` (ponteiro e tamanho) nos dois slots de `dst`:
    /// literal direto ou cópia de outra variável `str`.
    fn emitStrStore(self: *FnEmitter, dst: *const sema.Symbol, value: *ast.Expr) Error!void {
        const ptr_slot = try self.varName(dst.slot);
        const len_slot = try self.varName(dst.slot + 1);

        switch (value.kind) {
            .str_literal => |text| {
                const index = try self.state.strs.intern(text);
                try self.emit("  store ptr @.str{d}, ptr {s}, align 8\n", .{ index, ptr_slot });
                try self.emit("  store i64 {d}, ptr {s}, align 8\n", .{ text.len, len_slot });
            },
            .identifier => {
                const src = self.symbolAt(value.resolved orelse return error.MiscompiledAst);
                if (src.typ != .str) return error.MiscompiledAst;
                const ptr_temp = try self.newTemp();
                try self.emit("  {s} = load ptr, ptr {s}, align 8\n", .{ ptr_temp, try self.varName(src.slot) });
                const len_temp = try self.newTemp();
                try self.emit("  {s} = load i64, ptr {s}, align 8\n", .{ len_temp, try self.varName(src.slot + 1) });
                try self.emit("  store ptr {s}, ptr {s}, align 8\n", .{ ptr_temp, ptr_slot });
                try self.emit("  store i64 {s}, ptr {s}, align 8\n", .{ len_temp, len_slot });
            },
            else => return error.MiscompiledAst,
        }
    }

    /// `print(s)`: duas chamadas a `write` da libc — o texto e a quebra de
    /// linha. O resultado de `write` é descartado (a linguagem não expõe I/O
    /// de baixo nível ainda).
    fn emitPrint(self: *FnEmitter, call: ast.Expr.Call) Error!Operand {
        if (call.args.len != 1) return error.MiscompiledAst;
        const arg = call.args[0];

        var ptr_text: []const u8 = undefined;
        var len_text: []const u8 = undefined;
        switch (arg.kind) {
            .str_literal => |text| {
                const index = try self.state.strs.intern(text);
                ptr_text = try std.fmt.allocPrint(self.arena, "@.str{d}", .{index});
                len_text = try std.fmt.allocPrint(self.arena, "{d}", .{text.len});
            },
            .identifier => {
                const symbol = self.symbolAt(arg.resolved orelse return error.MiscompiledAst);
                if (symbol.typ != .str) return error.MiscompiledAst;
                const ptr_temp = try self.newTemp();
                try self.emit("  {s} = load ptr, ptr {s}, align 8\n", .{ ptr_temp, try self.varName(symbol.slot) });
                const len_temp = try self.newTemp();
                try self.emit("  {s} = load i64, ptr {s}, align 8\n", .{ len_temp, try self.varName(symbol.slot + 1) });
                ptr_text = ptr_temp;
                len_text = len_temp;
            },
            else => return error.UnsupportedNode,
        }

        try self.emit("  call i64 @write(i32 1, ptr {s}, i64 {s})\n", .{ ptr_text, len_text });
        try self.emit("  call i64 @write(i32 1, ptr @.nl, i64 1)\n", .{});
        self.state.used_print = true;
        return .{ .text = "", .typ = .void };
    }

    /// Copia um struct para os slots de `dst` (literal ou outra variável).
    fn emitStructStore(self: *FnEmitter, dst: *const sema.Symbol, value: *ast.Expr) Error!void {
        if (dst.struct_id >= self.checked.structs.len) return error.MiscompiledAst;
        const info = &self.checked.structs[dst.struct_id];

        switch (value.kind) {
            .struct_literal => |lit| {
                for (info.fields, 0..) |field, i| {
                    const init_value = findFieldInit(lit.fields, field.name) orelse return error.MiscompiledAst;
                    const operand = try self.emitExpr(init_value);
                    const ty = try llvmType(field.typ);
                    const align_value = try typeAlign(field.typ);
                    const name = try self.varName(dst.slot + 1 + @as(u32, @intCast(i)));
                    try self.emit("  store {s} {s}, ptr {s}, align {d}\n", .{ ty, operand.text, name, align_value });
                }
            },
            .identifier => {
                const src = self.symbolAt(value.resolved orelse return error.MiscompiledAst);
                if (src.typ != .aggregate) return error.MiscompiledAst;
                for (info.fields, 0..) |field, i| {
                    const index: u32 = @intCast(i);
                    const ty = try llvmType(field.typ);
                    const align_value = try typeAlign(field.typ);
                    const src_name = try self.varName(src.slot + 1 + index);
                    const dst_name = try self.varName(dst.slot + 1 + index);
                    const tmp = try self.newTemp();
                    try self.emit("  {s} = load {s}, ptr {s}, align {d}\n", .{ tmp, ty, src_name, align_value });
                    try self.emit("  store {s} {s}, ptr {s}, align {d}\n", .{ ty, tmp, dst_name, align_value });
                }
            },
            else => return error.MiscompiledAst,
        }
    }

    fn emitUnary(self: *FnEmitter, expr: *ast.Expr, unary: ast.Expr.Unary) Error!Operand {
        const operand = try self.emitExpr(unary.operand);
        if (operand.typ == .void) return error.UnsupportedNode;
        const result = try self.newTemp();
        switch (unary.op) {
            .neg => try self.emit("  {s} = sub i32 0, {s}\n", .{ result, operand.text }),
            .not => try self.emit("  {s} = xor i1 {s}, true\n", .{ result, operand.text }),
        }
        _ = expr;
        return .{
            .text = result,
            .typ = if (unary.op == .neg) .i32 else .bool,
        };
    }

    fn emitBinary(self: *FnEmitter, binary: ast.Expr.Binary) Error!Operand {
        if (binary.op.isLogical()) return self.emitLogical(binary);

        const lhs = try self.emitExpr(binary.lhs);
        const rhs = try self.emitExpr(binary.rhs);
        if (lhs.typ == .void or rhs.typ == .void) return error.UnsupportedNode;
        if (lhs.typ != rhs.typ) return error.UnsupportedNode;

        const ty = try llvmType(lhs.typ);
        const result = try self.newTemp();

        switch (binary.op) {
            .add => try self.emit("  {s} = add {s} {s}, {s}\n", .{ result, ty, lhs.text, rhs.text }),
            .sub => try self.emit("  {s} = sub {s} {s}, {s}\n", .{ result, ty, lhs.text, rhs.text }),
            .mul => try self.emit("  {s} = mul {s} {s}, {s}\n", .{ result, ty, lhs.text, rhs.text }),
            .div => try self.emit("  {s} = sdiv {s} {s}, {s}\n", .{ result, ty, lhs.text, rhs.text }),
            .mod => try self.emit("  {s} = srem {s} {s}, {s}\n", .{ result, ty, lhs.text, rhs.text }),
            .lt => try self.emit("  {s} = icmp slt {s} {s}, {s}\n", .{ result, ty, lhs.text, rhs.text }),
            .le => try self.emit("  {s} = icmp sle {s} {s}, {s}\n", .{ result, ty, lhs.text, rhs.text }),
            .gt => try self.emit("  {s} = icmp sgt {s} {s}, {s}\n", .{ result, ty, lhs.text, rhs.text }),
            .ge => try self.emit("  {s} = icmp sge {s} {s}, {s}\n", .{ result, ty, lhs.text, rhs.text }),
            .eq => try self.emit("  {s} = icmp eq {s} {s}, {s}\n", .{ result, ty, lhs.text, rhs.text }),
            .ne => try self.emit("  {s} = icmp ne {s} {s}, {s}\n", .{ result, ty, lhs.text, rhs.text }),
            .and_op, .or_op => unreachable,
        }

        return .{
            .text = result,
            .typ = if (binary.op.isArithmetic()) .i32 else .bool,
        };
    }

    /// `&&` e `||` com curto-circuito, usando blocos e `phi`.
    fn emitLogical(self: *FnEmitter, binary: ast.Expr.Binary) Error!Operand {
        const lhs = try self.emitExpr(binary.lhs);
        const is_and = binary.op == .and_op;

        const rhs_label = try self.newLabel(if (is_and) "and_rhs" else "or_rhs");
        const end_label = try self.newLabel(if (is_and) "and_end" else "or_end");
        const lhs_label = self.block().label;

        if (is_and) {
            try self.condBr(lhs.text, rhs_label, end_label);
        } else {
            try self.condBr(lhs.text, end_label, rhs_label);
        }

        try self.startBlock(rhs_label);
        const rhs = try self.emitExpr(binary.rhs);
        const rhs_source = self.block().label;
        try self.br(end_label);

        try self.startBlock(end_label);
        const result = try self.newTemp();
        const short_value = if (is_and) "false" else "true";
        try self.emit("  {s} = phi i1 [ {s}, %{s} ], [ {s}, %{s} ]\n", .{
            result, short_value, lhs_label, rhs.text, rhs_source,
        });
        return .{ .text = result, .typ = .bool };
    }

    fn emitCall(self: *FnEmitter, call: ast.Expr.Call) Error!Operand {
        if (call.builtin) |builtin| switch (builtin) {
            .print => return self.emitPrint(call),
        };

        const fn_index = call.callee_fn orelse return error.MiscompiledAst;
        const callee = self.checked.functions[fn_index];

        var args: std.ArrayList(u8) = .empty;
        for (call.args, 0..) |arg, i| {
            const value = try self.emitExpr(arg);
            if (value.typ == .void) return error.UnsupportedNode;
            const ty = try llvmType(value.typ);
            if (i != 0) try args.appendSlice(self.arena, ", ");
            try args.print(self.arena, "{s} {s}", .{ ty, value.text });
        }

        const ret_type = try llvmType(callee.return_type);
        if (callee.return_type == .void) {
            try self.emit("  call void @{s}({s})\n", .{ call.callee, args.items });
            return .{ .text = "", .typ = .void };
        }

        const result = try self.newTemp();
        try self.emit("  {s} = call {s} @{s}({s})\n", .{ result, ret_type, call.callee, args.items });
        return .{ .text = result, .typ = callee.return_type };
    }
};

fn appendIndented(out: *std.ArrayList(u8), arena: std.mem.Allocator, text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try out.print(arena, "  {s}\n", .{line});
    }
}

// ---------------------------------------------------------------------------
// Testes estruturais do IR emitido
// ---------------------------------------------------------------------------

const testing = std.testing;
const support = @import("test_support.zig");

fn emitFixture(f: *support.Fixture) ![]const u8 {
    return emit(f.allocator(), f.program, &f.checked);
}

test "llvm: função main trivial" {
    var f = try support.Fixture.build("fn main() -> i32 { return 7; }");
    defer f.deinit();
    const ir = try emitFixture(&f);
    try support.expectContains(ir, "define i32 @main() {");
    try support.expectContains(ir, "ret i32 7");
    try support.expectContains(ir, "entry:");
    try support.expectAllBlocksTerminated(ir);
}

test "llvm: aritmética é emitida com a instrução correta" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    let a: i32 = 2 + 3;
        \\    let b: i32 = a * 4;
        \\    let c: i32 = b - 1;
        \\    let d: i32 = c / 3;
        \\    return d % 5;
        \\}
    );
    defer f.deinit();
    const ir = try emitFixture(&f);
    try support.expectContains(ir, "add i32");
    try support.expectContains(ir, "mul i32");
    try support.expectContains(ir, "sub i32");
    try support.expectContains(ir, "sdiv i32");
    try support.expectContains(ir, "srem i32");
    try support.expectAllBlocksTerminated(ir);
}

test "llvm: comparação produz i1 e bool usa alinhamento 1" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    let ok: bool = 1 < 2;
        \\    if ok { return 1; } else { return 0; }
        \\}
    );
    defer f.deinit();
    const ir = try emitFixture(&f);
    try support.expectContains(ir, "icmp slt i32");
    try support.expectContains(ir, "alloca i1, align 1");
    try support.expectContains(ir, "br i1");
    try support.expectAllBlocksTerminated(ir);
}

test "llvm: and/or usam blocos e phi" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    let both: bool = 1 < 2 && 2 < 3 || false;
        \\    if both { return 1; }
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const ir = try emitFixture(&f);
    try support.expectContains(ir, "phi i1");
    try support.expectContains(ir, "and_rhs");
    try support.expectContains(ir, "or_rhs");
    try support.expectAllBlocksTerminated(ir);
}

test "llvm: while gera laço com rótulos próprios" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    var i: i32 = 0;
        \\    while i < 3 { i = i + 1; }
        \\    return i;
        \\}
    );
    defer f.deinit();
    const ir = try emitFixture(&f);
    try support.expectContains(ir, "while_cond0:");
    try support.expectContains(ir, "while_body1:");
    try support.expectContains(ir, "while_end2:");
    try support.expectAllBlocksTerminated(ir);
}

test "llvm: chamada de função usa a assinatura resolvida" {
    var f = try support.Fixture.build(
        \\fn add(a: i32, b: i32) -> i32 { return a + b; }
        \\fn main() -> i32 { return add(1, 2); }
    );
    defer f.deinit();
    const ir = try emitFixture(&f);
    try support.expectContains(ir, "define i32 @add(i32 %arg0, i32 %arg1) {");
    try support.expectContains(ir, "call i32 @add(i32 1, i32 2)");
    try support.expectContains(ir, "store i32 %arg1, ptr %v1, align 4");
    try support.expectAllBlocksTerminated(ir);
}

test "llvm: função void retorna com ret void" {
    var f = try support.Fixture.build("fn main() -> void { return; }");
    defer f.deinit();
    const ir = try emitFixture(&f);
    try support.expectContains(ir, "define void @main() {");
    try support.expectContains(ir, "ret void");
    try support.expectAllBlocksTerminated(ir);
}

test "llvm: código após return não é emitido" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    return 1;
        \\    return 2;
        \\}
    );
    defer f.deinit();
    const ir = try emitFixture(&f);
    try testing.expect(std.mem.indexOf(u8, ir, "ret i32 2") == null);
    try support.expectAllBlocksTerminated(ir);
}

test "llvm: struct vira um alloca por campo (substituição escalar)" {
    var f = try support.Fixture.build(
        \\struct Ponto { x: i32, y: bool }
        \\fn main() -> i32 {
        \\    var p: Ponto = Ponto { x: 7, y: true };
        \\    p.x = p.x + 1;
        \\    if p.y { return p.x; }
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const ir = try emitFixture(&f);

    try support.expectContains(ir, "%v1 = alloca i32, align 4");
    try support.expectContains(ir, "%v2 = alloca i1, align 1");
    try support.expectContains(ir, "store i32 7, ptr %v1, align 4");
    try support.expectContains(ir, "store i1 true, ptr %v2, align 1");
    try support.expectContains(ir, "load i32, ptr %v1, align 4");
    try support.expectContains(ir, "ret i32");
    // Sem tipos agregados: struct nunca aparece como tipo LLVM.
    try std.testing.expect(std.mem.indexOf(u8, ir, "alloca %") == null);
}

test "llvm: cópia de struct carrega e grava cada campo" {
    var f = try support.Fixture.build(
        \\struct P { a: i32, b: i32 }
        \\fn main() -> i32 {
        \\    let src: P = P { a: 1, b: 2 };
        \\    let dst: P = src;
        \\    return dst.a + dst.b;
        \\}
    );
    defer f.deinit();
    const ir = try emitFixture(&f);
    try support.expectContains(ir, "%v1 = alloca i32, align 4");
    try support.expectContains(ir, "%v4 = alloca i32, align 4");
    try support.expectContains(ir, "store i32 1, ptr %v1, align 4");
    try support.expectContains(ir, "ptr %v4, align 4");
}

/// Valor inicial de um campo dentro de um literal de struct, por nome.
fn findFieldInit(inits: []ast.Expr.FieldInit, name: []const u8) ?*ast.Expr {
    for (inits) |init| {
        if (std.mem.eql(u8, init.name, name)) return init.value;
    }
    return null;
}

test "llvm: print declara e chama write com a constante da string" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    print("ok");
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const ir = try emitFixture(&f);

    try support.expectContains(ir, "declare i64 @write(i32, ptr, i64)");
    try support.expectContains(ir, "@.str0 = private unnamed_addr constant [2 x i8] [i8 111, i8 107], align 1");
    try support.expectContains(ir, "call i64 @write(i32 1, ptr @.str0, i64 2)");
    try support.expectContains(ir, "@.nl = private unnamed_addr constant [1 x i8] [i8 10], align 1");
    try support.expectContains(ir, "call i64 @write(i32 1, ptr @.nl, i64 1)");
    try support.expectAllBlocksTerminated(ir);
}

test "llvm: str vira dois allocas (ponteiro e tamanho)" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    var s: str = "abc";
        \\    s = "de";
        \\    print(s);
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const ir = try emitFixture(&f);

    try support.expectContains(ir, "%v0 = alloca ptr, align 8");
    try support.expectContains(ir, "%v1 = alloca i64, align 8");
    try support.expectContains(ir, "store ptr @.str0, ptr %v0, align 8");
    try support.expectContains(ir, "store i64 3, ptr %v1, align 8");
    try support.expectContains(ir, "store ptr @.str1, ptr %v0, align 8");
    try support.expectContains(ir, "load ptr, ptr %v0, align 8");
    try support.expectContains(ir, "load i64, ptr %v1, align 8");
    try support.expectAllBlocksTerminated(ir);
}

test "llvm: literais repetidos compartilham a mesma constante" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    print("kyn");
        \\    print("kyn");
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const ir = try emitFixture(&f);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, ir, "@.str0 ="));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, ir, "ptr @.str0"));
    try testing.expect(std.mem.indexOf(u8, ir, "@.str1") == null);
}

test "llvm: string vazia usa zeroinitializer" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    print("");
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const ir = try emitFixture(&f);

    try support.expectContains(ir, "@.str0 = private unnamed_addr constant [0 x i8] zeroinitializer, align 1");
    try support.expectContains(ir, "call i64 @write(i32 1, ptr @.str0, i64 0)");
}
