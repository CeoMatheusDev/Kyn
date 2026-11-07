//! Parser do bootstrap em Zig.
//!
//! Contrato:
//! - Consome tokens do lexer (sem whitespace/comentários) e constrói a AST
//!   completa do programa.
//! - Falha no primeiro erro sintático: registra um diagnóstico com span e
//!   retorna `error.ParseError`. Erros de alocação retornam o erro original.
//! - Toda a AST é alocada na arena recebida em `init`.
//!
//! Subconjunto suportado (ver `docs/syntax.ebnf` e `docs/status.md`):
//!   `fn`, `let`/`var` com inicializador obrigatório, atribuição, `return`,
//!   `if`/`else`, `while`, blocos e expressões com precedência (`||`, `&&`,
//!   `==`/`!=`, comparações, `+`/`-`, `*`/`/`/`%`, unários `-`/`!`), literais
//!   inteiros e booleanos, variáveis e chamadas diretas de função.

const std = @import("std");
const ast = @import("../ast/ast.zig");
const lexer = @import("../lexer/lexer.zig");
const diagnostics = @import("../diagnostics.zig");
const Span = @import("../span.zig").Span;

pub const Error = std.mem.Allocator.Error || error{ParseError};

pub const Parser = struct {
    arena: std.mem.Allocator,
    tokens: []const lexer.Token,
    diags: *diagnostics.List,
    pos: usize = 0,
    /// `Nome { ... }` só é literal de struct com esta flag ativa. Condições de
    /// `if`/`while` a desativam, porque `if cond {` e `while cond {` usariam o
    /// mesmo prefixo (identificador seguido de `{`).
    allow_struct_literal: bool = true,

    pub fn init(arena: std.mem.Allocator, tokens: []const lexer.Token, diags: *diagnostics.List) Parser {
        return .{ .arena = arena, .tokens = tokens, .diags = diags };
    }

    fn current(self: *const Parser) lexer.Token {
        if (self.pos >= self.tokens.len) {
            if (self.tokens.len == 0) return lexer.Token.init(.eof, .{}, "");
            const last = self.tokens[self.tokens.len - 1];
            return lexer.Token.init(.eof, .{
                .start = last.span.end,
                .end = last.span.end,
                .line = last.span.line,
                .column = last.span.column,
            }, "");
        }
        return self.tokens[self.pos];
    }

    fn peekTag(self: *const Parser, offset: usize) lexer.Tag {
        const idx = self.pos + offset;
        if (idx >= self.tokens.len) return .eof;
        return self.tokens[idx].tag;
    }

    fn at(self: *const Parser, tag: lexer.Tag) bool {
        return self.current().tag == tag;
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.tokens.len) self.pos += 1;
    }

    fn take(self: *Parser) lexer.Token {
        const tok = self.current();
        self.advance();
        return tok;
    }

    fn fail(
        self: *Parser,
        kind: diagnostics.Kind,
        span: Span,
        comptime fmt: []const u8,
        args: anytype,
    ) Error {
        self.diags.add(kind, span, fmt, args) catch return error.OutOfMemory;
        return error.ParseError;
    }

    fn expect(self: *Parser, tag: lexer.Tag, label: []const u8) Error!lexer.Token {
        const tok = self.current();
        if (tok.tag != tag) {
            return self.fail(.syntax, tok.span, "esperado {s}, encontrado {s}", .{ label, tok.describe() });
        }
        return self.take();
    }

    fn expectIdentifier(self: *Parser, label: []const u8) Error!lexer.Token {
        const tok = self.current();
        if (tok.tag != .identifier) {
            return self.fail(.syntax, tok.span, "esperado {s}, encontrado {s}", .{ label, tok.describe() });
        }
        return self.take();
    }

    /// programa = { import }, { struct_decl | function_decl }, EOF
    pub fn parseProgram(self: *Parser) Error!*ast.Program {
        const start_span = self.current().span;
        var imports: std.ArrayList(ast.Import) = .empty;
        var structs: std.ArrayList(*ast.StructDecl) = .empty;
        var functions: std.ArrayList(*ast.Function) = .empty;
        var seen_decl = false;

        while (!self.at(.eof)) {
            switch (self.current().tag) {
                .kw_import => {
                    if (seen_decl) {
                        const tok = self.current();
                        return self.fail(
                            .syntax,
                            tok.span,
                            "'import' deve vir antes das declarações de 'struct' e 'fn'",
                            .{},
                        );
                    }
                    try imports.append(self.arena, try self.parseImport());
                },
                .kw_struct => {
                    seen_decl = true;
                    try structs.append(self.arena, try self.parseStruct());
                },
                .kw_fn => {
                    seen_decl = true;
                    try functions.append(self.arena, try self.parseFunction());
                },
                else => {
                    const tok = self.current();
                    return self.fail(
                        .syntax,
                        tok.span,
                        "esperado 'import', declaração 'struct' ou 'fn' no nível superior, encontrado {s}",
                        .{tok.describe()},
                    );
                },
            }
        }

        const program = try self.arena.create(ast.Program);
        program.* = .{
            .imports = try imports.toOwnedSlice(self.arena),
            .structs = try structs.toOwnedSlice(self.arena),
            .functions = try functions.toOwnedSlice(self.arena),
            .span = start_span.merge(self.current().span),
        };
        return program;
    }

    /// struct_decl = "struct", identifier, "{", { field, "," }, "}" ;
    /// Campos exigem tipo explícito; a vírgula final é opcional.
    fn parseStruct(self: *Parser) Error!*ast.StructDecl {
        const kw_tok = try self.expect(.kw_struct, "'struct'");
        const name_tok = try self.expectIdentifier("nome do struct após 'struct'");
        _ = try self.expect(.lbrace, "'{' para iniciar os campos do struct");

        var fields: std.ArrayList(ast.Field) = .empty;
        while (!self.at(.rbrace)) {
            if (self.at(.eof)) {
                return self.fail(
                    .syntax,
                    self.current().span,
                    "struct '{s}' não fechado: falta '}}' antes do fim do arquivo",
                    .{name_tok.text},
                );
            }
            const field_name = try self.expectIdentifier("nome do campo");
            _ = try self.expect(.colon, "':' e o tipo do campo");
            const type_name = try self.parseTypeName("tipo do campo");
            try fields.append(self.arena, .{
                .name = field_name.text,
                .name_span = field_name.span,
                .type_name = type_name,
                .span = field_name.span.merge(type_name.span),
            });
            if (self.at(.comma)) {
                self.advance();
                continue;
            }
            if (!self.at(.rbrace)) {
                const tok = self.current();
                return self.fail(
                    .syntax,
                    tok.span,
                    "esperado ',' entre campos do struct ou '}}' para fechar, encontrado {s}",
                    .{tok.describe()},
                );
            }
        }
        const close = try self.expect(.rbrace, "'}' para fechar o struct");

        const decl = try self.arena.create(ast.StructDecl);
        decl.* = .{
            .name = name_tok.text,
            .name_span = name_tok.span,
            .fields = try fields.toOwnedSlice(self.arena),
            .span = kw_tok.span.merge(close.span),
        };
        return decl;
    }

    /// import = "import", string, ";" ;
    fn parseImport(self: *Parser) Error!ast.Import {
        const kw_tok = try self.expect(.kw_import, "'import'");

        const path_tok = self.current();
        if (path_tok.tag == .string_unterminated) {
            return self.fail(.syntax, path_tok.span, "literal de string não terminado no caminho de importação", .{});
        }
        if (path_tok.tag != .string) {
            return self.fail(
                .syntax,
                path_tok.span,
                "esperado caminho de importação entre aspas, encontrado {s}",
                .{path_tok.describe()},
            );
        }
        self.advance();

        const semi = try self.expect(.semicolon, "';' após o caminho de importação");

        return .{
            .path = path_tok.text,
            .path_span = path_tok.span,
            .span = kw_tok.span.merge(semi.span),
        };
    }

    fn parseFunction(self: *Parser) Error!*ast.Function {
        const fn_tok = try self.expect(.kw_fn, "'fn'");
        const name_tok = try self.expectIdentifier("nome de função após 'fn'");
        _ = try self.expect(.lparen, "'(' após o nome da função");

        var params: std.ArrayList(ast.Param) = .empty;
        if (!self.at(.rparen)) {
            while (true) {
                try params.append(self.arena, try self.parseParam());
                if (self.at(.comma)) {
                    self.advance();
                    continue;
                }
                break;
            }
        }
        _ = try self.expect(.rparen, "')' para encerrar os parâmetros");

        var return_type: ?ast.TypeName = null;
        if (self.at(.arrow)) {
            self.advance();
            return_type = try self.parseTypeName("tipo de retorno após '->'");
        }

        const block = try self.parseBlock("'{' para iniciar o corpo da função");

        const func = try self.arena.create(ast.Function);
        func.* = .{
            .name = name_tok.text,
            .name_span = name_tok.span,
            .params = try params.toOwnedSlice(self.arena),
            .return_type = return_type,
            .body = block.stmts,
            .span = fn_tok.span.merge(block.span),
        };
        return func;
    }

    fn parseParam(self: *Parser) Error!ast.Param {
        const name_tok = try self.expectIdentifier("nome do parâmetro");
        _ = try self.expect(.colon, "':' e o tipo do parâmetro");
        const type_name = try self.parseTypeName("tipo do parâmetro");
        return .{
            .name = name_tok.text,
            .type_name = type_name,
            .span = name_tok.span.merge(type_name.span),
        };
    }

    fn parseTypeName(self: *Parser, label: []const u8) Error!ast.TypeName {
        const tok = try self.expectIdentifier(label);
        return .{ .name = tok.text, .span = tok.span };
    }

    const Block = struct {
        stmts: []*ast.Stmt,
        span: Span,
    };

    fn parseBlock(self: *Parser, label: []const u8) Error!Block {
        const open = try self.expect(.lbrace, label);
        var stmts: std.ArrayList(*ast.Stmt) = .empty;
        while (!self.at(.rbrace)) {
            if (self.at(.eof)) {
                return self.fail(.syntax, self.current().span, "bloco não fechado: falta o fechamento antes do fim do arquivo", .{});
            }
            try stmts.append(self.arena, try self.parseStatement());
        }
        const close = try self.expect(.rbrace, "'}' para fechar o bloco");
        return .{
            .stmts = try stmts.toOwnedSlice(self.arena),
            .span = open.span.merge(close.span),
        };
    }

    fn parseStatement(self: *Parser) Error!*ast.Stmt {
        const tok = self.current();
        return switch (tok.tag) {
            .kw_let, .kw_var => self.parseVarDecl(),
            .kw_return => self.parseReturn(),
            .kw_if => self.parseIf(),
            .kw_while => self.parseWhile(),
            .lbrace => blk: {
                const block = try self.parseBlock("'{' para iniciar o bloco");
                const stmt = try ast.Stmt.create(self.arena, block.span, .{ .block = block.stmts });
                break :blk stmt;
            },
            .identifier => blk: {
                if (self.peekTag(1) == .assign) break :blk try self.parseAssign();
                if (self.peekTag(1) == .dot) break :blk try self.parseFieldAssignOrExpr();
                break :blk try self.parseExprStatement();
            },
            else => self.parseExprStatement(),
        };
    }

    fn parseVarDecl(self: *Parser) Error!*ast.Stmt {
        const kw_tok = self.take(); // let | var
        const mutable = kw_tok.tag == .kw_var;
        const name_tok = try self.expectIdentifier("nome da variável");

        var type_name: ?ast.TypeName = null;
        if (self.at(.colon)) {
            self.advance();
            type_name = try self.parseTypeName("tipo da variável");
        }

        if (!self.at(.assign)) {
            const what = if (mutable) "var" else "let";
            const tok = self.current();
            return self.fail(
                .unsupported,
                tok.span,
                "'{s}' sem inicializador ainda não é suportado; informe um valor inicial",
                .{what},
            );
        }
        self.advance(); // =

        const init_expr = try self.parseExpression();
        const semi = try self.expect(.semicolon, "';' após a declaração");

        return ast.Stmt.create(self.arena, kw_tok.span.merge(semi.span), .{
            .let_decl = .{
                .name = name_tok.text,
                .name_span = name_tok.span,
                .type_name = type_name,
                .init = init_expr,
                .mutable = mutable,
            },
        });
    }

    fn parseAssign(self: *Parser) Error!*ast.Stmt {
        const name_tok = try self.expectIdentifier("nome da variável");
        _ = try self.expect(.assign, "'=' na atribuição");
        const value = try self.parseExpression();
        const semi = try self.expect(.semicolon, "';' após a atribuição");
        return ast.Stmt.create(self.arena, name_tok.span.merge(semi.span), .{
            .assign = .{
                .name = name_tok.text,
                .name_span = name_tok.span,
                .value = value,
            },
        });
    }

    fn parseReturn(self: *Parser) Error!*ast.Stmt {
        const kw_tok = try self.expect(.kw_return, "'return'");
        var value: ?*ast.Expr = null;
        if (!self.at(.semicolon)) {
            value = try self.parseExpression();
        }
        const semi = try self.expect(.semicolon, "';' após 'return'");
        return ast.Stmt.create(self.arena, kw_tok.span.merge(semi.span), .{ .return_stmt = value });
    }

    fn parseIf(self: *Parser) Error!*ast.Stmt {
        const kw_tok = try self.expect(.kw_if, "'if'");
        const cond = try self.parseCondition();
        const then_block = try self.parseBlock("'{' para iniciar o bloco do 'if'");

        var else_body: ?ast.Stmt.ElseBranch = null;
        var end_span = then_block.span;
        if (self.at(.kw_else)) {
            self.advance();
            if (self.at(.kw_if)) {
                const nested = try self.parseIf();
                else_body = .{ .if_stmt = nested };
                end_span = nested.span;
            } else {
                const else_block = try self.parseBlock("'{' para iniciar o bloco do 'else'");
                else_body = .{ .block = else_block.stmts };
                end_span = else_block.span;
            }
        }

        return ast.Stmt.create(self.arena, kw_tok.span.merge(end_span), .{
            .if_stmt = .{
                .cond = cond,
                .then_body = then_block.stmts,
                .else_body = else_body,
            },
        });
    }

    fn parseWhile(self: *Parser) Error!*ast.Stmt {
        const kw_tok = try self.expect(.kw_while, "'while'");
        const cond = try self.parseCondition();
        const block = try self.parseBlock("'{' para iniciar o bloco do 'while'");
        return ast.Stmt.create(self.arena, kw_tok.span.merge(block.span), .{
            .while_stmt = .{ .cond = cond, .body = block.stmts },
        });
    }

    fn parseExprStatement(self: *Parser) Error!*ast.Stmt {
        const expr = try self.parseExpression();
        const semi = try self.expect(.semicolon, "';' após a expressão");
        return ast.Stmt.create(self.arena, expr.span.merge(semi.span), .{ .expr_stmt = expr });
    }

    pub fn parseExpression(self: *Parser) Error!*ast.Expr {
        return self.parseBinary(1);
    }

    /// Expressão de condição: sem `Nome { ... }` para não consumir o `{` do
    /// bloco que segue.
    fn parseCondition(self: *Parser) Error!*ast.Expr {
        const saved = self.allow_struct_literal;
        self.allow_struct_literal = false;
        defer self.allow_struct_literal = saved;
        return self.parseExpression();
    }

    const BinaryInfo = struct {
        prec: u8,
        op: ast.Expr.BinaryOp,
    };

    fn binaryInfo(tag: lexer.Tag) ?BinaryInfo {
        return switch (tag) {
            .pipe_pipe => .{ .prec = 1, .op = .or_op },
            .amp_amp => .{ .prec = 2, .op = .and_op },
            .eq => .{ .prec = 3, .op = .eq },
            .ne => .{ .prec = 3, .op = .ne },
            .lt => .{ .prec = 4, .op = .lt },
            .le => .{ .prec = 4, .op = .le },
            .gt => .{ .prec = 4, .op = .gt },
            .ge => .{ .prec = 4, .op = .ge },
            .plus => .{ .prec = 5, .op = .add },
            .minus => .{ .prec = 5, .op = .sub },
            .star => .{ .prec = 6, .op = .mul },
            .slash => .{ .prec = 6, .op = .div },
            .percent => .{ .prec = 6, .op = .mod },
            else => null,
        };
    }

    fn parseBinary(self: *Parser, min_prec: u8) Error!*ast.Expr {
        var lhs = try self.parseUnary();
        while (binaryInfo(self.current().tag)) |info| {
            if (info.prec < min_prec) break;
            self.advance();
            const rhs = try self.parseBinary(info.prec + 1);
            lhs = try ast.Expr.create(self.arena, lhs.span.merge(rhs.span), .{
                .binary = .{ .op = info.op, .lhs = lhs, .rhs = rhs },
            });
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) Error!*ast.Expr {
        const tok = self.current();
        switch (tok.tag) {
            .minus => {
                self.advance();
                const operand = try self.parseUnary();
                return ast.Expr.create(self.arena, tok.span.merge(operand.span), .{
                    .unary = .{ .op = .neg, .operand = operand },
                });
            },
            .bang => {
                self.advance();
                const operand = try self.parseUnary();
                return ast.Expr.create(self.arena, tok.span.merge(operand.span), .{
                    .unary = .{ .op = .not, .operand = operand },
                });
            },
            else => return self.parsePrimary(),
        }
    }

    fn parsePrimary(self: *Parser) Error!*ast.Expr {
        const tok = self.current();
        switch (tok.tag) {
            .integer => {
                self.advance();
                const value = std.fmt.parseInt(i64, tok.text, 10) catch {
                    return self.fail(
                        .integer_overflow,
                        tok.span,
                        "literal inteiro '{s}' excede o intervalo de 64 bits suportado",
                        .{tok.text},
                    );
                };
                return ast.Expr.create(self.arena, tok.span, .{
                    .int_literal = .{ .value = value, .text = tok.text },
                });
            },
            .kw_true, .kw_false => {
                self.advance();
                return ast.Expr.create(self.arena, tok.span, .{ .bool_literal = tok.tag == .kw_true });
            },
            .identifier => {
                self.advance();
                if (self.at(.lparen)) {
                    const call = try self.parseCall(tok);
                    return call;
                }
                if (self.at(.lbrace) and self.allow_struct_literal) {
                    return self.parseStructLiteral(tok);
                }
                const base = try ast.Expr.create(self.arena, tok.span, .{ .identifier = tok.text });
                return self.parseFieldChain(base);
            },
            .lparen => {
                self.advance();
                const inner = try self.parseExpression();
                _ = try self.expect(.rparen, "')' para fechar a expressão");
                return inner;
            },
            .invalid => return self.fail(
                .syntax,
                tok.span,
                "caractere inválido '{s}' na expressão",
                .{if (tok.text.len > 0) tok.text else "?"},
            ),
            else => return self.fail(
                .syntax,
                tok.span,
                "esperado expressão, encontrado {s}",
                .{tok.describe()},
            ),
        }
    }

    fn parseCall(self: *Parser, callee: lexer.Token) Error!*ast.Expr {
        _ = try self.expect(.lparen, "'(' na chamada de função");
        var args: std.ArrayList(*ast.Expr) = .empty;
        if (!self.at(.rparen)) {
            while (true) {
                try args.append(self.arena, try self.parseExpression());
                if (self.at(.comma)) {
                    self.advance();
                    continue;
                }
                break;
            }
        }
        const close = try self.expect(.rparen, "')' para encerrar os argumentos");
        return ast.Expr.create(self.arena, callee.span.merge(close.span), .{
            .call = .{
                .callee = callee.text,
                .callee_span = callee.span,
                .args = try args.toOwnedSlice(self.arena),
            },
        });
    }

    /// Consome `.campo` encadeados sobre `base` e devolve o nó mais externo.
    fn parseFieldChain(self: *Parser, base: *ast.Expr) Error!*ast.Expr {
        var expr = base;
        while (self.at(.dot)) {
            self.advance();
            const field_tok = try self.expectIdentifier("nome do campo após '.'");
            const node = try ast.Expr.create(self.arena, expr.span.merge(field_tok.span), .{
                .field_access = .{
                    .base = expr,
                    .name = field_tok.text,
                    .name_span = field_tok.span,
                },
            });
            expr = node;
        }
        return expr;
    }

    /// `Nome { campo: valor, ... }` — a vírgula final é opcional.
    fn parseStructLiteral(self: *Parser, name_tok: lexer.Token) Error!*ast.Expr {
        _ = try self.expect(.lbrace, "'{' para iniciar o literal de struct");
        var fields: std.ArrayList(ast.Expr.FieldInit) = .empty;
        while (!self.at(.rbrace)) {
            if (self.at(.eof)) {
                return self.fail(
                    .syntax,
                    self.current().span,
                    "literal de struct não fechado: falta '}}' antes do fim do arquivo",
                    .{},
                );
            }
            const field_name = try self.expectIdentifier("nome do campo no literal");
            _ = try self.expect(.colon, "':' e o valor do campo");
            const value = try self.parseExpression();
            try fields.append(self.arena, .{
                .name = field_name.text,
                .name_span = field_name.span,
                .value = value,
            });
            if (self.at(.comma)) {
                self.advance();
                continue;
            }
            if (!self.at(.rbrace)) {
                const tok = self.current();
                return self.fail(
                    .syntax,
                    tok.span,
                    "esperado ',' entre campos do literal ou '}}' para fechar, encontrado {s}",
                    .{tok.describe()},
                );
            }
        }
        const close = try self.expect(.rbrace, "'}' para fechar o literal de struct");
        return ast.Expr.create(self.arena, name_tok.span.merge(close.span), .{
            .struct_literal = .{
                .type_name = .{ .name = name_tok.text, .span = name_tok.span },
                .fields = try fields.toOwnedSlice(self.arena),
            },
        });
    }

    /// `base.campo = valor;` ou expressão iniciada por acesso a campo.
    fn parseFieldAssignOrExpr(self: *Parser) Error!*ast.Stmt {
        const name_tok = try self.expectIdentifier("nome da variável");
        const base = try ast.Expr.create(self.arena, name_tok.span, .{ .identifier = name_tok.text });
        const target = try self.parseFieldChain(base);

        if (!self.at(.assign)) {
            const semi = try self.expect(.semicolon, "';' após a expressão");
            return ast.Stmt.create(self.arena, target.span.merge(semi.span), .{ .expr_stmt = target });
        }

        // Só `alvo.campo = valor` é aceito; cadeias mais profundas ficam para a
        // semântica diagnosticar (struct com campo struct ainda não existe).
        const access = switch (target.kind) {
            .field_access => |access| access,
            else => return self.fail(.syntax, target.span, "atribuição inválida", .{}),
        };
        self.advance(); // =
        const value = try self.parseExpression();
        const semi = try self.expect(.semicolon, "';' após a atribuição");
        return ast.Stmt.create(self.arena, name_tok.span.merge(semi.span), .{
            .field_assign = .{
                .base = access.base,
                .name = access.name,
                .name_span = access.name_span,
                .value = value,
            },
        });
    }
};

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Arena alocada no heap para manter o endereço estável enquanto o parser e a
/// semântica guardam `std.mem.Allocator` derivados dela.
const Parsed = struct {
    arena: *std.heap.ArenaAllocator,
    program: ?*ast.Program,
    diags: *diagnostics.List,

    fn parse(source: []const u8) !Parsed {
        const arena = try testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(testing.allocator);
        const a = arena.allocator();
        const diags = try arena.allocator().create(diagnostics.List);
        diags.* = diagnostics.List.init(a);
        var lex = lexer.Lexer.init(source);
        const tokens = try lex.tokenize(a);
        var parser = Parser.init(a, tokens, diags);
        const program = parser.parseProgram() catch |err| switch (err) {
            error.ParseError => null,
            else => return err,
        };
        return .{ .arena = arena, .program = program, .diags = diags };
    }

    fn deinit(self: *Parsed) void {
        self.arena.deinit();
        testing.allocator.destroy(self.arena);
    }
};

