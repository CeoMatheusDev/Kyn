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

test "thread: spawn/join compile and create no real thread" {
    const std = @import("std");
    const Runner = struct {
        fn run() void {}
    };
    var t = try Thread.spawn(&Runner.run);
    t.join();
    _ = std;
}
