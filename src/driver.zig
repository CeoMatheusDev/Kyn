//! Pipeline driver: source -> lexer -> parser -> semantics -> backend.
//!
//! Ownership: the public functions create their own arena (allocated from the
//! `gpa`) that owns every artifact — each module's AST, the symbol table,
//! diagnostics and the backend output. The caller must run `Result.deinit()`.
//!
//! Two public entry points:
//!
//! * `compile` — a single in-memory buffer (used by tests and by tools that
//!   already hold the source).
//! * `compilePath` — recursively loads the root file and its `import`s from
//!   disk, resolves paths relative to the importing file and flattens every
//!   module into a single `ast.Program` before semantics.

const std = @import("std");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const ast = @import("ast/ast.zig");
const sema = @import("sema/sema.zig");
const codegen = @import("codegen/codegen.zig");
const diagnostics = @import("diagnostics.zig");
const semantic_index = @import("semantic_index.zig");

pub const Action = enum {
    /// Lexer + parser + semantics only.
    check,
    /// Executa o pipeline completo e emite o artefato do backend.
    emit,
};

pub const Options = struct {
    action: Action = .check,
    backend: codegen.Backend = .llvm_ir,
    require_main: bool = true,
};

/// Byte limit per source file.
pub const max_source_bytes: usize = 16 * 1024 * 1024;

/// Maximum import chain depth (protection against runaway recursion before
/// a cycle is detected).
pub const max_import_depth: usize = 64;

/// A source unit already loaded. `path` is the normalized path used in
/// diagnostics; `text` is the full contents.
pub const Source = struct {
    path: []const u8,
    text: []const u8,
};

pub const SemanticSnapshot = struct {
    program: *ast.Program,
    checked: sema.Checked,
};

pub const Result = struct {
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    diags: *diagnostics.List,
    /// Texto produzido pelo backend (somente em `Action.emit` bem-sucedida).
    output: ?[]const u8 = null,
    /// Arquivos lidos, indexados por `diagnostics.Diagnostic.file`.
    sources: []const Source = &.{},
    /// Compiler-resolved AST and symbol tables, present after successful semantics.
    semantic: ?SemanticSnapshot = null,

    pub fn deinit(self: Result) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    pub fn failed(self: Result) bool {
        return self.diags.hasErrors() or self.output == null and false;
    }

    /// Source associated with the diagnostic, falling back to the first file.
    pub fn sourceFor(self: Result, diag: diagnostics.Diagnostic) Source {
        if (diag.file < self.sources.len) return self.sources[diag.file];
        return self.sources[0];
    }
};

pub const Error = std.mem.Allocator.Error;

/// Root-file read errors. Missing imported files become a
/// diagnostic (`.import_not_found`), not an error.
pub const LoadError = std.Io.Dir.ReadFileAllocError;

fn initResult(gpa: std.mem.Allocator) Error!Result {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }

    const a = arena.allocator();
    const diags = try a.create(diagnostics.List);
    diags.* = diagnostics.List.init(a);

    return .{ .gpa = gpa, .arena = arena, .diags = diags };
}

/// Compiles a single in-memory buffer (no `import` resolved on disk).
pub fn compile(gpa: std.mem.Allocator, source: []const u8, options: Options) Error!Result {
    var result = try initResult(gpa);
    errdefer result.deinit();

    const a = result.arena.allocator();
    const sources = try a.alloc(Source, 1);
    sources[0] = .{ .path = "<input>", .text = source };
    result.sources = sources;

    const program = try parseSource(a, source, result.diags) orelse return result;
    if (program.imports.len > 0) {
        try failUnresolvedImports(&result, program);
        return result;
    }

    try runPipeline(&result, program, options);
    return result;
}