test "parser: programa mínimo com retorno" {
    var parsed = try Parsed.parse("fn main() -> i32 { return 1; }");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());
    try testing.expectEqual(@as(usize, 1), parsed.program.?.functions.len);

    const fn_decl = parsed.program.?.functions[0];
    try testing.expectEqualStrings("main", fn_decl.name);
    try testing.expectEqualStrings("i32", fn_decl.return_type.?.name);
    try testing.expectEqual(@as(usize, 0), fn_decl.params.len);
    try testing.expectEqual(@as(usize, 1), fn_decl.body.len);
    try testing.expectEqual(@as(i64, 1), fn_decl.body[0].kind.return_stmt.?.kind.int_literal.value);
}

test "parser: múltiplas funções e parâmetros" {
    const source =
        \\fn add(a: i32, b: i32) -> i32 { return a + b; }
        \\fn main() -> void { return; }
    ;
    var parsed = try Parsed.parse(source);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());
    try testing.expectEqual(@as(usize, 2), parsed.program.?.functions.len);

    const add = parsed.program.?.functions[0];
    try testing.expectEqual(@as(usize, 2), add.params.len);
    try testing.expectEqualStrings("a", add.params[0].name);
    try testing.expectEqualStrings("i32", add.params[1].type_name.name);

    const main = parsed.program.?.functions[1];
    try testing.expectEqualStrings("void", main.return_type.?.name);
    try testing.expect(main.body[0].kind.return_stmt == null);
}

