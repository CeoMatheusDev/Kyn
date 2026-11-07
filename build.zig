const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Versão do projeto derivada de `build.zig.zon`, para que a CLI
    // (`kync --version`) e o changelog tenham uma única fonte de verdade.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    // Biblioteca do compilador (lexer -> parser/AST -> sema -> backends).
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
    b.step("run", "Executa o kync").dependOn(&run_cmd.step);

    // Testes unitários do compilador.
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
    const test_step = b.step("test", "Executa os testes unitários do compilador");
    test_step.dependOn(&run_unit_tests.step);

    // Testes unitários da biblioteca padrão experimental (kyn:core / kyn:std).
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

    // Testes de ponta a ponta: emite assembly, monta com `as`, liga com `ld`
    // e executa o binário resultante verificando o código de saída.
    // Depende de toolchain POSIX x86-64 (as, ld). Só roda quando solicitado.
    const e2e_cmd = b.addSystemCommand(&.{ "bash", "tools/e2e.sh" });
    e2e_cmd.addArtifactArg(exe);
    e2e_cmd.step.dependOn(b.getInstallStep());
    const e2e_step = b.step("e2e", "Executa o pipeline completo até binário nativo e verifica o código de saída");
    e2e_step.dependOn(&e2e_cmd.step);

    // Validação do LLVM IR por ferramenta LLVM (llvm-as ou clang). Sem LLVM no
    // ambiente, o script avisa e sai com código 0.
    const validate_ir_cmd = b.addSystemCommand(&.{ "bash", "tools/validate-ir.sh" });
    validate_ir_cmd.addArtifactArg(exe);
    validate_ir_cmd.step.dependOn(b.getInstallStep());
    const validate_ir_step = b.step("validate-ir", "Valida o LLVM IR emitido com llvm-as/clang (quando disponível)");
    validate_ir_step.dependOn(&validate_ir_cmd.step);

    // Variante estrita usada no CI: falha se nenhuma ferramenta LLVM existir,
    // para que a validação do IR nunca seja ignorada silenciosamente.
    const validate_ir_strict_cmd = b.addSystemCommand(&.{ "bash", "tools/validate-ir.sh" });
    validate_ir_strict_cmd.addArtifactArg(exe);
    validate_ir_strict_cmd.addArg("--require-tool");
    validate_ir_strict_cmd.step.dependOn(b.getInstallStep());
    const validate_ir_strict_step = b.step("validate-ir-strict", "Valida o LLVM IR e falha se não houver LLVM instalado");
    validate_ir_strict_step.dependOn(&validate_ir_strict_cmd.step);
}
