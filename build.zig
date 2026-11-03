//! build.zig — fonte única de verdade para build, testes e suíte de integração.
//!
//! ```sh
//! zig build                 # compila a CLI `kyn` em zig-out/bin/kyn
//! zig build test            # testes unitários do compilador
//! zig build integration     # compila e executa as fixtures `.kyn`
//! zig build check           # unitários + integração
//! zig build run -- check tests/cases/01_hello.kyn
//! ```

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const cc = b.option([]const u8, "cc", "Compilador C usado pela suíte de integração") orelse "cc";

    // Módulo com todo o compilador; também é a raiz dos testes unitários.
    const mod = b.addModule("kyn", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "kyn",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // ---------------------------------------------------------------- testes

    const unit_tests = b.addTest(.{ .root_module = mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Testes unitários de lexer, parser, semântica e backend");
    test_step.dependOn(&run_unit_tests.step);

    const runner = b.addExecutable(.{
        .name = "kyn-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_integration = b.addRunArtifact(runner);
    run_integration.addArg("--cc");
    run_integration.addArg(cc);
    run_integration.addArg("--tmp");
    run_integration.addDirectoryArg(std.Build.LazyPath.cache_root.path(b, "integration"));
    run_integration.addDirectoryArg(b.path("tests/cases"));
    run_integration.addDirectoryArg(b.path("tests/diagnostics"));
    run_integration.addDirectoryArg(b.path("tests/regression"));
    run_integration.setCwd(b.path("."));
    const integration_step = b.step("integration", "Compila e executa as fixtures .kyn de ponta a ponta");
    integration_step.dependOn(&run_integration.step);

    const check_step = b.step("check", "Testes unitários + suíte de integração");
    check_step.dependOn(&run_unit_tests.step);
    check_step.dependOn(&run_integration.step);

    // ------------------------------------------------------------------- CLI

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Executa a CLI do kyn (passe argumentos após --)");
    run_step.dependOn(&run_cmd.step);
}
