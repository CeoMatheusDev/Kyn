//! src/diag.zig — Diagnósticos do compilador Kyn.
//!
//! Um diagnóstico carrega um código estável (E0001, W0001, ...), uma mensagem,
//! um `Span` na origem e, opcionalmente, uma nota de ajuda. A renderização
//! produz o formato clássico de compiladores:
//!
//! ```text
//! error[E0013]: mismatch de tipos: esperado `i32`, encontrado `str`
//!  --> tests/x.kyn:3:5
//!   |
//! 3 |     let x: i32 = "texto";
//!   |                  ^^^^^^
//! ```
//!
//! Propriedade de memória: `List` não é dono da `source` nem do texto das
//! mensagens; tudo que é alocado (mensagens compostas e saída renderizada)
//! vem do allocator informado pelo chamador, tipicamente a arena do pipeline.

const std = @import("std");

/// Intervalo fechado-aberto em bytes dentro de um arquivo fonte.
pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,

    pub fn single(offset: u32) Span {
        return .{ .start = offset, .end = offset };
    }

    pub fn merge(a: Span, b: Span) Span {
        return .{
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
        };
    }

    pub fn len(self: Span) u32 {
        return self.end -| self.start;
    }
};

pub const Level = enum { err, warning, note };

/// Códigos estáveis de diagnóstico. O texto curto (`E0013`) é o contrato
/// observado pelos testes negativos em `tests/diagnostics`.
pub const Code = enum {
    // Frontend sintático.
    syntax, // E0001
    lex, // E0002
    // Resolução de nomes e tipos.
    unknown_type, // E0010
    undefined_name, // E0011
    duplicate_decl, // E0012
    type_mismatch, // E0013
    assign_immutable, // E0014
    unsafe_required, // E0015
    return_mismatch, // E0016
    arity_mismatch, // E0017
    unknown_module, // E0018
    invalid_field, // E0019
    unknown_attribute, // E0020
    invalid_control_flow, // E0021
    invalid_operand, // E0022
    missing_main, // E0023
    unsupported, // E0099
    // Avisos.
    unused_variable, // W0001

    pub fn text(self: Code) []const u8 {
        return switch (self) {
            .syntax => "E0001",
            .lex => "E0002",
            .unknown_type => "E0010",
            .undefined_name => "E0011",
            .duplicate_decl => "E0012",
            .type_mismatch => "E0013",
            .assign_immutable => "E0014",
            .unsafe_required => "E0015",
            .return_mismatch => "E0016",
            .arity_mismatch => "E0017",
            .unknown_module => "E0018",
            .invalid_field => "E0019",
            .unknown_attribute => "E0020",
            .invalid_control_flow => "E0021",
            .invalid_operand => "E0022",
            .missing_main => "E0023",
            .unsupported => "E0099",
            .unused_variable => "W0001",
        };
    }

    pub fn defaultLevel(self: Code) Level {
        return switch (self) {
            .unused_variable => .warning,
            else => .err,
        };
    }
};

pub const Diagnostic = struct {
    code: Code,
    message: []const u8,
    span: Span = .{},
    help: ?[]const u8 = null,
    level: Level = .err,

    pub fn init(code: Code, message: []const u8, span: Span) Diagnostic {
        return .{
            .code = code,
            .message = message,
            .span = span,
            .level = code.defaultLevel(),
        };
    }
};

/// Índice de inícios de linha, usado para transformar offsets em linha/coluna.
pub const LineMap = struct {
    line_starts: std.ArrayList(u32) = .empty,

    pub fn build(alloc: std.mem.Allocator, source: []const u8) !LineMap {
        var self: LineMap = .{};
        try self.line_starts.append(alloc, 0);
        for (source, 0..) |ch, i| {
            if (ch == '\n') try self.line_starts.append(alloc, @intCast(i + 1));
        }
        return self;
    }

    pub const Pos = struct {
        line: u32,
        col: u32,
        line_start: u32,
        line_end: u32,
    };

    pub fn locate(self: LineMap, source: []const u8, offset: u32) Pos {
        const off = @min(offset, @as(u32, @intCast(source.len)));
        var index: usize = 0;
        for (self.line_starts.items, 0..) |start, i| {
            if (start <= off) index = i else break;
        }
        const line_start = self.line_starts.items[index];
        var line_end: u32 = @intCast(source.len);
        if (index + 1 < self.line_starts.items.len) {
            line_end = self.line_starts.items[index + 1];
        }
        // Não incluir o '\n' no conteúdo exibido da linha.
        var content_end = line_end;
        if (content_end > line_start and source[content_end - 1] == '\n') content_end -= 1;
        if (content_end > line_start and source[content_end - 1] == '\r') content_end -= 1;
        return .{
            .line = @intCast(index + 1),
            .col = off - line_start + 1,
            .line_start = line_start,
            .line_end = content_end,
        };
    }
};

