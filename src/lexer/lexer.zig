//! src/lexer/lexer.zig — Lexer do Kyn.
//!
//! Converte o texto fonte em uma sequência de tokens com `Span`. O lexer não
//! interrompe a compilação no primeiro problema: ele registra um diagnóstico
//! (`E0002`), descarta o menor trecho possível e continua, para que o parser
//! ainda consiga reportar erros de sintaxe do restante do arquivo.
//!
//! Propriedade de memória: tokens referenciam slices da `source` original,
//! exceto literais de string/char, cujo conteúdo é desescapado e alocado no
//! allocator informado (a arena do pipeline).

const std = @import("std");
const diag = @import("../diag.zig");

pub const Kind = enum {
    eof,
    ident,

    kw_fn,
    kw_let,
    kw_var,
    kw_mut,
    kw_struct,
    kw_enum,
    kw_impl,
    kw_if,
    kw_else,
    kw_while,
    kw_for,
    kw_in,
    kw_return,
    kw_break,
    kw_continue,
    kw_true,
    kw_false,
    kw_unsafe,
    kw_import,
    kw_extern,
    kw_as,
    kw_self,
    kw_pub,

    int_lit,
    float_lit,
    string_lit,
    char_lit,

    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    comma,
    semicolon,
    colon,
    coloncolon,
    dot,
    dotdot,
    arrow,
    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    ampamp,
    pipe,
    pipepipe,
    caret,
    tilde,
    lt,
    le,
    gt,
    ge,
    shl,
    shr,
    eqeq,
    ne,
    bang,
    assign,
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
    percent_assign,
    hash,
    question,

    pub fn text(self: Kind) []const u8 {
        return switch (self) {
            .eof => "<eof>",
            .ident => "<ident>",
            .int_lit => "<int>",
            .float_lit => "<float>",
            .string_lit => "<string>",
            .char_lit => "<char>",
            .kw_fn => "fn",
            .kw_let => "let",
            .kw_var => "var",
            .kw_mut => "mut",
            .kw_struct => "struct",
            .kw_enum => "enum",
            .kw_impl => "impl",
            .kw_if => "if",
            .kw_else => "else",
            .kw_while => "while",
            .kw_for => "for",
            .kw_in => "in",
            .kw_return => "return",
            .kw_break => "break",
            .kw_continue => "continue",
            .kw_true => "true",
            .kw_false => "false",
            .kw_unsafe => "unsafe",
            .kw_import => "import",
            .kw_extern => "extern",
            .kw_as => "as",
            .kw_self => "self",
            .kw_pub => "pub",
            .lparen => "(",
            .rparen => ")",
            .lbrace => "{",
            .rbrace => "}",
            .lbracket => "[",
            .rbracket => "]",
            .comma => ",",
            .semicolon => ";",
            .colon => ":",
            .coloncolon => "::",
            .dot => ".",
            .dotdot => "..",
            .arrow => "->",
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .amp => "&",
            .ampamp => "&&",
            .pipe => "|",
            .pipepipe => "||",
            .caret => "^",
            .tilde => "~",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .shl => "<<",
            .shr => ">>",
            .eqeq => "==",
            .ne => "!=",
            .bang => "!",
            .assign => "=",
            .plus_assign => "+=",
            .minus_assign => "-=",
            .star_assign => "*=",
            .slash_assign => "/=",
            .percent_assign => "%=",
            .hash => "#",
            .question => "?",
        };
    }

    pub fn isKeyword(self: Kind) bool {
        return @intFromEnum(self) >= @intFromEnum(Kind.kw_fn) and
            @intFromEnum(self) <= @intFromEnum(Kind.kw_pub);
    }
};

pub const Token = struct {
    kind: Kind,
    /// Para literais de string/char, o valor já desescapado.
    text: []const u8,
    span: diag.Span,

    pub fn is(self: Token, kind: Kind) bool {
        return self.kind == kind;
    }
};

const Keyword = struct { text: []const u8, kind: Kind };

