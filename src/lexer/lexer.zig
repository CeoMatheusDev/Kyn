//! Lexer do bootstrap em Zig.
//!
//! Contrato:
//! - Tokens guardam `text` como slice da entrada original (sem cópia).
//! - Todos os tokens carregam um `Span` (offset, linha e coluna 1-based).
//! - Espaços em branco e comentários `// ...` são descartados na tokenização;
//!   não são entregues ao parser.
//! - Um caractere não reconhecido produz um token `.invalid`; o parser o
//!   converte em diagnóstico com a posição exata.
//!
//! Este contrato substitui a classificação genérica anterior
//! (`identifier`/`symbol`/`whitespace`/`comment`) que não permitia ao parser
//! distinguir operadores de pontuação.

const std = @import("std");
const Span = @import("../span.zig").Span;

pub const Tag = enum {
    // literais e nome
    identifier,
    integer,

    // palavras-chave
    kw_fn,
    kw_let,
    kw_var,
    kw_return,
    kw_if,
    kw_else,
    kw_while,
    kw_true,
    kw_false,

    // pontuação
    lparen,
    rparen,
    lbrace,
    rbrace,
    colon,
    semicolon,
    comma,
    arrow, // ->

    // operadores
    assign, // =
    eq, // ==
    ne, // !=
    lt, // <
    le, // <=
    gt, // >
    ge, // >=
    plus, // +
    minus, // -
    star, // *
    slash, // /
    percent, // %
    bang, // !
    amp_amp, // &&
    pipe_pipe, // ||

    /// Caractere não reconhecido pelo lexer.
    invalid,
    eof,
};

pub const Token = struct {
    tag: Tag,
    span: Span,
    text: []const u8,

    pub fn init(tag: Tag, span: Span, text: []const u8) Token {
        return .{ .tag = tag, .span = span, .text = text };
    }

    /// Descrição legível usada em diagnósticos.
    pub fn describe(self: Token) []const u8 {
        return switch (self.tag) {
            .identifier => "identificador",
            .integer => "número inteiro",
            .kw_fn => "'fn'",
            .kw_let => "'let'",
            .kw_var => "'var'",
            .kw_return => "'return'",
            .kw_if => "'if'",
            .kw_else => "'else'",
            .kw_while => "'while'",
            .kw_true => "'true'",
            .kw_false => "'false'",
            .lparen => "'('",
            .rparen => "')'",
            .lbrace => "'{'",
            .rbrace => "'}'",
            .colon => "':'",
            .semicolon => "';'",
            .comma => "','",
            .arrow => "'->'",
            .assign => "'='",
            .eq => "'=='",
            .ne => "'!='",
            .lt => "'<'",
            .le => "'<='",
            .gt => "'>'",
            .ge => "'>='",
            .plus => "'+'",
            .minus => "'-'",
            .star => "'*'",
            .slash => "'/'",
            .percent => "'%'",
            .bang => "'!'",
            .amp_amp => "'&&'",
            .pipe_pipe => "'||'",
            .invalid => "caractere inválido",
            .eof => "fim do arquivo",
        };
    }

    pub fn isKeyword(self: Token) bool {
        return switch (self.tag) {
            .kw_fn, .kw_let, .kw_var, .kw_return, .kw_if, .kw_else, .kw_while, .kw_true, .kw_false => true,
            else => false,
        };
    }
};

fn keywordTag(text: []const u8) ?Tag {
    const map = std.StaticStringMap(Tag).initComptime(.{
        .{ "fn", .kw_fn },
        .{ "let", .kw_let },
        .{ "var", .kw_var },
        .{ "return", .kw_return },
        .{ "if", .kw_if },
        .{ "else", .kw_else },
        .{ "while", .kw_while },
        .{ "true", .kw_true },
        .{ "false", .kw_false },
    });
    return map.get(text);
}

