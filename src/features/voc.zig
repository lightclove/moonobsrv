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
/// заметный кусок std.fmt в бинарнике. Потолок 99: пока Луна в знаке,
/// «пройдено 100%» противоречило бы строке про будущую ингрессию.
fn pct(x: f64) u32 {
    return @intFromFloat(@min(@max(0, x + 0.5), 99));
}

test "pct: округление и потолок 99 (BUG-038)" {
    try std.testing.expectEqual(@as(u32, 0), pct(-5));
    try std.testing.expectEqual(@as(u32, 50), pct(50.4));
    try std.testing.expectEqual(@as(u32, 51), pct(50.6));
    try std.testing.expectEqual(@as(u32, 99), pct(99.2));
    try std.testing.expectEqual(@as(u32, 99), pct(99.9)); // не 100 до ингрессии
}

fn cmdVoc(ctx: *router.Ctx) !void {
    const now = try ctx.moment();
    try writeStatus(now, ctx.base.cfg.tz_offset_sec, ctx.reply);
}

fn cmdVocNext(ctx: *router.Ctx) !void {
    const now = try ctx.moment();
    try writeForecast(now, ctx.base.cfg.tz_offset_sec, ctx.reply);
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
        // конец холостого периода называем словом «Закончится» — ингрессия
        // сама по себе («Вход в знак: …») читалась как справка о знаке,
        // а не как конец периода
        try w.print("Закончится: {s} (через {s}) — Луна войдёт {s}\n\n", .{
            util.fmtDateTime(&b_dt, s.ingress, tz, now),
            util.fmtDur(&b_dur, s.ingress - now),
            s.sign.next().accRu(),
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
                try w.print(" (через {s}, после аспекта {s} {s})", .{
                    util.fmtDur(&b_dur, last.t - now),
                    last.aspect.nameRu(),
                    last.body.nameRu(),
                });
            }
            try w.print(" по {s} — длится {s}, до входа Луны {s}.", .{
                to, util.fmtDur(&b_dur, s.ingress - last.t), s.sign.next().accRu(),
            });
        }
    }
}

/// Расписание холстых периодов: ближайший (идущий или будущий) и следующий
/// за ним, оба «с … по …». Отвечает на вопрос «когда будет ближайшая
/// холостая», даже если сейчас Луна уже холостая или до периода несколько
/// дней. Подробности текущего состояния — /voc, это именно прогноз.
pub fn writeForecast(now: i64, tz: i32, w: *std.Io.Writer) !void {
    var abuf: [voc.max_aspects]voc.AspectEvent = undefined;
    var periods: [voc.max_periods]voc.Period = undefined;
    const n = voc.nextPeriods(now, &abuf, &periods);
    if (n == 0) return error.NoVocPeriod;

    var b_dt: [64]u8 = undefined;
    var b_dt2: [64]u8 = undefined;
    var b_dur: [32]u8 = undefined;
    var b_dur2: [32]u8 = undefined;

    const p0 = periods[0];
    try w.print("🔮 Ближайшая холостая Луна\n\n", .{});
    if (p0.active(now)) {
        try w.print("🌚 Луна уже холостая — период идёт.\n", .{});
        try w.print("Текущий ({s} {s}): с {s} по {s} — длится {s}, закончится через {s}", .{
            p0.sign.glyph(),
            p0.sign.nameRu(),
            util.fmtDateTime(&b_dt, p0.start, tz, now),
            util.fmtDateTime(&b_dt2, p0.end, tz, now),
            util.fmtDur(&b_dur, p0.end - p0.start),
            util.fmtDur(&b_dur2, p0.end - now),
        });
    } else {
        try w.print("🌒 Луна сейчас не холостая.\n", .{});
        try w.print("Ближайший ({s} {s}): с {s}", .{
            p0.sign.glyph(),
            p0.sign.nameRu(),
            util.fmtDateTime(&b_dt, p0.start, tz, now),
        });
        if (p0.from_aspect) |a| {
            try w.print(" (через {s}, после аспекта {s} {s})", .{
                util.fmtDur(&b_dur, p0.start - now),
                a.aspect.nameRu(),
                a.body.nameRu(),
            });
        } else {
            try w.print(" — весь знак без аспектов", .{});
        }
        try w.print(" по {s} — длится {s}", .{
            util.fmtDateTime(&b_dt2, p0.end, tz, now),
            util.fmtDur(&b_dur, p0.end - p0.start),
        });
    }
    if (n > 1) {
        const p1 = periods[1];
        try w.print("\nЗатем ({s} {s}): с {s} по {s} — длится {s}", .{
            p1.sign.glyph(),
            p1.sign.nameRu(),
            util.fmtDateTime(&b_dt, p1.start, tz, now),
            util.fmtDateTime(&b_dt2, p1.end, tz, now),
            util.fmtDur(&b_dur, p1.end - p1.start),
        });
    }
    try w.print("\n\nПланируйте важные дела, сделки и покупки вне этих окон — холостое время «пустых» результатов.", .{});
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
        try w.print("Закончится: {s} (через {s}) — Луна войдёт {s}\n\n", .{
            util.fmtDateTime(&b_dt, s.ingress, tz, base.now),
            util.fmtDur(&b_dur, s.ingress - base.now),
            s.sign.next().accRu(),
        });
        try w.print("Не начинайте новых важных дел до конца периода.", .{});
    } else {
        try w.print("🌝 Луна вошла {s} — холостой период закончился ({s}).\n", .{
            s.sign.accRu(),
            util.fmtDateTime(&b_dt, base.now, tz, base.now),
        });
        try w.print("Можно снова браться за новые дела.", .{});
    }
    // уведомления о холостой Луне — премиум: рассылаем обычным подписчикам
    // и премиум-вайт-листу без дублей
    var snap: [256]i64 = undefined;
    var snap2: [256]i64 = undefined;
    const subs = base.store.subsSnapshot(&snap);
    const prem = base.store.premiumSnapshot(&snap2);
    var merged: [512]i64 = undefined;
    var n: usize = 0;
    for (subs) |id| {
        if (n >= merged.len) break;
        merged[n] = id;
        n += 1;
    }
    for (prem) |id| {
        if (n >= merged.len) break;
        var dup = false;
        for (merged[0..n]) |x| {
            if (x == id) dup = true;
        }
        if (!dup) {
            merged[n] = id;
            n += 1;
        }
    }
    notify.broadcast(base.api, merged[0..n], w.buffered());
}

pub const feature = features.Feature{
    .commands = &.{
        .{
            .name = "/voc",
            .aliases = &.{ "/void", "/холостая" },
            .description = "холостая Луна сейчас или на дату (/voc 21.09)",
            .handler = cmdVoc,
        },
        .{
            .name = "/vocnext",
            .aliases = &.{ "/next", "/ближайшая" },
            .description = "ближайшие холостые периоды: с … по …",
            .handler = cmdVocNext,
        },
    },
    .on_tick = onTick,
};
