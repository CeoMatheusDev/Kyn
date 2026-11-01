const std = @import("std");
const ast = @import("../ast/ast.zig");
const lexer = @import("../lexer/lexer.zig");

pub const Parser = struct {
    tokens: []const lexer.Token,
    pos: usize,
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator, tokens: []const lexer.Token) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .arena = arena,
        };
    }

    fn current(self: *Parser) ?lexer.Token {
        if (self.pos >= self.tokens.len) return null;
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.tokens.len) self.pos += 1;
    }

    pub fn parseProgram(self: *Parser) !*ast.Node {
        const root = try ast.Node.init(self.arena, .program);
        root.line = if (self.current()) |t| t.line else 0;
        while (self.current()) |t| {
            if (t.typ == .eof) break;
            // Ignorar whitespace/comment para simplificação inicial
            if (t.typ == .whitespace or t.typ == .comment) {
                self.advance();
                continue;
            }
            const stmt = try self.parseStatement();
            // Para simplificação, apenas armazenamos o primeiro nó no texto
            root.text = try std.fmt.allocPrint(self.arena, "{any}", .{stmt.typ});
            break;
        }
        return root;
    }

    fn parseStatement(self: *Parser) !*ast.Node {
        // Padrão básico para declaração de variável (simplificado para Marco 1.2)
        const tok = self.current() orelse return error.UnexpectedToken;
        if (tok.typ == .identifier) {
            const decl = try ast.Node.init(self.arena, .variable_decl);
            decl.text = tok.text;
            decl.line = tok.line;
            self.advance();
            return decl;
        }
        return error.UnexpectedToken;
    }

    pub fn parseExpression(self: *Parser) !*ast.Node {
        const tok = self.current() orelse return error.ExpectedExpression;
        if (tok.typ == .number) {
            const lit = try ast.Node.init(self.arena, .literal_int);
            lit.text = tok.text;
            lit.line = tok.line;
            self.advance();
            return lit;
        } else if (tok.typ == .identifier) {
            const id = try ast.Node.init(self.arena, .identifier);
            id.text = tok.text;
            id.line = tok.line;
            self.advance();
            return id;
        }
        return error.ExpectedExpression;
    }
};
