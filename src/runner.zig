//! src/runner.zig — Suíte de integração das fixtures `.kyn`.
//!
//! Para cada `nome.kyn` acompanhado de `nome.expect` o runner:
//! 1. executa o pipeline completo em processo (lexer → parser → semântica →
//!    backend C), sem passar pela CLI;
//! 2. se o `.expect` declara `error: E0013`, exige falha com aquele código;
//! 3. caso contrário, grava o C em `--tmp`, invoca o compilador C de `--cc`,
//!    executa o binário e compara código de saída e stdout.
//!
//! Formato do `.expect`:
//! ```text
//! exit: 0            # código de saída esperado (padrão 0)
//! stdout: |          # saída esperada, linhas recuadas por dois espaços
//!   Olá, Kyn!        # `\t`, `\n`, `\r`, `\"` e `\\` são interpretados
//! ```
//! ou, para casos negativos:
//! ```text
//! error: E0013
//! ```

const std = @import("std");
const root = @import("root.zig");
const driver = root.driver;
const diag = root.diag;

const Config = struct {
    cc: []const u8 = "cc",
    dirs: std.ArrayList([]const u8) = .empty,
    tmp: []const u8 = "zig-out/tmp",
    filter: ?[]const u8 = null,
};

const Expect = struct {
    exit_code: u8 = 0,
    stdout_text: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
};

const Outcome = enum { ok, failed };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var config = Config{};
    const argv = init.minimal.args.vector;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--cc") and i + 1 < argv.len) {
            i += 1;
            config.cc = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--tmp") and i + 1 < argv.len) {
            i += 1;
            config.tmp = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--filter") and i + 1 < argv.len) {
            i += 1;
            config.filter = std.mem.span(argv[i]);
        } else if (arg.len > 0 and arg[0] != '-') {
            try config.dirs.append(a, arg);
        }
    }
    if (config.dirs.items.len == 0) {
        try std.Io.File.stderr().writeStreamingAll(io, "kyn-test: informe ao menos um diretório de casos\n");
        return 2;
    }

    std.Io.Dir.cwd().createDirPath(io, config.tmp) catch |err| {
        try print(io, "kyn-test: não foi possível criar `{s}`: {t}\n", .{ config.tmp, err });
        return 3;
    };

    var total: usize = 0;
    var failures: usize = 0;

    for (config.dirs.items) |dir| {
        var entries: std.ArrayList([]const u8) = .empty;
        var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch |err| {
            try print(io, "kyn-test: não foi possível abrir `{s}`: {t}\n", .{ dir, err });
            return 3;
        };
        defer handle.close(io);
        var it = handle.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".kyn")) continue;
            try entries.append(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, entry.name }));
        }
        std.mem.sort([]const u8, entries.items, {}, orderStrings);

        for (entries.items) |case_path| {
            if (config.filter) |filter| {
                if (std.mem.indexOf(u8, case_path, filter) == null) continue;
            }
            total += 1;
            const outcome = runCase(io, a, &config, case_path) catch |err| blk: {
                try print(io, "FAIL {s} (erro interno: {t})\n", .{ case_path, err });
                break :blk .failed;
            };
            if (outcome == .failed) failures += 1;
        }
    }

    try print(io, "\n{s}: {d} caso(s), {d} falha(s)\n", .{
        if (failures == 0) "integração OK" else "integração FALHOU",
        total,
        failures,
    });
    return if (failures == 0) 0 else 1;
}

