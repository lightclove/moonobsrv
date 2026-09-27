//! Премиум-фича «Полнолуние»: уведомления за двое и за одни сутки до
//! полнолуния с процентом освещённости, плюс момент самого полнолуния.
//! Доступ: админ и вайт-лист избранных (`/grant`), остальные — платная
//! подписка (заглушка оплаты: платёжный контур не подключён, премиум
//! выдаёт админ вручную). Премиум-уведомления — полнолуние и холостая
//! Луна; прочие (ретро, лунные дни) остаются в обычной подписке.

const std = @import("std");
const router = @import("../bot/router.zig");
const notify = @import("../bot/notify.zig");
const features = @import("features.zig");
const astro = @import("../astro.zig");
const util = @import("../util.zig");

const time = astro.time;
const lunday = astro.lunday;
const moon = astro.moon;
const sunmod = astro.sun;
const ang = astro.angles;

/// Освещённость Луны в процентах (0..100) на момент jd.
fn illumPct(jd: f64) u32 {
    const e = ang.wrap360(moon.longitudeRaw(jd) - sunmod.longitudeRaw(jd));
    return @intFromFloat(@min(@max((1.0 - ang.cosD(e)) / 2.0 * 100.0 + 0.5, 0), 100));
}

/// Уведомлять ли на этом тике: ступень сменилась (включая первое
/// предупреждение «за двое суток») — да. Ступени: за двое суток (48 ч),
/// за сутки (24 ч) и сам момент.
fn shouldWarn(prev_step: ?u8, step: u8) bool {
    if (prev_step == null) return step != 2; // первое знакомство: не спамим постфактум
    return step != prev_step.?;
}

fn isAdmin(ctx: *router.Ctx) bool {
    return ctx.base.cfg.admin_id != 0 and ctx.from_id != null and ctx.from_id.? == ctx.base.cfg.admin_id;
}

fn denyAdmin(ctx: *router.Ctx) !void {
    try ctx.reply.writeAll("Команда только для админа.");
}

/// Полнолуние: когда, сколько осталось, сколько освещено сейчас.
fn cmdFullMoon(ctx: *router.Ctx) !void {
    const now = try ctx.moment();
    try writeFullMoonText(now, ctx.base.cfg.tz_offset_sec, ctx.reply);
}

pub fn writeFullMoonText(now: i64, tz: i32, w: *std.Io.Writer) !void {
    const jd0 = time.jdFromUnix(now);
    const fm_jd = lunday.nextFullMoonJd(jd0);
    const fm = time.unixFromJd(fm_jd);
    var b_dt: [64]u8 = undefined;
    var b_dur: [32]u8 = undefined;
    try w.print("🌕 Полнолуние: {s} (через {s})\n", .{
        util.fmtDateTime(&b_dt, fm, tz, now), util.fmtDur(&b_dur, fm - now),
    });
    try w.print("Освещённость сейчас: {d}%", .{illumPct(jd0)});
}

/// Заглушка платной подписки: платёжный контур не подключён — премиум
/// выдаёт админ (вайт-лист избранных через /grant). Честно об этом и пишем.
fn cmdPremium(ctx: *router.Ctx) !void {
    if (ctx.base.store.isPremium(ctx.chat_id)) {
        return ctx.reply.writeAll("⭐ У вас премиум: уведомления о холостой Луне и полнолунии (за 2 суток и за сутки — с процентом освещённости).\nОтключить: /unsubscribe");
    }
    try ctx.reply.writeAll("⭐ Премиум: уведомления о холостой Луне и полнолунии — за двое суток и за сутки до полнолуния, с процентом освещённости.\n\nОплата пока не подключена: премиум выдаёт владелец бота в вайт-лист избранных. Напишите ему — команда выдачи у админа.");
}

/// Выдача премиума в вайт-лист избранных: /grant <telegram_id>.
fn cmdGrant(ctx: *router.Ctx) !void {
    if (!isAdmin(ctx)) return denyAdmin(ctx);
    if (!ctx.base.store.dbMode()) {
        return ctx.reply.writeAll("Вайт-лист ведётся только с Postgres. Сейчас бот в режиме без БД — премиум и так у всех.");
    }
    const id = std.fmt.parseInt(i64, std.mem.trim(u8, ctx.args, " \t"), 10) catch {
        return ctx.reply.writeAll("Формат: /grant <telegram_id>");
    };
    if (id == ctx.base.cfg.admin_id) {
        return ctx.reply.writeAll("У админа премиум и так есть.");
    }
    if (ctx.base.store.setPremium(id, true)) {
        ctx.base.api.sendMessage(id, "⭐ Вам выдан премиум: уведомления о полнолунии (за 2 суток и за сутки) и холостой Луне.\nВключить уведомления: /subscribe") catch {};
        ctx.reply_html = true; // <code> в ответе
        try ctx.reply.print("Премиум выдан <code>{d}</code>.", .{id});
    } else {
        try ctx.reply.writeAll("Не удалось — проверьте БД.");
    }
}

