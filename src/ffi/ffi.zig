// src/ffi/ffi.zig — FFI with C (zero cost)
pub const c = struct {
    pub extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;
};

pub fn callC() void {
    _ = c.printf("Hello from Kyn FFI!\n");
}