const keywords = [_]Keyword{
    .{ .text = "fn", .kind = .kw_fn },
    .{ .text = "let", .kind = .kw_let },
    .{ .text = "var", .kind = .kw_var },
    .{ .text = "mut", .kind = .kw_mut },
    .{ .text = "struct", .kind = .kw_struct },
    .{ .text = "enum", .kind = .kw_enum },
    .{ .text = "impl", .kind = .kw_impl },
    .{ .text = "if", .kind = .kw_if },
    .{ .text = "else", .kind = .kw_else },
    .{ .text = "while", .kind = .kw_while },
    .{ .text = "for", .kind = .kw_for },
    .{ .text = "in", .kind = .kw_in },
    .{ .text = "return", .kind = .kw_return },
    .{ .text = "break", .kind = .kw_break },
    .{ .text = "continue", .kind = .kw_continue },
    .{ .text = "true", .kind = .kw_true },
    .{ .text = "false", .kind = .kw_false },
    .{ .text = "unsafe", .kind = .kw_unsafe },
    .{ .text = "import", .kind = .kw_import },
    .{ .text = "extern", .kind = .kw_extern },
    .{ .text = "as", .kind = .kw_as },
    .{ .text = "self", .kind = .kw_self },
    .{ .text = "pub", .kind = .kw_pub },
};