/// Снятие премиума: /revokepremium <telegram_id>.
fn cmdRevokePremium(ctx: *router.Ctx) !void {
    if (!isAdmin(ctx)) return denyAdmin(ctx);
    if (!ctx.base.store.dbMode()) {
        return ctx.reply.writeAll("Вайт-лист ведётся только с Postgres. Сейчас бот в режиме без БД — премиум и так у всех.");
    }
    const id = std.fmt.parseInt(i64, std.mem.trim(u8, ctx.args, " \t"), 10) catch {
        return ctx.reply.writeAll("Формат: /revokepremium <telegram_id>");
    };
    if (id == ctx.base.cfg.admin_id) {
        return ctx.reply.writeAll("Нельзя снять премиум у админа.");
    }
    if (ctx.base.store.setPremium(id, false)) {
        ctx.base.api.sendMessage(id, "Премиум отключён.") catch {};
        ctx.reply_html = true;
        try ctx.reply.print("Премиум снят у <code>{d}</code>.", .{id});
    } else {
        try ctx.reply.writeAll("Не удалось — проверьте БД.");
    }
}

/// Ватчер: рассылает предупреждения о полнолунии премиум-подписчикам.
/// Ключ — день полнолуния (одного полнолуния на лунный месяц); ступени
/// (за 48 ч, за 24 ч, сам момент) различаются, чтобы одно и то же
/// предупреждение не пришло дважды.
fn onTick(base: router.Base) !void {
    const now = base.now;
    const fm = time.unixFromJd(lunday.nextFullMoonJd(time.jdFromUnix(now)));
    const key = @divTrunc(fm, 86400);
    const step_idx = warnStep(now, fm);
    const prev = base.store.fullmoonWarn();

    if (prev != null and prev.? == key) {
        // то же полнолуние: уведомляем только при смене ступени
        if (!shouldWarn(base.store.fullmoonStep(), step_idx)) return;
    } else if (prev == null) {
        // первый запуск — молча инициализируем состояние
        try base.store.setFullmoonWarn(key);
        base.store.setFullmoonStep(step_idx);
        return;
    }

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var b_dt: [64]u8 = undefined;
    const tz = base.cfg.tz_offset_sec;
    const jd0 = time.jdFromUnix(now);

    if (step_idx == 2) {
        try w.print("🌕 Полнолуние! Освещённость {d}%\n", .{illumPct(jd0)});
        try w.print("Пик — {s}. До новолуния Луна будет убывать.", .{util.fmtDateTime(&b_dt, fm, tz, now)});
    } else {
        try writeWarnText(now, fm, tz, &w);
    }
    var snap: [256]i64 = undefined;
    notify.broadcast(base.api, base.store.premiumSnapshot(&snap), w.buffered());
    try base.store.setFullmoonWarn(key);
    base.store.setFullmoonStep(step_idx);
}

/// Ступень предупреждения: 0 — за двое суток (48 ч), 1 — за сутки (24 ч),
/// 2 — сам момент (полная Луна уже была). Дальше 48 ч — 0: ступень «за двое
/// суток» живёт от порога 48 ч до порога 24 ч.
fn warnStep(now: i64, fm: i64) u8 {
    const d = fm - now;
    if (d <= 0) return 2;
    if (d <= 86400) return 1;
    return 0;
}

/// Текст предупреждения (до полнолуния): через сколько, когда, проценты.
pub fn writeWarnText(now: i64, fm: i64, tz: i32, w: *std.Io.Writer) !void {
    var b_dt: [64]u8 = undefined;
    var b_dur: [32]u8 = undefined;
    try w.print("🌕 Через {s} — полнолуние ({s})\n", .{
        util.fmtDur(&b_dur, fm - now), util.fmtDateTime(&b_dt, fm, tz, now),
    });
    try w.print("Освещённость сейчас: {d}%", .{illumPct(time.jdFromUnix(now))});
}

pub const feature = features.Feature{
    .commands = &.{
        .{
            .name = "/fullmoon",
            .aliases = &.{ "/полнолуние", "/moonpct" },
            .description = "полнолуние: когда и сколько освещено сейчас (/fullmoon 21.09)",
            .handler = cmdFullMoon,
        },
        .{
            .name = "/premium",
            .aliases = &.{"/премиум"},
            .description = "премиум-подписка: уведомления о полнолунии и холостой Луне",
            .handler = cmdPremium,
        },
        .{
            .name = "/grant",
            .description = "выдать премиум в вайт-лист избранных (админ)",
            .handler = cmdGrant,
        },
        .{
            .name = "/revokepremium",
            .description = "снять премиум (админ)",
            .handler = cmdRevokePremium,
        },
    },
    .on_tick = onTick,
};

