//! Backend nativo x86-64 (Linux, System V AMD64), sem dependência de libc.
//!
//! Estratégia:
//! - cada variável (parâmetro ou local) recebe um slot de 8 bytes no frame;
//!   `i32`/`bool` ocupam 4 bytes no slot e são carregados em 32 bits;
//! - variável de struct ocupa um slot de base (reservado) seguido de um slot
//!   por campo, na ordem da declaração (`slot + 1 + índice`); structs nunca
//!   escapam da função (sem parâmetros/retorno por valor), então cabe em
//!   variáveis locais;
//! - expressões são avaliadas em `%eax` com pilha de temporários;
//! - `str` é uma fatia (ponteiro + tamanho) guardada em dois slots; em
//!   chamadas ela ocupa **dois registradores consecutivos** (`%rdi/%rsi`,
//!   `%rdx/%rcx`, `%r8/%r9` — no máximo três `str` por chamada) e o retorno
//!   volta em `%rax` (ponteiro) e `%rdx` (tamanho);
//! - `_start` chama `kyn_main` e encerra via syscall `exit` (60) com o valor
//!   retornado por `main` (`0` quando `main` é `void`).
//!
//! Este backend é o caminho validável: `as` + `ld` produzem um binário que pode
//! ser executado e conferido pelo código de saída (ver `tools/e2e.sh`).
//!
//! Limitações conhecidas: até 6 parâmetros (registradores SysV), nenhuma
//! chamada externa, `bool` é materializado como 32 bits, sem otimização.

const std = @import("std");
const ast = @import("../ast/ast.zig");
const sema = @import("../sema/sema.zig");
const codegen = @import("codegen.zig");

pub const Error = codegen.Error;

const arg_registers = [_][]const u8{ "%edi", "%esi", "%edx", "%ecx", "%r8d", "%r9d" };
/// Nomes de 64 bits dos mesmos registradores: usados para `str` (ponteiro e
/// tamanho são valores de 8 bytes).
const arg_registers_64 = [_][]const u8{ "%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9" };

/// Registradores de retorno de um struct: um por campo, na ordem de declaração.
/// Não colidem com os de argumento porque o chamador já consumiu os deles.
const struct_return_registers = [_][]const u8{ "%eax", "%edx", "%ecx", "%r8d", "%r9d", "%r10d" };

/// Os mesmos registradores em 64 bits, usados ao empilhar um struct devolvido
/// por chamada para repassá-lo como argumento de outra chamada.
const struct_return_registers_64 = [_][]const u8{ "%rax", "%rdx", "%rcx", "%r8", "%r9", "%r10" };

pub fn emit(
    arena: std.mem.Allocator,
    program: *const ast.Program,
    checked: *const sema.Checked,
) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var state = codegen.ProgramState{ .strs = codegen.StrPool.init(arena) };

    // Ponto de entrada do processo: chama `kyn_main` e encerra com syscall.
    const main_index = checked.findFunction("main") orelse return error.UnsupportedNode;
    const main_info = checked.functions[main_index];

    try out.print(arena, "# assembly x86-64 (System V, Linux) gerado pelo kync\n", .{});
    try out.print(arena, ".text\n", .{});
    try out.print(arena, ".globl _start\n", .{});
    try out.print(arena, "_start:\n", .{});
    try out.print(arena, "    call kyn_{s}\n", .{main_info.decl.name});
    if (main_info.return_type == .void) {
        try out.print(arena, "    xorl %edi, %edi\n", .{});
    } else {
        try out.print(arena, "    movl %eax, %edi\n", .{});
    }
    try out.print(arena, "    movl $60, %eax\n", .{});
    try out.print(arena, "    syscall\n\n", .{});

    for (program.functions, 0..) |func, i| {
        var emitter = FnEmitter.init(arena, func, checked, checked.functions[i], &state);
        try emitter.emitFunction(&out);
        try out.append(arena, '\n');
    }

    // Rotina de formatação decimal, emitida uma única vez por programa quando
    // `print_i32` aparece. Fica em `.text` (código), antes dos dados: `divl` é
    // unsigned, então após `negl` INT_MIN vira 0x80000000 e o laço produz
    // 2147483648 dígitos, com '-' na frente — resultado correto para
    // -2147483648. Sem libc e sem estado global.
    if (state.used_print_i32) {
        try out.print(arena, ".text\n", .{});
        try out.appendSlice(arena,
            \\.type kyn_print_i32, @function
            \\kyn_print_i32:
            \\    pushq %rbp
            \\    movq %rsp, %rbp
            \\    subq $32, %rsp
            \\    movl %edi, %eax
            \\    xorl %r8d, %r8d
            \\    testl %eax, %eax
            \\    jns .Lpi_abs
            \\    movl $1, %r8d
            \\    negl %eax
            \\.Lpi_abs:
            \\    leaq -12(%rbp), %rsi
            \\    movl $0, %ecx
            \\    movl $10, %r9d
            \\.Lpi_loop:
            \\    xorl %edx, %edx
            \\    divl %r9d
            \\    addl $48, %edx
            \\    decq %rsi
            \\    movb %dl, (%rsi)
            \\    incl %ecx
            \\    testl %eax, %eax
            \\    jne .Lpi_loop
            \\    testl %r8d, %r8d
            \\    je .Lpi_write
            \\    decq %rsi
            \\    movb $45, (%rsi)
            \\    incl %ecx
            \\.Lpi_write:
            \\    movl $1, %eax
            \\    movl $1, %edi
            \\    movq %rcx, %rdx
            \\    syscall
            \\    leaq .Lnl(%rip), %rsi
            \\    movq $1, %rdx
            \\    movl $1, %eax
            \\    movl $1, %edi
            \\    syscall
            \\    movq %rbp, %rsp
            \\    popq %rbp
            \\    ret
            \\.size kyn_print_i32, .-kyn_print_i32
            \\
        );
    }

    // Rodapé: constantes de string (deduplicadas) e a quebra de linha de
    // `print`. Só são emitidas quando o programa usa esse recurso.
    if (state.strs.texts.items.len > 0 or state.used_print or state.used_print_i32) {
        try out.print(arena, ".section .rodata\n", .{});
        for (state.strs.texts.items, 0..) |text, index| {
            try out.print(arena, ".Lstr{d}:\n", .{index});
            if (text.len == 0) {
                // `as` não aceita `.byte` sem operandos; um byte de padding
                // mantém o rótulo válido para comprimento zero (nada é escrito).
                try out.print(arena, "    .zero 1\n", .{});
            } else {
                try out.print(arena, "    .byte ", .{});
                for (text, 0..) |byte, byte_index| {
                    if (byte_index != 0) try out.print(arena, ", ", .{});
                    try out.print(arena, "{d}", .{byte});
                }
                try out.print(arena, "\n", .{});
            }
        }
        if (state.used_print or state.used_print_i32) {
            try out.print(arena, ".Lnl:\n    .byte 10\n", .{});
        }
    }

    try out.print(arena, ".section .note.GNU-stack,\"\",@progbits\n", .{});
    return out.toOwnedSlice(arena);
}

