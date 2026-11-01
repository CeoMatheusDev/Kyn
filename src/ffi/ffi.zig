// src/ffi/ffi.zig — FFI com C (custo zero)
pub const c = struct {
    pub extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;
};

pub fn callC() void {
    _ = c.printf("Hello from Kyn FFI!\n");
}