/// Lista acumulada de diagnósticos de um pipeline de compilação.
pub const List = struct {
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn add(self: *List, alloc: std.mem.Allocator, d: Diagnostic) !void {
        try self.items.append(alloc, d);
    }

    pub fn hasErrors(self: List) bool {
        for (self.items.items) |d| {
            if (d.level == .err) return true;
        }
        return false;
    }

    pub fn hasCode(self: List, code: Code) bool {
        for (self.items.items) |d| {
            if (d.code == code) return true;
        }
        return false;
    }

    pub fn count(self: List, level: Level) usize {
        var n: usize = 0;
        for (self.items.items) |d| {
            if (d.level == level) n += 1;
        }
        return n;
    }

    /// Renderiza todos os diagnósticos contra `source`. O chamador é dono do
    /// slice retornado (alocado em `alloc`).
    pub fn render(self: List, alloc: std.mem.Allocator, source: []const u8, path: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const lines = try LineMap.build(alloc, source);
        for (self.items.items) |d| {
            try renderOne(&out, alloc, d, source, path, lines);
        }
        const errors = self.count(.err);
        const warnings = self.count(.warning);
        if (errors > 0 or warnings > 0) {
            try appendf(&out, alloc, "\n{s}: {d} erro(s), {d} aviso(s)\n", .{
                path,
                errors,
                warnings,
            });
        }
        return out.items;
    }

    fn renderOne(
        out: *std.ArrayList(u8),
        alloc: std.mem.Allocator,
        d: Diagnostic,
        source: []const u8,
        path: []const u8,
        lines: LineMap,
    ) !void {
        const level_text: []const u8 = switch (d.level) {
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
        try appendf(out, alloc, "{s}[{s}]: {s}\n", .{ level_text, d.code.text(), d.message });

        const pos = lines.locate(source, d.span.start);
        try appendf(out, alloc, "  --> {s}:{d}:{d}\n", .{ path, pos.line, pos.col });

        const gutter_width = digitCount(pos.line) + 1;
        try appendSpaces(out, alloc, gutter_width);
        try out.append(alloc, '|');
        try out.append(alloc, '\n');

        const line_text = source[pos.line_start..pos.line_end];
        try appendf(out, alloc, "{d} | {s}\n", .{ pos.line, line_text });

        try appendSpaces(out, alloc, gutter_width);
        try out.appendSlice(alloc, "| ");
        const col_start = d.span.start - pos.line_start;
        try appendSpaces(out, alloc, col_start);
        const underline_len = @max(1, @min(d.span.len(), pos.line_end -| d.span.start));
        for (0..underline_len) |_| try out.append(alloc, '^');
        try out.append(alloc, '\n');

        if (d.help) |help| {
            try appendSpaces(out, alloc, gutter_width);
            try appendf(out, alloc, "= help: {s}\n", .{help});
        }
    }
};

fn digitCount(value: u32) usize {
    var n = value;
    var count: usize = 1;
    while (n >= 10) : (n /= 10) count += 1;
    return count;
}

fn appendSpaces(out: *std.ArrayList(u8), alloc: std.mem.Allocator, n: usize) !void {
    for (0..n) |_| try out.append(alloc, ' ');
}

pub fn appendf(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(alloc, fmt, args);
    try out.appendSlice(alloc, text);
}

test "line map locates line and column" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "let a = 1;\nlet b = 2;\n";
    const lines = try LineMap.build(alloc, source);

    const first = lines.locate(source, 0);
    try std.testing.expectEqual(@as(u32, 1), first.line);
    try std.testing.expectEqual(@as(u32, 1), first.col);

    const second = lines.locate(source, 14);
    try std.testing.expectEqual(@as(u32, 2), second.line);
    try std.testing.expectEqual(@as(u32, 4), second.col);
}

test "render formats code, location and underline" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "let x: i32 = \"texto\";\n";
    var list: List = .{};
    try list.add(a, Diagnostic.init(.type_mismatch, "mismatch de tipos", .{ .start = 13, .end = 20 }));

    const rendered = try list.render(a, source, "t.kyn");
    try std.testing.expect(std.mem.indexOf(u8, rendered, "error[E0013]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "--> t.kyn:1:14") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "^^^^^^^") != null);
    try std.testing.expect(list.hasErrors());
}
