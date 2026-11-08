//! Source location for a fragment of input.
//!
//! Spans never own or copy source text. They store byte offsets into the
//! original buffer and a one-based line/column origin. The source buffer must
//! outlive every span that refers to it.

const std = @import("std");

pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,
    line: u32 = 1,
    column: u32 = 1,

    pub const zero: Span = .{};

    /// Returns the span length in bytes, saturating for malformed ranges.
    pub fn len(self: Span) u32 {
        return self.end -| self.start;
    }

    /// Returns the source slice covered by this span.
    ///
    /// Offsets are clamped to the available buffer. A reversed range is
    /// treated as empty instead of triggering a bounds panic.
    pub fn text(self: Span, source: []const u8) []const u8 {
        const start = @min(@as(usize, self.start), source.len);
        const end = @max(start, @min(@as(usize, self.end), source.len));
        return source[start..end];
    }

    /// Combines two spans while preserving the origin of the earliest byte.
    ///
    /// When both spans start at the same offset, the left operand wins.
    pub fn merge(a: Span, b: Span) Span {
        const first = if (a.start <= b.start) a else b;
        return .{
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
            .line = first.line,
            .column = first.column,
        };
    }
};

test "span text and len" {
    const source = "hello world";
    const span: Span = .{ .start = 6, .end = 11, .line = 1, .column = 7 };
    try std.testing.expectEqualStrings("world", span.text(source));
    try std.testing.expectEqual(@as(u32, 5), span.len());
}

test "span text clamps offsets to source bounds" {
    const source = "hello";
    const beyond: Span = .{ .start = 2, .end = 99 };
    const reversed: Span = .{ .start = 4, .end = 2 };
    const after_source: Span = .{ .start = 99, .end = 120 };

    try std.testing.expectEqualStrings("llo", beyond.text(source));
    try std.testing.expectEqualStrings("", reversed.text(source));
    try std.testing.expectEqualStrings("", after_source.text(source));
}

test "span merge preserves the earliest source origin" {
    const first: Span = .{ .start = 2, .end = 4, .line = 1, .column = 3 };
    const second: Span = .{ .start = 8, .end = 9, .line = 2, .column = 5 };
    const merged = Span.merge(first, second);

    try std.testing.expectEqual(@as(u32, 2), merged.start);
    try std.testing.expectEqual(@as(u32, 9), merged.end);
    try std.testing.expectEqual(@as(u32, 1), merged.line);
    try std.testing.expectEqual(@as(u32, 3), merged.column);
}

test "span merge is independent of operand order" {
    const earlier: Span = .{ .start = 2, .end = 4, .line = 3, .column = 7 };
    const later: Span = .{ .start = 8, .end = 9, .line = 5, .column = 2 };

    const merged = Span.merge(later, earlier);
    try std.testing.expectEqual(@as(u32, 2), merged.start);
    try std.testing.expectEqual(@as(u32, 9), merged.end);
    try std.testing.expectEqual(@as(u32, 3), merged.line);
    try std.testing.expectEqual(@as(u32, 7), merged.column);
}
