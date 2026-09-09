//! Фича «Холостая Луна» (Void of Course): команда /voc и уведомления
//! о начале/конце холостых периодов.

const std = @import("std");
const router = @import("../bot/router.zig");
const notify = @import("../bot/notify.zig");
const features = @import("features.zig");
const astro = @import("../astro.zig");
const util = @import("../util.zig");

const voc = astro.voc;

/// Проценты печатаем целыми — форматирование дробных тянет за собой
/// заметный кусок std.fmt в бинарнике.
fn pct(x: f64) u32 {
    return @intFromFloat(@max(0, x + 0.5));
}

fn cmdVoc(ctx: *router.Ctx) !void {
    const now = try ctx.moment();
    try writeStatus(now, ctx.base.cfg.tz_offset_sec, ctx.reply);
}

/// Полный статус: используется и командой, и режимом --today.
pub fn writeStatus(now: i64, tz: i32, w: *std.Io.Writer) !void {
    var abuf: [voc.max_aspects]voc.AspectEvent = undefined;
    const s = voc.assess(now, &abuf);

    var b_dt: [64]u8 = undefined;
    var b_dt2: [64]u8 = undefined;
    var b_dur: [32]u8 = undefined;

    if (s.is_voc) {
        try w.print("🌚 Луна сейчас ХОЛОСТАЯ (Void of Course)\n", .{});
        try w.print("{s} {s} — пройдено {d}% знака\n", .{ s.sign.glyph(), s.sign.nameRu(), pct(s.progress_pct) });
        if (s.voc_last_aspect) |a| {
            try w.print("Холостая с {s} — после точного аспекта: {s} {s} {s}\n", .{
                util.fmtDateTime(&b_dt, s.voc_started, tz, now),
                a.aspect.glyph(),
                a.aspect.nameRu(),
                a.body.nameRu(),
            });
        } else {
            try w.print("Холостая с {s} — с момента входа в знак (аспектов в знаке нет)\n", .{
                util.fmtDateTime(&b_dt, s.sign_entered, tz, now),
            });
        }
        try w.print("Вход {s}: {s} (через {s})\n\n", .{
            s.sign.next().accRu(),
            util.fmtDateTime(&b_dt, s.ingress, tz, now),
            util.fmtDur(&b_dur, s.ingress - now),
        });
        try w.print("В холостой период не начинайте важных дел, сделок и покупок — время рутины, завершения начатого и отдыха.", .{});
    } else {
        try w.print("🌒 Луна не холостая\n", .{});
        try w.print("{s} {s} — пройдено {d}% знака\n", .{ s.sign.glyph(), s.sign.nameRu(), pct(s.progress_pct) });

        var upcoming: usize = 0;
        for (s.aspects) |ev| {
            if (ev.t <= now) continue;
            if (upcoming >= 6) break;
            try w.print("• {s} {s} {s} — {s}\n", .{
                ev.aspect.glyph(),                      ev.aspect.nameRu(), ev.body.nameRu(),
                util.fmtDateTime(&b_dt, ev.t, tz, now),
            });
            upcoming += 1;
        }

        // Холостая начнётся после последнего аспекта в знаке.
        if (s.aspects.len > 0) {
            const last = s.aspects[s.aspects.len - 1];
            const from = util.fmtDateTime(&b_dt, last.t, tz, now);
            const to = util.fmtDateTime(&b_dt2, s.ingress, tz, now);
            try w.print("\nБлижайший холостой период: с {s}", .{from});
            if (last.t > now) {
                try w.print(" (после аспекта {s} {s})", .{ last.aspect.nameRu(), last.body.nameRu() });
            }
            try w.print(" до входа {s} ({s}).", .{ s.sign.next().accRu(), to });
        }
    }
}

/// Ватчер: уведомляет подписчиков о переходах VOC.
pub fn onTick(base: router.Base) !void {
    var abuf: [voc.max_aspects]voc.AspectEvent = undefined;
    const s = voc.assess(base.now, &abuf);
    const prev = base.store.getFlag(.voc_active) orelse s.is_voc;
    if (s.is_voc == prev) return;

    try base.store.setFlag(.voc_active, s.is_voc);

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var b_dt: [64]u8 = undefined;
    var b_dur: [32]u8 = undefined;
    const tz = base.cfg.tz_offset_sec;

    if (s.is_voc) {
        try w.print("🌚 Луна стала ХОЛОСТОЙ (Void of Course)\n", .{});
        try w.print("Знак: {s} {s}\n", .{ s.sign.glyph(), s.sign.nameRu() });
        if (s.voc_last_aspect) |a| {
            try w.print("Последний аспект: {s} {s} {s} в {s}\n", .{
                a.aspect.glyph(),                                     a.aspect.nameRu(), a.body.nameRu(),
                util.fmtDateTime(&b_dt, s.voc_started, tz, base.now),
            });
        }
        try w.print("Холостая до входа {s}: {s} (через {s})\n\n", .{
            s.sign.next().accRu(),
            util.fmtDateTime(&b_dt, s.ingress, tz, base.now),
            util.fmtDur(&b_dur, s.ingress - base.now),
        });
        try w.print("Не начинайте новых важных дел до конца периода.", .{});
    } else {
        try w.print("🌝 Луна вошла {s} — холостой период закончился ({s}).\n", .{
            s.sign.accRu(),
            util.fmtDateTime(&b_dt, base.now, tz, base.now),
        });
        try w.print("Можно снова браться за новые дела.", .{});
    }
    var snap: [128]i64 = undefined;
    notify.broadcast(base.api, base.store.subsSnapshot(&snap), w.buffered());
}

pub const feature = features.Feature{
    .commands = &.{
        .{
            .name = "/voc",
            .aliases = &.{ "/void", "/холостая" },
            .description = "холостая Луна сейчас или на дату (/voc 21.09)",
            .handler = cmdVoc,
        },
    },
    .on_tick = onTick,
};
