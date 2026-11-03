//! src/main.zig — CLI do compilador Kyn.
//!
//! ```text
//! kyn <comando> [opções] <arquivo.kyn>
//!
//! comandos:
//!   check     lexer + parser + semântica, sem gerar código
//!   emit      escreve o C gerado (stdout ou -o)
//!   build     igual a `emit`, com -o obrigatório
//!   run       compila o C com um compilador C e executa o binário
//!             (grava `nome.kyn.c` e `nome.kyn.bin` ao lado da entrada)
//!   tokens    imprime a tokenização (depuração)
//!   ast       imprime a AST (depuração)
//!   version   imprime as versões do compilador e da linguagem
//!   help      esta mensagem
//!
//! opções:
//!   -o <arquivo>     arquivo de saída
//!   --cc <comando>   compilador C usado por `run` (padrão: cc)
//!   --warn-unused    ativa o aviso W0001 (variável nunca lida)
//!   --no-main        não exige `fn main` (bibliotecas e experimentos)
//!   --emit-c <arq>   em `run`, também grava o C intermediário
//! ```
//!
//! Códigos de saída:
//! `0` sucesso · `1` diagnósticos de compilação · `2` uso inválido da CLI ·
//! `3` falha de E/S ou interna · `4` falha no compilador C ·
//! em `run`, o código do programa executado é propagado.

const std = @import("std");
const root = @import("root.zig");
const driver = root.driver;
const diag = root.diag;

const ExitCode = enum(u8) {
    ok = 0,
    diagnostics = 1,
    usage = 2,
    internal = 3,
    c_compiler = 4,

    fn code(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

const Args = struct {
    command: []const u8 = "help",
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    cc: []const u8 = "cc",
    emit_c: ?[]const u8 = null,
    warn_unused: bool = false,
    require_main: bool = true,
    extra: std.ArrayList([]const u8) = .empty,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Argumentos em UTF-8 em qualquer plataforma: no Windows o vetor bruto é
    // UTF-16 e precisa de conversão, por isso o iterador com alocador.
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    while (arg_it.next()) |arg| try argv.append(a, arg);

    var args = Args{};
    if (!try parseArgs(a, argv.items, &args)) return ExitCode.usage.code();

    if (std.mem.eql(u8, args.command, "help") or std.mem.eql(u8, args.command, "--help") or
        std.mem.eql(u8, args.command, "-h"))
    {
        try std.Io.File.stdout().writeStreamingAll(io, help_text);
        return ExitCode.ok.code();
    }
    if (std.mem.eql(u8, args.command, "version") or std.mem.eql(u8, args.command, "--version")) {
        try print(io, "kyn {s} (linguagem {s}, bootstrap Zig 0.17.0)\n", .{ driver.version, driver.language_version });
        return ExitCode.ok.code();
    }

    const input = args.input orelse {
        try printErr(io, "kyn: falta o arquivo de entrada `.kyn`\n", .{});
        return ExitCode.usage.code();
    };

    const source = std.Io.Dir.cwd().readFileAlloc(io, input, a, .unlimited) catch |err| {
        try printErr(io, "kyn: não foi possível ler `{s}`: {t}\n", .{ input, err });
        return ExitCode.internal.code();
    };

    var diags: diag.List = .{};
    const sema_opts = driver.Options{ .require_main = args.require_main, .warn_unused = args.warn_unused };

    if (std.mem.eql(u8, args.command, "tokens")) {
        const tokens = try driver.tokenize(a, source, &diags);
        if (diags.hasErrors()) return report(io, a, &diags, source, input);
        const text = try driver.dumpTokens(a, source, tokens);
        try std.Io.File.stdout().writeStreamingAll(io, text);
        return ExitCode.ok.code();
    }
    if (std.mem.eql(u8, args.command, "ast")) {
        const program = try driver.parse(a, source, &diags);
        if (diags.hasErrors()) return report(io, a, &diags, source, input);
        const text = try driver.dumpAst(a, program);
        try std.Io.File.stdout().writeStreamingAll(io, text);
        return ExitCode.ok.code();
    }

    const is_check = std.mem.eql(u8, args.command, "check");
    const is_emit = std.mem.eql(u8, args.command, "emit");
    const is_build = std.mem.eql(u8, args.command, "build");
    const is_run = std.mem.eql(u8, args.command, "run");
    if (!is_check and !is_emit and !is_build and !is_run) {
        try printErr(io, "kyn: comando desconhecido `{s}`\n", .{args.command});
        try std.Io.File.stdout().writeStreamingAll(io, help_text);
        return ExitCode.usage.code();
    }

    const result = try driver.compile(a, source, input, &diags, sema_opts);
    if (diags.hasErrors() or result == .failure) return report(io, a, &diags, source, input);

    const output = switch (result) {
        .ok => |out| out,
        .failure => unreachable,
    };

    if (output.warnings > 0) {
        const text = try diags.render(a, source, input);
        try std.Io.File.stderr().writeStreamingAll(io, text);
    }

    if (is_check) {
        try print(io, "kyn: `{s}` verificado sem erros\n", .{input});
        return ExitCode.ok.code();
    }

    if (is_run) {
        if (args.emit_c) |path| {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = output.c_source }) catch |err| {
                try printErr(io, "kyn: não foi possível gravar `{s}`: {t}\n", .{ path, err });
                return ExitCode.internal.code();
            };
        }
        return runProgram(io, a, &args, output.c_source, input);
    }

    if (is_build and args.output == null) {
        try printErr(io, "kyn: `build` exige `-o <arquivo.c>`\n", .{});
        return ExitCode.usage.code();
    }

    if (args.output) |path| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = output.c_source }) catch |err| {
            try printErr(io, "kyn: não foi possível gravar `{s}`: {t}\n", .{ path, err });
            return ExitCode.internal.code();
        };
        try print(io, "kyn: C gerado em `{s}`\n", .{path});
        return ExitCode.ok.code();
    }

    try std.Io.File.stdout().writeStreamingAll(io, output.c_source);
    return ExitCode.ok.code();
}

