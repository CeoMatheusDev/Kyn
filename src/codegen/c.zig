//! src/codegen/c.zig — Backend que traduz a AST verificada para C99.
//!
//! O backend C é o caminho de compilação verificável do Kyn hoje: ele produz
//! um arquivo `.c` autocontido que qualquer compilador C moderno constrói.
//! Decisões de mapeamento:
//!
//! * tipos primitivos viram os equivalentes de `<stdint.h>` (`i32` → `int32_t`);
//! * `str` vira `const char*` imutável, `char` vira `char`;
//! * nomes de tipos ganham o prefixo `Kyn` e símbolos de função ganham `kyn_`,
//!   evitando colisão com palavras reservadas do C;
//! * métodos de `impl` viram funções `KynTipo_metodo` com receiver explícito;
//! * `print`/`println` viram `printf` com formato escolhido pelo tipo estático;
//! * `#[align(N)]` vira `__attribute__((aligned(N)))` quando o compilador C
//!   suportar, e é ignorado caso contrário.
//!
//! Nenhuma análise de tipo acontece aqui: o backend confia nos `type_id`
//! preenchidos pela análise semântica.

const std = @import("std");
const ast = @import("../ast/ast.zig");
const diag = @import("../diag.zig");
const sema = @import("../sema/sema.zig");
const types = @import("../sema/types.zig");

pub const Error = error{ CodegenFailed } || std.mem.Allocator.Error;

