//! src/parser/parser.zig — Parser recursivo-descendente do Kyn.
//!
//! Cobre o subconjunto implementado da linguagem:
//! imports, `fn`, `extern fn`, `struct`, `enum`, `impl`, atributos `#[...]`,
//! blocos `unsafe`, `let`/`var`, atribuição, `if`/`else`, `while`,
//! `for i in a..b`, `return`/`break`/`continue` e expressões com precedência
//! completa (incluindo chamadas, campos, caminhos `A::b`, casts `as T`,
//! referências e dereferência).
//!
//! Recuperação de erro: ao falhar em um statement o parser registra o
//! diagnóstico e avança até o próximo `;` ou `}`, permitindo relatar vários
//! problemas de uma só vez. Nada aqui aloca fora da arena recebida.

const std = @import("std");
const lex = @import("../lexer/lexer.zig");
const ast = @import("../ast/ast.zig");
const diag = @import("../diag.zig");

pub const Error = error{ParseFailed} || std.mem.Allocator.Error;

pub const Parser = struct {
    alloc: std.mem.Allocator,
    source: []const u8,
    tokens: []const lex.Token,
    diags: *diag.List,
    pos: usize = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        source: []const u8,
        tokens: []const lex.Token,
        diags: *diag.List,
    ) Parser {
        return .{ .alloc = alloc, .source = source, .tokens = tokens, .diags = diags };
    }

    // ---------------------------------------------------------------- tokens

    fn peek(self: *Parser) lex.Token {
        return self.tokens[@min(self.pos, self.tokens.len - 1)];
    }

    fn peekAt(self: *Parser, offset: usize) lex.Token {
        return self.tokens[@min(self.pos + offset, self.tokens.len - 1)];
    }

    fn at(self: *Parser, kind: lex.Kind) bool {
        return self.peek().kind == kind;
    }

    fn eat(self: *Parser, kind: lex.Kind) ?lex.Token {
        if (self.at(kind)) {
            const tok = self.peek();
            self.pos += 1;
            return tok;
        }
        return null;
    }

    fn expect(self: *Parser, kind: lex.Kind) Error!lex.Token {
        if (self.eat(kind)) |tok| return tok;
        const tok = self.peek();
        return self.fail(tok.span, "esperava `{s}`, encontrado `{s}`", .{ kind.text(), tokenLabel(tok) });
    }

    fn expectIdent(self: *Parser) Error!lex.Token {
        // `self` é palavra-chave, mas é um nome de parâmetro válido em métodos.
        if (self.at(.ident) or self.at(.kw_self)) {
            const tok = self.peek();
            self.pos += 1;
            return tok;
        }
        const tok = self.peek();
        return self.fail(tok.span, "esperava um identificador, encontrado `{s}`", .{tokenLabel(tok)});
    }

    fn fail(self: *Parser, span: diag.Span, comptime fmt: []const u8, args: anytype) Error {
        self.diags.add(self.alloc, .{
            .code = .syntax,
            .message = std.fmt.allocPrint(self.alloc, fmt, args) catch "erro de sintaxe",
            .span = span,
        }) catch {};
        return error.ParseFailed;
    }

    fn failHelp(
        self: *Parser,
        span: diag.Span,
        comptime fmt: []const u8,
        args: anytype,
        help: ?[]const u8,
    ) Error {
        self.diags.add(self.alloc, .{
            .code = .syntax,
            .message = std.fmt.allocPrint(self.alloc, fmt, args) catch "erro de sintaxe",
            .span = span,
            .help = help,
        }) catch {};
        return error.ParseFailed;
    }

    /// Avança até um ponto seguro para continuar o parsing. Consome ao menos
    /// um token para garantir progresso e evitar laço infinito na recuperação.
    fn synchronize(self: *Parser) void {
        if (!self.at(.eof)) self.pos += 1;
        while (!self.at(.eof)) {
            if (self.at(.semicolon)) {
                self.pos += 1;
                return;
            }
            if (self.at(.rbrace)) return;
            self.pos += 1;
        }
    }

    // --------------------------------------------------------------- programa

    pub fn parseProgram(self: *Parser) Error!ast.Program {
        var imports: std.ArrayList(ast.Import) = .empty;
        var decls: std.ArrayList(ast.Decl) = .empty;

        while (!self.at(.eof)) {
            if (self.at(.kw_import)) {
                imports.append(self.alloc, try self.parseImport()) catch return error.ParseFailed;
                continue;
            }
            const before = self.pos;
            self.parseDecl(&decls) catch {
                self.synchronize();
                // Garantia extra de progresso: nunca reler o mesmo token.
                if (self.pos == before and !self.at(.eof)) self.pos += 1;
                continue;
            };
        }

        return .{
            .imports = imports.items,
            .decls = decls.items,
            .span = .{ .start = 0, .end = @intCast(self.source.len) },
        };
    }

    fn parseImport(self: *Parser) Error!ast.Import {
        const start_tok = try self.expect(.kw_import);
        const start = start_tok.span.start;

        var parts: std.ArrayList([]const u8) = .empty;
        if (self.at(.string_lit)) {
            const tok = self.peek();
            self.pos += 1;
            parts.append(self.alloc, tok.text) catch return error.ParseFailed;
        } else {
            const first = try self.expectIdent();
            parts.append(self.alloc, first.text) catch return error.ParseFailed;
            while (self.at(.dot) or self.at(.colon) or self.at(.coloncolon)) {
                self.pos += 1;
                const next = try self.expectIdent();
                parts.append(self.alloc, next.text) catch return error.ParseFailed;
            }
        }
        const end_tok = try self.expect(.semicolon);

        // Normaliza `std.io`, `std/io` e `std::io` para `std::io`.
        var normalized: std.ArrayList(u8) = .empty;
        for (parts.items, 0..) |part, i| {
            if (i > 0) normalized.appendSlice(self.alloc, "::") catch return error.ParseFailed;
            var it = std.mem.splitScalar(u8, part, '/');
            var first_seg = true;
            while (it.next()) |seg| {
                const trimmed = stripKynSuffix(seg);
                if (trimmed.len == 0) continue;
                if (!first_seg) normalized.appendSlice(self.alloc, "::") catch return error.ParseFailed;
                normalized.appendSlice(self.alloc, trimmed) catch return error.ParseFailed;
                first_seg = false;
            }
        }

        return .{
            .path = normalized.items,
            .span = .{ .start = start, .end = end_tok.span.end },
        };
    }

    fn parseDecl(self: *Parser, decls: *std.ArrayList(ast.Decl)) Error!void {
        const attrs = try self.parseAttrs();
        const is_pub = self.eat(.kw_pub) != null;

        if (self.eat(.kw_fn)) |tok| {
            decls.append(self.alloc, .{ .func = try self.parseFunc(tok, attrs, is_pub) }) catch return error.ParseFailed;
            return;
        }
        if (self.at(.kw_extern)) {
            self.pos += 1;
            const fn_tok = try self.expect(.kw_fn);
            if (attrs.len > 0) {
                return self.fail(attrs[0].span, "atributos não são permitidos em `extern fn`", .{});
            }
            decls.append(self.alloc, .{ .extern_func = try self.parseExternFunc(fn_tok) }) catch return error.ParseFailed;
            return;
        }
        if (self.eat(.kw_struct)) |tok| {
            decls.append(self.alloc, .{ .structure = try self.parseStruct(tok, attrs, is_pub) }) catch return error.ParseFailed;
            return;
        }
        if (self.eat(.kw_enum)) |tok| {
            decls.append(self.alloc, .{ .enumeration = try self.parseEnum(tok, attrs, is_pub) }) catch return error.ParseFailed;
            return;
        }
        if (self.eat(.kw_impl)) |tok| {
            if (is_pub) return self.fail(tok.span, "`impl` não pode ser marcado como `pub`", .{});
            decls.append(self.alloc, .{ .impl = try self.parseImpl(tok) }) catch return error.ParseFailed;
            return;
        }

        const tok = self.peek();
        return self.failHelp(
            tok.span,
            "esperava uma declaração (`fn`, `struct`, `enum`, `impl`, `extern fn` ou `import`), encontrado `{s}`",
            .{tokenLabel(tok)},
            "declarações de nível superior não incluem `let`/`var`; envolva o código em uma função",
        );
    }

    fn parseAttrs(self: *Parser) Error![]const ast.Attr {
        var attrs: std.ArrayList(ast.Attr) = .empty;
        while (self.at(.hash)) {
            const hash_tok = self.peek();
            self.pos += 1;
            _ = try self.expect(.lbracket);
            const name_tok = try self.expectIdent();
            var args: std.ArrayList([]const u8) = .empty;
            if (self.eat(.lparen) != null) {
                while (!self.at(.rparen) and !self.at(.eof)) {
                    const arg_tok = self.peek();
                    self.pos += 1;
                    args.append(self.alloc, arg_tok.text) catch return error.ParseFailed;
                    if (self.eat(.comma) == null) break;
                }
                _ = try self.expect(.rparen);
            }
            const end_tok = try self.expect(.rbracket);
            attrs.append(self.alloc, .{
                .name = name_tok.text,
                .args = args.items,
                .span = .{ .start = hash_tok.span.start, .end = end_tok.span.end },
            }) catch return error.ParseFailed;
        }
        return attrs.items;
    }

    fn parseParams(self: *Parser) Error!struct { params: []const ast.Param, variadic: bool } {
        var params: std.ArrayList(ast.Param) = .empty;
        var variadic = false;
        _ = try self.expect(.lparen);
        while (!self.at(.rparen) and !self.at(.eof)) {
            if (self.at(.dotdot) or (self.at(.dot) and self.peekAt(1).kind == .dot)) {
                // `...` — varargs em declarações `extern fn`.
                self.pos += 1;
                if (self.at(.dot)) self.pos += 1;
                if (self.at(.dot)) self.pos += 1;
                variadic = true;
                break;
            }
            const name_tok = try self.expectIdent();
            _ = try self.expect(.colon);
            const ty = try self.parseType();
            params.append(self.alloc, .{
                .name = name_tok.text,
                .name_span = name_tok.span,
                .ty = ty,
                .span = .{ .start = name_tok.span.start, .end = ty.spanOf().end },
            }) catch return error.ParseFailed;
            if (self.eat(.comma) == null) break;
        }
        _ = try self.expect(.rparen);
        return .{ .params = params.items, .variadic = variadic };
    }

    fn parseRetType(self: *Parser) Error!?*ast.TypeExpr {
        if (self.eat(.arrow) == null) return null;
        return try self.parseType();
    }

    fn parseFunc(self: *Parser, fn_tok: lex.Token, attrs: []const ast.Attr, is_pub: bool) Error!ast.Func {
        const name_tok = try self.expectIdent();
        const parsed = try self.parseParams();
        if (parsed.variadic) {
            return self.fail(name_tok.span, "varargs só são permitidos em `extern fn`", .{});
        }
        const ret = try self.parseRetType();
        const body = try self.parseBlock();
        return .{
            .name = name_tok.text,
            .name_span = name_tok.span,
            .span = .{ .start = fn_tok.span.start, .end = body.span.end },
            .attrs = attrs,
            .is_pub = is_pub,
            .params = parsed.params,
            .ret = ret,
            .body = body,
        };
    }

    fn parseExternFunc(self: *Parser, fn_tok: lex.Token) Error!ast.ExternFunc {
        const name_tok = try self.expectIdent();
        const parsed = try self.parseParams();
        const ret = try self.parseRetType();
        const end_tok = try self.expect(.semicolon);
        return .{
            .name = name_tok.text,
            .name_span = name_tok.span,
            .span = .{ .start = fn_tok.span.start, .end = end_tok.span.end },
            .params = parsed.params,
            .ret = ret,
            .is_variadic = parsed.variadic,
        };
    }

    fn parseStruct(self: *Parser, tok: lex.Token, attrs: []const ast.Attr, is_pub: bool) Error!ast.StructDecl {
        const name_tok = try self.expectIdent();
        _ = try self.expect(.lbrace);
        var fields: std.ArrayList(ast.Field) = .empty;
        while (!self.at(.rbrace) and !self.at(.eof)) {
            const field_attrs = try self.parseAttrs();
            if (field_attrs.len > 0) {
                return self.fail(field_attrs[0].span, "atributos em campos de `struct` ainda não são suportados", .{});
            }
            _ = self.eat(.kw_pub);
            const field_name = try self.expectIdent();
            _ = try self.expect(.colon);
            const ty = try self.parseType();
            fields.append(self.alloc, .{
                .name = field_name.text,
                .name_span = field_name.span,
                .ty = ty,
                .span = .{ .start = field_name.span.start, .end = ty.spanOf().end },
            }) catch return error.ParseFailed;
            if (self.eat(.comma) == null and !self.at(.rbrace)) {
                return self.fail(self.peek().span, "esperava `,` ou `}}` após o campo `{s}`", .{field_name.text});
            }
        }
        const end_tok = try self.expect(.rbrace);
        return .{
            .name = name_tok.text,
            .name_span = name_tok.span,
            .span = .{ .start = tok.span.start, .end = end_tok.span.end },
            .attrs = attrs,
            .is_pub = is_pub,
            .fields = fields.items,
        };
    }

    fn parseEnum(self: *Parser, tok: lex.Token, attrs: []const ast.Attr, is_pub: bool) Error!ast.EnumDecl {
        const name_tok = try self.expectIdent();
        _ = try self.expect(.lbrace);
        var variants: std.ArrayList(ast.EnumVariant) = .empty;
        while (!self.at(.rbrace) and !self.at(.eof)) {
            const variant_tok = try self.expectIdent();
            variants.append(self.alloc, .{ .name = variant_tok.text, .span = variant_tok.span }) catch return error.ParseFailed;
            if (self.eat(.comma) == null and !self.at(.rbrace)) {
                return self.fail(self.peek().span, "esperava `,` ou `}}` após a variante `{s}`", .{variant_tok.text});
            }
        }
        const end_tok = try self.expect(.rbrace);
        return .{
            .name = name_tok.text,
            .name_span = name_tok.span,
            .span = .{ .start = tok.span.start, .end = end_tok.span.end },
            .attrs = attrs,
            .is_pub = is_pub,
            .variants = variants.items,
        };
    }

    fn parseImpl(self: *Parser, tok: lex.Token) Error!ast.ImplDecl {
        const target_tok = try self.expectIdent();
        _ = try self.expect(.lbrace);
        var methods: std.ArrayList(ast.Func) = .empty;
        while (!self.at(.rbrace) and !self.at(.eof)) {
            const attrs = try self.parseAttrs();
            const is_pub = self.eat(.kw_pub) != null;
            const fn_tok = self.eat(.kw_fn) orelse {
                return self.fail(self.peek().span, "esperava `fn` dentro de `impl`", .{});
            };
            methods.append(self.alloc, try self.parseFunc(fn_tok, attrs, is_pub)) catch return error.ParseFailed;
        }
        const end_tok = try self.expect(.rbrace);
        return .{
            .target = target_tok.text,
            .target_span = target_tok.span,
            .span = .{ .start = tok.span.start, .end = end_tok.span.end },
            .methods = methods.items,
        };
    }

    // ------------------------------------------------------------------ tipos

    fn parseType(self: *Parser) Error!*ast.TypeExpr {
        if (self.at(.amp)) {
            const tok = self.peek();
            self.pos += 1;
            const mutable = self.eat(.kw_mut) != null;
            const inner = try self.parseType();
            const node = try self.alloc.create(ast.TypeExpr);
            node.* = .{ .ref_ = .{ .inner = inner, .mutable = mutable, .span = .{ .start = tok.span.start, .end = inner.spanOf().end } } };
            return node;
        }
        if (self.at(.star)) {
            const tok = self.peek();
            self.pos += 1;
            var is_const = false;
            if (self.at(.ident) and std.mem.eql(u8, self.peek().text, "const")) {
                self.pos += 1;
                is_const = true;
            }
            const inner = try self.parseType();
            const node = try self.alloc.create(ast.TypeExpr);
            node.* = .{ .ptr = .{ .inner = inner, .is_const = is_const, .span = .{ .start = tok.span.start, .end = inner.spanOf().end } } };
            return node;
        }
        if (self.at(.lbracket)) {
            const tok = self.peek();
            self.pos += 1;
            // `[*]T` continua sendo aceito como alias de ponteiro cru.
            if (self.eat(.star) != null) {
                _ = try self.expect(.rbracket);
                const inner = try self.parseType();
                const node = try self.alloc.create(ast.TypeExpr);
                node.* = .{ .ptr = .{ .inner = inner, .is_const = false, .span = .{ .start = tok.span.start, .end = inner.spanOf().end } } };
                return node;
            }
            // `[N]T` — array de tamanho fixo.
            if (self.at(.int_lit)) {
                const count_tok = self.peek();
                self.pos += 1;
                const value = parseIntLiteral(count_tok.text) orelse
                    return self.fail(count_tok.span, "tamanho de array `{s}` é inválido", .{count_tok.text});
                if (value < 1) {
                    return self.failHelp(count_tok.span, "array precisa ter tamanho maior que zero", .{}, "use `[]T` para uma coleção de tamanho dinâmico");
                }
                _ = try self.expect(.rbracket);
                const inner = try self.parseType();
                const node = try self.alloc.create(ast.TypeExpr);
                node.* = .{ .array = .{ .inner = inner, .count = @intCast(value), .span = .{ .start = tok.span.start, .end = inner.spanOf().end } } };
                return node;
            }
            // `[]T` ou `[]const T` — slice.
            _ = try self.expect(.rbracket);
            var is_const = false;
            if (self.at(.ident) and std.mem.eql(u8, self.peek().text, "const")) {
                self.pos += 1;
                is_const = true;
            }
            const inner = try self.parseType();
            const node = try self.alloc.create(ast.TypeExpr);
            node.* = .{ .slice = .{ .inner = inner, .is_const = is_const, .span = .{ .start = tok.span.start, .end = inner.spanOf().end } } };
            return node;
        }

        const tok = self.peek();
        if (tok.kind != .ident and !tok.kind.isKeyword()) {
            return self.fail(tok.span, "esperava um tipo, encontrado `{s}`", .{tokenLabel(tok)});
        }
        self.pos += 1;
        if (ast.PrimKind.fromText(tok.text)) |prim| {
            const node = try self.alloc.create(ast.TypeExpr);
            node.* = .{ .prim = .{ .kind = prim, .span = tok.span } };
            return node;
        }
        const node = try self.alloc.create(ast.TypeExpr);
        node.* = .{ .named = .{ .name = tok.text, .span = tok.span } };
        return node;
    }

    // ------------------------------------------------------------- statements

    fn parseBlock(self: *Parser) Error!ast.Block {
        const open_tok = try self.expect(.lbrace);
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        while (!self.at(.rbrace) and !self.at(.eof)) {
            if (self.parseStmt(&stmts)) |_| {
                continue;
            } else |_| {
                self.synchronize();
            }
        }
        const end_tok = try self.expect(.rbrace);
        return .{ .stmts = stmts.items, .span = .{ .start = open_tok.span.start, .end = end_tok.span.end } };
    }

    fn parseStmt(self: *Parser, stmts: *std.ArrayList(ast.Stmt)) Error!void {
        if (self.at(.kw_let) or self.at(.kw_var)) {
            stmts.append(self.alloc, .{ .binding = try self.parseBinding() }) catch return error.ParseFailed;
            return;
        }
        if (self.at(.kw_return)) {
            stmts.append(self.alloc, .{ .ret = try self.parseReturn() }) catch return error.ParseFailed;
            return;
        }
        if (self.at(.kw_if)) {
            stmts.append(self.alloc, .{ .cond = try self.parseIf() }) catch return error.ParseFailed;
            return;
        }
        if (self.at(.kw_while)) {
            stmts.append(self.alloc, .{ .loop = try self.parseWhile() }) catch return error.ParseFailed;
            return;
        }
        if (self.at(.kw_for)) {
            if (self.forUsesRange()) {
                stmts.append(self.alloc, .{ .range_for = try self.parseRangeFor() }) catch return error.ParseFailed;
            } else {
                stmts.append(self.alloc, .{ .collection_for = try self.parseCollectionFor() }) catch return error.ParseFailed;
            }
            return;
        }
        if (self.at(.kw_match)) {
            stmts.append(self.alloc, .{ .match_ = try self.parseMatch() }) catch return error.ParseFailed;
            return;
        }
        if (self.at(.kw_break)) {
            const tok = self.peek();
            self.pos += 1;
            _ = try self.expect(.semicolon);
            stmts.append(self.alloc, .{ .break_ = tok.span }) catch return error.ParseFailed;
            return;
        }
        if (self.at(.kw_continue)) {
            const tok = self.peek();
            self.pos += 1;
            _ = try self.expect(.semicolon);
            stmts.append(self.alloc, .{ .continue_ = tok.span }) catch return error.ParseFailed;
            return;
        }
        if (self.at(.kw_unsafe)) {
            const tok = self.peek();
            self.pos += 1;
            const block = try self.parseBlock();
            stmts.append(self.alloc, .{ .unsafe_block = block }) catch return error.ParseFailed;
            _ = tok;
            return;
        }
        if (self.at(.lbrace)) {
            stmts.append(self.alloc, .{ .block = try self.parseBlock() }) catch return error.ParseFailed;
            return;
        }

        const expr = try self.parseExpr(0);
        const assign_op: ?ast.AssignOp = if (self.eat(.assign) != null)
            .assign
        else if (self.eat(.plus_assign) != null)
            .add
        else if (self.eat(.minus_assign) != null)
            .sub
        else if (self.eat(.star_assign) != null)
            .mul
        else if (self.eat(.slash_assign) != null)
            .div
        else if (self.eat(.percent_assign) != null)
            .rem
        else
            null;

        if (assign_op) |op| {
            const value = try self.parseExpr(0);
            const end = try self.expect(.semicolon);
            stmts.append(self.alloc, .{ .assign = .{
                .target = expr.*,
                .op = op,
                .value = value.*,
                .span = .{ .start = expr.span.start, .end = end.span.end },
            } }) catch return error.ParseFailed;
            return;
        }

        const end = try self.expect(.semicolon);
        stmts.append(self.alloc, .{ .expr = .{
            .kind = expr.kind,
            .span = .{ .start = expr.span.start, .end = end.span.end },
        } }) catch return error.ParseFailed;
    }

    fn parseBinding(self: *Parser) Error!ast.Binding {
        const start_tok = self.peek();
        self.pos += 1; // let | var
        var mutable = start_tok.kind == .kw_var;
        if (self.eat(.kw_mut) != null) mutable = true;

        const name_tok = try self.expectIdent();
        var ty: ?*ast.TypeExpr = null;
        if (self.eat(.colon) != null) ty = try self.parseType();
        _ = try self.expect(.assign);
        const initializer = try self.parseExpr(0);
        const end_tok = try self.expect(.semicolon);
        return .{
            .name = name_tok.text,
            .name_span = name_tok.span,
            .span = .{ .start = start_tok.span.start, .end = end_tok.span.end },
            .mutable = mutable,
            .ty = ty,
            .init = initializer.*,
        };
    }

    fn parseReturn(self: *Parser) Error!ast.Return {
        const tok = self.peek();
        self.pos += 1;
        var value: ?ast.Expr = null;
        if (!self.at(.semicolon)) {
            const expr = try self.parseExpr(0);
            value = expr.*;
        }
        const end_tok = try self.expect(.semicolon);
        return .{ .value = value, .span = .{ .start = tok.span.start, .end = end_tok.span.end } };
    }

    fn parseIf(self: *Parser) Error!ast.If {
        const tok = self.peek();
        self.pos += 1;
        const cond = try self.parseExpr(0);
        const then_block = try self.parseBlock();
        var els: ?ast.Else = null;
        if (self.eat(.kw_else) != null) {
            if (self.at(.kw_if)) {
                const nested = try self.parseIf();
                const node = try self.alloc.create(ast.If);
                node.* = nested;
                els = .{ .cond = node };
            } else {
                els = .{ .block = try self.parseBlock() };
            }
        }
        const end = if (els) |e| switch (e) {
            .block => |b| b.span.end,
            .cond => |c| c.span.end,
        } else then_block.span.end;
        return .{
            .cond = cond.*,
            .then = then_block,
            .els = els,
            .span = .{ .start = tok.span.start, .end = end },
        };
    }

    fn parseWhile(self: *Parser) Error!ast.While {
        const tok = self.peek();
        self.pos += 1;
        const cond = try self.parseExpr(0);
        const body = try self.parseBlock();
        return .{
            .cond = cond.*,
            .body = body,
            .span = .{ .start = tok.span.start, .end = body.span.end },
        };
    }

    fn parseRangeFor(self: *Parser) Error!ast.RangeFor {
        const tok = self.peek();
        self.pos += 1;
        const name_tok = try self.expectIdent();
        _ = try self.expect(.kw_in);
        const start = try self.parseExpr(0);
        if (self.eat(.dotdot) == null) {
            return self.failHelp(self.peek().span, "esperava `..` em um laço `for`", .{}, "a forma suportada é `for i in inicio..fim {{ ... }}`");
        }
        const end = try self.parseExpr(0);
        const body = try self.parseBlock();
        return .{
            .var_name = name_tok.text,
            .var_span = name_tok.span,
            .start = start.*,
            .end = end.*,
            .body = body,
            .span = .{ .start = tok.span.start, .end = body.span.end },
        };
    }

    /// `match sujeito { Padrao => { ... }, ... }`.
    /// Padrões aceitos: `Enum::Variante`, `Variante` e o curinga `_`.
    fn parseMatch(self: *Parser) Error!ast.Match {
        const tok = self.peek();
        self.pos += 1;
        const subject = try self.parseExpr(0);
        _ = try self.expect(.lbrace);
        var arms: std.ArrayList(ast.MatchArm) = .empty;
        while (!self.at(.rbrace) and !self.at(.eof)) {
            const first = try self.expectIdent();
            var head: ?[]const u8 = null;
            var variant: ?[]const u8 = null;
            if (self.eat(.coloncolon) != null) {
                const second = try self.expectIdent();
                head = first.text;
                variant = second.text;
            } else if (!std.mem.eql(u8, first.text, "_")) {
                variant = first.text;
            }
            if (self.eat(.fat_arrow) == null) {
                return self.failHelp(
                    self.peek().span,
                    "esperava `=>` depois do padrão do `match`",
                    .{},
                    "a forma é `Enum::Variante => {{ ... }}`",
                );
            }
            const body = try self.parseBlock();
            arms.append(self.alloc, .{
                .variant = variant,
                .head = head,
                .span = .{ .start = first.span.start, .end = first.span.end },
                .body = body,
            }) catch return error.ParseFailed;
            _ = self.eat(.comma);
        }
        const end_tok = try self.expect(.rbrace);
        if (arms.items.len == 0) {
            return self.failHelp(tok.span, "`match` precisa de pelo menos um braço", .{}, "adicione `Padrao => {{ ... }}` ou o curinga `_ => {{ ... }}`");
        }
        return .{
            .subject = subject.*,
            .arms = arms.items,
            .span = .{ .start = tok.span.start, .end = end_tok.span.end },
        };
    }

    fn parseCollectionFor(self: *Parser) Error!ast.CollectionFor {
        const tok = self.peek();
        self.pos += 1;
        const name_tok = try self.expectIdent();
        _ = try self.expect(.kw_in);
        const collection = try self.parseExpr(0);
        const body = try self.parseBlock();
        return .{
            .var_name = name_tok.text,
            .var_span = name_tok.span,
            .collection = collection.*,
            .body = body,
            .span = .{ .start = tok.span.start, .end = body.span.end },
        };
    }

    /// Distingue `for i in a..b` de `for x in colecao` sem backtrack: varre os
    /// tokens até o `{` do corpo procurando um `..` fora de delimitadores.
    fn forUsesRange(self: *Parser) bool {
        var i: usize = self.pos;
        var depth: usize = 0;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].kind) {
                .lparen, .lbracket => depth += 1,
                .rparen, .rbracket => {
                    if (depth > 0) depth -= 1;
                },
                .dotdot => if (depth == 0) return true,
                .lbrace, .eof => return false,
                else => {},
            }
        }
        return false;
    }

    // ------------------------------------------------------------ expressões

    /// Precedência por "binding power": quanto maior o número, mais forte o
    /// operador se liga. Todos são associativos à esquerda (`right = left + 1`).
    fn binOpOf(kind: lex.Kind) ?struct { op: ast.BinOp, left: u8, right: u8 } {
        return switch (kind) {
            .pipepipe => .{ .op = .or_, .left = 1, .right = 2 },
            .ampamp => .{ .op = .and_, .left = 3, .right = 4 },
            .pipe => .{ .op = .bit_or, .left = 5, .right = 6 },
            .caret => .{ .op = .bit_xor, .left = 7, .right = 8 },
            .amp => .{ .op = .bit_and, .left = 9, .right = 10 },
            .eqeq => .{ .op = .eq, .left = 11, .right = 12 },
            .ne => .{ .op = .ne, .left = 11, .right = 12 },
            .lt => .{ .op = .lt, .left = 13, .right = 14 },
            .le => .{ .op = .le, .left = 13, .right = 14 },
            .gt => .{ .op = .gt, .left = 13, .right = 14 },
            .ge => .{ .op = .ge, .left = 13, .right = 14 },
            .shl => .{ .op = .shl, .left = 15, .right = 16 },
            .shr => .{ .op = .shr, .left = 15, .right = 16 },
            .plus => .{ .op = .add, .left = 17, .right = 18 },
            .minus => .{ .op = .sub, .left = 17, .right = 18 },
            .star => .{ .op = .mul, .left = 19, .right = 20 },
            .slash => .{ .op = .div, .left = 19, .right = 20 },
            .percent => .{ .op = .rem, .left = 19, .right = 20 },
            else => null,
        };
    }

    pub fn parseExpr(self: *Parser, min_bp: u8) Error!*ast.Expr {
        var lhs = try self.parseUnary();

        while (true) {
            // Pós-fixos: chamada, campo e cast.
            if (self.at(.lparen)) {
                const call = try self.parseCallArgs();
                const node = try ast.Expr.make(self.alloc, .{ .call = .{ .callee = lhs, .args = call.args } }, .{
                    .start = lhs.span.start,
                    .end = call.end,
                });
                lhs = node;
                continue;
            }
            if (self.at(.dot)) {
                self.pos += 1;
                const name_tok = try self.expectIdent();
                const node = try ast.Expr.make(self.alloc, .{ .field = .{ .object = lhs, .name = name_tok.text } }, .{
                    .start = lhs.span.start,
                    .end = name_tok.span.end,
                });
                lhs = node;
                continue;
            }
            if (self.at(.lbracket)) {
                const open_tok = self.peek();
                self.pos += 1;
                // `[..fim]` e `[..]` começam direto no operador de intervalo.
                var start: ?*ast.Expr = null;
                if (!self.at(.dotdot)) start = try self.parseExpr(0);
                if (self.eat(.dotdot) != null) {
                    var end: ?*ast.Expr = null;
                    if (!self.at(.rbracket)) end = try self.parseExpr(0);
                    const close_tok = try self.expect(.rbracket);
                    const node = try ast.Expr.make(
                        self.alloc,
                        .{ .slice_range = .{ .object = lhs, .start = start, .end = end } },
                        .{ .start = lhs.span.start, .end = close_tok.span.end },
                    );
                    lhs = node;
                    continue;
                }
                const index_expr = start orelse
                    return self.fail(open_tok.span, "esperava um índice dentro de `[]`", .{});
                const close_tok = try self.expect(.rbracket);
                const node = try ast.Expr.make(
                    self.alloc,
                    .{ .index = .{ .object = lhs, .index = index_expr } },
                    .{ .start = lhs.span.start, .end = close_tok.span.end },
                );
                lhs = node;
                continue;
            }
            if (self.at(.kw_as)) {
                self.pos += 1;
                const ty = try self.parseType();
                const node = try ast.Expr.make(self.alloc, .{ .cast = .{ .operand = lhs, .ty = ty } }, .{
                    .start = lhs.span.start,
                    .end = ty.spanOf().end,
                });
                lhs = node;
                continue;
            }

            const op_info = binOpOf(self.peek().kind) orelse break;
            if (op_info.left < min_bp) break;
            self.pos += 1;
            const rhs = try self.parseExpr(op_info.right);
            lhs = try ast.Expr.make(self.alloc, .{ .binary = .{ .op = op_info.op, .lhs = lhs, .rhs = rhs } }, .{
                .start = lhs.span.start,
                .end = rhs.span.end,
            });
        }

        return lhs;
    }

    fn parseUnary(self: *Parser) Error!*ast.Expr {
        if (self.at(.minus)) {
            const tok = self.peek();
            self.pos += 1;
            const operand = try self.parseUnary();
            return ast.Expr.make(self.alloc, .{ .unary = .{ .op = .neg, .operand = operand } }, .{
                .start = tok.span.start,
                .end = operand.span.end,
            });
        }
        if (self.at(.bang)) {
            const tok = self.peek();
            self.pos += 1;
            const operand = try self.parseUnary();
            return ast.Expr.make(self.alloc, .{ .unary = .{ .op = .not, .operand = operand } }, .{
                .start = tok.span.start,
                .end = operand.span.end,
            });
        }
        if (self.at(.tilde)) {
            const tok = self.peek();
            self.pos += 1;
            const operand = try self.parseUnary();
            return ast.Expr.make(self.alloc, .{ .unary = .{ .op = .bit_not, .operand = operand } }, .{
                .start = tok.span.start,
                .end = operand.span.end,
            });
        }
        if (self.at(.star)) {
            const tok = self.peek();
            self.pos += 1;
            const operand = try self.parseUnary();
            return ast.Expr.make(self.alloc, .{ .deref = operand }, .{
                .start = tok.span.start,
                .end = operand.span.end,
            });
        }
        if (self.at(.amp)) {
            const tok = self.peek();
            self.pos += 1;
            const mutable = self.eat(.kw_mut) != null;
            const operand = try self.parseUnary();
            return ast.Expr.make(self.alloc, .{ .ref_of = .{ .operand = operand, .mutable = mutable } }, .{
                .start = tok.span.start,
                .end = operand.span.end,
            });
        }
        return self.parsePrimary();
    }

    fn parseCallArgs(self: *Parser) Error!struct { args: []const *ast.Expr, end: u32 } {
        _ = try self.expect(.lparen);
        var args: std.ArrayList(*ast.Expr) = .empty;
        while (!self.at(.rparen) and !self.at(.eof)) {
            const arg = try self.parseExpr(0);
            args.append(self.alloc, arg) catch return error.ParseFailed;
            if (self.eat(.comma) == null) break;
        }
        const end_tok = try self.expect(.rparen);
        return .{ .args = args.items, .end = end_tok.span.end };
    }

    fn looksLikeStructLiteral(self: *Parser) bool {
        // `Nome {` só é literal de struct se vier `}` ou `campo:` em seguida.
        if (!self.at(.lbrace)) return false;
        const next = self.peekAt(1);
        if (next.kind == .rbrace) return true;
        return next.kind == .ident and self.peekAt(2).kind == .colon;
    }

    fn parsePrimary(self: *Parser) Error!*ast.Expr {
        const tok = self.peek();
        switch (tok.kind) {
            .lbracket => {
                self.pos += 1;
                var items: std.ArrayList(*ast.Expr) = .empty;
                while (!self.at(.rbracket) and !self.at(.eof)) {
                    const item = try self.parseExpr(0);
                    items.append(self.alloc, item) catch return error.ParseFailed;
                    if (self.eat(.comma) == null) break;
                }
                const end_tok = try self.expect(.rbracket);
                return ast.Expr.make(self.alloc, .{ .array_lit = items.items }, .{
                    .start = tok.span.start,
                    .end = end_tok.span.end,
                });
            },
            .int_lit => {
                self.pos += 1;
                const value = parseIntLiteral(tok.text) orelse {
                    return self.fail(tok.span, "literal inteiro `{s}` é inválido ou excede i128", .{tok.text});
                };
                return ast.Expr.make(self.alloc, .{ .int_lit = value }, tok.span);
            },
            .float_lit => {
                self.pos += 1;
                const value = parseFloatLiteral(tok.text) orelse {
                    return self.fail(tok.span, "literal de ponto flutuante `{s}` é inválido", .{tok.text});
                };
                return ast.Expr.make(self.alloc, .{ .float_lit = value }, tok.span);
            },
            .string_lit => {
                self.pos += 1;
                return ast.Expr.make(self.alloc, .{ .string_lit = tok.text }, tok.span);
            },
            .char_lit => {
                self.pos += 1;
                return ast.Expr.make(self.alloc, .{ .char_lit = tok.text[0] }, tok.span);
            },
            .kw_true, .kw_false => {
                self.pos += 1;
                return ast.Expr.make(self.alloc, .{ .bool_lit = tok.kind == .kw_true }, tok.span);
            },
            .kw_self => {
                self.pos += 1;
                return ast.Expr.make(self.alloc, .self_, tok.span);
            },
            .lparen => {
                self.pos += 1;
                const inner = try self.parseExpr(0);
                _ = try self.expect(.rparen);
                return inner;
            },
            .ident => {
                self.pos += 1;
                if (self.at(.coloncolon)) {
                    self.pos += 1;
                    const tail_tok = try self.expectIdent();
                    return ast.Expr.make(self.alloc, .{ .path = .{ .head = tok.text, .tail = tail_tok.text } }, .{
                        .start = tok.span.start,
                        .end = tail_tok.span.end,
                    });
                }
                if (self.looksLikeStructLiteral()) {
                    return self.parseStructLiteral(tok);
                }
                return ast.Expr.make(self.alloc, .{ .ident = tok.text }, tok.span);
            },
            else => {
                return self.failHelp(tok.span, "esperava uma expressão, encontrado `{s}`", .{tokenLabel(tok)}, null);
            },
        }
    }

    fn parseStructLiteral(self: *Parser, name_tok: lex.Token) Error!*ast.Expr {
        _ = try self.expect(.lbrace);
        var inits: std.ArrayList(ast.StructInit) = .empty;
        while (!self.at(.rbrace) and !self.at(.eof)) {
            const field_tok = try self.expectIdent();
            _ = try self.expect(.colon);
            const value = try self.parseExpr(0);
            inits.append(self.alloc, .{
                .name = field_tok.text,
                .name_span = field_tok.span,
                .value = value.*,
            }) catch return error.ParseFailed;
            if (self.eat(.comma) == null and !self.at(.rbrace)) {
                return self.fail(self.peek().span, "esperava `,` ou `}}` no literal de `{s}`", .{name_tok.text});
            }
        }
        const end_tok = try self.expect(.rbrace);
        return ast.Expr.make(self.alloc, .{ .struct_lit = .{ .name = name_tok.text, .inits = inits.items } }, .{
            .start = name_tok.span.start,
            .end = end_tok.span.end,
        });
    }
};