/// Loads `root_path` and, recursively, every file it imports.
pub fn compilePath(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    root_path: []const u8,
    options: Options,
) (Error || LoadError)!Result {
    var result = try initResult(gpa);
    errdefer result.deinit();

    const a = result.arena.allocator();
    const modules = try loadModules(a, io, dir, root_path, result.diags);

    const sources = try a.alloc(Source, modules.len);
    for (modules, 0..) |module, i| sources[i] = module.source;
    result.sources = sources;

    // Loading or syntax errors stop here: there is no complete AST for
    // semantics and the CLI only needs to render the diagnostics.
    if (result.diags.hasErrors()) return result;

    var structs: std.ArrayList(*ast.StructDecl) = .empty;
    var enums: std.ArrayList(*ast.EnumDecl) = .empty;
    var impls: std.ArrayList(*ast.ImplBlock) = .empty;
    var functions: std.ArrayList(*ast.Function) = .empty;
    for (modules) |module| {
        for (module.program.?.structs) |decl| try structs.append(a, decl);
        for (module.program.?.enums) |decl| try enums.append(a, decl);
        for (module.program.?.impls) |block| try impls.append(a, block);
        // Methods already travel inside `functions`, in source order.
        for (module.program.?.functions) |func| try functions.append(a, func);
    }

    // `require_main` and the symbol order depend on modules arriving in
    // pre-order (root first), as the loader returns them.
    const program = try a.create(ast.Program);
    program.* = .{
        .imports = &.{},
        .structs = try structs.toOwnedSlice(a),
        .enums = try enums.toOwnedSlice(a),
        .impls = try impls.toOwnedSlice(a),
        .functions = try functions.toOwnedSlice(a),
        .span = modules[0].program.?.span,
    };

    try runPipeline(&result, program, options);
    return result;
}

const Module = struct {
    source: Source,
    /// `null` when the file was read but did not parse.
    program: ?*ast.Program,
};

/// Walks the import graph depth-first (pre-order) and returns the
/// modules in the order each file first appears. Paths are
/// normalized (`std.fs.path.resolveAlloc`, no syscalls) and each module enters
/// only once, which also covers diamond imports.
fn loadModules(
    a: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    root_path: []const u8,
    diags: *diagnostics.List,
) (Error || LoadError)![]const Module {
    var loader: Loader = .{ .a = a, .io = io, .dir = dir, .diags = diags };
    const root_key = try std.fs.path.resolveAlloc(a, &.{root_path});
    const root_text = try dir.readFileAlloc(io, root_key, a, .limited(max_source_bytes));
    try loader.load(root_key, root_text, 0);
    return loader.modules.items;
}

const Loader = struct {
    a: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    diags: *diagnostics.List,
    /// Accepted modules, in load order (DFS pre-order).
    modules: std.ArrayList(Module) = .empty,
    /// Keys of files already loaded or already reported as missing.
    loaded: std.ArrayList([]const u8) = .empty,
    /// Keys of the current DFS stack, used to detect cycles.
    stack: std.ArrayList([]const u8) = .empty,

    fn load(self: *Loader, key: []const u8, text: []const u8, depth: usize) Error!void {
        const file_id: u32 = @intCast(self.modules.items.len);
        self.diags.current_file = file_id;
        // The file enters the list before the parser so that syntax diagnostics
        // point at it; `program` stays null when parsing fails.
        try self.modules.append(self.a, .{ .source = .{ .path = key, .text = text }, .program = null });
        try self.loaded.append(self.a, key);
        try self.stack.append(self.a, key);
        defer _ = self.stack.pop();

        const program = try parseSource(self.a, text, self.diags) orelse return;
        for (program.functions) |func| func.file_id = file_id;
        for (program.structs) |decl| decl.file_id = file_id;
        for (program.enums) |decl| decl.file_id = file_id;
        for (program.impls) |block| block.file_id = file_id;
        self.modules.items[file_id].program = program;

        const dir = std.fs.path.dirname(key) orelse ".";
        for (program.imports) |import| {
            const child_key = try std.fs.path.resolveAlloc(self.a, &.{ dir, import.path });

            if (indexOf(self.stack.items, child_key) != null) {
                try self.diags.addInFile(
                    file_id,
                    .import_cycle,
                    import.path_span,
                    "import cycle: '{s}' is already in the current chain",
                    .{child_key},
                );
                continue;
            }
            if (indexOf(self.loaded.items, child_key) != null) continue;

            if (depth + 1 >= max_import_depth) {
                try self.diags.addInFile(
                    file_id,
                    .unsupported,
                    import.path_span,
                    "maximum import depth ({d}) exceeded in '{s}'",
                    .{ max_import_depth, child_key },
                );
                try self.loaded.append(self.a, child_key);
                continue;
            }

            const child_text = self.dir.readFileAlloc(self.io, child_key, self.a, .limited(max_source_bytes)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try self.diags.addInFile(
                        file_id,
                        .import_not_found,
                        import.path_span,
                        "could not import '{s}': {s}",
                        .{ import.path, @errorName(err) },
                    );
                    // Avoids repeating the same error for every import of the file.
                    try self.loaded.append(self.a, child_key);
                    continue;
                },
            };
            try self.load(child_key, child_text, depth + 1);
        }
    }
};