// ─── Тесты ──────────────────────────────────────────────────────────────────

test "якорь: полнолуния 2026 (nextFullMoonJd)" {
    // 28.08.2026 04:18 UTC (лунное затмение) и 26.09.2026 16:49 UTC
    // (timeanddate/skyatnight); допуск ±15 мин, как у якорей новолуний
    const jd = time.jdFromUnix(time.unixUTC(2026, 9, 9, 12, 0));
    const fm = time.unixFromJd(lunday.nextFullMoonJd(jd));
    try expectNear(fm, time.unixUTC(2026, 9, 26, 16, 49), 15 * 60);
    // до полнолуния 28.08 ближайшее — оно само
    const jd2 = time.jdFromUnix(time.unixUTC(2026, 8, 20, 0, 0));
    const fm2 = time.unixFromJd(lunday.nextFullMoonJd(jd2));
    try expectNear(fm2, time.unixUTC(2026, 8, 28, 4, 18), 15 * 60);
    // строго после запрошенного момента
    try std.testing.expect(fm2 > time.unixFromJd(jd2));
}

fn expectNear(actual: i64, expected: i64, tol: i64) !void {
    if (@abs(actual - expected) > tol) {
        std.debug.print("ожидалось около {d}, получено {d} (сдвиг {d} с)\n", .{ expected, actual, actual - expected });
        return error.TestUnexpectedResult;
    }
}

test "illumPct: новолуние ~0, полнолуние ~100" {
    // новолуние 11.09.2026 03:27 UTC, полнолуние 26.09.2026 16:49 UTC
    try std.testing.expect(illumPct(time.jdFromUnix(time.unixUTC(2026, 9, 11, 3, 27))) <= 1);
    try std.testing.expect(illumPct(time.jdFromUnix(time.unixUTC(2026, 9, 26, 16, 49))) >= 99);
}

test "warnStep: ступени по расстоянию до полнолуния" {
    const fm = time.unixUTC(2026, 9, 26, 16, 49);
    try std.testing.expectEqual(@as(u8, 0), warnStep(fm - 2 * 86400 - 3600, fm)); // дальше 48 ч
    try std.testing.expectEqual(@as(u8, 0), warnStep(fm - 2 * 86400, fm)); // ровно 48 ч
    try std.testing.expectEqual(@as(u8, 1), warnStep(fm - 86400, fm)); // ровно сутки
    try std.testing.expectEqual(@as(u8, 1), warnStep(fm - 23 * 3600, fm)); // внутри 24 ч
    try std.testing.expectEqual(@as(u8, 0), warnStep(fm - 25 * 3600, fm)); // чуть больше суток — ещё «за двое»
    try std.testing.expectEqual(@as(u8, 2), warnStep(fm + 60, fm)); // сам момент
    // между ступенями (30 ч): порог 48 ч пройден, 24 ч — нет → ступень 0
    try std.testing.expectEqual(@as(u8, 0), warnStep(fm - 30 * 3600, fm));
}

test "shouldWarn: первая встреча без спама, смена ступени — сигнал" {
    try std.testing.expect(!shouldWarn(null, 2)); // первый запуск после полнолуния — молчим
    try std.testing.expect(shouldWarn(null, 0)); // первый запуск до полнолуния — предупредим
    try std.testing.expect(!shouldWarn(0, 0)); // та же ступень — молчим
    try std.testing.expect(shouldWarn(0, 1)); // сутки вместо двух — сигнал
    try std.testing.expect(shouldWarn(1, 2)); // сам момент — сигнал
}

test "текст /fullmoon: момент и проценты" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeFullMoonText(time.unixUTC(2026, 9, 9, 12, 0), 3 * 3600, &w);
    const s = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s, "Полнолуние") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "26 сентября") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Освещённость сейчас: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "%") != null);
}

test "текст предупреждений: за двое суток и за сутки" {
    const fm = time.unixUTC(2026, 9, 26, 16, 49);
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeWarnText(fm - 2 * 86400, fm, 3 * 3600, &w);
    const s2 = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s2, "2 д") != null); // «через 2 д»
    try std.testing.expect(std.mem.indexOf(u8, s2, "26 сентября") != null);

    var buf2: [512]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    try writeWarnText(fm - 86400, fm, 3 * 3600, &w2);
    const s1 = w2.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s1, "1 д") != null); // «через 1 д»
    try std.testing.expect(std.mem.indexOf(u8, s1, "Освещённость") != null);
}
