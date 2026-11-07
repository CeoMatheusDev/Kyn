//! Agregador de testes da biblioteca padrão experimental (`kyn:core`,
//! `kyn:std`). Executado por `zig build test`.

test {
    _ = @import("core/core.zig");
    _ = @import("os/io.zig");
    _ = @import("os/thread.zig");
    _ = @import("os/net.zig");
}