fn indexOf(haystack: []const []const u8, needle: []const u8) ?usize {
    for (haystack, 0..) |item, i| {
        if (std.mem.eql(u8, item, needle)) return i;
    }
    return null;
}

/// Runs lexer + parser on one buffer. Returns `null` on a syntax error
/// (the diagnostic is already recorded).
fn parseSource(a: std.mem.Allocator, source: []const u8, diags: *diagnostics.List) Error!?*ast.Program {
    var lex = lexer.Lexer.init(source);
    const tokens = try lex.tokenize(a);

    var p = parser.Parser.init(a, tokens, diags);
    const program = p.parseProgram() catch |err| switch (err) {
        error.ParseError => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return program;
}

fn failUnresolvedImports(result: *Result, program: *const ast.Program) Error!void {
    for (program.imports) |import| {
        try result.diags.add(
            .unsupported,
            import.path_span,
            "import '{s}' cannot be resolved in this mode (use a file path)",
            .{import.path},
        );
    }
}

fn runPipeline(result: *Result, program: *ast.Program, options: Options) Error!void {
    const a = result.arena.allocator();
    const diags = result.diags;

    var file_names = try a.alloc([]const u8, result.sources.len);
    for (result.sources, 0..) |source, i| file_names[i] = source.path;

    var checker = sema.Checker.init(a, diags, .{
        .require_main = options.require_main,
        .file_names = file_names,
    });
    const checked = try checker.checkProgram(program);

    if (diags.hasErrors()) return;
    result.semantic = .{ .program = program, .checked = checked };
    if (options.action == .check) return;

    const output = codegen.generate(a, program, &checked, options.backend) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diags.add(
                .unsupported,
                program.span,
                "could not generate code for backend '{s}': {s}",
                .{ options.backend.cliName(), @errorName(err) },
            );
            return;
        },
    };

    result.output = output;
}

/// Serializes the successful semantic snapshot for language tooling.
pub fn semanticJson(result: *Result) Error![]const u8 {
    const snapshot = result.semantic orelse return error.SemanticSnapshotUnavailable;
    const arena = result.arena.allocator();
    const paths = try arena.alloc([]const u8, result.sources.len);
    for (result.sources, 0..) |source, i| paths[i] = source.path;
    return semantic_index.generate(arena, snapshot.program, &snapshot.checked, paths);
}

/// Renders every diagnostic, each with its correct source file.
pub fn renderDiagnostics(
    writer: *std.Io.Writer,
    sources: []const Source,
    diags: *const diagnostics.List,
) std.Io.Writer.Error!void {
    if (sources.len == 0) return;
    for (diags.items.items) |d| {
        const source = if (d.file < sources.len) sources[d.file] else sources[0];
        try diagnostics.render(writer, source.path, source.text, d);
    }
}

// ---------------------------------------------------------------------------
// Pipeline integration tests (in process)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectClean(source: []const u8, options: Options) !Result {
    var result = try compile(testing.allocator, source, options);
    errdefer result.deinit();
    if (result.diags.hasErrors()) {
        std.debug.print("unexpected diagnostics in a valid compilation:\n", .{});
        for (result.diags.items.items) |d| std.debug.print("  {d}:{d}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.UnexpectedDiagnostics;
    }
    return result;
}

