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