test "parser: declarações let e var com anotação e inferência" {
    const source =
        \\fn main() -> i32 {
        \\    let x: i32 = 10;
        \\    var y = 20;
        \\    return x;
        \\}
    ;
    var parsed = try Parsed.parse(source);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());
    const body = parsed.program.?.functions[0].body;

    const x = body[0].kind.let_decl;
    try testing.expectEqualStrings("x", x.name);
    try testing.expectEqualStrings("i32", x.type_name.?.name);
    try testing.expect(!x.mutable);

    const y = body[1].kind.let_decl;
    try testing.expectEqualStrings("y", y.name);
    try testing.expect(y.type_name == null);
    try testing.expect(y.mutable);
}

test "parser: precedência de operadores" {
    // 1 + 2 * 3 => add(1, mul(2, 3))
    var parsed = try Parsed.parse("fn main() -> i32 { return 1 + 2 * 3; }");
    defer parsed.deinit();
    const ret = parsed.program.?.functions[0].body[0].kind.return_stmt.?;
    const add = ret.kind.binary;
    try testing.expectEqual(ast.Expr.BinaryOp.add, add.op);
    try testing.expectEqual(@as(i64, 1), add.lhs.kind.int_literal.value);
    const mul = add.rhs.kind.binary;
    try testing.expectEqual(ast.Expr.BinaryOp.mul, mul.op);
    try testing.expectEqual(@as(i64, 2), mul.lhs.kind.int_literal.value);
    try testing.expectEqual(@as(i64, 3), mul.rhs.kind.int_literal.value);
}

