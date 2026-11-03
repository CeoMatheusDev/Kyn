//! src/root.zig — Raiz do módulo `kyn`.
//!
//! Reexporta os componentes do compilador e agrega os blocos `test` de cada
//! arquivo, de modo que `zig build test` exercite todo o frontend e o backend.

pub const diag = @import("diag.zig");
pub const lexer = @import("lexer/lexer.zig");
pub const ast = @import("ast/ast.zig");
pub const parser = @import("parser/parser.zig");
pub const types = @import("sema/types.zig");
pub const sema = @import("sema/sema.zig");
pub const unsafe = @import("sema/unsafe.zig");
pub const codegen = @import("codegen/c.zig");
pub const driver = @import("driver.zig");

pub const version = "0.5.0-alpha.1";

test {
    // O runner de integração tem `main`, mas seus testes unitários (parser do
    // formato `.expect`) rodam junto com o resto.
    _ = @import("runner.zig");

    _ = diag;
    _ = lexer;
    _ = ast;
    _ = parser;
    _ = types;
    _ = sema;
    _ = unsafe;
    _ = codegen;
    _ = driver;
}
