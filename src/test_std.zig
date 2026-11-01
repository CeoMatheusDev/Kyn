const std = @import("std");
const io = @import("../std/os/io.zig");
const thread = @import("../std/os/thread.zig");
const net = @import("../std/os/net.zig");

test "std basic io thread net" {
    var f = try io.File.open("test.txt");
    defer f.close();
    const t = try thread.Thread.spawn(&struct { fn run() void {} }.run);
    var t_mut = t;
    t_mut.join();
    var s = try net.Socket.connect("localhost", 80);
    defer s.close();
}
