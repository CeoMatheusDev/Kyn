//! Driver do pipeline: fonte -> lexer -> parser -> semântica -> backend.
//!
//! Ownership: as funções públicas criam uma arena própria (alocada no `gpa`)
//! que possui todos os artefatos — AST de cada módulo, tabela de símbolos,
//! diagnósticos e saída do backend. O chamador deve invocar `Result.deinit()`.
//!
//! Duas entradas públicas:
//!
//! * `compile` — um único buffer em memória (usada pelos testes e por
//!   ferramentas que já têm a fonte em mãos).
//! * `compilePath` — carrega recursivamente o arquivo raiz e seus `import`s do
//!   disco, resolve caminhos relativos ao arquivo importador e achata todos os
//!   módulos em um único `ast.Program` antes da semântica.

const std = @import("std");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const ast = @import("ast/ast.zig");
const sema = @import("sema/sema.zig");
const codegen = @import("codegen/codegen.zig");
const diagnostics = @import("diagnostics.zig");

pub const Action = enum {
    /// Apenas lexer + parser + semântica.
    check,
    /// Executa o pipeline completo e emite o artefato do backend.
    emit,
};

pub const Options = struct {
    action: Action = .check,
    backend: codegen.Backend = .llvm_ir,
    require_main: bool = true,
};

/// Limite de bytes por arquivo de origem.
pub const max_source_bytes: usize = 16 * 1024 * 1024;

/// Profundidade máxima da cadeia de importações (proteção contra recursão
/// descontrolada antes de detectar ciclos).
pub const max_import_depth: usize = 64;

/// Uma unidade de origem já carregada. `path` é o caminho normalizado usado
/// nos diagnósticos; `text` é o conteúdo completo.
pub const Source = struct {
    path: []const u8,
    text: []const u8,
};

pub const Result = struct {
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    diags: *diagnostics.List,
    /// Texto produzido pelo backend (somente em `Action.emit` bem-sucedida).
    output: ?[]const u8 = null,
    /// Arquivos lidos, indexados por `diagnostics.Diagnostic.file`.
    sources: []const Source = &.{},

    pub fn deinit(self: Result) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    pub fn failed(self: Result) bool {
        return self.diags.hasErrors() or self.output == null and false;
    }

    /// Fonte associada ao diagnóstico, com fallback para o primeiro arquivo.
    pub fn sourceFor(self: Result, diag: diagnostics.Diagnostic) Source {
        if (diag.file < self.sources.len) return self.sources[diag.file];
        return self.sources[0];
    }
};

pub const Error = std.mem.Allocator.Error;

/// Erros de leitura do arquivo raiz. Arquivos importados ausentes viram
/// diagnóstico (`.import_not_found`), não erro.
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

/// Compila um único buffer em memória (sem `import` resolvidos no disco).
pub fn compile(gpa: std.mem.Allocator, source: []const u8, options: Options) Error!Result {
    var result = try initResult(gpa);
    errdefer result.deinit();

    const a = result.arena.allocator();
    const sources = try a.alloc(Source, 1);
    sources[0] = .{ .path = "<entrada>", .text = source };
    result.sources = sources;

    const program = try parseSource(a, source, result.diags) orelse return result;
    if (program.imports.len > 0) {
        try failUnresolvedImports(&result, program);
        return result;
    }

    try runPipeline(&result, program, options);
    return result;
}

/// Carrega `root_path` e, recursivamente, todos os arquivos por ele importados.
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

    // Erros de carregamento ou de sintaxe já interrompem aqui: não há AST
    // completa para a semântica e a CLI só precisa renderizar os diagnósticos.
    if (result.diags.hasErrors()) return result;

    var structs: std.ArrayList(*ast.StructDecl) = .empty;
    var functions: std.ArrayList(*ast.Function) = .empty;
    for (modules) |module| {
        for (module.program.?.structs) |decl| try structs.append(a, decl);
        for (module.program.?.functions) |func| try functions.append(a, func);
    }

    // `require_main` e a ordem dos símbolos dependem de os módulos entrarem em
    // pré-ordem (raiz primeiro), como o loader os devolve.
    const program = try a.create(ast.Program);
    program.* = .{
        .imports = &.{},
        .structs = try structs.toOwnedSlice(a),
        .functions = try functions.toOwnedSlice(a),
        .span = modules[0].program.?.span,
    };

    try runPipeline(&result, program, options);
    return result;
}