pub const Lexer = struct {
    alloc: std.mem.Allocator,
    source: []const u8,
    pos: u32 = 0,
    diags: *diag.List,

    pub fn init(alloc: std.mem.Allocator, source: []const u8, diags: *diag.List) Lexer {
        return .{ .alloc = alloc, .source = source, .diags = diags };
    }

    pub fn tokenize(self: *Lexer) ![]Token {
        var tokens: std.ArrayList(Token) = .empty;
        while (true) {
            self.skipTrivia();
            const start = self.pos;
            if (start >= self.source.len) {
                try tokens.append(self.alloc, .{
                    .kind = .eof,
                    .text = "",
                    .span = .{ .start = start, .end = start },
                });
                break;
            }
            const token = try self.scanToken() orelse continue;
            try tokens.append(self.alloc, token);
        }
        return tokens.items;
    }

    fn peek(self: Lexer, offset: u32) u8 {
        const index = self.pos + offset;
        if (index >= self.source.len) return 0;
        return self.source[@intCast(index)];
    }

    fn atEnd(self: Lexer) bool {
        return self.pos >= self.source.len;
    }

    fn advance(self: *Lexer) u8 {
        const ch = self.source[@intCast(self.pos)];
        self.pos += 1;
        return ch;
    }

    fn errorAt(self: *Lexer, comptime fmt: []const u8, args: anytype, span: diag.Span, help: ?[]const u8) !void {
        try self.diags.add(self.alloc, .{
            .code = .lex,
            .message = try std.fmt.allocPrint(self.alloc, fmt, args),
            .span = span,
            .help = help,
        });
    }

    fn skipTrivia(self: *Lexer) void {
        while (!self.atEnd()) {
            const ch = self.source[@intCast(self.pos)];
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
                self.pos += 1;
                continue;
            }
            if (ch == '/' and self.peek(1) == '/') {
                while (!self.atEnd() and self.source[@intCast(self.pos)] != '\n') self.pos += 1;
                continue;
            }
            if (ch == '/' and self.peek(1) == '*') {
                const start = self.pos;
                self.pos += 2;
                var depth: u32 = 1;
                while (!self.atEnd() and depth > 0) {
                    if (self.source[@intCast(self.pos)] == '/' and self.peek(1) == '*') {
                        depth += 1;
                        self.pos += 2;
                    } else if (self.source[@intCast(self.pos)] == '*' and self.peek(1) == '/') {
                        depth -= 1;
                        self.pos += 2;
                    } else {
                        self.pos += 1;
                    }
                }
                if (depth != 0) {
                    self.errorAt("comentário de bloco não terminado", .{}, .{ .start = start, .end = self.pos }, "adicione `*/` para fechar o comentário") catch {};
                }
                continue;
            }
            break;
        }
    }

    fn scanToken(self: *Lexer) !?Token {
        const start = self.pos;
        const ch = self.advance();

        if (isIdentStart(ch)) {
            while (!self.atEnd() and isIdentContinue(self.source[@intCast(self.pos)])) self.pos += 1;
            const text = self.source[start..self.pos];
            for (keywords) |kw| {
                if (std.mem.eql(u8, kw.text, text)) {
                    return Token{ .kind = kw.kind, .text = text, .span = .{ .start = start, .end = self.pos } };
                }
            }
            return Token{ .kind = .ident, .text = text, .span = .{ .start = start, .end = self.pos } };
        }

        if (std.ascii.isDigit(ch)) return try self.scanNumber(start);
        if (ch == '"') return try self.scanString(start);
        if (ch == '\'') return try self.scanChar(start);

        const span = diag.Span{ .start = start, .end = start + 1 };
        const kind: Kind = switch (ch) {
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            ',' => .comma,
            ';' => .semicolon,
            '~' => .tilde,
            '#' => .hash,
            '?' => .question,
            '^' => .caret,
            '%' => if (self.peek(0) == '=') self.takeAssign(.percent_assign) else .percent,
            ':' => if (self.peek(0) == ':') self.takeAssign(.coloncolon) else .colon,
            '.' => if (self.peek(0) == '.') self.takeAssign(.dotdot) else .dot,
            '+' => if (self.peek(0) == '=') self.takeAssign(.plus_assign) else .plus,
            '-' => if (self.peek(0) == '>') self.takeAssign(.arrow) else if (self.peek(0) == '=') self.takeAssign(.minus_assign) else .minus,
            '*' => if (self.peek(0) == '=') self.takeAssign(.star_assign) else .star,
            '/' => if (self.peek(0) == '=') self.takeAssign(.slash_assign) else .slash,
            '&' => if (self.peek(0) == '&') self.takeAssign(.ampamp) else .amp,
            '|' => if (self.peek(0) == '|') self.takeAssign(.pipepipe) else .pipe,
            '=' => if (self.peek(0) == '=') self.takeAssign(.eqeq) else .assign,
            '!' => if (self.peek(0) == '=') self.takeAssign(.ne) else .bang,
            '<' => if (self.peek(0) == '<')
                self.takeAssign(.shl)
            else if (self.peek(0) == '=')
                self.takeAssign(.le)
            else
                .lt,
            '>' => if (self.peek(0) == '>')
                self.takeAssign(.shr)
            else if (self.peek(0) == '=')
                self.takeAssign(.ge)
            else
                .gt,
            else => {
                try self.errorAt("caractere inesperado '{c}'", .{ch}, span, null);
                return null;
            },
        };
        return Token{ .kind = kind, .text = kind.text(), .span = .{ .start = start, .end = self.pos } };
    }

    /// Consome um segundo caractere de operadores de dois símbolos.
    fn takeAssign(self: *Lexer, kind: Kind) Kind {
        self.pos += 1;
        return kind;
    }

    fn scanNumber(self: *Lexer, start: u32) !Token {
        var is_float = false;
        if (self.source[@intCast(start)] == '0' and (self.peek(0) == 'x' or self.peek(0) == 'b' or self.peek(0) == 'o')) {
            self.pos += 1; // prefixo
            const digits_start = self.pos;
            while (!self.atEnd() and (std.ascii.isDigit(self.source[@intCast(self.pos)]) or
                std.ascii.isAlphabetic(self.source[@intCast(self.pos)]) or
                self.source[@intCast(self.pos)] == '_')) self.pos += 1;
            if (self.pos == digits_start) {
                try self.errorAt("literal numérico sem dígitos após o prefixo", .{}, .{ .start = start, .end = self.pos }, null);
            }
            return Token{ .kind = .int_lit, .text = self.source[start..self.pos], .span = .{ .start = start, .end = self.pos } };
        }

        while (!self.atEnd()) {
            const ch = self.source[@intCast(self.pos)];
            if (std.ascii.isDigit(ch) or ch == '_') {
                self.pos += 1;
            } else if (ch == '.' and std.ascii.isDigit(self.peek(1))) {
                // `1..10` continua sendo inteiro seguido de `..`.
                is_float = true;
                self.pos += 1;
            } else if ((ch == 'e' or ch == 'E') and (std.ascii.isDigit(self.peek(1)) or
                ((self.peek(1) == '+' or self.peek(1) == '-') and std.ascii.isDigit(self.peek(2)))))
            {
                is_float = true;
                self.pos += 1;
                if (self.peek(0) == '+' or self.peek(0) == '-') self.pos += 1;
            } else break;
        }
        return Token{
            .kind = if (is_float) .float_lit else .int_lit,
            .text = self.source[start..self.pos],
            .span = .{ .start = start, .end = self.pos },
        };
    }

    fn scanString(self: *Lexer, start: u32) !?Token {
        var value: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.atEnd()) {
                try self.errorAt("string não terminada", .{}, .{ .start = start, .end = self.pos }, "adicione `\"` para fechar a string");
                return null;
            }
            const ch = self.advance();
            if (ch == '"') break;
            if (ch == '\n') {
                try self.errorAt("string não terminada antes do fim da linha", .{}, .{ .start = start, .end = self.pos }, null);
                return null;
            }
            if (ch != '\\') {
                try value.append(self.alloc, ch);
                continue;
            }
            if (self.atEnd()) {
                try self.errorAt("escape incompleto no fim do arquivo", .{}, .{ .start = self.pos - 1, .end = self.pos }, null);
                return null;
            }
            const esc = self.advance();
            const esc_span = diag.Span{ .start = self.pos - 2, .end = self.pos };
            switch (esc) {
                'n' => try value.append(self.alloc, '\n'),
                't' => try value.append(self.alloc, '\t'),
                'r' => try value.append(self.alloc, '\r'),
                '0' => try value.append(self.alloc, 0),
                '\\' => try value.append(self.alloc, '\\'),
                '"' => try value.append(self.alloc, '"'),
                '\'' => try value.append(self.alloc, '\''),
                'x' => {
                    const hi = self.peek(0);
                    const lo = self.peek(1);
                    if (!isHexDigit(hi) or !isHexDigit(lo)) {
                        try self.errorAt("escape hexadecimal `\\x` exige dois dígitos", .{}, esc_span, null);
                        return null;
                    }
                    _ = self.advance();
                    _ = self.advance();
                    const byte = (try std.fmt.charToDigit(hi, 16)) * 16 + (try std.fmt.charToDigit(lo, 16));
                    try value.append(self.alloc, @intCast(byte));
                },
                else => {
                    try self.errorAt("escape desconhecido `\\{c}`", .{esc}, esc_span, "escapes válidos: \\n \\t \\r \\0 \\\\ \\\" \\' \\xNN");
                    return null;
                },
            }
        }
        return Token{
            .kind = .string_lit,
            .text = value.items,
            .span = .{ .start = start, .end = self.pos },
        };
    }

    fn scanChar(self: *Lexer, start: u32) !?Token {
        var value: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.atEnd()) {
                try self.errorAt("literal de char não terminado", .{}, .{ .start = start, .end = self.pos }, null);
                return null;
            }
            const ch = self.advance();
            if (ch == '\'') break;
            if (ch == '\n') {
                try self.errorAt("literal de char não terminado antes do fim da linha", .{}, .{ .start = start, .end = self.pos }, null);
                return null;
            }
            if (ch != '\\') {
                try value.append(self.alloc, ch);
                continue;
            }
            const esc = self.advance();
            const esc_span = diag.Span{ .start = self.pos - 2, .end = self.pos };
            switch (esc) {
                'n' => try value.append(self.alloc, '\n'),
                't' => try value.append(self.alloc, '\t'),
                'r' => try value.append(self.alloc, '\r'),
                '0' => try value.append(self.alloc, 0),
                '\\' => try value.append(self.alloc, '\\'),
                '\'' => try value.append(self.alloc, '\''),
                '"' => try value.append(self.alloc, '"'),
                else => {
                    try self.errorAt("escape desconhecido `\\{c}`", .{esc}, esc_span, null);
                    return null;
                },
            }
        }
        if (value.items.len != 1) {
            try self.errorAt("literal de char deve conter exatamente um byte", .{}, .{ .start = start, .end = self.pos }, null);
            return null;
        }
        return Token{
            .kind = .char_lit,
            .text = value.items,
            .span = .{ .start = start, .end = self.pos },
        };
    }
};

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn isHexAlpha(ch: u8) bool {
    return (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}

fn isHexDigit(ch: u8) bool {
    return std.ascii.isDigit(ch) or isHexAlpha(ch);
}

fn lexTokens(alloc: std.mem.Allocator, source: []const u8, diags: *diag.List) ![]Token {
    var lexer = Lexer.init(alloc, source, diags);
    return lexer.tokenize();
}

test "lexes identifiers, keywords and operators" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var diags: diag.List = .{};

    const tokens = try lexTokens(a, "fn add(a: i32) -> i32 { return a + 1; }", &diags);
    try std.testing.expect(!diags.hasErrors());
    const expected = [_]Kind{
        .kw_fn,      .ident,    .lparen,    .ident, .colon,
        .ident,      .rparen,   .arrow,     .ident, .lbrace,
        .kw_return,  .ident,    .plus,      .int_lit, .semicolon,
        .rbrace,     .eof,
    };
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, 0..) |kind, i| {
        try std.testing.expectEqual(kind, tokens[i].kind);
    }
}