/// Remove o sufixo `.kyn` de um segmento de caminho de importação.
fn stripKynSuffix(segment: []const u8) []const u8 {
    if (segment.len >= 4 and std.mem.eql(u8, segment[segment.len - 4 ..], ".kyn")) {
        return segment[0 .. segment.len - 4];
    }
    return segment;
}

fn tokenLabel(tok: lex.Token) []const u8 {
    if (tok.kind == .eof) return "<fim do arquivo>";
    if (tok.kind == .ident or tok.kind == .string_lit or tok.kind == .char_lit or
        tok.kind == .int_lit or tok.kind == .float_lit or tok.kind.isKeyword())
    {
        return tok.text;
    }
    return tok.kind.text();
}

fn parseFloatLiteral(text: []const u8) ?f64 {
    if (std.mem.indexOfScalar(u8, text, '_') == null) {
        return std.fmt.parseFloat(f64, text) catch null;
    }
    var buf: [128]u8 = undefined;
    var out: usize = 0;
    for (text) |ch| {
        if (ch == '_') continue;
        if (out >= buf.len) return null;
        buf[out] = ch;
        out += 1;
    }
    return std.fmt.parseFloat(f64, buf[0..out]) catch null;
}

fn parseIntLiteral(text: []const u8) ?i128 {
    var base: u8 = 10;
    var digits = text;
    if (text.len > 2 and text[0] == '0') {
        switch (text[1]) {
            'x', 'X' => {
                base = 16;
                digits = text[2..];
            },
            'o', 'O' => {
                base = 8;
                digits = text[2..];
            },
            'b', 'B' => {
                base = 2;
                digits = text[2..];
            },
            else => {},
        }
    }
    if (digits.len == 0) return null;
    if (std.mem.indexOfScalar(u8, digits, '_') == null) {
        return std.fmt.parseInt(i128, digits, base) catch null;
    }
    var buf: [128]u8 = undefined;
    var out: usize = 0;
    for (digits) |ch| {
        if (ch == '_') continue;
        if (out >= buf.len) return null;
        buf[out] = ch;
        out += 1;
    }
    return std.fmt.parseInt(i128, buf[0..out], base) catch null;
}

test "parseIntLiteral handles bases and separators" {
    try std.testing.expectEqual(@as(i128, 255), parseIntLiteral("0xFF").?);
    try std.testing.expectEqual(@as(i128, 1000), parseIntLiteral("1_000").?);
    try std.testing.expectEqual(@as(i128, 5), parseIntLiteral("0b101").?);
    try std.testing.expectEqual(@as(i128, 493), parseIntLiteral("0o755").?);
    try std.testing.expectEqual(null, parseIntLiteral("0x"));
    try std.testing.expectEqual(null, parseIntLiteral("99999999999999999999999999999999999999999999"));
}
