const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Project version derived from `build.zig.zon`, so the CLI
    // (`kync --version`) and the changelog share a single source of truth.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    // Compiler library (lexer -> parser/AST -> sema -> backends).
    const kyn = b.addModule("kyn", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    kyn.addOptions("build_options", build_options);

    // CLI `kync`.
    const exe = b.addExecutable(.{
        .name = "kync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "kyn", .module = kyn }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the kync compiler").dependOn(&run_cmd.step);

    // Compiler unit tests.
    const unit_tests = b.addTest(.{
        .name = "kyn-unit-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "kyn", .module = kyn }},
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Runs the compiler unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Unit tests of the experimental standard library (kyn:core / kyn:std).
    const std_tests = b.addTest(.{
        .name = "kyn-std-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("std/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_std_tests = b.addRunArtifact(std_tests);
    test_step.dependOn(&run_std_tests.step);

    // End-to-end tests: emit assembly, assemble with `as`, link with `ld`
    // and run the resulting binary checking its exit code.
    // Depends on a POSIX x86-64 toolchain (as, ld). Only runs when requested.
    const e2e_cmd = b.addSystemCommand(&.{ "bash", "tools/e2e.sh" });
    e2e_cmd.addArtifactArg(exe);
    e2e_cmd.step.dependOn(b.getInstallStep());
    const e2e_step = b.step("e2e", "Runs the full pipeline down to a native binary and checks the exit code");
    e2e_step.dependOn(&e2e_cmd.step);

    // LLVM IR validation through an LLVM tool (llvm-as or clang). Without LLVM
    // in the environment the script warns and exits with code 0.
    const validate_ir_cmd = b.addSystemCommand(&.{ "bash", "tools/validate-ir.sh" });
    validate_ir_cmd.addArtifactArg(exe);
    validate_ir_cmd.step.dependOn(b.getInstallStep());
    const validate_ir_step = b.step("validate-ir", "Validates the emitted LLVM IR with llvm-as/clang (when available)");
    validate_ir_step.dependOn(&validate_ir_cmd.step);

    // Strict variant used in CI: fails when no LLVM tool exists,
    // so IR validation is never skipped silently.
    const validate_ir_strict_cmd = b.addSystemCommand(&.{ "bash", "tools/validate-ir.sh" });
    validate_ir_strict_cmd.addArtifactArg(exe);
    validate_ir_strict_cmd.addArg("--require-tool");
    validate_ir_strict_cmd.step.dependOn(b.getInstallStep());
    const validate_ir_strict_step = b.step("validate-ir-strict", "Validates the LLVM IR and fails when LLVM is not installed");
    validate_ir_strict_step.dependOn(&validate_ir_strict_cmd.step);
}