test "parser: associatividade à esquerda" {
    // 10 - 3 - 2 => sub(sub(10, 3), 2)
    var parsed = try Parsed.parse("fn main() -> i32 { return 10 - 3 - 2; }");
    defer parsed.deinit();
    const ret = parsed.program.?.functions[0].body[0].kind.return_stmt.?;
    const outer = ret.kind.binary;
    try testing.expectEqual(ast.Expr.BinaryOp.sub, outer.op);
    try testing.expectEqual(ast.Expr.BinaryOp.sub, outer.lhs.kind.binary.op);
    try testing.expectEqual(@as(i64, 2), outer.rhs.kind.int_literal.value);
}

test "parser: comparações têm precedência menor que aritmética" {
    // 1 + 2 < 5 => lt(add(1,2), 5)
    var parsed = try Parsed.parse("fn main() -> bool { return 1 + 2 < 5; }");
    defer parsed.deinit();
    const ret = parsed.program.?.functions[0].body[0].kind.return_stmt.?;
    try testing.expectEqual(ast.Expr.BinaryOp.lt, ret.kind.binary.op);
    try testing.expectEqual(ast.Expr.BinaryOp.add, ret.kind.binary.lhs.kind.binary.op);
}

test "parser: unários e parênteses" {
    var parsed = try Parsed.parse("fn main() -> i32 { return -(1 + 2) * 3; }");
    defer parsed.deinit();
    const ret = parsed.program.?.functions[0].body[0].kind.return_stmt.?;
    const mul = ret.kind.binary;
    try testing.expectEqual(ast.Expr.BinaryOp.mul, mul.op);
    try testing.expectEqual(ast.Expr.UnaryOp.neg, mul.lhs.kind.unary.op);
    try testing.expectEqual(ast.Expr.BinaryOp.add, mul.lhs.kind.unary.operand.kind.binary.op);
}