pub const Lexer = struct {
    source: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    fn column(self: *const Lexer, offset: usize) u32 {
        return @intCast(offset - self.line_start + 1);
    }

    fn makeSpan(self: *const Lexer, start: usize, start_line: u32, start_column: u32) Span {
        return .{
            .start = @intCast(start),
            .end = @intCast(self.pos),
            .line = start_line,
            .column = start_column,
        };
    }

    fn peek(self: *const Lexer) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn peekAt(self: *const Lexer, offset: usize) ?u8 {
        const idx = self.pos + offset;
        if (idx >= self.source.len) return null;
        return self.source[idx];
    }

    fn bump(self: *Lexer) void {
        if (self.pos < self.source.len) self.pos += 1;
    }

    /// Descarta espaços, tabulações, retornos de carro, quebras de linha e
    /// comentários de linha (`// ...`).
    fn skipTrivia(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            switch (ch) {
                ' ', '\t', '\r' => self.pos += 1,
                '\n' => {
                    self.pos += 1;
                    self.line += 1;
                    self.line_start = self.pos;
                },
                '/' => {
                    if (self.peekAt(1) != '/') return;
                    while (self.pos < self.source.len and self.source[self.pos] != '\n') self.pos += 1;
                },
                else => return,
            }
        }
    }

    /// Retorna o próximo token significativo (nunca whitespace/comentário).
    pub fn next(self: *Lexer) Token {
        self.skipTrivia();

        const start = self.pos;
        const start_line = self.line;
        const start_column = self.column(start);

        const ch = self.peek() orelse {
            return Token.init(.eof, .{
                .start = @intCast(start),
                .end = @intCast(start),
                .line = start_line,
                .column = start_column,
            }, "");
        };

        if (isIdentStart(ch)) {
            self.bump();
            while (self.peek()) |c| {
                if (!isIdentContinue(c)) break;
                self.bump();
            }
            const text = self.source[start..self.pos];
            const tag = keywordTag(text) orelse .identifier;
            return Token.init(tag, self.makeSpan(start, start_line, start_column), text);
        }

        if (std.ascii.isDigit(ch)) {
            self.bump();
            while (self.peek()) |c| {
                if (!std.ascii.isDigit(c)) break;
                self.bump();
            }
            return Token.init(.integer, self.makeSpan(start, start_line, start_column), self.source[start..self.pos]);
        }

        self.bump();
        const tag: Tag = switch (ch) {
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            ':' => .colon,
            ';' => .semicolon,
            ',' => .comma,
            '+' => .plus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '=' => if (self.eat('=')) .eq else .assign,
            '!' => if (self.eat('=')) .ne else .bang,
            '<' => if (self.eat('=')) .le else .lt,
            '>' => if (self.eat('=')) .ge else .gt,
            '-' => if (self.eat('>')) .arrow else .minus,
            '&' => if (self.eat('&')) .amp_amp else .invalid,
            '|' => if (self.eat('|')) .pipe_pipe else .invalid,
            else => .invalid,
        };
        return Token.init(tag, self.makeSpan(start, start_line, start_column), self.source[start..self.pos]);
    }

    fn eat(self: *Lexer, expected: u8) bool {
        if (self.peek()) |c| {
            if (c == expected) {
                self.bump();
                return true;
            }
        }
        return false;
    }

    /// Tokeniza a entrada inteira, alocando em `gpa`. O token final é `.eof`.
    /// O chamador é dono do slice retornado.
    pub fn tokenize(self: *Lexer, gpa: std.mem.Allocator) ![]Token {
        var list: std.ArrayList(Token) = .empty;
        errdefer list.deinit(gpa);
        while (true) {
            const tok = self.next();
            try list.append(gpa, tok);
            if (tok.tag == .eof) break;
        }
        return list.toOwnedSlice(gpa);
    }
};

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn collect(source: []const u8, buf: []Token) []Token {
    var lex = Lexer.init(source);
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        buf[i] = lex.next();
        if (buf[i].tag == .eof) return buf[0 .. i + 1];
    }
    return buf[0..i];
}

fn expectTags(source: []const u8, expected: []const Tag) !void {
    var buf: [64]Token = undefined;
    const toks = collect(source, &buf);
    try std.testing.expectEqual(expected.len, toks.len);
    for (expected, toks) |want, got| {
        try std.testing.expectEqual(want, got.tag);
    }
}

test "lexer: identificadores e palavras-chave" {
    try expectTags("fn main let var return if else while true false x1 _y", &.{
        .kw_fn, .identifier, .kw_let, .kw_var, .kw_return, .kw_if, .kw_else, .kw_while, .kw_true, .kw_false, .identifier, .identifier, .eof,
    });
}

test "lexer: palavras-chave preservam o texto original" {
    var lex = Lexer.init("let");
    const tok = lex.next();
    try std.testing.expectEqual(Tag.kw_let, tok.tag);
    try std.testing.expectEqualStrings("let", tok.text);
}

test "lexer: operadores de dois caracteres" {
    try expectTags("-> == != <= >= && || < > = ! + - * / %", &.{
        .arrow, .eq, .ne, .le, .ge, .amp_amp, .pipe_pipe, .lt, .gt, .assign, .bang, .plus, .minus, .star, .slash, .percent, .eof,
    });
}

test "lexer: pontuação" {
    try expectTags("( ) { } : ; ,", &.{ .lparen, .rparen, .lbrace, .rbrace, .colon, .semicolon, .comma, .eof });
}

test "lexer: descarta comentários e espaços" {
    try expectTags("// comentário\n  let   x = 1; // fim\n", &.{ .kw_let, .identifier, .assign, .integer, .semicolon, .eof });
}

test "lexer: spans com linha e coluna" {
    var lex = Lexer.init("let x = 10;\n  return x;");
    const let_tok = lex.next();
    try std.testing.expectEqual(@as(u32, 1), let_tok.span.line);
    try std.testing.expectEqual(@as(u32, 1), let_tok.span.column);
    _ = lex.next(); // x
    _ = lex.next(); // =
    const ten = lex.next();
    try std.testing.expectEqualStrings("10", ten.text);
    _ = lex.next(); // ;
    const ret = lex.next();
    try std.testing.expectEqual(Tag.kw_return, ret.tag);
    try std.testing.expectEqual(@as(u32, 2), ret.span.line);
    try std.testing.expectEqual(@as(u32, 3), ret.span.column);
}

test "lexer: inteiros" {
    var lex = Lexer.init("0 42 1234567");
    for ([_][]const u8{ "0", "42", "1234567" }) |want| {
        const tok = lex.next();
        try std.testing.expectEqual(Tag.integer, tok.tag);
        try std.testing.expectEqualStrings(want, tok.text);
    }
    try std.testing.expectEqual(Tag.eof, lex.next().tag);
}

test "lexer: caractere inválido não causa panic" {
    var lex = Lexer.init("@");
    const tok = lex.next();
    try std.testing.expectEqual(Tag.invalid, tok.tag);
    try std.testing.expectEqual(Tag.eof, lex.next().tag);
}

test "lexer: and e or isolados são inválidos" {
    try expectTags("& |", &.{ .invalid, .invalid, .eof });
}

test "lexer: tokenize aloca e encerra com eof" {
    const gpa = std.testing.allocator;
    var lex = Lexer.init("let x = 1;");
    const toks = try lex.tokenize(gpa);
    defer gpa.free(toks);
    try std.testing.expectEqual(@as(usize, 6), toks.len);
    try std.testing.expectEqual(Tag.eof, toks[toks.len - 1].tag);
}
