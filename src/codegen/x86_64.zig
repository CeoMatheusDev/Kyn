//! Backend nativo x86-64 (Linux, System V AMD64), sem dependência de libc.
//!
//! Estratégia:
//! - cada variável (parâmetro ou local) recebe um slot de 8 bytes no frame;
//!   `i32`/`bool` ocupam 4 bytes no slot e são carregados em 32 bits;
//! - expressões são avaliadas em `%eax` com pilha de temporários;
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

pub fn emit(
    arena: std.mem.Allocator,
    program: *const ast.Program,
    checked: *const sema.Checked,
) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;

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
        var emitter = FnEmitter.init(arena, func, checked, checked.functions[i]);
        try emitter.emitFunction(&out);
        try out.append(arena, '\n');
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
    label_count: u32 = 0,
    /// Bloco corrente já terminou (return)? Evita emitir código inalcançável.
    terminated: bool = false,

    fn init(
        arena: std.mem.Allocator,
        func: *const ast.Function,
        checked: *const sema.Checked,
        info: sema.FunctionInfo,
    ) FnEmitter {
        return .{ .arena = arena, .func = func, .checked = checked, .info = info };
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

    fn emitFunction(self: *FnEmitter, out: *std.ArrayList(u8)) !void {
        self.out = out;

        if (self.func.params.len > arg_registers.len) return error.UnsupportedNode;

        const frame_bytes: u32 = std.mem.alignForward(u32, self.info.slot_count * 8, 16);

        try self.print(".type kyn_{s}, @function\n", .{self.func.name});
        try self.print("kyn_{s}:\n", .{self.func.name});
        try self.print("    pushq %rbp\n", .{});
        try self.print("    movq %rsp, %rbp\n", .{});
        if (frame_bytes > 0) {
            try self.print("    subq ${d}, %rsp\n", .{frame_bytes});
        }

        // Parâmetros: registradores -> slots.
        for (self.func.params, 0..) |_, i| {
            const sym = &self.checked.symbols[self.info.symbol_start + i];
            try self.print("    movl {s}, -{d}(%rbp)\n", .{ arg_registers[i], slotOffset(sym.slot) });
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
                try self.emitExpr(decl.init);
                try self.print("    movl %eax, -{d}(%rbp)\n", .{slotOffset(symbol.slot)});
            },

            .assign => |assign| {
                const symbol = self.symbolAt(assign.resolved orelse return error.MiscompiledAst);
                try self.emitExpr(assign.value);
                try self.print("    movl %eax, -{d}(%rbp)\n", .{slotOffset(symbol.slot)});
            },

            .return_stmt => |maybe_expr| {
                if (maybe_expr) |expr| {
                    try self.emitExpr(expr);
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

            .call => |call| try self.emitCall(call),
        }
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
        if (call.args.len > arg_registers.len) return error.UnsupportedNode;

        for (call.args) |arg| {
            try self.emitExpr(arg);
            try self.print("    pushq %rax\n", .{});
        }

        var i: usize = call.args.len;
        while (i > 0) {
            i -= 1;
            try self.print("    popq %rax\n", .{});
            try self.print("    movl %eax, {s}\n", .{arg_registers[i]});
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
    try support.expectContains(asm_text, "movl %eax, %edi");
    try support.expectContains(asm_text, "movl %eax, %esi");
    try support.expectContains(asm_text, "call kyn_sub");
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
