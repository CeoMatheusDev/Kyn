//! Test aggregator of the experimental standard library (`kyn:core`,
//! `kyn:std`). Run by `zig build test`.

test {
    _ = @import("core/core.zig");
    _ = @import("os/io.zig");
    _ = @import("os/thread.zig");
    _ = @import("os/net.zig");
}