const FnEmitter = struct {
    arena: std.mem.Allocator,
    func: *const ast.Function,
    checked: *const sema.Checked,
    info: sema.FunctionInfo,
    out: *std.ArrayList(u8) = undefined,
    /// Estado compartilhado do programa (pool de strings e uso de `print`).
    state: *codegen.ProgramState,
    label_count: u32 = 0,
    /// Bloco corrente já terminou (return)? Evita emitir código inalcançável.
    terminated: bool = false,

    fn init(
        arena: std.mem.Allocator,
        func: *const ast.Function,
        checked: *const sema.Checked,
        info: sema.FunctionInfo,
        state: *codegen.ProgramState,
    ) FnEmitter {
        return .{ .arena = arena, .func = func, .checked = checked, .info = info, .state = state };
    }

    fn print(self: *FnEmitter, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(self.arena, fmt, args);
    }

    fn label(self: *FnEmitter, prefix: []const u8) ![]const u8 {
        const name = try std.fmt.allocPrint(self.arena, ".L{s}_{s}_{d}", .{
            self.func.name, prefix, self.label_count,
        });
        self.label_count += 1;
        return name;
    }

    fn slotOffset(slot: u32) u32 {
        return 8 * (slot + 1);
    }

    fn symbolAt(self: *FnEmitter, index: u32) *const sema.Symbol {
        return &self.checked.symbols[index];
    }

    /// Palavras de registrador que o tipo consome (struct: um por campo).
    fn registerWordsOf(self: *FnEmitter, typ: sema.Type, struct_id: u32) usize {
        return sema.registerWordsOf(self.checked.structs, typ, struct_id);
    }

    fn structFields(self: *FnEmitter, struct_id: u32) Error![]const sema.FieldInfo {
        if (struct_id >= self.checked.structs.len) return error.MiscompiledAst;
        return self.checked.structs[struct_id].fields;
    }

    fn emitFunction(self: *FnEmitter, out: *std.ArrayList(u8)) !void {
        self.out = out;

        // `str` consome dois registradores e cada campo de struct um; a
        // semântica já limita o total.
        var register_words: usize = 0;
        for (self.info.params, 0..) |ptype, i| {
            const struct_id = if (i < self.info.param_struct_ids.len) self.info.param_struct_ids[i] else 0;
            register_words += self.registerWordsOf(ptype, struct_id);
        }
        if (register_words > arg_registers.len) return error.UnsupportedNode;

        const frame_bytes: u32 = std.mem.alignForward(u32, self.info.slot_count * 8, 16);

        try self.print(".type kyn_{s}, @function\n", .{self.func.name});
        try self.print("kyn_{s}:\n", .{self.func.name});
        try self.print("    pushq %rbp\n", .{});
        try self.print("    movq %rsp, %rbp\n", .{});
        if (frame_bytes > 0) {
            try self.print("    subq ${d}, %rsp\n", .{frame_bytes});
        }

        // Parâmetros: registradores -> slots. `str` grava ponteiro e tamanho.
        var reg: usize = 0;
        for (self.func.params, 0..) |_, i| {
            const sym = &self.checked.symbols[self.info.symbol_start + i];
            if (sym.typ == .aggregate) {
                if (sym.struct_id >= self.checked.structs.len) return error.MiscompiledAst;
                const fields = self.checked.structs[sym.struct_id].fields;
                for (fields, 0..) |_, field_index| {
                    try self.print("    movl {s}, -{d}(%rbp)\n", .{
                        arg_registers[reg],
                        slotOffset(sym.slot + 1 + @as(u32, @intCast(field_index))),
                    });
                    reg += 1;
                }
                continue;
            }
            if (sym.typ == .str) {
                try self.print("    movq {s}, -{d}(%rbp)\n", .{ arg_registers_64[reg], slotOffset(sym.slot) });
                try self.print("    movq {s}, -{d}(%rbp)\n", .{ arg_registers_64[reg + 1], slotOffset(sym.slot + 1) });
                reg += 2;
            } else {
                try self.print("    movl {s}, -{d}(%rbp)\n", .{ arg_registers[reg], slotOffset(sym.slot) });
                reg += 1;
            }
        }

        try self.emitStatements(self.func.body);

        if (!self.terminated) {
            if (self.info.return_type != .void) {
                try self.print("    xorl %eax, %eax\n", .{});
            }
            try self.print("    movq %rbp, %rsp\n", .{});
            try self.print("    popq %rbp\n", .{});
            try self.print("    ret\n", .{});
            self.terminated = true;
        }

        try self.print(".size kyn_{s}, .-kyn_{s}\n", .{ self.func.name, self.func.name });
    }

    fn emitStatements(self: *FnEmitter, stmts: []*ast.Stmt) Error!void {
        for (stmts) |stmt| {
            if (self.terminated) return;
            try self.emitStatement(stmt);
        }
    }

    fn emitStatement(self: *FnEmitter, stmt: *ast.Stmt) Error!void {
        switch (stmt.kind) {
            .let_decl => |decl| {
                const symbol = self.symbolAt(stmt.decl_symbol orelse return error.MiscompiledAst);
                if (symbol.typ == .aggregate) {
                    try self.emitStructStore(symbol, decl.init);
                } else if (symbol.typ == .str) {
                    try self.emitStrStore(symbol, decl.init);
                } else {
                    try self.emitExpr(decl.init);
                    try self.print("    movl %eax, -{d}(%rbp)\n", .{slotOffset(symbol.slot)});
                }
            },

            .assign => |assign| {
                const symbol = self.symbolAt(assign.resolved orelse return error.MiscompiledAst);
                if (symbol.typ == .aggregate) {
                    try self.emitStructStore(symbol, assign.value);
                } else if (symbol.typ == .str) {
                    try self.emitStrStore(symbol, assign.value);
                } else {
                    try self.emitExpr(assign.value);
                    try self.print("    movl %eax, -{d}(%rbp)\n", .{slotOffset(symbol.slot)});
                }
            },

            .field_assign => |field_assign| {
                const base = self.symbolAt(field_assign.base.resolved orelse return error.MiscompiledAst);
                if (base.typ != .aggregate) return error.MiscompiledAst;
                const field_index = field_assign.field_index orelse return error.MiscompiledAst;
                try self.emitExpr(field_assign.value);
                try self.print("    movl %eax, -{d}(%rbp)\n", .{
                    slotOffset(base.slot + 1 + field_index),
                });
            },

            .return_stmt => |maybe_expr| {
                if (maybe_expr) |expr| {
                    if (self.info.return_type == .str) {
                        // Fatia de volta em `%rax` (ponteiro) e `%rdx` (tamanho).
                        try self.emitStrValue(expr);
                    } else if (self.info.return_type == .aggregate) {
                        // Struct volta com um registrador por campo.
                        try self.emitStructReturn(expr);
                    } else {
                        try self.emitExpr(expr);
                    }
                } else if (self.info.return_type != .void) {
                    return error.MiscompiledAst;
                }
                try self.print("    movq %rbp, %rsp\n", .{});
                try self.print("    popq %rbp\n", .{});
                try self.print("    ret\n", .{});
                self.terminated = true;
            },

            .expr_stmt => |expr| try self.emitExpr(expr),

            .if_stmt => |if_stmt| {
                const else_label = try self.label("else");
                const end_label = try self.label("endif");

                try self.emitExpr(if_stmt.cond);
                try self.print("    cmpl $0, %eax\n", .{});
                try self.print("    je {s}\n", .{else_label});

                try self.emitStatements(if_stmt.then_body);
                const then_terminated = self.terminated;
                if (!then_terminated) try self.print("    jmp {s}\n", .{end_label});

                try self.print("{s}:\n", .{else_label});
                self.terminated = false;
                if (if_stmt.else_body) |else_branch| {
                    switch (else_branch) {
                        .block => |stmts| try self.emitStatements(stmts),
                        .if_stmt => |nested| try self.emitStatement(nested),
                    }
                }
                const else_terminated = self.terminated;
                if (!else_terminated) try self.print("    jmp {s}\n", .{end_label});

                try self.print("{s}:\n", .{end_label});
                self.terminated = then_terminated and else_terminated;
            },

            .while_stmt => |while_stmt| {
                const cond_label = try self.label("while_cond");
                const end_label = try self.label("while_end");

                try self.print("{s}:\n", .{cond_label});
                self.terminated = false;
                try self.emitExpr(while_stmt.cond);
                try self.print("    cmpl $0, %eax\n", .{});
                try self.print("    je {s}\n", .{end_label});

                try self.emitStatements(while_stmt.body);
                self.terminated = false;
                try self.print("    jmp {s}\n", .{cond_label});
                try self.print("{s}:\n", .{end_label});
                self.terminated = false;
            },

            .block => |stmts| try self.emitStatements(stmts),
        }
    }

    fn emitExpr(self: *FnEmitter, expr: *ast.Expr) Error!void {
        switch (expr.kind) {
            .int_literal => |lit| {
                if (lit.value > std.math.maxInt(i32) or lit.value < std.math.minInt(i32)) {
                    return error.UnsupportedNode;
                }
                try self.print("    movl ${d}, %eax\n", .{@as(i32, @intCast(lit.value))});
            },

            .bool_literal => |value| {
                try self.print("    movl ${d}, %eax\n", .{@as(u8, if (value) 1 else 0)});
            },

            .identifier => {
                const symbol = self.symbolAt(expr.resolved orelse return error.MiscompiledAst);
                // `str` não cabe em `%eax`: só é copiado/impresso por rotinas
                // dedicadas, e a semântica recusa usá-lo como escalar.
                if (symbol.typ == .str) return error.MiscompiledAst;
                try self.print("    movl -{d}(%rbp), %eax\n", .{slotOffset(symbol.slot)});
            },

            .unary => |unary| {
                try self.emitExpr(unary.operand);
                switch (unary.op) {
                    .neg => try self.print("    negl %eax\n", .{}),
                    .not => {
                        try self.print("    cmpl $0, %eax\n", .{});
                        try self.print("    sete %al\n", .{});
                        try self.print("    movzbl %al, %eax\n", .{});
                    },
                }
            },

            .binary => |binary| {
                if (binary.op.isLogical()) {
                    try self.emitLogical(binary);
                } else {
                    try self.emitBinaryOp(binary);
                }
            },

            .call => |call| {
                // Valor de struct não cabe em `%eax`: quem consome usa
                // `emitStructStore`/`emitStructReturn`/`emitCall` direto.
                if (call.callee_fn) |index| {
                    if (self.checked.functions[index].return_type == .aggregate) {
                        return error.UnsupportedNode;
                    }
                }
                try self.emitCall(call);
            },

            .field_access => |access| {
                const base = self.symbolAt(access.base.resolved orelse return error.MiscompiledAst);
                if (base.typ != .aggregate) return error.MiscompiledAst;
                const field_index = access.field_index orelse return error.MiscompiledAst;
                try self.print("    movl -{d}(%rbp), %eax\n", .{
                    slotOffset(base.slot + 1 + field_index),
                });
            },

            // Valor de struct não cabe em `%eax`: `let`/atribuição tratam o
            // literal campo a campo em `emitStructStore`.
            .struct_literal => return error.UnsupportedNode,
            // `str` são dois slots (ponteiro + tamanho), tratados por
            // `emitStrStore` e `emitPrint`.
            .str_literal => return error.UnsupportedNode,
        }
    }

    /// Copia um valor de struct para os slots de `dst`: literal (cada campo
    /// avaliado e gravado) ou variável de struct (cópia campo a campo).
    fn emitStructStore(self: *FnEmitter, dst: *const sema.Symbol, value: *ast.Expr) Error!void {
        if (dst.struct_id >= self.checked.structs.len) return error.MiscompiledAst;
        const info = &self.checked.structs[dst.struct_id];

        switch (value.kind) {
            .struct_literal => |lit| {
                for (info.fields, 0..) |field, i| {
                    const init_value = findFieldInit(lit.fields, field.name) orelse return error.MiscompiledAst;
                    const index: u32 = @intCast(i);
                    try self.emitExpr(init_value);
                    try self.print("    movl %eax, -{d}(%rbp)\n", .{
                        slotOffset(dst.slot + 1 + index),
                    });
                }
            },
            .identifier => {
                const src = self.symbolAt(value.resolved orelse return error.MiscompiledAst);
                if (src.typ != .aggregate) return error.MiscompiledAst;
                for (info.fields, 0..) |_, i| {
                    const index: u32 = @intCast(i);
                    try self.print("    movl -{d}(%rbp), %eax\n", .{
                        slotOffset(src.slot + 1 + index),
                    });
                    try self.print("    movl %eax, -{d}(%rbp)\n", .{
                        slotOffset(dst.slot + 1 + index),
                    });
                }
            },
            .call => |call| {
                if (info.fields.len > struct_return_registers.len) return error.UnsupportedNode;
                try self.emitCall(call);
                for (info.fields, 0..) |_, i| {
                    const index: u32 = @intCast(i);
                    try self.print("    movl {s}, -{d}(%rbp)\n", .{
                        struct_return_registers[i],
                        slotOffset(dst.slot + 1 + index),
                    });
                }
            },
            else => return error.MiscompiledAst,
        }
    }

    /// Deixa um struct em `struct_return_registers`: um por campo, na ordem de
    /// declaração. Campos são avaliados na pilha para que um não clobbere o
    /// resultado do outro.
    fn emitStructReturn(self: *FnEmitter, value: *ast.Expr) Error!void {
        const fields = try self.structFields(self.info.return_struct_id);
        if (fields.len > struct_return_registers.len) return error.UnsupportedNode;

        switch (value.kind) {
            .identifier => {
                const src = self.symbolAt(value.resolved orelse return error.MiscompiledAst);
                if (src.typ != .aggregate) return error.MiscompiledAst;
                for (fields, 0..) |_, i| {
                    const index: u32 = @intCast(i);
                    try self.print("    movl -{d}(%rbp), {s}\n", .{
                        slotOffset(src.slot + 1 + index),
                        struct_return_registers[i],
                    });
                }
            },
            .call => |call| try self.emitCall(call),
            .struct_literal => |lit| {
                for (fields, 0..) |field, i| {
                    const init_value = findFieldInit(lit.fields, field.name) orelse return error.MiscompiledAst;
                    try self.emitExpr(init_value);
                    try self.print("    pushq %rax\n", .{});
                    _ = i;
                }
                var i: usize = fields.len;
                while (i > 0) {
                    i -= 1;
                    try self.print("    popq %rax\n", .{});
                    try self.print("    movl %eax, {s}\n", .{struct_return_registers[i]});
                }
            },
            else => return error.MiscompiledAst,
        }
    }

    /// Empilha um struct campo a campo (para passagem por valor em chamadas).
    fn emitStructArgsPush(self: *FnEmitter, struct_id: u32, value: *ast.Expr) Error!void {
        const fields = try self.structFields(struct_id);

        switch (value.kind) {
            .identifier => {
                const src = self.symbolAt(value.resolved orelse return error.MiscompiledAst);
                if (src.typ != .aggregate) return error.MiscompiledAst;
                for (fields, 0..) |_, i| {
                    const index: u32 = @intCast(i);
                    try self.print("    movl -{d}(%rbp), %eax\n", .{
                        slotOffset(src.slot + 1 + index),
                    });
                    try self.print("    pushq %rax\n", .{});
                }
            },
            .struct_literal => |lit| {
                for (fields) |field| {
                    const init_value = findFieldInit(lit.fields, field.name) orelse return error.MiscompiledAst;
                    try self.emitExpr(init_value);
                    try self.print("    pushq %rax\n", .{});
                }
            },
            .call => |call| {
                if (fields.len > struct_return_registers.len) return error.UnsupportedNode;
                try self.emitCall(call);
                for (fields, 0..) |_, i| {
                    try self.print("    pushq {s}\n", .{struct_return_registers_64[i]});
                }
            },
            else => return error.MiscompiledAst,
        }
    }

    /// Grava um valor `str` (ponteiro e tamanho) nos dois slots de `dst`:
    /// literal direto ou cópia de outra variável `str`.
    /// Deixa um valor `str` em `%rax` (ponteiro) e `%rdx` (tamanho) — a mesma
    /// convenção do retorno de função, o que permite reutilizar chamadas.
    fn emitStrValue(self: *FnEmitter, value: *ast.Expr) Error!void {
        switch (value.kind) {
            .str_literal => |text| {
                const index = try self.state.strs.intern(text);
                try self.print("    leaq .Lstr{d}(%rip), %rax\n", .{index});
                try self.print("    movq ${d}, %rdx\n", .{text.len});
            },
            .identifier => {
                const src = self.symbolAt(value.resolved orelse return error.MiscompiledAst);
                if (src.typ != .str) return error.MiscompiledAst;
                try self.print("    movq -{d}(%rbp), %rax\n", .{slotOffset(src.slot)});
                try self.print("    movq -{d}(%rbp), %rdx\n", .{slotOffset(src.slot + 1)});
            },
            .call => |call| {
                const index = call.callee_fn orelse return error.MiscompiledAst;
                if (self.checked.functions[index].return_type != .str) return error.MiscompiledAst;
                try self.emitCall(call);
            },
            else => return error.MiscompiledAst,
        }
    }

    fn emitStrStore(self: *FnEmitter, dst: *const sema.Symbol, value: *ast.Expr) Error!void {
        try self.emitStrValue(value);
        try self.print("    movq %rax, -{d}(%rbp)\n", .{slotOffset(dst.slot)});
        try self.print("    movq %rdx, -{d}(%rbp)\n", .{slotOffset(dst.slot + 1)});
    }

    /// `print(s)`: uma syscall `write(1, ptr, len)` para o texto e outra para a
    /// quebra de linha. `syscall` não exige alinhamento de pilha e clobbera
    /// `%rcx`/`%r11`, que não guardam estado entre expressões neste backend.
    fn emitPrint(self: *FnEmitter, call: ast.Expr.Call) Error!void {
        if (call.args.len != 1) return error.MiscompiledAst;
        const arg = call.args[0];

        // `emitStrValue` deixa ponteiro em `%rax` e tamanho em `%rdx`; `write`
        // espera ponteiro em `%rsi` e tamanho em `%rdx`.
        try self.emitStrValue(arg);
        try self.print("    movq %rax, %rsi\n", .{});

        try self.print("    movl $1, %eax\n", .{}); // syscall write
        try self.print("    movl $1, %edi\n", .{}); // fd = stdout
        try self.print("    syscall\n", .{});
        try self.print("    leaq .Lnl(%rip), %rsi\n", .{});
        try self.print("    movq $1, %rdx\n", .{});
        try self.print("    movl $1, %eax\n", .{});
        try self.print("    movl $1, %edi\n", .{});
        try self.print("    syscall\n", .{});
        self.state.used_print = true;
    }

    /// `print_i32(n)`: avalia o argumento em `%eax`, passa em `%edi` (SysV) e
    /// chama a rotina compartilhada `kyn_print_i32`.
    fn emitPrintI32(self: *FnEmitter, call: ast.Expr.Call) Error!void {
        if (call.args.len != 1) return error.MiscompiledAst;
        try self.emitExpr(call.args[0]);
        try self.print("    movl %eax, %edi\n", .{});
        try self.print("    call kyn_print_i32\n", .{});
        self.state.used_print_i32 = true;
    }

    fn emitBinaryOp(self: *FnEmitter, binary: ast.Expr.Binary) Error!void {
        try self.emitExpr(binary.lhs);
        try self.print("    pushq %rax\n", .{});
        try self.emitExpr(binary.rhs);
        try self.print("    movl %eax, %ecx\n", .{});
        try self.print("    popq %rax\n", .{});

        switch (binary.op) {
            .add => try self.print("    addl %ecx, %eax\n", .{}),
            .sub => try self.print("    subl %ecx, %eax\n", .{}),
            .mul => try self.print("    imull %ecx, %eax\n", .{}),
            .div => {
                try self.print("    cltd\n", .{});
                try self.print("    idivl %ecx\n", .{});
            },
            .mod => {
                try self.print("    cltd\n", .{});
                try self.print("    idivl %ecx\n", .{});
                try self.print("    movl %edx, %eax\n", .{});
            },
            .lt, .le, .gt, .ge, .eq, .ne => {
                try self.print("    cmpl %ecx, %eax\n", .{});
                const setcc: []const u8 = switch (binary.op) {
                    .lt => "setl",
                    .le => "setle",
                    .gt => "setg",
                    .ge => "setge",
                    .eq => "sete",
                    .ne => "setne",
                    else => unreachable,
                };
                try self.print("    {s} %al\n", .{setcc});
                try self.print("    movzbl %al, %eax\n", .{});
            },
            .and_op, .or_op => unreachable,
        }
    }

    /// Curto-circuito: `&&` só avalia o lado direito se o esquerdo for verdadeiro.
    fn emitLogical(self: *FnEmitter, binary: ast.Expr.Binary) Error!void {
        const is_and = binary.op == .and_op; // false => or
        const short_label = try self.label(if (is_and) "and_false" else "or_true");
        const end_label = try self.label(if (is_and) "and_end" else "or_end");

        try self.emitExpr(binary.lhs);
        try self.print("    cmpl $0, %eax\n", .{});
        if (is_and) {
            try self.print("    je {s}\n", .{short_label});
        } else {
            try self.print("    jne {s}\n", .{short_label});
        }

        try self.emitExpr(binary.rhs);
        try self.print("    cmpl $0, %eax\n", .{});
        if (is_and) {
            try self.print("    je {s}\n", .{short_label});
        } else {
            try self.print("    jne {s}\n", .{short_label});
        }

        try self.print("    movl ${d}, %eax\n", .{@as(u8, if (is_and) 1 else 0)});
        try self.print("    jmp {s}\n", .{end_label});
        try self.print("{s}:\n", .{short_label});
        try self.print("    movl ${d}, %eax\n", .{@as(u8, if (is_and) 0 else 1)});
        try self.print("{s}:\n", .{end_label});
    }

    fn emitCall(self: *FnEmitter, call: ast.Expr.Call) Error!void {
        if (call.builtin) |builtin| switch (builtin) {
            .print => return self.emitPrint(call),
            .print_i32 => return self.emitPrintI32(call),
        };

        const callee_index = call.callee_fn orelse return error.MiscompiledAst;
        const callee = self.checked.functions[callee_index];
        if (call.args.len != callee.params.len) return error.MiscompiledAst;

        // Cada argumento ocupa 1 registrador, 2 quando é `str` (ponteiro e
        // tamanho, nesta ordem) e um por campo quando é struct. A semântica já
        // validou o total.
        var words: usize = 0;
        for (callee.params, 0..) |ptype, i| {
            const struct_id = if (i < callee.param_struct_ids.len) callee.param_struct_ids[i] else 0;
            words += self.registerWordsOf(ptype, struct_id);
        }
        if (words > arg_registers.len) return error.UnsupportedNode;

        // Caminho rápido: com um único argumento nada pode clobberar os
        // registradores de destino, então movemos direto sem passar pela pilha.
        if (call.args.len == 1 and callee.params[0] != .aggregate) {
            if (callee.params[0] == .str) {
                try self.emitStrValue(call.args[0]);
                try self.print("    movq %rax, {s}\n", .{arg_registers_64[0]});
                try self.print("    movq %rdx, {s}\n", .{arg_registers_64[1]});
            } else {
                try self.emitExpr(call.args[0]);
                try self.print("    movl %eax, {s}\n", .{arg_registers[0]});
            }
            try self.print("    call kyn_{s}\n", .{call.callee});
            return;
        }

        for (call.args, callee.params, 0..) |arg, ptype, arg_index| {
            if (ptype == .aggregate) {
                const struct_id = if (arg_index < callee.param_struct_ids.len)
                    callee.param_struct_ids[arg_index]
                else
                    0;
                try self.emitStructArgsPush(struct_id, arg);
            } else if (ptype == .str) {
                try self.emitStrValue(arg);
                try self.print("    pushq %rax\n", .{});
                try self.print("    pushq %rdx\n", .{});
            } else {
                try self.emitExpr(arg);
                try self.print("    pushq %rax\n", .{});
            }
        }

        // Desempilha na ordem inversa: a última palavra empilhada volta para o
        // registrador de maior índice, preservando a ordem dos argumentos.
        var word: usize = words;
        while (word > 0) {
            word -= 1;
            try self.print("    popq %rax\n", .{});
            try self.print("    movq %rax, {s}\n", .{arg_registers_64[word]});
        }

        // A pilha volta ao alinhamento de 16 bytes antes da chamada,
        // pois todos os argumentos foram empilhados e desempilhados.
        try self.print("    call kyn_{s}\n", .{call.callee});
    }
};

