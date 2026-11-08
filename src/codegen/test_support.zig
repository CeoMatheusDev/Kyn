//! Backend test support: compiles Kyn source down to `sema.Checked`
//! using a heap arena (stable pointer) and fails when there are diagnostics.
//!
//! Test-only; not part of the compiler's public API.

const std = @import("std");
const ast = @import("../ast/ast.zig");
const lexer = @import("../lexer/lexer.zig");
const parser = @import("../parser/parser.zig");
const sema = @import("../sema/sema.zig");
const diagnostics = @import("../diagnostics.zig");

pub const Fixture = struct {
    arena: *std.heap.ArenaAllocator,
    diags: *diagnostics.List,
    program: *ast.Program,
    checked: sema.Checked,

    pub fn build(source: []const u8) !Fixture {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer {
            arena.deinit();
            std.testing.allocator.destroy(arena);
        }

        const a = arena.allocator();
        const diags = try a.create(diagnostics.List);
        diags.* = diagnostics.List.init(a);

        var lex = lexer.Lexer.init(source);
        const tokens = try lex.tokenize(a);

        var p = parser.Parser.init(a, tokens, diags);
        const program = p.parseProgram() catch {
            return error.FixtureParseFailed;
        };

        var checker = sema.Checker.init(a, diags, .{});
        const checked = try checker.checkProgram(program);

        for (diags.items.items) |d| {
            std.debug.print("unexpected diagnostic {d}:{d}: {s}\n", .{ d.span.line, d.span.column, d.message });
        }
        try std.testing.expectEqual(@as(usize, 0), diags.count());

        return .{ .arena = arena, .diags = diags, .program = program, .checked = checked };
    }

    pub fn allocator(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Fixture) void {
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
    }
};

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn isTerminator(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "ret ") or
        std.mem.startsWith(u8, line, "ret void") or
        std.mem.startsWith(u8, line, "br ") or
        // `switch i32 %tag, label %default [ ... ]` closes a block as well.
        std.mem.startsWith(u8, line, "switch ") or
        std.mem.eql(u8, line, "unreachable");
}

/// Checks that every basic block of the emitted IR ends with a valid
/// terminator, avoiding malformed IR an LLVM assembler would reject.
pub fn expectAllBlocksTerminated(ir: []const u8) !void {
    var in_block = false;
    var last_instruction: []const u8 = "";
    var block_label: []const u8 = "";

    var it = std.mem.splitScalar(u8, ir, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.eql(u8, line, "}")) {
            if (in_block) {
                if (!isTerminator(last_instruction)) {
                    std.debug.print("block '{s}' has no terminator; last instruction: '{s}'\n", .{ block_label, last_instruction });
                }
                try std.testing.expect(isTerminator(last_instruction));
            }
            in_block = false;
            continue;
        }

        const starts_indented = raw_line.len > 0 and (raw_line[0] == ' ' or raw_line[0] == '\t');
        if (!starts_indented and std.mem.endsWith(u8, line, ":")) {
            if (in_block) {
                if (!isTerminator(last_instruction)) {
                    std.debug.print("block '{s}' has no terminator; last instruction: '{s}'\n", .{ block_label, last_instruction });
                }
                try std.testing.expect(isTerminator(last_instruction));
            }
            in_block = true;
            block_label = line[0 .. line.len - 1];
            last_instruction = "";
            continue;
        }

        if (in_block) last_instruction = line;
    }

    if (in_block) try std.testing.expect(isTerminator(last_instruction));
}