test "lexes multi-character operators" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var diags: diag.List = .{};
    const tokens = try lexTokens(arena.allocator(), "<= >= == != && || -> :: .. += # << >>", &diags);
    const expected = [_]Kind{ .le, .ge, .eqeq, .ne, .ampamp, .pipepipe, .arrow, .coloncolon, .dotdot, .plus_assign, .hash, .shl, .shr, .eof };
    for (expected, 0..) |kind, i| try std.testing.expectEqual(kind, tokens[i].kind);
}

test "lexes literals with escapes" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var diags: diag.List = .{};
    const tokens = try lexTokens(arena.allocator(), "\"a\\nb\" 'z' 0xFF 1_000 2.5 1e3", &diags);
    try std.testing.expect(!diags.hasErrors());
    try std.testing.expectEqual(Kind.string_lit, tokens[0].kind);
    try std.testing.expectEqualStrings("a\nb", tokens[0].text);
    try std.testing.expectEqual(Kind.char_lit, tokens[1].kind);
    try std.testing.expectEqualStrings("z", tokens[1].text);
    try std.testing.expectEqual(Kind.int_lit, tokens[2].kind);
    try std.testing.expectEqualStrings("0xFF", tokens[2].text);
    try std.testing.expectEqualStrings("1_000", tokens[3].text);
    try std.testing.expectEqual(Kind.float_lit, tokens[4].kind);
    try std.testing.expectEqual(Kind.float_lit, tokens[5].kind);
}

