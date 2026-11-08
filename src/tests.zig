//! Aggregator of the bootstrap compiler's unit tests.
//!
//! Executado por `zig build test` (artefato `kyn-unit-tests`).

test {
    _ = @import("span.zig");
    _ = @import("diagnostics.zig");
    _ = @import("lexer/lexer.zig");
    _ = @import("ast/ast.zig");
    _ = @import("parser/parser.zig");
    _ = @import("sema/sema.zig");
    _ = @import("sema/unsafe.zig");
    _ = @import("codegen/codegen.zig");
    _ = @import("driver.zig");
    _ = @import("ffi/ffi.zig");
}
