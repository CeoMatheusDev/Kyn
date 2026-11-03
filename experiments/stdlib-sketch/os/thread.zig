// std/os/thread.zig — kyn:std (Threads)
pub const Thread = struct {
    pub fn spawn(fn_ptr: *const fn () void) !Thread {
        _ = fn_ptr;
        return Thread{};
    }
    pub fn join(self: *Thread) void {
        _ = self;
    }
};