test "driver: check of a valid program" {
    var result = try expectClean(
        \\fn main() -> i32 {
        \\    let x: i32 = 6 * 7;
        \\    return x;
        \\}
    , .{ .action = .check });
    defer result.deinit();
    try testing.expect(result.output == null);
}

test "driver: emit llvm ir" {
    var result = try expectClean("fn main() -> i32 { return 42; }", .{
        .action = .emit,
        .backend = .llvm_ir,
    });
    defer result.deinit();
    const ir = result.output.?;
    try testing.expect(std.mem.indexOf(u8, ir, "define i32 @main()") != null);
    try testing.expect(std.mem.indexOf(u8, ir, "ret i32 42") != null);
}

test "driver: emit assembly x86-64" {
    var result = try expectClean("fn main() -> i32 { return 42; }", .{
        .action = .emit,
        .backend = .x86_64_asm,
    });
    defer result.deinit();
    const asm_text = result.output.?;
    try testing.expect(std.mem.indexOf(u8, asm_text, "_start:") != null);
    try testing.expect(std.mem.indexOf(u8, asm_text, "call kyn_main") != null);
    try testing.expect(std.mem.indexOf(u8, asm_text, "syscall") != null);
}

test "driver: syntax error stops the pipeline" {
    var result = try compile(testing.allocator, "fn main( { }", .{});
    defer result.deinit();
    try testing.expect(result.diags.hasErrors());
    try testing.expect(result.output == null);
    try testing.expectEqual(diagnostics.Kind.syntax, result.diags.items.items[0].kind);
}

test "driver: semantic error produces no artifact" {
    var result = try compile(testing.allocator, "fn main() -> i32 { let x: bool = 1; return 0; }", .{
        .action = .emit,
    });
    defer result.deinit();
    try testing.expect(result.diags.hasErrors());
    try testing.expect(result.output == null);
}

test "driver: require_main desativado permite biblioteca sem main" {
    var result = try compile(testing.allocator, "fn id(x: i32) -> i32 { return x; }", .{
        .require_main = false,
    });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.diags.count());
}

test "driver: diagnostic render includes file, line and column" {
    var result = try compile(testing.allocator, "fn main() -> i32 {\n  return z;\n}\n", .{});
    defer result.deinit();

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try renderDiagnostics(&writer, result.sources, result.diags);
    const out = writer.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "<input>:2:10: error: variable 'z' is not declared"));
}

// ---------------------------------------------------------------------------
// Multi-file loading tests
// ---------------------------------------------------------------------------

const Fixtures = struct {
    tmp: std.testing.TmpDir,

    fn init() Fixtures {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn deinit(self: *Fixtures) void {
        self.tmp.cleanup();
    }

    fn write(self: *Fixtures, name: []const u8, text: []const u8) !void {
        if (std.fs.path.dirname(name)) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = text });
    }

    fn compile(self: *Fixtures, root: []const u8, options: Options) !Result {
        return compilePath(testing.allocator, testing.io, self.tmp.dir, root, options);
    }
};

fn expectKinds(result: Result, expected: []const diagnostics.Kind) !void {
    var actual = std.ArrayList(diagnostics.Kind).empty;
    defer actual.deinit(testing.allocator);
    for (result.diags.items.items) |d| try actual.append(testing.allocator, d.kind);
    try testing.expectEqualSlices(diagnostics.Kind, expected, actual.items);
}

test "driver: imports a function from another file" {
    var fx = Fixtures.init();
    defer fx.deinit();
    try fx.write("lib.kyn", "fn dobro(x: i32) -> i32 { return x * 2; }\n");
    try fx.write("main.kyn",
        \\import "lib.kyn";
        \\fn main() -> i32 { return dobro(21); }
    );

    var result = try fx.compile("main.kyn", .{ .action = .emit });
    defer result.deinit();
    try expectKinds(result, &.{});
    try testing.expectEqual(@as(usize, 2), result.sources.len);
    try testing.expectEqualStrings("main.kyn", result.sources[0].path);
    try testing.expectEqualStrings("lib.kyn", result.sources[1].path);

    const ir = result.output.?;
    try testing.expect(std.mem.indexOf(u8, ir, "define i32 @dobro(i32 %arg0)") != null);
    try testing.expect(std.mem.indexOf(u8, ir, "define i32 @main()") != null);
}