pub const Codegen = struct {
    alloc: std.mem.Allocator,
    sema: *sema.Sema,
    out: std.ArrayList(u8) = .empty,

    pub fn init(alloc: std.mem.Allocator, analyzer: *sema.Sema) Codegen {
        return .{ .alloc = alloc, .sema = analyzer };
    }

    pub fn emit(self: *Codegen, program: ast.Program) Error![]const u8 {
        try self.emitHeader();
        try self.emitEnums();
        try self.emitStructs();
        try self.emitExternDecls(program);
        try self.emitForwardDecls();
        try self.emitFunctions(program);
        try self.emitMainWrapper();
        return self.out.items;
    }

    // ------------------------------------------------------------------ saída

    fn write(self: *Codegen, comptime fmt: []const u8, args: anytype) Error!void {
        const text = try std.fmt.allocPrint(self.alloc, fmt, args);
        try self.out.appendSlice(self.alloc, text);
    }

    fn writeRaw(self: *Codegen, text: []const u8) Error!void {
        try self.out.appendSlice(self.alloc, text);
    }

    fn indent(self: *Codegen, level: usize) Error!void {
        for (0..level) |_| try self.out.append(self.alloc, ' ');
    }

    // ----------------------------------------------------------------- prólogo

    fn emitHeader(self: *Codegen) Error!void {
        try self.writeRaw(
            \\/* Gerado pelo compilador Kyn. Não editar manualmente. */
            \\#include <stdint.h>
            \\#include <stdbool.h>
            \\#include <stddef.h>
            \\#include <stdio.h>
            \\
            \\#if defined(__GNUC__) || defined(__clang__)
            \\#define KYN_ALIGN(n) __attribute__((aligned(n)))
            \\#else
            \\#define KYN_ALIGN(n)
            \\#endif
            \\
            \\typedef int8_t kyn_i8;
            \\typedef int16_t kyn_i16;
            \\typedef int32_t kyn_i32;
            \\typedef int64_t kyn_i64;
            \\typedef intptr_t kyn_isize;
            \\typedef uint8_t kyn_u8;
            \\typedef uint16_t kyn_u16;
            \\typedef uint32_t kyn_u32;
            \\typedef uint64_t kyn_u64;
            \\typedef uintptr_t kyn_usize;
            \\typedef float kyn_f32;
            \\typedef double kyn_f64;
            \\typedef bool kyn_bool;
            \\typedef char kyn_char;
            \\typedef const char *kyn_str;
            \\
        );
    }

    fn emitEnums(self: *Codegen) Error!void {
        for (self.sema.enum_order.items) |info| {
            try self.write("typedef enum {{\n", .{});
            for (info.variants, 0..) |variant, i| {
                try self.write("    Kyn{s}_{s}{s}\n", .{ info.name, variant, if (i + 1 < info.variants.len) "," else "" });
            }
            try self.write("}} Kyn{s};\n\n", .{info.name});
        }
    }

    fn emitStructs(self: *Codegen) Error!void {
        for (self.sema.struct_order.items) |info| {
            try self.write("typedef struct Kyn{s} Kyn{s};\n", .{ info.name, info.name });
        }
        if (self.sema.struct_order.items.len > 0) try self.writeRaw("\n");
        for (self.sema.struct_order.items) |info| {
            if (info.alignment) |alignment| {
                try self.write("struct KYN_ALIGN({d}) Kyn{s} {{\n", .{ alignment, info.name });
            } else {
                try self.write("struct Kyn{s} {{\n", .{info.name});
            }
            if (info.fields.len == 0) {
                try self.writeRaw("    char kyn_placeholder;\n");
            }
            for (info.fields) |field| {
                try self.write("    {s} kyn_{s};\n", .{ try self.cType(field.type_id), field.name });
            }
            try self.write("}};\n\n", .{});
        }
    }

    fn emitExternDecls(self: *Codegen, program: ast.Program) Error!void {
        var any = false;
        for (program.decls) |decl| {
            const extern_fn = switch (decl) {
                .extern_func => |f| f,
                else => continue,
            };
            var params: std.ArrayList(u8) = .empty;
            for (extern_fn.params) |param| {
                if (params.items.len > 0) try params.appendSlice(self.alloc, ", ");
                try diag.appendf(&params, self.alloc, "{s} kyn_{s}", .{
                    try self.cType(try self.sema.resolveType(param.ty)),
                    param.name,
                });
            }
            if (extern_fn.is_variadic) {
                if (params.items.len > 0) try params.appendSlice(self.alloc, ", ");
                try params.appendSlice(self.alloc, "...");
            }
            if (params.items.len == 0) try params.appendSlice(self.alloc, "void");
            try self.write("extern {s} {s}({s});\n", .{
                if (extern_fn.ret) |ret| try self.cType(try self.sema.resolveType(ret)) else "void",
                extern_fn.name,
                params.items,
            });
            any = true;
        }
        if (any) try self.writeRaw("\n");
    }

    fn emitForwardDecls(self: *Codegen) Error!void {
        for (self.sema.func_order.items) |func| {
            if (func.is_extern or func.body == null) continue;
            try self.write("static {s} {s}({s});\n", .{
                try self.cType(func.ret),
                try self.symbolOf(func),
                try self.paramList(func),
            });
        }
        try self.writeRaw("\n");
    }

    fn symbolOf(self: *Codegen, func: *sema.FuncInfo) Error![]const u8 {
        if (func.owner) |owner| {
            return std.fmt.allocPrint(self.alloc, "Kyn{s}_{s}", .{ owner, func.name });
        }
        return std.fmt.allocPrint(self.alloc, "kyn_{s}", .{func.name});
    }

    fn paramList(self: *Codegen, func: *sema.FuncInfo) Error![]const u8 {
        var params: std.ArrayList(u8) = .empty;
        if (func.has_self) {
            const owner = func.owner.?;
            const owner_info = self.sema.structs.get(owner).?;
            try diag.appendf(&params, self.alloc, "{s}{s} *kyn_self", .{
                if (func.self_mutable) "" else "const ",
                try self.cType(owner_info.type_id),
            });
        }
        for (func.params) |param| {
            if (params.items.len > 0) try params.appendSlice(self.alloc, ", ");
            try diag.appendf(&params, self.alloc, "{s} kyn_{s}", .{ try self.cType(param.type_id), param.name });
        }
        if (params.items.len == 0) return "void";
        return params.items;
    }

    fn emitFunctions(self: *Codegen, program: ast.Program) Error!void {
        for (program.decls) |decl| {
            switch (decl) {
                .func => |func| try self.emitFunc(func, null),
                .impl => |impl| {
                    for (impl.methods) |method| try self.emitFunc(method, impl.target);
                },
                else => {},
            }
        }
    }

    fn emitFunc(self: *Codegen, decl: ast.Func, owner: ?[]const u8) Error!void {
        const key = if (owner) |o|
            try std.fmt.allocPrint(self.alloc, "{s}::{s}", .{ o, decl.name })
        else
            decl.name;
        const info = if (owner != null) self.sema.methods.get(key) else self.sema.funcs.get(key);
        const func = info orelse return;

        try self.write("static {s} {s}({s}) {{\n", .{
            try self.cType(func.ret),
            try self.symbolOf(func),
            try self.paramList(func),
        });
        for (decl.body.stmts) |stmt| try self.emitStmt(stmt, 4);
        if (!self.sema.type_table.isVoid(func.ret) and !sema.alwaysReturns(decl.body)) {
            // Alcançável apenas quando a semântica já reportou E0016; o valor
            // mantém o C válido para inspeção manual.
            try self.writeRaw("    return 0;\n");
        }
        try self.writeRaw("}\n\n");
    }

    fn emitMainWrapper(self: *Codegen) Error!void {
        const main_func = self.sema.funcs.get("main") orelse return;
        if (main_func.is_extern or main_func.body == null) return;
        if (self.sema.type_table.isVoid(main_func.ret)) {
            try self.writeRaw("int main(void) {\n    kyn_main();\n    return 0;\n}\n");
        } else {
            try self.writeRaw("int main(void) {\n    return (int)kyn_main();\n}\n");
        }
    }

    // ------------------------------------------------------------- statements

    fn emitStmt(self: *Codegen, stmt: ast.Stmt, level: usize) Error!void {
        switch (stmt) {
            .binding => |binding| {
                const type_id = binding.init.type_id;
                try self.indent(level);
                try self.write("{s} kyn_{s} = ", .{ try self.cType(type_id), binding.name });
                try self.emitExpr(binding.init);
                try self.writeRaw(";\n");
            },
            .assign => |assign| {
                const op_text = switch (assign.op) {
                    .assign => "=",
                    .add => "+=",
                    .sub => "-=",
                    .mul => "*=",
                    .div => "/=",
                    .rem => "%=",
                };
                try self.indent(level);
                try self.emitExpr(assign.target);
                try self.write(" {s} ", .{op_text});
                try self.emitExpr(assign.value);
                try self.writeRaw(";\n");
            },
            .expr => |expr| {
                try self.indent(level);
                try self.emitExpr(expr);
                try self.writeRaw(";\n");
            },
            .ret => |ret| {
                try self.indent(level);
                if (ret.value) |value| {
                    try self.writeRaw("return ");
                    try self.emitExpr(value);
                    try self.writeRaw(";\n");
                } else {
                    try self.writeRaw("return;\n");
                }
            },
            .cond => |cond| try self.emitIf(cond, level),
            .loop => |loop| {
                try self.indent(level);
                try self.writeRaw("while (");
                try self.emitExpr(loop.cond);
                try self.writeRaw(") {\n");
                for (loop.body.stmts) |inner| try self.emitStmt(inner, level + 4);
                try self.indent(level);
                try self.writeRaw("}\n");
            },
            .range_for => |range| {
                const ty = try self.cType(range.start.type_id);
                try self.indent(level);
                try self.write("for ({s} kyn_{s} = ", .{ ty, range.var_name });
                try self.emitExpr(range.start);
                try self.write("; kyn_{s} < ", .{range.var_name});
                try self.emitExpr(range.end);
                try self.write("; kyn_{s} += 1) {{\n", .{range.var_name});
                for (range.body.stmts) |inner| try self.emitStmt(inner, level + 4);
                try self.indent(level);
                try self.writeRaw("}\n");
            },
            .break_ => {
                try self.indent(level);
                try self.writeRaw("break;\n");
            },
            .continue_ => {
                try self.indent(level);
                try self.writeRaw("continue;\n");
            },
            .block => |block| {
                try self.indent(level);
                try self.writeRaw("{\n");
                for (block.stmts) |inner| try self.emitStmt(inner, level + 4);
                try self.indent(level);
                try self.writeRaw("}\n");
            },
            .unsafe_block => |block| {
                try self.indent(level);
                try self.writeRaw("{ /* unsafe */\n");
                for (block.stmts) |inner| try self.emitStmt(inner, level + 4);
                try self.indent(level);
                try self.writeRaw("}\n");
            },
        }
    }

    fn emitIf(self: *Codegen, cond: ast.If, level: usize) Error!void {
        try self.indent(level);
        try self.writeRaw("if (");
        try self.emitExpr(cond.cond);
        try self.writeRaw(") {\n");
        for (cond.then.stmts) |stmt| try self.emitStmt(stmt, level + 4);
        if (cond.els) |els| {
            switch (els) {
                .block => |block| {
                    try self.indent(level);
                    try self.writeRaw("} else {\n");
                    for (block.stmts) |stmt| try self.emitStmt(stmt, level + 4);
                    try self.indent(level);
                    try self.writeRaw("}\n");
                },
                .cond => |nested| {
                    try self.indent(level);
                    try self.writeRaw("} else ");
                    // `else if` sem bloco extra: reutiliza o nível atual.
                    try self.writeRaw("");
                    try self.emitIfInline(nested.*, level);
                },
            }
            return;
        }
        try self.indent(level);
        try self.writeRaw("}\n");
    }

    fn emitIfInline(self: *Codegen, cond: ast.If, level: usize) Error!void {
        try self.writeRaw("if (");
        try self.emitExpr(cond.cond);
        try self.writeRaw(") {\n");
        for (cond.then.stmts) |stmt| try self.emitStmt(stmt, level + 4);
        if (cond.els) |els| {
            switch (els) {
                .block => |block| {
                    try self.indent(level);
                    try self.writeRaw("} else {\n");
                    for (block.stmts) |stmt| try self.emitStmt(stmt, level + 4);
                    try self.indent(level);
                    try self.writeRaw("}\n");
                },
                .cond => |nested| {
                    try self.indent(level);
                    try self.writeRaw("} else ");
                    try self.emitIfInline(nested.*, level);
                },
            }
            return;
        }
        try self.indent(level);
        try self.writeRaw("}\n");
    }

    // ------------------------------------------------------------ expressões

    fn emitExpr(self: *Codegen, expr: ast.Expr) Error!void {
        switch (expr.kind) {
            .int_lit => |value| try self.emitInt(value, expr.type_id),
            .float_lit => |value| try self.emitFloat(value),
            .string_lit => |value| {
                try self.writeRaw("\"");
                try self.emitEscaped(value);
                try self.writeRaw("\"");
            },
            .char_lit => |value| {
                try self.writeRaw("'");
                try self.emitEscapedChar(value);
                try self.writeRaw("'");
            },
            .bool_lit => |value| try self.writeRaw(if (value) "true" else "false"),
            .ident => |name| try self.write("kyn_{s}", .{name}),
            .self_ => try self.writeRaw("kyn_self"),
            .binary => |binary| {
                try self.writeRaw("(");
                try self.emitExpr(binary.lhs.*);
                try self.write(" {s} ", .{cBinOp(binary.op)});
                try self.emitExpr(binary.rhs.*);
                try self.writeRaw(")");
            },
            .unary => |unary| {
                const op_text = switch (unary.op) {
                    .neg => "-",
                    .not => "!",
                    .bit_not => "~",
                };
                try self.write("({s}", .{op_text});
                try self.emitExpr(unary.operand.*);
                try self.writeRaw(")");
            },
            .call => |call| try self.emitCall(call),
            .field => |field| {
                const object_ty = field.object.type_id;
                const through_ptr = self.sema.type_table.refElem(object_ty) != null or
                    self.sema.type_table.isRawPtr(object_ty);
                try self.writeRaw("((");
                try self.emitExpr(field.object.*);
                if (through_ptr) {
                    try self.write(")->kyn_{s})", .{field.name});
                } else {
                    try self.write(").kyn_{s})", .{field.name});
                }
            },
            .path => |path| try self.write("Kyn{s}_{s}", .{ path.head, path.tail }),
            .struct_lit => |literal| {
                try self.write("((Kyn{s}){{", .{literal.name});
                for (literal.inits, 0..) |field_init, i| {
                    try self.write("{s}.kyn_{s} = ", .{if (i > 0) ", " else "", field_init.name});
                    try self.emitExpr(field_init.value);
                }
                try self.writeRaw("})");
            },
            .enum_lit => |literal| try self.write("Kyn{s}_{s}", .{ literal.name, literal.variant }),
            .cast => |cast| {
                try self.write("(({s})(", .{try self.cType(expr.type_id)});
                try self.emitExpr(cast.operand.*);
                try self.writeRaw("))");
            },
            .ref_of => |ref_of| {
                try self.writeRaw("(&");
                try self.emitExpr(ref_of.operand.*);
                try self.writeRaw(")");
            },
            .deref => |operand| {
                try self.writeRaw("(*");
                try self.emitExpr(operand.*);
                try self.writeRaw(")");
            },
        }
    }

    fn emitCall(self: *Codegen, call: anytype) Error!void {
        switch (call.callee.kind) {
            .ident => |name| {
                if (std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "println")) {
                    try self.emitPrint(name, call);
                    return;
                }
                if (self.sema.funcs.get(name)) |func| {
                    try self.write("{s}(", .{if (func.is_extern) func.name else try self.symbolOf(func)});
                    try self.emitArgs(call.args);
                    try self.writeRaw(")");
                    return;
                }
                try self.write("kyn_{s}(", .{name});
                try self.emitArgs(call.args);
                try self.writeRaw(")");
            },
            .field => |field| {
                const owner_ty = self.sema.autoDeref(field.object.type_id);
                const owner_name = self.sema.nameOfType(owner_ty) orelse {
                    try self.writeRaw("0");
                    return;
                };
                const key = try std.fmt.allocPrint(self.alloc, "{s}::{s}", .{ owner_name, field.name });
                const method = self.sema.methods.get(key);
                if (method == null or !method.?.has_self) {
                    // Não é método: a semântica já reportou o problema.
                    try self.writeRaw("0");
                    return;
                }
                try self.write("{s}(", .{try self.symbolOf(method.?)});
                const needs_address = self.sema.type_table.refElem(field.object.type_id) == null;
                try self.write("{s}", .{if (needs_address) "&" else ""});
                try self.emitExpr(field.object.*);
                if (call.args.len > 0) try self.writeRaw(", ");
                try self.emitArgs(call.args);
                try self.writeRaw(")");
            },
            .path => |path| {
                const key = try std.fmt.allocPrint(self.alloc, "{s}::{s}", .{ path.head, path.tail });
                if (self.sema.methods.get(key)) |method| {
                    try self.write("{s}(", .{try self.symbolOf(method)});
                    try self.emitArgs(call.args);
                    try self.writeRaw(")");
                    return;
                }
                try self.write("Kyn{s}_{s}()", .{ path.head, path.tail });
            },
            else => try self.writeRaw("0"),
        }
    }

    fn emitArgs(self: *Codegen, args: []const *ast.Expr) Error!void {
        for (args, 0..) |arg, i| {
            if (i > 0) try self.writeRaw(", ");
            try self.emitExpr(arg.*);
        }
    }

    fn emitPrint(self: *Codegen, name: []const u8, call: anytype) Error!void {
        const newline = std.mem.eql(u8, name, "println");
        if (call.args.len == 0) {
            try self.writeRaw(if (newline) "printf(\"\\n\")" else "printf(\"\")");
            return;
        }
        const arg: ast.Expr = call.args[0].*;
        const ty = self.sema.type_table.get(arg.type_id);
        const format: []const u8 = if (newline) "\\n" else "";
        switch (ty) {
            .bool => {
                try self.writeRaw("printf(\"%s");
                try self.writeRaw(format);
                try self.writeRaw("\", ");
                try self.emitExpr(arg);
                try self.writeRaw(" ? \"true\" : \"false\")");
            },
            .char => {
                try self.writeRaw("printf(\"%c");
                try self.writeRaw(format);
                try self.writeRaw("\", ");
                try self.emitExpr(arg);
                try self.writeRaw(")");
            },
            .str => {
                try self.writeRaw("printf(\"%s");
                try self.writeRaw(format);
                try self.writeRaw("\", ");
                try self.emitExpr(arg);
                try self.writeRaw(")");
            },
            .float => {
                try self.writeRaw("printf(\"%f");
                try self.writeRaw(format);
                try self.writeRaw("\", (double)");
                try self.emitExpr(arg);
                try self.writeRaw(")");
            },
            .int => |info| {
                if (info.signed) {
                    try self.writeRaw("printf(\"%lld");
                    try self.writeRaw(format);
                    try self.writeRaw("\", (long long)");
                } else {
                    try self.writeRaw("printf(\"%llu");
                    try self.writeRaw(format);
                    try self.writeRaw("\", (unsigned long long)");
                }
                try self.emitExpr(arg);
                try self.writeRaw(")");
            },
            else => {
                try self.writeRaw("printf(\"?");
                try self.writeRaw(format);
                try self.writeRaw("\")");
            },
        }
    }

    fn emitInt(self: *Codegen, value: i128, type_id: types.Id) Error!void {
        const info = self.sema.type_table.intInfo(type_id);
        const suffix: []const u8 = if (info) |i| blk: {
            const bits = if (i.addr_width) 64 else i.bits;
            if (bits < 32) break :blk "";
            if (!i.signed and value > std.math.maxInt(i32)) break :blk if (bits == 64) "ULL" else "U";
            break :blk if (bits == 64) (if (i.signed) "LL" else "ULL") else "";
        } else "";
        if (suffix.len == 0) {
            try self.write("{d}", .{value});
            return;
        }
        try self.write("{d}{s}", .{ value, suffix });
    }

    fn emitFloat(self: *Codegen, value: f64) Error!void {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch {
            try self.writeRaw("0.0");
            return;
        };
        try self.writeRaw(text);
        if (std.mem.indexOfAny(u8, text, ".eE") == null) try self.writeRaw(".0");
    }

    fn emitEscaped(self: *Codegen, text: []const u8) Error!void {
        for (text) |ch| try self.emitEscapedChar(ch);
    }

    fn emitEscapedChar(self: *Codegen, ch: u8) Error!void {
        switch (ch) {
            '\n' => try self.writeRaw("\\n"),
            '\t' => try self.writeRaw("\\t"),
            '\r' => try self.writeRaw("\\r"),
            '\\' => try self.writeRaw("\\\\"),
            '"' => try self.writeRaw("\\\""),
            '\'' => try self.writeRaw("\\'"),
            else => {
                if (ch >= 32 and ch <= 126) {
                    const buf = [_]u8{ch};
                    try self.out.appendSlice(self.alloc, &buf);
                } else {
                    // Octal com três dígitos: nunca ambíguo com o byte seguinte.
                    try self.write("\\{d:0>3}", .{ch});
                }
            },
        }
    }

    // ----------------------------------------------------------- tipos em C

    pub fn cType(self: *Codegen, type_id: types.Id) Error![]const u8 {
        const ty = self.sema.type_table.get(type_id);
        return switch (ty) {
            .void => "void",
            .bool => "kyn_bool",
            .char => "kyn_char",
            .str => "kyn_str",
            .int => |info| blk: {
                if (info.addr_width) break :blk if (info.signed) "kyn_isize" else "kyn_usize";
                const base = if (info.signed) "kyn_i" else "kyn_u";
                break :blk try std.fmt.allocPrint(self.alloc, "{s}{d}", .{ base, info.bits });
            },
            .float => |bits| if (bits == 32) "kyn_f32" else "kyn_f64",
            .ptr => |ptr| {
                // Em C, `char *` é o ponteiro de bytes; mapear `*u8` para ele
                // mantém compatibilidade com cabeçalhos do sistema (FFI).
                if (self.sema.type_table.eql(ptr.elem, self.sema.type_table.u8_id)) {
                    return if (ptr.is_const) "const char *" else "char *";
                }
                return try std.fmt.allocPrint(self.alloc, "{s}{s} *", .{
                    if (ptr.is_const) "const " else "",
                    try self.cType(ptr.elem),
                });
            },
            .ref_ => |ref| try std.fmt.allocPrint(self.alloc, "{s} *", .{try self.cType(ref.elem)}),
            .named => |named| try std.fmt.allocPrint(self.alloc, "Kyn{s}", .{named.name}),
        };
    }
};

fn cBinOp(op: ast.BinOp) []const u8 {
    return switch (op) {
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

test "cBinOp maps every operator" {
    const all_ops = [_]ast.BinOp{
        .add, .sub,   .mul,    .div,   .rem,  .eq,    .ne,    .lt,    .le,
        .gt,  .ge,    .and_,   .or_,   .bit_and, .bit_or, .bit_xor, .shl, .shr,
    };
    for (all_ops) |op| {
        try std.testing.expect(cBinOp(op).len > 0);
    }
    try std.testing.expectEqualStrings("&&", cBinOp(.and_));
    try std.testing.expectEqualStrings("<<", cBinOp(.shl));
}