fn runProgram(io: std.Io, a: std.mem.Allocator, args: *const Args, c_source: []const u8, input: []const u8) !u8 {
    // Arquivos intermediários ficam ao lado da entrada, com sufixo próprio.
    // "./" é necessário quando a entrada é um caminho relativo simples: sem um
    // separador, o spawn procuraria o binário no PATH.
    const base = blk: {
        const slash = std.mem.lastIndexOfScalar(u8, input, '/') orelse break :blk "./";
        break :blk input[0 .. slash + 1];
    };
    const stem = blk: {
        const name = input[base.len..];
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse break :blk name;
        break :blk name[0..dot];
    };
    const c_path = try std.fmt.allocPrint(a, "{s}{s}.kyn.c", .{ base, stem });
    const bin_path = try std.fmt.allocPrint(a, "{s}{s}.kyn.bin", .{ base, stem });

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = c_path, .data = c_source }) catch |err| {
        try printErr(io, "kyn: não foi possível gravar `{s}`: {t}\n", .{ c_path, err });
        return ExitCode.internal.code();
    };

    var cc_argv: std.ArrayList([]const u8) = .empty;
    try cc_argv.append(a, args.cc);
    try cc_argv.append(a, "-std=c99");
    try cc_argv.append(a, "-Wall");
    try cc_argv.append(a, "-o");
    try cc_argv.append(a, bin_path);
    try cc_argv.append(a, c_path);

    const cc_result = std.process.run(a, io, .{ .argv = cc_argv.items }) catch |err| {
        try printErr(io, "kyn: não foi possível executar `{s}`: {t}\n", .{ args.cc, err });
        return ExitCode.c_compiler.code();
    };
    if (!cc_result.term.success()) {
        try std.Io.File.stderr().writeStreamingAll(io, cc_result.stderr);
        try printErr(io, "kyn: o compilador C falhou ao construir `{s}`\n", .{c_path});
        return ExitCode.c_compiler.code();
    }
    if (cc_result.stderr.len > 0) {
        try std.Io.File.stderr().writeStreamingAll(io, cc_result.stderr);
    }

    var run_argv: std.ArrayList([]const u8) = .empty;
    try run_argv.append(a, bin_path);
    for (args.extra.items) |arg| try run_argv.append(a, arg);

    var child = std.process.spawn(io, .{
        .argv = run_argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        try printErr(io, "kyn: não foi possível executar `{s}`: {t}\n", .{ bin_path, err });
        return ExitCode.internal.code();
    };
    const term = child.wait(io) catch |err| {
        try printErr(io, "kyn: falha ao esperar `{s}`: {t}\n", .{ bin_path, err });
        return ExitCode.internal.code();
    };
    return switch (term) {
        .exited => |code| code,
        else => ExitCode.internal.code(),
    };
}

