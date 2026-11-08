//! Compiler diagnostics: severity, span and message.
//!
//! `kind` identifies the error category in a stable way (used by tests and by
//! the CLI to decide the exit code); the message is human-readable text already
//! formatted in the caller's allocator (usually one arena per compilation).

const std = @import("std");
const Span = @import("span.zig").Span;

pub const Severity = enum { @"error", warning };

pub const Kind = enum {
    // syntax
    syntax,
    integer_overflow,
    // semantics
    undefined_variable,
    duplicate_declaration,
    unknown_type,
    type_mismatch,
    immutable_assignment,
    invalid_condition,
    invalid_return,
    invalid_call,
    /// Field that does not exist in a struct.
    undefined_field,
    /// Incomplete struct literal or repeated field.
    invalid_struct_literal,
    /// `switch` arm whose case exists but whose payload binding is wrong
    /// (missing payload, payload on a payload-less case, wrong arity).
    invalid_switch_arm,
    /// Method declaration problem: missing/misnamed receiver or a receiver of
    /// the wrong nominal type.
    invalid_method,
    /// Case name that the enum does not declare.
    unknown_case,
    /// `switch` without an `else` and without covering every case.
    non_exhaustive_switch,
    /// `else` arm that can never run because every case is covered.
    unreachable_arm,
    missing_main,
    invalid_main,
    // modules
    import_not_found,
    import_cycle,
    // infrastructure
    unsupported,
    internal,
};

pub const Diagnostic = struct {
    kind: Kind,
    span: Span,
    message: []const u8,
    severity: Severity = .@"error",
    /// Source file index (see `driver.Result.sources`).
    file: u32 = 0,
};

/// Diagnostic list allocated in an arena.
pub const List = struct {
    arena: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,
    /// File assigned to diagnostics added through `add`. The driver and
    /// semantics update it when entering each module/function.
    current_file: u32 = 0,

    pub fn init(arena: std.mem.Allocator) List {
        return .{ .arena = arena };
    }

    pub fn add(
        self: *List,
        kind: Kind,
        span: Span,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.addInFile(self.current_file, kind, span, fmt, args);
    }

    pub fn addInFile(
        self: *List,
        file: u32,
        kind: Kind,
        span: Span,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.items.append(self.arena, .{
            .kind = kind,
            .span = span,
            .message = try std.fmt.allocPrint(self.arena, fmt, args),
            .file = file,
        });
    }

    pub fn addError(self: *List, kind: Kind, span: Span, message: []const u8) !void {
        try self.items.append(self.arena, .{
            .kind = kind,
            .span = span,
            .message = message,
            .file = self.current_file,
        });
    }

    pub fn count(self: *const List) usize {
        return self.items.items.len;
    }

    pub fn hasErrors(self: *const List) bool {
        for (self.items.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    pub fn last(self: *const List) ?Diagnostic {
        if (self.items.items.len == 0) return null;
        return self.items.items[self.items.items.len - 1];
    }
};

/// Renders a diagnostic as `file:line:column: error: message`
/// followed by the source line and a `^` marker.
pub fn render(
    writer: *std.Io.Writer,
    filename: []const u8,
    source: []const u8,
    diag: Diagnostic,
) std.Io.Writer.Error!void {
    const severity = switch (diag.severity) {
        .@"error" => "error",
        .warning => "warning",
    };
    try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{
        filename,
        diag.span.line,
        diag.span.column,
        severity,
        diag.message,
    });

    const line_text = lineAt(source, diag.span.line) orelse return;
    if (line_text.len == 0) return;
    try writer.print("    {s}\n", .{line_text});

    // Marker: prefix with the line's indentation, then `^` at the column.
    try writer.writeAll("    ");
    var i: usize = 1;
    while (i < diag.span.column) : (i += 1) {
        const ch = if (i - 1 < line_text.len) line_text[i - 1] else ' ';
        try writer.writeByte(if (ch == '\t') '\t' else ' ');
    }
    const width: usize = @max(@as(usize, 1), @as(usize, @min(diag.span.len(), 120)));
    var j: usize = 0;
    while (j < width) : (j += 1) try writer.writeByte('^');
    try writer.writeByte('\n');
}

fn lineAt(source: []const u8, line: u32) ?[]const u8 {
    if (line == 0) return null;
    var current: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        if (i == source.len or source[i] == '\n') {
            if (current == line) {
                const end = i;
                const text = source[start..end];
                return std.mem.trimEnd(u8, text, "\r");
            }
            current += 1;
            start = i + 1;
        }
    }
    return null;
}

test "diagnostics: list accumulates and detects errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var list = List.init(arena.allocator());
    try std.testing.expect(!list.hasErrors());
    try list.add(.undefined_variable, .{ .line = 1, .column = 5 }, "variable '{s}' is not declared", .{"x"});
    try std.testing.expectEqual(@as(usize, 1), list.count());
    try std.testing.expect(list.hasErrors());
    try std.testing.expectEqualStrings("variable 'x' is not declared", list.last().?.message);
}

test "diagnostics: render points at line and column" {
    const source = "fn main() {\n    let x = y;\n}\n";
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const diag: Diagnostic = .{
        .kind = .undefined_variable,
        .span = .{ .start = 21, .end = 22, .line = 2, .column = 13 },
        .message = "variable 'y' is not declared",
    };
    try render(&writer, "test.kyn", source, diag);
    const out = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "test.kyn:2:13: error: variable 'y' is not declared\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "let x = y;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "^") != null);
}
