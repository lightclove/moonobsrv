//! Рассылка уведомлений подписчикам. Ошибки доставки логируются и
//! не прерывают цикл — один недоступный чат не должен блокировать остальных.

const std = @import("std");
const tg = @import("telegram.zig");

pub fn broadcast(api: *tg.Api, subs: []const i64, text: []const u8) void {
    for (subs) |chat_id| {
        api.sendMessage(chat_id, text) catch |e| {
            logWarn("sendMessage({d}): {s}", .{ chat_id, @errorName(e) });
        };
    }
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("[warn] " ++ fmt ++ "\n", args) catch return;
    std.fs.File.stderr().writeAll(w.buffered()) catch {};
}