test "parser: if/else e while" {
    const source =
        \\fn main() -> i32 {
        \\    var i = 0;
        \\    while i < 3 {
        \\        if i == 1 { i = i + 1; } else { i = i + 2; }
        \\    }
        \\    return i;
        \\}
    ;
    var parsed = try Parsed.parse(source);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());
    const body = parsed.program.?.functions[0].body;
    const while_stmt = body[1].kind.while_stmt;
    try testing.expectEqual(ast.Expr.BinaryOp.lt, while_stmt.cond.kind.binary.op);
    try testing.expectEqual(@as(usize, 1), while_stmt.body.len);
    const if_stmt = while_stmt.body[0].kind.if_stmt;
    try testing.expect(if_stmt.else_body != null);
    try testing.expectEqual(@as(usize, 1), if_stmt.else_body.?.block.len);
}

test "parser: else if encadeado" {
    const source =
        \\fn main() -> i32 {
        \\    let x = 1;
        \\    if x == 1 { return 1; } else if x == 2 { return 2; } else { return 3; }
        \\}
    ;
    var parsed = try Parsed.parse(source);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());
    const if_stmt = parsed.program.?.functions[0].body[1].kind.if_stmt;
    const nested = if_stmt.else_body.?.if_stmt;
    try testing.expect(nested.kind.if_stmt.else_body != null);
}