// ---------------------------------------------------------------------------
// Testes estruturais do assembly emitido
// ---------------------------------------------------------------------------

const testing = std.testing;
const support = @import("test_support.zig");

fn emitFixture(f: *support.Fixture) ![]const u8 {
    return emit(f.allocator(), f.program, &f.checked);
}

test "x86_64: entrypoint chama kyn_main e usa syscall exit" {
    var f = try support.Fixture.build("fn main() -> i32 { return 42; }");
    defer f.deinit();
    const asm_text = try emitFixture(&f);
    try support.expectContains(asm_text, ".globl _start");
    try support.expectContains(asm_text, "call kyn_main");
    try support.expectContains(asm_text, "movl $42, %eax");
    try support.expectContains(asm_text, "movl %eax, %edi");
    try support.expectContains(asm_text, "movl $60, %eax");
    try support.expectContains(asm_text, "syscall");
}

test "x86_64: main void encerra com código zero" {
    var f = try support.Fixture.build("fn main() -> void { return; }");
    defer f.deinit();
    const asm_text = try emitFixture(&f);
    try support.expectContains(asm_text, "xorl %edi, %edi");
}

test "x86_64: prólogo, frame e epílogo" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    var a: i32 = 1;
        \\    var b: i32 = 2;
        \\    a = a + b;
        \\    return a;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);
    try support.expectContains(asm_text, "pushq %rbp");
    try support.expectContains(asm_text, "movq %rsp, %rbp");
    try support.expectContains(asm_text, "subq $16, %rsp"); // 2 slots -> 16 bytes
    try support.expectContains(asm_text, "addl %ecx, %eax");
    try support.expectContains(asm_text, "popq %rbp");
    try support.expectContains(asm_text, "ret");
}

