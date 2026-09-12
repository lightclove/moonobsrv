//! Фича «Лунный день»: команда /day и уведомления о начале нового дня.
//! Две системы счёта рядом: титхи (30-я часть месяца по элонгации, глобально)
//! и лунные сутки «от восхода до восхода» для места наблюдателя из конфига.

const std = @import("std");
const router = @import("../bot/router.zig");
const notify = @import("../bot/notify.zig");
const features = @import("features.zig");
const config = @import("../config.zig");
const astro = @import("../astro.zig");
const util = @import("../util.zig");

const lunday = astro.lunday;
const lunday_rise = astro.lunday_rise;
const rise = astro.rise;

pub fn observerOf(cfg: *const config.Config) rise.Observer {
    return .{ .lat_deg = cfg.lat_deg, .lon_deg = cfg.lon_deg };
}

fn cmdDay(ctx: *router.Ctx) !void {
    const now = try ctx.moment();
    try writeStatus(now, ctx.base.cfg.tz_offset_sec, observerOf(ctx.base.cfg), ctx.reply);
}

/// «55.8° с.ш., 37.6° в.д.» — место без имени, чтобы не тащить справочник городов.
pub fn fmtPlace(buf: []u8, obs: rise.Observer) []const u8 {
    const la: i64 = @intFromFloat(@round(@abs(obs.lat_deg) * 10.0));
    const lo: i64 = @intFromFloat(@round(@abs(obs.lon_deg) * 10.0));
    const ns: []const u8 = if (obs.lat_deg < 0) "ю.ш." else "с.ш.";
    const ew: []const u8 = if (obs.lon_deg < 0) "з.д." else "в.д.";
    return std.fmt.bufPrint(buf, "{d}.{d}° {s}, {d}.{d}° {s}", .{
        @divTrunc(la, 10), @mod(la, 10), ns, @divTrunc(lo, 10), @mod(lo, 10), ew,
    }) catch buf[0..0];
}

pub fn writeStatus(now: i64, tz: i32, obs: rise.Observer, w: *std.Io.Writer) !void {
    const info = lunday.assess(now);
    var b_dt: [64]u8 = undefined;

    try w.print("🗓 На момент запроса — {d}-й лунный день (титхи)\n", .{info.number});
    try w.print("Начался: {s}\n", .{util.fmtDateTime(&b_dt, info.started, tz, now)});
    try w.print("Закончится: {s}\n", .{util.fmtDateTime(&b_dt, info.ends, tz, now)});

    if (lunday_rise.assess(now, obs)) |r| {
        var b_pl: [48]u8 = undefined;
        try w.print("\n🌄 По восходам Луны ({s}) — {d}-е лунные сутки\n", .{ fmtPlace(&b_pl, obs), r.number });
        try w.print("Начались: {s}\n", .{util.fmtDateTime(&b_dt, r.started, tz, now)});
        try w.print("Закончатся: {s}\n", .{util.fmtDateTime(&b_dt, r.ends, tz, now)});
    }

    try w.print("\n🌙 Луна {s} {s}, освещённость {d}%, фаза: {s}\n", .{
        info.sign.glyph(), info.sign.inRu(), @as(u32, @intFromFloat(info.illum_pct + 0.5)), info.phase,
    });
    try w.print("\nДве системы счёта. Титхи — 30-я часть лунного месяца, едина для всей Земли: {d}-й день начинается, когда элонгация Луна–Солнце проходит {d}°. Лунные сутки традиции — от восхода до восхода Луны в вашем месте, 1-е — с момента новолуния; к концу месяца отстают от титхи на 1–2 номера.", .{ info.number, @as(u16, info.number - 1) * 12 });
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
    const tz = base.cfg.tz_offset_sec;
    try w.print("🌙 Начался {d}-й лунный день (титхи)\n", .{info.number});
    try w.print("Закончится: {s}\n", .{util.fmtDateTime(&b_dt, info.ends, tz, base.now)});
    if (lunday_rise.assess(base.now, observerOf(base.cfg))) |r| {
        try w.print("По восходам Луны — {d}-е лунные сутки, до {s}\n", .{ r.number, util.fmtDateTime(&b_dt, r.ends, tz, base.now) });
    }
    try w.print("Луна {s} {s}, фаза: {s}", .{ info.sign.glyph(), info.sign.inRu(), info.phase });
    var snap: [256]i64 = undefined;
    notify.broadcast(base.api, base.store.subsSnapshot(&snap), w.buffered());
}

pub const feature = features.Feature{
    .commands = &.{
        .{
            .name = "/day",
            .aliases = &.{ "/lunday", "/moon", "/луна" },
            .description = "лунный день: титхи и сутки от восхода, сейчас или на дату (/day 21.09)",
            .handler = cmdDay,
        },
    },
    .on_tick = onTick,
};
