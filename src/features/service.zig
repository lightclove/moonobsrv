//! Сервисные команды: /start /help /status /subscribe /unsubscribe.
//! /start и /help шлют HTML-меню с кнопками (гид, оглавление, меню команд).

const std = @import("std");
const router = @import("../bot/router.zig");
const features = @import("features.zig");
const runtime = @import("../runtime.zig");
const util = @import("../util.zig");
const wizard = @import("wizard.zig");

fn sendHtmlWithKb(ctx: *router.Ctx, text: []const u8) void {
    var kb: [512]u8 = undefined;
    var kw: std.Io.Writer = .fixed(&kb);
    wizard.openKb(&kw) catch {};
    _ = ctx.base.api.sendMessageOpts(ctx.chat_id, text, true, kbKw(&kw)) catch {};
}

fn kbKw(kw: *std.Io.Writer) ?[]const u8 {
    if (kw.buffered().len == 0) return null;
    return kw.buffered();
}

fn cmdStart(ctx: *router.Ctx) !void {
    const admin = ctx.base.cfg.admin_id != 0 and ctx.from_id != null and ctx.from_id.? == ctx.base.cfg.admin_id;
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("🌒 <b>Привет!</b> Я слежу за небом: холостая Луна, ретро-Меркурий и лунные дни.\nВсё считается локально, без внешних сервисов.\n\nСамый быстрый путь научиться — пошаговый гид из {d} слайдов.", .{wizard.n(admin)});
    sendHtmlWithKb(ctx, w.buffered());
}

fn cmdHelp(ctx: *router.Ctx) !void {
    const admin = ctx.base.cfg.admin_id != 0 and ctx.from_id != null and ctx.from_id.? == ctx.base.cfg.admin_id;
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try wizard.helpText(&w, admin);
    sendHtmlWithKb(ctx, w.buffered());
}

fn cmdStatus(ctx: *router.Ctx) !void {
    var b_dur: [32]u8 = undefined;
    var b_tz: [24]u8 = undefined;
    const uptime = if (runtime.started_at > 0) std.time.timestamp() - runtime.started_at else 0;
    try ctx.reply.print("🛰 moonobsrv v{s}\n", .{runtime.version});
    try ctx.reply.print("Ваш id: {d}\n", .{ctx.chat_id});
    try ctx.reply.print("Аптайм: {s}\n", .{util.fmtDur(&b_dur, uptime)});
    try ctx.reply.print("Подписчиков: {d}\n", .{ctx.base.store.subsCount()});
    try ctx.reply.print("Проверка неба: каждые {d} с\n", .{ctx.base.cfg.check_interval_s});
    try ctx.reply.print("Часовой пояс вывода: {s}", .{util.tzLabel(&b_tz, ctx.base.cfg.tz_offset_sec)});
}

fn cmdSubscribe(ctx: *router.Ctx) !void {
    ctx.base.store.addSub(ctx.chat_id) catch {
        return ctx.reply.print("⚠ Не удалось сохранить подписку, попробуйте позже.", .{});
    };
    try ctx.reply.print("🔔 Подписка оформлена.\nБуду присылать: начало и конец холостой Луны, станции Меркурия и других планет, начало лунных дней.\nОтписка: /unsubscribe", .{});
}

fn cmdUnsubscribe(ctx: *router.Ctx) !void {
    if (!ctx.base.store.hasSub(ctx.chat_id)) {
        return ctx.reply.print("Вы ещё не были подписаны.", .{});
    }
    ctx.base.store.removeSub(ctx.chat_id) catch {
        return ctx.reply.print("⚠ Не удалось сохранить изменение, попробуйте позже.", .{});
    };
    try ctx.reply.print("🔕 Подписка отменена.", .{});
}

pub const feature = features.Feature{
    .commands = &.{
        .{ .name = "/start", .description = "приветствие и кнопки", .handler = cmdStart },
        .{ .name = "/help", .aliases = &.{"/commands"}, .description = "меню команд", .handler = cmdHelp },
        .{ .name = "/status", .aliases = &.{"/stat"}, .description = "состояние сервиса", .handler = cmdStatus },
        .{ .name = "/subscribe", .aliases = &.{ "/sub", "/подписка" }, .description = "подписаться на уведомления о событиях", .handler = cmdSubscribe },
        .{ .name = "/unsubscribe", .aliases = &.{ "/unsub", "/отписка" }, .description = "отключить уведомления", .handler = cmdUnsubscribe },
    },
};
