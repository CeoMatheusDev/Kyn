//! Bootstrap lexer, written in Zig.
//!
//! Contract:
//! - Tokens keep `text` as a slice of the original input (no copy).
//! - Every token carries a `Span` (offset, 1-based line and column).
//! - Whitespace and `// ...` comments are discarded while tokenizing;
//!   they never reach the parser.
//! - An unrecognized character produces an `.invalid` token; the parser turns
//!   it into a diagnostic with the exact position.
//!
//! This contract replaces the previous generic classification
//! (`identifier`/`symbol`/`whitespace`/`comment`) which did not let the parser
//! tell operators from punctuation.

const std = @import("std");
const Span = @import("../span.zig").Span;

pub const Tag = enum {
    // literals and names
    identifier,
    integer,
    /// Content of a string literal (no quotes, no escape interpretation).
    string,

    // keywords
    kw_fn,
    kw_import,
    kw_struct,
    kw_let,
    kw_var,
    kw_return,
    kw_if,
    kw_else,
    kw_while,
    kw_enum,
    kw_switch,
    kw_impl,
    kw_true,
    kw_false,

    // punctuation
    lparen,
    rparen,
    lbrace,
    rbrace,
    colon,
    semicolon,
    comma,
    dot, // .
    arrow, // ->
    fat_arrow, // =>

    // operators
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

    /// String literal without a closing quote (up to end of line/file).
    string_unterminated,

    /// Character the lexer does not recognize.
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

    /// Human-readable description used in diagnostics.
    pub fn describe(self: Token) []const u8 {
        return switch (self.tag) {
            .identifier => "identifier",
            .integer => "integer",
            .string => "string literal",
            .kw_fn => "'fn'",
            .kw_import => "'import'",
            .kw_struct => "'struct'",
            .kw_let => "'let'",
            .kw_var => "'var'",
            .kw_return => "'return'",
            .kw_if => "'if'",
            .kw_else => "'else'",
            .kw_while => "'while'",
            .kw_enum => "'enum'",
            .kw_switch => "'switch'",
            .kw_impl => "'impl'",
            .kw_true => "'true'",
            .kw_false => "'false'",
            .lparen => "'('",
            .rparen => "')'",
            .lbrace => "'{'",
            .rbrace => "'}'",
            .colon => "':'",
            .semicolon => "';'",
            .comma => "','",
            .dot => "'.'",
            .arrow => "'->'",
            .fat_arrow => "'=>'",
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
            .string_unterminated => "unterminated string literal",
            .invalid => "invalid character",
            .eof => "end of file",
        };
    }

    pub fn isKeyword(self: Token) bool {
        return switch (self.tag) {
            .kw_fn, .kw_struct, .kw_let, .kw_var, .kw_return, .kw_if, .kw_else, .kw_while, .kw_enum, .kw_switch, .kw_impl, .kw_true, .kw_false => true,
            else => false,
        };
    }
};