fn report(io: std.Io, a: std.mem.Allocator, diags: *diag.List, source: []const u8, path: []const u8) !u8 {
    const text = try diags.render(a, source, path);
    try std.Io.File.stderr().writeStreamingAll(io, text);
    return ExitCode.diagnostics.code();
}

fn parseArgs(a: std.mem.Allocator, argv: []const []const u8, args: *Args) !bool {
    var i: usize = 1;
    var seen_command = false;
    while (i < argv.len) : (i += 1) {
        const raw: []const u8 = argv[i];
        if (raw.len == 0) continue;
        if (raw[0] == '-' and raw.len > 1) {
            if (std.mem.eql(u8, raw, "-o")) {
                i += 1;
                if (i >= argv.len) return false;
                args.output = argv[i];
            } else if (std.mem.eql(u8, raw, "--cc")) {
                i += 1;
                if (i >= argv.len) return false;
                args.cc = argv[i];
            } else if (std.mem.eql(u8, raw, "--emit-c")) {
                i += 1;
                if (i >= argv.len) return false;
                args.emit_c = argv[i];
            } else if (std.mem.eql(u8, raw, "--warn-unused")) {
                args.warn_unused = true;
            } else if (std.mem.eql(u8, raw, "--no-main")) {
                args.require_main = false;
            } else {
                return false;
            }
            continue;
        }
        if (!seen_command) {
            args.command = raw;
            seen_command = true;
            continue;
        }
        if (args.input == null) {
            args.input = raw;
            continue;
        }
        try args.extra.append(a, raw);
    }
    return true;
}

fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [8192]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch {
        try std.Io.File.stdout().writeStreamingAll(io, "<mensagem longa demais>\n");
        return;
    };
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [8192]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch {
        try std.Io.File.stderr().writeStreamingAll(io, "<mensagem longa demais>\n");
        return;
    };
    try std.Io.File.stderr().writeStreamingAll(io, text);
}

const help_text =
    \\kyn — compilador da linguagem Kyn
    \\
    \\Uso:
    \\  kyn <comando> [opções] <arquivo.kyn>
    \\
    \\Comandos:
    \\  check     lexer + parser + semântica, sem gerar código
    \\  emit      escreve o C gerado (stdout ou -o)
    \\  build     igual a `emit`, com -o obrigatório
    \\  run       compila o C com um compilador C e executa o binário
    \\            (grava `nome.kyn.c` e `nome.kyn.bin` ao lado da entrada)
    \\  tokens    imprime a tokenização (depuração)
    \\  ast       imprime a AST (depuração)
    \\  version   imprime as versões do compilador e da linguagem
    \\  help      esta mensagem
    \\
    \\Opções:
    \\  -o <arquivo>     arquivo de saída
    \\  --cc <comando>   compilador C usado por `run` (padrão: cc)
    \\  --warn-unused    ativa o aviso W0001 (variável nunca lida)
    \\  --no-main        não exige `fn main`
    \\  --emit-c <arq>   em `run`, também grava o C intermediário
    \\
    \\Códigos de saída:
    \\  0 sucesso · 1 diagnósticos · 2 uso inválido · 3 falha interna ·
    \\  4 falha no compilador C · em `run`, o código do programa é propagado
    \\
;