test "driver: import in a subdirectory is relative to the importing file" {
    var fx = Fixtures.init();
    defer fx.deinit();
    try fx.write("util/math.kyn", "fn quadrado(x: i32) -> i32 { return x * x; }\n");
    try fx.write("main.kyn",
        \\import "util/math.kyn";
        \\fn main() -> i32 { return quadrado(7); }
    );

    var result = try fx.compile("main.kyn", .{});
    defer result.deinit();
    try expectKinds(result, &.{});
    try testing.expectEqualStrings("util/math.kyn", result.sources[1].path);
}

test "driver: diamond import loads the module only once" {
    var fx = Fixtures.init();
    defer fx.deinit();
    try fx.write("base.kyn", "fn base() -> i32 { return 1; }\n");
    try fx.write("a.kyn",
        \\import "base.kyn";
        \\fn a() -> i32 { return base(); }
    );
    try fx.write("b.kyn",
        \\import "base.kyn";
        \\fn b() -> i32 { return base(); }
    );
    try fx.write("main.kyn",
        \\import "a.kyn";
        \\import "b.kyn";
        \\fn main() -> i32 { return a() + b(); }
    );

    var result = try fx.compile("main.kyn", .{ .action = .emit });
    defer result.deinit();
    try expectKinds(result, &.{});
    try testing.expectEqual(@as(usize, 4), result.sources.len);
    // `base` appears only once in the IR (no duplicated symbols).
    const ir = result.output.?;
    const first = std.mem.indexOf(u8, ir, "define i32 @base()").?;
    try testing.expect(std.mem.indexOfPos(u8, ir, first + 1, "define i32 @base()") == null);
}

test "driver: import cycle is detected with the right file" {
    var fx = Fixtures.init();
    defer fx.deinit();
    try fx.write("a.kyn",
        \\import "b.kyn";
        \\fn main() -> i32 { return 0; }
    );
    try fx.write("b.kyn",
        \\import "a.kyn";
        \\fn b() -> i32 { return 0; }
    );

    var result = try fx.compile("a.kyn", .{});
    defer result.deinit();
    try expectKinds(result, &.{.import_cycle});
    const diag = result.diags.last().?;
    try testing.expectEqual(@as(u32, 1), diag.file);
    try testing.expect(std.mem.indexOf(u8, diag.message, "import cycle") != null);

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try renderDiagnostics(&writer, result.sources, result.diags);
    try testing.expect(std.mem.startsWith(u8, writer.buffered(), "b.kyn:1:8: error: import cycle"));
}

test "driver: missing imported file becomes a diagnostic" {
    var fx = Fixtures.init();
    defer fx.deinit();
    try fx.write("main.kyn",
        \\import "nao_existe.kyn";
        \\fn main() -> i32 { return 0; }
    );

    var result = try fx.compile("main.kyn", .{});
    defer result.deinit();
    try expectKinds(result, &.{.import_not_found});
    try testing.expectEqual(@as(u32, 0), result.diags.last().?.file);
    try testing.expect(std.mem.indexOf(u8, result.diags.last().?.message, "nao_existe.kyn") != null);
}

test "driver: missing root file propagates an I/O error" {
    var fx = Fixtures.init();
    defer fx.deinit();
    try testing.expectError(error.FileNotFound, fx.compile("missing.kyn", .{}));
}

