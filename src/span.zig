//! Location of a fragment of source code.
//!
//! Spans do not copy text: they store offsets into the original input, so the
//! lexer, parser, semantic analysis and diagnostics all refer to one buffer.

const std = @import("std");

pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,
    line: u32 = 1,
    column: u32 = 1,

    pub const zero: Span = .{};

    pub fn len(self: Span) u32 {
        return self.end -| self.start;
    }

    /// Texto correspondente ao span na fonte fornecida.
    pub fn text(self: Span, source: []const u8) []const u8 {
        const start: usize = @min(self.start, source.len);
        const end: usize = @min(self.end, source.len);
        return source[start..end];
    }

    pub fn merge(a: Span, b: Span) Span {
        return .{
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
            .line = a.line,
            .column = a.column,
        };
    }
};

test "span text and len" {
    const src = "hello world";
    const s: Span = .{ .start = 6, .end = 11, .line = 1, .column = 7 };
    try std.testing.expectEqualStrings("world", s.text(src));
    try std.testing.expectEqual(@as(u32, 5), s.len());
}

test "span merge keeps the first origin" {
    const a: Span = .{ .start = 2, .end = 4, .line = 1, .column = 3 };
    const b: Span = .{ .start = 8, .end = 9, .line = 1, .column = 9 };
    const m = Span.merge(a, b);
    try std.testing.expectEqual(@as(u32, 2), m.start);
    try std.testing.expectEqual(@as(u32, 9), m.end);
    try std.testing.expectEqual(@as(u32, 3), m.column);
}
