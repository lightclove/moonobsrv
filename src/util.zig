//! Утилиты форматирования: гражданские даты (алгоритм Хиннанта),
//! русские месяцы/длительности/плюрализация.

const std = @import("std");

pub const Date = struct { y: i32, mo: u8, d: u8, hh: u8, mm: u8, ss: u8 };

pub const month_gen = [12][]const u8{
    "января", "февраля", "марта",       "апреля",   "мая",       "июня",
    "июля",     "августа", "сентября", "октября", "ноября", "декабря",
};

fn civilFromDays(z_in: i64) struct { y: i64, m: i64, d: i64 } {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

pub fn civilFromUnix(secs: i64, tz_off: i32) Date {
    const local = secs + tz_off;
    const days = @divFloor(local, 86400);
    const sod = @mod(local, 86400);
    const c = civilFromDays(days);
    return .{
        .y = @intCast(c.y),
        .mo = @intCast(c.m),
        .d = @intCast(c.d),
        .hh = @intCast(@divTrunc(sod, 3600)),
        .mm = @intCast(@mod(@divTrunc(sod, 60), 60)),
        .ss = @intCast(@mod(sod, 60)),
    };
}

/// «14:32» в заданной зоне.
pub fn fmtClock(buf: []u8, secs: i64, tz_off: i32) []const u8 {
    const dt = civilFromUnix(secs, tz_off);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ dt.hh, dt.mm }) catch buf[0..0];
}

/// «9 сентября, 14:32» (год добавляется, если отличается от текущего).
pub fn fmtDateTime(buf: []u8, secs: i64, tz_off: i32, now_for_year: i64) []const u8 {
    const dt = civilFromUnix(secs, tz_off);
    const cur = civilFromUnix(now_for_year, tz_off);
    if (dt.y != cur.y) {
        return std.fmt.bufPrint(buf, "{d} {s} {d}, {d:0>2}:{d:0>2}", .{
            dt.d, month_gen[dt.mo - 1], dt.y, dt.hh, dt.mm,
        }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d} {s}, {d:0>2}:{d:0>2}", .{
        dt.d, month_gen[dt.mo - 1], dt.hh, dt.mm,
    }) catch buf[0..0];
}