test "driver: duplicated symbol across files points at the second file" {
    var fx = Fixtures.init();
    defer fx.deinit();
    try fx.write("lib.kyn", "fn dup() -> i32 { return 1; }\n");
    try fx.write("main.kyn",
        \\import "lib.kyn";
        \\fn dup() -> i32 { return 2; }
        \\fn main() -> i32 { return dup(); }
    );

    var result = try fx.compile("main.kyn", .{});
    defer result.deinit();
    try expectKinds(result, &.{.duplicate_declaration});
    const diag = result.diags.last().?;
    // The first declaration (root) is recorded first; the diagnostic points at
    // the second occurrence, in the imported module.
    try testing.expectEqual(@as(u32, 1), diag.file);
    try testing.expect(std.mem.indexOf(u8, diag.message, "already declared in 'main.kyn'") != null);
}

test "driver: semantic error in an imported module cites the source file" {
    var fx = Fixtures.init();
    defer fx.deinit();
    try fx.write("lib.kyn", "fn broken() -> i32 { return missing; }\n");
    try fx.write("main.kyn",
        \\import "lib.kyn";
        \\fn main() -> i32 { return broken(); }
    );

    var result = try fx.compile("main.kyn", .{});
    defer result.deinit();
    try expectKinds(result, &.{.undefined_variable});
    try testing.expectEqual(@as(u32, 1), result.diags.last().?.file);

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try renderDiagnostics(&writer, result.sources, result.diags);
    try testing.expect(std.mem.startsWith(u8, writer.buffered(), "lib.kyn:1:29: error: variable 'missing' is not declared"));
}

test "driver: syntax error in an imported module stops with a diagnostic" {
    var fx = Fixtures.init();
    defer fx.deinit();
    try fx.write("lib.kyn", "fn broken( { }\n");
    try fx.write("main.kyn",
        \\import "lib.kyn";
        \\fn main() -> i32 { return 0; }
    );

    var result = try fx.compile("main.kyn", .{ .action = .emit });
    defer result.deinit();
    try expectKinds(result, &.{.syntax});
    try testing.expectEqual(@as(u32, 1), result.diags.last().?.file);
    try testing.expect(result.output == null);
}

test "driver: unresolved import in `compile` (single buffer) is diagnosed" {
    var result = try compile(testing.allocator,
        \\import "lib.kyn";
        \\fn main() -> i32 { return 0; }
    , .{});
    defer result.deinit();
    try expectKinds(result, &.{.unsupported});
    try testing.expect(std.mem.indexOf(u8, result.diags.last().?.message, "file path") != null);
}

test "driver: struct declared in an imported module" {
    var fx = Fixtures.init();
    defer fx.deinit();
    try fx.write("ponto.kyn",
        \\struct Ponto {
        \\    x: i32,
        \\    y: i32,
        \\}
    );
    try fx.write("main.kyn",
        \\import "ponto.kyn";
        \\
        \\fn main() -> i32 {
        \\    var p: Ponto = Ponto { x: 6, y: 7 };
        \\    p.x = p.x * 2;
        \\    return p.x - p.y;
        \\}
    );

    var result = try fx.compile("main.kyn", .{ .action = .emit });
    defer result.deinit();
    try expectKinds(result, &.{});
    const ir = result.output.?;
    try testing.expect(std.mem.indexOf(u8, ir, "alloca i32, align 4") != null);
    try testing.expect(std.mem.indexOf(u8, ir, "store i32 6, ptr") != null);
}

test "driver: duplicated struct across modules cites the source file" {
    var fx = Fixtures.init();
    defer fx.deinit();
    try fx.write("a.kyn", "struct P { x: i32 }\nfn a() -> i32 { return 1; }\n");
    try fx.write("main.kyn",
        \\import "a.kyn";
        \\
        \\struct P {
        \\    y: i32,
        \\}
        \\
        \\fn main() -> i32 {
        \\    let p: P = P { y: 1 };
        \\    return p.y;
        \\}
    );

    var result = try fx.compile("main.kyn", .{});
    defer result.deinit();
    try expectKinds(result, &.{.duplicate_declaration});
    const diag = result.diags.last().?;
    try testing.expectEqual(@as(u32, 1), diag.file); // the imported module repeats 'P'
    try testing.expect(std.mem.indexOf(u8, diag.message, "struct 'P' already declared in 'main.kyn'") != null);
}