test "x86_64: divisão e módulo usam idivl" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    let q: i32 = 7 / 2;
        \\    return q % 3;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);
    try support.expectContains(asm_text, "cltd");
    try support.expectContains(asm_text, "idivl %ecx");
    try support.expectContains(asm_text, "movl %edx, %eax");
}

test "x86_64: comparações usam setcc" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    if 1 < 2 { return 1; }
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);
    try support.expectContains(asm_text, "cmpl %ecx, %eax");
    try support.expectContains(asm_text, "setl %al");
    try support.expectContains(asm_text, "movzbl %al, %eax");
}

test "x86_64: if/else e while usam rótulos" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    var i: i32 = 0;
        \\    while i < 2 {
        \\        if i == 1 { i = i + 1; } else { i = i + 2; }
        \\    }
        \\    return i;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);
    try support.expectContains(asm_text, ".Lmain_while_cond_");
    try support.expectContains(asm_text, ".Lmain_while_end_");
    try support.expectContains(asm_text, ".Lmain_else_");
    try support.expectContains(asm_text, ".Lmain_endif_");
}

test "x86_64: chamada passa argumentos em registradores SysV" {
    var f = try support.Fixture.build(
        \\fn sub(a: i32, b: i32) -> i32 { return a - b; }
        \\fn main() -> i32 { return sub(10, 4); }
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);
    // Com dois argumentos os valores passam pela pilha para preservar a ordem
    // de avaliação; a volta é na ordem inversa (%rsi antes de %rdi).
    try support.expectContains(asm_text, "movl $10, %eax\n    pushq %rax");
    try support.expectContains(asm_text, "movl $4, %eax\n    pushq %rax");
    try support.expectContains(asm_text, "popq %rax\n    movq %rax, %rsi\n    popq %rax\n    movq %rax, %rdi");
    try support.expectContains(asm_text, "call kyn_sub");
}

