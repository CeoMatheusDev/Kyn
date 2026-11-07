//! Driver do pipeline: fonte -> lexer -> parser -> semântica -> backend.
//!
//! Ownership: `compile` cria uma arena própria (alocada no `gpa`) que possui
//! todos os artefatos — AST, tabela de símbolos, diagnósticos e saída do
//! backend. O chamador deve invocar `Result.deinit()`.

const std = @import("std");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const sema = @import("sema/sema.zig");
const codegen = @import("codegen/codegen.zig");
const diagnostics = @import("diagnostics.zig");

pub const Action = enum {
    /// Apenas lexer + parser + semântica.
    check,
    /// Executa o pipeline completo e emite o artefato do backend.
    emit,
};

pub const Options = struct {
    action: Action = .check,
    backend: codegen.Backend = .llvm_ir,
    require_main: bool = true,
};

pub const Result = struct {
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    diags: *diagnostics.List,
    /// Texto produzido pelo backend (somente em `Action.emit` bem-sucedida).
    output: ?[]const u8 = null,

    pub fn deinit(self: Result) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    pub fn failed(self: Result) bool {
        return self.diags.hasErrors() or self.output == null and false;
    }
};

pub const Error = std.mem.Allocator.Error;

pub fn compile(gpa: std.mem.Allocator, source: []const u8, options: Options) Error!Result {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }

    const a = arena.allocator();
    const diags = try a.create(diagnostics.List);
    diags.* = diagnostics.List.init(a);

    const result: Result = .{ .gpa = gpa, .arena = arena, .diags = diags };

    // 1. Lexer
    var lex = lexer.Lexer.init(source);
    const tokens = try lex.tokenize(a);

    // 2. Parser (falha no primeiro erro sintático)
    var p = parser.Parser.init(a, tokens, diags);
    const program = p.parseProgram() catch |err| switch (err) {
        error.ParseError => return result,
        error.OutOfMemory => return error.OutOfMemory,
    };

    // 3. Semântica (acumula diagnósticos e anota a AST)
    var checker = sema.Checker.init(a, diags, .{ .require_main = options.require_main });
    const checked = try checker.checkProgram(program);

    if (diags.hasErrors()) return result;
    if (options.action == .check) return result;

    // 4. Backend
    const output = codegen.generate(a, program, &checked, options.backend) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diags.add(
                .unsupported,
                program.span,
                "não foi possível gerar código para o backend '{s}': {s}",
                .{ options.backend.cliName(), @errorName(err) },
            );
            return result;
        },
    };

    var with_output = result;
    with_output.output = output;
    return with_output;
}

/// Renderiza todos os diagnósticos de uma compilação.
pub fn renderDiagnostics(
    writer: *std.Io.Writer,
    filename: []const u8,
    source: []const u8,
    diags: *const diagnostics.List,
) std.Io.Writer.Error!void {
    for (diags.items.items) |d| {
        try diagnostics.render(writer, filename, source, d);
    }
}

// ---------------------------------------------------------------------------
// Testes de integração do pipeline (em processo)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectClean(source: []const u8, options: Options) !Result {
    var result = try compile(testing.allocator, source, options);
    errdefer result.deinit();
    if (result.diags.hasErrors()) {
        std.debug.print("diagnósticos inesperados em compilação válida:\n", .{});
        for (result.diags.items.items) |d| std.debug.print("  {d}:{d}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.UnexpectedDiagnostics;
    }
    return result;
}

test "driver: check de programa válido" {
    var result = try expectClean(
        \\fn main() -> i32 {
        \\    let x: i32 = 6 * 7;
        \\    return x;
        \\}
    , .{ .action = .check });
    defer result.deinit();
    try testing.expect(result.output == null);
}

test "driver: emit llvm ir" {
    var result = try expectClean("fn main() -> i32 { return 42; }", .{
        .action = .emit,
        .backend = .llvm_ir,
    });
    defer result.deinit();
    const ir = result.output.?;
    try testing.expect(std.mem.indexOf(u8, ir, "define i32 @main()") != null);
    try testing.expect(std.mem.indexOf(u8, ir, "ret i32 42") != null);
}

test "driver: emit assembly x86-64" {
    var result = try expectClean("fn main() -> i32 { return 42; }", .{
        .action = .emit,
        .backend = .x86_64_asm,
    });
    defer result.deinit();
    const asm_text = result.output.?;
    try testing.expect(std.mem.indexOf(u8, asm_text, "_start:") != null);
    try testing.expect(std.mem.indexOf(u8, asm_text, "call kyn_main") != null);
    try testing.expect(std.mem.indexOf(u8, asm_text, "syscall") != null);
}

test "driver: erro de sintaxe interrompe o pipeline" {
    var result = try compile(testing.allocator, "fn main( { }", .{});
    defer result.deinit();
    try testing.expect(result.diags.hasErrors());
    try testing.expect(result.output == null);
    try testing.expectEqual(diagnostics.Kind.syntax, result.diags.items.items[0].kind);
}

test "driver: erro semântico não gera artefato" {
    var result = try compile(testing.allocator, "fn main() -> i32 { let x: bool = 1; return 0; }", .{
        .action = .emit,
    });
    defer result.deinit();
    try testing.expect(result.diags.hasErrors());
    try testing.expect(result.output == null);
}

test "driver: require_main desativado permite biblioteca sem main" {
    var result = try compile(testing.allocator, "fn id(x: i32) -> i32 { return x; }", .{
        .require_main = false,
    });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.diags.count());
}

test "driver: render de diagnósticos inclui arquivo, linha e coluna" {
    var result = try compile(testing.allocator, "fn main() -> i32 {\n  return z;\n}\n", .{});
    defer result.deinit();

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try renderDiagnostics(&writer, "prog.kyn", "fn main() -> i32 {\n  return z;\n}\n", result.diags);
    const out = writer.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "prog.kyn:2:10: erro: variável 'z' não declarada"));
}
