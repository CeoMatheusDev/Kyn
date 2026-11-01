const core = @import("kyn_core.zig");

test "core basic unsafe and align" {
    const buf = core.Alloc.alloc(16);
    _ = buf;
    _ = core.alignAttr(8);
    core.Unsafe.block("raw");
}
