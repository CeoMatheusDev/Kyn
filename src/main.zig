const std = @import("std");
const lexer = @import("lexer/lexer.zig");

pub fn main() !void {
    std.debug.print("Kyn v0.2.0-alpha.1 (bootstrap Zig 0.17.0)\n", .{});
    std.debug.print("Marco 2.1: std/core (unsafe, @align, alocadores explícitos)\n", .{});
}
