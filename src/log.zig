//! Единый логгер в stderr с меткой времени (UTC).

const std = @import("std");
const util = @import("util.zig");

pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var tbuf: [16]u8 = undefined;
    const ts = util.fmtClock(&tbuf, std.time.timestamp(), 0);
    w.print("[{s}] " ++ fmt ++ "\n", .{ts} ++ args) catch return;
    std.fs.File.stderr().writeAll(w.buffered()) catch {};
}
