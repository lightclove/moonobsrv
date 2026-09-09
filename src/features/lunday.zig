//! Фича «Лунный день»: команда /day и уведомления о начале нового дня.

const std = @import("std");
const router = @import("../bot/router.zig");
const notify = @import("../bot/notify.zig");
const features = @import("features.zig");
const astro = @import("../astro.zig");
const util = @import("../util.zig");

const lunday = astro.lunday;

fn cmdDay(ctx: *router.Ctx) !void {
    const now = try ctx.moment();
    try writeStatus(now, ctx.base.cfg.tz_offset_sec, ctx.reply);
}

pub fn writeStatus(now: i64, tz: i32, w: *std.Io.Writer) !void {
    const info = lunday.assess(now);
    var b_dt: [64]u8 = undefined;

    try w.print("🗓 На момент запроса — {d}-й лунный день\n", .{info.number});
    try w.print("Начался: {s}\n", .{util.fmtDateTime(&b_dt, info.started, tz, now)});
    try w.print("Закончится: {s}\n", .{util.fmtDateTime(&b_dt, info.ends, tz, now)});
    try w.print("🌙 Луна {s} {s}, освещённость {d}%, фаза: {s}\n", .{
        info.sign.glyph(), info.sign.inRu(), @as(u32, @intFromFloat(info.illum_pct + 0.5)), info.phase,
    });
    try w.print("\nЛунные дни считаются 30-ми частями лунного месяца: {d}-й день начинается, когда элонгация Луна–Солнце проходит {d}°.", .{ info.number, @as(u16, info.number - 1) * 12 });
}

pub fn onTick(base: router.Base) !void {
    const info = lunday.assess(base.now);
    const prev = base.store.lunarDay();
    if (prev == null) {
        // первый запуск — молча инициализируем состояние
        try base.store.setLunarDay(info.number);
        return;
    }
    if (prev.? == info.number) return;
    try base.store.setLunarDay(info.number);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var b_dt: [64]u8 = undefined;
    try w.print("🌙 Начался {d}-й лунный день\n", .{info.number});
    try w.print("Закончится: {s}\n", .{util.fmtDateTime(&b_dt, info.ends, base.cfg.tz_offset_sec, base.now)});
    try w.print("Луна {s} {s}, фаза: {s}", .{ info.sign.glyph(), info.sign.inRu(), info.phase });
    var snap: [128]i64 = undefined;
    notify.broadcast(base.api, base.store.subsSnapshot(&snap), w.buffered());
}

pub const feature = features.Feature{
    .commands = &.{
        .{
            .name = "/day",
            .aliases = &.{ "/lunday", "/moon", "/луна" },
            .description = "лунный день: сейчас или на дату (/day 21.09)",
            .handler = cmdDay,
        },
    },
    .on_tick = onTick,
};