fn keywordTag(text: []const u8) ?Tag {
    const map = std.StaticStringMap(Tag).initComptime(.{
        .{ "fn", .kw_fn },
        .{ "import", .kw_import },
        .{ "struct", .kw_struct },
        .{ "let", .kw_let },
        .{ "var", .kw_var },
        .{ "return", .kw_return },
        .{ "if", .kw_if },
        .{ "else", .kw_else },
        .{ "while", .kw_while },
        .{ "enum", .kw_enum },
        .{ "switch", .kw_switch },
        .{ "impl", .kw_impl },
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

    /// Skips spaces, tabs, carriage returns, line breaks and
    /// line comments (`// ...`).
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

    /// Returns the next significant token (never whitespace/comment).
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

        if (ch == '"') return self.scanString(start, start_line, start_column);

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
            '.' => .dot,
            '+' => .plus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '=' => if (self.eat('=')) .eq else if (self.eat('>')) .fat_arrow else .assign,
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

    /// String literal: `"content"`. No escape interpretation and no line
    /// breaks; quotes cannot be escaped at this stage.
    /// `text` holds only the content, without quotes; the span covers the quotes.
    fn scanString(self: *Lexer, start: usize, start_line: u32, start_column: u32) Token {
        self.bump(); // aspa de abertura
        const content_start = self.pos;

        while (self.peek()) |c| {
            if (c == '"') {
                const content = self.source[content_start..self.pos];
                self.bump(); // aspa de fechamento
                return Token.init(.string, self.makeSpan(start, start_line, start_column), content);
            }
            if (c == '\n') break; // strings do not span lines
            self.bump();
        }

        return Token.init(
            .string_unterminated,
            self.makeSpan(start, start_line, start_column),
            self.source[start..self.pos],
        );
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

    /// Tokenizes the whole input, allocating from `gpa`. The last token is `.eof`.
    /// The caller owns the returned slice.
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

test "lexer: identifiers and keywords" {
    try expectTags("fn main let var return if else while true false x1 _y", &.{
        .kw_fn, .identifier, .kw_let, .kw_var, .kw_return, .kw_if, .kw_else, .kw_while, .kw_true, .kw_false, .identifier, .identifier, .eof,
    });
}

test "lexer: keywords keep the original text" {
    var lex = Lexer.init("let");
    const tok = lex.next();
    try std.testing.expectEqual(Tag.kw_let, tok.tag);
    try std.testing.expectEqualStrings("let", tok.text);
}

test "lexer: two-character operators" {
    try expectTags("-> == != <= >= && || < > = ! + - * / %", &.{
        .arrow, .eq, .ne, .le, .ge, .amp_amp, .pipe_pipe, .lt, .gt, .assign, .bang, .plus, .minus, .star, .slash, .percent, .eof,
    });
}

test "lexer: punctuation" {
    try expectTags("( ) { } : ; ,", &.{ .lparen, .rparen, .lbrace, .rbrace, .colon, .semicolon, .comma, .eof });
}

test "lexer: discards comments and whitespace" {
    try expectTags("// comment\n  let   x = 1; // end\n", &.{ .kw_let, .identifier, .assign, .integer, .semicolon, .eof });
}

test "lexer: spans carry line and column" {
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

test "lexer: invalid character does not panic" {
    var lex = Lexer.init("@");
    const tok = lex.next();
    try std.testing.expectEqual(Tag.invalid, tok.tag);
    try std.testing.expectEqual(Tag.eof, lex.next().tag);
}

test "lexer: isolated and/or are invalid" {
    try expectTags("& |", &.{ .invalid, .invalid, .eof });
}

test "lexer: tokenize allocates and ends with eof" {
    const gpa = std.testing.allocator;
    var lex = Lexer.init("let x = 1;");
    const toks = try lex.tokenize(gpa);
    defer gpa.free(toks);
    try std.testing.expectEqual(@as(usize, 6), toks.len);
    try std.testing.expectEqual(Tag.eof, toks[toks.len - 1].tag);
}

test "lexer: string literal keeps the content without quotes" {
    var lex = Lexer.init("import \"lib/math.kyn\";");
    const import_tok = lex.next();
    try std.testing.expectEqual(Tag.kw_import, import_tok.tag);

    const str = lex.next();
    try std.testing.expectEqual(Tag.string, str.tag);
    try std.testing.expectEqualStrings("lib/math.kyn", str.text);
    // The span covers the quotes so the marker points at the whole literal.
    try std.testing.expectEqual(@as(u32, 7), str.span.start);
    try std.testing.expectEqual(@as(u32, 21), str.span.end);

    try std.testing.expectEqual(Tag.semicolon, lex.next().tag);
    try std.testing.expectEqual(Tag.eof, lex.next().tag);
}

test "lexer: empty string is valid" {
    var lex = Lexer.init("\"\"");
    const tok = lex.next();
    try std.testing.expectEqual(Tag.string, tok.tag);
    try std.testing.expectEqualStrings("", tok.text);
}

test "lexer: unterminated string is tokenized without panic" {
    var lex = Lexer.init("import \"lib/math;");
    _ = lex.next();
    const tok = lex.next();
    try std.testing.expectEqual(Tag.string_unterminated, tok.tag);
    try std.testing.expectEqual(Tag.eof, lex.next().tag);
}

test "lexer: string does not span lines" {
    var lex = Lexer.init("\"ab\ncd\"");
    const tok = lex.next();
    try std.testing.expectEqual(Tag.string_unterminated, tok.tag);
    try std.testing.expectEqual(@as(u32, 1), tok.span.line);
}

test "lexer: 'struct' is a keyword and '.' is punctuation" {
    var lex = Lexer.init("struct Ponto { x: i32 }");
    try std.testing.expectEqual(Tag.kw_struct, lex.next().tag);
    try std.testing.expectEqual(Tag.identifier, lex.next().tag);
    try std.testing.expectEqual(Tag.lbrace, lex.next().tag);

    var fields = Lexer.init("p.x = 1;");
    try std.testing.expectEqual(Tag.identifier, fields.next().tag);
    const dot = fields.next();
    try std.testing.expectEqual(Tag.dot, dot.tag);
    try std.testing.expectEqualStrings(".", dot.text);
    try std.testing.expectEqual(Tag.identifier, fields.next().tag);
    try std.testing.expectEqual(Tag.assign, fields.next().tag);
}

test "lexer: 'enum', 'switch' and '=>' are their own tokens" {
    try expectTags("enum Color { Red } switch x { Red => 1 }", &.{
        .kw_enum,   .identifier, .lbrace, .identifier, .rbrace,
        .kw_switch, .identifier, .lbrace, .identifier, .fat_arrow,
        .integer,   .rbrace,     .eof,
    });
}

test "lexer: '=>' is a single token, distinct from '=' and '>'" {
    var buf: [8]Token = undefined;
    const toks = collect("=> = >", &buf);
    try std.testing.expectEqual(@as(usize, 4), toks.len);
    try std.testing.expectEqual(Tag.fat_arrow, toks[0].tag);
    try std.testing.expectEqual(Tag.assign, toks[1].tag);
    try std.testing.expectEqual(Tag.gt, toks[2].tag);
    try std.testing.expectEqualStrings("=>", toks[0].text);
}

test "lexer: 'enum' and 'switch' are keywords, not identifiers" {
    var lex = Lexer.init("enum switch");
    const first = lex.next();
    const second = lex.next();
    try std.testing.expectEqual(Tag.kw_enum, first.tag);
    try std.testing.expectEqual(Tag.kw_switch, second.tag);
    try std.testing.expect(first.isKeyword());
    try std.testing.expect(second.isKeyword());
}
