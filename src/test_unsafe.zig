const std = @import("std");
const unsafe = @import("sema/unsafe.zig");

test "unsafe block check" {
    var checker = unsafe.UnsafeChecker.init();
    checker.enterUnsafe();
    try checker.checkOperation("raw_ptr");
    checker.exitUnsafe();
    try std.testing.expectError(error.UnsafeOutsideBlock, checker.checkOperation("raw_ptr"));
}