test "x86_64: limite de argumentos da semântica coincide com a tabela SysV" {
    // A semântica valida `str` como duas palavras; a tabela precisa ter o mesmo
    // tamanho, senão o diagnóstico e o backend divergem silenciosamente.
    try testing.expectEqual(sema.max_arg_registers, arg_registers.len);
    try testing.expectEqual(sema.max_arg_registers, arg_registers_64.len);
}

test "x86_64: struct por valor chega um campo por registrador" {
    var f = try support.Fixture.build(
        \\struct P { x: i32, y: i32 }
        \\fn eco(p: P) -> P { return p; }
        \\fn main() -> i32 { return 0; }
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);

    // Slots 1 e 2 do struct (slot 0 é a base interna) recebem %edi e %esi.
    try support.expectContains(asm_text, "movl %edi, -16(%rbp)");
    try support.expectContains(asm_text, "movl %esi, -24(%rbp)");
    // `return p` devolve campo a campo em %eax e %edx.
    try support.expectContains(asm_text, "movl -16(%rbp), %eax");
    try support.expectContains(asm_text, "movl -24(%rbp), %edx");
}

test "x86_64: chamada com struct empilha um campo por vez" {
    var f = try support.Fixture.build(
        \\struct P { x: i32, y: i32 }
        \\fn soma(p: P) -> i32 { return p.x + p.y; }
        \\fn main() -> i32 {
        \\    let a: P = P { x: 1, y: 2 };
        \\    return soma(a);
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);

    try support.expectContains(asm_text, "movl -16(%rbp), %eax\n    pushq %rax\n    movl -24(%rbp), %eax\n    pushq %rax");
    try support.expectContains(asm_text, "popq %rax\n    movq %rax, %rsi\n    popq %rax\n    movq %rax, %rdi\n    call kyn_soma");
}

test "x86_64: let de chamada que devolve struct grava os campos" {
    var f = try support.Fixture.build(
        \\struct P { x: i32, y: i32 }
        \\fn eco(p: P) -> P { return p; }
        \\fn main() -> i32 {
        \\    let b = eco(P { x: 7, y: 9 });
        \\    return b.x;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);

    try support.expectContains(asm_text, "call kyn_eco");
    try support.expectContains(asm_text, "movl %eax, -16(%rbp)");
    try support.expectContains(asm_text, "movl %edx, -24(%rbp)");
}

test "x86_64: struct aninhado em expressão usa a pilha na ordem certa" {
    var f = try support.Fixture.build(
        \\struct P { x: i32, y: i32 }
        \\fn eco(p: P) -> P { return p; }
        \\fn soma(p: P) -> i32 { return p.x + p.y; }
        \\fn main() -> i32 { return soma(eco(P { x: 3, y: 4 })); }
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);

    // O struct devolvido por `eco` é empilhado campo a campo (%rax/%rdx).
    try support.expectContains(asm_text, "call kyn_eco");
    try support.expectContains(asm_text, "pushq %rax\n    pushq %rdx");
    try support.expectContains(asm_text, "call kyn_soma");
}

test "x86_64: parâmetro 'str' chega em %rdi/%rsi e é salvo em dois slots" {
    var f = try support.Fixture.build(
        \\fn eco(s: str) -> str { return s; }
        \\fn main() -> i32 { return 0; }
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);

    try support.expectContains(asm_text, "movq %rdi, -8(%rbp)");
    try support.expectContains(asm_text, "movq %rsi, -16(%rbp)");
    // `return s` devolve ponteiro em %rax e tamanho em %rdx.
    try support.expectContains(asm_text, "movq -8(%rbp), %rax");
    try support.expectContains(asm_text, "movq -16(%rbp), %rdx");
    try support.expectContains(asm_text, "subq $16, %rsp");
}

test "x86_64: chamada com 'str' empilha duas palavras por argumento" {
    var f = try support.Fixture.build(
        \\fn par(a: str, b: str) -> i32 {
        \\    print(a);
        \\    return 0;
        \\}
        \\fn main() -> i32 { return par("a", "b"); }
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);

    try support.expectContains(asm_text, "pushq %rax\n    pushq %rdx");
    // Ponteiro/tamanho chegam em %rdi/%rsi e %rdx/%rcx; desempilhamento é inverso.
    try support.expectContains(asm_text, "movq %rax, %rcx");
    try support.expectContains(asm_text, "movq %rax, %rdx");
    try support.expectContains(asm_text, "movq %rax, %rsi");
    try support.expectContains(asm_text, "movq %rax, %rdi");
    try support.expectContains(asm_text, "call kyn_par");
}

test "x86_64: chamada de um argumento não passa pela pilha" {
    var f = try support.Fixture.build(
        \\fn eco(s: str) -> str { return s; }
        \\fn dobro(n: i32) -> i32 { return n + n; }
        \\fn main() -> i32 { print(eco("kyn")); return dobro(2); }
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);

    try support.expectContains(asm_text, "movq %rax, %rdi\n    movq %rdx, %rsi\n    call kyn_eco");
    try support.expectContains(asm_text, "movl %eax, %edi\n    call kyn_dobro");
}

test "x86_64: and/or têm curto-circuito" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    let b: bool = 1 < 2 && 2 < 3;
        \\    if b { return 1; }
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);
    try support.expectContains(asm_text, ".Lmain_and_false_");
    try support.expectContains(asm_text, ".Lmain_and_end_");
}

