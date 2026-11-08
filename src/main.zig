//! The `kync` CLI — the Kyn bootstrap compiler.
//!
//! Commands and exit codes are an observable contract; see also
//! `docs/development.md`.

const std = @import("std");
const kyn = @import("kyn");

const driver = kyn.driver;
const codegen = kyn.codegen;

const usage =
    \\kync — Kyn compiler (bootstrap)
    \\
    \\Usage:
    \\  kync <command> [options] <file.kyn>
    \\
    \\Commands:
    \\  check <file>      validate syntax and semantics without generating code
    \\  emit <file>       emit the selected backend artifact
    \\  help              show this help
    \\  version           show the version and available backends
    \\
    \\emit options:
    \\  --llvm            textual LLVM IR (default)
    \\  --asm             x86-64 assembly (Linux, System V; assemblable with as/ld)
    \\  -o <file>         write the output to a file (default: stdout)
    \\
    \\general options:
    \\  --lib             do not require 'fn main' (compile a library unit)
    \\  -h, --help        show this help
    \\  -V, --version     show the version
    \\
    \\Exit codes:
    \\  0  success
    \\  1  compilation errors (syntax or semantics)
    \\  2  invalid usage
    \\  3  I/O failure (reading the source or writing the artifact)
    \\
;

const exit_success: u8 = 0;
const exit_compile_error: u8 = 1;
const exit_usage: u8 = 2;
const exit_io: u8 = 3;

const Cli = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    gpa: std.mem.Allocator,
    stderr: std.Io.File,
    stdout: std.Io.File,

    fn writeStderr(self: *Cli, bytes: []const u8) void {
        self.stderr.writeStreamingAll(self.io, bytes) catch {};
    }

    fn printStderr(self: *Cli, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.arena, fmt, args) catch return;
        self.writeStderr(text);
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const collected = collectArgs(arena, init.minimal.args) catch {
        std.process.exit(exit_io);
    };

    var cli: Cli = .{
        .arena = arena,
        .io = init.io,
        .gpa = init.gpa,
        .stderr = std.Io.File.stderr(),
        .stdout = std.Io.File.stdout(),
    };

    if (collected.len == 0) {
        cli.writeStderr(usage);
        std.process.exit(exit_usage);
    }

    const command = collected[0];

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        cli.writeStderr(usage);
        std.process.exit(exit_success);
    }

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "-V") or std.mem.eql(u8, command, "--version")) {
        cli.printStderr("kync {s} (zig {s})\n", .{ kyn.version, kyn.zig_version });
        cli.printStderr("backends: {s} ({s}), {s} ({s})\n", .{
            codegen.Backend.llvm_ir.cliName(),
            codegen.Backend.llvm_ir.description(),
            codegen.Backend.x86_64_asm.cliName(),
            codegen.Backend.x86_64_asm.description(),
        });
        std.process.exit(exit_success);
    }

    var action: driver.Action = .check;
    if (std.mem.eql(u8, command, "check")) {
        action = .check;
    } else if (std.mem.eql(u8, command, "emit")) {
        action = .emit;
    } else {
        cli.printStderr("error: unknown command '{s}'\n\n", .{command});
        cli.writeStderr(usage);
        std.process.exit(exit_usage);
    }

    var source_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var backend: codegen.Backend = .llvm_ir;
    var require_main = true;

    var i: usize = 1;
    while (i < collected.len) : (i += 1) {
        const arg = collected[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            cli.writeStderr(usage);
            std.process.exit(exit_success);
        } else if (std.mem.eql(u8, arg, "--llvm")) {
            backend = .llvm_ir;
        } else if (std.mem.eql(u8, arg, "--asm")) {
            backend = .x86_64_asm;
        } else if (std.mem.eql(u8, arg, "--lib")) {
            require_main = false;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= collected.len) {
                cli.writeStderr("error: '-o' requires an output path\n");
                std.process.exit(exit_usage);
            }
            output_path = collected[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            cli.printStderr("error: unknown option '{s}'\n", .{arg});
            std.process.exit(exit_usage);
        } else if (source_path == null) {
            source_path = arg;
        } else {
            cli.printStderr("error: unexpected argument '{s}'\n", .{arg});
            std.process.exit(exit_usage);
        }
    }

    const path = source_path orelse {
        cli.writeStderr("error: no input file given\n\n");
        cli.writeStderr(usage);
        std.process.exit(exit_usage);
    };

    if (action == .check and output_path != null) {
        cli.writeStderr("error: '-o' is only valid with the 'emit' command\n");
        std.process.exit(exit_usage);
    }

    var result = driver.compilePath(init.gpa, init.io, std.Io.Dir.cwd(), path, .{
        .action = action,
        .backend = backend,
        .require_main = require_main,
    }) catch |err| switch (err) {
        error.OutOfMemory => {
            cli.writeStderr("error: out of memory\n");
            std.process.exit(exit_io);
        },
        else => {
            cli.printStderr("error: could not read '{s}': {s}\n", .{ path, @errorName(err) });
            std.process.exit(exit_io);
        },
    };
    defer result.deinit();

    if (result.diags.count() > 0) {
        var writer = std.Io.File.stderr().writerStreaming(init.io, &.{});
        driver.renderDiagnostics(&writer.interface, result.sources, result.diags) catch {};
        writer.interface.flush() catch {};
        std.process.exit(exit_compile_error);
    }

    if (action == .check) {
        cli.printStderr("ok: '{s}' passed the check\n", .{path});
        std.process.exit(exit_success);
    }

    const output = result.output orelse {
        cli.writeStderr("internal error: backend produced no output\n");
        std.process.exit(exit_io);
    };

    if (output_path) |dest| {
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = dest, .data = output }) catch |err| {
            cli.printStderr("error: could not write '{s}': {s}\n", .{ dest, @errorName(err) });
            std.process.exit(exit_io);
        };
    } else {
        cli.stdout.writeStreamingAll(init.io, output) catch {
            std.process.exit(exit_io);
        };
    }

    std.process.exit(exit_success);
}

/// Copies the arguments into the process arena, since the iterator may
/// reuse its internal buffer between calls.
fn collectArgs(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    var it = try std.process.Args.Iterator.initAllocator(args, arena);
    defer it.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    while (it.next()) |arg| {
        try list.append(arena, try arena.dupe(u8, arg));
    }

    var slice = try list.toOwnedSlice(arena);
    if (slice.len > 0) {
        // argv[0] is the executable path; the CLI only handles what follows.
        slice = slice[1..];
    }
    return slice;
}
