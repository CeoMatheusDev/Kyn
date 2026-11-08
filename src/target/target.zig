//! Explicit compilation targets for Kyn.
//!
//! Target metadata is deliberately independent from code generation. A target
//! describes the ABI and object contract; it does not imply that every backend
//! can emit that target yet. Keep host defaults out of this module.

pub const Architecture = enum {
    x86_64,
};

pub const OperatingSystem = enum {
    linux,
    none,
};

pub const Abi = enum {
    linux_sysv,
    x86_64_kernel,
};

pub const ObjectFormat = enum {
    elf,
};

pub const CodeModel = enum {
    small,
    kernel,
};

pub const Target = struct {
    triple: []const u8,
    architecture: Architecture,
    operating_system: OperatingSystem,
    abi: Abi,
    object_format: ObjectFormat,
    pointer_bits: u8,
    stack_alignment: u8,
    red_zone: bool,
    requires_libc: bool,
    position_independent: bool,
    code_model: CodeModel,
    entry_symbol: []const u8,

    /// Reject inconsistent target descriptions before a backend consumes them.
    pub fn validate(self: Target) error{InvalidTarget}!void {
        if (self.pointer_bits != 64 or self.stack_alignment != 16) {
            return error.InvalidTarget;
        }

        switch (self.operating_system) {
            .linux => {
                if (self.abi != .linux_sysv or self.requires_libc or self.code_model != .small) {
                    return error.InvalidTarget;
                }
            },
            .none => {
                if (self.abi != .x86_64_kernel or self.requires_libc or self.red_zone or
                    self.code_model != .kernel)
                {
                    return error.InvalidTarget;
                }
            },
        }
    }
};

/// Native Linux target used by the existing executable backend.
pub const x86_64_linux = Target{
    .triple = "x86_64-unknown-linux-gnu",
    .architecture = .x86_64,
    .operating_system = .linux,
    .abi = .linux_sysv,
    .object_format = .elf,
    .pointer_bits = 64,
    .stack_alignment = 16,
    .red_zone = true,
    .requires_libc = false,
    .position_independent = false,
    .code_model = .small,
    .entry_symbol = "_start",
};

/// Freestanding kernel target. This is a target contract, not yet a promise
/// that the current code generators can emit a bootable kernel.
pub const x86_64_freestanding = Target{
    .triple = "x86_64-unknown-none-elf",
    .architecture = .x86_64,
    .operating_system = .none,
    .abi = .x86_64_kernel,
    .object_format = .elf,
    .pointer_bits = 64,
    .stack_alignment = 16,
    .red_zone = false,
    .requires_libc = false,
    .position_independent = false,
    .code_model = .kernel,
    .entry_symbol = "_start",
};

/// Resolve only targets whose contracts are explicitly defined by Kyn.
pub fn fromTriple(triple: []const u8) ?Target {
    const std = @import("std");
    if (std.mem.eql(u8, triple, x86_64_linux.triple)) return x86_64_linux;
    if (std.mem.eql(u8, triple, x86_64_freestanding.triple)) return x86_64_freestanding;
    return null;
}

test "target: Linux x86_64 contract is valid" {
    try x86_64_linux.validate();
    try @import("std").testing.expect(x86_64_linux.red_zone);
    try @import("std").testing.expect(!x86_64_linux.requires_libc);
}

test "target: freestanding x86_64 contract disables runtime assumptions" {
    try x86_64_freestanding.validate();
    try @import("std").testing.expect(!x86_64_freestanding.red_zone);
    try @import("std").testing.expect(!x86_64_freestanding.requires_libc);
    try @import("std").testing.expectEqual(CodeModel.kernel, x86_64_freestanding.code_model);
}

test "target: only declared triples resolve" {
    const std = @import("std");
    try std.testing.expectEqual(x86_64_linux, fromTriple("x86_64-unknown-linux-gnu").?);
    try std.testing.expectEqual(x86_64_freestanding, fromTriple("x86_64-unknown-none-elf").?);
    try std.testing.expect(fromTriple("aarch64-unknown-none-elf") == null);
}

test "target: invalid kernel ABI assumptions are rejected" {
    var invalid = x86_64_freestanding;
    invalid.red_zone = true;
    try @import("std").testing.expectError(error.InvalidTarget, invalid.validate());
}