test "x86_64: struct grava campos em slots consecutivos" {
    var f = try support.Fixture.build(
        \\struct Ponto { x: i32, y: i32 }
        \\fn main() -> i32 {
        \\    var p: Ponto = Ponto { x: 3, y: 4 };
        \\    p.x = p.x + p.y;
        \\    return p.x;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);

    // p ocupa o slot 0 (base) e os campos os slots 1 e 2 => offsets -16 e -24.
    try support.expectContains(asm_text, "movl %eax, -16(%rbp)");
    try support.expectContains(asm_text, "movl %eax, -24(%rbp)");
    try support.expectContains(asm_text, "movl -16(%rbp), %eax");
    try support.expectContains(asm_text, "movl -24(%rbp), %eax");
    // frame: 3 slots de 8 bytes arredondados para 16 => 32 bytes.
    try support.expectContains(asm_text, "subq $32, %rsp");
}

test "x86_64: atribuição de struct copia campo a campo" {
    var f = try support.Fixture.build(
        \\struct P { v: i32, w: bool }
        \\fn main() -> i32 {
        \\    var a: P = P { v: 1, w: false };
        \\    var b: P = a;
        \\    b.w = true;
        \\    if b.w { return b.v; }
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);
    // a: slots 1,2 ; b: slots 4,5 ; cópia lê de a e grava em b.
    try support.expectContains(asm_text, "movl -16(%rbp), %eax");
    try support.expectContains(asm_text, "movl %eax, -40(%rbp)");
}

/// Valor inicial de um campo dentro de um literal de struct, por nome.
fn findFieldInit(inits: []ast.Expr.FieldInit, name: []const u8) ?*ast.Expr {
    for (inits) |init| {
        if (std.mem.eql(u8, init.name, name)) return init.value;
    }
    return null;
}

test "x86_64: print emite write do texto e da quebra de linha" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    print("ok");
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);

    try support.expectContains(asm_text, "leaq .Lstr0(%rip), %rax");
    try support.expectContains(asm_text, "movq $2, %rdx");
    try support.expectContains(asm_text, "movq %rax, %rsi");
    try support.expectContains(asm_text, "movl $1, %eax");
    try support.expectContains(asm_text, "movl $1, %edi");
    try support.expectContains(asm_text, "syscall");
    // Texto e quebra de linha em .rodata, como listas de bytes.
    try support.expectContains(asm_text, ".section .rodata");
    try support.expectContains(asm_text, ".Lstr0:\n    .byte 111, 107");
    try support.expectContains(asm_text, ".Lnl:\n    .byte 10");
}