test "range token is not lexed as float" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var diags: diag.List = .{};
    const tokens = try lexTokens(arena.allocator(), "0..10", &diags);
    try std.testing.expectEqual(Kind.int_lit, tokens[0].kind);
    try std.testing.expectEqual(Kind.dotdot, tokens[1].kind);
    try std.testing.expectEqual(Kind.int_lit, tokens[2].kind);
}

test "unterminated string reports E0002 and recovers" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var diags: diag.List = .{};
    const tokens = try lexTokens(arena.allocator(), "let s = \"abc\nlet t = 1;", &diags);
    try std.testing.expect(diags.hasCode(.lex));
    // A tokenização continua após o erro.
    var saw_kw_let = false;
    for (tokens) |t| {
        if (t.kind == .kw_let) saw_kw_let = true;
    }
    try std.testing.expect(saw_kw_let);
}

test "unknown character reports E0002 without stopping" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var diags: diag.List = .{};
    const tokens = try lexTokens(arena.allocator(), "a $ b", &diags);
    try std.testing.expect(diags.hasCode(.lex));
    try std.testing.expectEqual(Kind.ident, tokens[0].kind);
    try std.testing.expectEqual(Kind.ident, tokens[1].kind);
}

test "spans point at source offsets" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var diags: diag.List = .{};
    const source = "let x = 1;";
    const tokens = try lexTokens(arena.allocator(), source, &diags);
    try std.testing.expectEqual(@as(u32, 8), tokens[3].span.start);
    try std.testing.expectEqual(@as(u32, 9), tokens[3].span.end);
    try std.testing.expectEqualStrings("1", source[tokens[3].span.start..tokens[3].span.end]);
}