test "parser: chamada de função com argumentos" {
    var parsed = try Parsed.parse("fn main() -> i32 { return add(1, 2); }");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());
    const ret = parsed.program.?.functions[0].body[0].kind.return_stmt.?;
    const call = ret.kind.call;
    try testing.expectEqualStrings("add", call.callee);
    try testing.expectEqual(@as(usize, 2), call.args.len);
}

test "parser: spans apontam linha e coluna do erro" {
    var parsed = try Parsed.parse("fn main() -> i32 {\n    return 1\n}\n");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    const diag = parsed.diags.last().?;
    try testing.expectEqual(diagnostics.Kind.syntax, diag.kind);
    try testing.expectEqual(@as(u32, 3), diag.span.line);
}

test "parser: erro em declaração sem inicializador" {
    var parsed = try Parsed.parse("fn main() -> void { let x: i32; }");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.unsupported, parsed.diags.last().?.kind);
}

test "parser: erro em statement no nível superior" {
    var parsed = try Parsed.parse("let x = 1;");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.last().?.kind);
}

test "parser: caractere inválido gera diagnóstico" {
    var parsed = try Parsed.parse("fn main() -> i32 { return @; }");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.last().?.kind);
}

test "parser: bloco não fechado é diagnosticado" {
    var parsed = try Parsed.parse("fn main() -> i32 { return 1;");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expect(std.mem.indexOf(u8, parsed.diags.last().?.message, "não fechado") != null);
}

