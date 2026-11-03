//! src/sema/sema.zig — Análise semântica e verificação de tipos do Kyn.
//!
//! Duas passadas sobre o programa:
//! 1. **Declarações** — registra `struct`, `enum`, `fn`, `extern fn`, métodos de
//!    `impl` e imports, resolvendo os tipos nomeados. Nessa fase o compilador
//!    já conhece todos os símbolos, então recursão e referências diretas
//!    funcionam em qualquer ordem.
//! 2. **Corpos** — verifica tipos, mutabilidade, escopo, contexto `unsafe`,
//!    uso de `break`/`continue`, chamadas e caminhos de retorno.
//!
//! Todo diagnóstico é acumulado em `diag.List`; a análise continua depois de
//! um erro para relatar o máximo de problemas em uma única execução.

const std = @import("std");
const ast = @import("../ast/ast.zig");
const diag = @import("../diag.zig");
const types = @import("types.zig");
const unsafe = @import("unsafe.zig");

/// Conjunto explícito de erros da verificação. É declarado (e não inferido)
/// porque `checkExpr` e `checkExprInner` são mutuamente recursivos.
pub const Error = std.mem.Allocator.Error;

pub const Options = struct {
    /// Emite `W0001` para bindings nunca lidos.
    warn_unused: bool = false,
    /// Exige `fn main` no módulo (compilação de executável).
    require_main: bool = true,
};

pub const FieldInfo = struct {
    name: []const u8,
    type_id: types.Id,
    index: usize,
    span: diag.Span,
};

pub const StructInfo = struct {
    name: []const u8,
    type_id: types.Id,
    fields: []const FieldInfo,
    decl: ast.StructDecl,
    alignment: ?u32,
    repr_c: bool,
};

pub const EnumInfo = struct {
    name: []const u8,
    type_id: types.Id,
    variants: []const []const u8,
    decl: ast.EnumDecl,
};

pub const ParamInfo = struct {
    name: []const u8,
    type_id: types.Id,
    span: diag.Span,
};

pub const FuncInfo = struct {
    name: []const u8,
    /// `null` para funções livres; nome do struct para métodos.
    owner: ?[]const u8,
    params: []const ParamInfo,
    ret: types.Id,
    is_extern: bool,
    is_variadic: bool,
    /// `self` implícito (`&T` ou `&mut T`).
    has_self: bool,
    self_mutable: bool,
    body: ?ast.Block,
    span: diag.Span,
};

const VarInfo = struct {
    name: []const u8,
    type_id: types.Id,
    mutable: bool,
    span: diag.Span,
    used: bool,
};

const Scope = struct {
    vars: std.ArrayList(VarInfo),
};

