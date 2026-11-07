//! Raiz da biblioteca do compilador Kyn (bootstrap em Zig).
//!
//! Exposta pelo módulo `kyn` no `build.zig`; a CLI `kync` e os testes importam
//! esta biblioteca em vez de arquivos individuais.

const build_options = @import("build_options");

/// Versão do compilador/linguagem (pré-1.0: ver CHANGELOG.md). Vem de
/// `build.zig.zon` via opções de build.
pub const version = build_options.version;

/// Versão mínima do Zig declarada em `build.zig.zon`.
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