test "parser: literal fora de 64 bits é diagnosticado" {
    var parsed = try Parsed.parse("fn main() -> i32 { return 99999999999999999999; }");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.integer_overflow, parsed.diags.last().?.kind);
}

test "parser: imports antes das funções" {
    var parsed = try Parsed.parse(
        \\import "lib/math";
        \\import "util.kyn";
        \\fn main() -> i32 { return 0; }
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());
    const imports = parsed.program.?.imports;
    try testing.expectEqual(@as(usize, 2), imports.len);
    try testing.expectEqualStrings("lib/math", imports[0].path);
    try testing.expectEqualStrings("util.kyn", imports[1].path);
    try testing.expectEqual(@as(u32, 1), imports[0].path_span.line);
    try testing.expectEqual(@as(usize, 1), parsed.program.?.functions.len);
}

test "parser: import depois de função é rejeitado" {
    var parsed = try Parsed.parse(
        \\fn main() -> i32 { return 0; }
        \\import "lib/math";
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.last().?.kind);
    try testing.expect(std.mem.indexOf(u8, parsed.diags.last().?.message, "antes das declarações") != null);
}

test "parser: import exige string entre aspas" {
    var parsed = try Parsed.parse("import lib;");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.last().?.kind);
}

test "parser: import exige ponto e vírgula" {
    var parsed = try Parsed.parse("import \"lib/math\"");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.last().?.kind);
}