test "x86_64: variável str ocupa dois slots (ponteiro e tamanho)" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    var s: str = "abc";
        \\    print(s);
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);

    // slot 0 guarda o ponteiro (-8) e o slot 1 o tamanho (-16).
    try support.expectContains(asm_text, "movq %rax, -8(%rbp)");
    try support.expectContains(asm_text, "movq $3, %rdx");
    try support.expectContains(asm_text, "movq %rdx, -16(%rbp)");
    try support.expectContains(asm_text, "movq -8(%rbp), %rax");
    try support.expectContains(asm_text, "movq -16(%rbp), %rdx");
    try support.expectContains(asm_text, "movq %rax, %rsi");
    try support.expectContains(asm_text, "subq $16, %rsp");
}

test "x86_64: literais de string repetidos compartilham o rótulo" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    print("ok");
        \\    print("ok");
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, asm_text, ".Lstr0:"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, asm_text, "leaq .Lstr0(%rip), %rax"));
    try testing.expect(std.mem.indexOf(u8, asm_text, ".Lstr1:") == null);
}

test "x86_64: string vazia mantém o rótulo válido e escreve zero bytes" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    print("");
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);

    try support.expectContains(asm_text, ".Lstr0:\n    .zero 1");
    try support.expectContains(asm_text, "movq $0, %rdx");
}

