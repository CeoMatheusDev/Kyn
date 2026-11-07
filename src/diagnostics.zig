//! Diagnósticos do compilador: severidade, span e mensagem.
//!
//! O `kind` identifica a categoria do erro de forma estável (usada por testes
//! e pela CLI para decidir o código de saída); a mensagem é texto legível já
//! formatado no allocator do chamador (normalmente uma arena por compilação).

const std = @import("std");
const Span = @import("span.zig").Span;

pub const Severity = enum { @"error", warning };

pub const Kind = enum {
    // sintaxe
    syntax,
    integer_overflow,
    // semântica
    undefined_variable,
    duplicate_declaration,
    unknown_type,
    type_mismatch,
    immutable_assignment,
    invalid_condition,
    invalid_return,
    invalid_call,
    missing_main,
    invalid_main,
    // módulos
    import_not_found,
    import_cycle,
    // infraestrutura
    unsupported,
    internal,
};

pub const Diagnostic = struct {
    kind: Kind,
    span: Span,
    message: []const u8,
    severity: Severity = .@"error",
    /// Índice do arquivo de origem (ver `driver.Result.sources`).
    file: u32 = 0,
};

/// Lista de diagnósticos alocada em uma arena.
pub const List = struct {
    arena: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,
    /// Arquivo atribuído aos diagnósticos adicionados via `add`. O driver e a
    /// semântica o atualizam ao entrar em cada módulo/função.
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

/// Renderiza um diagnóstico como `arquivo:linha:coluna: erro: mensagem`
/// seguido da linha de código e de um marcador `^`.
pub fn render(
    writer: *std.Io.Writer,
    filename: []const u8,
    source: []const u8,
    diag: Diagnostic,
) std.Io.Writer.Error!void {
    const severity = switch (diag.severity) {
        .@"error" => "erro",
        .warning => "aviso",
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

    // Marcador: prefixo com a indentação da linha, depois `^` na coluna.
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

test "diagnostics: lista acumula e detecta erros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var list = List.init(arena.allocator());
    try std.testing.expect(!list.hasErrors());
    try list.add(.undefined_variable, .{ .line = 1, .column = 5 }, "variável '{s}' não declarada", .{"x"});
    try std.testing.expectEqual(@as(usize, 1), list.count());
    try std.testing.expect(list.hasErrors());
    try std.testing.expectEqualStrings("variável 'x' não declarada", list.last().?.message);
}

test "diagnostics: render aponta linha e coluna" {
    const source = "fn main() {\n    let x = y;\n}\n";
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const diag: Diagnostic = .{
        .kind = .undefined_variable,
        .span = .{ .start = 21, .end = 22, .line = 2, .column = 13 },
        .message = "variável 'y' não declarada",
    };
    try render(&writer, "teste.kyn", source, diag);
    const out = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "teste.kyn:2:13: erro: variável 'y' não declarada\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "let x = y;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "^") != null);
}