test "parser: string não terminada em import gera diagnóstico específico" {
    var parsed = try Parsed.parse("import \"lib/math;");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expect(std.mem.indexOf(u8, parsed.diags.last().?.message, "não terminado") != null);
}

test "parser: declaração de struct com campos e vírgula final" {
    var parsed = try Parsed.parse(
        \\struct Ponto {
        \\    x: i32,
        \\    y: bool,
        \\}
        \\fn main() -> i32 { return 0; }
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());
    const program = parsed.program.?;
    try testing.expectEqual(@as(usize, 1), program.structs.len);
    try testing.expectEqualStrings("Ponto", program.structs[0].name);
    try testing.expectEqual(@as(usize, 2), program.structs[0].fields.len);
    try testing.expectEqualStrings("x", program.structs[0].fields[0].name);
    try testing.expectEqualStrings("i32", program.structs[0].fields[0].type_name.name);
    try testing.expectEqual(@as(u32, 3), program.structs[0].fields[1].name_span.line);
}

test "parser: struct depois de função é aceito (ordem livre)" {
    var parsed = try Parsed.parse(
        \\fn main() -> i32 { return 0; }
        \\struct Tardio { v: i32 }
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());
    try testing.expectEqual(@as(usize, 1), parsed.program.?.structs.len);
}

test "parser: struct sem fechamento gera diagnóstico" {
    var parsed = try Parsed.parse("struct P { x: i32 ");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.last().?.kind);
}

test "parser: campo sem tipo é rejeitado" {
    var parsed = try Parsed.parse("struct P { x }");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.last().?.kind);
}

test "parser: literal de struct e acesso a campo" {
    var parsed = try Parsed.parse(
        \\struct Ponto { x: i32, y: i32 }
        \\fn main() -> i32 {
        \\    var p: Ponto = Ponto { x: 1, y: 2 };
        \\    p.x = p.y;
        \\    return p.x;
        \\}
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());

    const body = parsed.program.?.functions[0].body;
    try testing.expectEqual(@as(usize, 3), body.len);

    const lit = body[0].kind.let_decl.init.kind.struct_literal;
    try testing.expectEqualStrings("Ponto", lit.type_name.name);
    try testing.expectEqual(@as(usize, 2), lit.fields.len);
    try testing.expectEqualStrings("y", lit.fields[1].name);

    const assign = body[1].kind.field_assign;
    try testing.expectEqualStrings("x", assign.name);
    try testing.expectEqualStrings("p", assign.base.kind.identifier);

    const ret = body[2].kind.return_stmt.?.kind.field_access;
    try testing.expectEqualStrings("x", ret.name);
    try testing.expectEqualStrings("p", ret.base.kind.identifier);
}

test "parser: condições de if/while aceitam acesso a campo sem virar literal" {
    var parsed = try Parsed.parse(
        \\struct C { v: i32 }
        \\fn main() -> i32 {
        \\    var c: C = C { v: 0 };
        \\    while c.v < 3 { c.v = c.v + 1; }
        \\    if c.v == 3 { return 1; }
        \\    return 0;
        \\}
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());
    const body = parsed.program.?.functions[0].body;
    const while_stmt = body[1].kind.while_stmt;
    try testing.expectEqualStrings("v", while_stmt.cond.kind.binary.lhs.kind.field_access.name);
}

test "parser: 'import' depois de struct é rejeitado" {
    var parsed = try Parsed.parse(
        \\struct P { x: i32 }
        \\import "lib.kyn";
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expect(std.mem.indexOf(u8, parsed.diags.last().?.message, "antes das declarações") != null);
}