test "x86_64: print_i32 chama a rotina decimal em .text" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    print_i32(42);
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);

    try support.expectContains(asm_text, "movl %eax, %edi");
    try support.expectContains(asm_text, "call kyn_print_i32");
    try support.expectContains(asm_text, ".type kyn_print_i32, @function");
    // Conversão: divisão unsigned por 10 e sinal com '-'.
    try support.expectContains(asm_text, "divl %r9d");
    try support.expectContains(asm_text, "movb $45, (%rsi)");
    try support.expectContains(asm_text, ".Lnl:\n    .byte 10");
    // O código fica em .text, antes dos dados: nunca dentro de .rodata.
    const helper_at = std.mem.indexOf(u8, asm_text, ".type kyn_print_i32").?;
    const rodata_at = std.mem.indexOf(u8, asm_text, ".section .rodata").?;
    try testing.expect(helper_at < rodata_at);
}

test "x86_64: rotina decimal é emitida uma única vez" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    print_i32(1);
        \\    print_i32(2);
        \\    print_i32(3);
        \\    return 0;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, asm_text, ".type kyn_print_i32"));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, asm_text, "call kyn_print_i32"));
}

test "x86_64: programa sem print_i32 não emite a rotina decimal" {
    var f = try support.Fixture.build(
        \\fn main() -> i32 {
        \\    print("ok");
        \\    return 1;
        \\}
    );
    defer f.deinit();
    const asm_text = try emitFixture(&f);
    try testing.expect(std.mem.indexOf(u8, asm_text, "kyn_print_i32") == null);
}
