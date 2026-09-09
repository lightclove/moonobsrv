//! Роутер команд и общий контекст вызова.

const std = @import("std");
const config = @import("../config.zig");
const storemod = @import("store.zig");
const tg = @import("telegram.zig");
const util = @import("../util.zig");

/// Контекст ватчера (периодическая проверка неба).
pub const Base = struct {
    /// Арена на один тик/одно обновление.
    alloc: std.mem.Allocator,
    now: i64,
    cfg: *const config.Config,
    store: *storemod.Store,
    api: *tg.Api,
};

/// Контекст обработки команды: Base + чат, писатель ответа,
/// matched-команда и хвост аргументов («/voc 21.09» → args = «21.09»).
pub const Ctx = struct {
    base: Base,
    chat_id: i64,
    /// Telegram-id отправителя (для админских проверок); null — webhook-запрос без from.
    from_id: ?i64 = null,
    /// Имя отправителя для карточек заявок.
    from_label: []const u8 = "",
    /// Полный текст сообщения (для превью в заявке на доступ).
    raw_text: []const u8 = "",
    reply: *std.Io.Writer,
    cmd: *const Command,
    args: []const u8 = &.{},

    /// Момент запроса: «сейчас» или дата из аргумента
    /// (дд.мм, дд.мм.гггг, гггг-мм-дд → полдень того дня).
    /// При невнятном аргументе пишет подсказку и возвращает ошибку.
    pub fn moment(self: *Ctx) !i64 {
        return (util.parseDateArg(self.args, self.base.cfg.tz_offset_sec) catch {
            try self.reply.print("Не понял дату «{s}».\nФормат: ДД.ММ, ДД.ММ.ГГГГ или ГГГГ-ММ-ДД.", .{self.args});
            return error.BadDate;
        }) orelse self.base.now;
    }
};

pub const Command = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    description: []const u8 = "",
    handler: *const fn (*Ctx) anyerror!void,
};

pub const Match = struct {
    cmd: *const Command,
    args: []const u8,
};

/// Сопоставляет «/voc@my_bot 21.09» с реестром команд.
pub fn match(registry: []const Command, text_in: []const u8) ?Match {
    if (text_in.len == 0 or text_in[0] != '/') return null;
    var name_part = text_in;
    var args: []const u8 = &.{};
    if (std.mem.indexOfScalar(u8, name_part, ' ')) |i| {
        args = std.mem.trim(u8, name_part[i + 1 ..], " \t");
        name_part = name_part[0..i];
    }
    if (std.mem.indexOfScalar(u8, name_part, '@')) |i| name_part = name_part[0..i];
    for (registry) |*cmd| {
        if (std.mem.eql(u8, cmd.name, name_part)) return .{ .cmd = cmd, .args = args };
        for (cmd.aliases) |al| {
            if (std.mem.eql(u8, al, name_part)) return .{ .cmd = cmd, .args = args };
        }
    }
    return null;
}

test "match: имена, суффиксы, аргументы" {
    const h = struct {
        fn nop(_: *Ctx) anyerror!void {}
    }.nop;
    const reg = [_]Command{
        .{ .name = "/voc", .aliases = &.{"/холостая"}, .description = "d", .handler = h },
    };
    const m1 = match(&reg, "/voc").?;
    try std.testing.expectEqualStrings("/voc", m1.cmd.name);
    try std.testing.expectEqualStrings("", m1.args);
    const m2 = match(&reg, "/voc@my_bot 21.09.2026").?;
    try std.testing.expectEqualStrings("21.09.2026", m2.args);
    const m3 = match(&reg, "/холостая   завтра ").?;
    try std.testing.expectEqualStrings("завтра", m3.args);
    try std.testing.expect(match(&reg, "привет") == null);
    try std.testing.expect(match(&reg, "/нет") == null);
}