pub const Sema = struct {
    alloc: std.mem.Allocator,
    diags: *diag.List,
    opts: Options,
    type_table: types.Table,

    structs: std.StringHashMap(*StructInfo),
    enums: std.StringHashMap(*EnumInfo),
    funcs: std.StringHashMap(*FuncInfo),
    /// Chave `Struct::metodo`.
    methods: std.StringHashMap(*FuncInfo),
    /// Ordem de declaração, preservada para o backend.
    func_order: std.ArrayList(*FuncInfo),
    struct_order: std.ArrayList(*StructInfo),
    enum_order: std.ArrayList(*EnumInfo),

    scopes: std.ArrayList(Scope),
    unsafe_ctx: unsafe.Context = .{},
    loop_depth: u32 = 0,
    /// > 0 dentro de um braço de `match`: `break`/`continue` ali sairiam do
    /// `switch` gerado em C, não do laço, então são rejeitados.
    match_depth: u32 = 0,
    current_func: ?*FuncInfo = null,

    pub fn init(alloc: std.mem.Allocator, diags: *diag.List, opts: Options) !Sema {
        return .{
            .alloc = alloc,
            .diags = diags,
            .opts = opts,
            .type_table = try types.Table.init(alloc),
            .structs = std.StringHashMap(*StructInfo).init(alloc),
            .enums = std.StringHashMap(*EnumInfo).init(alloc),
            .funcs = std.StringHashMap(*FuncInfo).init(alloc),
            .methods = std.StringHashMap(*FuncInfo).init(alloc),
            .func_order = .empty,
            .struct_order = .empty,
            .enum_order = .empty,
            .scopes = .empty,
        };
    }

    // -------------------------------------------------------------- diagnóstico

    fn report(self: *Sema, code: diag.Code, message: []const u8, span: diag.Span) void {
        self.diags.add(self.alloc, .{
            .code = code,
            .message = message,
            .span = span,
        }) catch {};
    }

    fn reportHelp(self: *Sema, code: diag.Code, message: []const u8, span: diag.Span, help: ?[]const u8) void {
        self.diags.add(self.alloc, .{
            .code = code,
            .message = message,
            .span = span,
            .help = help,
        }) catch {};
    }

    fn typeName(self: *Sema, id: types.Id) []const u8 {
        return self.type_table.describePrefixed(self.alloc, id) catch "?";
    }

    // ------------------------------------------------------------------- driver

    pub fn analyze(self: *Sema, program: ast.Program) !void {
        try self.declareProgram(program);
        if (self.diags.hasErrors()) return;
        try self.checkProgram(program);
    }

    // ------------------------------------------------------------ fase 1: decls

    fn declareProgram(self: *Sema, program: ast.Program) !void {
        for (program.imports) |imp| {
            if (!knownModule(imp.path)) {
                self.reportHelp(
                    .unknown_module,
                    std.fmt.allocPrint(self.alloc, "módulo desconhecido `{s}`", .{imp.path}) catch "módulo desconhecido",
                    imp.span,
                    "módulos conhecidos: kyn::core, kyn::std, kyn::std::io, kyn::std::thread, kyn::std::net",
                );
            }
        }

        for (program.decls) |*decl| {
            switch (decl.*) {
                .structure => |*st| try self.declareStruct(st.*),
                .enumeration => |*en| try self.declareEnum(en.*),
                else => {},
            }
        }
        // Campos podem referenciar outros structs declarados depois.
        for (program.decls) |*decl| {
            switch (decl.*) {
                .structure => |*st| try self.resolveStructFields(st.*),
                else => {},
            }
        }

        for (program.decls) |*decl| {
            switch (decl.*) {
                .func => |*f| try self.declareFunc(f, null),
                .extern_func => |*f| try self.declareExternFunc(f.*),
                .impl => |*i| try self.declareImpl(i),
                else => {},
            }
        }
    }

    fn declareStruct(self: *Sema, decl: ast.StructDecl) !void {
        try unsafe.checkAttrs(self.alloc, self.diags, decl.attrs);
        if (self.structs.contains(decl.name) or self.enums.contains(decl.name)) {
            self.report(
                .duplicate_decl,
                std.fmt.allocPrint(self.alloc, "o tipo `{s}` já foi declarado", .{decl.name}) catch "declaração duplicada",
                decl.name_span,
            );
            return;
        }
        const type_id = try self.type_table.add(self.alloc, .{ .named = .{ .name = decl.name, .kind = .structure } });
        const info = try self.alloc.create(StructInfo);
        info.* = .{
            .name = decl.name,
            .type_id = type_id,
            .fields = &.{},
            .decl = decl,
            .alignment = unsafe.alignOf(decl.attrs),
            .repr_c = unsafe.hasReprC(decl.attrs),
        };
        try self.structs.put(decl.name, info);
        try self.struct_order.append(self.alloc, info);
    }

    fn resolveStructFields(self: *Sema, decl: ast.StructDecl) !void {
        const info = self.structs.get(decl.name) orelse return;
        var fields: std.ArrayList(FieldInfo) = .empty;
        for (decl.fields) |field| {
            const ty = try self.resolveType(field.ty);
            for (fields.items) |existing| {
                if (std.mem.eql(u8, existing.name, field.name)) {
                    self.report(
                        .duplicate_decl,
                        std.fmt.allocPrint(self.alloc, "o campo `{s}` já existe em `{s}`", .{ field.name, decl.name }) catch "campo duplicado",
                        field.name_span,
                    );
                }
            }
            try fields.append(self.alloc, .{
                .name = field.name,
                .type_id = ty,
                .index = fields.items.len,
                .span = field.span,
            });
        }
        info.fields = fields.items;
    }

    fn declareEnum(self: *Sema, decl: ast.EnumDecl) !void {
        try unsafe.checkAttrs(self.alloc, self.diags, decl.attrs);
        if (self.structs.contains(decl.name) or self.enums.contains(decl.name)) {
            self.report(
                .duplicate_decl,
                std.fmt.allocPrint(self.alloc, "o tipo `{s}` já foi declarado", .{decl.name}) catch "declaração duplicada",
                decl.name_span,
            );
            return;
        }
        var variants: std.ArrayList([]const u8) = .empty;
        for (decl.variants) |variant| {
            for (variants.items) |existing| {
                if (std.mem.eql(u8, existing, variant.name)) {
                    self.report(
                        .duplicate_decl,
                        std.fmt.allocPrint(self.alloc, "a variante `{s}` já existe em `{s}`", .{ variant.name, decl.name }) catch "variante duplicada",
                        variant.span,
                    );
                }
            }
            try variants.append(self.alloc, variant.name);
        }
        const type_id = try self.type_table.add(self.alloc, .{ .named = .{ .name = decl.name, .kind = .enumeration } });
        const info = try self.alloc.create(EnumInfo);
        info.* = .{ .name = decl.name, .type_id = type_id, .variants = variants.items, .decl = decl };
        try self.enums.put(decl.name, info);
        try self.enum_order.append(self.alloc, info);
    }

    fn declareFunc(self: *Sema, decl: *const ast.Func, owner: ?[]const u8) !void {
        try unsafe.checkAttrs(self.alloc, self.diags, decl.attrs);
        const info = try self.alloc.create(FuncInfo);
        info.* = .{
            .name = decl.name,
            .owner = owner,
            .params = &.{},
            .ret = self.type_table.void_id,
            .is_extern = false,
            .is_variadic = false,
            .has_self = false,
            .self_mutable = false,
            .body = decl.body,
            .span = decl.span,
        };

        var params: std.ArrayList(ParamInfo) = .empty;
        for (decl.params) |param| {
            // `self: &T` / `self: &mut T` define o receiver do método.
            if (owner != null and std.mem.eql(u8, param.name, "self") and params.items.len == 0) {
                const ref_ty = switch (param.ty.*) {
                    .ref_ => |r| r,
                    else => {
                        self.reportHelp(
                            .type_mismatch,
                            "`self` deve ser declarado como `&Tipo` ou `&mut Tipo`",
                            param.ty.spanOf(),
                            null,
                        );
                        continue;
                    },
                };
                info.has_self = true;
                info.self_mutable = ref_ty.mutable;
                continue;
            }
            const ty = try self.resolveType(param.ty);
            // Parâmetro `[N]T` decai para `[]T`, como o array-to-pointer do C:
            // a função recebe ponteiro + comprimento e ainda tem `.len`.
            const final_ty = if (self.type_table.arrayInfo(ty)) |arr|
                try self.type_table.add(self.alloc, .{ .slice = .{ .elem = arr.elem, .is_const = false } })
            else ty;
            try params.append(self.alloc, .{ .name = param.name, .type_id = final_ty, .span = param.span });
        }
        info.params = params.items;

        if (decl.ret) |ret_ty| {
            info.ret = try self.resolveType(ret_ty);
            if (self.type_table.isArray(info.ret)) {
                self.reportHelp(
                    .unsupported,
                    "funções não podem retornar array: o tamanho viveria na pilha da função",
                    ret_ty.spanOf(),
                    "retorne um slice `[]T` ou envolva o array em um `struct`",
                );
            }
        }

        if (owner) |owner_name| {
            const key = try std.fmt.allocPrint(self.alloc, "{s}::{s}", .{ owner_name, decl.name });
            if (self.methods.contains(key)) {
                self.report(
                    .duplicate_decl,
                    std.fmt.allocPrint(self.alloc, "o método `{s}` já foi declarado em `{s}`", .{ decl.name, owner_name }) catch "método duplicado",
                    decl.name_span,
                );
                return;
            }
            try self.methods.put(key, info);
        } else {
            if (self.funcs.contains(decl.name)) {
                self.report(
                    .duplicate_decl,
                    std.fmt.allocPrint(self.alloc, "a função `{s}` já foi declarada", .{decl.name}) catch "declaração duplicada",
                    decl.name_span,
                );
                return;
            }
            try self.funcs.put(decl.name, info);
        }
        try self.func_order.append(self.alloc, info);
    }

    fn declareExternFunc(self: *Sema, decl: ast.ExternFunc) !void {
        if (self.funcs.contains(decl.name)) {
            self.report(
                .duplicate_decl,
                std.fmt.allocPrint(self.alloc, "a função `{s}` já foi declarada", .{decl.name}) catch "declaração duplicada",
                decl.name_span,
            );
            return;
        }
        const info = try self.alloc.create(FuncInfo);
        var params: std.ArrayList(ParamInfo) = .empty;
        for (decl.params) |param| {
            const ty = try self.resolveType(param.ty);
            try params.append(self.alloc, .{ .name = param.name, .type_id = ty, .span = param.span });
        }
        var ret = self.type_table.void_id;
        if (decl.ret) |ret_ty| ret = try self.resolveType(ret_ty);

        info.* = .{
            .name = decl.name,
            .owner = null,
            .params = params.items,
            .ret = ret,
            .is_extern = true,
            .is_variadic = decl.is_variadic,
            .has_self = false,
            .self_mutable = false,
            .body = null,
            .span = decl.span,
        };
        try self.funcs.put(decl.name, info);
        try self.func_order.append(self.alloc, info);
    }

    fn declareImpl(self: *Sema, decl: *const ast.ImplDecl) !void {
        if (!self.structs.contains(decl.target)) {
            self.reportHelp(
                .unknown_type,
                std.fmt.allocPrint(self.alloc, "`impl {s}` refere-se a um tipo inexistente", .{decl.target}) catch "tipo inexistente",
                decl.target_span,
                "somente `struct` pode receber `impl`",
            );
            return;
        }
        for (decl.methods) |*method| {
            try self.declareFunc(method, decl.target);
        }
    }

    pub fn resolveType(self: *Sema, ty: *const ast.TypeExpr) !types.Id {
        switch (ty.*) {
            .prim => |p| return switch (p.kind) {
                .void => self.type_table.void_id,
                .bool => self.type_table.bool_id,
                .char => self.type_table.char_id,
                .str => self.type_table.str_id,
                .i8 => self.type_table.i8_id,
                .i16 => self.type_table.i16_id,
                .i32 => self.type_table.i32_id,
                .i64 => self.type_table.i64_id,
                .isize => self.type_table.isize_id,
                .u8 => self.type_table.u8_id,
                .u16 => self.type_table.u16_id,
                .u32 => self.type_table.u32_id,
                .u64 => self.type_table.u64_id,
                .usize => self.type_table.usize_id,
                .f32 => self.type_table.f32_id,
                .f64 => self.type_table.f64_id,
            },
            .named => |n| {
                if (self.structs.get(n.name)) |s| return s.type_id;
                if (self.enums.get(n.name)) |e| return e.type_id;
                self.report(
                    .unknown_type,
                    std.fmt.allocPrint(self.alloc, "tipo desconhecido `{s}`", .{n.name}) catch "tipo desconhecido",
                    n.span,
                );
                return types.invalid;
            },
            .ref_ => |r| {
                const inner = try self.resolveType(r.inner);
                return self.type_table.add(self.alloc, .{ .ref_ = .{ .elem = inner, .mutable = r.mutable } });
            },
            .ptr => |p| {
                const inner = try self.resolveType(p.inner);
                return self.type_table.add(self.alloc, .{ .ptr = .{ .elem = inner, .is_const = p.is_const } });
            },
            .array => |a| {
                const inner = try self.resolveType(a.inner);
                if (self.type_table.isArray(inner)) {
                    self.reportHelp(
                        .unsupported,
                        "arrays multidimensionais não são suportados",
                        a.span,
                        "use um array de structs ou um slice de slices",
                    );
                    return types.invalid;
                }
                return self.type_table.add(self.alloc, .{ .array = .{ .elem = inner, .count = a.count } });
            },
            .slice => |sl| {
                const inner = try self.resolveType(sl.inner);
                if (self.type_table.isArray(inner)) {
                    self.reportHelp(
                        .unsupported,
                        "slice de array não é suportado",
                        sl.span,
                        "use um slice de structs ou um array de tamanho fixo",
                    );
                    return types.invalid;
                }
                return self.type_table.add(self.alloc, .{ .slice = .{ .elem = inner, .is_const = sl.is_const } });
            },
        }
    }

    // --------------------------------------------------------- fase 2: corpos

    fn checkProgram(self: *Sema, program: ast.Program) Error!void {
        var has_main = false;
        for (self.func_order.items) |func| {
            if (func.owner == null and std.mem.eql(u8, func.name, "main")) {
                has_main = true;
                if (func.params.len != 0) {
                    self.report(.return_mismatch, "`fn main` não aceita parâmetros", func.span);
                }
                const ret_ok = self.type_table.isVoid(func.ret) or self.type_table.eql(func.ret, self.type_table.i32_id);
                if (!ret_ok) {
                    self.report(
                        .return_mismatch,
                        std.fmt.allocPrint(self.alloc, "`fn main` deve retornar `void` ou `i32`, não `{s}`", .{self.typeName(func.ret)}) catch "retorno inválido",
                        func.span,
                    );
                }
            }
            const body = func.body orelse continue;
            try self.checkFunction(func, body);
        }
        if (self.opts.require_main and !has_main) {
            self.reportHelp(
                .missing_main,
                "este módulo não define `fn main`",
                program.span,
                "adicione `fn main() -> i32 {{ ... }}` para compilar um executável",
            );
        }
    }

    fn checkFunction(self: *Sema, func: *FuncInfo, body: ast.Block) Error!void {
        self.current_func = func;
        try self.pushScope();
        if (func.has_self) {
            const owner_name = func.owner.?;
            const owner_info = self.structs.get(owner_name).?;
            const self_ty = try self.type_table.add(self.alloc, .{
                .ref_ = .{ .elem = owner_info.type_id, .mutable = func.self_mutable },
            });
            try self.declareVar("self", self_ty, func.self_mutable, func.span, false);
        }
        for (func.params) |param| {
            try self.declareVar(param.name, param.type_id, false, param.span, false);
        }
        try self.checkBlock(body);
        try self.popScope();

        if (!self.type_table.isVoid(func.ret) and !blockAlwaysReturnsInner(body, true)) {
            self.reportHelp(
                .return_mismatch,
                std.fmt.allocPrint(self.alloc, "a função `{s}` deve retornar `{s}` em todos os caminhos", .{
                    func.name,
                    self.typeName(func.ret),
                }) catch "caminho sem retorno",
                body.span,
                "adicione um `return` no fim da função",
            );
        }
        self.current_func = null;
    }

    // ------------------------------------------------------------------ escopo

    fn pushScope(self: *Sema) !void {
        try self.scopes.append(self.alloc, .{ .vars = .empty });
    }

    fn popScope(self: *Sema) !void {
        const scope = self.scopes.pop() orelse return;
        if (!self.opts.warn_unused) return;
        for (scope.vars.items) |variable| {
            if (variable.used) continue;
            self.diags.add(self.alloc, .{
                .code = .unused_variable,
                .message = std.fmt.allocPrint(self.alloc, "a variável `{s}` nunca é lida", .{variable.name}) catch "variável não utilizada",
                .span = variable.span,
            }) catch {};
        }
    }

    fn declareVar(self: *Sema, name: []const u8, type_id: types.Id, mutable: bool, span: diag.Span, warnable: bool) !void {
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        // Shadowing é permitido entre escopos, não dentro do mesmo escopo.
        for (scope.vars.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) {
                self.report(
                    .duplicate_decl,
                    std.fmt.allocPrint(self.alloc, "`{s}` já foi declarado neste escopo", .{name}) catch "declaração duplicada",
                    span,
                );
                return;
            }
        }
        try scope.vars.append(self.alloc, .{
            .name = name,
            .type_id = type_id,
            .mutable = mutable,
            .span = span,
            .used = !warnable,
        });
    }

    fn lookupVar(self: *Sema, name: []const u8) ?*VarInfo {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scopes.items[i].vars.items) |*variable| {
                if (std.mem.eql(u8, variable.name, name)) return variable;
            }
        }
        return null;
    }

    // ------------------------------------------------------------- statements

    fn checkBlock(self: *Sema, block: ast.Block) Error!void {
        try self.pushScope();
        for (block.stmts) |*stmt| try self.checkStmt(stmt);
        try self.popScope();
    }

    fn checkStmt(self: *Sema, stmt: *ast.Stmt) Error!void {
        switch (stmt.*) {
            .binding => |*binding| try self.checkBinding(binding),
            .assign => |*assign| try self.checkAssign(assign),
            .expr => |*expr| {
                _ = try self.checkExpr(expr, null);
            },
            .ret => |*ret| try self.checkReturn(ret),
            .cond => |*cond| try self.checkIf(cond),
            .loop => |*loop| {
                _ = try self.checkExpr(&loop.cond, self.type_table.bool_id);
                const saved_match = self.match_depth;
                self.match_depth = 0;
                self.loop_depth += 1;
                try self.checkBlock(loop.body);
                self.loop_depth -= 1;
                self.match_depth = saved_match;
            },
            .range_for => |*range| try self.checkRangeFor(range),
            .collection_for => |*loop| try self.checkCollectionFor(loop),
            .match_ => |*match| try self.checkMatch(match),
            .break_ => |span| {
                if (self.match_depth > 0) {
                    self.reportHelp(
                        .invalid_control_flow,
                        "`break` dentro de um braço de `match` sairia do `match`, não do laço",
                        span,
                        "use `return`, ou mova o laço para fora do `match`",
                    );
                } else if (self.loop_depth == 0) {
                    self.reportHelp(.invalid_control_flow, "`break` fora de um laço", span, "use `break` apenas dentro de `while` ou `for`");
                }
            },
            .continue_ => |span| {
                if (self.match_depth > 0) {
                    self.reportHelp(
                        .invalid_control_flow,
                        "`continue` dentro de um braço de `match` é ambíguo",
                        span,
                        "use `return`, ou mova o laço para fora do `match`",
                    );
                } else if (self.loop_depth == 0) {
                    self.reportHelp(.invalid_control_flow, "`continue` fora de um laço", span, "use `continue` apenas dentro de `while` ou `for`");
                }
            },
            .block => |block| try self.checkBlock(block),
            .unsafe_block => |block| {
                self.unsafe_ctx.enter();
                try self.checkBlock(block);
                self.unsafe_ctx.exit();
            },
        }
    }

    fn checkBinding(self: *Sema, binding: *ast.Binding) Error!void {
        var declared: types.Id = types.invalid;
        if (binding.ty) |ty| declared = try self.resolveType(ty);

        const init_ty = try self.checkExpr(&binding.init, if (declared == types.invalid) null else declared);
        var final_ty = init_ty;

        if (declared != types.invalid) {
            if (!self.coercible(init_ty, declared, &binding.init)) {
                self.report(
                    .type_mismatch,
                    std.fmt.allocPrint(self.alloc, "mismatch de tipos: esperado `{s}`, encontrado `{s}`", .{
                        self.typeName(declared),
                        self.typeName(init_ty),
                    }) catch "mismatch de tipos",
                    binding.span,
                );
            }
            try self.decayToSlice(&binding.init, declared);
            final_ty = declared;
        } else if (init_ty == types.invalid) {
            final_ty = self.type_table.i32_id;
        }

        try self.declareVar(binding.name, final_ty, binding.mutable, binding.name_span, true);
    }

    fn checkReturn(self: *Sema, ret: *ast.Return) Error!void {
        const func = self.current_func orelse {
            self.report(.invalid_control_flow, "`return` fora de uma função", ret.span);
            return;
        };
        const expected = func.ret;
        if (ret.value) |*value| {
            const got = try self.checkExpr(value, if (self.type_table.isVoid(expected)) null else expected);
            if (self.type_table.isVoid(expected)) {
                self.report(
                    .return_mismatch,
                    std.fmt.allocPrint(self.alloc, "`{s}` retorna `void` e não pode devolver `{s}`", .{
                        func.name,
                        self.typeName(got),
                    }) catch "retorno inválido",
                    ret.span,
                );
            } else if (!self.coercible(got, expected, value)) {
                self.report(
                    .return_mismatch,
                    std.fmt.allocPrint(self.alloc, "esperado `{s}` no retorno, encontrado `{s}`", .{
                        self.typeName(expected),
                        self.typeName(got),
                    }) catch "retorno inválido",
                    ret.span,
                );
            } else {
                try self.decayToSlice(value, expected);
            }
        } else if (!self.type_table.isVoid(expected)) {
            self.report(
                .return_mismatch,
                std.fmt.allocPrint(self.alloc, "esperado `{s}` no retorno de `{s}`", .{ self.typeName(expected), func.name }) catch "retorno inválido",
                ret.span,
            );
        }
    }

    fn checkIf(self: *Sema, cond: *ast.If) Error!void {
        _ = try self.checkExpr(&cond.cond, self.type_table.bool_id);
        try self.checkBlock(cond.then);
        if (cond.els) |els| {
            switch (els) {
                .block => |block| try self.checkBlock(block),
                .cond => |nested| try self.checkIf(nested),
            }
        }
    }

    fn checkRangeFor(self: *Sema, range: *ast.RangeFor) Error!void {
        // Um limite literal adota o tipo do outro lado: `for i in 0..xs.len`
        // não pode falhar só porque `0` seria `i32` por padrão.
        const start_ty: types.Id = blk: {
            if (self.isLiteral(&range.start) and !self.isLiteral(&range.end)) {
                const end_ty = try self.checkExpr(&range.end, null);
                break :blk try self.checkExpr(&range.start, end_ty);
            }
            break :blk try self.checkExpr(&range.start, null);
        };
        const end_ty = try self.checkExpr(&range.end, start_ty);
        if (!self.type_table.isInt(start_ty)) {
            self.report(
                .type_mismatch,
                std.fmt.allocPrint(self.alloc, "laço `for` exige limites inteiros, encontrado `{s}`", .{self.typeName(start_ty)}) catch "tipo inválido",
                range.start.span,
            );
            return;
        }
        if (!self.type_table.eql(start_ty, end_ty)) {
            self.report(
                .type_mismatch,
                std.fmt.allocPrint(self.alloc, "limites do laço têm tipos diferentes: `{s}` e `{s}`", .{
                    self.typeName(start_ty),
                    self.typeName(end_ty),
                }) catch "tipos diferentes",
                .{ .start = range.start.span.start, .end = range.end.span.end },
            );
        }
        self.loop_depth += 1;
        try self.pushScope();
        try self.declareVar(range.var_name, start_ty, false, range.var_span, true);
        for (range.body.stmts) |*stmt| try self.checkStmt(stmt);
        try self.popScope();
        self.loop_depth -= 1;
    }

    /// `match sujeito { Padrao => { ... }, ... }` sobre enum, com verificação
    /// de exaustividade: sem curinga, todas as variantes precisam aparecer.
    fn checkMatch(self: *Sema, match: *ast.Match) Error!void {
        const subject_ty = try self.checkExpr(&match.subject, null);
        const info = self.enumByType(subject_ty) orelse {
            self.reportHelp(
                .invalid_pattern,
                std.fmt.allocPrint(self.alloc, "`match` exige um enum como sujeito, encontrado `{s}`", .{self.typeName(subject_ty)}) catch "sujeito inválido",
                match.subject.span,
                "para outros tipos use `if`/`else if`",
            );
            return;
        };

        var covered: std.ArrayList([]const u8) = .empty;
        var has_wildcard = false;
        for (match.arms) |*arm| {
            if (arm.variant == null) has_wildcard = true;
            if (arm.variant) |name| {
                var found = false;
                for (info.variants) |candidate| {
                    if (std.mem.eql(u8, candidate, name)) found = true;
                }
                if (!found) {
                    self.report(
                        .invalid_pattern,
                        std.fmt.allocPrint(self.alloc, "`{s}` não tem variante `{s}`", .{ info.name, name }) catch "variante inexistente",
                        arm.span,
                    );
                }
                if (arm.head) |head| {
                    if (!std.mem.eql(u8, head, info.name)) {
                        self.report(
                            .invalid_pattern,
                            std.fmt.allocPrint(self.alloc, "`{s}::{s}` não pertence a `{s}`", .{ head, name, info.name }) catch "variante de outro enum",
                            arm.span,
                        );
                    }
                }
                for (covered.items) |previous| {
                    if (std.mem.eql(u8, previous, name)) {
                        self.report(
                            .invalid_pattern,
                            std.fmt.allocPrint(self.alloc, "braço duplicado para `{s}`", .{name}) catch "braço duplicado",
                            arm.span,
                        );
                        break;
                    }
                }
                covered.append(self.alloc, name) catch {};
            }

            const saved = self.match_depth;
            self.match_depth += 1;
            try self.pushScope();
            for (arm.body.stmts) |*stmt| try self.checkStmt(stmt);
            try self.popScope();
            self.match_depth = saved;
        }

        match.exhaustive = true;
        if (!has_wildcard) {
            var missing: std.ArrayList([]const u8) = .empty;
            for (info.variants) |candidate| {
                var present = false;
                for (covered.items) |name| {
                    if (std.mem.eql(u8, name, candidate)) present = true;
                }
                if (!present) missing.append(self.alloc, candidate) catch {};
            }
            if (missing.items.len > 0) {
                match.exhaustive = false;
                var list: std.ArrayList(u8) = .empty;
                for (missing.items, 0..) |name, i| {
                    if (i > 0) list.appendSlice(self.alloc, ", ") catch {};
                    list.appendSlice(self.alloc, "`") catch {};
                    list.appendSlice(self.alloc, name) catch {};
                    list.appendSlice(self.alloc, "`") catch {};
                }
                self.reportHelp(
                    .non_exhaustive_match,
                    std.fmt.allocPrint(self.alloc, "`match` não cobre todas as variantes de `{s}`: falta {s}", .{ info.name, list.items }) catch "match não exaustivo",
                    match.span,
                    "adicione os braços faltantes ou um curinga `_ => { ... }`",
                );
            }
        }
    }

    /// `for item in colecao { ... }` sobre array ou slice. O elemento é uma
    /// cópia imutável; para modificar, indexe a coleção dentro do corpo.
    fn checkCollectionFor(self: *Sema, loop: *ast.CollectionFor) Error!void {
        const collection_ty = try self.checkExpr(&loop.collection, null);
        if (!self.type_table.isArray(collection_ty) and !self.type_table.isSlice(collection_ty)) {
            self.reportHelp(
                .invalid_operand,
                std.fmt.allocPrint(self.alloc, "`{s}` não pode ser percorrido com `for`", .{self.typeName(collection_ty)}) catch "coleção inválida",
                loop.collection.span,
                "use um array `[N]T`, um slice `[]T` ou a forma `for i in inicio..fim`",
            );
            return;
        }
        const elem = self.type_table.elemOf(collection_ty) orelse types.invalid;
        // O backend percorre uma cópia em slice; arrays decaem aqui.
        if (self.type_table.isArray(collection_ty)) {
            const slice_ty = try self.type_table.add(self.alloc, .{ .slice = .{ .elem = elem, .is_const = false } });
            try self.decayToSlice(&loop.collection, slice_ty);
        }
        self.loop_depth += 1;
        try self.pushScope();
        try self.declareVar(loop.var_name, elem, false, loop.var_span, true);
        for (loop.body.stmts) |*stmt| try self.checkStmt(stmt);
        try self.popScope();
        self.loop_depth -= 1;
    }

    fn checkAssign(self: *Sema, assign: *ast.Assign) Error!void {
        // Verificação adiantada: em C, arrays não são atribuíveis.
        if (assign.target.kind == .ident) {
            if (self.lookupVar(assign.target.kind.ident)) |variable| {
                if (self.type_table.isArray(variable.type_id)) {
                    self.reportHelp(
                        .unsupported,
                        "arrays não são atribuíveis como um todo",
                        assign.span,
                        "atribua elemento a elemento (`xs[0] = ...`) ou trabalhe com um slice",
                    );
                }
            }
        }
        const target_ty = try self.checkAssignable(assign.target);
        if (target_ty == types.invalid) return;

        if (assign.op != .assign) {
            if (!self.type_table.isNumeric(target_ty)) {
                self.report(
                    .invalid_operand,
                    std.fmt.allocPrint(self.alloc, "atribuição composta exige tipo numérico, encontrado `{s}`", .{self.typeName(target_ty)}) catch "tipo inválido",
                    assign.span,
                );
                return;
            }
        }

        const value_ty = try self.checkExpr(&assign.value, target_ty);
        if (!self.coercible(value_ty, target_ty, &assign.value)) {
            self.report(
                .type_mismatch,
                std.fmt.allocPrint(self.alloc, "mismatch de tipos: esperado `{s}`, encontrado `{s}`", .{
                    self.typeName(target_ty),
                    self.typeName(value_ty),
                }) catch "mismatch de tipos",
                assign.span,
            );
        }
    }

    /// Verifica se a expressão é um destino de atribuição válido e devolve o
    /// tipo armazenado ali.
    fn checkAssignable(self: *Sema, expr: ast.Expr) Error!types.Id {
        switch (expr.kind) {
            .ident => |name| {
                const variable = self.lookupVar(name) orelse {
                    self.report(
                        .undefined_name,
                        std.fmt.allocPrint(self.alloc, "`{s}` não está definido", .{name}) catch "nome indefinido",
                        expr.span,
                    );
                    return types.invalid;
                };
                if (!variable.mutable) {
                    self.reportHelp(
                        .assign_immutable,
                        std.fmt.allocPrint(self.alloc, "`{s}` é imutável", .{name}) catch "atribuição inválida",
                        expr.span,
                        "declare com `var` (ou `let mut`) para permitir atribuição",
                    );
                }
                return variable.type_id;
            },
            .field => |field| {
                const object_ty = try self.checkExpr(field.object, null);
                const struct_ty = self.autoDeref(object_ty);
                const info = self.structByType(struct_ty) orelse {
                    self.report(
                        .invalid_field,
                        std.fmt.allocPrint(self.alloc, "`{s}` não é um campo de `{s}`", .{ field.name, self.typeName(struct_ty) }) catch "campo inválido",
                        expr.span,
                    );
                    return types.invalid;
                };
                if (!self.placeThroughType(object_ty, field.object.*)) {
                    self.reportHelp(
                        .assign_immutable,
                        std.fmt.allocPrint(self.alloc, "não é possível atribuir ao campo `{s}` de um valor imutável", .{field.name}) catch "atribuição inválida",
                        expr.span,
                        "declare o binding com `var` (ou `let mut`), ou receba o valor por `&mut`",
                    );
                }
                return self.fieldType(info, field.name, expr.span);
            },
            .index => |index| {
                const object_ty = try self.checkExpr(index.object, null);
                if (!self.type_table.isArray(object_ty) and !self.type_table.isSlice(object_ty)) {
                    self.report(
                        .invalid_operand,
                        std.fmt.allocPrint(self.alloc, "`{s}` não pode ser indexado", .{self.typeName(object_ty)}) catch "operand inválido",
                        expr.span,
                    );
                    return types.invalid;
                }
                const elem = self.type_table.elemOf(object_ty) orelse types.invalid;
                const index_ty = try self.checkExpr(index.index, self.type_table.usize_id);
                if (!self.type_table.isInt(index_ty)) {
                    self.report(.type_mismatch, "índice deve ser um inteiro", index.index.span);
                }
                if (self.type_table.sliceInfo(object_ty)) |slice| {
                    if (slice.is_const) {
                        self.reportHelp(
                            .assign_immutable,
                            "não é possível escrever em elemento de `[]const`",
                            expr.span,
                            "receba o slice como `[]T` para poder modificar",
                        );
                    }
                } else if (!self.placeThroughType(object_ty, index.object.*)) {
                    self.reportHelp(
                        .assign_immutable,
                        "não é possível atribuir a elemento de um valor imutável",
                        expr.span,
                        "declare o binding com `var` (ou `let mut`)",
                    );
                }
                return elem;
            },
            .deref => |operand| {
                const operand_ty = try self.checkExpr(operand, null);
                const elem = self.type_table.ptrElem(operand_ty) orelse self.type_table.refElem(operand_ty) orelse {
                    self.report(
                        .invalid_operand,
                        std.fmt.allocPrint(self.alloc, "`{s}` não pode ser dereferenciado", .{self.typeName(operand_ty)}) catch "operand inválido",
                        expr.span,
                    );
                    return types.invalid;
                };
                switch (self.type_table.get(operand_ty)) {
                    .ptr => |ptr| {
                        if (try self.unsafe_ctx.require(self.alloc, .write_raw_ptr, expr.span)) |d| {
                            self.diags.add(self.alloc, d) catch {};
                        }
                        if (ptr.is_const) {
                            self.report(.assign_immutable, "não é possível escrever através de `*const`", expr.span);
                        }
                    },
                    .ref_ => |ref| {
                        if (!ref.mutable) {
                            self.report(.assign_immutable, "não é possível escrever através de `&` (use `&mut`)", expr.span);
                        }
                    },
                    else => {},
                }
                return elem;
            },
            else => {
                self.report(.invalid_operand, "expressão não é um destino de atribuição válido", expr.span);
                return types.invalid;
            },
        }
    }

    /// Decide a mutabilidade de um acesso cujo objeto já foi tipado: passar
    /// por `&mut` ou por ponteiro não-`const` torna o lugar mutável mesmo que
    /// o binding que guarda a referência seja imutável.
    fn placeThroughType(self: *Sema, object_ty: types.Id, object_expr: ast.Expr) bool {
        return switch (self.type_table.get(object_ty)) {
            .ref_ => |ref| ref.mutable,
            .ptr => |ptr| !ptr.is_const,
            else => self.placeIsMutable(object_expr),
        };
    }

    /// Um lugar é mutável quando o binding é `var`/`let mut`, ou quando o
    /// acesso passa por `&mut` ou por ponteiro cru não-`const`.
    fn placeIsMutable(self: *Sema, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |name| if (self.lookupVar(name)) |variable| variable.mutable else false,
            .self_ => if (self.lookupVar("self")) |variable| variable.mutable else false,
            .field => |field| switch (self.type_table.get(field.object.type_id)) {
                .ref_ => |ref| ref.mutable,
                .ptr => |ptr| !ptr.is_const,
                else => self.placeIsMutable(field.object.*),
            },
            .deref => |operand| switch (self.type_table.get(operand.type_id)) {
                .ref_ => |ref| ref.mutable,
                .ptr => |ptr| !ptr.is_const,
                else => true,
            },
            else => false,
        };
    }

    fn isEnum(self: *const Sema, ty: types.Id) bool {
        return switch (self.type_table.get(ty)) {
            .named => |named| named.kind == .enumeration,
            else => false,
        };
    }

    // ------------------------------------------------------------ expressões

    fn checkExpr(self: *Sema, expr: *ast.Expr, expected: ?types.Id) Error!types.Id {
        const ty = try self.checkExprInner(expr, expected);
        expr.type_id = ty;
        return ty;
    }

    fn checkExprInner(self: *Sema, expr: *ast.Expr, expected: ?types.Id) Error!types.Id {
        switch (expr.kind) {
            .int_lit => |value| {
                if (expected) |want| {
                    if (self.type_table.isInt(want)) {
                        if (!intFits(value, want, self.type_table)) {
                            self.report(
                                .type_mismatch,
                                std.fmt.allocPrint(self.alloc, "o literal `{d}` não cabe em `{s}`", .{
                                    value,
                                    self.typeName(want),
                                }) catch "literal fora do intervalo",
                                expr.span,
                            );
                        }
                        return want;
                    }
                    if (self.type_table.isFloat(want)) return want;
                }
                return self.type_table.i32_id;
            },
            .float_lit => {
                if (expected) |want| {
                    if (self.type_table.isFloat(want)) return want;
                    if (self.type_table.isInt(want)) {
                        self.report(
                            .type_mismatch,
                            std.fmt.allocPrint(self.alloc, "literal de ponto flutuante não pode ser usado como `{s}`", .{self.typeName(want)}) catch "mismatch de tipos",
                            expr.span,
                        );
                    }
                }
                return self.type_table.f64_id;
            },
            .string_lit => {
                if (expected) |want| {
                    if (self.isCStringPtr(want)) return want;
                }
                return self.type_table.str_id;
            },
            .char_lit => return self.type_table.char_id,
            .bool_lit => return self.type_table.bool_id,
            .ident => |name| {
                const variable = self.lookupVar(name) orelse {
                    self.report(
                        .undefined_name,
                        std.fmt.allocPrint(self.alloc, "`{s}` não está definido", .{name}) catch "nome indefinido",
                        expr.span,
                    );
                    return types.invalid;
                };
                variable.used = true;
                return variable.type_id;
            },
            .self_ => {
                const variable = self.lookupVar("self") orelse {
                    self.reportHelp(.undefined_name, "`self` só pode ser usado dentro de um método", expr.span, null);
                    return types.invalid;
                };
                variable.used = true;
                return variable.type_id;
            },
            .binary => |binary| return self.checkBinary(binary, expr.span),
            .unary => |unary| return self.checkUnary(unary, expr.span),
            .call => |call| return self.checkCall(call, expr.span, expected),
            .field => |field| {
                const object_ty = try self.checkExpr(field.object, null);
                // `.len` de array/slice não é um campo de struct.
                if (std.mem.eql(u8, field.name, "len")) {
                    if (self.type_table.isArray(object_ty) or self.type_table.isSlice(object_ty)) {
                        return self.type_table.usize_id;
                    }
                }
                // Método usado como valor não é suportado; apenas chamadas.
                const struct_ty = self.autoDeref(object_ty);
                const info = self.structByType(struct_ty) orelse {
                    self.report(
                        .invalid_field,
                        std.fmt.allocPrint(self.alloc, "`{s}` não tem campo `{s}`", .{ self.typeName(struct_ty), field.name }) catch "campo inválido",
                        expr.span,
                    );
                    return types.invalid;
                };
                return self.fieldType(info, field.name, expr.span);
            },
            .path => |path| return self.checkPath(path, expr.span),
            .struct_lit => |literal| return self.checkStructLiteral(literal, expr.span),
            .enum_lit => |literal| {
                const info = self.enums.get(literal.name) orelse {
                    self.report(.unknown_type, std.fmt.allocPrint(self.alloc, "enum `{s}` não existe", .{literal.name}) catch "enum inexistente", expr.span);
                    return types.invalid;
                };
                for (info.variants) |variant| {
                    if (std.mem.eql(u8, variant, literal.variant)) return info.type_id;
                }
                self.report(
                    .invalid_field,
                    std.fmt.allocPrint(self.alloc, "`{s}` não tem variante `{s}`", .{ literal.name, literal.variant }) catch "variante inválida",
                    expr.span,
                );
                return info.type_id;
            },
            .cast => |cast| {
                const target = try self.resolveType(cast.ty);
                const from = try self.checkExpr(cast.operand, null);
                try self.checkCast(from, target, expr.span);
                return target;
            },
            .ref_of => |ref_of| {
                const operand_ty = try self.checkExpr(ref_of.operand, null);
                if (ref_of.mutable and !self.placeIsMutable(ref_of.operand.*)) {
                    self.reportHelp(
                        .assign_immutable,
                        "`&mut` exige um lugar mutável",
                        expr.span,
                        "declare o binding com `var` (ou `let mut`)",
                    );
                }
                if (!isPlace(ref_of.operand.*)) {
                    self.report(.invalid_operand, "não é possível obter referência de um valor temporário", expr.span);
                }
                if (self.type_table.isArray(operand_ty)) {
                    self.reportHelp(
                        .unsupported,
                        "não é possível obter referência de um array",
                        expr.span,
                        "use uma fatia `xs[..]` para passar a coleção adiante",
                    );
                    return types.invalid;
                }
                return self.type_table.add(self.alloc, .{ .ref_ = .{ .elem = operand_ty, .mutable = ref_of.mutable } });
            },
            .deref => |operand| {
                const operand_ty = try self.checkExpr(operand, null);
                const elem = self.type_table.ptrElem(operand_ty) orelse self.type_table.refElem(operand_ty) orelse {
                    self.report(
                        .invalid_operand,
                        std.fmt.allocPrint(self.alloc, "`{s}` não pode ser dereferenciado", .{self.typeName(operand_ty)}) catch "operand inválido",
                        expr.span,
                    );
                    return types.invalid;
                };
                if (self.type_table.isRawPtr(operand_ty)) {
                    if (try self.unsafe_ctx.require(self.alloc, .deref_raw_ptr, expr.span)) |d| {
                        self.diags.add(self.alloc, d) catch {};
                    }
                }
                return elem;
            },
            .array_lit => |items| return self.checkArrayLiteral(items, expr.span, expected),
            .index => |index| {
                const object_ty = try self.checkExpr(index.object, null);
                if (!self.type_table.isArray(object_ty) and !self.type_table.isSlice(object_ty)) {
                    self.reportHelp(
                        .invalid_operand,
                        std.fmt.allocPrint(self.alloc, "`{s}` não pode ser indexado", .{self.typeName(object_ty)}) catch "operand inválido",
                        expr.span,
                        "indexação é suportada em `[N]T` e `[]T`",
                    );
                    return types.invalid;
                }
                const index_ty = try self.checkExpr(index.index, self.type_table.usize_id);
                if (!self.type_table.isInt(index_ty)) {
                    self.report(
                        .type_mismatch,
                        std.fmt.allocPrint(self.alloc, "índice deve ser inteiro, encontrado `{s}`", .{self.typeName(index_ty)}) catch "índice inválido",
                        index.index.span,
                    );
                }
                return self.type_table.elemOf(object_ty) orelse types.invalid;
            },
            .slice_range => |range| return self.checkSliceRange(range, expr.span),
            .to_slice => |operand| {
                // Inserido pela própria semântica; o operando já está tipado.
                _ = operand;
                return expr.type_id;
            },
        }
    }

    /// `[a, b, c]` — o tipo do elemento vem do contexto quando existe; caso
    /// contrário, do primeiro elemento (os demais precisam ser coercíveis).
    fn checkArrayLiteral(self: *Sema, items: []const *ast.Expr, span: diag.Span, expected: ?types.Id) Error!types.Id {
        var expected_elem: types.Id = types.invalid;
        if (expected) |want| {
            if (self.type_table.arrayInfo(want)) |arr| {
                expected_elem = arr.elem;
                if (arr.count != items.len) {
                    self.report(
                        .type_mismatch,
                        std.fmt.allocPrint(self.alloc, "o literal tem {d} elemento(s), mas o tipo declara [{d}]", .{
                            items.len,
                            arr.count,
                        }) catch "tamanho de array incompatível",
                        span,
                    );
                }
            } else if (self.type_table.sliceInfo(want)) |slice| {
                expected_elem = slice.elem;
            }
        }
        if (items.len == 0) {
            self.reportHelp(
                .unsupported,
                "literal de array vazio `[]` não é suportado",
                span,
                "declare pelo menos um elemento",
            );
            return types.invalid;
        }

        var elem_ty = expected_elem;
        for (items, 0..) |item, i| {
            const got = try self.checkExpr(item, if (elem_ty == types.invalid) null else elem_ty);
            if (elem_ty == types.invalid) {
                elem_ty = got;
                continue;
            }
            if (!self.coercible(got, elem_ty, item)) {
                self.report(
                    .type_mismatch,
                    std.fmt.allocPrint(self.alloc, "elemento {d}: esperado `{s}`, encontrado `{s}`", .{
                        i + 1,
                        self.typeName(elem_ty),
                        self.typeName(got),
                    }) catch "elemento incompatível",
                    item.span,
                );
            }
        }
        if (elem_ty == types.invalid) elem_ty = self.type_table.i32_id;
        return self.type_table.add(self.alloc, .{ .array = .{ .elem = elem_ty, .count = @intCast(items.len) } });
    }

    /// `objeto[lo..hi]` — produz um slice sobre o mesmo armazenamento. Os
    /// limites **não** são verificados em tempo de execução.
    fn checkSliceRange(self: *Sema, range: anytype, span: diag.Span) Error!types.Id {
        const object_ty = try self.checkExpr(range.object, null);
        const is_array = self.type_table.isArray(object_ty);
        if (!is_array and !self.type_table.isSlice(object_ty)) {
            self.reportHelp(
                .invalid_operand,
                std.fmt.allocPrint(self.alloc, "`{s}` não pode ser fatiado", .{self.typeName(object_ty)}) catch "operand inválido",
                span,
                "fatias são suportadas em `[N]T` e `[]T`",
            );
            return types.invalid;
        }
        if (range.start) |start| {
            const ty = try self.checkExpr(start, self.type_table.usize_id);
            if (!self.type_table.isInt(ty)) {
                self.report(.type_mismatch, "início da fatia deve ser inteiro", start.span);
            }
        }
        if (range.end) |end| {
            const ty = try self.checkExpr(end, self.type_table.usize_id);
            if (!self.type_table.isInt(ty)) {
                self.report(.type_mismatch, "fim da fatia deve ser inteiro", end.span);
            }
        }
        const elem = self.type_table.elemOf(object_ty) orelse types.invalid;
        // A constância dos elementos segue o lugar de origem: fatiar um array
        // imutável não pode criar um caminho de escrita.
        const is_const = if (self.type_table.sliceInfo(object_ty)) |slice|
            slice.is_const
        else
            !self.placeIsMutable(range.object.*);
        return self.type_table.add(self.alloc, .{ .slice = .{ .elem = elem, .is_const = is_const } });
    }

    /// Converte um array em slice quando o destino espera `[]T`. A conversão
    /// fica explícita na AST (nó `to_slice`) para o backend emitir o literal
    /// composto de C correspondente.
    fn decayToSlice(self: *Sema, expr: *ast.Expr, target: types.Id) !void {
        if (!self.type_table.isArray(expr.type_id)) return;
        if (self.type_table.sliceInfo(target) == null) return;
        const copy = try self.alloc.create(ast.Expr);
        copy.* = expr.*;
        expr.kind = .{ .to_slice = copy };
        expr.type_id = target;
    }

    fn checkBinary(self: *Sema, binary: anytype, span: diag.Span) Error!types.Id {
        const op = binary.op;
        switch (op) {
            .and_, .or_ => {
                _ = try self.checkExpr(binary.lhs, self.type_table.bool_id);
                _ = try self.checkExpr(binary.rhs, self.type_table.bool_id);
                return self.type_table.bool_id;
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                const lhs_ty = try self.checkExpr(binary.lhs, null);
                const rhs_ty = try self.checkExpr(binary.rhs, lhs_ty);
                switch (op) {
                    .lt, .le, .gt, .ge => {
                        const ok = self.type_table.isNumeric(lhs_ty) or
                            self.type_table.isChar(lhs_ty) or
                            self.type_table.isStr(lhs_ty);
                        if (!ok) {
                            self.report(
                                .invalid_operand,
                                std.fmt.allocPrint(self.alloc, "`{s}` não aceita operandos `{s}`", .{
                                    op.text(),
                                    self.typeName(lhs_ty),
                                }) catch "operand inválido",
                                span,
                            );
                        }
                    },
                    .eq, .ne => {
                        const ok = self.type_table.isNumeric(lhs_ty) or
                            self.type_table.isBool(lhs_ty) or
                            self.type_table.isChar(lhs_ty) or
                            self.type_table.isStr(lhs_ty) or
                            self.type_table.isRawPtr(lhs_ty) or
                            self.isEnum(lhs_ty);
                        if (!ok) {
                            self.report(
                                .invalid_operand,
                                std.fmt.allocPrint(self.alloc, "`{s}` não aceita operandos `{s}`", .{
                                    op.text(),
                                    self.typeName(lhs_ty),
                                }) catch "operand inválido",
                                span,
                            );
                        }
                    },
                    else => {},
                }
                if (!self.compatible(lhs_ty, rhs_ty)) {
                    self.report(
                        .type_mismatch,
                        std.fmt.allocPrint(self.alloc, "comparação entre `{s}` e `{s}`", .{
                            self.typeName(lhs_ty),
                            self.typeName(rhs_ty),
                        }) catch "mismatch de tipos",
                        span,
                    );
                }
                return self.type_table.bool_id;
            },
            .shl, .shr => {
                const lhs_ty = try self.checkExpr(binary.lhs, null);
                _ = try self.checkExpr(binary.rhs, null);
                if (!self.type_table.isInt(lhs_ty)) {
                    self.report(
                        .invalid_operand,
                        std.fmt.allocPrint(self.alloc, "deslocamento exige inteiro, encontrado `{s}`", .{self.typeName(lhs_ty)}) catch "operand inválido",
                        span,
                    );
                }
                return lhs_ty;
            },
            .bit_and, .bit_or, .bit_xor => {
                const lhs_ty = try self.checkExpr(binary.lhs, null);
                const rhs_ty = try self.checkExpr(binary.rhs, lhs_ty);
                if (!self.type_table.isInt(lhs_ty)) {
                    self.report(
                        .invalid_operand,
                        std.fmt.allocPrint(self.alloc, "operador bit a bit exige inteiro, encontrado `{s}`", .{self.typeName(lhs_ty)}) catch "operand inválido",
                        span,
                    );
                }
                if (!self.compatible(lhs_ty, rhs_ty)) {
                    self.report(
                        .type_mismatch,
                        std.fmt.allocPrint(self.alloc, "operandos `{s}` e `{s}`", .{ self.typeName(lhs_ty), self.typeName(rhs_ty) }) catch "mismatch de tipos",
                        span,
                    );
                }
                return lhs_ty;
            },
            else => {},
        }

        // Aritmética.
        const lhs_ty = try self.checkExpr(binary.lhs, null);
        const rhs_ty = try self.checkExpr(binary.rhs, lhs_ty);
        if (!self.type_table.isNumeric(lhs_ty)) {
            self.reportHelp(
                .invalid_operand,
                std.fmt.allocPrint(self.alloc, "operador `{s}` não aceita `{s}`", .{ op.text(), self.typeName(lhs_ty) }) catch "operand inválido",
                span,
                "operações aritméticas exigem tipos numéricos; conversões usam `as`",
            );
            return types.invalid;
        }
        if (op == .rem and !self.type_table.isInt(lhs_ty)) {
            self.report(.invalid_operand, "`%` exige operandos inteiros", span);
        }
        if (!self.compatible(lhs_ty, rhs_ty)) {
            self.report(
                .type_mismatch,
                std.fmt.allocPrint(self.alloc, "operandos `{s}` e `{s}` em `{s}`", .{
                    self.typeName(lhs_ty),
                    self.typeName(rhs_ty),
                    op.text(),
                }) catch "mismatch de tipos",
                span,
            );
        }
        return lhs_ty;
    }

    fn checkUnary(self: *Sema, unary: anytype, span: diag.Span) Error!types.Id {
        switch (unary.op) {
            .not => {
                _ = try self.checkExpr(unary.operand, self.type_table.bool_id);
                return self.type_table.bool_id;
            },
            .neg => {
                const ty = try self.checkExpr(unary.operand, null);
                if (!self.type_table.isNumeric(ty)) {
                    self.report(
                        .invalid_operand,
                        std.fmt.allocPrint(self.alloc, "`-` não aceita `{s}`", .{self.typeName(ty)}) catch "operand inválido",
                        span,
                    );
                }
                return ty;
            },
            .bit_not => {
                const ty = try self.checkExpr(unary.operand, null);
                if (!self.type_table.isInt(ty)) {
                    self.report(
                        .invalid_operand,
                        std.fmt.allocPrint(self.alloc, "`~` exige inteiro, encontrado `{s}`", .{self.typeName(ty)}) catch "operand inválido",
                        span,
                    );
                }
                return ty;
            },
        }
    }

    fn checkCast(self: *Sema, from: types.Id, to: types.Id, span: diag.Span) Error!void {
        if (self.type_table.isNumeric(from) and self.type_table.isNumeric(to)) return;
        if (self.type_table.isRawPtr(from) and self.type_table.isRawPtr(to)) return;
        // `&T` <-> `*T`: o endereço é o mesmo; a garantia de validade continua
        // sendo responsabilidade de quem dereferencia.
        const ref_to_ptr = self.type_table.refElem(from) != null and self.type_table.isRawPtr(to);
        const ptr_to_ref = self.type_table.isRawPtr(from) and self.type_table.refElem(to) != null;
        if (ref_to_ptr or ptr_to_ref) return;
        const int_to_ptr = self.type_table.isInt(from) and self.type_table.isRawPtr(to);
        const ptr_to_int = self.type_table.isRawPtr(from) and self.type_table.isInt(to);
        if (int_to_ptr or ptr_to_int) {
            if (try self.unsafe_ctx.require(self.alloc, .deref_raw_ptr, span)) |d| {
                self.diags.add(self.alloc, d) catch {};
            }
            return;
        }
        self.report(
            .type_mismatch,
            std.fmt.allocPrint(self.alloc, "conversão `{s}` para `{s}` não é suportada", .{
                self.typeName(from),
                self.typeName(to),
            }) catch "conversão inválida",
            span,
        );
    }

    fn checkPath(self: *Sema, path: anytype, span: diag.Span) Error!types.Id {
        // `Enum::Variante` fora de chamada; `Struct::funcao` exige chamada.
        if (self.enums.get(path.head)) |info| {
            for (info.variants) |variant| {
                if (std.mem.eql(u8, variant, path.tail)) return info.type_id;
            }
            self.report(
                .invalid_field,
                std.fmt.allocPrint(self.alloc, "`{s}` não tem variante `{s}`", .{ path.head, path.tail }) catch "variante inválida",
                span,
            );
            return info.type_id;
        }
        if (self.structs.contains(path.head)) {
            self.reportHelp(
                .invalid_operand,
                std.fmt.allocPrint(self.alloc, "`{s}::{s}` precisa ser chamado", .{ path.head, path.tail }) catch "uso inválido",
                span,
                "use `Struct::funcao(...)`",
            );
            return types.invalid;
        }
        self.report(
            .undefined_name,
            std.fmt.allocPrint(self.alloc, "caminho `{s}::{s}` não resolve para nenhum item", .{ path.head, path.tail }) catch "caminho inválido",
            span,
        );
        return types.invalid;
    }

    fn checkStructLiteral(self: *Sema, literal: anytype, span: diag.Span) Error!types.Id {
        const info = self.structs.get(literal.name) orelse {
            if (self.enums.contains(literal.name)) {
                self.reportHelp(
                    .invalid_operand,
                    std.fmt.allocPrint(self.alloc, "`{s}` é um enum; use `{s}::Variante`", .{ literal.name, literal.name }) catch "literal inválido",
                    span,
                    null,
                );
            } else {
                self.report(
                    .unknown_type,
                    std.fmt.allocPrint(self.alloc, "struct `{s}` não existe", .{literal.name}) catch "struct inexistente",
                    span,
                );
            }
            return types.invalid;
        };

        for (info.fields) |field| {
            var found = false;
            for (literal.inits) |*field_init| {
                if (!std.mem.eql(u8, field_init.name, field.name)) continue;
                found = true;
                const got = try self.checkExpr(&field_init.value, field.type_id);
                if (!self.coercible(got, field.type_id, &field_init.value)) {
                    self.report(
                        .type_mismatch,
                        std.fmt.allocPrint(self.alloc, "campo `{s}`: esperado `{s}`, encontrado `{s}`", .{
                            field.name,
                            self.typeName(field.type_id),
                            self.typeName(got),
                        }) catch "mismatch de tipos",
                        field_init.name_span,
                    );
                }
            }
            if (!found) {
                self.reportHelp(
                    .invalid_field,
                    std.fmt.allocPrint(self.alloc, "o campo `{s}` de `{s}` não foi inicializado", .{ field.name, literal.name }) catch "campo ausente",
                    span,
                    "todos os campos devem ser inicializados no literal",
                );
            }
        }
        for (literal.inits) |field_init| {
            var known = false;
            for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, field_init.name)) known = true;
            }
            if (!known) {
                self.report(
                    .invalid_field,
                    std.fmt.allocPrint(self.alloc, "`{s}` não tem campo `{s}`", .{ literal.name, field_init.name }) catch "campo inexistente",
                    field_init.name_span,
                );
            }
        }
        return info.type_id;
    }

    fn checkCall(self: *Sema, call: anytype, span: diag.Span, expected: ?types.Id) Error!types.Id {
        _ = expected;
        switch (call.callee.kind) {
            .ident => |name| {
                if (std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "println")) {
                    return self.checkBuiltinPrint(name, call, span);
                }
                const func = self.funcs.get(name) orelse {
                    self.report(
                        .undefined_name,
                        std.fmt.allocPrint(self.alloc, "a função `{s}` não existe", .{name}) catch "função inexistente",
                        span,
                    );
                    return types.invalid;
                };
                return self.checkCallArgs(func, call, span);
            },
            .field => |field| {
                const object_ty = try self.checkExpr(field.object, null);
                const struct_ty = self.autoDeref(object_ty);
                const info = self.structByType(struct_ty) orelse {
                    self.report(
                        .invalid_field,
                        std.fmt.allocPrint(self.alloc, "`{s}` não tem método `{s}`", .{ self.typeName(struct_ty), field.name }) catch "método inexistente",
                        span,
                    );
                    return types.invalid;
                };
                const key = try std.fmt.allocPrint(self.alloc, "{s}::{s}", .{ info.name, field.name });
                const method = self.methods.get(key) orelse {
                    // Pode ser um campo sendo "chamado" por engano.
                    for (info.fields) |f| {
                        if (std.mem.eql(u8, f.name, field.name)) {
                            self.reportHelp(
                                .invalid_operand,
                                std.fmt.allocPrint(self.alloc, "`{s}` é um campo, não um método", .{field.name}) catch "uso inválido",
                                span,
                                null,
                            );
                            return f.type_id;
                        }
                    }
                    self.report(
                        .undefined_name,
                        std.fmt.allocPrint(self.alloc, "`{s}` não tem método `{s}`", .{ info.name, field.name }) catch "método inexistente",
                        span,
                    );
                    return types.invalid;
                };
                if (!method.has_self) {
                    self.reportHelp(
                        .invalid_operand,
                        std.fmt.allocPrint(self.alloc, "`{s}` é uma função associada; use `{s}::{s}(...)`", .{
                            field.name,
                            info.name,
                            field.name,
                        }) catch "uso inválido",
                        span,
                        null,
                    );
                }
                return self.checkCallArgs(method, call, span);
            },
            .path => |path| {
                if (self.structs.get(path.head)) |info| {
                    const key = try std.fmt.allocPrint(self.alloc, "{s}::{s}", .{ info.name, path.tail });
                    if (self.methods.get(key)) |method| {
                        if (method.has_self) {
                            self.reportHelp(
                                .invalid_operand,
                                std.fmt.allocPrint(self.alloc, "`{s}` é um método; chame a partir de um valor `{s}`", .{
                                    path.tail,
                                    info.name,
                                }) catch "uso inválido",
                                span,
                                "métodos recebem `self` implicitamente",
                            );
                        }
                        return self.checkCallArgs(method, call, span);
                    }
                    self.report(
                        .undefined_name,
                        std.fmt.allocPrint(self.alloc, "`{s}` não tem função associada `{s}`", .{ info.name, path.tail }) catch "função inexistente",
                        span,
                    );
                    return types.invalid;
                }
                if (self.enums.contains(path.head)) {
                    self.reportHelp(
                        .invalid_operand,
                        "variantes de enum não são chamáveis",
                        span,
                        "use `Enum::Variante` sem parênteses",
                    );
                    return types.invalid;
                }
                self.report(
                    .undefined_name,
                    std.fmt.allocPrint(self.alloc, "caminho `{s}::{s}` não resolve para uma função", .{ path.head, path.tail }) catch "função inexistente",
                    span,
                );
                return types.invalid;
            },
            else => {
                self.report(.invalid_operand, "apenas funções nomeadas podem ser chamadas", span);
                return types.invalid;
            },
        }
    }

    fn checkBuiltinPrint(self: *Sema, name: []const u8, call: anytype, span: diag.Span) Error!types.Id {
        const newline = std.mem.eql(u8, name, "println");
        _ = newline;
        if (call.args.len > 1) {
            self.reportHelp(
                .arity_mismatch,
                std.fmt.allocPrint(self.alloc, "`{s}` aceita no máximo 1 argumento, recebidos {d}", .{ name, call.args.len }) catch "aridade inválida",
                span,
                "chame `println` uma vez por valor",
            );
            return self.type_table.void_id;
        }
        if (call.args.len == 1) {
            const ty = try self.checkExpr(call.args[0], null);
            const printable = self.type_table.isNumeric(ty) or self.type_table.isBool(ty) or
                self.type_table.isChar(ty) or self.type_table.isStr(ty);
            if (!printable) {
                self.report(
                    .type_mismatch,
                    std.fmt.allocPrint(self.alloc, "`{s}` não sabe imprimir `{s}`", .{ name, self.typeName(ty) }) catch "tipo não imprimível",
                    span,
                );
            }
        }
        return self.type_table.void_id;
    }

    fn checkCallArgs(self: *Sema, func: *FuncInfo, call: anytype, span: diag.Span) Error!types.Id {
        if (func.is_extern) {
            if (try self.unsafe_ctx.require(self.alloc, .call_extern, span)) |d| {
                self.diags.add(self.alloc, d) catch {};
            }
        }
        const expected_count = func.params.len;
        if (call.args.len < expected_count or (call.args.len > expected_count and !func.is_variadic)) {
            self.report(
                .arity_mismatch,
                std.fmt.allocPrint(self.alloc, "`{s}` espera {d} argumento(s), recebidos {d}", .{
                    func.name,
                    expected_count,
                    call.args.len,
                }) catch "aridade inválida",
                span,
            );
            return func.ret;
        }
        for (func.params, 0..) |param, i| {
            if (i >= call.args.len) break;
            const got = try self.checkExpr(call.args[i], param.type_id);
            if (!self.coercible(got, param.type_id, call.args[i])) {
                self.report(
                    .type_mismatch,
                    std.fmt.allocPrint(self.alloc, "argumento {d} de `{s}`: esperado `{s}`, encontrado `{s}`", .{
                        i + 1,
                        func.name,
                        self.typeName(param.type_id),
                        self.typeName(got),
                    }) catch "mismatch de tipos",
                    call.args[i].span,
                );
            } else {
                try self.decayToSlice(call.args[i], param.type_id);
            }
        }
        for (call.args[expected_count..]) |extra| {
            _ = try self.checkExpr(extra, null);
        }
        return func.ret;
    }

    // ---------------------------------------------------------------- helpers

    pub fn autoDeref(self: *const Sema, ty: types.Id) types.Id {
        if (self.type_table.refElem(ty)) |elem| return elem;
        return ty;
    }

    /// Nome do tipo nomeado (struct/enum), se for o caso. Usado pelo backend.
    pub fn nameOfType(self: *const Sema, ty: types.Id) ?[]const u8 {
        return switch (self.type_table.get(ty)) {
            .named => |named| named.name,
            else => null,
        };
    }

    fn enumByType(self: *Sema, ty: types.Id) ?*EnumInfo {
        switch (self.type_table.get(ty)) {
            .named => |named| {
                if (named.kind != .enumeration) return null;
                return self.enums.get(named.name);
            },
            else => return null,
        }
    }

    fn structByType(self: *Sema, ty: types.Id) ?*StructInfo {
        switch (self.type_table.get(ty)) {
            .named => |named| {
                if (named.kind != .structure) return null;
                return self.structs.get(named.name);
            },
            else => return null,
        }
    }

    fn fieldType(self: *Sema, info: *StructInfo, name: []const u8, span: diag.Span) types.Id {
        for (info.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.type_id;
        }
        self.report(
            .invalid_field,
            std.fmt.allocPrint(self.alloc, "`{s}` não tem campo `{s}`", .{ info.name, name }) catch "campo inexistente",
            span,
        );
        return types.invalid;
    }

    fn isCStringPtr(self: *Sema, ty: types.Id) bool {
        const ptr = switch (self.type_table.get(ty)) {
            .ptr => |p| p,
            else => return false,
        };
        return self.type_table.eql(ptr.elem, self.type_table.u8_id);
    }

    /// Um literal numérico é compatível com qualquer tipo numérico do contexto.
    fn isLiteral(self: *const Sema, expr: *const ast.Expr) bool {
        return switch (expr.kind) {
            .int_lit, .float_lit, .char_lit, .string_lit, .bool_lit => true,
            .unary => |unary| unary.op == .neg and self.isLiteral(unary.operand),
            else => false,
        };
    }

    /// Regras de conversão implícita permitidas pelo compilador.
    fn coercible(self: *Sema, from: types.Id, to: types.Id, expr: *const ast.Expr) bool {
        if (self.type_table.eql(from, to)) return true;
        if (from == types.invalid or to == types.invalid) return true;
        if (self.isLiteral(expr)) {
            if (self.type_table.isNumeric(from) and self.type_table.isNumeric(to)) return true;
            // Literal de string em parâmetro `*const u8`/`*u8` (FFI com C).
            if (self.type_table.isStr(from) and self.isCStringPtr(to)) return true;
        }
        // `[N]T` onde se espera `[]T` (decadência explícita via `to_slice`).
        if (self.type_table.arrayInfo(from)) |source| {
            if (self.type_table.sliceInfo(to)) |target| {
                if (self.compatible(source.elem, target.elem)) return true;
            }
        }
        // `[]T` onde se espera `[]const T`.
        if (self.type_table.sliceInfo(from)) |source| {
            if (self.type_table.sliceInfo(to)) |target| {
                if (target.is_const and !source.is_const and self.compatible(source.elem, target.elem)) return true;
            }
        }
        return false;
    }

    /// Tipos comparáveis entre si sem conversão explícita.
    fn compatible(self: *Sema, a: types.Id, b: types.Id) bool {
        if (self.type_table.eql(a, b)) return true;
        if (a == types.invalid or b == types.invalid) return true;
        return false;
    }
};