const Module = struct {
    source: Source,
    /// `null` quando o arquivo foi lido mas não passou no parser.
    program: ?*ast.Program,
};

/// Percorre o grafo de importações em profundidade (pré-ordem) e devolve os
/// módulos na ordem em que o arquivo aparece pela primeira vez. Caminhos são
/// normalizados (`std.fs.path.resolveAlloc`, sem syscalls) e cada módulo entra
/// uma única vez, o que também cobre importações em diamante.
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
    /// Módulos aceitos, na ordem de carregamento (pré-ordem de DFS).
    modules: std.ArrayList(Module) = .empty,
    /// Chaves de arquivos já carregados ou já reportados como ausentes.
    loaded: std.ArrayList([]const u8) = .empty,
    /// Chaves da pilha de DFS atual, para detectar ciclos.
    stack: std.ArrayList([]const u8) = .empty,

    fn load(self: *Loader, key: []const u8, text: []const u8, depth: usize) Error!void {
        const file_id: u32 = @intCast(self.modules.items.len);
        self.diags.current_file = file_id;
        // O arquivo entra na lista antes do parser para que os diagnósticos de
        // sintaxe apontem para ele; `program` fica nulo se a análise falhar.
        try self.modules.append(self.a, .{ .source = .{ .path = key, .text = text }, .program = null });
        try self.loaded.append(self.a, key);
        try self.stack.append(self.a, key);
        defer _ = self.stack.pop();

        const program = try parseSource(self.a, text, self.diags) orelse return;
        for (program.functions) |func| func.file_id = file_id;
        for (program.structs) |decl| decl.file_id = file_id;
        self.modules.items[file_id].program = program;

        const dir = std.fs.path.dirname(key) orelse ".";
        for (program.imports) |import| {
            const child_key = try std.fs.path.resolveAlloc(self.a, &.{ dir, import.path });

            if (indexOf(self.stack.items, child_key) != null) {
                try self.diags.addInFile(
                    file_id,
                    .import_cycle,
                    import.path_span,
                    "ciclo de importação: '{s}' já está na cadeia atual",
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
                    "profundidade máxima de importação ({d}) excedida em '{s}'",
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
                        "não foi possível importar '{s}': {s}",
                        .{ import.path, @errorName(err) },
                    );
                    // Evita repetir o mesmo erro a cada importação do arquivo.
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

/// Roda lexer + parser em um buffer. Retorna `null` quando houve erro sintático
/// (o diagnóstico já foi registrado).
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
            "importação '{s}' não pode ser resolvida neste modo (use um caminho de arquivo)",
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
    if (options.action == .check) return;

    const output = codegen.generate(a, program, &checked, options.backend) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diags.add(
                .unsupported,
                program.span,
                "não foi possível gerar código para o backend '{s}': {s}",
                .{ options.backend.cliName(), @errorName(err) },
            );
            return;
        },
    };

    result.output = output;
}

/// Renderiza todos os diagnósticos, cada um com o arquivo de origem correto.
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
// Testes de integração do pipeline (em processo)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectClean(source: []const u8, options: Options) !Result {
    var result = try compile(testing.allocator, source, options);
    errdefer result.deinit();
    if (result.diags.hasErrors()) {
        std.debug.print("diagnósticos inesperados em compilação válida:\n", .{});
        for (result.diags.items.items) |d| std.debug.print("  {d}:{d}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.UnexpectedDiagnostics;
    }
    return result;
}

