const std = @import("std");

pub const TokenType = enum {
    identifier,
    number,
    symbol,
    comment,
    whitespace,
    eof,
};

pub const Token = struct {
    typ: TokenType,
    text: []const u8,
    line: u32,
};

pub const Lexer = struct {
    input: []const u8,
    pos: usize,
    line: u32,

    pub fn init(input: []const u8) Lexer {
        return .{
            .input = input,
            .pos = 0,
            .line = 1,
        };
    }

    pub fn nextToken(self: *Lexer, allocator: std.mem.Allocator) !Token {
        _ = allocator;

        if (self.pos >= self.input.len) {
            return self.makeToken(.eof, self.pos, self.pos, self.line);
        }

        const start = self.pos;
        const start_line = self.line;
        const ch = self.input[self.pos];

        if (isWhitespace(ch)) {
            while (self.pos < self.input.len and isWhitespace(self.input[self.pos])) {
                self.consumeNewline();
            }
            return self.makeToken(.whitespace, start, self.pos, start_line);
        }

        if (ch == '/' and self.peek(1) == '/') {
            self.pos += 2;
            while (self.pos < self.input.len and self.input[self.pos] != '\n' and self.input[self.pos] != '\r') {
                self.pos += 1;
            }
            return self.makeToken(.comment, start, self.pos, start_line);
        }

        if (isIdentifierStart(ch)) {
            self.pos += 1;
            while (self.pos < self.input.len and isIdentifierContinue(self.input[self.pos])) {
                self.pos += 1;
            }
            return self.makeToken(.identifier, start, self.pos, start_line);
        }

        if (isDigit(ch)) {
            self.pos += 1;
            while (self.pos < self.input.len and isDigit(self.input[self.pos])) {
                self.pos += 1;
            }
            return self.makeToken(.number, start, self.pos, start_line);
        }

        // Operadores e delimitadores ainda são emitidos como símbolos individuais.
        self.pos += 1;
        return self.makeToken(.symbol, start, self.pos, start_line);
    }

    fn makeToken(self: *const Lexer, typ: TokenType, start: usize, end: usize, line: u32) Token {
        return .{
            .typ = typ,
            .text = self.input[start..end],
            .line = line,
        };
    }

    fn peek(self: *const Lexer, offset: usize) ?u8 {
        const index = self.pos + offset;
        if (index >= self.input.len) return null;
        return self.input[index];
    }

    fn consumeNewline(self: *Lexer) void {
        const ch = self.input[self.pos];
        if (ch == '\r') {
            self.pos += 1;
            if (self.pos < self.input.len and self.input[self.pos] == '\n') {
                self.pos += 1;
            }
            self.line += 1;
            return;
        }

        if (ch == '\n') self.line += 1;
        self.pos += 1;
    }

    fn isWhitespace(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
    }

    fn isDigit(ch: u8) bool {
        return ch >= '0' and ch <= '9';
    }

    fn isIdentifierStart(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            ch == '_';
    }

    fn isIdentifierContinue(ch: u8) bool {
        return isIdentifierStart(ch) or isDigit(ch);
    }
};

test "lexer reads an identifier" {
    var lex = Lexer.init("hello");
    const tok = try lex.nextToken(std.testing.allocator);
    try std.testing.expectEqual(TokenType.identifier, tok.typ);
    try std.testing.expectEqualStrings("hello", tok.text);
    try std.testing.expectEqual(@as(u32, 1), tok.line);
}

test "lexer preserves token start line across whitespace" {
    var lex = Lexer.init("\n\n  value");
    const whitespace = try lex.nextToken(std.testing.allocator);
    const identifier = try lex.nextToken(std.testing.allocator);

    try std.testing.expectEqual(TokenType.whitespace, whitespace.typ);
    try std.testing.expectEqual(@as(u32, 1), whitespace.line);
    try std.testing.expectEqual(TokenType.identifier, identifier.typ);
    try std.testing.expectEqual(@as(u32, 3), identifier.line);
}

test "lexer treats CRLF as one newline" {
    var lex = Lexer.init("\r\nname");
    _ = try lex.nextToken(std.testing.allocator);
    const identifier = try lex.nextToken(std.testing.allocator);

    try std.testing.expectEqualStrings("name", identifier.text);
    try std.testing.expectEqual(@as(u32, 2), identifier.line);
}

test "lexer reads line comments without consuming newline" {
    var lex = Lexer.init("// comment\nnext");
    const comment = try lex.nextToken(std.testing.allocator);
    const whitespace = try lex.nextToken(std.testing.allocator);
    const identifier = try lex.nextToken(std.testing.allocator);

    try std.testing.expectEqual(TokenType.comment, comment.typ);
    try std.testing.expectEqualStrings("// comment", comment.text);
    try std.testing.expectEqual(TokenType.whitespace, whitespace.typ);
    try std.testing.expectEqualStrings("next", identifier.text);
    try std.testing.expectEqual(@as(u32, 2), identifier.line);
}

test "lexer reads integers and single-character symbols" {
    var lex = Lexer.init("123 +");
    const number = try lex.nextToken(std.testing.allocator);
    const whitespace = try lex.nextToken(std.testing.allocator);
    const symbol = try lex.nextToken(std.testing.allocator);

    try std.testing.expectEqual(TokenType.number, number.typ);
    try std.testing.expectEqualStrings("123", number.text);
    try std.testing.expectEqual(TokenType.whitespace, whitespace.typ);
    try std.testing.expectEqual(TokenType.symbol, symbol.typ);
    try std.testing.expectEqualStrings("+", symbol.text);
}

test "lexer returns stable EOF tokens" {
    var lex = Lexer.init("");
    const first = try lex.nextToken(std.testing.allocator);
    const second = try lex.nextToken(std.testing.allocator);

    try std.testing.expectEqual(TokenType.eof, first.typ);
    try std.testing.expectEqual(TokenType.eof, second.typ);
    try std.testing.expectEqual(@as(usize, 0), first.text.len);
}