fn intFits(value: i128, ty: types.Id, table: types.Table) bool {
    const info = table.intInfo(ty) orelse return true;
    const bits: u7 = if (info.addr_width) 64 else @intCast(info.bits);
    if (info.signed) {
        const max: i128 = (@as(i128, 1) << (bits - 1)) - 1;
        const min: i128 = -(@as(i128, 1) << (bits - 1));
        return value >= min and value <= max;
    }
    if (value < 0) return false;
    const max: i128 = (@as(i128, 1) << bits) - 1;
    return value <= max;
}

/// Expressões que denotam um lugar na memória (podem ter endereço tomado).
fn isPlace(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .ident, .self_, .field => true,
        .deref, .index => true,
        else => false,
    };
}

/// Verdadeiro quando todo caminho de execução do bloco termina em `return`.
/// Exportado para o backend decidir se precisa de um `return` de segurança.
pub fn alwaysReturns(block: ast.Block) bool {
    return blockAlwaysReturnsInner(block, true);
}

/// Como `alwaysReturns`, mas desconsiderando a exaustividade de `match`: um
/// compilador C não consegue provar que um `switch` cobre todos os casos de um
/// enum, então o backend usa esta versão para decidir se insere um `return` de
/// segurança e evitar o aviso `-Wreturn-type`.
pub fn alwaysReturnsForC(block: ast.Block) bool {
    return blockAlwaysReturnsInner(block, false);
}