test "driver: check de programa válido" {
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

test "driver: erro de sintaxe interrompe o pipeline" {
    var result = try compile(testing.allocator, "fn main( { }", .{});
    defer result.deinit();
    try testing.expect(result.diags.hasErrors());
    try testing.expect(result.output == null);
    try testing.expectEqual(diagnostics.Kind.syntax, result.diags.items.items[0].kind);
}

test "driver: erro semântico não gera artefato" {
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

test "driver: render de diagnósticos inclui arquivo, linha e coluna" {
    var result = try compile(testing.allocator, "fn main() -> i32 {\n  return z;\n}\n", .{});
    defer result.deinit();

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try renderDiagnostics(&writer, result.sources, result.diags);
    const out = writer.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "<entrada>:2:10: erro: variável 'z' não declarada"));
}

// ---------------------------------------------------------------------------
// Testes de carregamento multi-arquivo
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

test "driver: importa função de outro arquivo" {
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

test "driver: importação em subdiretório é relativa ao arquivo importador" {
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

test "driver: importação em diamante carrega o módulo uma única vez" {
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
    // `base` aparece uma única vez no IR (sem duplicação de símbolos).
    const ir = result.output.?;
    const first = std.mem.indexOf(u8, ir, "define i32 @base()").?;
    try testing.expect(std.mem.indexOfPos(u8, ir, first + 1, "define i32 @base()") == null);
}

test "driver: ciclo de importação é detectado com o arquivo certo" {
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
    try testing.expect(std.mem.indexOf(u8, diag.message, "ciclo de importação") != null);

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try renderDiagnostics(&writer, result.sources, result.diags);
    try testing.expect(std.mem.startsWith(u8, writer.buffered(), "b.kyn:1:8: erro: ciclo de importação"));
}

test "driver: arquivo importado ausente vira diagnóstico" {
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

test "driver: arquivo raiz ausente propaga erro de E/S" {
    var fx = Fixtures.init();
    defer fx.deinit();
    try testing.expectError(error.FileNotFound, fx.compile("ausente.kyn", .{}));
}

test "driver: símbolo duplicado entre arquivos aponta o segundo arquivo" {
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
    // A primeira declaração (raiz) é registrada antes; o diagnóstico aponta a
    // segunda ocorrência, no módulo importado.
    try testing.expectEqual(@as(u32, 1), diag.file);
    try testing.expect(std.mem.indexOf(u8, diag.message, "já declarada em 'main.kyn'") != null);
}

test "driver: erro semântico em módulo importado cita o arquivo de origem" {
    var fx = Fixtures.init();
    defer fx.deinit();
    try fx.write("lib.kyn", "fn quebrado() -> i32 { return ausente; }\n");
    try fx.write("main.kyn",
        \\import "lib.kyn";
        \\fn main() -> i32 { return quebrado(); }
    );

    var result = try fx.compile("main.kyn", .{});
    defer result.deinit();
    try expectKinds(result, &.{.undefined_variable});
    try testing.expectEqual(@as(u32, 1), result.diags.last().?.file);

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try renderDiagnostics(&writer, result.sources, result.diags);
    try testing.expect(std.mem.startsWith(u8, writer.buffered(), "lib.kyn:1:31: erro: variável 'ausente' não declarada"));
}

test "driver: erro de sintaxe em módulo importado interrompe com diagnóstico" {
    var fx = Fixtures.init();
    defer fx.deinit();
    try fx.write("lib.kyn", "fn quebrado( { }\n");
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

test "driver: import não resolvido em `compile` (buffer único) é diagnosticado" {
    var result = try compile(testing.allocator,
        \\import "lib.kyn";
        \\fn main() -> i32 { return 0; }
    , .{});
    defer result.deinit();
    try expectKinds(result, &.{.unsupported});
    try testing.expect(std.mem.indexOf(u8, result.diags.last().?.message, "caminho de arquivo") != null);
}

test "driver: struct declarado em módulo importado" {
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

test "driver: struct duplicado entre módulos cita o arquivo de origem" {
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
    try testing.expectEqual(@as(u32, 1), diag.file); // o módulo importado repete 'P'
    try testing.expect(std.mem.indexOf(u8, diag.message, "struct 'P' já declarado em 'main.kyn'") != null);
}
