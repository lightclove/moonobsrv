//! Переводы времени: Unix <-> юлианский день (JD) <-> юлианские столетия от J2000.

pub const JD_J2000: f64 = 2451545.0;
pub const JD_UNIX_EPOCH: f64 = 2440587.5;

pub fn jdFromUnix(secs: i64) f64 {
    return @as(f64, @floatFromInt(secs)) / 86400.0 + JD_UNIX_EPOCH;
}

pub fn unixFromJd(jd: f64) i64 {
    return @intFromFloat((jd - JD_UNIX_EPOCH) * 86400.0);
}

pub fn centuriesSinceJ2000(jd: f64) f64 {
    return (jd - JD_J2000) / 36525.0;
}

/// Unix-время из гражданской даты по UTC (для тестов и якорей).
pub fn unixUTC(y: i32, mo: u8, d: u8, h: u8, mi: u8) i64 {
    return daysFromCivil(y, mo, d) * 86400 + @as(i64, h) * 3600 + @as(i64, mi) * 60;
}

/// Дней от 1970-01-01 до указанной даты (алгоритм Говарда Хиннанта).
pub fn daysFromCivil(y_in: i32, m: u8, d: u8) i64 {
    const y: i64 = y_in;
    const y2 = if (m <= 2) y - 1 else y;
    const era = @divFloor(y2, 400);
    const yoe = y2 - era * 400;
    const mp: i64 = if (m > 2) @as(i64, m) - 3 else @as(i64, m) + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "daysFromCivil" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 19723), daysFromCivil(2024, 1, 1)); // проверено: 2024-01-01
    try std.testing.expectEqual(unixUTC(2026, 8, 12, 17, 46), daysFromCivil(2026, 8, 12) * 86400 + 17 * 3600 + 46 * 60);
}

test "jd roundtrip" {
    const std = @import("std");
    const t: i64 = 1_773_000_000;
    const back: i64 = unixFromJd(jdFromUnix(t));
    const diff: f64 = @floatFromInt(back - t);
    try std.testing.expectApproxEqAbs(@as(f64, 0), diff, 0.001);
}
