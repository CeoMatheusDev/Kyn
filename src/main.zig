const std = @import("std");
const lexer = @import("lexer/lexer.zig");

pub fn main() !void {
    std.debug.print("Kyn v0.2.0-alpha.1 (bootstrap Zig 0.17.0)\n", .{});
    std.debug.print("Marco 1.2: Parser + AST (lexer → parser → ast)\n", .{});

    // Demonstrar integração Lexer + Parser para tests/parser_basic.kyn
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const content = "let x: i32 = 10;";
    std.debug.print("Arquivo: tests/parser_basic.kyn (simulado, {} bytes) — Lexer + Parser...\n", .{content.len});

    const lex = @import("lexer/lexer.zig");
    var lexInst = lex.Lexer.init(content);
    var tokens: [10]lex.Token = undefined;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        tokens[i] = try lexInst.nextToken(allocator);
        if (tokens[i].typ == .eof) break;
    }

    // Parser básico
    const parser = @import("parser/parser.zig");
    var p = parser.Parser.init(allocator, tokens[0..i]);
    const node = try p.parseProgram();
    std.debug.print("AST raiz: {any} (linha {d})\n", .{ node.typ, node.line });
}