fn blockAlwaysReturnsInner(block: ast.Block, trust_match: bool) bool {
    if (block.stmts.len == 0) return false;
    const last = block.stmts[block.stmts.len - 1];
    return switch (last) {
        .ret => true,
        .block => |inner| blockAlwaysReturnsInner(inner, trust_match),
        .unsafe_block => |inner| blockAlwaysReturnsInner(inner, trust_match),
        .cond => |cond| ifAlwaysReturns(cond, trust_match),
        .match_ => |match| if (trust_match) matchAlwaysReturns(match) else false,
        else => false,
    };
}

/// Um `match` termina em `return` quando é exaustivo (a semântica já validou)
/// e todos os braços terminam em `return`.
fn matchAlwaysReturns(match: ast.Match) bool {
    if (!match.exhaustive) return false;
    if (match.arms.len == 0) return false;
    for (match.arms) |arm| {
        if (!blockAlwaysReturnsInner(arm.body, true)) return false;
    }
    return true;
}

fn ifAlwaysReturns(cond: ast.If, trust_match: bool) bool {
    const els = cond.els orelse return false;
    if (!blockAlwaysReturnsInner(cond.then, trust_match)) return false;
    return switch (els) {
        .block => |block| blockAlwaysReturnsInner(block, trust_match),
        .cond => |nested| ifAlwaysReturns(nested.*, trust_match),
    };
}