fn orderStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn runCase(io: std.Io, a: std.mem.Allocator, config: *const Config, case_path: []const u8) !Outcome {
    const expect_path = try replaceExtension(a, case_path, ".expect");
    const source = try std.Io.Dir.cwd().readFileAlloc(io, case_path, a, .unlimited);
    const expect_text = std.Io.Dir.cwd().readFileAlloc(io, expect_path, a, .unlimited) catch {
        try print(io, "FAIL {s} (falta o arquivo `{s}`)\n", .{ case_path, expect_path });
        return .failed;
    };
    const expect = parseExpect(a, expect_text);

    var diags: diag.List = .{};
    const result = try driver.compile(a, source, case_path, &diags, .{});

    if (expect.error_code) |code| {
        if (!diags.hasErrors()) {
            try print(io, "FAIL {s} (esperava erro {s}, mas a compilação passou)\n", .{ case_path, code });
            return .failed;
        }
        if (!hasCodeText(&diags, code)) {
            const rendered = try diags.render(a, source, case_path);
            try print(io, "FAIL {s} (esperava {s}, vieram outros códigos)\n{s}", .{ case_path, code, rendered });
            return .failed;
        }
        try print(io, "ok   {s} ({s})\n", .{ case_path, code });
        return .ok;
    }

    if (diags.hasErrors() or result == .failure) {
        const rendered = try diags.render(a, source, case_path);
        try print(io, "FAIL {s} (compilação falhou)\n{s}", .{ case_path, rendered });
        return .failed;
    }

    const output = switch (result) {
        .ok => |out| out,
        .failure => unreachable,
    };

    const stem = stemOf(case_path);
    const c_path = try std.fmt.allocPrint(a, "{s}/{s}.c", .{ config.tmp, stem });
    const bin_path = try std.fmt.allocPrint(a, "{s}/{s}.bin", .{ config.tmp, stem });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = c_path, .data = output.c_source });

    const cc_result = try std.process.run(a, io, .{ .argv = &.{
        config.cc,  "-std=c99", "-Wall",       "-o",
        bin_path,   c_path,
    } });
    if (!cc_result.term.success()) {
        try print(io, "FAIL {s} (o compilador C falhou)\n{s}\n--- C gerado ---\n{s}\n", .{
            case_path,
            cc_result.stderr,
            output.c_source,
        });
        return .failed;
    }

    const run_result = try std.process.run(a, io, .{ .argv = &.{bin_path} });
    const actual_exit: u8 = switch (run_result.term) {
        .exited => |code| code,
        else => 255,
    };

    var ok = true;
    if (actual_exit != expect.exit_code) {
        try print(io, "FAIL {s} (exit esperado {d}, obtido {d})\n", .{ case_path, expect.exit_code, actual_exit });
        ok = false;
    }
    if (expect.stdout_text) |wanted| {
        if (!std.mem.eql(u8, run_result.stdout, wanted)) {
            try print(io, "FAIL {s} (stdout diferente)\n--- esperado ---\n{s}--- obtido ---\n{s}\n", .{
                case_path,
                wanted,
                run_result.stdout,
            });
            ok = false;
        }
    }
    if (!ok) return .failed;

    try print(io, "ok   {s}\n", .{case_path});
    return .ok;
}

fn hasCodeText(diags: *const diag.List, code: []const u8) bool {
    for (diags.items.items) |item| {
        if (std.mem.eql(u8, item.code.text(), code)) return true;
    }
    return false;
}

fn stemOf(path: []const u8) []const u8 {
    var stem = path;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| stem = path[slash + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, stem, '.')) |dot| stem = stem[0..dot];
    return stem;
}

fn replaceExtension(a: std.mem.Allocator, path: []const u8, ext: []const u8) ![]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    return std.fmt.allocPrint(a, "{s}{s}", .{ path[0..dot], ext });
}

fn parseExpect(a: std.mem.Allocator, text: []const u8) Expect {
    var expect = Expect{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_stdout = false;
    var collected: std.ArrayList(u8) = .empty;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (in_stdout) {
            if (std.mem.startsWith(u8, line, "  ")) {
                appendUnescaped(a, &collected, line[2..]) catch return expect;
                collected.append(a, '\n') catch return expect;
                continue;
            }
            if (line.len == 0) continue;
            in_stdout = false;
        }
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.startsWith(u8, trimmed, "exit:")) {
            const value = std.mem.trim(u8, trimmed["exit:".len..], " \t");
            expect.exit_code = std.fmt.parseInt(u8, value, 10) catch 0;
        } else if (std.mem.startsWith(u8, trimmed, "stdout:")) {
            in_stdout = true;
        } else if (std.mem.startsWith(u8, trimmed, "error:")) {
            expect.error_code = std.mem.trim(u8, trimmed["error:".len..], " \t");
        }
    }
    if (collected.items.len > 0) expect.stdout_text = collected.items;
    return expect;
}

/// Interpreta `\t`, `\n`, `\r`, `\"` e `\\` nas linhas de stdout esperado.
fn appendUnescaped(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\' or i + 1 >= text.len) {
            try out.append(a, text[i]);
            continue;
        }
        i += 1;
        switch (text[i]) {
            't' => try out.append(a, '\t'),
            'n' => try out.append(a, '\n'),
            'r' => try out.append(a, '\r'),
            '"' => try out.append(a, '"'),
            '\\' => try out.append(a, '\\'),
            else => {
                try out.append(a, '\\');
                try out.append(a, text[i]);
            },
        }
    }
}

fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [65536]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch {
        try std.Io.File.stdout().writeStreamingAll(io, "<mensagem longa demais>\n");
        return;
    };
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

test "parseExpect reads exit, stdout and error" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const run_case = parseExpect(a, "# comentário\nexit: 7\nstdout: |\n  linha um\n  tab:\tdois\n");
    try std.testing.expectEqual(@as(u8, 7), run_case.exit_code);
    try std.testing.expectEqualStrings("linha um\ntab:\tdois\n", run_case.stdout_text.?);
    try std.testing.expect(run_case.error_code == null);

    const error_case = parseExpect(a, "error: E0013\n");
    try std.testing.expectEqualStrings("E0013", error_case.error_code.?);
}

test "stemOf and replaceExtension" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("hello", stemOf("tests/cases/hello.kyn"));
    try std.testing.expectEqualStrings("tests/cases/hello.expect", try replaceExtension(a, "tests/cases/hello.kyn", ".expect"));
}
