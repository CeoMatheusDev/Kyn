// std/core/core.zig — kyn:core (bare-metal, zero-deps)
pub const Error = error{OutOfMemory};

pub const Unsafe = struct {
    pub fn block(code: []const u8) void {
        _ = code;
    }
};

pub const Alloc = struct {
    pub fn alloc(size: usize) []u8 {
        _ = size;
        return &[_]u8{};
    }
};

pub fn alignAttr(comptime value: u32) u32 {
    return value;
}

// ---------------------------------------------------------------------------
// Testes: fixam o contrato atual (stub) de `kyn:core`.
// Quando as APIs ganharem implementação real, estes testes devem ser
// substituídos por testes de comportamento (alocação, alinhamento, liberação).
// ---------------------------------------------------------------------------

test "core: alignAttr é identidade em comptime" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 8), alignAttr(8));
    try std.testing.expectEqual(@as(u32, 1), alignAttr(1));
}

test "core: Alloc.alloc devolve slice vazia (stub documentado)" {
    const std = @import("std");
    const buf = Alloc.alloc(16);
    try std.testing.expectEqual(@as(usize, 0), buf.len);
}

test "core: Unsafe.block não faz nada (stub documentado)" {
    Unsafe.block("raw");
}
