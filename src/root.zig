//! Root of the Kyn compiler library (Zig bootstrap).
//!
//! Exposed by the `kyn` module in `build.zig`; the `kync` CLI and tests import
//! this library instead of individual files.

const build_options = @import("build_options");

/// Compiler/language version (pre-1.0: see CHANGELOG.md). Comes from
/// `build.zig.zon` through build options.
pub const version = build_options.version;

/// Minimum Zig version declared in `build.zig.zon`.
pub const zig_version = "0.17.0";

pub const span = @import("span.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const lexer = @import("lexer/lexer.zig");
pub const ast = @import("ast/ast.zig");
pub const parser = @import("parser/parser.zig");
pub const sema = @import("sema/sema.zig");
pub const unsafe_checks = @import("sema/unsafe.zig");
pub const codegen = @import("codegen/codegen.zig");
pub const driver = @import("driver.zig");
pub const ffi = @import("ffi/ffi.zig");

test {
    _ = driver;
    _ = codegen;
}