/// Метка часового пояса: «МСК» для UTC+3, иначе «UTC+5:30».
pub fn tzLabel(buf: []u8, off_sec: i32) []const u8 {
    if (off_sec == 3 * 3600) return "МСК";
    if (off_sec == 0) return "UTC";
    const h = @divTrunc(off_sec, 3600);
    const m: u32 = @intCast(@abs(@mod(off_sec, 3600)));
    const sign: []const u8 = if (off_sec < 0) "-" else "+";
    if (m == 0) {
        return std.fmt.bufPrint(buf, "UTC{s}{d}", .{ sign, @abs(h) }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "UTC{s}{d}:{d:0>2}", .{ sign, @abs(h), m }) catch buf[0..0];
}

/// «3 ч 15 мин», «2 д 4 ч», «45 мин».
pub fn fmtDur(buf: []u8, secs_in: i64) []const u8 {
    var s = secs_in;
    if (s < 0) s = 0;
    const d = @divTrunc(s, 86400);
    const h = @divTrunc(@mod(s, 86400), 3600);
    const m = @divTrunc(@mod(s, 3600), 60);
    if (d > 0) {
        if (h > 0) return std.fmt.bufPrint(buf, "{d} д {d} ч", .{ d, h }) catch buf[0..0];
        return std.fmt.bufPrint(buf, "{d} д", .{d}) catch buf[0..0];
    }
    if (h > 0) {
        if (m > 0) return std.fmt.bufPrint(buf, "{d} ч {d} мин", .{ h, m }) catch buf[0..0];
        return std.fmt.bufPrint(buf, "{d} ч", .{h}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d} мин", .{m}) catch buf[0..0];
}

/// Русская плюрализация: plural(2, "день", "дня", "дней") == "дня".
pub fn plural(n: i64, one: []const u8, few: []const u8, many: []const u8) []const u8 {
    const n100 = @mod(n, 100);
    const n10 = @mod(n, 10);
    if (n10 == 1 and n100 != 11) return one;
    if (n10 >= 2 and n10 <= 4 and (n100 < 12 or n100 > 14)) return few;
    return many;
}

test "civilFromUnix" {
    const dt = civilFromUnix(0, 0);
    try std.testing.expectEqual(@as(i32, 1970), dt.y);
    try std.testing.expectEqual(@as(u8, 1), dt.mo);
    try std.testing.expectEqual(@as(u8, 1), dt.d);
    const dt2 = civilFromUnix(1_773_484_800, 0); // 2026-03-14 00:00 UTC
    try std.testing.expectEqual(@as(i32, 2026), dt2.y);
    try std.testing.expectEqual(@as(u8, 3), dt2.mo);
    try std.testing.expectEqual(@as(u8, 14), dt2.d);
    const dt3 = civilFromUnix(1_773_484_800, 3 * 3600); // 10:40 UTC + 3ч = 13:40
    try std.testing.expectEqual(@as(u8, 13), dt3.hh);
}

test "plural and fmtDur" {
    try std.testing.expectEqualStrings("день", plural(1, "день", "дня", "дней"));
    try std.testing.expectEqualStrings("дня", plural(2, "день", "дня", "дней"));
    try std.testing.expectEqualStrings("дней", plural(5, "день", "дня", "дней"));
    try std.testing.expectEqualStrings("дней", plural(11, "день", "дня", "дней"));
    try std.testing.expectEqualStrings("день", plural(21, "день", "дня", "дней"));

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("7 ч 26 мин", fmtDur(&buf, 7 * 3600 + 26 * 60));
    try std.testing.expectEqualStrings("2 д 4 ч", fmtDur(&buf, 2 * 86400 + 4 * 3600));
    try std.testing.expectEqualStrings("45 мин", fmtDur(&buf, 45 * 60));
}

/// Разбор аргумента-даты для команд: «21.09», «21.09.2026», «2026-09-21».
/// null — аргумент пуст (использовать «сейчас»); error.BadDate — не разобралось.
/// Возвращается полдень указанного дня в зоне tz.
pub fn parseDateArg(args: []const u8, tz: i32) !?i64 {
    const s = std.mem.trim(u8, args, " \t");
    if (s.len == 0) return null;

    var day: u8 = 0;
    var month: u8 = 0;
    var year: i32 = 0;
    if (std.mem.indexOfScalar(u8, s, '-')) |dash| {
        if (dash != 4 or s.len < 10) return error.BadDate; // ждём ISO yyyy-mm-dd
        year = std.fmt.parseInt(i32, s[0..4], 10) catch return error.BadDate;
        month = std.fmt.parseInt(u8, s[5..7], 10) catch return error.BadDate;
        day = std.fmt.parseInt(u8, s[8..10], 10) catch return error.BadDate;
    } else {
        const p1 = std.mem.indexOfScalar(u8, s, '.') orelse return error.BadDate;
        day = std.fmt.parseInt(u8, s[0..p1], 10) catch return error.BadDate;
        const rest = s[p1 + 1 ..];
        const p2 = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
        month = std.fmt.parseInt(u8, rest[0..p2], 10) catch return error.BadDate;
        year = if (p2 < rest.len)
            std.fmt.parseInt(i32, rest[p2 + 1 ..], 10) catch return error.BadDate
        else
            0; // год не указан — подставим текущий
    }
    if (year == 0) {
        const now = civilFromUnix(std.time.timestamp(), tz);
        year = now.y;
    }
    if (month < 1 or month > 12 or day < 1 or day > 31 or year < 1900 or year > 2200) {
        return error.BadDate;
    }

    const days = @import("astro/time.zig").daysFromCivil(year, month, day);
    return days * 86400 + 12 * 3600 - tz;
}

test "parseDateArg" {
    const t1 = (try parseDateArg("21.09.2026", 3 * 3600)).?;
    const dt = civilFromUnix(t1, 3 * 3600);
    try std.testing.expectEqual(@as(i32, 2026), dt.y);
    try std.testing.expectEqual(@as(u8, 9), dt.mo);
    try std.testing.expectEqual(@as(u8, 21), dt.d);
    try std.testing.expectEqual(@as(u8, 12), dt.hh); // полдень

    const t2 = (try parseDateArg("2026-09-21", 0)).?;
    try std.testing.expectEqual(t1 + 3 * 3600, t2); // полдень UTC = полдень МСК + 3 ч

    // без года берётся текущий — просто проверяем, что разбирается
    try std.testing.expect((try parseDateArg("21.09", 0)) != null);
    try std.testing.expectEqual(@as(?i64, null), try parseDateArg("   ", 0));
    try std.testing.expectError(error.BadDate, parseDateArg("32.13", 0));
    try std.testing.expectError(error.BadDate, parseDateArg("завтра", 0));
    try std.testing.expectError(error.BadDate, parseDateArg("1.1.1234", 0));
}
