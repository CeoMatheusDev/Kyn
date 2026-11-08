//! `unsafe` and representation (`#[repr(C)]`) checks.
//!
//! The current language subset (see `docs/status.md`) has no `unsafe`
//! blocks, `struct` nodes or attributes in the AST. This module keeps the
//! verification policy isolated and tested, ready to be wired in once
//! those nodes exist — without faking them in the parser.

const std = @import("std");
const Span = @import("../span.zig").Span;

pub const Error = error{
    UnsafeOutsideBlock,
    ReprCInvalidLayout,
};

pub const UnsafeChecker = struct {
    in_unsafe: bool = false,

    pub fn init() UnsafeChecker {
        return .{};
    }

    pub fn enterUnsafe(self: *UnsafeChecker) void {
        self.in_unsafe = true;
    }

    pub fn exitUnsafe(self: *UnsafeChecker) void {
        self.in_unsafe = false;
    }

    /// Low-level operations require an explicit `unsafe` context.
    pub fn checkOperation(self: *UnsafeChecker, op: []const u8) !void {
        _ = op;
        if (!self.in_unsafe) return error.UnsafeOutsideBlock;
    }
};

pub const ReprChecker = struct {
    /// Validates that a struct exposed in the ABI declares `#[repr(C)]`.
    ///
    /// While the AST has no `struct` nodes, the check receives the data
    /// explicitly; no attribute is ever inferred.
    pub fn checkExternStruct(self: *ReprChecker, name: []const u8, span: Span, has_repr_c: bool) !void {
        _ = self;
        _ = span;
        _ = name;
        if (!has_repr_c) return error.ReprCInvalidLayout;
    }
};

test "unsafe: operation outside the block is rejected" {
    var checker = UnsafeChecker.init();
    try std.testing.expectError(error.UnsafeOutsideBlock, checker.checkOperation("raw_ptr"));

    checker.enterUnsafe();
    try checker.checkOperation("raw_ptr");
    checker.exitUnsafe();
    try std.testing.expectError(error.UnsafeOutsideBlock, checker.checkOperation("raw_ptr"));
}

test "unsafe: contexto aninhado simplificado" {
    var checker = UnsafeChecker.init();
    checker.enterUnsafe();
    checker.enterUnsafe();
    try checker.checkOperation("deref");
    checker.exitUnsafe();
    // The current policy does not account for nesting; tracked as pending.
    try std.testing.expectError(error.UnsafeOutsideBlock, checker.checkOperation("deref"));
}

test "repr(C): struct externa exige repr(C)" {
    var checker = ReprChecker{};
    try std.testing.expectError(error.ReprCInvalidLayout, checker.checkExternStruct("Point", .{}, false));
    try checker.checkExternStruct("Point", .{}, true);
}
