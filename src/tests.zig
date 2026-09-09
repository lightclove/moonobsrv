//! Корень тестового бинарника: подтягивает все модули (их тесты) и добавляет
//! астрономические якорные проверки по реальным событиям 2026 года.

const std = @import("std");
const astro = @import("astro.zig");
const util = @import("util.zig");

test {
    _ = @import("util.zig");
    _ = @import("envfile.zig");
    _ = @import("config.zig");
    _ = @import("net/socks5.zig");
    _ = @import("net/https.zig");
    _ = @import("db/pg.zig");
    _ = @import("astro.zig");
    _ = @import("bot/telegram.zig");
    _ = @import("bot/router.zig");
    _ = @import("bot/store.zig");
    _ = @import("bot/notify.zig");
    _ = @import("bot/webhook.zig");
    _ = @import("bot/wd.zig");
    _ = @import("bot/mon.zig");
    _ = @import("bot/rst.zig");
    _ = @import("bot/access.zig");
    _ = @import("bot/cb.zig");
    _ = @import("features/features.zig");
    _ = @import("hostwatch.zig");
}

const time = astro.time;
const ang = astro.angles;
const moon = astro.moon;
const sunmod = astro.sun;
const planets = astro.planets;
const retro = astro.retro;
const voc = astro.voc;
const lunday = astro.lunday;

fn elong(jd: f64) f64 {
    return ang.wrap180(moon.longitudeRaw(jd) - sunmod.longitudeRaw(jd));
}

// Полное солнечное затмение 12.08.2026, максимум 17:45:54 UTC:
// Луна и Солнце в одной точке эклиптики. Допуск 0.6° ≈ ±70 минут хода Луны.
test "якорь: солнечное затмение 2026-08-12 17:46 UTC" {
    const jd = time.jdFromUnix(time.unixUTC(2026, 8, 12, 17, 46));
    const e = elong(jd);
    try std.testing.expect(@abs(e) < 0.6);
}

// Полное лунное затмение 03.03.2026, максимум 11:33:37 UTC: элонгация 180°.
test "якорь: лунное затмение 2026-03-03 11:33 UTC" {
    const jd = time.jdFromUnix(time.unixUTC(2026, 3, 3, 11, 33));
    const e = elong(jd);
    try std.testing.expect(@abs(@abs(e) - 180.0) < 0.8);
}

// Ретро-Меркурий 2026: 26.02–20.03, 29.06–23.07, 24.10–13.11 (Old Farmer's Almanac).
test "якорь: ретроградный Меркурий 2026" {
    try std.testing.expect(retro.isRetro(.mercury, time.unixUTC(2026, 3, 8, 12, 0)));
    try std.testing.expect(!retro.isRetro(.mercury, time.unixUTC(2026, 4, 10, 12, 0)));
    try std.testing.expect(retro.isRetro(.mercury, time.unixUTC(2026, 7, 5, 12, 0)));
    try std.testing.expect(!retro.isRetro(.mercury, time.unixUTC(2026, 8, 5, 12, 0)));
    try std.testing.expect(retro.isRetro(.mercury, time.unixUTC(2026, 11, 1, 12, 0)));

    var wb: [retro.max_windows]?retro.Window = undefined;
    const n = retro.upcoming(.mercury, time.unixUTC(2026, 2, 1, 0, 0), &wb);
    try std.testing.expect(n >= 3);

    // станции в пределах полутора суток от табличных
    const tol: i64 = 36 * 3600;
    try expectNearDay(wb[0].?.start, time.unixUTC(2026, 2, 26, 7, 0), tol);
    try expectNearDay(wb[0].?.end, time.unixUTC(2026, 3, 20, 0, 0), tol);
    try expectNearDay(wb[1].?.start, time.unixUTC(2026, 6, 29, 18, 0), tol);
    try expectNearDay(wb[1].?.end, time.unixUTC(2026, 7, 23, 0, 0), tol);
    try expectNearDay(wb[2].?.start, time.unixUTC(2026, 10, 24, 0, 0), tol);
    try expectNearDay(wb[2].?.end, time.unixUTC(2026, 11, 13, 0, 0), tol);
    // четвёртое окно: 09.02–03.03.2027 (Astro-Seek/Drik Panchang)
    try expectNearDay(wb[3].?.start, time.unixUTC(2027, 2, 9, 18, 0), tol);
    try expectNearDay(wb[3].?.end, time.unixUTC(2027, 3, 3, 13, 0), tol);

    // тени обрамляют ретро-период
    try std.testing.expect(wb[0].?.pre_shadow < wb[0].?.start);
    try std.testing.expect(wb[0].?.post_shadow > wb[0].?.end);
}

fn expectNearDay(actual: i64, expected: i64, tol: i64) !void {
    if (@abs(actual - expected) > tol) {
        std.debug.print("ожидалось около {d}, получено {d} (сдвиг {d} с)\n", .{ expected, actual, actual - expected });
        return error.TestUnexpectedResult;
    }
}