fn knownModule(path: []const u8) bool {
    const known = [_][]const u8{
        "kyn::core",
        "kyn::std",
        "kyn::std::io",
        "kyn::std::thread",
        "kyn::std::net",
        "core",
        "std",
        "std::io",
        "std::thread",
        "std::net",
    };
    for (known) |item| {
        if (std.mem.eql(u8, item, path)) return true;
    }
    return false;
}

test "intFits respects signedness and width" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const table = try types.Table.init(a);

    try std.testing.expect(intFits(255, table.u8_id, table));
    try std.testing.expect(!intFits(256, table.u8_id, table));
    try std.testing.expect(!intFits(-1, table.u8_id, table));
    try std.testing.expect(intFits(-128, table.i8_id, table));
    try std.testing.expect(!intFits(128, table.i8_id, table));
}

test "blockAlwaysReturns follows if/else" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var ret_stmts = [_]ast.Stmt{.{ .ret = .{ .value = null, .span = .{} } }};
    const returning = ast.Block{ .stmts = &ret_stmts, .span = .{} };
    try std.testing.expect(blockAlwaysReturnsInner(returning, true));
    try std.testing.expect(!blockAlwaysReturnsInner(.{ .stmts = &.{}, .span = .{} }, true));

    // `match` exaustivo cujos braços retornam encerra a função para a
    // semântica, mas não para o compilador C (`alwaysReturnsForC`).
    var arm_block = [_]ast.Stmt{.{ .ret = .{ .value = null, .span = .{} } }};
    var arms = [_]ast.MatchArm{.{
        .variant = "A",
        .head = null,
        .span = .{},
        .body = .{ .stmts = &arm_block, .span = .{} },
    }};
    var match_stmts = [_]ast.Stmt{.{ .match_ = .{
        .subject = .{ .kind = .{ .ident = "x" }, .span = .{} },
        .arms = &arms,
        .span = .{},
        .exhaustive = true,
    } }};
    const match_block = ast.Block{ .stmts = &match_stmts, .span = .{} };
    try std.testing.expect(alwaysReturns(match_block));
    try std.testing.expect(!alwaysReturnsForC(match_block));

    var if_stmts = [_]ast.Stmt{.{ .cond = .{
        .cond = .{ .kind = .{ .bool_lit = true }, .span = .{} },
        .then = returning,
        .els = .{ .block = returning },
        .span = .{},
    } }};
    _ = a;
    try std.testing.expect(blockAlwaysReturnsInner(.{ .stmts = &if_stmts, .span = .{} }, true));
}
