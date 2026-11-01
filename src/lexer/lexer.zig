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
        return .{ .input = input, .pos = 0, .line = 1 };
    }

    pub fn nextToken(self: *Lexer, allocator: std.mem.Allocator) !Token {
        _ = allocator;
        if (self.pos >= self.input.len) return Token{ .typ = .eof, .text = "", .line = self.line };
        const ch = self.input[self.pos];
        if (ch == ' ' or ch == '\t' or ch == '\n') {
            const start = self.pos;
            while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t' or self.input[self.pos] == '\n')) {
                if (self.input[self.pos] == '\n') self.line += 1;
                self.pos += 1;
            }
            return Token{ .typ = .whitespace, .text = self.input[start..self.pos], .line = self.line };
        }
        if (ch == '/' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '/') {
            const start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] != '\n') self.pos += 1;
            return Token{ .typ = .comment, .text = self.input[start..self.pos], .line = self.line };
        }
        if (ch >= 'a' and ch <= 'z' or ch >= 'A' and ch <= 'Z' or ch == '_') {
            const start = self.pos;
            while (self.pos < self.input.len and ( (self.input[self.pos] >= 'a' and self.input[self.pos] <= 'z') or (self.input[self.pos] >= 'A' and self.input[self.pos] <= 'Z') or (self.input[self.pos] >= '0' and self.input[self.pos] <= '9') or self.input[self.pos] == '_' )) {
                self.pos += 1;
            }
            return Token{ .typ = .identifier, .text = self.input[start..self.pos], .line = self.line };
        }
        if (ch >= '0' and ch <= '9') {
            const start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') self.pos += 1;
            return Token{ .typ = .number, .text = self.input[start..self.pos], .line = self.line };
        }
        // símbolo simples
        const start = self.pos;
        self.pos += 1;
        return Token{ .typ = .symbol, .text = self.input[start..self.pos], .line = self.line };
    }
};

test "lexer basic identifier" {
    const allocator = std.testing.allocator;
    var lex = Lexer.init("hello");
    const tok = try lex.nextToken(allocator);
    try std.testing.expectEqual(tok.typ, .identifier);
    try std.testing.expectEqualStrings(tok.text, "hello");
}
