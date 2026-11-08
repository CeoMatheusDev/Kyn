//! Parser do bootstrap em Zig.
//!
//! Contrato:
//! - Consumes lexer tokens (no whitespace/comments) and builds the AST
//!   completa do programa.
//! - Fails on the first syntax error: records a diagnostic with a span and
//!   returns `error.ParseError`. Allocation errors return the original error.
//! - The whole AST is allocated in the arena received by `init`.
//!
//! Subconjunto suportado (ver `docs/syntax.ebnf` e `docs/status.md`):
//!   `fn`, `let`/`var` with a mandatory initializer, assignment, `return`,
//!   `if`/`else`, `while`, blocks and expressions with precedence (`||`, `&&`,
//!   `==`/`!=`, comparisons, `+`/`-`, `*`/`/`/`%`, unary `-`/`!`), integer and
//!   boolean literals, variables and direct function calls.

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
    /// `Name { ... }` is only a struct literal with this flag on. `if`/`while`
    /// `if`/`while` a desativam, porque `if cond {` e `while cond {` usariam o
    /// same prefix (identifier followed by `{`).
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
            return self.fail(.syntax, tok.span, "expected {s}, found {s}", .{ label, tok.describe() });
        }
        return self.take();
    }

    fn expectIdentifier(self: *Parser, label: []const u8) Error!lexer.Token {
        const tok = self.current();
        if (tok.tag != .identifier) {
            return self.fail(.syntax, tok.span, "expected {s}, found {s}", .{ label, tok.describe() });
        }
        return self.take();
    }

    /// programa = { import }, { struct_decl | enum_decl | impl_decl | function_decl }, EOF
    pub fn parseProgram(self: *Parser) Error!*ast.Program {
        const start_span = self.current().span;
        var imports: std.ArrayList(ast.Import) = .empty;
        var structs: std.ArrayList(*ast.StructDecl) = .empty;
        var enums: std.ArrayList(*ast.EnumDecl) = .empty;
        var impls: std.ArrayList(*ast.ImplBlock) = .empty;
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
                            "'import' must come before 'struct', 'enum', 'impl' and 'fn' declarations",
                            .{},
                        );
                    }
                    try imports.append(self.arena, try self.parseImport());
                },
                .kw_struct => {
                    seen_decl = true;
                    try structs.append(self.arena, try self.parseStruct());
                },
                .kw_enum => {
                    seen_decl = true;
                    try enums.append(self.arena, try self.parseEnum());
                },
                .kw_impl => {
                    seen_decl = true;
                    const block = try self.parseImpl();
                    // Methods enter the single function list in source order;
                    // the block keeps the target span for diagnostics.
                    for (block.methods) |method| try functions.append(self.arena, method);
                    try impls.append(self.arena, block);
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
                        "expected 'import', 'struct', 'enum', 'impl' or 'fn' at top level, found {s}",
                        .{tok.describe()},
                    );
                },
            }
        }

        const program = try self.arena.create(ast.Program);
        program.* = .{
            .imports = try imports.toOwnedSlice(self.arena),
            .structs = try structs.toOwnedSlice(self.arena),
            .enums = try enums.toOwnedSlice(self.arena),
            .impls = try impls.toOwnedSlice(self.arena),
            .functions = try functions.toOwnedSlice(self.arena),
            .span = start_span.merge(self.current().span),
        };
        return program;
    }

    /// struct_decl = "struct", identifier, "{", { field, "," }, "}" ;
    /// Fields require an explicit type; the trailing comma is optional.
    fn parseStruct(self: *Parser) Error!*ast.StructDecl {
        const kw_tok = try self.expect(.kw_struct, "'struct'");
        const name_tok = try self.expectIdentifier("struct name after 'struct'");
        _ = try self.expect(.lbrace, "'{' to start the struct fields");

        var fields: std.ArrayList(ast.Field) = .empty;
        while (!self.at(.rbrace)) {
            if (self.at(.eof)) {
                return self.fail(
                    .syntax,
                    self.current().span,
                    "struct '{s}' is not closed: missing '}}' before end of file",
                    .{name_tok.text},
                );
            }
            const field_name = try self.expectIdentifier("field name");
            _ = try self.expect(.colon, "':' and the field type");
            const type_name = try self.parseTypeName("field type");
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
                    "expected ',' between struct fields or '}}' to close, found {s}",
                    .{tok.describe()},
                );
            }
        }
        const close = try self.expect(.rbrace, "'}' to close the struct");

        const decl = try self.arena.create(ast.StructDecl);
        decl.* = .{
            .name = name_tok.text,
            .name_span = name_tok.span,
            .fields = try fields.toOwnedSlice(self.arena),
            .span = kw_tok.span.merge(close.span),
        };
        return decl;
    }

    /// enum_decl = "enum", identifier, "{", { case, [","] }, "}" ;
    /// case = identifier, ["(", type_name, ")"] ;
    fn parseEnum(self: *Parser) Error!*ast.EnumDecl {
        const kw_tok = try self.expect(.kw_enum, "'enum'");
        const name_tok = try self.expectIdentifier("enum name after 'enum'");
        _ = try self.expect(.lbrace, "'{' to start the enum cases");

        var cases: std.ArrayList(ast.EnumCase) = .empty;
        while (!self.at(.rbrace)) {
            if (self.at(.eof)) {
                return self.fail(
                    .syntax,
                    self.current().span,
                    "enum '{s}' is not closed: missing '}}' before end of file",
                    .{name_tok.text},
                );
            }
            // A stray separator between cases is accepted and ignored.
            if (self.at(.comma) or self.at(.semicolon)) {
                self.advance();
                continue;
            }

            const case_tok = try self.expectIdentifier("case name");
            var payload: ?ast.TypeName = null;
            var case_span = case_tok.span;
            if (self.at(.lparen)) {
                self.advance();
                payload = try self.parseTypeName("payload type of the case");
                const close = try self.expect(.rparen, "')' to close the payload type");
                case_span = case_span.merge(close.span);
            }
            try cases.append(self.arena, .{
                .name = case_tok.text,
                .name_span = case_tok.span,
                .payload = payload,
                .span = case_span,
            });

            if (self.at(.comma) or self.at(.semicolon)) {
                self.advance();
                continue;
            }
            if (!self.at(.rbrace)) {
                const tok = self.current();
                return self.fail(
                    .syntax,
                    tok.span,
                    "expected ',' between enum cases or '}}' to close, found {s}",
                    .{tok.describe()},
                );
            }
        }
        const close = try self.expect(.rbrace, "'}' to close the enum");

        const decl = try self.arena.create(ast.EnumDecl);
        decl.* = .{
            .name = name_tok.text,
            .name_span = name_tok.span,
            .cases = try cases.toOwnedSlice(self.arena),
            .span = kw_tok.span.merge(close.span),
        };
        return decl;
    }

    /// impl_decl = "impl", identifier, "{", { function_decl }, "}" ;
    /// The target type is resolved by semantics; the parser only records it.
    fn parseImpl(self: *Parser) Error!*ast.ImplBlock {
        const kw_tok = try self.expect(.kw_impl, "'impl'");
        const type_name = try self.parseTypeName("type name after 'impl'");
        _ = try self.expect(.lbrace, "'{' to start the methods of 'impl'");

        var methods: std.ArrayList(*ast.Function) = .empty;
        while (!self.at(.rbrace)) {
            if (self.at(.eof)) {
                return self.fail(
                    .syntax,
                    self.current().span,
                    "impl '{s}' is not closed: missing '}}' before end of file",
                    .{type_name.name},
                );
            }
            if (!self.at(.kw_fn)) {
                const tok = self.current();
                return self.fail(
                    .syntax,
                    tok.span,
                    "expected 'fn' inside 'impl' or '}}' to close, found {s}",
                    .{tok.describe()},
                );
            }
            const method = try self.parseFunction();
            method.owner_type = type_name;
            try methods.append(self.arena, method);
        }
        const close = try self.expect(.rbrace, "'}' to close the impl");

        const block = try self.arena.create(ast.ImplBlock);
        block.* = .{
            .type_name = type_name,
            .methods = try methods.toOwnedSlice(self.arena),
            .span = kw_tok.span.merge(close.span),
        };
        return block;
    }

    /// import = "import", string, ";" ;
    fn parseImport(self: *Parser) Error!ast.Import {
        const kw_tok = try self.expect(.kw_import, "'import'");

        const path_tok = self.current();
        if (path_tok.tag == .string_unterminated) {
            return self.fail(.syntax, path_tok.span, "unterminated string literal in the import path", .{});
        }
        if (path_tok.tag != .string) {
            return self.fail(
                .syntax,
                path_tok.span,
                "expected a quoted import path, found {s}",
                .{path_tok.describe()},
            );
        }
        self.advance();

        const semi = try self.expect(.semicolon, "';' after the import path");

        return .{
            .path = path_tok.text,
            .path_span = path_tok.span,
            .span = kw_tok.span.merge(semi.span),
        };
    }

    fn parseFunction(self: *Parser) Error!*ast.Function {
        const fn_tok = try self.expect(.kw_fn, "'fn'");
        const name_tok = try self.expectIdentifier("function name after 'fn'");
        _ = try self.expect(.lparen, "'(' after the function name");

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
        _ = try self.expect(.rparen, "')' to close the parameters");

        var return_type: ?ast.TypeName = null;
        if (self.at(.arrow)) {
            self.advance();
            return_type = try self.parseTypeName("return type after '->'");
        }

        const block = try self.parseBlock("'{' to start the function body");

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
        const name_tok = try self.expectIdentifier("parameter name");
        _ = try self.expect(.colon, "':' and the parameter type");
        const type_name = try self.parseTypeName("parameter type");
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
                return self.fail(.syntax, self.current().span, "block is not closed: missing closing brace before end of file", .{});
            }
            try stmts.append(self.arena, try self.parseStatement());
        }
        const close = try self.expect(.rbrace, "'}' to close the block");
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
            .kw_switch => self.parseSwitch(),
            .lbrace => blk: {
                const block = try self.parseBlock("'{' to start the block");
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
        const name_tok = try self.expectIdentifier("variable name");

        var type_name: ?ast.TypeName = null;
        if (self.at(.colon)) {
            self.advance();
            type_name = try self.parseTypeName("variable type");
        }

        if (!self.at(.assign)) {
            const what = if (mutable) "var" else "let";
            const tok = self.current();
            return self.fail(
                .unsupported,
                tok.span,
                "'{s}' without an initializer is not supported yet; provide an initial value",
                .{what},
            );
        }
        self.advance(); // =

        const init_expr = try self.parseExpression();
        const semi = try self.expect(.semicolon, "';' after the declaration");

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
        const name_tok = try self.expectIdentifier("variable name");
        _ = try self.expect(.assign, "'=' in the assignment");
        const value = try self.parseExpression();
        const semi = try self.expect(.semicolon, "';' after the assignment");
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
        const semi = try self.expect(.semicolon, "';' after 'return'");
        return ast.Stmt.create(self.arena, kw_tok.span.merge(semi.span), .{ .return_stmt = value });
    }

    fn parseIf(self: *Parser) Error!*ast.Stmt {
        const kw_tok = try self.expect(.kw_if, "'if'");
        const cond = try self.parseCondition();
        const then_block = try self.parseBlock("'{' to start the 'if' block");

        var else_body: ?ast.Stmt.ElseBranch = null;
        var end_span = then_block.span;
        if (self.at(.kw_else)) {
            self.advance();
            if (self.at(.kw_if)) {
                const nested = try self.parseIf();
                else_body = .{ .if_stmt = nested };
                end_span = nested.span;
            } else {
                const else_block = try self.parseBlock("'{' to start the 'else' block");
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
        const block = try self.parseBlock("'{' to start the 'while' block");
        return ast.Stmt.create(self.arena, kw_tok.span.merge(block.span), .{
            .while_stmt = .{ .cond = cond, .body = block.stmts },
        });
    }

    /// switch_stmt = "switch", expr, "{", { arm }, "}" ;
    /// arm = (case_name, ["(", identifier, ")"]) | "else", "=>", block ;
    fn parseSwitch(self: *Parser) Error!*ast.Stmt {
        const kw_tok = try self.expect(.kw_switch, "'switch'");
        const scrutinee = try self.parseCondition();
        _ = try self.expect(.lbrace, "'{' to start the switch arms");

        var arms: std.ArrayList(ast.Stmt.SwitchArm) = .empty;
        var else_body: ?[]*ast.Stmt = null;
        var else_span: ?Span = null;
        var else_seen = false;

        while (!self.at(.rbrace)) {
            if (self.at(.eof)) {
                return self.fail(
                    .syntax,
                    self.current().span,
                    "switch is not closed: missing '}}' before end of file",
                    .{},
                );
            }
            // Tolerates stray separators between arms.
            if (self.at(.comma) or self.at(.semicolon)) {
                self.advance();
                continue;
            }

            const arm_tok = self.current();
            if (arm_tok.tag == .kw_else) {
                self.advance();
                _ = try self.expect(.fat_arrow, "'=>' after 'else'");
                const body = try self.parseBlock("'{' to start the 'else' arm");
                if (else_seen) {
                    return self.fail(
                        .syntax,
                        arm_tok.span,
                        "duplicate 'else' arm in the switch",
                        .{},
                    );
                }
                else_seen = true;
                else_body = body.stmts;
                else_span = arm_tok.span;
                continue;
            }

            const case_tok = try self.expectIdentifier("case name or 'else'");
            var binding: ?[]const u8 = null;
            var binding_span: ?Span = null;
            if (self.at(.lparen)) {
                self.advance();
                const name_tok = try self.expectIdentifier("name to bind the payload");
                binding = name_tok.text;
                binding_span = name_tok.span;
                _ = try self.expect(.rparen, "')' to close the payload binding");
            }
            _ = try self.expect(.fat_arrow, "'=>' after the case");
            const body = try self.parseBlock("'{' to start the arm body");

            try arms.append(self.arena, .{
                .case_name = case_tok.text,
                .case_span = case_tok.span,
                .binding = binding,
                .binding_span = binding_span,
                .body = body.stmts,
                .span = case_tok.span.merge(body.span),
            });
        }
        const close = try self.expect(.rbrace, "'}' to close the switch");

        return ast.Stmt.create(self.arena, kw_tok.span.merge(close.span), .{
            .switch_stmt = .{
                .scrutinee = scrutinee,
                .arms = try arms.toOwnedSlice(self.arena),
                .else_body = else_body,
                .else_span = else_span,
            },
        });
    }

    fn parseExprStatement(self: *Parser) Error!*ast.Stmt {
        const expr = try self.parseExpression();
        const semi = try self.expect(.semicolon, "';' after the expression");
        return ast.Stmt.create(self.arena, expr.span.merge(semi.span), .{ .expr_stmt = expr });
    }

    pub fn parseExpression(self: *Parser) Error!*ast.Expr {
        var expr = try self.parseBinary(1);
        // `expr as Type` — explicit numeric conversion. `as` binds looser than
        // all binary operators but tighter than a semicolon.
        if (self.at(.kw_as)) {
            self.advance();
            const type_name = try self.parseTypeName("type after 'as'");
            expr = try ast.Expr.create(self.arena, expr.span.merge(type_name.span), .{
                .cast = .{ .expr = expr, .type_name = type_name },
            });
        }
        return expr;
    }

    /// Condition expression: no `Name { ... }` so it does not consume the `{` of
    /// the following block.
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
            .bitor => .{ .prec = 3, .op = .bitor },
            .bitxor => .{ .prec = 4, .op = .bitxor },
            .bitand => .{ .prec = 5, .op = .bitand },
            .eq => .{ .prec = 6, .op = .eq },
            .ne => .{ .prec = 6, .op = .ne },
            .lt => .{ .prec = 7, .op = .lt },
            .le => .{ .prec = 7, .op = .le },
            .gt => .{ .prec = 7, .op = .gt },
            .ge => .{ .prec = 7, .op = .ge },
            .shl => .{ .prec = 8, .op = .shl },
            .shr => .{ .prec = 8, .op = .shr },
            .plus => .{ .prec = 9, .op = .add },
            .minus => .{ .prec = 9, .op = .sub },
            .star => .{ .prec = 10, .op = .mul },
            .slash => .{ .prec = 10, .op = .div },
            .percent => .{ .prec = 10, .op = .mod },
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
            .bitnot => {
                self.advance();
                const operand = try self.parseUnary();
                return ast.Expr.create(self.arena, tok.span.merge(operand.span), .{
                    .unary = .{ .op = .bitnot, .operand = operand },
                });
            },
            // Address-of (`&var`): unary only in operand position. The binary
            // `&` (bitwise AND) is handled in `parseBinary`.
            .bitand => {
                self.advance();
                const operand = try self.parseUnary();
                return ast.Expr.create(self.arena, tok.span.merge(operand.span), .{
                    .unary = .{ .op = .address_of, .operand = operand },
                });
            },
            // Dereference (`*ptr`): unary only in operand position. The binary
            // `*` (multiplication) is handled in `parseBinary`.
            .star => {
                self.advance();
                const operand = try self.parseUnary();
                return ast.Expr.create(self.arena, tok.span.merge(operand.span), .{
                    .unary = .{ .op = .dereference, .operand = operand },
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
            .string => {
                self.advance();
                return ast.Expr.create(self.arena, tok.span, .{ .str_literal = tok.text });
            },
            .string_unterminated => return self.fail(
                .syntax,
                tok.span,
                "unterminated string literal",
                .{},
            ),
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
                _ = try self.expect(.rparen, "')' to close the expression");
                return inner;
            },
            .invalid => return self.fail(
                .syntax,
                tok.span,
                "invalid character '{s}' in expression",
                .{if (tok.text.len > 0) tok.text else "?"},
            ),
            else => return self.fail(
                .syntax,
                tok.span,
                "expected an expression, found {s}",
                .{tok.describe()},
            ),
        }
    }

    fn parseCall(self: *Parser, callee: lexer.Token) Error!*ast.Expr {
        _ = try self.expect(.lparen, "'(' in the function call");
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
        const close = try self.expect(.rparen, "')' to close the arguments");
        return ast.Expr.create(self.arena, callee.span.merge(close.span), .{
            .call = .{
                .callee = callee.text,
                .callee_span = callee.span,
                .args = try args.toOwnedSlice(self.arena),
            },
        });
    }

    /// Consumes chained `.field` accesses over `base` and returns the outermost
    /// node. `Name.Case(...)` becomes a `method_call`, which semantics resolves
    /// as an enum constructor (other method calls are rejected there).
    fn parseFieldChain(self: *Parser, base: *ast.Expr) Error!*ast.Expr {
        var expr = base;
        while (self.at(.dot)) {
            self.advance();
            const field_tok = try self.expectIdentifier("field name after '.'");

            if (self.at(.lparen)) {
                self.advance();
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
                const close = try self.expect(.rparen, "')' to close the arguments");
                expr = try ast.Expr.create(self.arena, expr.span.merge(close.span), .{
                    .method_call = .{
                        .base = expr,
                        .name = field_tok.text,
                        .name_span = field_tok.span,
                        .args = try args.toOwnedSlice(self.arena),
                    },
                });
                continue;
            }

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

    /// `Name { field: value, ... }` — the trailing comma is optional.
    fn parseStructLiteral(self: *Parser, name_tok: lexer.Token) Error!*ast.Expr {
        _ = try self.expect(.lbrace, "'{' to start the struct literal");
        var fields: std.ArrayList(ast.Expr.FieldInit) = .empty;
        while (!self.at(.rbrace)) {
            if (self.at(.eof)) {
                return self.fail(
                    .syntax,
                    self.current().span,
                    "struct literal is not closed: missing '}}' before end of file",
                    .{},
                );
            }
            const field_name = try self.expectIdentifier("field name in the literal");
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
                    "expected ',' between literal fields or '}}' to close, found {s}",
                    .{tok.describe()},
                );
            }
        }
        const close = try self.expect(.rbrace, "'}' to close the struct literal");
        return ast.Expr.create(self.arena, name_tok.span.merge(close.span), .{
            .struct_literal = .{
                .type_name = .{ .name = name_tok.text, .span = name_tok.span },
                .fields = try fields.toOwnedSlice(self.arena),
            },
        });
    }

    /// `base.field = value;` or an expression starting with a field access.
    fn parseFieldAssignOrExpr(self: *Parser) Error!*ast.Stmt {
        const name_tok = try self.expectIdentifier("variable name");
        const base = try ast.Expr.create(self.arena, name_tok.span, .{ .identifier = name_tok.text });
        const target = try self.parseFieldChain(base);

        if (!self.at(.assign)) {
            const semi = try self.expect(.semicolon, "';' after the expression");
            return ast.Stmt.create(self.arena, target.span.merge(semi.span), .{ .expr_stmt = target });
        }

        // Only `target.field = value` is accepted; deeper chains are left to
        // semantics (a struct with a struct field does not exist yet).
        const access = switch (target.kind) {
            .field_access => |access| access,
            else => return self.fail(.syntax, target.span, "invalid assignment", .{}),
        };
        if (access.resolved_enum != null) {
            return self.fail(.syntax, target.span, "invalid assignment", .{});
        }
        self.advance(); // =
        const value = try self.parseExpression();
        const semi = try self.expect(.semicolon, "';' after the assignment");
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

/// Heap-allocated arena that keeps the address stable while the parser and
/// semantics hold `std.mem.Allocator`s derived from it.
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

test "parser: minimal program with return" {
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

test "parser: multiple functions and parameters" {
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

test "parser: let and var declarations with annotation and inference" {
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

test "parser: operator precedence" {
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

test "parser: left associativity" {
    // 10 - 3 - 2 => sub(sub(10, 3), 2)
    var parsed = try Parsed.parse("fn main() -> i32 { return 10 - 3 - 2; }");
    defer parsed.deinit();
    const ret = parsed.program.?.functions[0].body[0].kind.return_stmt.?;
    const outer = ret.kind.binary;
    try testing.expectEqual(ast.Expr.BinaryOp.sub, outer.op);
    try testing.expectEqual(ast.Expr.BinaryOp.sub, outer.lhs.kind.binary.op);
    try testing.expectEqual(@as(i64, 2), outer.rhs.kind.int_literal.value);
}

test "parser: comparisons bind looser than arithmetic" {
    // 1 + 2 < 5 => lt(add(1,2), 5)
    var parsed = try Parsed.parse("fn main() -> bool { return 1 + 2 < 5; }");
    defer parsed.deinit();
    const ret = parsed.program.?.functions[0].body[0].kind.return_stmt.?;
    try testing.expectEqual(ast.Expr.BinaryOp.lt, ret.kind.binary.op);
    try testing.expectEqual(ast.Expr.BinaryOp.add, ret.kind.binary.lhs.kind.binary.op);
}

test "parser: unary operators and parentheses" {
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

test "parser: function call with arguments" {
    var parsed = try Parsed.parse("fn main() -> i32 { return add(1, 2); }");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());
    const ret = parsed.program.?.functions[0].body[0].kind.return_stmt.?;
    const call = ret.kind.call;
    try testing.expectEqualStrings("add", call.callee);
    try testing.expectEqual(@as(usize, 2), call.args.len);
}

test "parser: spans point at the error line and column" {
    var parsed = try Parsed.parse("fn main() -> i32 {\n    return 1\n}\n");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    const diag = parsed.diags.last().?;
    try testing.expectEqual(diagnostics.Kind.syntax, diag.kind);
    try testing.expectEqual(@as(u32, 3), diag.span.line);
}

test "parser: error on declaration without initializer" {
    var parsed = try Parsed.parse("fn main() -> void { let x: i32; }");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.unsupported, parsed.diags.last().?.kind);
}

test "parser: error on top-level statement" {
    var parsed = try Parsed.parse("let x = 1;");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.last().?.kind);
}

test "parser: invalid character produces a diagnostic" {
    var parsed = try Parsed.parse("fn main() -> i32 { return @; }");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.last().?.kind);
}

test "parser: unclosed block is diagnosed" {
    var parsed = try Parsed.parse("fn main() -> i32 { return 1;");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expect(std.mem.indexOf(u8, parsed.diags.last().?.message, "not closed") != null);
}

test "parser: literal outside 64 bits is diagnosed" {
    var parsed = try Parsed.parse("fn main() -> i32 { return 99999999999999999999; }");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.integer_overflow, parsed.diags.last().?.kind);
}

test "parser: imports before functions" {
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

test "parser: import after a function is rejected" {
    var parsed = try Parsed.parse(
        \\fn main() -> i32 { return 0; }
        \\import "lib/math";
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.last().?.kind);
    try testing.expect(std.mem.indexOf(u8, parsed.diags.last().?.message, "must come before") != null);
}

test "parser: import requires a quoted string" {
    var parsed = try Parsed.parse("import lib;");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.last().?.kind);
}

test "parser: import requires a semicolon" {
    var parsed = try Parsed.parse("import \"lib/math\"");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.last().?.kind);
}

test "parser: unterminated string in import gives a specific diagnostic" {
    var parsed = try Parsed.parse("import \"lib/math;");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expect(std.mem.indexOf(u8, parsed.diags.last().?.message, "unterminated") != null);
}

test "parser: struct declaration with fields and trailing comma" {
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

test "parser: struct after a function is accepted (free order)" {
    var parsed = try Parsed.parse(
        \\fn main() -> i32 { return 0; }
        \\struct Tardio { v: i32 }
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());
    try testing.expectEqual(@as(usize, 1), parsed.program.?.structs.len);
}

test "parser: unclosed struct produces a diagnostic" {
    var parsed = try Parsed.parse("struct P { x: i32 ");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.last().?.kind);
}

test "parser: field without a type is rejected" {
    var parsed = try Parsed.parse("struct P { x }");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.last().?.kind);
}

test "parser: struct literal and field access" {
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

test "parser: if/while conditions accept field access without becoming a literal" {
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

test "parser: 'import' after struct is rejected" {
    var parsed = try Parsed.parse(
        \\struct P { x: i32 }
        \\import "lib.kyn";
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expect(std.mem.indexOf(u8, parsed.diags.last().?.message, "must come before") != null);
}

test "parser: string literal is an expression (print argument)" {
    var parsed = try Parsed.parse(
        \\fn main() -> i32 {
        \\    print("kyn");
        \\    return 0;
        \\}
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());

    const body = parsed.program.?.functions[0].body;
    const call = body[0].kind.expr_stmt.kind.call;
    try testing.expectEqualStrings("print", call.callee);
    try testing.expectEqualStrings("kyn", call.args[0].kind.str_literal);
}

test "parser: empty string is a valid expression" {
    var parsed = try Parsed.parse(
        \\fn main() -> i32 {
        \\    print("");
        \\    return 0;
        \\}
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());
    const call = parsed.program.?.functions[0].body[0].kind.expr_stmt.kind.call;
    try testing.expectEqual(@as(usize, 0), call.args[0].kind.str_literal.len);
}

test "parser: unterminated string in an expression gives a diagnostic" {
    var parsed = try Parsed.parse(
        "fn main() -> i32 {\n    print(\"sem fim);\n    return 0;\n}",
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.items.items[0].kind);
    try testing.expect(std.mem.indexOf(u8, parsed.diags.items.items[0].message, "unterminated") != null);
}

test "parser: print_i32 call with an arithmetic expression" {
    var parsed = try Parsed.parse(
        \\fn main() -> i32 {
        \\    print_i32(6 * 7);
        \\    return 0;
        \\}
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());

    const call = parsed.program.?.functions[0].body[0].kind.expr_stmt.kind.call;
    try testing.expectEqualStrings("print_i32", call.callee);
    try testing.expectEqual(ast.Expr.BinaryOp.mul, call.args[0].kind.binary.op);
}

test "parser: enum declaration with and without payload" {
    var parsed = try Parsed.parse(
        \\enum Color { Red, Green, Blue }
        \\enum Shape { Circle(i32), Empty, }
        \\fn main() -> i32 { return 0; }
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());

    const program = parsed.program.?;
    try testing.expectEqual(@as(usize, 2), program.enums.len);
    try testing.expectEqualStrings("Color", program.enums[0].name);
    try testing.expectEqual(@as(usize, 3), program.enums[0].cases.len);
    try testing.expect(program.enums[0].cases[0].payload == null);
    try testing.expectEqualStrings("Green", program.enums[0].cases[1].name);
    try testing.expectEqualStrings("Circle", program.enums[1].cases[0].name);
    try testing.expectEqualStrings("i32", program.enums[1].cases[0].payload.?.name);
    try testing.expect(program.enums[1].cases[1].payload == null);
}

test "parser: unclosed enum is diagnosed" {
    var parsed = try Parsed.parse(
        \\enum Color { Red
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expectEqual(diagnostics.Kind.syntax, parsed.diags.items.items[0].kind);
}

test "parser: switch with payload binding, plain case and else" {
    var parsed = try Parsed.parse(
        \\enum Shape { Circle(i32), Empty }
        \\fn main() -> i32 {
        \\    var s = Shape.Empty;
        \\    switch s {
        \\        Circle(r) => { return r; }
        \\        Empty => { return 0; }
        \\        else => { return 1; }
        \\    }
        \\}
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());

    const body = parsed.program.?.functions[0].body;
    try testing.expectEqual(@as(usize, 2), body.len);
    const sw = body[1].kind.switch_stmt;
    try testing.expectEqual(@as(usize, 2), sw.arms.len);
    try testing.expectEqualStrings("Circle", sw.arms[0].case_name);
    try testing.expectEqualStrings("r", sw.arms[0].binding.?);
    try testing.expectEqual(@as(usize, 1), sw.arms[0].body.len);
    try testing.expectEqualStrings("Empty", sw.arms[1].case_name);
    try testing.expect(sw.arms[1].binding == null);
    try testing.expect(sw.else_body != null);
}

test "parser: enum case and enum constructor in expressions" {
    var parsed = try Parsed.parse(
        \\enum Shape { Circle(i32), Empty }
        \\fn main() -> i32 {
        \\    let a = Shape.Empty;
        \\    let b = Shape.Circle(5);
        \\    return 0;
        \\}
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());

    const body = parsed.program.?.functions[0].body;
    const plain = body[0].kind.let_decl.init.kind.field_access;
    try testing.expectEqualStrings("Shape", plain.base.kind.identifier);
    try testing.expectEqualStrings("Empty", plain.name);

    const with_payload = body[1].kind.let_decl.init.kind.method_call;
    try testing.expectEqualStrings("Shape", with_payload.base.kind.identifier);
    try testing.expectEqualStrings("Circle", with_payload.name);
    try testing.expectEqual(@as(usize, 1), with_payload.args.len);
}

test "parser: switch arm requires '=>'" {
    var parsed = try Parsed.parse(
        \\enum Color { Red }
        \\fn main() -> i32 {
        \\    let c = Color.Red;
        \\    switch c {
        \\        Red { return 1; }
        \\    }
        \\}
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expect(
        std.mem.indexOf(u8, parsed.diags.items.items[0].message, "'=>' after the case") != null,
    );
}

test "parser: duplicate 'else' arm is diagnosed" {
    var parsed = try Parsed.parse(
        \\enum Color { Red }
        \\fn main() -> i32 {
        \\    let c = Color.Red;
        \\    switch c {
        \\        else => { return 1; }
        \\        else => { return 2; }
        \\    }
        \\}
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expect(
        std.mem.indexOf(u8, parsed.diags.items.items[0].message, "duplicate 'else' arm") != null,
    );
}

test "parser: impl block keeps its target and hands the methods to program.functions" {
    var parsed = try Parsed.parse(
        \\struct Point { x: i32, y: i32 }
        \\impl Point {
        \\    fn sum(self: Point) -> i32 { return self.x + self.y; }
        \\    fn scaled(self: Point, factor: i32) -> i32 { return self.sum() * factor; }
        \\}
        \\fn main() -> i32 { return 0; }
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.diags.count());

    const program = parsed.program.?;
    try testing.expectEqual(@as(usize, 1), program.impls.len);
    try testing.expectEqualStrings("Point", program.impls[0].type_name.name);
    try testing.expectEqual(@as(usize, 2), program.impls[0].methods.len);

    // Methods travel in the single function list, in source order.
    try testing.expectEqual(@as(usize, 3), program.functions.len);
    try testing.expectEqualStrings("sum", program.functions[0].name);
    try testing.expectEqualStrings("scaled", program.functions[1].name);
    try testing.expectEqualStrings("main", program.functions[2].name);
    try testing.expectEqualStrings("Point", program.functions[0].owner_type.?.name);
    try testing.expect(program.functions[2].owner_type == null);

    // `self.sum()` parses as a method call on the receiver.
    const body = program.functions[1].body;
    const call = body[0].kind.return_stmt.?.kind.binary.lhs.kind.method_call;
    try testing.expectEqualStrings("sum", call.name);
    try testing.expectEqualStrings("self", call.base.kind.identifier);
}

test "parser: only 'fn' is accepted inside 'impl'" {
    var parsed = try Parsed.parse(
        \\struct Point { x: i32 }
        \\impl Point {
        \\    let x = 1;
        \\}
        \\fn main() -> i32 { return 0; }
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expect(
        std.mem.indexOf(u8, parsed.diags.items.items[0].message, "expected 'fn' inside 'impl' or '}' to close") != null,
    );
}

test "parser: an unclosed impl reports the missing '}'" {
    var parsed = try Parsed.parse(
        \\struct Point { x: i32 }
        \\impl Point {
        \\    fn sum(self: Point) -> i32 { return self.x; }
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.diags.count());
    try testing.expect(
        std.mem.indexOf(u8, parsed.diags.items.items[0].message, "impl 'Point' is not closed: missing '}' before end of file") != null,
    );
}