test "VOC: инварианты на дату запуска" {
    const now = time.unixUTC(2026, 9, 9, 12, 0);
    var abuf: [voc.max_aspects]voc.AspectEvent = undefined;
    const s = voc.assess(now, &abuf);

    // ингрессия в пределах 62 часов, в прошлом — вход в знак
    try std.testing.expect(s.ingress > now and s.ingress < now + 62 * 3600);
    try std.testing.expect(s.sign_entered < now and s.sign_entered > now - 62 * 3600);
    try std.testing.expect(s.progress_pct >= 0 and s.progress_pct < 100);

    // после ингрессии Луна действительно в следующем знаке
    const after = voc.Sign.fromLongitude(moon.longitudeRaw(time.jdFromUnix(s.ingress + 60)));
    try std.testing.expectEqual(s.sign.next(), after);

    // аспекты отсортированы; VOC ⇔ нет аспектов после текущего момента
    var i: usize = 1;
    while (i < s.aspects.len) : (i += 1) {
        try std.testing.expect(s.aspects[i - 1].t <= s.aspects[i].t);
    }
    var any_after = false;
    for (s.aspects) |ev| {
        if (ev.t > now) any_after = true;
    }
    try std.testing.expectEqual(any_after, !s.is_voc);
    if (s.is_voc) {
        try std.testing.expect(s.voc_started <= now);
    }
}

test "лунный день: инварианты" {
    const now = time.unixUTC(2026, 9, 9, 12, 0);
    const info = lunday.assess(now);
    try std.testing.expect(info.number >= 1 and info.number <= 30);
    try std.testing.expect(info.started < now and now < info.ends);
    const dur = info.ends - info.started;
    try std.testing.expect(dur > 21 * 3600 and dur < 27 * 3600);
    try std.testing.expect(info.illum_pct >= 0 and info.illum_pct <= 100);

    // в момент новолуния 2026-08-12 начинается 1-й лунный день
    const nm = lunday.assess(time.unixUTC(2026, 8, 12, 19, 0));
    try std.testing.expect(nm.number == 1);
}

test "долгота Луны строго растёт, элонгация тоже" {
    var jd = time.jdFromUnix(time.unixUTC(2026, 1, 1, 0, 0));
    var prev_lam = moon.longitudeRaw(jd);
    var prev_e = moon.longitudeRaw(jd) - sunmod.longitudeRaw(jd);
    var step: usize = 0;
    while (step < 180) : (step += 1) {
        jd += 2.0;
        const lam = moon.longitudeRaw(jd);
        const e = moon.longitudeRaw(jd) - sunmod.longitudeRaw(jd);
        try std.testing.expect(lam - prev_lam > 2.0 * 11.0); // > 11°/сутки
        try std.testing.expect(e - prev_e > 2.0 * 10.5); // элонгация ≥ ~10.5°/сутки
        prev_lam = lam;
        prev_e = e;
    }
}

test "долготы планет в разумных пределах" {
    const jd = time.jdFromUnix(time.unixUTC(2026, 9, 9, 0, 0));
    inline for (.{ planets.Body.mercury, .venus, .mars, .jupiter, .saturn }) |b| {
        const lam = planets.longitude(b, jd);
        try std.testing.expect(lam >= 0 and lam < 360);
    }
}

// Ретро-Венера 2026: 3 октября — 14 ноября (Almanac/Astro-Seek).
test "якорь: ретро-Венера октябрь-ноябрь 2026" {
    try std.testing.expect(!retro.isRetro(.venus, time.unixUTC(2026, 9, 9, 12, 0)));
    try std.testing.expect(retro.isRetro(.venus, time.unixUTC(2026, 10, 20, 12, 0)));

    var wb: [retro.max_windows]?retro.Window = undefined;
    const n = retro.upcoming(.venus, time.unixUTC(2026, 9, 9, 0, 0), &wb);
    try std.testing.expect(n >= 1);
    try expectNearDay(wb[0].?.start, time.unixUTC(2026, 10, 3, 0, 0), 36 * 3600);
    try expectNearDay(wb[0].?.end, time.unixUTC(2026, 11, 14, 0, 0), 36 * 3600);
}

test "планеты: текст статуса" {
    const f_planets = @import("features/planets.zig");
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try f_planets.writeStatus(.venus, time.unixUTC(2026, 9, 9, 12, 0), 3 * 3600, &w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Венера") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "директное") != null);

    var buf2: [1024]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    try f_planets.writeStatus(.saturn, time.unixUTC(2026, 9, 9, 12, 0), 3 * 3600, &w2);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "Сатурн") != null);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "ретроградное") != null); // июль–декабрь 2026
}

test "форматирование дат согласовано" {
    const t = time.unixUTC(2026, 9, 9, 14, 32);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("9 сентября, 17:32", util.fmtDateTime(&buf, t, 3 * 3600, t));
    var buf2: [24]u8 = undefined;
    try std.testing.expectEqualStrings("МСК", util.tzLabel(&buf2, 3 * 3600));
}

// РегрессияSmoke: тексты фич форматируются целиком, без переполнений
// (ловит алиасинг буферов и u8-переполнение (number-1)*12).
test "тексты фич: форматирование без мусора" {
    const f_voc = @import("features/voc.zig");
    const f_mercury = @import("features/mercury.zig");
    const f_lunday = @import("features/lunday.zig");

    const now = time.unixUTC(2026, 9, 9, 0, 0); // 03:00 МСК 9 сентября
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try f_voc.writeStatus(now, 3 * 3600, &w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Луна не холостая") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Деву") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "22:36") != null);

    var buf2: [4096]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    try f_mercury.writeStatus(now, 3 * 3600, &w2);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "директен") != null);
    // даты станций печатаются раздельно: обе части диапазона присутствуют
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "24 октября") != null);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "13 ноября") != null);

    var buf3: [4096]u8 = undefined;
    var w3: std.Io.Writer = .fixed(&buf3);
    try f_lunday.writeStatus(now, 3 * 3600, &w3);
    try std.testing.expect(std.mem.indexOf(u8, w3.buffered(), "28-й лунный день") != null);
    try std.testing.expect(std.mem.indexOf(u8, w3.buffered(), "324") != null); // (28-1)*12 без u8-переполнения
}
