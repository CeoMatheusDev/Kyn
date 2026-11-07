// std/os/io.zig — kyn:std (OS I/O)
pub const Error = error{IoFailed};

pub const File = struct {
    pub fn open(path: []const u8) !File {
        _ = path;
        return File{};
    }
    pub fn read(self: *File, buf: []u8) !usize {
        _ = self;
        _ = buf;
        return 0;
    }
    pub fn close(self: *File) void {
        _ = self;
    }
};

// Testes do contrato atual (stub): nenhuma E/S real é feita ainda.

test "io: File.open/read/close compilam e não fazem E/S real" {
    const std = @import("std");
    var f = try File.open("unused.txt");
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try f.read(&buf));
    f.close();
}
