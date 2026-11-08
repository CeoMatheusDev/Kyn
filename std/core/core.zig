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
// Tests: pin the current (stub) contract of `kyn:core`.
// Once the APIs get a real implementation, these tests must be
// replaced by behavior tests (allocation, alignment, release).
// ---------------------------------------------------------------------------

test "core: alignAttr is the identity at comptime" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 8), alignAttr(8));
    try std.testing.expectEqual(@as(u32, 1), alignAttr(1));
}

test "core: Alloc.alloc returns an empty slice (documented stub)" {
    const std = @import("std");
    const buf = Alloc.alloc(16);
    try std.testing.expectEqual(@as(usize, 0), buf.len);
}

test "core: Unsafe.block does nothing (documented stub)" {
    Unsafe.block("raw");
}
